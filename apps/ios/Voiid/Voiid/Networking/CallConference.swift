//
//  CallConference.swift
//  Voiid
//
//  ADD A THIRD PERSON TO A LIVE 1:1 CALL — the client half. (repair plan §3.4, §3.5)
//
//  THE PRODUCT RULE THIS FILE EXISTS TO PROTECT
//  If the person you add is UNKNOWN to the other participant, that participant sees only
//  their `@username`. To contact them afterwards they must still go through the 6-digit
//  contact-PIN gate. **A SHARED CALL GRANTS NO MESSAGING RIGHTS.** That is the whole reason
//  this cannot be built by creating a group conversation — which is what the app's only
//  multi-party path does today, via a LiveKit room keyed on a group's MLS state. A group
//  conversation would hand the stranger a permanent messaging surface with both people.
//
//  STRUCTURAL RULE — NON-NEGOTIABLE
//  Nothing in the call path may write conversation tables. Every endpoint this file calls
//  (`/calls/:id/escalate|adhoc-token|join|leave|participants`) touches `call_participants`
//  and `calls` only. If a future change makes escalation create or mutate a conversation or
//  membership row, the contact-PIN gate in 020_reachability.sql is bypassed and the
//  requirement is violated. Do not add a "just create the conversation" shortcut here.
//
//  MAKE BEFORE BREAK (§3.4)
//  The 1:1 engine owns exactly one PeerConnection and the group engine owns a LiveKit room,
//  and the two are mutually exclusive BY AUDIO-SESSION DESIGN — two WebRTC builds, one
//  AVAudioSession. Escalation therefore runs three states:
//
//      CONNECTED ──escalate()──▶ ESCALATING ──both originals on the SFU──▶ CONFERENCE
//                                     │
//                                     └── SFU failed / timed out ──▶ back to CONNECTED
//
//  During ESCALATING **both legs are alive**: the 1:1 PeerConnection keeps carrying audio
//  while the SFU comes up, so the user never hears a gap. The 1:1 leg is hung up only after
//  BOTH ORIGINAL PARTICIPANTS are visible on the SFU. If the SFU never comes up we abandon
//  the upgrade and keep the working call — never drop live media to attempt an upgrade.
//
//  The audio-session handover is the genuinely hard part. During ESCALATING the LiveKit
//  engine is told NOT to touch AVAudioSession (`GroupCallService.deferAudioSession`), so
//  RTCAudioSession stays in charge of the route the user is currently hearing. Only once the
//  1:1 leg is torn down does the SFU leg take the session over.
//
//  IDENTITY (§3.5)
//  Rosters come from `GET /calls/:id/participants`, which returns `username` and state and
//  nothing else — deliberately NOT `GET /users/:id`, which hands `full_name` to any
//  authenticated caller and would leak a stranger's private-plane profile into a call.
//  Labels are resolved per viewer by `CallIdentity`: your saved name if you know them,
//  `@username` if you do not, "Unknown" if they have no username. NEVER a raw user id.
//

import Combine
import Foundation

// MARK: - Roster

/// One participant of an ad-hoc call, as returned by `GET /v1/calls/:id/participants`.
///
/// Hand-decoded with `try?` on every field. Swift `Codable` throws `keyNotFound` on an
/// absent key, and one missing field in one element would fail the decode of the WHOLE
/// roster array — turning a cosmetic server change into "the call has no participants".
struct CallRosterEntry: Decodable, Identifiable, Equatable {
    let userId: String
    /// The ONLY name the server will tell us about a stranger. May be null.
    let username: String?
    /// "invited" (ringing) or "joined". "left" is never returned.
    let state: String
    let invitedBy: String?
    let isSelf: Bool

    var id: String { userId }
    var isRinging: Bool { state == "invited" }

    private enum CodingKeys: String, CodingKey {
        case user_id, username, state, invited_by, is_self
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = (try? c.decode(String.self, forKey: .user_id)) ?? ""
        username = try? c.decode(String.self, forKey: .username)
        state = (try? c.decode(String.self, forKey: .state)) ?? "joined"
        invitedBy = try? c.decode(String.self, forKey: .invited_by)
        isSelf = (try? c.decode(Bool.self, forKey: .is_self)) ?? false
    }
}

