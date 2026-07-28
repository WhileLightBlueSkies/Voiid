//
//  Stores.swift
//  Voiid
//
//  Local, in-memory app state (NO network, NO crypto — dummy experience build).
//  Everything is interactive: sending a message appends it, marks it sent→delivered→read
//  on timers, and simulates a reply, so the app *feels* real end-to-end on a device.
//

import SwiftUI
import Combine

// MARK: - Session / onboarding

@MainActor
final class AppSession: ObservableObject {
    enum Route { case onboarding, main }
    @Published var route: Route
    // Empty until the REAL profile loads (loadLocalProfile → refreshServerProfile). Never a
    // dummy "You / +91 …" placeholder that could flash on screen before the real data arrives.
    @Published var profile = VUser(id: "me", fullName: "", phoneNumber: "")
    /// Hides the bottom tab bar when a full-screen child (e.g. a chat) is open.
    @Published var hideTabBar = false
    /// The MEASURED height of the custom bottom tab bar, including its home-indicator
    /// padding — published by RootTabView, which is the only view that knows it.
    ///
    /// The bar is NOT a TabView bar: RootTabView draws it as a ZStack sibling painted
    /// OVER the active page, so it contributes nothing to any page's safe area. A page
    /// that anchors its own chrome to the bottom therefore lands UNDERNEATH the bar
    /// unless it insets by this value. `0` whenever the bar is hidden, so a full-screen
    /// child inherits no phantom gap.
    @Published var tabBarHeight: CGFloat = 0

    private let auth = AuthService.shared

    /// Where the local copy of your own profile lives. Small and flat, so UserDefaults
    /// is the right tool — it is read during launch, before the database is touched,
    /// and it must never be the reason a launch blocks.
    private static let profileKey = "voiid.me.profile.v1"
    /// The VERIFIED E.164 phone from the OTP flow. The server never stores the phone, so
    /// this UserDefaults key is the only source of the user's REAL number.
    static let verifiedPhoneKey = "voiid.me.phone.e164"

    /// Called from the OTP screen on a successful verification. The one place the real
    /// number is known.
    static func saveVerifiedPhone(_ e164: String) {
        UserDefaults.standard.set(e164, forKey: verifiedPhoneKey)
    }

    init() {
        // Resume straight to the app if we already hold a valid session token.
        route = AuthService.shared.isAuthenticated ? .main : .onboarding
        loadLocalProfile()
        // Show the REAL verified number, never DummyData's placeholder. Prefer the value
        // captured at OTP time; fall back to Firebase's persisted signed-in user (covers
        // accounts that logged in BEFORE we saved it) and persist that for next launch.
        // Empty (→ "—" in Settings) only if truly unknown, but NEVER a fake number.
        if let saved = UserDefaults.standard.string(forKey: Self.verifiedPhoneKey), !saved.isEmpty {
            profile.phoneNumber = saved
        } else if let fromFirebase = FirebasePhoneAuth.currentPhoneNumber {
            profile.phoneNumber = fromFirebase
            Self.saveVerifiedPhone(fromFirebase)
        } else {
            profile.phoneNumber = ""
        }
        // On relaunch of an already-authenticated session, pull the authoritative profile
        // from the server so a reinstall / new device shows the REAL name, photo, bio and
        // username — not a stale local copy or a placeholder.
        if AuthService.shared.isAuthenticated {
            Task { await refreshServerProfile() }
        }
    }

    /// Fetch this account's real profile from the server and merge it into `profile`.
    ///
    /// Call after login and on launch. `GET /users/:id` is the source of truth for
    /// full_name / photo_url / bio / username; the phone number is NOT server-held (it
    /// comes from the OTP flow), so it is preserved from local state. Every field is
    /// applied only when the server actually returned it, so this never blanks a value.
    func refreshServerProfile() async {
        guard let id = auth.userId else { return }
        guard let p = try? await ChatService.shared.userProfile(userId: id) else { return }
        if let n = p.name, !n.isEmpty { profile.fullName = n }
        if let url = p.photoURL, !url.isEmpty { profile.photoURL = url }
        if let bio = p.about, !bio.isEmpty { profile.bio = bio }
        if let u = p.username, !u.isEmpty { profile.username = u }
        // The server returns the phone number ONLY for our own profile — the authoritative,
        // Firebase-independent source. Use it if we don't already have one (e.g. an account
        // that logged in before we captured it at OTP), and persist it for offline launches.
        if profile.phoneNumber.isEmpty, let phone = p.phoneNumber, !phone.isEmpty {
            profile.phoneNumber = phone
            Self.saveVerifiedPhone(phone)
        }
        persistLocalProfile()
    }

    // MARK: - Own profile
    //
    // This was hardcoded to `DummyData.me` — every screen that showed "your" name or
    // photo was showing a placeholder, and there was nowhere to put a real one. It is
    // now persisted locally and synced, like everything else.

