//
//  MapPresenceEngine.swift
//  Voiid
//
//  The brain of Feature (B) — the Map. It ties together the coarse location provider, the
//  Keychain-held share keys, the local presence store, the server share row, and the WS
//  relay, and it enforces the two safety invariants that make the Map safe to ship:
//
//    1. YOU APPEAR TO NO ONE until you name individuals. Visibility is off (ghost) by
//       default; going visible requires an explicit, non-empty per-contact audience.
//    2. GHOST IS A HARD LOCAL GATE. While ghosted, no fix is emitted and — because the
//       provider is stopped — none is even taken. Turning ghost off MINTS A FRESH KEY, so
//       the ghosted period is cryptographically dark.
//
//  HOW A COORDINATE STAYS E2EE WITH ONE CIPHERTEXT FOR THE WHOLE AUDIENCE (§1):
//    - Going visible mints a fresh 32-byte `mapKey` (generateMasterSecret) → MapKeyStore.
//    - `mapKey` reaches each audience member inside a durable `map_key` control message
//      over the 1:1 Double Ratchet (the `controlSender` seam). The server never sees it.
//    - Every coarse fix is `encryptBackup(mapKey, fixJSON)` → ONE ciphertext, relayed to
//      each recipient's user channel over the ephemeral WS. No DB row, no push, no ratchet
//      advance per fix.
//
//  THE HONEST LIMIT, stated where it lives: there is no forward secrecy within a single
//  visibility session — whoever holds `mapKey` can decrypt every fix until the key rotates
//  (on ghost, on revoke, on kill). Forward secrecy ACROSS sessions is preserved because
//  each session mints a fresh random key. Fixes are never stored, so the window is the live
//  stream only. This is a substrate limit (`e2e-core` exposes no 32→32 KDF), not a bug.
//
//  THE ONE INTEGRATION SEAM: distributing/receiving the `map_key` and `map_off` control
//  messages over the ratchet is the shared location substrate owned jointly with Feature
//  (A). This engine performs that work through `controlSender` (outbound) and
//  `ingestLocationEnvelope` (inbound). Everything else — audience, ghost, provider, server
//  row, WS fix stream in and out, the render state machine — is self-contained here.
//

import Foundation
import CoreLocation
import Combine

@MainActor
final class MapPresenceEngine: ObservableObject {

    static let shared = MapPresenceEngine()

    // MARK: - Published state (the UI reads these, never the network)

    /// Contacts currently visible to you, freshest first. The render state (live/stale/…)
    /// is derived per-row from `fixedAt` by `MapPresenceState.forFix`.
    @Published private(set) var presences: [MapPresence] = []
    /// People who have made themselves visible to you (sent a `map_key`), whether or not a
    /// fix has arrived yet. Drives the "waiting for location" and "away" lists.
    @Published private(set) var inboundSenders: Set<String> = []
    /// Your own allow-list — who can see you.
    @Published private(set) var audience: [MapAudienceMember] = []
    /// Your active server share id while visible, else nil.
    @Published private(set) var outboundShareId: String?
    /// A human-readable reason the last visibility action could not complete (e.g. location
    /// permission denied, server unreachable). Surfaced honestly; never a silent failure.
    @Published var lastError: String?

    private let visibility = MapVisibilityState.shared
    private let provider = MapLocationProvider.shared

    /// The ratchet control-message seam (see file header). Returns true if the control
    /// message was accepted for delivery to that user. Wired at app start by the shared
    /// location substrate; nil means peer key exchange is not available in this build, in
    /// which case going visible still runs locally but cannot hand keys to the audience —
    /// surfaced via `lastError`, never faked.
    var controlSender: ((_ envelopeJSON: Data, _ toUserId: String) async -> Bool)?

    private var emitSeq = 0
    private let knownInboundKey = "voiid.map.inboundSenders.v1"