// MARK: - Identity disclosure (§3.5)

/// How a call participant is labelled on THIS device.
///
/// The house rule is absolute: **a raw user id must never reach the screen.** Both group
/// rosters used to violate it — iOS showed the first six characters of the uuid — and that is
/// exactly the surface an added stranger lands on.
///
/// Resolution is deliberately LOCAL and per-viewer, so two participants can legitimately see
/// different labels for the same person (my "Mum" is your "@nehal"). The server asserts no
/// names at all: the LiveKit token carries no `name` claim, on purpose.
enum CallIdentity {

    /// "Known" means a relationship that already exists in the private plane:
    ///   • a SAVED CONTACT (their name came from this device's address book), or
    ///   • an accepted-conversation peer (we have a direct conversation with them).
    ///
    /// Merely appearing in `UserDirectory` is NOT enough — a row can be created by a profile
    /// fetch for someone you have never met, and treating that as "known" is what would let a
    /// stranger's `full_name` onto a call screen.
    static func isKnown(_ userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        if let saved = UserDirectory.shared.user(userId)?.savedName,
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return LocalStore.conversationId(forPeer: userId) != nil
    }

    /// The label for one participant.
    ///
    /// KNOWN     → the normal precedence chain (saved name wins, photo allowed elsewhere).
    /// UNKNOWN   → `@username` and nothing else: no full name, no photo, no phone.
    /// NO USERNAME → "Unknown". Never a uuid, never a uuid prefix.
    static func label(userId: String, username: String?, isSelf: Bool = false) -> String {
        if isSelf { return "You" }
        if isKnown(userId) {
            let resolved = UserDirectory.shared.displayName(userId)
            if resolved != "Unknown" { return resolved }
        }
        if let handle = username?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
            return handle.hasPrefix("@") ? handle : "@" + handle
        }
        return "Unknown"
    }

    static func label(for entry: CallRosterEntry) -> String {
        label(userId: entry.userId, username: entry.username, isSelf: entry.isSelf)
    }

    /// Label a LiveKit identity (`"<user_id>:<device_id>"`) with no roster to hand.
    ///
    /// Used by the MLS group-call grid, which had no roster endpoint and fell back to a
    /// uuid prefix. Falls back to the directory's username — still never to the id itself.
    static func label(identity: String, isLocal: Bool) -> String {
        if isLocal { return "You" }
        let userId = identity.split(separator: ":").first.map(String.init) ?? identity
        return label(userId: userId, username: UserDirectory.shared.user(userId)?.username)
    }

    /// Whether a photo may be shown for this participant. Unknown participants get an
    /// initials placeholder — a stranger's avatar is private-plane data.
    static func mayShowPhoto(_ userId: String) -> Bool { isKnown(userId) }
}

// MARK: - Escalation state

enum CallConferencePhase: Equatable {
    /// No conference activity. A plain 1:1 call (or no call at all).
    case idle
    /// We are the invitee and this device is ringing for a conference invite.
    case invited
    /// Both the 1:1 PeerConnection and the SFU room are alive. Make-before-break window.
    case escalating
    /// SFU only. The 1:1 leg is down and the call is a conference.
    case conference
}

@MainActor
final class CallConferenceService: ObservableObject {
    static let shared = CallConferenceService()

    // MARK: Published state

    @Published private(set) var phase: CallConferencePhase = .idle
    /// The call this conference belongs to — the SAME id as the 1:1 call it grew out of,
    /// and the same id every WS call frame carries.
    @Published private(set) var callId: String?
    @Published private(set) var roster: [CallRosterEntry] = []
    /// Set when the deployment has no LiveKit configured (backend 503). The UI must HIDE
    /// the add-person button rather than offer an action that cannot work.
    @Published private(set) var conferenceUnavailable = false
    /// A short, user-safe explanation of the last failure, or nil.
    @Published private(set) var lastError: String?
    /// Who invited us, while `phase == .invited`. Labelled through `CallIdentity`.
    @Published private(set) var inviterUserId: String?

