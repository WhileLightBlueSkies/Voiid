//
//  GroupEngine.swift
//  Voiid
//
//  Real end-to-end-encrypted GROUP messaging on top of the MLS FFI (voiid.swift)
//  + the backend's /mls/* endpoints. Mirrors ChatEngine (1:1) but for MLS groups.
//
//  Model (single-committer):
//   - ONE MLS `GroupMember` per DEVICE (identity = "<userId>::<deviceId>" UTF-8),
//     created/restored + persisted to the Keychain. Its serialized blob holds the
//     signer + KeyPackage privates + EVERY group we belong to. MLS state is
//     in-memory only, so we re-serialize after EVERY mutating call and restore it
//     on launch — otherwise groups die on restart.
//   - We publish a batch of KeyPackages so peers can add us; each is consumed once.
//   - A conversation ⇄ group_id map lets us re-open (loadGroup) each group lazily.
//
//  Transport:
//   - App messages: encrypt ONCE, replicate the SAME ciphertext to every member
//     device over the existing 1:1 relay (POST /messages/send, content_type "group").
//   - Welcome/Commit control messages ride /mls/group-events (NOT /messages/send)
//     and are processed BEFORE app messages on every sync.
//
//  Limitations (this increment):
//   - Single committer: concurrent adds/removes from different members can conflict
//     (MLS epochs must advance in order). VOIID's create/add path commits locally.
//   - Multi-device-per-user for the SAME user in one group is not fully supported:
//     /mls/group-events delivers per recipient_user_id and marks delivered on first
//     fetch, so a second device of the same user may miss a commit. Test with one
//     device per user.
//   - Adding a member AFTER creation updates MLS + distributes Welcome/Commit, but
//     the server-side conversation membership (used to fan out app messages) needs a
//     backend "add member to conversation" endpoint that isn't in the current contract.
//
//  CROSS-PROCESS SINGLE WRITER (why every mutation goes through `withGroupState`):
//   The Notification Service Extension decrypts group messages for the notification
//   preview in a SEPARATE process, against the SAME keychain blob. `GroupMember.serialize`
//   / `.restore` is a WHOLE-STATE snapshot — one blob holding every group, the signature
//   key and every KeyPackage private — so a write-back derived from a stale read does not
//   merge, it REPLACES. Lose a Commit that way and the group is dead: `max_past_epochs`
//   is 0 and /mls/group-events is destructive-on-read, so the Commit can never be
//   re-fetched. Every mutating entry point therefore: takes the app-group flock, drops
//   ALL in-memory state (member, sessions, conversation→group map), re-reads the blob,
//   and only then mutates. `persistMember()` additionally refuses any write whose base
//   version is no longer current, so a future unlocked path fails loudly instead of
//   silently destroying the other process's epoch.
//

import Foundation
import Security
import Combine

@MainActor
final class GroupEngine {
    static let shared = GroupEngine()
    private let api = APIClient()
    private let kc = KeychainData(service: "com.voiid.mls")

    /// Fires with a `conversationId` whenever that group's MLS epoch advances — i.e.
    /// right after a membership commit is applied (`syncGroupEvents`) or merged locally
    /// (`addMember`/`removeMember`). The exporter secret, and therefore the derived call
    /// key, changes on every such commit, so a live call must re-derive and re-apply its
    /// media key when this fires. Only emitted when the derived key genuinely changed.
    let groupEpochChanged = PassthroughSubject<String, Never>()

    private let memberBlobName = "mls_member_blob"     // serialized GroupMember (all state)
    private let memberVersionName = "mls_member_blob_version"   // monotonic write counter
    private let convGroupsName = "mls_conv_groups"     // JSON { conversationId: base64(group_id) }

    /// This device's MLS identity (holds every group). nil until bootstrap/restore.
    private var member: GroupMember?
    /// Lazily-opened group sessions, keyed by conversationId.
    private var sessions: [String: GroupSession] = [:]
    /// conversationId → MLS group_id (persisted, so we can loadGroup after restart).
    private var convGroups: [String: Data] = [:]

    /// The blob version `member` was restored FROM. `persistMember` refuses to write when
    /// the stored version has moved on, because that means another process committed
    /// something our in-memory state never saw — and our serialize() would erase it.
    private var memberBlobVersion = 0

    /// While false, nothing may MINT a GroupMember. Set for the extension's inbound-only
    /// section: creating (or recreating after a failed restore) writes a group-less blob
    /// over the app's real MLS state, which loses every group irrecoverably. The app is
    /// the only process allowed to bootstrap an identity.
    private var memberCreationAllowed = true

