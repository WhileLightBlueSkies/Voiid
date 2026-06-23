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

    func sendTyping(conversationId: String, recipientIds: [String], isStart: Bool) {
        let frame: [String: Any] = [
            "type": "typing", "conversation_id": conversationId,
            "recipient_ids": recipientIds, "state": isStart ? "start" : "stop",
        ]
        sendJSON(frame)
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