    private struct StoredProfile: Codable {
        var fullName: String
        var phoneNumber: String
        var photoURL: String?
        var email: String?
        var bio: String?
        var username: String?
    }

    private func loadLocalProfile() {
        guard let data = UserDefaults.standard.data(forKey: Self.profileKey),
              let stored = try? JSONDecoder().decode(StoredProfile.self, from: data)
        else { return }
        profile = VUser(id: auth.userId ?? "me",
                        fullName: stored.fullName,
                        phoneNumber: stored.phoneNumber,
                        email: stored.email,
                        photoName: nil,
                        photoURL: stored.photoURL,
                        username: stored.username,
                        bio: stored.bio)
    }

    private func persistLocalProfile() {
        let stored = StoredProfile(fullName: profile.fullName,
                                   phoneNumber: profile.phoneNumber,
                                   photoURL: profile.photoURL,
                                   email: profile.email,
                                   bio: profile.bio,
                                   username: profile.username)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
    }

    /// Update your profile locally and immediately. Callers sync to the server
    /// separately; a failed sync must not undo what the user sees.
    func updateProfile(fullName: String? = nil, photoURL: String? = nil,
                       phoneNumber: String? = nil, email: String? = nil,
                       bio: String? = nil, username: String? = nil) {
        if let fullName { profile.fullName = fullName }
        if let photoURL { profile.photoURL = photoURL }
        if let phoneNumber { profile.phoneNumber = phoneNumber }
        if let email { profile.email = email }
        if let bio { profile.bio = bio }
        if let username { profile.username = username }
        persistLocalProfile()
    }

    /// The authenticated user's id (our backend id), once logged in.
    var userId: String? { auth.userId }

    /// Called at the end of onboarding once a real session token exists
    /// (onboarding logs in via AuthService before calling this).
    func completeOnboarding() {
        withAnimation(.easeInOut) { route = .main }
    }

    /// Clears the auth token and this account's own profile.
    ///
    /// It does NOT wipe the local database, the plaintext message blob, the E2E keychain
    /// or the registered VoIP token — that is `SessionTeardown.wipeLocalAccountState()`,
    /// which the Log Out row runs immediately BEFORE calling this (before, because the
    /// teardown's VoIP unregister still needs the JWT). Call them in that order or the
    /// previous account's data survives on the device.
    func signOut() {
        auth.logout()
        // Your profile is per-account state; leaving it behind would show the previous
        // user's name and photo on the next login.
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        UserDefaults.standard.removeObject(forKey: Self.verifiedPhoneKey)
        profile = VUser(id: "me", fullName: "", phoneNumber: "")
        // In-memory stores outlive the session (they are @StateObjects on ContentView),
        // so they have to be told.
        NotificationCenter.default.post(name: .voiidDidSignOut, object: nil)
        withAnimation(.easeInOut) { route = .onboarding }
    }
}

/// Posted by `AppSession.signOut()`. Anything holding per-account state in memory
/// observes this and drops it.
extension Notification.Name {
    static let voiidDidSignOut = Notification.Name("voiidDidSignOut")
}

// MARK: - Chat store (the heart of the "feels real" experience)

@MainActor
final class ChatStore: ObservableObject {
    // REAL backend data — starts empty, loaded via `loadConversations()`. A new
    // account shows an empty list, which confirms we're reading the live server
    // (not mock). Message content is still E2EE/not-yet-decrypted (placeholder).
    @Published var directConversations: [VConversation] = []
    @Published var groupConversations: [VConversation] = []
    @Published var messagesByConversation: [String: [VMessage]] = [:]
    /// Finished calls per conversation, as transcript bubbles. Kept SEPARATE from the message
    /// map and merged on read: a call log is not a message, is never sent over the wire, and
    /// must not be persisted into the message store, previewed, or counted as unread.
    @Published var callLogsByConversation: [String: [VMessage]] = [:]
    @Published var typingConversations: Set<String> = []
    @Published var loadError: String?