    private var bootstrapped = false
    private static let keyPackageBatch = 10

    private init() { loadConvGroups() }

    // MARK: - Cross-process critical section

    /// Run `body` as the single writer of MLS state: hold the app-group flock, then drop
    /// and re-read every cached piece of shared state before touching it.
    ///
    /// The reload is not an optimisation, it is the correctness condition. Cached
    /// `sessions` are especially dangerous: a `GroupSession` wraps an `MlsGroup`
    /// materialised from a SPECIFIC `GroupMember`'s storage provider, but decrypt takes the
    /// member as a parameter — so reusing one across a re-restore writes an old group view
    /// into a new provider. They are dropped wholesale.
    ///
    /// NEVER nest these: `CrossProcessLock` is an flock on a fresh descriptor each time, so
    /// a second acquisition from inside the first deadlocks this process against itself.
    /// Public entry points take it exactly once and call `…Locked` bodies internally.
    private func withGroupState<T>(createMember: Bool = true,
                                   _ body: () async throws -> T) async rethrows -> T {
        try await CrossProcessLock.withLock {
            let previous = memberCreationAllowed
            memberCreationAllowed = createMember
            defer { memberCreationAllowed = previous }
            reloadSharedState()
            return try await body()
        }
    }

    /// Drop this process's caches and re-read the authoritative shared state. Called only
    /// from `withGroupState`, i.e. always with the cross-process lock held.
    private func reloadSharedState() {
        member = nil
        sessions.removeAll()          // bound to the OLD member's provider — never reuse
        loadConvGroups()              // the other process may have joined a new group
        // The decrypt-once ledger for group messages is ChatEngine's store; re-read it so
        // we neither re-decrypt what the other process already did nor persist over it.
        ChatEngine.shared.reloadStore()
        if let uid = TokenStore.shared.userId, let dev = E2EManager.shared.deviceId {
            restoreMember(userId: uid, deviceId: dev)
        }
    }

    // MARK: - Bootstrap / lifecycle

    /// Create-or-restore this device's GroupMember and publish a batch of KeyPackages.
    /// Idempotent per app session. Must run AFTER E2EManager registered the device
    /// (needs the device id); called from E2EManager.bootstrap().
    func bootstrap() async {
        guard TokenStore.shared.userId != nil,
              let deviceId = E2EManager.shared.deviceId else {
            NSLog("[VOIID] MLS bootstrap skipped (no user/device yet)")
            return
        }
        // `withGroupState` performs the create-or-restore (reloadSharedState → restoreMember);
        // minting KeyPackages mutates the member, so it must run under the same lock.
        await withGroupState {
            if bootstrapped { return }
            do {
                try await publishKeyPackages(deviceId: deviceId)
                bootstrapped = true
                NSLog("[VOIID] MLS bootstrap: keypackages published")
            } catch {
                NSLog("[VOIID] MLS bootstrap keypackage publish failed: \(error)")
            }
        }
    }

    /// Restore the persisted GroupMember, or create a fresh one (first run). A fresh
    /// member has NO groups — only acceptable when there was no prior blob. If restore
    /// of an existing blob fails we recreate (groups are unfortunately lost) rather
    /// than crash — but ONLY when `memberCreationAllowed`, so the extension degrades to a
    /// generic notification instead of nuking the app's MLS state on a transient failure.
    private func restoreMember(userId: String, deviceId: String) {
        if member != nil { return }
        let identity = Data("\(userId)::\(deviceId)".utf8)
        if let blob = kc.data(memberBlobName) {
            do {
                member = try GroupMember.restore(blob: blob)
                memberBlobVersion = storedBlobVersion()   // the version this state derives from
                return
            } catch {
                NSLog("[VOIID] MLS member restore failed: \(error)")
            }
        }
        guard memberCreationAllowed else {
            NSLog("[VOIID] MLS member unavailable and creation not permitted here — skipping")
            return
        }
        do {
            let m = try GroupMember.create(identity: identity)
            member = m
            memberBlobVersion = storedBlobVersion()
            persistMember()
            NSLog("[VOIID] MLS member created for \(userId)::\(deviceId)")
        } catch {
            NSLog("[VOIID] MLS member create FAILED: \(error)")
        }
    }

    /// Ensure the member is available (lazy restore) — used by paths that may run
    /// before bootstrap completed.
    @discardableResult
    private func ensureMember() -> GroupMember? {
        if member == nil, let uid = TokenStore.shared.userId, let dev = E2EManager.shared.deviceId {
            restoreMember(userId: uid, deviceId: dev)
        }
        return member
    }

