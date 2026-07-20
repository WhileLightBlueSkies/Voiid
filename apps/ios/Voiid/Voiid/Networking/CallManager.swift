//
//  CallManager.swift
//  Voiid
//
//  CallKit bridge for 1:1 voice/video calls. Reports incoming calls to the OS so
//  the native full-screen / lock-screen incoming-call UI appears, and routes the
//  OS actions (answer / end / mute) back into `CallService` (the WebRTC engine).
//
//  It also owns the AVAudioSession handoff that WebRTC needs: when CallKit's
//  provider activates the audio session we hand it to WebRTC's RTCAudioSession
//  (manual-audio mode), and disable audio again on deactivate. This is the
//  standard CallKit + WebRTC pattern.
//
//  NOTE (runtime caveat): CallKit + VoIP push only deliver real incoming calls on
//  a SIGNED build on a real device. In the simulator this compiles and the state
//  machine runs, but the native call UI / PushKit wake-up won't fire.
//

import Foundation
import CallKit
import AVFoundation
import WebRTC

@MainActor
final class CallManager: NSObject {
    static let shared = CallManager()

    private let provider: CXProvider
    private let callController = CXCallController()

    /// The engine we drive. Wired up in `configure()` to avoid an init cycle.
    weak var service: CallService?

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // WebRTC drives the audio session itself, activated by CallKit's callbacks.
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.useManualAudio = true
        rtcSession.isAudioEnabled = false
    }

    func configure(service: CallService) { self.service = service }

    // MARK: - Reporting calls to CallKit

    /// Report an inbound call so the OS shows the native incoming-call UI.
    func reportIncomingCall(uuid: UUID, handle: String, displayName: String, hasVideo: Bool,
                            completion: @escaping (Bool) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = displayName
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error { NSLog("[VOIID] CallKit reportIncoming error: \(error.localizedDescription)") }
            completion(error == nil)
        }
    }

    /// Start an outgoing call through CallKit (gives us the system audio session).
    func startOutgoingCall(uuid: UUID, handle: String, displayName: String, hasVideo: Bool) {
        let cxHandle = CXHandle(type: .generic, value: handle)
        let action = CXStartCallAction(call: uuid, handle: cxHandle)
        action.isVideo = hasVideo
        action.contactIdentifier = displayName
        callController.request(CXTransaction(action: action)) { error in
            if let error { NSLog("[VOIID] CallKit startCall error: \(error.localizedDescription)") }
        }
        let update = CXCallUpdate()
        update.remoteHandle = cxHandle
        update.localizedCallerName = displayName
        update.hasVideo = hasVideo
        provider.reportCall(with: uuid, updated: update)
    }

    /// Tell CallKit the outgoing call started ringing / connected.
    func reportOutgoingConnecting(uuid: UUID) { provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil) }
    func reportOutgoingConnected(uuid: UUID) { provider.reportOutgoingCall(with: uuid, connectedAt: nil) }

    /// End a call in CallKit (peer hung up, we hung up, error, etc.).
    func endCall(uuid: UUID) {
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
    }

    /// Request-to-end via the transaction API (when the user taps hang up in-app).
    func requestEnd(uuid: UUID) {
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { error in
            if let error { NSLog("[VOIID] CallKit requestEnd error: \(error.localizedDescription)") }
        }
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.service?.endActiveCall(notifyPeer: true, fromCallKit: true) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            self.service?.callKitAnswer(uuid: action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            self.service?.callKitEnd(uuid: action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            self.service?.callKitStart(uuid: action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            self.service?.setMuted(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Hand the CallKit-activated session to WebRTC and enable audio.
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }
}
