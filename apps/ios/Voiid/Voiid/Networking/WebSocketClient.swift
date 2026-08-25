//
//  WebSocketClient.swift
//  Voiid
//
//  Realtime connection to the backend WS relay (wss://…/ws?token=JWT).
//  The server pushes only *references* — {type:"message", message_id,
//  conversation_id} and {type:"typing", …} — so on a message ref we tell the
//  app to fetch+decrypt that conversation. Also sends heartbeat + typing frames.
//

import Foundation

@MainActor
final class WebSocketClient {
    static let shared = WebSocketClient()
    private init() {}

    private var task: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var connected = false

    // MARK: - Liveness + outbound queue
    //
    // A call must survive a signaling blip. Media (SRTP) keeps flowing over the
    // peer connection while this socket is down, so the only thing that actually
    // breaks is *new* signaling — trickle ICE above all. Dropping those on the
    // floor is what turns a 2-second socket hiccup into a failed call, so
    // call-signaling frames are queued and flushed in order once we're live.

    /// True once a frame has actually been received on the current socket —
    /// `connected` only means "we called resume()", which is not the same thing.
    private(set) var isLive = false
    /// Notified (main actor) when liveness flips. CallService uses this to flush
    /// anything it deferred and to know a mid-call restart offer can be sent.
    var onLivenessChange: ((_ isLive: Bool) -> Void)?

    /// Call-signaling frames buffered while the socket was down, oldest first.
    private var outboundQueue: [[String: Any]] = []
    /// Bounded so a long outage can't grow this without limit. ICE candidates are
    /// small and the newest ones matter most, so we drop from the front.
    private static let maxQueuedFrames = 128

    /// Consecutive failed connection attempts, for exponential backoff.
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?

    /// Called when a new message arrives for a conversation (id). The app should
    /// fetch + decrypt that conversation.
    var onMessageRef: ((_ conversationId: String) -> Void)?
    /// Typing updates: conversationId, fromUserId, isTyping.
    var onTyping: ((_ conversationId: String, _ userId: String, _ isTyping: Bool) -> Void)?
    /// Receipt for one of OUR sent messages: messageId, status ("delivered"|"read").
    var onReceipt: ((_ messageId: String, _ status: String) -> Void)?
    /// Peer couldn't decrypt our message → reset (re-establish) the session for this conversation.
    var onSessionReset: ((_ conversationId: String) -> Void)?
    /// An MLS group control event (Welcome/Commit) is waiting → fetch + process group events.
    var onGroupEvent: ((_ conversationId: String) -> Void)?

    // MARK: - Location fix relay (P3, ephemeral — never a message row, never a push)
    //
    // Deliberately generic (share_id / from_user_id / opaque ciphertext) so BOTH location
    // features share this one routing point: the Map (Feature B) and in-conversation live
    // sharing (Feature A) each subscribe from their own engine. `ciphertext` is an opaque
    // base64 string this client copies and NEVER parses — the coordinate is sealed under a
    // per-share key the server (and this relay) cannot read.
    /// One encrypted position fix for a share. (shareId, fromUserId, ciphertext-b64)
    var onLocationUpdate: ((_ shareId: String, _ fromUserId: String, _ ciphertext: String) -> Void)?
    /// A share was stopped (instant effect on live sockets). (shareId, fromUserId, kind, reason)
    ///
    /// `kind` ("map" / "conversation") and `reason` ("ended" / "superseded") are only present
    /// on a stop the API published; a stop relayed straight from another client carries
    /// neither, so both arrive as "" and a subscriber must fall back to its own bookkeeping.
    /// `superseded` in particular is NOT "the sharer went dark" — it means they replaced the
    /// row, and erasing their key or cached position there is the pin-blink bug.
    var onLocationStop: ((_ shareId: String, _ fromUserId: String, _ kind: String, _ reason: String) -> Void)?