    // MARK: - KeyPackage publishing

    private struct PublishKPBody: Encodable { let device_id: String; let key_packages: [String] }
    private struct PublishKPResponse: Decodable { let uploaded: Int? }

    /// Generate + publish a batch of this device's KeyPackages. Each `keyPackage()`
    /// call mints a fresh package whose private half is stored in the member blob, so
    /// we MUST persist the member after generating them (or a consumed KeyPackage's
    /// Welcome becomes un-joinable after restart).
    private func publishKeyPackages(deviceId: String) async throws {
        guard let m = ensureMember() else { return }
        var packages: [String] = []
        for _ in 0..<Self.keyPackageBatch {
            let kp = try m.keyPackage()
            packages.append(kp.base64EncodedString())
        }
        persistMember()   // privates now live in the blob — save BEFORE upload
        let _: PublishKPResponse = try await api.request(
            "POST", "mls/keypackages",
            body: PublishKPBody(device_id: deviceId, key_packages: packages))
    }

    // MARK: - Create group

    private struct KeyPackageDTO: Decodable { let device_id: String; let key_package: String }
    private struct KeyPackagesResponse: Decodable { let key_packages: [KeyPackageDTO] }

    /// One control message queued for /mls/group-events.
    private struct GroupEventOut: Encodable {
        let recipient_user_id: String
        let kind: String                 // "welcome" | "commit"
        let payload: String              // base64
        var ratchet_tree: String? = nil  // base64 (welcome only)
    }
    private struct GroupEventsBody: Encodable { let conversation_id: String; let events: [GroupEventOut] }
    private struct StoredResponse: Decodable { let stored: Int? }

    /// Build the real MLS group for a freshly-created server conversation: create the
    /// group, add every member's device (by their published KeyPackages), and
    /// distribute Welcome (to each new device's user) + Commit (to already-added
    /// members) over /mls/group-events. `memberUserIds` are the OTHER members (not us).
    func createGroup(conversationId: String, memberUserIds: [String]) async {
        await withGroupState { await createGroupLocked(conversationId: conversationId, memberUserIds: memberUserIds) }
    }

    private func createGroupLocked(conversationId: String, memberUserIds: [String]) async {
        guard let m = ensureMember() else {
            NSLog("[VOIID] MLS createGroup: no member"); return
        }
        do {
            let session = try m.createGroup()
            let gid = session.groupId()
            sessions[conversationId] = session
            convGroups[conversationId] = gid
            persistConvGroups()
            persistMember()

            // Users already added to the MLS group (for commit fan-out). Deduped by
            // user: a commit is user-broadcast, so every existing member device applies it.
            var existingUsers: Set<String> = []
            var events: [GroupEventOut] = []

            for userId in memberUserIds {
                let kps = try await fetchKeyPackages(userId: userId)
                for kp in kps {
                    guard let kpData = decodeB64(kp.key_package) else { continue }
                    let out = try session.addMember(member: m, theirKeyPackage: kpData)
                    persistMember()   // addMember merged a commit locally — save now
                    // Welcome → the NEW device's user (its device picks its own Welcome).
                    events.append(GroupEventOut(recipient_user_id: userId,
                                                kind: "welcome",
                                                payload: out.welcome.base64EncodedString(),
                                                ratchet_tree: out.ratchetTree.base64EncodedString()))
                    // Commit → every user already in the group (they must advance epoch).
                    for existing in existingUsers {
                        events.append(GroupEventOut(recipient_user_id: existing,
                                                    kind: "commit",
                                                    payload: out.commit.base64EncodedString()))
                    }
                }
                existingUsers.insert(userId)
            }
            try await distribute(conversationId: conversationId, events: events)
            NSLog("[VOIID] MLS group created conv=\(conversationId) members=\(session.memberCount())")
        } catch {
            NSLog("[VOIID] MLS createGroup FAILED conv=\(conversationId): \(error)")
        }
    }

    private func fetchKeyPackages(userId: String) async throws -> [KeyPackageDTO] {
        let env: KeyPackagesResponse = try await api.request("GET", "mls/keypackages/\(userId)")
        return env.key_packages
    }

    private func distribute(conversationId: String, events: [GroupEventOut]) async throws {
        guard !events.isEmpty else { return }
        let _: StoredResponse = try await api.request(
            "POST", "mls/group-events",
            body: GroupEventsBody(conversation_id: conversationId, events: events))
    }