    /// True while the add-person sheet should offer to escalate.
    var canEscalate: Bool {
        guard !conferenceUnavailable else { return false }
        guard let call = CallService.shared.active else { return false }
        return call.state == .connected && !call.isConferenceInvite
    }

    // MARK: Internals

    private let api = APIClient()
    /// The original 1:1 peer, remembered across the migration so we know when BOTH
    /// originals are on the SFU.
    private var originalPeerUserId: String?
    /// The room we are escalating into, from the server (never derived optimistically).
    private var room: String?
    private var livekitURL: String?
    private var adhocToken: String?
    /// Watches the SFU for the original peer's arrival; cancelled on completion/abort.
    private var handoverTask: Task<Void, Never>?
    /// Roster polling while a conference is up (there is no roster push frame).
    private var rosterTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var wired = false

    /// How long the SFU leg gets to come up before we abandon the upgrade and keep the
    /// perfectly good 1:1 call. Generous: a cold LiveKit connect on a bad network is slow,
    /// and the user is still talking the whole time.
    private static let handoverTimeout: Duration = .seconds(20)

    private init() {}

    // MARK: - Wiring

    /// Subscribe to the escalation frames. Call once at startup, next to
    /// `CallService.configure`. Every handler no-ops when there is no relevant call.
    func configure(socket: WebSocketClient) {
        guard !wired else { return }
        wired = true

        socket.onCallInvite = { [weak self] from, callId, room, kind, otherUserId in
            Task { @MainActor in
                self?.handleInvite(from: from, callId: callId, room: room,
                                   callKind: kind, otherUserId: otherUserId)
            }
        }
        socket.onCallMigrate = { [weak self] from, callId, room in
            Task { @MainActor in self?.handleMigrate(from: from, callId: callId, room: room) }
        }
        socket.onCallInviteAccept = { [weak self] _, callId in
            Task { @MainActor in self?.refreshRoster(callId: callId) }
        }
        socket.onCallInviteDecline = { [weak self] from, callId in
            Task { @MainActor in self?.handleInviteDeclined(from: from, callId: callId) }
        }
        socket.onCallKey = { from, callId, senderDeviceId, ciphertexts in
            Task { @MainActor in
                await CallKeyExchange.shared.handleInboundCallKey(
                    fromUserId: from, callId: callId,
                    senderDeviceId: senderDeviceId, ciphertexts: ciphertexts)
            }
        }
    }

    // MARK: - Inviter: escalate (§3.4)

    /// Add `inviteeUserId` to the live 1:1 call.
    ///
    /// Order matters and is deliberate:
    ///   1. `POST /calls/:id/escalate` — the server checks that we are live on the call AND
    ///      that we may reach the invitee (the 020 policy, reused verbatim), then pushes
    ///      them. It 503s BEFORE any write if LiveKit is unconfigured.
    ///   2. Mint and fan out a fresh CALL secret pairwise over the ratchet — the invitee
    ///      must never receive a conversation key.
    ///   3. Tell the current peer to migrate, and join the SFU ourselves, WITHOUT dropping
    ///      the 1:1 leg.
    ///
    /// Never throws. Every failure leaves the 1:1 call exactly as it was.
    func escalate(inviteeUserId: String) async {
        guard let call = CallService.shared.active, call.state == .connected else {
            lastError = "You can only add someone to a connected call."
            return
        }
        guard phase == .idle || phase == .escalating || phase == .conference else { return }
        guard !inviteeUserId.isEmpty, inviteeUserId != TokenStore.shared.userId else { return }

        let id = call.id
        lastError = nil

        struct Body: Encodable { let invitee_user_id: String }
        let response: EscalateResponse
        do {
            response = try await api.request("POST", "calls/\(id)/escalate",
                                             body: Body(invitee_user_id: inviteeUserId),
                                             as: EscalateResponse.self)
        } catch let APIError.http(status, message, _) {
            // 503 → this deployment has no SFU. Remember it so the button disappears rather
            // than failing again on every tap.
            if status == 503 { conferenceUnavailable = true }
            lastError = Self.userFacing(status: status, serverMessage: message)
            NSLog("[VOIID] escalate \(id) failed: \(status) \(message)")
            return
        } catch {
            lastError = "Couldn't add them to the call."
            return
        }

        conferenceUnavailable = false
        callId = id
        roster = response.participants ?? []
        room = response.room
        livekitURL = response.livekit_url
        originalPeerUserId = call.peerUserId.isEmpty ? nil : call.peerUserId

        // ── 2. Fresh CALL secret to every live participant, pairwise over the ratchet.
        //       Minted AFTER the server accepted the invite so we never rekey a call the
        //       invitee was not actually added to.
        await rekeyForCurrentRoster(callId: id)

        // ── 3. Tell the peer to come along. They keep 1:1 audio until SFU media flows.
        if let peer = originalPeerUserId, let room {
            WebSocketClient.shared.sendCallMigrate(toUserId: peer, callId: id, room: room)
            WebSocketClient.shared.sendCallInvite(toUserId: inviteeUserId, callId: id,
                                                  room: room,
                                                  callKind: call.isVideo ? "video" : "voice",
                                                  otherUserId: peer)
        }

        await enterEscalating(callId: id, isVideo: call.isVideo)
        startRosterPolling(callId: id)
    }