    private init() {
        reloadFromStore()
        inboundSenders = loadKnownInbound()
        wireProvider()
        wireWebSocket()
        // A cold start must not resurrect a stale trail: drop anything past the 8-hour
        // window before the first render (§8).
        MapPresenceStore.pruneAged()
        reloadFromStore()

        NotificationCenter.default.addObserver(forName: .voiidDidSignOut, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSignOut() }
        }
    }

    // MARK: - Wiring

    /// Wire the ratchet control seam so `map_key` / `map_off` actually reach the audience.
    /// Call ONCE at app start, post-auth. Each control message goes to a single peer over the
    /// durable 1:1 message path (`content_type: "location"`, key stays end-to-end); the peer's
    /// direct conversation is resolved (idempotently created) from their user id. Without this
    /// the sender goes visible locally but never hands out the key, so nobody can decrypt the
    /// WS fix stream — the "others never appear on my map" bug.
    func configureControlSender() {
        controlSender = { envelopeJSON, toUserId in
            guard let json = String(data: envelopeJSON, encoding: .utf8) else { return false }
            do {
                let convId = try await ChatService.shared.createDirect(memberId: toUserId)
                try await ChatEngine.shared.sendLocation(
                    plaintextJSON: json, conversationId: convId, peerUserId: toUserId,
                    displayText: "", rendersBubble: false)   // control only — never a bubble
                return true
            } catch {
                NSLog("[VOIID] map controlSender: send to \(toUserId) FAILED: \(error)")
                return false
            }
        }
    }

    private func wireProvider() {
        provider.onFix = { [weak self] loc in self?.emitFix(loc) }
    }

    /// Route the relay's map frames. These callbacks are additive on `WebSocketClient` and
    /// intentionally generic (share_id / from_user_id / ciphertext) so Feature (A) can share
    /// the same routing point rather than duplicating it.
    private func wireWebSocket() {
        let ws = WebSocketClient.shared
        let priorUpdate = ws.onLocationUpdate
        ws.onLocationUpdate = { [weak self] shareId, fromUserId, ciphertext in
            priorUpdate?(shareId, fromUserId, ciphertext)
            self?.receiveFix(shareId: shareId, fromUserId: fromUserId, ciphertext: ciphertext)
        }
        let priorStop = ws.onLocationStop
        ws.onLocationStop = { [weak self] shareId, fromUserId in
            priorStop?(shareId, fromUserId)
            self?.receiveStop(shareId: shareId, fromUserId: fromUserId)
        }
    }

    // MARK: - Reads

    func reloadFromStore() {
        MapPresenceStore.pruneAged()
        presences = MapPresenceStore.presences()
        audience = MapPresenceStore.audience()
    }

    var isVisible: Bool { visibility.isVisible }
    var mode: MapVisibilityMode { visibility.mode }

    /// The render state for a known inbound sender. A sender we hold no presence for is
    /// either waiting for their first fix or has aged out; `notSharing` is only ever reached
    /// via an explicit `map_off`, which erases the row — so it is represented by the sender
    /// simply not being in `inboundSenders` at all.
    func state(forSender userId: String, now: Date = Date()) -> MapPresenceState {
        guard let p = MapPresenceStore.presence(for: userId) else { return .agedOut }
        return MapPresenceState.forFix(at: p.fixedAt, now: now)
    }

    // MARK: - Foreground

    /// Called when the Map appears / the app becomes active. Resets the 24-hour auto-ghost
    /// clock, refreshes a fix if visible, and pushes the server row's ceiling forward.
    func noteForegrounded() {
        visibility.noteForegrounded()
        reloadFromStore()
        if visibility.isVisible {
            provider.refreshOnce()
            if let sid = outboundShareId {
                Task { _ = try? await MapShareAPI.extend(shareId: sid) }
            }
        } else {
            // The auto-ghost may have fired while we were away — make sure we are not still
            // emitting and the local flag is honest.
            stopEmitting()
        }
    }

    // MARK: - Going visible

    /// Make yourself visible to `userIds` (added to the allow-list). Requires location
    /// permission; on denial, surfaces `lastError` and stays ghost — never a fake "visible".
    func goVisible(to userIds: [String]) async {
        lastError = nil
        let targets = userIds.filter { !$0.isEmpty }
        guard !targets.isEmpty else {
            lastError = "Choose at least one person who can see you."
            return
        }

        // 1. Location permission, in-context.
        if !provider.isAuthorized {
            provider.requestWhenInUse()
            // The delegate resolves asynchronously; if it is still not authorized we cannot
            // proceed. The caller re-invokes after the system prompt returns.
            if !provider.isAuthorized {
                lastError = "Voiid needs location access to put you on the Map."
                return
            }
        }

        // goVisible SETS the audience to exactly `targets` (the chosen scope), so switching
        // from "Everyone" to "My Contacts" or a smaller set actually shrinks it — clear first,
        // then add. "Add more people" uses addToAudience(_:) instead.
        MapPresenceStore.clearAudience()
        MapPresenceStore.addToAudience(targets)
        reloadFromStore()

        // 2. Fresh key — never the backup master secret (see MapKeyStore).
        let key = MapKeyStore.mintOutboundKey()

        // 3. Server row (the only place membership is validated + abuse rate-limited).
        let audienceIds = audience.map(\.userId)
        do {
            let res = try await MapShareAPI.createMapShare(targetUserIds: audienceIds)
            outboundShareId = res.share_id
        } catch {
            // Do not claim visibility the server never recorded.
            MapKeyStore.clearOutboundKey()
            lastError = "Couldn’t start sharing on the Map. Check your connection and try again."
            return
        }

        // 4. Distribute the key over the ratchet to each audience member.
        await distributeMapKey(key, to: audienceIds)

        // 5. Flip local state + start the coarse provider.
        visibility.markVisible()
        emitSeq = 0
        provider.start()
        provider.refreshOnce()
    }

    // MARK: - Ghost Mode

    /// Enter Ghost Mode — instant and local-first (§8): stop emitting, tell the audience,
    /// end the server share, and rotate the key so the ghosted window is cryptographically
    /// dark. The audience allow-list is retained, so turning ghost off re-shares with the
    /// same people under a fresh key.
    func enterGhost(_ duration: GhostDuration = .untilOff) async {
        // Hard gate first — no fix may be taken from this instant.
        visibility.markGhost(duration)
        stopEmitting()

        let audienceIds = audience.map(\.userId)
        let sid = outboundShareId

        // Instant effect on live sockets, then the durable stop that reaches offline peers.
        if let sid { WebSocketClient.shared.sendLocationStop(shareId: sid, recipientIds: audienceIds) }
        await distributeMapOff(shareId: sid, to: audienceIds)
        if let sid { await MapShareAPI.endShare(shareId: sid) }

        outboundShareId = nil
        MapKeyStore.clearOutboundKey()   // rotate: anyone holding the old key sees nothing new
    }

    /// Leave Ghost Mode — re-share with the retained audience under a FRESH key.
    func leaveGhost() async {
        guard !audience.isEmpty else {
            // Nothing to share with; leaving ghost with an empty allow-list just means
            // "not ghosted, but visible to no one". Stay honest — do not start the provider.
            visibility.markVisible()
            return
        }
        await goVisible(to: audience.map(\.userId))
    }

    // MARK: - Audience management

    /// Add people to your allow-list. If already visible, extend the current session to them
    /// under the CURRENT key (no rekey needed to add — only to remove).
    func addToAudience(_ userIds: [String]) async {
        let targets = userIds.filter { !$0.isEmpty }
        guard !targets.isEmpty else { return }
        MapPresenceStore.addToAudience(targets)
        reloadFromStore()
        guard visibility.isVisible, let key = MapKeyStore.outboundKey() else { return }
        // Recreate the server row with the full audience (server auto-ends the prior share),
        // then hand the current key to the newly-added members.
        let audienceIds = audience.map(\.userId)
        if let res = try? await MapShareAPI.createMapShare(targetUserIds: audienceIds) {
            outboundShareId = res.share_id
        }
        await distributeMapKey(key, to: targets)
    }

    /// Remove one person. Revocation is a REKEY (§3): stop that recipient, mint a new key,
    /// and redistribute to the remaining audience so the removed recipient's key decrypts
    /// nothing further. (It cannot un-see a past fix — revocation stops future fixes only.)
    func removeFromAudience(_ userId: String) async {
        let sid = outboundShareId
        MapPresenceStore.removeFromAudience(userId)
        reloadFromStore()

        guard visibility.isVisible else { return }

        // Stop the removed recipient specifically.
        if let sid { WebSocketClient.shared.sendLocationStop(shareId: sid, recipientIds: [userId]) }
        await distributeMapOff(shareId: sid, to: [userId])
        if let sid { await MapShareAPI.revokeTarget(shareId: sid, userId: userId) }

        // Rekey the remaining audience.
        let remaining = audience.map(\.userId)
        guard !remaining.isEmpty else { await enterGhost(); return }
        let newKey = MapKeyStore.mintOutboundKey()
        if let res = try? await MapShareAPI.createMapShare(targetUserIds: remaining) {
            outboundShareId = res.share_id
        }
        emitSeq = 0
        await distributeMapKey(newKey, to: remaining)
    }

    // MARK: - Kill switch (§8)

    /// Stop all Map sharing: end the outbound share, rotate away the key, clear the
    /// allow-list, and turn Ghost Mode on. Destructive and immediate.
    func killSwitch() async {
        await enterGhost(.untilOff)
        MapPresenceStore.clearAudience()
        reloadFromStore()
    }

    // MARK: - Emission

    private func emitFix(_ loc: CLLocation) {
        // Belt-and-braces: even though the provider is stopped when ghosted, never emit
        // while the hard gate is engaged.
        guard !visibility.isEffectivelyGhosted,
              let sid = outboundShareId,
              let key = MapKeyStore.outboundKey() else { return }
        let audienceIds = audience.map(\.userId)
        guard !audienceIds.isEmpty else { return }

        emitSeq += 1
        let env = MapEnvelope.presenceFix(shareId: sid, seq: emitSeq,
                                          coord: loc.coordinate, accuracy: loc.horizontalAccuracy)
        guard let plaintext = try? JSONEncoder().encode(env),
              let ciphertext = try? encryptBackup(secret: key, plaintext: plaintext) else { return }
        WebSocketClient.shared.sendLocationUpdate(shareId: sid, recipientIds: audienceIds,
                                                  ciphertext: ciphertext.base64EncodedString())
    }

    private func stopEmitting() {
        provider.stop()
    }

    // MARK: - Reception (WS fix stream)

    private func receiveFix(shareId: String, fromUserId: String, ciphertext: String) {
        // CLIENT-SIDE AUTHORIZATION (§9): the WS process cannot verify the recipient is an
        // authorized target, so the client must. We accept a fix ONLY from a sender who has
        // handed us a `map_key` (an inbound key exists). Anything else decrypts to garbage
        // and is dropped.
        guard let key = MapKeyStore.inboundKey(forSender: fromUserId),
              let blob = Data(base64Encoded: ciphertext),
              let plaintext = try? decryptBackup(secret: key, blob: blob),
              let env = try? JSONDecoder().decode(MapEnvelope.self, from: plaintext),
              env.kind == .fix,
              env.s == shareId,               // the authenticated share id must match the frame
              let lat = env.lat, let lon = env.lon, let seq = env.n
        else { return }

        let fixedAt = env.t.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? Date()
        let changed = MapPresenceStore.upsertFix(
            senderUserId: fromUserId, shareId: shareId,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            accuracy: env.acc ?? 0, seq: seq, fixedAt: fixedAt)
        if changed {
            noteInboundSender(fromUserId)
            reloadFromStore()
        }
    }

    private func receiveStop(shareId: String, fromUserId: String) {
        // An explicit stop ERASES the cached position (the load-bearing distinction from an
        // age-out, which keeps it) and rotates the sender out of our view.
        MapKeyStore.clearInboundKey(forSender: fromUserId)
        MapPresenceStore.erasePresence(senderUserId: fromUserId)
        forgetInboundSender(fromUserId)
        reloadFromStore()
    }

    // MARK: - Control-message plumbing (the ratchet seam)

    /// Feed EVERY inbound `_vloc` location envelope here. Map-relevant kinds (`map_key`,
    /// `map_off`) are consumed; conversation-share kinds and `fix` are ignored, so this is
    /// safe to call from a single `_vloc` decode hook shared with Feature (A).
    func ingestLocationEnvelope(_ json: Data, fromUserId: String) {
        guard let env = try? JSONDecoder().decode(MapEnvelope.self, from: json) else { return }
        switch env.kind {
        case .mapKey:
            guard let b64 = env.key, let key = Data(base64Encoded: b64), key.count == 32 else { return }
            MapKeyStore.setInboundKey(key, forSender: fromUserId)
            noteInboundSender(fromUserId)
            reloadFromStore()
        case .mapOff:
            receiveStop(shareId: env.s ?? "", fromUserId: fromUserId)
        default:
            break   // fix (WS-only) / conversation kinds — not the Map's concern
        }
    }

    private func distributeMapKey(_ key: Data, to userIds: [String]) async {
        guard let sid = outboundShareId else { return }
        let env = MapEnvelope(vloc: 1, k: MapEnvelope.Kind.mapKey.rawValue, s: sid,
                              t: Int64(Date().timeIntervalSince1970 * 1000),
                              expiresAt: Int64(Date().addingTimeInterval(TimeInterval(MapShareAPI.mapDurationSeconds)).timeIntervalSince1970 * 1000),
                              key: key.base64EncodedString(),
                              cadence: 300)
        await sendControl(env, to: userIds, purpose: "map_key")
    }

    private func distributeMapOff(shareId: String?, to userIds: [String]) async {
        let env = MapEnvelope(vloc: 1, k: MapEnvelope.Kind.mapOff.rawValue, s: shareId,
                              t: Int64(Date().timeIntervalSince1970 * 1000))
        await sendControl(env, to: userIds, purpose: "map_off")
    }

    private func sendControl(_ env: MapEnvelope, to userIds: [String], purpose: String) async {
        guard let json = try? JSONEncoder().encode(env) else { return }
        guard let sender = controlSender else {
            // Honest degradation: the ratchet control path is not wired in this build, so we
            // cannot hand `\(purpose)` to the audience. Local state is still correct; peers
            // just will not receive the key/stop until the substrate is wired.
            NSLog("[VOIID] map \(purpose): no controlSender wired — audience not reached")
            if purpose == "map_key" {
                lastError = "You’re on the Map locally, but couldn’t reach your contacts to share the key yet."
            }
            return
        }
        for uid in userIds {
            let ok = await sender(json, uid)
            if !ok { NSLog("[VOIID] map \(purpose): control undelivered to \(uid)") }
        }
    }

    // MARK: - Inbound-sender bookkeeping (who is on my map)

    private func noteInboundSender(_ userId: String) {
        guard !inboundSenders.contains(userId) else { return }
        inboundSenders.insert(userId)
        persistKnownInbound()
    }

    private func forgetInboundSender(_ userId: String) {
        guard inboundSenders.contains(userId) else { return }
        inboundSenders.remove(userId)
        persistKnownInbound()
    }

    private func loadKnownInbound() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: knownInboundKey) ?? [])
    }
    private func persistKnownInbound() {
        UserDefaults.standard.set(Array(inboundSenders), forKey: knownInboundKey)
    }

    // MARK: - Teardown

    private func handleSignOut() {
        stopEmitting()
        outboundShareId = nil
        MapKeyStore.clearOutboundKey()
        MapPresenceStore.clearPresence()
        MapPresenceStore.clearAudience()
        for uid in inboundSenders { MapKeyStore.clearInboundKey(forSender: uid) }
        inboundSenders = []
        persistKnownInbound()
        presences = []
        audience = []
    }
}