    // MARK: - Send app message

    private struct DeviceCiphertext: Encodable { let recipient_device_id: String; let ciphertext: String }
    private struct SendBundleBody: Encodable {
        let conversation_id: String
        var sender_device_id: String? = nil
        let messages: [DeviceCiphertext]
        var content_type: String? = nil
    }
    private struct SendResponse: Decodable { let message_id: String; var created_at: String? = nil }

    /// Encrypt `text` ONCE with the group session and fan the SAME ciphertext out to
    /// every member device (all conversation members' devices + our other devices,
    /// excluding this sending device). Appends a local echo so the UI renders it.
    func sendGroupMessage(conversationId: String, text: String) async {
        await withGroupState { await sendGroupMessageLocked(conversationId: conversationId, text: text) }
    }

    private func sendGroupMessageLocked(conversationId: String, text: String) async {
        guard let m = ensureMember() else { NSLog("[VOIID] MLS send: no member"); return }
        do {
            let session = try loadSession(conversationId)
            let ct = try session.encrypt(member: m, plaintext: Data(text.utf8))
            persistMember()   // encrypt advanced the sender ratchet — save

            let ctB64 = ct.base64EncodedString()
            let targets = try await resolveTargets(conversationId: conversationId)
            guard !targets.isEmpty else {
                NSLog("[VOIID] MLS send: no target devices conv=\(conversationId)"); return
            }
            let messages = targets.map { DeviceCiphertext(recipient_device_id: $0.deviceId, ciphertext: ctB64) }
            let res: SendResponse = try await api.request(
                "POST", "messages/send",
                body: SendBundleBody(conversation_id: conversationId,
                                     sender_device_id: E2EManager.shared.deviceId,
                                     messages: messages, content_type: "group"))
            // Local echo (we can't decrypt our own MLS output) — use the server id so it
            // dedups against the inbound copy and never double-renders.
            // A location envelope rides the MLS text plaintext; decode it back so the
            // sender sees the pin/live bubble immediately (docs/LOCATION.md §4).
            let loc = LocationWire.decode(text)
            let echo = DecryptedMessage(id: res.message_id,
                                        senderId: TokenStore.shared.userId ?? "me",
                                        text: loc?.text ?? text,
                                        createdAt: res.created_at.map(parseDate) ?? Date(),
                                        isMine: true, locationJSON: loc?.json, deliveryStatus: "sent")
            ChatEngine.shared.ingestGroupMessage(echo, conversationId: conversationId)
            NSLog("[VOIID] MLS sent id=\(res.message_id) conv=\(conversationId) devices=\(messages.count)")
        } catch {
            NSLog("[VOIID] MLS send FAILED conv=\(conversationId): \(error)")
        }
    }

    // MARK: - Sync (control events THEN app messages)

    private struct GroupEventIn: Decodable {
        let id: String
        let conversation_id: String
        let sender_user_id: String?
        let kind: String
        let payload: String
        var ratchet_tree: String?
        var created_at: String?
    }
    private struct GroupEventsInResponse: Decodable { let events: [GroupEventIn] }

    /// Fetch + process this device's undelivered Welcome/Commit events. A Welcome joins
    /// a new group; a Commit advances an existing one. Failures are logged + skipped so
    /// one bad event never kills the loop. Call BEFORE decrypting app messages.
    /// NEVER call this from the Notification Service Extension: GET /mls/group-events sets
    /// `delivered_at` on every one of the caller's undelivered rows on the FIRST fetch, so
    /// an extension killed by the ~30s watchdog before `persistMember()` loses those
    /// Welcome/Commit messages forever and the group becomes permanently undecryptable.
    func syncGroupEvents() async {
        await withGroupState { await syncGroupEventsLocked() }
    }