    init() {
        // Sign-out has to empty this store. It is a @StateObject on ContentView, so it
        // survives the route change back to onboarding, and `loadConversations()` is
        // local-first — a stale array would render the PREVIOUS user's chat grid to the
        // next account before the network could correct it.
        NotificationCenter.default.addObserver(forName: .voiidDidSignOut,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.reset() }
        }
    }

    /// Drop every trace of the signed-out account held in memory.
    func reset() {
        directConversations = []
        groupConversations = []
        messagesByConversation = [:]
        typingConversations = []
        loadError = nil
    }

    /// Load conversations LOCAL-FIRST, then reconcile with the server.
    ///
    /// Order matters. Previously this was network-only, so a failed GET left the
    /// arrays empty and the user saw a blank chat grid even though their entire
    /// message history was on disk — the messages were unreachable because nothing
    /// knew which conversations existed. Now the database answers first and the
    /// network merely updates it: offline, you see your chats.
    func loadConversations() async {
        startRealtime()

        // One-time lift of the legacy app-group JSON blob into SQLite.
        LocalStore.importLegacyMessageBlobIfNeeded()

        // Render from disk before touching the network.
        applyLocalConversations()

        do {
            let convs = try await ChatService.shared.fetchConversations()
            LocalStore.saveConversations(convs)
            // Learn the peer names/photos this payload carried, so calls and headers
            // can resolve a name without a further round trip. Bulk, not per-row: the
            // single-row upsert reloads the whole table and republishes each time.
            UserDirectory.shared.upsertManyFromServer(
                convs.compactMap { c in
                    guard c.type == .direct, let peer = c.peerUserId else { return nil }
                    return (userId: peer, fullName: c.title, username: nil, photoURL: c.photoURL)
                }
            )
            applyLocalConversations()
            loadError = nil
        } catch {
            // Only surface the failure if we have nothing to show. With cached
            // conversations on screen, a dropped connection is not worth an error
            // banner — the list is simply as fresh as the last successful sync.
            if directConversations.isEmpty && groupConversations.isEmpty {
                loadError = (error as? APIError)?.errorDescription ?? "Couldn’t load chats."
            } else {
                loadError = nil
            }
        }
    }

    /// Publish whatever the local database currently holds.
    ///
    /// Previews are filled in from the local message store rather than being read from
    /// the conversations table: the offline list would otherwise render with no preview
    /// text at all, making a cold launch look emptier than it actually is even though
    /// every message is right there on disk.
    private func applyLocalConversations() {
        // Render the list STRAIGHT from SQLite: rows + denormalized last-message preview +
        // ordering, all from the conversations table. This touches NO message store — no whole
        // JSON decode, no per-conversation message load, no sorting — so the list paints
        // instantly and offline regardless of how much history exists. Each chat's full
        // message array is decoded lazily by openConversation(...) when it's actually opened
        // (WhatsApp-style). Previews stay fresh via bumpPreview at message-write time.
        let convs = LocalStore.conversations()
        guard !convs.isEmpty else { return }
        directConversations = convs.filter { $0.type == .direct }
        groupConversations = convs.filter { $0.type == .group }
        backfillPreviewsIfNeeded()
    }

    /// One-time backfill of last-message previews for chats that existed BEFORE previews were
    /// denormalized (the column is new). Runs OFF the launch-critical path (a low-priority
    /// task, after the list is already on screen) and only once — new activity keeps previews
    /// fresh from then on. No-op for fresh installs (nothing to backfill).
    private func backfillPreviewsIfNeeded() {
        let flag = "voiid.previews.backfilled.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let ids = (directConversations + groupConversations).map { $0.id }
        Task(priority: .utility) {
            for id in ids {
                guard let last = ChatEngine.shared.messages(conversationId: id).last else { continue }
                let preview = !last.text.isEmpty ? last.text
                    : (last.media.map { $0.mime.hasPrefix("audio/") ? "Voice message" : "Photo" } ?? "")
                if !preview.isEmpty {
                    LocalStore.updatePreview(conversationId: id, preview: preview, at: last.createdAt)
                }
            }
            UserDefaults.standard.set(true, forKey: flag)
            applyLocalConversations()   // re-render with the freshly backfilled previews
        }
    }

    /// The transcript: real messages with this conversation's call bubbles merged in by time.
    ///
    /// Merging HERE rather than inserting into the message list keeps call logs out of the
    /// message store, the chat-list preview and the unread count, while every existing caller
    /// picks them up for free. No dummy seeding — a chat with nothing decrypted shows empty.
    func messages(for id: String) -> [VMessage] {
        let msgs = messagesByConversation[id] ?? []
        let calls = callLogsByConversation[id] ?? []
        if calls.isEmpty { return msgs }
        return (msgs + calls).sorted { $0.createdAt < $1.createdAt }
    }

    /// Load this conversation's call history into the transcript. Call on chat open, and again
    /// whenever a call ends so a call placed from this chat leaves its bubble immediately.
    func loadCallLogs(_ conversationId: String) {
        callLogsByConversation[conversationId] = LocalStore.callsForConversation(conversationId).map { r in
            let incoming = r.direction == "incoming"
            return VMessage(
                id: "call:\(r.id)",
                conversationId: conversationId,
                senderId: incoming ? (directConversations.first { $0.id == conversationId }?.peerUserId ?? "") : "me",
                kind: .call,
                text: "",
                createdAt: r.startedAt,
                isMine: !incoming,
                call: VCallLog(callId: r.id,
                               isVideo: r.kind == "video",
                               incoming: incoming,
                               outcome: r.outcome,
                               startedAt: r.startedAt,
                               endedAt: r.endedAt)
            )
        }
    }

    /// Start (or reopen) a 1:1 chat with a discovered contact. Creates the
    /// conversation server-side (idempotent), inserts it locally, and returns it
    /// so the caller can navigate into ChatDetail.
    func startDirectChat(with contact: VContact) async -> VConversation? {
        do {
            let convId = try await ChatService.shared.createDirect(memberId: contact.userId)
            if let existing = directConversations.first(where: { $0.id == convId }) {
                return existing
            }
            let conv = VConversation(id: convId, type: .direct, title: contact.displayName,
                                     photoName: nil, lastMessagePreview: nil, lastMessageAt: nil,
                                     unreadCount: 0, peerUserId: contact.userId, photoURL: contact.photoURL)
            // Persist before returning: a chat started here must still exist after a
            // restart even if no message is ever sent in it.
            LocalStore.upsertConversation(conv)
            directConversations.insert(conv, at: 0)
            return conv
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t start chat."
            return nil
        }
    }

    /// Create a group conversation with `name` and the chosen contacts, insert it
    /// locally, and return it so the caller can navigate into it. Message E2E for
    /// groups (MLS) is a later increment — this wires the create + membership only.
    func createGroup(name: String, members: [VContact]) async -> VConversation? {
        do {
            let memberIds = members.map { $0.userId }
            let convId = try await ChatService.shared.createGroup(name: name, memberIds: memberIds)
            if let existing = groupConversations.first(where: { $0.id == convId }) {
                return existing
            }
            // Build the REAL MLS group on top of the server conversation: add each
            // member's device by KeyPackage and distribute Welcome/Commit.
            await GroupEngine.shared.createGroup(conversationId: convId, memberUserIds: memberIds)
            let conv = VConversation(id: convId, type: .group, title: name,
                                     photoName: nil, lastMessagePreview: nil, lastMessageAt: nil,
                                     unreadCount: 0, memberCount: members.count + 1)
            LocalStore.upsertConversation(conv)
            groupConversations.insert(conv, at: 0)
            return conv
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t create group."
            return nil
        }
    }

    /// Open a conversation: show cached messages, then sync (fetch + decrypt-new) from server.
    func openConversation(_ conv: VConversation) {
        refresh(conv.id)
        Task { await syncMessages(conv) }
    }

    /// Pull from the server and decrypt any new messages, then refresh the UI.
    func syncMessages(_ conv: VConversation) async {
        if conv.type == .group {
            // Groups: process MLS control events (Welcome/Commit) FIRST, then decrypt
            // this device's copy of the group's app messages into the shared store.
            await GroupEngine.shared.syncGroupEvents()
            await GroupEngine.shared.syncGroupMessages(conversationId: conv.id)
            // Settings → Privacy → "Send read receipts". This is one of the only two
            // places the app POSTs receipts/mark with status "read"; both are gated.
            if PrivacySettings.shared.sendReadReceipts {
                await ChatEngine.shared.markRead(conversationId: conv.id)
            }
            refresh(conv.id)
            return
        }
        do {
            let peer = try await peerUserId(for: conv)
            _ = try await ChatEngine.shared.sync(conversationId: conv.id, peerUserId: peer)
            refresh(conv.id)
            // If we couldn't decrypt inbound messages, our session with the peer is
            // stale — ask them (once) to re-establish so future messages work.
            if ChatEngine.shared.lastSyncHadDecryptFailure, !resetRequested.contains(conv.id) {
                resetRequested.insert(conv.id)
                // Sessions are keyed per (peerUserId, deviceId) now — reset by peer, not conv.
                ChatEngine.shared.resetSession(peer)
                WebSocketClient.shared.sendSessionReset(conversationId: conv.id, recipientIds: [peer])
            }
            // Settings → Privacy → "Send read receipts" (blue ticks for the sender).
            if PrivacySettings.shared.sendReadReceipts {
                await ChatEngine.shared.markRead(conversationId: conv.id)
            }
            await fetchPresence(conv.id, peerUserId: peer)
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t load messages."
        }
    }

    /// Resolve the peer + refresh presence (for the periodic poll while a chat is open).
    func refreshPresence(_ conv: VConversation) async {
        guard conv.type == .direct, let peer = try? await peerUserId(for: conv) else { return }
        await fetchPresence(conv.id, peerUserId: peer)
    }

    /// Fetch + apply the peer's online/last-seen presence to the conversation.
    func fetchPresence(_ convId: String, peerUserId: String) async {
        guard let st = try? await ChatService.shared.status(userId: peerUserId),
              let i = directConversations.firstIndex(where: { $0.id == convId }) else { return }
        directConversations[i].isOnline = st.online
        directConversations[i].lastSeenAt = st.lastSeen
    }

    /// Apply a delivery/read receipt (WS) — persist it in the engine (no regression)
    /// then refresh that conversation.
    private func applyReceipt(messageId: String, status: String) {
        let cid = ChatEngine.shared.applyReceipt(messageId: messageId, status: status)
        NSLog("[VOIID] 📥 receipt \(status) for \(messageId) → \(cid == nil ? "no match" : "applied")")
        if let cid { refresh(cid) }
    }

    /// Rebuild a conversation's UI messages from the local (decrypted) store.
    private func refresh(_ convId: String) {
        let mapped = ChatEngine.shared.messages(conversationId: convId).compactMap { d -> VMessage? in
            // A location envelope: decode the stored (key-stripped) JSON into a LocationRef.
            // Rows in the location tables are RECONCILED from the message store here (the
            // store is the source of truth; the tables are a derived cache). pin / live_start
            // render a bubble; live_stop / live_rekey are SILENT control — recorded in the
            // decrypt-once ledger but never shown as a message (docs/LOCATION.md §4).
            let locRef: LocationRef?
            if let json = d.locationJSON, let env = LocationEnvelope.parse(json) {
                reconcileLocationShare(env, conversationId: convId, isMine: d.isMine, senderId: d.senderId)
                guard env.k.rendersBubble, env.k != .live_stop else { return nil }
                locRef = env.ref
            } else { locRef = nil }
            let kind: MessageKind
            if locRef != nil { kind = .location }
            else { kind = d.media.map { $0.mime.hasPrefix("audio/") ? .voice : .image } ?? .text }
            // Mine: sending (offline) / sent / delivered / read — from the PERSISTED
            // delivery status so it never regresses on rebuild. Inbound: shown as read.
            let status: MessageStatus
            if d.isMine {
                if d.pending { status = .sending }
                else {
                    switch d.deliveryStatus {
                    case "read": status = .read
                    case "delivered": status = .delivered
                    default: status = .sent
                    }
                }
            } else { status = .read }
            var vm = VMessage(id: d.serverId ?? d.id, conversationId: convId,
                              senderId: d.isMine ? "me" : d.senderId,
                              kind: kind, text: d.text, createdAt: d.createdAt,
                              status: status, isMine: d.isMine,
                              mediaRef: d.media, location: locRef)
            // Sender's real display name (saved name → full name → phone → username) for the
            // group bubble. Without this senderName stayed "" and the name never showed.
            if !d.isMine { vm.senderName = UserDirectory.shared.displayName(d.senderId) }
            // Real Delivered / Read times for the Message Info sheet (nil until each receipt).
            vm.deliveredAt = d.deliveredAt
            vm.readAt = d.readAt
            // Surface delivered chat actions onto the bubble.
            vm.deletedForEveryone = d.deletedForEveryone ?? false
            vm.forwarded = d.forwarded ?? false
            if let q = d.quotedPreview { vm.replyToText = q; vm.replyToSender = d.quotedSender }
            // Reactions: display the peer's reaction if any, else our own. (Per-user map is
            // persisted in the engine; single-emoji display is a UI simplification.)
            if let reactions = d.reactions, !reactions.isEmpty {
                let myId = TokenStore.shared.userId
                vm.reaction = reactions.first(where: { $0.key != myId })?.value ?? reactions.first?.value
            }
            return vm
        }
        if !mapped.isEmpty || messagesByConversation[convId] != nil {
            messagesByConversation[convId] = mapped
        }
        if let last = mapped.last {
            let preview = (last.kind == .text || last.kind == .location) ? last.text : previewFor(last.kind)
            bumpPreview(convId, preview: preview)
        }
    }

    /// Keep the location tables in step with the message store: an INBOUND live_start creates
    /// the inbound-share row (so a relayed fix passes the client-side authorization check and
    /// its expiry is known), and a live_stop ends it. Outbound rows are owned by
    /// LocationShareEngine. Idempotent — runs on every refresh; the shareKey is already in the
    /// Keychain (captured at decrypt time), so no key handling is needed here.
    private func reconcileLocationShare(_ env: LocationEnvelope, conversationId: String,
                                        isMine: Bool, senderId: String) {
        guard !isMine, let shareId = env.s else { return }
        switch env.k {
        case .live_start:
            LocationStore.upsertInbound(id: shareId, conversationId: conversationId,
                                        ownerUserId: senderId, expiresAtMillis: env.expiresAt,
                                        cadenceSeconds: env.cadence ?? 15)
        case .live_stop:
            LocationStore.end(id: shareId)
            LocationShareEngine.shared.markStopped(shareId)
        default:
            break
        }
    }

    /// Send a media (image/voice) message: encrypt the blob on-device, upload the
    /// ciphertext to R2, and pack the key into the E2EE message (direct chats only).
    func sendMedia(_ data: Data, mime: String, caption: String = "", to conversationId: String) {
        let kind: MessageKind = mime.hasPrefix("audio/") ? .voice : .image
        let tempId = UUID().uuidString
        let msg = VMessage(id: tempId, conversationId: conversationId, senderId: "me",
                           kind: kind, text: caption, createdAt: .now, status: .sending, isMine: true)
        messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
        bumpPreview(conversationId, preview: previewFor(kind))

        guard let conv = directConversations.first(where: { $0.id == conversationId }) else {
            markStatus(tempId, in: conversationId, to: .sent)   // group: not supported yet
            return
        }
        Task {
            do {
                let peer = try await peerUserId(for: conv)
                _ = try await ChatEngine.shared.sendMedia(data, mime: mime, caption: caption,
                                                          conversationId: conversationId, peerUserId: peer)
                removeMessage(tempId, in: conversationId)
                refresh(conversationId)
            } catch {
                markStatus(tempId, in: conversationId, to: .failed)
                loadError = (error as? APIError)?.errorDescription ?? "Couldn’t send media."
            }
        }
    }

    /// Resolve (and cache) the peer user_id for a direct conversation.
    private func peerUserId(for conv: VConversation) async throws -> String {
        if let p = conv.peerUserId { return p }
        if let i = directConversations.firstIndex(where: { $0.id == conv.id }),
           let p = directConversations[i].peerUserId { return p }
        let resolved = try await ChatService.shared.resolvePeer(conversationId: conv.id)
        guard let peer = resolved.peerUserId else { throw APIError.http(status: 404, message: "no peer") }
        if let i = directConversations.firstIndex(where: { $0.id == conv.id }) {
            directConversations[i].peerUserId = peer
        }
        return peer
    }

    /// Send a real E2EE message in a direct chat (encrypt → /messages/send). Group
    /// chats keep a local echo only until MLS group messaging is wired.
    func send(_ text: String, kind: MessageKind = .text, to conversationId: String,
              replyTo: VMessage? = nil, forwarded: Bool = false) {
        let tempId = UUID().uuidString
        var msg = VMessage(id: tempId, conversationId: conversationId, senderId: "me",
                           kind: kind, text: text, createdAt: .now, status: .sending, isMine: true)
        msg.forwarded = forwarded
        if let r = replyTo {
            msg.replyToSender = r.isMine ? "You" : (r.senderName.isEmpty ? "" : r.senderName)
            msg.replyToText = r.kind == .text ? r.text : "Attachment"
        }
        guard let conv = directConversations.first(where: { $0.id == conversationId }) else {
            // Group conversation: real MLS end-to-end encryption.
            if kind == .text,
               groupConversations.contains(where: { $0.id == conversationId }) {
                bumpPreview(conversationId, preview: text)
                Task {
                    await GroupEngine.shared.sendGroupMessage(conversationId: conversationId, text: text)
                    refresh(conversationId)
                }
                return
            }
            // Unknown / non-text group payload — transient local echo only.
            messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
            bumpPreview(conversationId, preview: kind == .text ? text : previewFor(kind))
            markStatus(tempId, in: conversationId, to: .sent)
            return
        }

        guard kind == .text else {
            // Non-text via this path (rare, e.g. forwarded media) — transient echo.
            messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
            bumpPreview(conversationId, preview: previewFor(kind))
            return
        }

        // A quoted reply travels as its own E2EE envelope so the quote reaches the peer.
        if let r = replyTo {
            bumpPreview(conversationId, preview: text)
            let quotedId = r.id
            let preview = r.kind == .text ? String(r.text.prefix(80)) : previewFor(r.kind)
            let sender = r.isMine ? "You" : (r.senderName.isEmpty ? "" : r.senderName)
            Task {
                guard let peer = try? await peerUserId(for: conv) else {
                    loadError = "Couldn’t resolve the recipient."; return
                }
                _ = try? await ChatEngine.shared.sendReply(text: text, quotedId: quotedId,
                                                           quotedPreview: preview, quotedSender: sender,
                                                           conversationId: conversationId, peerUserId: peer)
                refresh(conversationId)
            }
            return
        }

        // Text: persist as PENDING in the engine store NOW (instant + offline-visible),
        // then flush (send) in the background. The store is the single source of truth.
        _ = ChatEngine.shared.enqueueText(text, conversationId: conversationId)
        refresh(conversationId)
        bumpPreview(conversationId, preview: text)
        Task {
            guard let peer = try? await peerUserId(for: conv) else {
                loadError = "Couldn’t resolve the recipient."; return
            }
            await ChatEngine.shared.flushPending(conversationId: conversationId, peerUserId: peer)
            refresh(conversationId)
        }
    }

    // MARK: - Realtime (WebSocket) glue

    private var realtimeInstalled = false
    private func startRealtime() {
        guard !realtimeInstalled else { return }
        realtimeInstalled = true
        WebSocketClient.shared.onMessageRef = { [weak self] cid in
            Task { await self?.handleIncoming(cid) }
        }
        WebSocketClient.shared.onTyping = { [weak self] cid, _, isTyping in
            guard let self else { return }
            if isTyping { self.typingConversations.insert(cid) } else { self.typingConversations.remove(cid) }
        }
        WebSocketClient.shared.onReceipt = { [weak self] mid, status in
            self?.applyReceipt(messageId: mid, status: status)
        }
        WebSocketClient.shared.onGroupEvent = { [weak self] cid in
            Task { await self?.handleGroupEvent(cid) }
        }
        WebSocketClient.shared.onSessionReset = { [weak self] cid in
            // Peer couldn't decrypt our messages → drop our session so the next send
            // re-establishes. Sessions are keyed per (peerUserId, deviceId) now, so resolve
            // the conversation's peer and reset across all of that peer's devices.
            guard let self else { return }
            Task {
                if let conv = self.directConversations.first(where: { $0.id == cid }),
                   let peer = try? await self.peerUserId(for: conv) {
                    ChatEngine.shared.resetSession(peer)
                }
            }
        }
        // Call signaling: wire the WebRTC engine's inbound handlers (call_offer/answer/
        // ice/hangup) + CallKit onto the same socket.
        CallService.shared.configure(socket: WebSocketClient.shared)
        // We're authenticated by the time realtime starts, so this is the point where
        // a VoIP token captured before login (or on a fresh install) gets uploaded.
        VoIPPushManager.shared.uploadTokenIfNeeded()
    }

    // Conversations we've already asked the peer to reset this session (avoid loops).
    private var resetRequested: Set<String> = []

    /// A message arrived (WS ref) — fetch + decrypt that conversation.
    private func handleIncoming(_ conversationId: String) async {
        NSLog("[VOIID] handleIncoming conv=\(conversationId) known=\(directConversations.contains { $0.id == conversationId })")
        if let conv = directConversations.first(where: { $0.id == conversationId })
            ?? groupConversations.first(where: { $0.id == conversationId }) {
            await syncMessages(conv); return
        }
        // Unknown conversation (first message / a group we were just added to) — load the
        // list, THEN sync that conversation so the message actually appears (not just on open).
        await loadConversations()
        if let conv = directConversations.first(where: { $0.id == conversationId })
            ?? groupConversations.first(where: { $0.id == conversationId }) {
            await syncMessages(conv)
        }
    }

    /// An MLS control event (Welcome/Commit) is waiting for us — process group events,
    /// then refresh any group we may have just joined. Triggered by the `mls_event` WS push.
    private func handleGroupEvent(_ conversationId: String) async {
        await GroupEngine.shared.syncGroupEvents()
        // A Welcome may have added us to a brand-new group not yet in our list.
        if !groupConversations.contains(where: { $0.id == conversationId }) {
            await loadConversations()
        }
        if let conv = groupConversations.first(where: { $0.id == conversationId }) {
            await syncMessages(conv)
        }
    }

    private func markStatus(_ id: String, in convId: String, to status: MessageStatus) {
        guard var arr = messagesByConversation[convId], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        arr[i].status = status
        messagesByConversation[convId] = arr
    }
    private func removeMessage(_ id: String, in convId: String) {
        messagesByConversation[convId]?.removeAll { $0.id == id }
    }

    private func previewFor(_ kind: MessageKind) -> String {
        switch kind {
        case .image: return "📷 Photo"
        case .voice: return "🎤 Voice message"
        case .document: return "📄 Document"
        default: return "Message"
        }
    }

    /// Forward a message to one or more conversations (with a Forwarded tag).
    /// Media is forwarded by RE-SENDING its existing E2EE reference — the ciphertext is
    /// already in R2, so no re-upload; the media key rides E2E as always.
    func forward(_ message: VMessage, to conversationIds: [String]) {
        for cid in conversationIds {
            if let ref = message.mediaRef, message.kind == .image || message.kind == .voice || message.kind == .document,
               let conv = directConversations.first(where: { $0.id == cid }) {
                Task {
                    guard let peer = try? await peerUserId(for: conv) else { return }
                    _ = try? await ChatEngine.shared.forwardMedia(ref, caption: message.text,
                                                                  conversationId: cid, peerUserId: peer)
                    refresh(cid)
                }
            } else {
                send(message.text,
                     kind: message.kind == .poll ? .text : message.kind,
                     to: cid, forwarded: true)
            }
        }
    }

    /// Delete a message. forEveryone=true tombstones it AND tells the peer to do the same;
    /// otherwise removes it only from this device.
    func deleteMessage(_ messageId: String, in convId: String, forEveryone: Bool) {
        guard var arr = messagesByConversation[convId] else { return }
        if forEveryone {
            if let i = arr.firstIndex(where: { $0.id == messageId }) {
                arr[i].deletedForEveryone = true
                arr[i].reaction = nil
                withAnimation { messagesByConversation[convId] = arr }
            }
            // Deliver the delete over E2EE so the peer erases it too (direct chats).
            if let conv = directConversations.first(where: { $0.id == convId }) {
                Task {
                    guard let peer = try? await peerUserId(for: conv) else { return }
                    try? await ChatEngine.shared.sendDeleteForEveryone(
                        targetServerId: messageId, conversationId: convId, peerUserId: peer)
                }
            }
        } else {
            withAnimation { arr.removeAll { $0.id == messageId }; messagesByConversation[convId] = arr }
        }
        Haptics.rigid()
    }

    /// Delete an entire conversation from the list.
    func deleteConversation(_ convId: String) {
        withAnimation {
            directConversations.removeAll { $0.id == convId }
            groupConversations.removeAll { $0.id == convId }
            messagesByConversation[convId] = nil
        }
        Haptics.rigid()
    }

    /// Clear all messages in a conversation but keep it in the list.
    func clearChat(_ convId: String) {
        withAnimation { messagesByConversation[convId] = [] }
        if let i = directConversations.firstIndex(where: { $0.id == convId }) {
            directConversations[i].lastMessagePreview = nil
        } else if let i = groupConversations.firstIndex(where: { $0.id == convId }) {
            groupConversations[i].lastMessagePreview = nil
        }
        Haptics.rigid()
    }

    /// Toggle an emoji reaction on a message — and DELIVER it to the peer over E2EE.
    func react(messageId: String, emoji: String, in convId: String) {
        guard var arr = messagesByConversation[convId],
              let idx = arr.firstIndex(where: { $0.id == messageId }) else { return }
        let cleared = (arr[idx].reaction == emoji)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            arr[idx].reaction = cleared ? nil : emoji     // optimistic local
            messagesByConversation[convId] = arr
        }
        Haptics.tap()
        // Send over the real E2EE path (direct chats). emoji=nil clears our reaction.
        guard let conv = directConversations.first(where: { $0.id == convId }) else { return }
        Task {
            guard let peer = try? await peerUserId(for: conv) else { return }
            try? await ChatEngine.shared.sendReaction(targetServerId: messageId,
                                                      emoji: cleared ? nil : emoji,
                                                      conversationId: convId, peerUserId: peer)
        }
    }

    /// Send a poll into a conversation.
    func sendPoll(_ question: String, options: [String], to conversationId: String) {
        let poll = VPoll(id: UUID().uuidString, question: question,
                         options: options.map { .init(id: UUID().uuidString, text: $0, votes: 0) })
        let msg = VMessage(id: UUID().uuidString, conversationId: conversationId, senderId: "me",
                           kind: .poll, text: "Poll", createdAt: .now, status: .sent, isMine: true, poll: poll)
        messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
        bumpPreview(conversationId, preview: "📊 Poll: \(question)")
    }

    /// Register a vote on a poll option (single choice; toggles).
    func vote(messageId: String, optionId: String, in conversationId: String) {
        guard var arr = messagesByConversation[conversationId],
              let mi = arr.firstIndex(where: { $0.id == messageId }),
              var poll = arr[mi].poll else { return }
        for oi in poll.options.indices {
            if poll.options[oi].id == optionId { poll.options[oi].votes += 1 }
        }
        arr[mi].poll = poll
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            messagesByConversation[conversationId] = arr
        }
    }

    private func bumpPreview(_ convId: String, preview: String) {
        let now = Date()
        if let i = directConversations.firstIndex(where: { $0.id == convId }) {
            directConversations[i].lastMessagePreview = preview
            directConversations[i].lastMessageAt = now
        } else if let i = groupConversations.firstIndex(where: { $0.id == convId }) {
            groupConversations[i].lastMessagePreview = preview
            groupConversations[i].lastMessageAt = now
        }
        // Persist the snippet + time so the chat LIST renders it (and orders by it) on the
        // NEXT cold launch straight from SQLite — no message-store decode on the launch path.
        if !preview.isEmpty { LocalStore.updatePreview(conversationId: convId, preview: preview, at: now) }
    }
}

// MARK: - AI store

@MainActor
final class AIStore: ObservableObject {
    @Published var messages: [VAIMessage] = DummyData.aiMessages
    @Published var thinking = false

    func send(_ text: String) {
        messages.append(VAIMessage(id: UUID().uuidString, text: text, isUser: true))
        Task {
            thinking = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            thinking = false
            let canned = "Whats good? How can i Help you today?"
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                messages.append(VAIMessage(id: UUID().uuidString, text: canned, isUser: false))
            }
        }
    }
}

// MARK: - Clips store

@MainActor
final class ClipsStore: ObservableObject {
    @Published var clips: [VClip] = DummyData.clips
    @Published var comments: [VClipComment] = DummyData.clipComments

    func toggleLike(_ clip: VClip) {
        guard let i = clips.firstIndex(of: clip) else { return }
        clips[i].likes += 1
    }
    func addComment(_ text: String) {
        comments.insert(VClipComment(id: UUID().uuidString, authorName: "You", text: text), at: 0)
    }
}