    // MARK: - 1:1 call signaling (relayed over the same WS)
    // Each inbound frame is stamped server-side with `from_user_id` (authenticated).
    /// Inbound SDP offer for a new incoming call. (fromUserId, callId, callKind, sdp)
    var onCallOffer: ((_ fromUserId: String, _ callId: String, _ callKind: String, _ sdp: String) -> Void)?
    /// Inbound SDP answer to our outgoing call. (fromUserId, callId, sdp)
    var onCallAnswer: ((_ fromUserId: String, _ callId: String, _ sdp: String) -> Void)?
    /// Inbound trickle ICE candidate. (fromUserId, callId, candidate, sdpMLineIndex, sdpMid)
    var onCallIce: ((_ fromUserId: String, _ callId: String, _ candidate: String, _ sdpMLineIndex: Int32, _ sdpMid: String?) -> Void)?
    /// Peer hung up / call ended. (fromUserId, callId)
    var onCallHangup: ((_ fromUserId: String, _ callId: String) -> Void)?
    /// Peer is busy in another call. (fromUserId, callId)
    var onCallBusy: ((_ fromUserId: String, _ callId: String) -> Void)?
    /// Peer declined the incoming call. (fromUserId, callId)
    var onCallDecline: ((_ fromUserId: String, _ callId: String) -> Void)?
    /// The callee's device has actually started alerting — this is what tells the
    /// CALLER it may start its ringback tone. Deliberately distinct from "we sent
    /// the offer": a phone that never rang must never produce ringback.
    /// (fromUserId, callId)
    var onCallRinging: ((_ fromUserId: String, _ callId: String) -> Void)?
    /// ANOTHER OF OUR OWN DEVICES answered or declined this incoming call, so this
    /// one must stop ringing. Relayed to the sender's own channel by the WS server —
    /// every other call frame goes only to the far side, which is why a second device
    /// used to keep ringing until the caller gave up. (callId, "answer" | "decline")
    var onCallTaken: ((_ callId: String, _ reason: String) -> Void)?
    /// Peer put the call on hold. (fromUserId, callId)
    var onCallHold: ((_ fromUserId: String, _ callId: String) -> Void)?
    /// Peer took the call off hold. (fromUserId, callId)
    var onCallUnhold: ((_ fromUserId: String, _ callId: String) -> Void)?

    // MARK: - Conference escalation frames (docs/research/02_conference_1to1.md §4.1)
    //
    // Five frames added for "add a third person to a live 1:1". They are relayed with the
    // same discipline as the nine above — unicast `to_user_id`, `from_user_id` stamped from
    // the socket JWT, never logged — and they carry NO conversation id, because an invited
    // stranger is not a member of the call's conversation and must never be handed its id.
    // A shared call grants no messaging rights (020/029): none of these frames creates one.

    /// The inviter is adding us to a live call. (fromUserId, callId, room, callKind, otherUserId)
    ///
    /// `otherUserId` is the ORIGINAL peer — supplied so the invitee's roster is complete
    /// before it has a token; it may be empty and every reader must tolerate that.
    var onCallInvite: ((_ fromUserId: String, _ callId: String, _ room: String,
                        _ callKind: String, _ otherUserId: String) -> Void)?
    /// The invitee accepted. (fromUserId, callId)
    var onCallInviteAccept: ((_ fromUserId: String, _ callId: String) -> Void)?
    /// The invitee declined. (fromUserId, callId)
    var onCallInviteDecline: ((_ fromUserId: String, _ callId: String) -> Void)?
    /// The inviter is escalating: connect to the SFU room, but KEEP 1:1 media running
    /// until it is up (make-before-break). (fromUserId, callId, room)
    var onCallMigrate: ((_ fromUserId: String, _ callId: String, _ room: String) -> Void)?
    /// Opaque pairwise-ratchet ciphertext carrying a call secret. The relay applies the same
    /// base64-only structural check it applies to location payloads and can never read this.
    /// (fromUserId, callId, senderDeviceId, ciphertexts keyed by RECIPIENT device id)
    var onCallKey: ((_ fromUserId: String, _ callId: String, _ senderDeviceId: String?,
                     _ ciphertexts: [String: String]) -> Void)?