    /// Bring up the SFU leg while the 1:1 leg keeps running, then watch for the handover
    /// condition. This is the make-before-break window.
    private func enterEscalating(callId id: String, isVideo: Bool) async {
        phase = .escalating
        // The 1:1 engine must not tear the call down as a normal hangup while we migrate:
        // the `calls` row has to stay live or /join and /escalate would 409.
        CallService.shared.beginMigration(callId: id)

        guard await joinAdhocRoom(callId: id, isVideo: isVideo) else {
            abortEscalation(reason: "Couldn't connect to the conference.")
            return
        }
        startHandoverWatch(callId: id)
    }

    /// Fetch the ad-hoc token and connect LiveKit with the CALL key. Returns false if we
    /// could not — the caller keeps the 1:1 call.
    private func joinAdhocRoom(callId id: String, isVideo: Bool) async -> Bool {
        let auth: AdhocTokenResponse
        do {
            struct Empty: Encodable {}
            auth = try await api.request("POST", "calls/\(id)/adhoc-token",
                                         body: Empty(), as: AdhocTokenResponse.self)
        } catch let APIError.http(status, message, _) {
            if status == 503 { conferenceUnavailable = true }
            NSLog("[VOIID] adhoc-token \(id) failed: \(status) \(message)")
            return false
        } catch {
            return false
        }
        guard let url = auth.url, let token = auth.token else { return false }
        let roomName = auth.room ?? room ?? "voiid-call-\(id)"
        room = roomName
        livekitURL = url
        adhocToken = token

        // REFUSE TO JOIN WITHOUT A KEY. Both group clients already do this, and an ad-hoc
        // room is no different: connecting unkeyed would hand plaintext media to the SFU.
        guard let passphrase = CallKeyExchange.shared.passphrase(callId: id) else {
            NSLog("[VOIID] adhoc join refused for \(id): no call key")
            return false
        }
        return await GroupCallService.shared.joinAdhoc(callId: id, url: url, token: token,
                                                       room: roomName, passphrase: passphrase,
                                                       isVideo: isVideo,
                                                       deferAudioSession: phase == .escalating)
    }

    /// Watch the SFU until BOTH ORIGINAL PARTICIPANTS are on it, then drop the 1:1 leg.
    ///
    /// The invitee is deliberately not part of this condition: they may decline, or be
    /// asleep, and the two people already talking should not be held in a half-migrated
    /// state waiting for a third party who may never arrive.
    private func startHandoverWatch(callId id: String) {
        handoverTask?.cancel()
        handoverTask = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.handoverTimeout)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                guard self.phase == .escalating, self.callId == id else { return }

