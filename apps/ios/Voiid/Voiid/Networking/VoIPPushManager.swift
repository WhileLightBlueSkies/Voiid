//
//  VoIPPushManager.swift
//  Voiid
//
//  PushKit VoIP push. A normal alert push is delivered best-effort — a killed or
//  long-backgrounded app misses the ring entirely. A VoIP push is delivered with
//  high priority and *wakes the app*, which is why every serious calling app
//  (Signal, WhatsApp) rings off PushKit rather than APNs alerts.
//
//  The hard iOS contract: inside `didReceiveIncomingPushWith` we MUST call
//  `CXProvider.reportNewIncomingCall` and only then `completion()`. If we don't,
//  iOS kills the app and, after repeated offences, stops delivering VoIP pushes to
//  it altogether. So this file does exactly one thing on push: report the call to
//  CallKit (via CallService → CallManager) and complete. All the real work — SDP,
//  ICE, media — still happens over the WebSocket once the app is awake.
//
//  The push payload carries ROUTING METADATA ONLY (call_id / caller_id /
//  conversation_id / call_kind). Never SDP, never message content — APNs sees it.
//
//  RUNTIME CAVEAT: VoIP pushes need a separate APNs VoIP key and the
//  `<bundle-id>.voip` topic, and are only delivered to a SIGNED build on real
//  hardware. In the simulator this compiles and the state machine runs, but no
//  push will ever arrive. See docs at the bottom of this file.
//

import Foundation
import PushKit
import UIKit

/// Owns the `PKPushRegistry` and the VoIP-token upload to the backend.
final class VoIPPushManager: NSObject {
    static let shared = VoIPPushManager()

    private var registry: PKPushRegistry?
    private let api = APIClient()

    /// Current VoIP token as lowercase hex, persisted so we can re-upload after a
    /// login without waiting for PushKit to hand us the credentials again (it only
    /// re-fires `didUpdate` when the token actually changes).
    private(set) var voipToken: String? {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenKey) }
    }
    /// The (token, deviceId) pair we last successfully uploaded — skip no-op posts.
    private var lastUploaded: String?

    private static let tokenKey = "voiid.voip_token"

    private override init() { super.init() }

    /// Create the registry and start receiving VoIP pushes. Safe to call twice.
    /// Must run on the main thread — we pass `.main` as the callback queue so the
    /// delegate callbacks are already on the main actor (see `assumeIsolated` below).
    func start() {
        guard registry == nil else { return }
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        registry = r
        NSLog("[VOIID] PushKit VoIP registry started")
        // We may already have a token from a previous launch but no JWT at the time.
        uploadTokenIfNeeded()
    }

    /// Upload the VoIP token to the backend. No-ops when we have no token yet, no
    /// JWT (not signed in), or no device id (E2E not provisioned) — call it again
    /// after login, which `Stores` does. Retries a few times on transport failure.
    func uploadTokenIfNeeded(force: Bool = false) {
        guard let token = voipToken else { return }
        guard TokenStore.shared.jwt != nil else { return }
        guard let deviceId = E2EManager.shared.deviceId else { return }
        let key = "\(deviceId):\(token)"
        if !force, lastUploaded == key { return }

        Task { [api] in
            struct Body: Encodable { let device_id: String; let voip_token: String }
            let body = Body(device_id: deviceId, voip_token: token)
            for attempt in 0..<3 {
                do {
                    _ = try await api.request("POST", "devices/voip-token", body: body, as: EmptyResponse.self)
                    self.lastUploaded = key
                    NSLog("[VOIID] VoIP token registered (device=\(deviceId))")
                    return
                } catch {
                    NSLog("[VOIID] VoIP token upload failed (attempt \(attempt + 1)): \(error.localizedDescription)")
                    // 2s, 4s, then give up until the next trigger (login / new token).
                    try? await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
                }
            }
        }
    }
}

// MARK: - PKPushRegistryDelegate
//
// The project builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so these
// protocol requirements have to be spelled `nonisolated`. The registry was created
// with `queue: .main`, so PushKit really does call us on the main queue and
// `MainActor.assumeIsolated` is sound — and it is what lets us report the call to
// CallKit SYNCHRONOUSLY, which is the whole point. Hopping via `Task { @MainActor }`
// would return from this method before the call was reported and get us killed.

extension VoIPPushManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didUpdate pushCredentials: PKPushCredentials,
                                  for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            self.voipToken = hex
            self.uploadTokenIfNeeded(force: true)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        MainActor.assumeIsolated {
            self.voipToken = nil
            self.lastUploaded = nil
            NSLog("[VOIID] VoIP push token invalidated")
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType,
                                  completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let info = payload.dictionaryPayload

        // Routing metadata only — anything else in here would be a privacy bug.
        let callId = (info["call_id"] as? String) ?? UUID().uuidString
        let kind = (info["call_kind"] as? String) ?? "voice"
        let callerId = (info["caller_id"] as? String) ?? ""
        let conversationId = info["conversation_id"] as? String
        let displayName = (info["caller_name"] as? String)
        // A conference invite rides the same VoIP push as a 1:1 ring (so CallKit, the system
        // call log and the ringtone all keep working) — but the client must not then wait for
        // an SDP offer that is never sent. Accepts a real bool or the string form, since the
        // FCM side of the same contract has to stringify it.
        let isConference = (info["conference"] as? Bool) == true
            || (info["conference"] as? String) == "true"

        MainActor.assumeIsolated {
            // MUST report to CallKit before `completion()` — CallService does that
            // synchronously and invokes `completion` from the report callback.
            CallService.shared.reportIncomingCallFromVoIPPush(
                callId: callId,
                callerId: callerId,
                kind: kind,
                conversationId: conversationId,
                displayName: displayName,
                isConference: isConference,
                completion: completion
            )
        }
    }
}

//  ---------------------------------------------------------------------------
//  BACKEND / PROVISIONING CHECKLIST (cannot be verified from this machine)
//
//  1. APNs VoIP key: VoIP pushes are a SEPARATE APNs topic — `com.voiid.app.voip`
//     — and require a VoIP Services certificate or a p8 key with the
//     `apns-topic: com.voiid.app.voip` and `apns-push-type: voip` headers.
//     The regular message-push topic (`com.voiid.app`) will NOT deliver these.
//  2. `POST /v1/devices/voip-token { device_id, voip_token }` must exist and store
//     the token per device (see the backend agent's work). If the real path differs,
//     it's the one string in `uploadTokenIfNeeded` above.
//  3. The ring path (`POST /calls/ring`) should send the VoIP push to the callee's
//     registered VoIP tokens with payload:
//       { "call_id": …, "call_kind": "voice"|"video",
//         "caller_id": …, "conversation_id": …, "caller_name": … }
//     and NOTHING else. No SDP, no message content.
//  4. Entitlement/capability: `UIBackgroundModes` must include `voip` (set via
//     INFOPLIST_KEY_UIBackgroundModes in the project's build settings).
//  ---------------------------------------------------------------------------
