//
//  LocationShareEngine.swift
//  Voiid
//
//  The lifecycle of a conversation location share (docs/LOCATION.md §1, §3). Owns:
//   • the static pin send,
//   • live-share start / stop / extend,
//   • minting + distributing the shareKey (never seen by the server),
//   • streaming position fixes over the WS relay as encryptBackup(shareKey, fix) blobs,
//   • receiving + decrypting inbound fixes, and
//   • the live / stale / ended state machine, every state derivable from `expiresAt` alone.
//
//  TRANSPORT SPLIT (the whole design):
//   P1 pin + P2 control  → the durable MESSAGE path (ChatEngine 1:1 / GroupEngine MLS).
//                          Durability is what lets a STOP reach an offline recipient.
//   P3 fixes             → the ephemeral WS relay ONLY. Never a message, never a push,
//                          never persisted beyond the single most recent fix.
//
//  KEY SLED (docs/LOCATION.md §1): the shareKey MUST come from generateMasterSecret() and
//  MUST NEVER be a backup master secret — encryptBackup's HKDF label is shared with
//  account backups, so reusing the backup secret would derive the same AES key.
//
//  HONEST LIMIT: there is no forward secrecy WITHIN a share. e2e-core exposes no 32→32
//  KDF, so a key chain is impossible: one share == one key for its whole duration.
//  Forward secrecy ACROSS shares holds — every share mints a fresh random key.
//

import Foundation
import CoreLocation
import Combine

@MainActor
final class LocationShareEngine: ObservableObject {
    static let shared = LocationShareEngine()

    /// Active OUTBOUND shares this device is emitting — the banner renders these.
    @Published private(set) var outboundShares: [OutboundShare] = []
    /// Bumped on any inbound change (new fix, stop) so location bubbles recompute.
    @Published private(set) var version: Int = 0

    private let api = LocationAPI()
    private let service = LocationService()

    /// Per-active-share emit context: who receives, over which transport, at what cadence,
    /// and the next seq. `isGroup`/`conversationId` are needed to route the DURABLE stop.
    private struct Emit {
        let recipientIds: [String]
        let cadenceSeconds: Int
        let isGroup: Bool
        let conversationId: String
        var seq: Int
    }
    private var emitting: [String: Emit] = [:]

    /// share_ids we have seen an explicit stop for (so a bubble reads "ended", not just
    /// "stale", before expiry). Backed durably by LocationStore.ended_at.
    private var stopped: Set<String> = []
    /// Last accepted inbound seq per share, to drop out-of-order relay frames.
    private var inboundSeq: [String: Int] = [:]

    private var ticker: Timer?
    private var configured = false