                // Our own SFU leg died — keep the 1:1 call rather than losing both.
                if case .failed = GroupCallService.shared.state {
                    self.abortEscalation(reason: "The conference connection failed.")
                    return
                }
                guard GroupCallService.shared.state == .connected else { continue }
                // A 1:1 call that ended underneath us (peer hung up) ends the escalation too.
                guard CallService.shared.active != nil else {
                    self.completeHandover(callId: id)
                    return
                }
                if self.peerIsOnSFU() {
                    self.completeHandover(callId: id)
                    return
                }
            }
            guard let self, !Task.isCancelled, self.phase == .escalating, self.callId == id else { return }
            // The peer never showed up on the SFU. That is NOT a reason to end anything: the
            // 1:1 leg is still carrying the conversation. Stay in the conference for the
            // invitee's sake but keep the 1:1 leg alive — the peer hears everything either way.
            NSLog("[VOIID] escalation handover timed out for \(id) — keeping the 1:1 leg up")
        }
    }

    /// Is the ORIGINAL peer publishing on the SFU yet? The LiveKit identity is
    /// `"<user_id>:<device_id>"`, so match on the user half.
    private func peerIsOnSFU() -> Bool {
        guard let peer = originalPeerUserId else { return true }   // nobody to wait for
        return GroupCallService.shared.participants.contains { !$0.isLocal && $0.userId == peer }
    }

    /// Both originals are on the SFU: break the 1:1 leg. This is the ONLY place that does.
    private func completeHandover(callId id: String) {
        handoverTask?.cancel(); handoverTask = nil
        guard phase == .escalating, callId == id else { return }
        NSLog("[VOIID] escalation \(id): both originals on the SFU — dropping the 1:1 leg")
        phase = .conference
        // Normal `call_hangup` to the peer — the relay's existing cleanup applies. The peer's
        // CallService recognises a hangup during migration and keeps the conference.
        CallService.shared.finishMigration(callId: id, notifyPeer: true)
        // Only now may the SFU own the audio route: the 1:1 engine has released it.
        GroupCallService.shared.adoptAudioSession()
    }

    /// The upgrade failed. Keep the 1:1 call exactly as it was — never drop working media to
    /// attempt an upgrade — and leave the ad-hoc room so nobody is stranded in it.
    private func abortEscalation(reason: String) {
        handoverTask?.cancel(); handoverTask = nil
        let id = callId
        NSLog("[VOIID] escalation aborted: \(reason)")
        lastError = reason
        phase = .idle
        Task {
            await GroupCallService.shared.leaveAdhoc()
            if let id { await postLeave(callId: id) }
        }
        if let id { CallService.shared.cancelMigration(callId: id) }
        stopRosterPolling()
    }

    // MARK: - Peer: inbound `call_migrate`

    /// The other side of our 1:1 call is escalating. Join the room but KEEP 1:1 audio until
    /// SFU media flows — the user must not hear a gap while someone is added.
    private func handleMigrate(from: String, callId id: String, room incomingRoom: String) {
        guard let call = CallService.shared.active, call.id == id else { return }
        guard phase == .idle else { return }
        NSLog("[VOIID] call \(id): peer is escalating — joining the SFU, keeping 1:1 audio")
        callId = id
        room = incomingRoom.isEmpty ? "voiid-call-\(id)" : incomingRoom
        originalPeerUserId = from.isEmpty ? (call.peerUserId.isEmpty ? nil : call.peerUserId) : from
        lastError = nil
        Task { [weak self] in
            guard let self else { return }
            // Wait for the inviter's call_key: joining unkeyed is not an option, and the key
            // frame and the migrate frame race on the wire.
            guard await self.awaitCallKey(callId: id) else {
                NSLog("[VOIID] call \(id): no call key arrived — staying on the 1:1 leg")
                return
            }
            await self.enterEscalating(callId: id, isVideo: call.isVideo)
            self.startRosterPolling(callId: id)
        }
    }

    /// Poll (briefly) for the pairwise-delivered call key. The `call_key` frame is not
    /// queued while the socket is down — a superseded key is worse than none — so a short
    /// wait here is what covers a reconnect racing the migrate frame.
    private func awaitCallKey(callId id: String, timeout: Duration = .seconds(8)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if CallKeyExchange.shared.hasKey(callId: id) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return CallKeyExchange.shared.hasKey(callId: id)
    }

    // MARK: - Invitee: inbound invite

    /// A `call_invite` arrived over the socket (the app was alive). The ring surface itself
    /// is CallService's — it owns CallKit — so this only records the conference context.
    ///
    /// A push-woken invitee gets here by a different route: the push carries a `call_id` and
    /// deliberately NO `conversation_id`, and that ABSENCE is the wire signal for "conference
    /// invite, take the ad-hoc path". See `CallService.reportIncomingCallFromVoIPPush`.
    private func handleInvite(from: String, callId id: String, room incomingRoom: String,
                              callKind: String, otherUserId: String) {
        // Already on this call (e.g. re-invited after a reconnect) — nothing to ring for.
        if phase == .conference || phase == .escalating, callId == id { return }
        callId = id
        room = incomingRoom.isEmpty ? "voiid-call-\(id)" : incomingRoom
        inviterUserId = from.isEmpty ? nil : from
        originalPeerUserId = otherUserId.isEmpty ? nil : otherUserId
        phase = .invited
        CallService.shared.reportConferenceInvite(callId: id, inviterUserId: from,
                                                  isVideo: callKind == "video")
    }

    /// Someone we invited said no. Their row is already gone server-side (decline is the
    /// leave path); just refresh so their tile disappears.
    private func handleInviteDeclined(from: String, callId id: String) {
        guard callId == id else { return }
        lastError = "\(CallIdentity.label(userId: from, username: rosterUsername(from))) declined."
        refreshRoster(callId: id)
    }

    /// The invitee accepted from the ring surface: token, join, connect, rekey.
    ///
    /// Returns false when we could not get in, so the caller can end the CallKit call
    /// instead of leaving a dead "connected" screen up.
    @discardableResult
    func acceptInvite() async -> Bool {
        guard let id = callId else { return false }
        guard let inviter = inviterUserId, !inviter.isEmpty else {
            // No inviter to accept to. Still legal — the push may have carried no caller id
            // — so proceed, we just cannot send the accept frame.
            return await joinAsInvitee(callId: id, inviter: nil)
        }
        WebSocketClient.shared.sendCallInviteAccept(toUserId: inviter, callId: id)
        return await joinAsInvitee(callId: id, inviter: inviter)
    }

    private func joinAsInvitee(callId id: String, inviter: String?) async -> Bool {
        let isVideo = CallService.shared.active?.isVideo ?? false
        // `POST /join` flips our row invited → joined and rewrites the relay grant. It is
        // ALSO the membership event the inviter hangs the rekey off, so it must precede the
        // key wait: the fresh secret is minted in response to this call.
        struct Empty: Encodable {}
        do {
            let joined: JoinResponse = try await api.request("POST", "calls/\(id)/join",
                                                             body: Empty(), as: JoinResponse.self)
            roster = joined.participants ?? []
            if let r = joined.room { room = r }
        } catch let APIError.http(status, message, _) {
            NSLog("[VOIID] join \(id) failed: \(status) \(message)")
            lastError = Self.userFacing(status: status, serverMessage: message)
            phase = .idle
            return false
        } catch {
            lastError = "Couldn't join the call."
            phase = .idle
            return false
        }

        guard await awaitCallKey(callId: id) else {
            NSLog("[VOIID] invitee \(id): no call key arrived — refusing to join unencrypted")
            lastError = "Secure keys for this call didn't arrive."
            phase = .idle
            await postLeave(callId: id)
            return false
        }
        // The invitee has no 1:1 leg, so there is nothing to make-before-break: the SFU may
        // own the audio session immediately.
        guard await joinAdhocRoom(callId: id, isVideo: isVideo) else {
            lastError = "Couldn't connect to the call."
            phase = .idle
            await postLeave(callId: id)
            return false
        }
        phase = .conference
        GroupCallService.shared.adoptAudioSession()
        startRosterPolling(callId: id)
        return true
    }

    /// Decline a conference invite. `POST /leave` IS the decline path server-side — one
    /// transition, one place that rewrites the relay grant.
    func declineInvite() async {
        guard let id = callId else { return }
        if let inviter = inviterUserId, !inviter.isEmpty {
            WebSocketClient.shared.sendCallInviteDecline(toUserId: inviter, callId: id)
        }
        await postLeave(callId: id)
        resetLocalState()
    }

    // MARK: - Leaving

    /// Leave the conference (the in-call hang-up button while `phase == .conference`).
    func leaveConference() async {
        guard let id = callId else { return }
        handoverTask?.cancel(); handoverTask = nil
        stopRosterPolling()
        await GroupCallService.shared.leaveAdhoc()
        await postLeave(callId: id)
        // The 1:1 leg may still be up if we abandoned the upgrade — end it properly.
        if CallService.shared.active?.id == id {
            CallService.shared.finishMigration(callId: id, notifyPeer: true)
        }
        resetLocalState()
    }

    /// `POST /calls/:id/leave` — idempotent by contract, so a teardown retry is always safe
    /// and a failure here can never strand the caller. Rewrites the relay grant WITHOUT us,
    /// which is what stops our frames being relayed the moment we go.
    private func postLeave(callId id: String) async {
        struct Empty: Encodable {}
        _ = try? await api.request("POST", "calls/\(id)/leave", body: Empty(), as: LeaveResponse.self)
        CallKeyExchange.shared.clear(callId: id)
    }

    private func resetLocalState() {
        phase = .idle
        callId = nil
        roster = []
        room = nil
        livekitURL = nil
        adhocToken = nil
        inviterUserId = nil
        originalPeerUserId = nil
        lastError = nil
    }

    /// Called by CallService when the underlying call ends by any route, so a stale
    /// conference cannot outlive it.
    func callEnded(callId id: String) {
        guard callId == id else { return }
        handoverTask?.cancel(); handoverTask = nil
        stopRosterPolling()
        CallKeyExchange.shared.clear(callId: id)
        if phase == .conference || phase == .escalating {
            Task { await GroupCallService.shared.leaveAdhoc() }
        }
        resetLocalState()
    }

    // MARK: - Rekey on membership change (§3.3 step 4)

    /// Mint a fresh secret and re-fan it to every live participant.
    ///
    /// Called on JOIN and on LEAVE. The rule is the inviter mints; if the inviter is gone,
    /// the LOWEST remaining user id does, so exactly one device rekeys and everyone converges.
    private func rekeyForCurrentRoster(callId id: String) async {
        let others = liveParticipantIds(excludingSelf: true)
        guard !others.isEmpty else { return }
        guard shouldMint() else { return }
        await CallKeyExchange.shared.mintAndDistribute(callId: id, to: others)
    }

    /// Are WE the one who mints this generation? The inviter is whoever `invited_by` names
    /// on the newest tile; with no roster to consult, fall back to the lowest live user id.
    private func shouldMint() -> Bool {
        guard let me = TokenStore.shared.userId else { return false }
        let inviters = roster.compactMap { $0.invitedBy }.filter { !$0.isEmpty }
        if let inviter = inviters.first {
            // The inviter still on the call mints; if they have left, fall through.
            if roster.contains(where: { $0.userId == inviter }) { return inviter == me }
        }
        let live = liveParticipantIds(excludingSelf: false).sorted()
        return live.first == me
    }

    private func liveParticipantIds(excludingSelf: Bool) -> [String] {
        let me = TokenStore.shared.userId
        var ids = roster.map { $0.userId }.filter { !$0.isEmpty }
        // Before the first roster fetch, the original pair is all we know.
        if ids.isEmpty {
            if let peer = originalPeerUserId { ids.append(peer) }
            if let me { ids.append(me) }
        }
        if excludingSelf, let me { ids.removeAll { $0 == me } }
        return Array(Set(ids))
    }

    // MARK: - Roster

    /// Refresh the roster and rekey if membership actually changed.
    ///
    /// There is no roster push frame, so this polls while a conference is up. The poll is
    /// slow (3s) because the roster is small and its only job is labelling tiles + deciding
    /// when to rekey — media state comes from LiveKit directly and is instant.
    private func startRosterPolling(callId id: String) {
        stopRosterPolling()
        rosterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.callId == id,
                      self.phase == .escalating || self.phase == .conference else { return }
                await self.pollRoster(callId: id)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopRosterPolling() {
        rosterTask?.cancel()
        rosterTask = nil
    }

    private func pollRoster(callId id: String) async {
        guard let fresh = try? await api.request("GET", "calls/\(id)/participants",
                                                 as: ParticipantsResponse.self) else { return }
        guard callId == id else { return }
        let next = fresh.participants ?? []
        let before = Set(roster.filter { $0.state == "joined" }.map { $0.userId })
        let after = Set(next.filter { $0.state == "joined" }.map { $0.userId })
        roster = next
        // MEMBERSHIP CHANGED → REKEY. Both directions: a joiner must not be able to decrypt
        // media sent before they arrived, and a leaver must not decrypt anything after.
        if before != after {
            await rekeyForCurrentRoster(callId: id)
        }
    }

    /// Force a roster refresh (used by the accept/decline frames).
    private func refreshRoster(callId id: String) {
        Task { await pollRoster(callId: id) }
    }

    private func rosterUsername(_ userId: String) -> String? {
        roster.first { $0.userId == userId }?.username
    }

    /// The label to show for a LiveKit identity in the conference grid — roster first (it is
    /// the only place a stranger's `@username` comes from), directory second, "Unknown" last.
    func displayName(forIdentity identity: String, isLocal: Bool) -> String {
        if isLocal { return "You" }
        let userId = identity.split(separator: ":").first.map(String.init) ?? identity
        if let entry = roster.first(where: { $0.userId == userId }) {
            return CallIdentity.label(for: entry)
        }
        return CallIdentity.label(identity: identity, isLocal: false)
    }

    // MARK: - Error mapping

    /// Server errors, translated. Deliberately does NOT distinguish "no such user" from
    /// "you may not add them": the backend returns an identical 403 for both precisely so the
    /// endpoint is not a user-id oracle, and repeating that distinction here would undo it.
    private static func userFacing(status: Int, serverMessage: String) -> String {
        switch status {
        case 403: return "You can't add this person to a call."
        case 404: return "That call has ended."
        case 409: return serverMessage.contains("at most")
            ? "This call is full."
            : "That call is no longer live."
        case 503: return "Conference calling isn't available on this server."
        default:  return "Couldn't add them to the call."
        }
    }
}