    // MARK: Call-signaling senders

    // All of these pass `queueIfDown: true` — see the outbound-queue note above.

    func sendCallOffer(toUserId: String, callId: String, callKind: String, sdp: String) {
        sendJSON(["type": "call_offer", "to_user_id": toUserId, "call_id": callId,
                  "call_kind": callKind, "sdp": sdp], queueIfDown: true)
    }
    func sendCallAnswer(toUserId: String, callId: String, sdp: String) {
        sendJSON(["type": "call_answer", "to_user_id": toUserId, "call_id": callId, "sdp": sdp],
                 queueIfDown: true)
    }
    func sendCallIce(toUserId: String, callId: String, candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        var candidateBody: [String: Any] = ["candidate": candidate, "sdpMLineIndex": sdpMLineIndex]
        if let sdpMid, !sdpMid.isEmpty { candidateBody["sdpMid"] = sdpMid }
        sendJSON(["type": "call_ice", "to_user_id": toUserId, "call_id": callId,
                  "candidate": candidateBody], queueIfDown: true)
    }
    func sendCallHangup(toUserId: String, callId: String) {
        sendJSON(["type": "call_hangup", "to_user_id": toUserId, "call_id": callId], queueIfDown: true)
    }
    func sendCallBusy(toUserId: String, callId: String) {
        sendJSON(["type": "call_busy", "to_user_id": toUserId, "call_id": callId], queueIfDown: true)
    }
    func sendCallDecline(toUserId: String, callId: String) {
        sendJSON(["type": "call_decline", "to_user_id": toUserId, "call_id": callId], queueIfDown: true)
    }
    /// Sent by the CALLEE the moment its device starts alerting (i.e. when we
    /// report the incoming call to CallKit), so the caller can start ringback.
    func sendCallRinging(toUserId: String, callId: String) {
        sendJSON(["type": "call_ringing", "to_user_id": toUserId, "call_id": callId], queueIfDown: true)
    }
    func sendCallHold(toUserId: String, callId: String) {
        sendJSON(["type": "call_hold", "to_user_id": toUserId, "call_id": callId], queueIfDown: true)
    }
    func sendCallUnhold(toUserId: String, callId: String) {
        sendJSON(["type": "call_unhold", "to_user_id": toUserId, "call_id": callId], queueIfDown: true)
    }

    // MARK: Conference escalation senders

    /// Tell the invitee a live call is being opened to them. Queued while down: the invite
    /// is the invitee's only in-app signal when the push is what woke them.
    func sendCallInvite(toUserId: String, callId: String, room: String,
                        callKind: String, otherUserId: String) {
        var frame: [String: Any] = ["type": "call_invite", "to_user_id": toUserId,
                                    "call_id": callId, "room": room, "call_kind": callKind]
        if !otherUserId.isEmpty { frame["other_user_id"] = otherUserId }
        sendJSON(frame, queueIfDown: true)
    }
    func sendCallInviteAccept(toUserId: String, callId: String) {
        sendJSON(["type": "call_invite_accept", "to_user_id": toUserId, "call_id": callId],
                 queueIfDown: true)
    }
    func sendCallInviteDecline(toUserId: String, callId: String) {
        sendJSON(["type": "call_invite_decline", "to_user_id": toUserId, "call_id": callId],
                 queueIfDown: true)
    }
    /// "I am escalating this call — join the room, keep 1:1 audio until SFU media flows."
    func sendCallMigrate(toUserId: String, callId: String, room: String) {
        sendJSON(["type": "call_migrate", "to_user_id": toUserId, "call_id": callId, "room": room],
                 queueIfDown: true)
    }
    /// One recipient's pairwise-encrypted copies of a call secret. `ciphertexts` is keyed by
    /// the RECIPIENT's device id; every value is base64 the relay must treat as opaque.
    ///
    /// `queueIfDown: false`, deliberately unlike the other call frames: a call key is only
    /// valid for the membership generation that produced it, and the rekey is re-fanned on
    /// the next join/leave. Delivering a superseded key out of a queue is worse than not
    /// delivering it — the receiver would install a key nobody is encrypting with.
    func sendCallKey(toUserId: String, callId: String, senderDeviceId: String?,
                     ciphertexts: [String: String]) {
        guard !ciphertexts.isEmpty else { return }
        var frame: [String: Any] = [
            "type": "call_key", "to_user_id": toUserId, "call_id": callId,
            "ciphertexts": ciphertexts.map { ["device_id": $0.key, "body": $0.value] },
        ]
        if let senderDeviceId, !senderDeviceId.isEmpty { frame["sender_device_id"] = senderDeviceId }
        sendJSON(frame)
    }