    private func syncGroupEventsLocked() async {
        guard let m = ensureMember() else { return }
        let events: [GroupEventIn]
        do {
            let env: GroupEventsInResponse = try await api.request("GET", "mls/group-events")
            events = env.events
        } catch {
            NSLog("[VOIID] MLS group-events fetch failed: \(error)")
            return
        }
        for e in events {
            switch e.kind {
            case "welcome":
                // Already a member of this conversation's group? Skip (a Welcome for a
                // different device / a replay would fail joinGroup anyway).
                if convGroups[e.conversation_id] != nil { continue }
                guard let welcome = decodeB64(e.payload),
                      let tree = e.ratchet_tree.flatMap(decodeB64) else { continue }
                do {
                    let session = try m.joinGroup(welcome: welcome, ratchetTree: tree)
                    let gid = session.groupId()
                    sessions[e.conversation_id] = session
                    convGroups[e.conversation_id] = gid
                    persistConvGroups()
                    persistMember()
                    NSLog("[VOIID] MLS joined group conv=\(e.conversation_id)")
                } catch {
                    NSLog("[VOIID] MLS joinGroup skipped conv=\(e.conversation_id): \(error)")
                }
            case "commit":
                guard let commit = decodeB64(e.payload) else { continue }
                do {
                    let session = try loadSession(e.conversation_id)
                    let keyBefore = callKeyPassphraseIfAvailable(e.conversation_id)
                    _ = try session.decrypt(member: m, message: commit)   // applies (returns nil)
                    persistMember()
                    // Epoch advanced → the call key rotated. Signal any live call so it can
                    // re-derive and re-apply, else members desync after this membership change.
                    emitEpochChangeIfKeyRotated(e.conversation_id, previous: keyBefore)
                    NSLog("[VOIID] MLS applied commit conv=\(e.conversation_id)")
                } catch {
                    NSLog("[VOIID] MLS commit apply skipped conv=\(e.conversation_id): \(error)")
                }
            default:
                break
            }
        }
    }

    // MARK: - Receive app messages

    private struct MessageDTO: Decodable {
        let id: String
        let sender_id: String
        let ciphertext: String?
        let created_at: String
        var sender_device_id: String? = nil
        var content_type: String? = nil
    }
    private struct MessagesResponse: Decodable { let messages: [MessageDTO] }

    /// Fetch this device's copy of the group's app messages, decrypt-once every unseen
    /// one, and append the plaintext into the shared ChatEngine store (so the chat UI
    /// renders it). Our OWN messages + already-seen ids are skipped; a commit that
    /// somehow rides this path decrypts to nil and is ignored. A failed decrypt is
    /// tombstoned — it never kills the sync.
    func syncGroupMessages(conversationId: String) async {
        await withGroupState { await decryptInboundLocked(conversationId: conversationId,
                                                          tombstoneFailures: true) }
    }

    // MARK: - Notification Service Extension entry point

    /// Decrypt this group's unseen inbound messages IN THE EXTENSION and return the one the
    /// push is about, or nil to fall back to the generic placeholder.
    ///
    /// STRICTLY INBOUND-ONLY. It runs the same locked decrypt-once path as the app, so a
    /// message decrypted here is marked seen in the shared store and the app will not
    /// re-decrypt it (double-decrypting one MLS generation is a hard SecretReuseError —
    /// the key is taken out of `past_secrets`). It deliberately does NOT call
    /// `syncGroupEvents()`: that endpoint is destructive-on-read and losing a Commit to the
    /// extension's watchdog would kill the group. A message from an epoch whose Commit we
    /// haven't applied simply fails to decrypt BEFORE any storage write, so it degrades to
    /// the placeholder and the app decrypts it properly later.
    func notificationDecrypt(conversationId: String, messageId: String) async -> DecryptedMessage? {
        await withGroupState(createMember: false) { () async -> DecryptedMessage? in
            // Not a group we hold MLS state for (a Welcome we haven't processed yet) —
            // there is nothing to decrypt with and the extension must not go looking.
            guard hasGroup(conversationId: conversationId) else { return nil }
            // No tombstones from here: the extension skips MLS control events by design, so
            // "I don't have this epoch's Commit yet" is a NORMAL outcome for it. Writing a
            // "couldn't be decrypted" row for that would put a scary placeholder in the chat
            // for a message the app decrypts correctly moments later.
            await decryptInboundLocked(conversationId: conversationId, tombstoneFailures: false)
            return ChatEngine.shared.storedMessage(id: messageId, conversationId: conversationId)
        }
    }