// MARK: - Wire responses
//
// EVERY field is optional. These are new endpoints, the app ships ahead of and behind the
// server, and Swift `Codable` throws `keyNotFound` on an absent key — a single missing
// field would turn a working escalation into a decode error.

private struct EscalateResponse: Decodable {
    struct Invitee: Decodable {
        let user_id: String?
        let username: String?
    }
    let call_id: String?
    let room: String?
    let livekit_url: String?
    let livekit_configured: Bool?
    let invitee: Invitee?
    let participants: [CallRosterEntry]?
    let ringing_devices: Int?
    let voip_devices: Int?
    let grant_ttl_seconds: Int?
}

private struct AdhocTokenResponse: Decodable {
    let url: String?
    let token: String?
    let room: String?
    let identity: String?
    let state: String?
    let ttl_seconds: Int?
}

private struct JoinResponse: Decodable {
    let call_id: String?
    let room: String?
    let state: String?
    let participant_count: Int?
    let participants: [CallRosterEntry]?
}

private struct LeaveResponse: Decodable {
    let call_id: String?
    let left: Bool?
    let was_participant: Bool?
    let participant_count: Int?
}

private struct ParticipantsResponse: Decodable {
    let call_id: String?
    let room: String?
    let call_kind: String?
    let status: String?
    let participants: [CallRosterEntry]?
}