    func connect() {
        guard !connected, let jwt = TokenStore.shared.jwt else {
            NSLog("[VOIID] WS connect skipped (connected=\(connected) hasJWT=\(TokenStore.shared.jwt != nil))")
            return
        }
        var comps = URLComponents(url: APIConfig.wsURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "token", value: jwt)]
        guard let url = comps?.url else { return }

        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        connected = true
        NSLog("[VOIID] WS connecting → \(url.host ?? "")")
        receiveLoop()
        startHeartbeat()
    }

    func disconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        heartbeat?.invalidate(); heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil; connected = false
        setLive(false)
    }

    /// Force a fresh socket — call when the chats screen appears / app foregrounds.
    /// URLSessionWebSocketTask doesn't always fire its failure handler on a silent
    /// network drop, so `connected` can be stuck true on a dead socket and we'd miss
    /// pushes. Tearing down + reconnecting guarantees a live connection.
    func reconnect() {
        reconnectAttempts = 0
        disconnect()
        connect()
    }

    func sendTyping(conversationId: String, recipientIds: [String], isStart: Bool) {
        let frame: [String: Any] = [
            "type": "typing", "conversation_id": conversationId,
            "recipient_ids": recipientIds, "state": isStart ? "start" : "stop",
        ]
        sendJSON(frame)
    }

    /// Ask the message's sender to re-establish the E2E session (we couldn't decrypt).
    func sendSessionReset(conversationId: String, recipientIds: [String]) {
        sendJSON(["type": "session_reset", "conversation_id": conversationId, "recipient_ids": recipientIds])
    }

    /// Relay one encrypted position fix to the audience. The client supplies
    /// `recipient_ids` because the WS process has no database (same shape as `typing`);
    /// the server stamps `from_user_id` from the JWT and never echoes client extras. Not
    /// queued while down: a stale fix is worthless, so a dropped frame is simply the next
    /// cadence tick's problem.
    func sendLocationUpdate(shareId: String, recipientIds: [String], ciphertext: String) {
        sendJSON(["type": "loc_update", "share_id": shareId,
                  "recipient_ids": recipientIds, "ciphertext": ciphertext])
    }

    /// Stop a share for instant effect on live sockets. The durable stop (the guarantee that
    /// reaches an offline recipient) rides the message path separately.
    func sendLocationStop(shareId: String, recipientIds: [String]) {
        sendJSON(["type": "loc_stop", "share_id": shareId, "recipient_ids": recipientIds])
    }

    /// Submit one game move (docs/GAMES.md §6).
    ///
    /// Unlike `loc_update` there are no `recipient_ids`: the relay forwards this to
    /// backend/games, which knows the match roster and answers the players itself. The
    /// payload is small, readable game state — games are the one surface where the server
    /// is the referee and must read what it relays.
    ///
    /// `queueIfDown: true`, deliberately unlike location: a stale position is worthless,
    /// but a move is the player's actual intent. Dropping it silently would look like the
    /// tap never registered, so a move made in a reconnect window is delivered on
    /// reattach. The server rejects it if the match has moved on.
    func sendGameInput(matchId: String, payload: [String: Any]) {
        sendJSON(["type": "game_input", "match_id": matchId, "payload": payload],
                 queueIfDown: true)
    }

    // MARK: - Internals

    private func receiveLoop() {
        // Capture the task this loop belongs to. Without this, a loop belonging to
        // an already-replaced socket can fire late and schedule a reconnect that
        // tears down the *current* healthy connection.
        let owner = task
        owner?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === owner else { return }
                switch result {
                case .failure(let err):
                    NSLog("[VOIID] WS disconnected: \(err.localizedDescription) — reconnecting")
                    self.connected = false
                    self.setLive(false)
                    self.scheduleReconnect()
                case .success(let message):
                    // First frame on this socket proves it's actually usable.
                    if !self.isLive {
                        self.reconnectAttempts = 0
                        self.setLive(true)
                        self.flushOutboundQueue()
                    }
                    if case .string(let text) = message { self.handle(text) }
                    self.receiveLoop()
                }
            }
        }
    }

    /// Exponential backoff, capped. Prevents a hard-down backend from turning
    /// every client into a retry storm, while still recovering in ~1s for the
    /// common case of a brief handover.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let attempt = reconnectAttempts
        reconnectAttempts = min(reconnectAttempts + 1, 6)
        // 1s, 2s, 4s, 8s, 16s, 30s, 30s…
        let delay = min(pow(2.0, Double(attempt)), 30.0)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            NSLog("[VOIID] WS reconnect attempt \(attempt + 1) after \(delay)s")
            self.connect()
        }
    }

    private func setLive(_ live: Bool) {
        guard isLive != live else { return }
        isLive = live
        onLivenessChange?(live)
    }

    /// Replay queued call-signaling frames in the order they were produced.
    /// Order matters: an ICE candidate applied before its offer is discarded by
    /// the peer, and a hangup must not overtake the answer it follows.
    private func flushOutboundQueue() {
        guard !outboundQueue.isEmpty else { return }
        let pending = outboundQueue
        outboundQueue.removeAll()
        NSLog("[VOIID] WS flushing \(pending.count) queued signaling frame(s)")
        for frame in pending { sendJSON(frame, queueIfDown: false) }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        NSLog("[VOIID] WS recv type=\(type)")
        switch type {
        case "message":
            if let cid = obj["conversation_id"] as? String { onMessageRef?(cid) }
        case "typing":
            if let cid = obj["conversation_id"] as? String,
               let uid = obj["user_id"] as? String {
                onTyping?(cid, uid, (obj["state"] as? String) == "start")
            }
        case "receipt":
            if let mid = obj["message_id"] as? String,
               let status = obj["status"] as? String {
                onReceipt?(mid, status)
            }
        case "session_reset":
            if let cid = obj["conversation_id"] as? String { onSessionReset?(cid) }
        case "mls_event":
            if let cid = obj["conversation_id"] as? String { onGroupEvent?(cid) }
        case "loc_update":
            // Opaque relay: copy the ciphertext, never parse it. Sender is server-stamped.
            if let sid = obj["share_id"] as? String,
               let from = obj["from_user_id"] as? String,
               let ct = obj["ciphertext"] as? String {
                onLocationUpdate?(sid, from, ct)
                // Additionally fan out to any other location surface (conversation shares
                // AND the Map) — a single closure would starve one of them, and each drops
                // share_ids it doesn't own, so broadcasting is safe.
                NotificationCenter.default.post(name: .voiidLocationRelayUpdate, object: nil,
                    userInfo: ["share_id": sid, "from": from, "ciphertext": ct])
            }
        case "loc_stop":
            if let sid = obj["share_id"] as? String,
               let from = obj["from_user_id"] as? String {
                // Absent on a client-relayed stop — see `onLocationStop`.
                let kind = (obj["kind"] as? String) ?? ""
                let reason = (obj["reason"] as? String) ?? ""
                onLocationStop?(sid, from, kind, reason)
                NotificationCenter.default.post(name: .voiidLocationRelayStop, object: nil,
                    userInfo: ["share_id": sid, "from": from, "kind": kind, "reason": reason])
            }
        case "game_state":
            // Full authoritative state for one match. NotificationCenter rather than a
            // closure, mirroring the story/loc precedent: whichever game screen is open
            // picks it up, and one that isn't open simply ignores it — no wiring at the
            // WS setup site, and no closure to starve when several surfaces care.
            if let mid = obj["match_id"] as? String,
               let payload = obj["payload"] as? [String: Any] {
                NotificationCenter.default.post(name: .voiidGameState, object: nil,
                    userInfo: ["match_id": mid,
                               "game": (obj["game"] as? String) ?? "",
                               "seq": (obj["seq"] as? Int) ?? 0,
                               "payload": payload])
            }
        case "game_lobby_update", "game_lobby_message":
            // The party lobby's live channel (backend/api routes/games.ts, the lobby block).
            // Relayed WHOLE and unparsed, for the same reason `game_state` is: whichever lobby
            // screen is open decodes it against the same typed models the REST call uses, and
            // a screen that is not open ignores it. Parsing the roster here would put a second
            // decoder for the same payload in a file that knows nothing about lobbies.
            //
            // `game_lobby_update` carries the full roster rather than a delta, so a screen that
            // missed a frame is corrected by the next one instead of drifting.
            if let mid = obj["match_id"] as? String {
                NotificationCenter.default.post(name: .voiidGameLobbyEvent, object: nil,
                    userInfo: ["type": type, "match_id": mid, "frame": obj])
            }
        case "story", "story_receipt", "story_deleted":
            // Routing signals only — a device's story ciphertext is NEVER on this channel
            // (§7.10). Wake StoryEngine, which pulls its own blobs from GET /stories/feed.
            // NotificationCenter (not a new closure) mirrors the loc_* precedent above so
            // no extra wiring is needed at the WS setup site.
            NotificationCenter.default.post(name: .voiidStorySignal, object: nil,
                userInfo: ["type": type, "story_id": (obj["story_id"] as? String) ?? ""])
        case "call_offer":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String,
               let sdp = obj["sdp"] as? String {
                onCallOffer?(from, cid, (obj["call_kind"] as? String) ?? "voice", sdp)
            }
        case "call_answer":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String,
               let sdp = obj["sdp"] as? String {
                onCallAnswer?(from, cid, sdp)
            }
        case "call_ice":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String {
                // The candidate may arrive as a nested object or flat fields.
                let cand = obj["candidate"] as? [String: Any] ?? obj
                if let sdpStr = cand["candidate"] as? String {
                    let idx = (cand["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
                    let mid = cand["sdpMid"] as? String
                    onCallIce?(from, cid, sdpStr, idx, (mid?.isEmpty == true) ? nil : mid)
                }
            }
        case "call_hangup":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String { onCallHangup?(from, cid) }
        case "call_busy":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String { onCallBusy?(from, cid) }
        case "call_decline":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String { onCallDecline?(from, cid) }
        case "call_ringing":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String { onCallRinging?(from, cid) }
        case "call_taken":
            if let cid = obj["call_id"] as? String {
                onCallTaken?(cid, (obj["reason"] as? String) ?? "answer")
            }
        // ── Conference escalation. EVERY field except type/from/call_id is optional here:
        // these frames are new, the relay is deployed separately, and an older relay that
        // rebuilds outbound frames from its own field list will drop whatever it does not
        // know about. A missing `room` is recoverable (the client derives it from the
        // call_id); a hard `guard` on it would silently break escalation against a relay
        // that is otherwise working.
        case "call_invite":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String {
                onCallInvite?(from, cid,
                              (obj["room"] as? String) ?? "",
                              (obj["call_kind"] as? String) ?? "voice",
                              (obj["other_user_id"] as? String) ?? "")
            }
        case "call_invite_accept":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String {
                onCallInviteAccept?(from, cid)
            }
        case "call_invite_decline":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String {
                onCallInviteDecline?(from, cid)
            }
        case "call_migrate":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String {
                onCallMigrate?(from, cid, (obj["room"] as? String) ?? "")
            }
        case "call_key":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String {
                // Accept both shapes: the documented array of {device_id, body}, and a plain
                // {device_id: body} map, so a relay that normalises one into the other cannot
                // strand a rekey. The bodies are opaque base64 — never parsed here.
                var byDevice: [String: String] = [:]
                if let arr = obj["ciphertexts"] as? [[String: Any]] {
                    for entry in arr {
                        if let dev = entry["device_id"] as? String, let body = entry["body"] as? String {
                            byDevice[dev] = body
                        }
                    }
                } else if let map = obj["ciphertexts"] as? [String: String] {
                    byDevice = map
                }
                if !byDevice.isEmpty {
                    onCallKey?(from, cid, obj["sender_device_id"] as? String, byDevice)
                }
            }
        case "call_hold":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String { onCallHold?(from, cid) }
        case "call_unhold":
            if let from = obj["from_user_id"] as? String, let cid = obj["call_id"] as? String { onCallUnhold?(from, cid) }
        default: break   // "connected" etc.
        }
    }

    private func sendJSON(_ obj: [String: Any], queueIfDown: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }

        // Send optimistically as soon as the socket is resumed — waiting for
        // `isLive` (which needs an inbound frame) would stall the heartbeat that
        // helps prove liveness in the first place. A write that genuinely fails
        // is re-queued below.
        guard let task, connected else {
            if queueIfDown { enqueue(obj) }
            return
        }
        task.send(.string(s)) { [weak self] err in
            guard let err else { return }
            NSLog("[VOIID] WS send failed: \(err.localizedDescription)")
            guard queueIfDown else { return }
            // The socket looked live but the write lost — re-queue so the frame
            // rides the next connection instead of vanishing.
            Task { @MainActor in
                self?.setLive(false)
                self?.enqueue(obj)
            }
        }
    }

    private func enqueue(_ frame: [String: Any]) {
        // GAME INPUT IS COALESCED, NOT APPENDED. Every other queued frame here is a discrete
        // event with its own identity (a message, an ICE candidate, a call signal) and losing
        // one is losing something real. A steering frame is a POSITION: the newest one fully
        // supersedes every older one for the same match, so queuing them as a growing backlog
        // is queuing garbage.
        //
        // Two failures came from treating it like the others. First, the queue is shared and
        // bounded at 128 slots, dropping from the FRONT — a ~9 second network blip at Snake's
        // 10-15 frames/sec fills it completely, which means stale headings were evicting
        // queued messages, call offers and ICE candidates to make room for themselves. Second,
        // on reconnect the whole backlog flushed as one burst, instantly spending an entire
        // rate-limit window (docs/GAMES_SNAKE_BUGS.md Part A) and blacking out controls again
        // right as the player regained connectivity — a brief blip was enough to retrigger the
        // freeze on its own.
        //
        // Replacing the prior queued input for the SAME match fixes both: the queue can never
        // grow from steering, so it never evicts anything else, and reconnect replays exactly
        // one heading instead of a burst of stale ones.
        if frame["type"] as? String == "game_input",
           let matchId = frame["match_id"] as? String,
           let idx = outboundQueue.firstIndex(where: {
               $0["type"] as? String == "game_input" && $0["match_id"] as? String == matchId
           }) {
            outboundQueue[idx] = frame
            return
        }

        outboundQueue.append(frame)
        if outboundQueue.count > Self.maxQueuedFrames {
            outboundQueue.removeFirst(outboundQueue.count - Self.maxQueuedFrames)
        }
    }

    /// Drop anything still queued for a call that's over — no point replaying
    /// ICE for a torn-down peer connection after a long outage.
    func dropQueuedFrames(forCallId callId: String) {
        outboundQueue.removeAll { ($0["call_id"] as? String) == callId }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendJSON(["type": "heartbeat"]) }
        }
    }
}