    /// Body of the receive path. Assumes the cross-process lock is held and shared state
    /// was reloaded (`withGroupState`) — it advances per-sender ratchets and writes the
    /// member blob, so it must never run unlocked.
    private func decryptInboundLocked(conversationId: String, tombstoneFailures: Bool) async {
        guard let m = ensureMember() else { return }
        let session: GroupSession
        do { session = try loadSession(conversationId) }
        catch { NSLog("[VOIID] MLS syncMessages: no session conv=\(conversationId): \(error)"); return }

        let myId = TokenStore.shared.userId
        let devParam = E2EManager.shared.deviceId.map { "?device_id=\($0)" } ?? ""
        let env: MessagesResponse
        do { env = try await api.request("GET", "messages/conversation/\(conversationId)\(devParam)") }
        catch { NSLog("[VOIID] MLS syncMessages fetch failed conv=\(conversationId): \(error)"); return }

        let seen = ChatEngine.shared.storedMessageIds(conversationId: conversationId)
        for msg in env.messages.reversed() {   // server DESC → process ASC
            if msg.sender_id == myId { continue }              // our own echo already stored
            if seen.contains(msg.id) { continue }              // decrypt-once
            guard let ciphertext = msg.ciphertext, let ct = decodeB64(ciphertext) else { continue }
            do {
                guard let plain = try session.decrypt(member: m, message: ct) else {
                    persistMember(); continue   // a commit/proposal — applied, no plaintext
                }
                persistMember()   // FIRST thing after a successful decrypt: the sender
                                  // ratchet advanced in memory and is lost otherwise
                let text = String(decoding: plain, as: UTF8.self)
                // Location control (live_start/stop/rekey) carried over MLS: LocationWire
                // captures its key + strips it, and renders a clean bubble instead of raw JSON.
                let loc = LocationWire.decode(text)
                let decrypted = DecryptedMessage(id: msg.id, senderId: msg.sender_id,
                                                 text: loc?.text ?? text,
                                                 createdAt: parseDate(msg.created_at),
                                                 isMine: false, locationJSON: loc?.json)
                ChatEngine.shared.ingestGroupMessage(decrypted, conversationId: conversationId)
            } catch {
                NSLog("[VOIID] MLS decrypt FAILED id=\(msg.id) conv=\(conversationId): \(error)")
                // TOMBSTONE rather than skip: previously a failed id was never recorded, so
                // the message left no trace at all and the chat just had a silent hole where
                // someone had spoken. The record is retryable by design (see
                // `ChatEngine.storedMessageIds`) — it upgrades to the real text if a later
                // Commit makes the message decryptable, and otherwise stays a visible
                // "couldn't be decrypted" placeholder instead of nothing.
                guard tombstoneFailures else { continue }
                ChatEngine.shared.ingestGroupMessage(
                    DecryptedMessage(id: msg.id, senderId: msg.sender_id,
                                     text: "🔒 Message couldn’t be decrypted",
                                     createdAt: parseDate(msg.created_at), isMine: false,
                                     failed: true),
                    conversationId: conversationId)
            }
        }
    }

    // MARK: - Add / remove members (admin)

    /// Add a user's device(s) to an existing group: consume their KeyPackages, add each
    /// via MLS, and distribute Welcome (to them) + Commit (to existing members).
    func addMember(conversationId: String, userId: String, existingMemberUserIds: [String]) async {
        await withGroupState {
            await addMemberLocked(conversationId: conversationId, userId: userId,
                                  existingMemberUserIds: existingMemberUserIds)
        }
    }

    private func addMemberLocked(conversationId: String, userId: String,
                                 existingMemberUserIds: [String]) async {
        guard let m = ensureMember() else { return }
        do {
            let session = try loadSession(conversationId)
            let keyBefore = callKeyPassphraseIfAvailable(conversationId)
            let kps = try await fetchKeyPackages(userId: userId)
            var events: [GroupEventOut] = []
            let existing = Set(existingMemberUserIds).subtracting([userId])
            for kp in kps {
                guard let kpData = decodeB64(kp.key_package) else { continue }
                let out = try session.addMember(member: m, theirKeyPackage: kpData)
                persistMember()
                events.append(GroupEventOut(recipient_user_id: userId, kind: "welcome",
                                            payload: out.welcome.base64EncodedString(),
                                            ratchet_tree: out.ratchetTree.base64EncodedString()))
                for e in existing {
                    events.append(GroupEventOut(recipient_user_id: e, kind: "commit",
                                                payload: out.commit.base64EncodedString()))
                }
            }
            // Adding a member merged a commit locally → advance our own live call's key.
            emitEpochChangeIfKeyRotated(conversationId, previous: keyBefore)
            try await distribute(conversationId: conversationId, events: events)
            NSLog("[VOIID] MLS added user=\(userId) conv=\(conversationId)")
        } catch {
            NSLog("[VOIID] MLS addMember FAILED conv=\(conversationId): \(error)")
        }
    }

    /// Remove a user from the group: produce a removal commit per device identity and
    /// broadcast it to the remaining members (MLS rekeys so the removed member can't
    /// read later messages).
    func removeMember(conversationId: String, userId: String, remainingMemberUserIds: [String]) async {
        await withGroupState {
            await removeMemberLocked(conversationId: conversationId, userId: userId,
                                     remainingMemberUserIds: remainingMemberUserIds)
        }
    }

