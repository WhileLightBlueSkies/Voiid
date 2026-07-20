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

    // MARK: Call-signaling senders

    func sendCallOffer(toUserId: String, callId: String, callKind: String, sdp: String) {
        sendJSON(["type": "call_offer", "to_user_id": toUserId, "call_id": callId,
                  "call_kind": callKind, "sdp": sdp])
    }
    func sendCallAnswer(toUserId: String, callId: String, sdp: String) {
        sendJSON(["type": "call_answer", "to_user_id": toUserId, "call_id": callId, "sdp": sdp])
    }
    func sendCallIce(toUserId: String, callId: String, candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        var frame: [String: Any] = [
            "type": "call_ice", "to_user_id": toUserId, "call_id": callId,
            "candidate": ["candidate": candidate, "sdpMLineIndex": sdpMLineIndex, "sdpMid": sdpMid ?? ""],
        ]
        if sdpMid == nil { (frame["candidate"] as? NSMutableDictionary)?.removeObject(forKey: "sdpMid") }
        sendJSON(frame)
    }
    func sendCallHangup(toUserId: String, callId: String) {
        sendJSON(["type": "call_hangup", "to_user_id": toUserId, "call_id": callId])
    }
    func sendCallBusy(toUserId: String, callId: String) {
        sendJSON(["type": "call_busy", "to_user_id": toUserId, "call_id": callId])
    }
    func sendCallDecline(toUserId: String, callId: String) {
        sendJSON(["type": "call_decline", "to_user_id": toUserId, "call_id": callId])
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
        heartbeat?.invalidate(); heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil; connected = false
    }

    /// Force a fresh socket — call when the chats screen appears / app foregrounds.
    /// URLSessionWebSocketTask doesn't always fire its failure handler on a silent
    /// network drop, so `connected` can be stuck true on a dead socket and we'd miss
    /// pushes. Tearing down + reconnecting guarantees a live connection.
    func reconnect() {
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

    // MARK: - Internals

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let err):
                    NSLog("[VOIID] WS disconnected: \(err.localizedDescription) — reconnecting")
                    self.connected = false
                    // simple reconnect after a short delay
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.connect()
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receiveLoop()
                }
            }
        }
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
        default: break   // "connected" etc.
        }
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendJSON(["type": "heartbeat"]) }
        }
    }
}