    private init() {
        // LocationService delivers on the main run loop; hop onto the MainActor explicitly
        // so the isolation is never in question.
        service.onFix = { [weak self] loc in Task { @MainActor in self?.handleOutboundFix(loc) } }
        // A location control message was decrypted (possibly in the NSE). The inbound-share
        // rows are reconciled from the message store by ChatStore.refresh(); here we just
        // refresh the live UI.
        NotificationCenter.default.addObserver(forName: .voiidLocationInboxChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadFromStore(); self?.version &+= 1 }
        }
        NotificationCenter.default.addObserver(forName: .voiidDidSignOut, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wipe() }
        }
    }

    // MARK: - Wiring

    /// Route inbound WS location frames here + start the expiry ticker. Idempotent;
    /// called from the chats screen on foreground.
    ///
    /// Inbound frames are received via a NotificationCenter fan-out from WebSocketClient
    /// (not the single `onLocationUpdate` closure) so this and the Map surface can BOTH
    /// consume every frame without starving each other — each drops share_ids it doesn't own.
    func configure() {
        guard !configured else { reloadFromStore(); return }
        configured = true
        NotificationCenter.default.addObserver(forName: .voiidLocationRelayUpdate, object: nil,
                                               queue: .main) { [weak self] note in
            guard let sid = note.userInfo?["share_id"] as? String,
                  let from = note.userInfo?["from"] as? String,
                  let ct = note.userInfo?["ciphertext"] as? String else { return }
            Task { @MainActor in self?.handleInboundFix(shareId: sid, fromUserId: from, ciphertextB64: ct) }
        }
        NotificationCenter.default.addObserver(forName: .voiidLocationRelayStop, object: nil,
                                               queue: .main) { [weak self] note in
            guard let sid = note.userInfo?["share_id"] as? String else { return }
            let kind = (note.userInfo?["kind"] as? String) ?? ""
            Task { @MainActor in self?.handleInboundStop(shareId: sid, kind: kind) }
        }
        reloadFromStore()
        resumeOutboundIfNeeded()
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func reloadFromStore() { outboundShares = LocationStore.activeOutbound() }

    /// Resume streaming for any active outbound share we are not already emitting — e.g.
    /// after the app was relaunched mid-share. Without this the banner would show "sharing"
    /// while nothing actually streamed.
    private func resumeOutboundIfNeeded() {
        var resumedAny = false
        for share in LocationStore.activeOutbound() where emitting[share.id] == nil {
            let targets = LocationStore.targets(shareId: share.id)
            guard !targets.isEmpty, LocationKeyStore.shared.key(shareId: share.id) != nil else { continue }
            // isGroup comes off the row, not from the recipient count: a group of exactly two
            // has one other member, and inferring "1 recipient ⇒ 1:1" routed its durable
            // `live_stop` down the 1:1 ratchet carrying the GROUP conversation id, where it
            // was lost. (The WS stop and expiresAt still covered it, which is why this only
            // ever showed up for an offline recipient.)
            emitting[share.id] = Emit(recipientIds: targets, cadenceSeconds: share.cadenceSeconds,
                                      isGroup: share.isGroup, conversationId: share.conversationId,
                                      seq: Int(Date().timeIntervalSince1970))
            resumedAny = true
        }
        if resumedAny { service.startLive() }
    }

    private func wipe() {
        for id in Array(emitting.keys) { emitting[id] = nil }
        service.stopUpdating()
        outboundShares = []
        stopped.removeAll(); inboundSeq.removeAll()
    }

    // MARK: - Authorization (in-context, at the moment of first share)

    var authorizationStatus: CLAuthorizationStatus { service.authorizationStatus }
    var isReducedAccuracy: Bool { service.isReducedAccuracy }
    func requestWhenInUse() { service.requestWhenInUse() }
    func requestAlways() { service.requestAlways() }

    // MARK: - Static pin (P1)

    /// Capture one fix and send it as a pin. `label` is user-typed only, never geocoded.
    /// Completion carries success so the compose sheet can show a failure.
    /// Send a pin.
    ///
    /// `coordinate` is the position the user CHOSE on the picker map. When nil this falls back
    /// to a one-shot fix, which is "send my current location" — the old behaviour, and still
    /// what the quick path uses.
    ///
    /// Accuracy is deliberately nil for a chosen pin: an accuracy radius describes how well a
    /// SENSOR knows where you are, and a coordinate you dropped by hand has no such
    /// uncertainty. Drawing a 30 m circle around a deliberately-placed pin would be inventing
    /// a measurement that was never taken.
    func sendPin(conversationId: String, isGroup: Bool, peerUserId: String?,
                 label: String?, coordinate: CLLocationCoordinate2D? = nil,
                 completion: @escaping (Bool) -> Void) {
        if let coordinate {
            Task { @MainActor in
                let env = LocationEnvelope(
                    vloc: 1, k: .pin, s: nil, t: Date().timeIntervalSince1970 * 1000,
                    lat: LocationRounding.round(coordinate.latitude, decimals: LocationRounding.liveDecimals),
                    lon: LocationRounding.round(coordinate.longitude, decimals: LocationRounding.liveDecimals),
                    acc: nil,
                    label: (label?.isEmpty == false ? label : nil))
                let ok = await self.sendControl(env, conversationId: conversationId,
                                                isGroup: isGroup, peerUserId: peerUserId)
                completion(ok)
            }
            return
        }

        service.requestOneShot { [weak self] loc in
            Task { @MainActor in
                guard let self, let loc else { completion(false); return }
                let env = LocationEnvelope(
                    vloc: 1, k: .pin, s: nil, t: Date().timeIntervalSince1970 * 1000,
                    lat: LocationRounding.round(loc.coordinate.latitude, decimals: LocationRounding.liveDecimals),
                    lon: LocationRounding.round(loc.coordinate.longitude, decimals: LocationRounding.liveDecimals),
                    acc: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
                    label: (label?.isEmpty == false ? label : nil))
                let ok = await self.sendControl(env, conversationId: conversationId,
                                                isGroup: isGroup, peerUserId: peerUserId)
                completion(ok)
            }
        }
    }

    // MARK: - Live share (P2 control + P3 stream)

    /// Start a live share: create the server session, mint + distribute the shareKey,
    /// then stream fixes over the WS relay. `recipientIds` is the audience for the WS
    /// frames (the 1:1 peer, or every other group member). Returns the share_id or nil.
    @discardableResult
    func startLiveShare(conversationId: String, isGroup: Bool, peerUserId: String?,
                        recipientIds: [String], duration: ShareDuration) async -> String? {
        let targets = recipientIds.filter { !$0.isEmpty }
        guard !targets.isEmpty else { return nil }
        do {
            // 1. Server session — the only place membership is validated + abuse limited.
            let created = try await api.createShare(conversationId: conversationId,
                                                    targetUserIds: targets,
                                                    durationSeconds: duration.seconds)
            let shareId = created.share_id
            let expiresAt = parseISO(created.expires_at) ?? Date().addingTimeInterval(TimeInterval(duration.seconds))

            // 2. Mint a FRESH random key (never a backup secret) and keep it in the Keychain.
            let shareKey = generateMasterSecret()
            LocationKeyStore.shared.setKey(shareKey, shareId: shareId)

            // 3. Distribute the key inside a DURABLE live_start control message. The server
            //    never sees it; only devices with a live ratchet/MLS session get it.
            let startEnv = LocationEnvelope(
                vloc: 1, k: .live_start, s: shareId, t: Date().timeIntervalSince1970 * 1000,
                expiresAt: expiresAt.timeIntervalSince1970 * 1000,
                key: shareKey.base64EncodedString(), cadence: liveCadence)
            _ = await sendControl(startEnv, conversationId: conversationId,
                                  isGroup: isGroup, peerUserId: peerUserId)

            // 4. Local bookkeeping + start the stream.
            LocationStore.upsertOutbound(id: shareId, conversationId: conversationId, isGroup: isGroup,
                                         expiresAtMillis: expiresAt.timeIntervalSince1970 * 1000,
                                         cadenceSeconds: liveCadence, targets: targets)
            // Seed the sequence from epoch seconds so it stays monotonic even across an app
            // restart mid-share (a recipient drops any fix whose seq isn't strictly greater).
            emitting[shareId] = Emit(recipientIds: targets, cadenceSeconds: liveCadence,
                                     isGroup: isGroup, conversationId: conversationId,
                                     seq: Int(Date().timeIntervalSince1970))
            stopped.remove(shareId)
            service.startLive()
            reloadFromStore()
            return shareId
        } catch {
            NSLog("[VOIID] live share start FAILED conv=\(conversationId): \(error)")
            return nil
        }
    }

    /// Stop an outbound live share: instant WS stop, durable control stop (reaches an
    /// offline recipient), server DELETE, then tear down the key + local state. Every step
    /// is best-effort except the local teardown — the recipient's expiresAt is the actual
    /// guarantee, so a failed network step never leaves a share un-stoppable.
    func stopLiveShare(_ shareId: String) async {
        let ctx = emitting[shareId]
        let recipients = ctx?.recipientIds ?? LocationStore.targets(shareId: shareId)
        // (a) instant stop on live sockets.
        if !recipients.isEmpty {
            WebSocketClient.shared.sendLocationStop(shareId: shareId, recipientIds: recipients)
        }
        // (b) durable stop so an offline recipient still hides the marker — routed over the
        // same transport the share used.
        if let ctx {
            let stopEnv = LocationEnvelope(vloc: 1, k: .live_stop, s: shareId,
                                           t: Date().timeIntervalSince1970 * 1000)
            _ = await sendControl(stopEnv, conversationId: ctx.conversationId, isGroup: ctx.isGroup,
                                  peerUserId: ctx.isGroup ? nil : ctx.recipientIds.first)
        }
        // (c) server DELETE + local teardown.
        try? await api.endShare(shareId)
        emitting[shareId] = nil
        stopped.insert(shareId)
        LocationKeyStore.shared.deleteKey(shareId: shareId)
        LocationStore.end(id: shareId)
        if emitting.isEmpty { service.stopUpdating() }
        reloadFromStore()
        version &+= 1
    }

    /// End every outbound share (the kill switch / sign-out).
    func stopAll() async {
        for id in Array(emitting.keys) { await stopLiveShare(id) }
    }

    /// Extend an owned share.
    func extendLiveShare(_ shareId: String, duration: ShareDuration) async {
        guard let res = try? await api.extendShare(shareId, durationSeconds: duration.seconds) else { return }
        let expires = parseISO(res.expires_at) ?? Date().addingTimeInterval(TimeInterval(duration.seconds))
        LocationStore.extend(id: shareId, expiresAtMillis: expires.timeIntervalSince1970 * 1000)
        reloadFromStore()
    }

    // MARK: - Outbound fix stream (P3)

    private func handleOutboundFix(_ loc: CLLocation) {
        guard !emitting.isEmpty else { return }
        let lat = LocationRounding.round(loc.coordinate.latitude, decimals: LocationRounding.liveDecimals)
        let lon = LocationRounding.round(loc.coordinate.longitude, decimals: LocationRounding.liveDecimals)
        let acc = loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
        let nowMillis = Date().timeIntervalSince1970 * 1000
        let me = TokenStore.shared.userId ?? "me"
        for (shareId, var ctx) in emitting {
            ctx.seq += 1
            emitting[shareId] = ctx
            let fix = LocationFix(shareId: shareId, seq: ctx.seq, timestampMillis: nowMillis,
                                  lat: lat, lon: lon, acc: acc)
            guard let key = LocationKeyStore.shared.key(shareId: shareId),
                  let ct = try? encryptBackup(secret: key, plaintext: fix.envelope().encoded()) else { continue }
            // ONE ciphertext for the whole audience — decryptable by every recipient device.
            WebSocketClient.shared.sendLocationUpdate(shareId: shareId, recipientIds: ctx.recipientIds,
                                                      ciphertext: ct.base64EncodedString())
            LocationStore.saveFix(fix, senderUserId: me)
        }
    }

    // MARK: - Inbound fix stream (P3)

    private func handleInboundFix(shareId: String, fromUserId: String, ciphertextB64: String) {
        // CLIENT-SIDE authorization (docs/LOCATION.md §9): the WS process cannot verify the
        // recipient list, so a frame for a share we don't hold is dropped. Its payload is
        // encrypted under a key we don't have anyway — this is the real authorization.
        guard LocationStore.hasActiveInbound(shareId: shareId),
              let key = LocationKeyStore.shared.key(shareId: shareId),
              let ct = Data(base64Encoded: ciphertextB64),
              let plain = try? decryptBackup(secret: key, blob: ct),
              let fix = LocationFix.from(plaintext: String(decoding: plain, as: UTF8.self)) else { return }
        // Drop an out-of-order relay frame rather than rendering a jump backwards.
        if let last = inboundSeq[shareId], fix.seq <= last { return }
        inboundSeq[shareId] = fix.seq
        LocationStore.saveFix(fix, senderUserId: fromUserId)
        version &+= 1
    }

    /// `kind` is "map" / "conversation" when the API stamped it, "" on a client-relayed stop.
    private func handleInboundStop(shareId: String, kind: String = "") {
        // OWNERSHIP GUARD. Every location surface consumes this notification, so a friend's
        // Map ghost lands here too — and this used to run its full teardown on it. That is a
        // no-op only by accident: conversation keys are filed under the share id in a separate
        // Keychain service and the Map's share ids are never in that table, so the delete and
        // the row update both miss. A future key-naming change or an upsert on the store would
        // silently turn that accident into cross-feature teardown, which is precisely the bug
        // the Map side already had to fix. Act only on a share we actually hold.
        if kind == "map" { return }
        guard emitting[shareId] != nil || stopped.contains(shareId)
                || LocationStore.hasActiveInbound(shareId: shareId) else { return }
        stopped.insert(shareId)
        LocationStore.end(id: shareId)
        LocationKeyStore.shared.deleteKey(shareId: shareId)
        version &+= 1
    }

    // MARK: - State machine (every state derivable from expiresAt alone)

    /// The recipient-visible state of a share. An explicit stop OR `now >= expiresAt`
    /// means ENDED; a fix older than 2×cadence + 30 s (but still before expiry) is STALE.
    func shareState(shareId: String, expiresAt: Date?, cadence: Int) -> ShareState {
        if stopped.contains(shareId) { return .ended }
        if let expiresAt, Date() >= expiresAt { return .ended }
        if let (_, _, fixedAt) = LocationStore.lastFix(shareId: shareId) {
            let liveWindow = TimeInterval(2 * cadence + 30)
            if Date().timeIntervalSince(fixedAt) <= liveWindow { return .live }
            return .stale
        }
        // No fix yet, still within the timer → treat as stale (waiting for first fix),
        // never as live (we have no position to show).
        return .stale
    }

    /// The most recent known coordinate for a share (for the live marker / frozen pin).
    func lastFix(shareId: String) -> LocationFix? { LocationStore.lastFix(shareId: shareId)?.fix }

    /// Every inbound conversation share still running, in any chat, that has NOT ended.
    ///
    /// The Map tab merges these with ambient presence so a contact actively live-sharing with
    /// you moves at the share's 10–15 s cadence instead of the 5-minute presence cadence. This
    /// only reads state that already exists for the in-chat bubble — nothing is published and
    /// no cadence changes.
    func activeInboundShares() -> [(shareId: String, ownerUserId: String, expiresAt: Date, cadence: Int)] {
        LocationStore.activeInboundAll().filter {
            shareState(shareId: $0.shareId, expiresAt: $0.expiresAt, cadence: $0.cadence) != .ended
        }
    }

    /// Is this my own outbound share (renders an inline Stop on the live bubble)?
    func isEmitting(_ shareId: String) -> Bool { emitting[shareId] != nil }

    /// Mark a share ended for rendering (a durable live_stop reached us over the message
    /// path). Called by ChatStore.refresh() when it processes a live_stop envelope.
    func markStopped(_ shareId: String) {
        guard !stopped.contains(shareId) else { return }
        stopped.insert(shareId)
        version &+= 1
    }

    // MARK: - Expiry ticker

    private func tick() {
        // Stop emitting anything whose timer has elapsed — the primary guarantee. Both
        // sides also hide the marker at expiresAt with no network at all.
        let now = Date()
        for share in outboundShares where share.expiresAt <= now {
            Task { await stopLiveShare(share.id) }
        }
        reloadFromStore()
        version &+= 1
    }

    // MARK: - Control-message send (routes to the right E2EE transport)

    /// Send a location envelope over the durable message path. 1:1 → ChatEngine fan-out
    /// with content_type "location"; group → GroupEngine MLS (the JSON rides as the text
    /// plaintext and is recognised by its `_vloc` marker on the far side).
    private func sendControl(_ env: LocationEnvelope, conversationId: String,
                             isGroup: Bool, peerUserId: String?) async -> Bool {
        let json = String(decoding: env.encoded(), as: UTF8.self)
        if isGroup {
            // The JSON rides as the MLS text plaintext; the far side recognises it by `_vloc`.
            await GroupEngine.shared.sendGroupMessage(conversationId: conversationId, text: json)
            return true
        }
        guard let peer = peerUserId else { return false }
        do {
            try await ChatEngine.shared.sendLocation(plaintextJSON: json, conversationId: conversationId,
                                                     peerUserId: peer, displayText: env.displayText,
                                                     rendersBubble: env.k.rendersBubble)
            return true
        } catch {
            NSLog("[VOIID] location control send FAILED conv=\(conversationId): \(error)")
            return false
        }
    }

    // MARK: - Constants + helpers

    /// Live-share cadence (seconds). 10–15 s with a 25 m distance filter (docs/LOCATION.md §5).
    private let liveCadence = 15

    private func parseISO(_ s: String?) -> Date? { s.flatMap { ISO8601DateFormatter().date(from: $0) } }
}

extension Notification.Name {
    /// Posted by LocationInbox when an inbound share control message is decrypted, so the
    /// engine + any open chat refresh. Object is the share_id (String).
    static let voiidLocationInboxChanged = Notification.Name("voiidLocationInboxChanged")
    /// Posted by WebSocketClient for every relayed live fix / stop, so every location
    /// surface (conversation shares + the Map) can consume it. userInfo: share_id, from,
    /// ciphertext (update only).
    static let voiidLocationRelayUpdate = Notification.Name("voiidLocationRelayUpdate")
    static let voiidLocationRelayStop = Notification.Name("voiidLocationRelayStop")
    /// Posted by `LocationWire.decode` when a Feature (B) Map control message (`map_key` /
    /// `map_off`) is decrypted, so MapPresenceEngine can reconcile its in-memory view.
    /// The key itself is already written/erased in the Keychain by the decoder (that has to
    /// happen in the NSE too); this only carries the EFFECT. userInfo: kind, fromUserId,
    /// shareId — present on both kinds, since it is what identifies WHICH stream a later
    /// stop belongs to.
    static let voiidMapControlReceived = Notification.Name("voiidMapControlReceived")
}