    private func removeMemberLocked(conversationId: String, userId: String,
                                    remainingMemberUserIds: [String]) async {
        guard let m = ensureMember() else { return }
        do {
            let session = try loadSession(conversationId)
            let keyBefore = callKeyPassphraseIfAvailable(conversationId)
            let deviceIds = try await deviceIds(of: userId)
            var events: [GroupEventOut] = []
            let remaining = Set(remainingMemberUserIds).subtracting([userId])
            for deviceId in deviceIds {
                let identity = Data("\(userId)::\(deviceId)".utf8)
                let commit = try session.removeMember(member: m, identity: identity)
                persistMember()
                for r in remaining {
                    events.append(GroupEventOut(recipient_user_id: r, kind: "commit",
                                                payload: commit.base64EncodedString()))
                }
            }
            // Removing a member merged a commit locally → advance our own live call's key.
            emitEpochChangeIfKeyRotated(conversationId, previous: keyBefore)
            try await distribute(conversationId: conversationId, events: events)
            NSLog("[VOIID] MLS removed user=\(userId) conv=\(conversationId)")
        } catch {
            NSLog("[VOIID] MLS removeMember FAILED conv=\(conversationId): \(error)")
        }
    }

    /// Current member count of a group, from our local MLS view (0 if not joined).
    func memberCount(conversationId: String) -> Int {
        guard let session = try? loadSession(conversationId) else { return 0 }
        return Int(session.memberCount())
    }

    // MARK: - Device / member resolution (fan-out targets)

    private struct TargetDevice { let userId: String; let deviceId: String }
    private struct DeviceDTO: Decodable { let id: String }
    private struct DevicesResponse: Decodable { let devices: [DeviceDTO] }
    private struct ConvMemberDTO: Decodable { let user_id: String }
    private struct ConvDetailResponse: Decodable { let members: [ConvMemberDTO] }

    /// Every device we must deliver an app message to: all conversation members' devices
    /// + our own OTHER devices, minus this sending device.
    private func resolveTargets(conversationId: String) async throws -> [TargetDevice] {
        let detail: ConvDetailResponse = try await api.request("GET", "conversations/\(conversationId)")
        let myId = TokenStore.shared.userId
        let myDev = E2EManager.shared.deviceId
        var targets: [TargetDevice] = []
        for member in detail.members {
            let devs = (try? await deviceIds(of: member.user_id)) ?? []
            for d in devs where !(member.user_id == myId && d == myDev) {
                targets.append(TargetDevice(userId: member.user_id, deviceId: d))
            }
        }
        return targets
    }

    private func deviceIds(of userId: String) async throws -> [String] {
        let env: DevicesResponse = try await api.request("GET", "devices/\(userId)")
        return env.devices.map { $0.id }
    }

    // MARK: - Session (re)opening

    /// Return the cached session for a conversation, or re-open it via loadGroup using
    /// the persisted group_id.
    private func loadSession(_ conversationId: String) throws -> GroupSession {
        if let s = sessions[conversationId] { return s }
        guard let m = ensureMember() else { throw APIError.notAuthenticated }
        guard let gid = convGroups[conversationId] else {
            throw APIError.http(status: 404, message: "no MLS group for conversation")
        }
        let s = try m.loadGroup(groupId: gid)
        sessions[conversationId] = s
        return s
    }

    /// True once we hold (or can re-open) an MLS group for this conversation.
    func hasGroup(conversationId: String) -> Bool { convGroups[conversationId] != nil }

    // MARK: - Call keys (group calling / SFU media encryption)

    /// Derive this conversation's SRTP call keys from the MLS group's exporter secret.
    ///
    /// Every member holding the same group state derives the same keys, and because the
    /// exporter secret changes on every membership commit, the keys rotate automatically
    /// when someone is added or removed. Nothing here is ever sent to the API or the SFU.
    ///
    /// Throws if the member isn't restored yet, or we hold no MLS group for the conversation.
    func callKeys(conversationId: String) throws -> SrtpKeys {
        guard let m = ensureMember() else { throw APIError.notAuthenticated }
        return try loadSession(conversationId).callKeys(member: m)
    }

    /// The MLS-derived call key encoded as a string, for LiveKit's shared-key E2EE provider.
    ///
    /// LiveKit's `BaseKeyProvider` takes a `String` and force-unwraps `.data(using: .utf8)`,
    /// so raw MLS key bytes cannot be handed over directly — they are not valid UTF-8 and
    /// the force-unwrap would crash. We therefore base64-encode `masterKey || masterSalt`.
    /// The encoding is deterministic, so every member still arrives at byte-identical key
    /// material, and LiveKit runs its own PBKDF2 over it to derive the frame-encryption key.
    ///
    /// Both halves are included so the salt contributes entropy rather than being discarded.
    func callKeyPassphrase(conversationId: String) throws -> String {
        let keys = try callKeys(conversationId: conversationId)
        return (keys.masterKey + keys.masterSalt).base64EncodedString()
    }

    /// Snapshot the current derived call-key passphrase for a conversation, or nil if we
    /// can't derive one (no group / not restored). Used to decide whether a just-applied
    /// commit actually rotated the media key before signalling a live call.
    private func callKeyPassphraseIfAvailable(_ conversationId: String) -> String? {
        try? callKeyPassphrase(conversationId: conversationId)
    }

    /// Emit `groupEpochChanged` for a conversation only if the derived call key changed
    /// between `previous` and now. Cheap, never throws — a nil/derive failure is treated
    /// as "no confirmed change" and stays silent rather than churning a live call.
    private func emitEpochChangeIfKeyRotated(_ conversationId: String, previous: String?) {
        let current = callKeyPassphraseIfAvailable(conversationId)
        guard let current, current != previous else { return }
        groupEpochChanged.send(conversationId)
    }

    // MARK: - Persistence

    /// Snapshot the whole MLS state back to the shared keychain.
    ///
    /// GUARDED WRITE: `serialize()` is a full-state replace, so writing a snapshot taken
    /// from an older base version would delete whatever the other process committed in
    /// between — and an erased epoch is unrecoverable (max_past_epochs = 0, and
    /// /mls/group-events marks events delivered on first read, so the Commit cannot be
    /// re-fetched). Under `withGroupState` the versions always match; a mismatch means a
    /// mutation path was added that skipped the lock/reload, and refusing the write turns
    /// permanent group death into a recoverable "this message didn't stick".
    ///
    /// (An MLS epoch counter would be a stronger check than a local write counter, but
    /// `GroupSession::epoch()` exists only in the Rust core and is not on the uniffi
    /// surface — see the note in packages/e2e-core/src/group.rs.)
    private func persistMember() {
        guard let m = member, let blob = try? m.serialize() else { return }
        let current = storedBlobVersion()
        guard current == memberBlobVersion else {
            NSLog("[VOIID] ⛔️ MLS persist REFUSED: blob moved \(memberBlobVersion)→\(current) under us — dropping this write to avoid destroying the other process's epoch")
            return
        }
        kc.setData(blob, memberBlobName)          // data first: a crash before the counter
        memberBlobVersion = current + 1           // write only costs us a missed detection
        kc.set(String(memberBlobVersion), memberVersionName)
    }

    /// The version counter of the blob currently in the keychain (0 when never written).
    private func storedBlobVersion() -> Int {
        Int(kc.string(memberVersionName) ?? "") ?? 0
    }

    private func loadConvGroups() {
        guard let s = kc.string(convGroupsName),
              let data = s.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        var out: [String: Data] = [:]
        for (k, v) in map { if let d = decodeB64(v) { out[k] = d } }
        convGroups = out
    }

    private func persistConvGroups() {
        let map = convGroups.mapValues { $0.base64EncodedString() }
        guard let data = try? JSONEncoder().encode(map),
              let s = String(data: data, encoding: .utf8) else { return }
        kc.set(s, convGroupsName)
    }

    /// Forget all MLS state (fresh-install wipe, mirrors E2EManager).
    func wipe() {
        kc.wipeService()
        member = nil
        sessions.removeAll()
        convGroups.removeAll()
        memberBlobVersion = 0        // the counter lived in the wiped service too
        bootstrapped = false
    }

    // MARK: - Helpers

    /// Lenient base64 decode (peers/backend may emit unpadded standard base64).
    private func decodeB64(_ s: String) -> Data? {
        let rem = s.count % 4
        let padded = rem == 0 ? s : s + String(repeating: "=", count: 4 - rem)
        return Data(base64Encoded: s)
            ?? Data(base64Encoded: padded)
            ?? Data(base64Encoded: padded, options: .ignoreUnknownCharacters)
    }

    private func parseDate(_ s: String) -> Date { ISO8601DateFormatter().date(from: s) ?? Date() }
}
