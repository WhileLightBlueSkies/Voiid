//
//  CallService.swift
//  Voiid
//
//  The WebRTC engine for 1:1 voice/video calls. Owns the RTCPeerConnection,
//  drives signaling over the existing WebSocketClient (call_offer/answer/ice/
//  hangup/busy/decline — the backend relay stamps the authenticated sender), and
//  pulls ICE servers from GET /calls/turn.
//
//  Media is encrypted peer-to-peer by WebRTC's DTLS-SRTP; the server sees only
//  signaling (and at most relays media via TURN, never in the clear). The
//  signaling that carries the DTLS fingerprints is authenticated server-side, so
//  a network attacker can't MITM without the server colluding. (An additional
//  verified-keying layer from e2e-core `srtpKeysFor1to1` is a future enhancement.)
//
//  CallManager (CallKit) reports the OS-level incoming/outgoing UI and hands us
//  the activated AVAudioSession; this class is the actual call state + transport.
//
//  RUNTIME CAVEAT: compile-verified only. A real call needs two devices, a
//  reachable TURN server, and (for CallKit/VoIP push wake-up) a signed build on
//  real hardware.
//

import Foundation
import Combine
import WebRTC
import AVFoundation
import UIKit

/// High-level call state the UI renders.
enum CallState: Equatable {
    case idle
    case outgoingRinging   // we placed the call, waiting for answer
    case incomingRinging   // we received an offer, waiting for the user to accept
    case connecting        // answered, negotiating / ICE
    case connected
    case ended
}

/// One active (or ringing) 1:1 call.
struct ActiveCall: Identifiable, Equatable {
    let id: String            // call_id (shared by both peers)
    let uuid: UUID            // CallKit handle
    /// Filled from the VoIP push payload, then corrected by the authenticated
    /// `from_user_id` on the WS offer (the push payload is not authenticated).
    var peerUserId: String
    var title: String
    let isVideo: Bool
    let isOutgoing: Bool
    var state: CallState
}

@MainActor
final class CallService: NSObject, ObservableObject {
    static let shared = CallService()

    // MARK: Published UI state
    @Published private(set) var active: ActiveCall?
    @Published private(set) var muted = false
    @Published private(set) var speakerOn = false
    @Published private(set) var videoEnabled = true
    @Published private(set) var connectedSeconds = 0
    /// Remote + local video tracks for the UI to render (nil for voice calls).
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var localVideoTrack: RTCVideoTrack?

    // MARK: WebRTC
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }()

    private var pc: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var usingFrontCamera = true

    // Buffer remote ICE that arrives before the remote description is set.
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    // The offer we received but haven't answered yet (incoming call awaiting accept).
    private var pendingIncomingOfferSDP: String?

    // MARK: VoIP-push reconciliation
    // A VoIP push reports the call to CallKit *before* the SDP offer arrives over the
    // WebSocket. These track that in-between window so the later `call_offer` for the
    // same call_id attaches to the call we already reported instead of creating a
    // second one (which would double-ring and wedge CallKit).
    /// call_ids we rang from a VoIP push and are still waiting on an offer for.
    private var awaitingOfferCallIds: Set<String> = []
    /// The user hit Answer in CallKit before the offer landed — answer on arrival.
    private var answerWhenOfferArrives = false
    /// Fires if the offer never comes (caller cancelled / push raced a hangup) so we
    /// don't ring forever.
    private var offerTimeoutTask: Task<Void, Never>?
    /// How long a push-rung call may ring without an offer before we give up.
    private static let offerTimeout: Duration = .seconds(30)

    private var timer: Timer?
    private let api = APIClient()

    // MARK: Lifecycle / background handling
    /// True while the full-screen call UI is on screen. Used to decide whether a
    /// PiP restore tap needs to re-present it, and whether to show the in-app
    /// floating call window.
    @Published private(set) var callUIVisible = false
    /// The user minimized the call screen but the call is still running. Keeps the
    /// call-screen presentation bindings from immediately re-presenting it, and is
    /// what makes the in-app floating window appear.
    @Published private(set) var callUIMinimized = false
    /// Set when we stopped the camera because the app went to the background, so
    /// foregrounding knows to restart it (and only then).
    private var captureSuspendedForBackground = false
    private var systemObserversInstalled = false

    private override init() { super.init() }

    /// Wire signaling callbacks + CallKit. Call once at app startup.
    func configure(socket: WebSocketClient) {
        CallManager.shared.configure(service: self)
        installSystemObservers()
        // PiP follows the call lifecycle (remote track in, call ended out) without
        // this class needing to know about AVKit.
        CallPiPController.shared.observe(self)
        // In-app floating "return to call" window (foreground only — system PiP
        // is what covers the backgrounded case).
        CallFloatingWindowManager.shared.observe(self)

        socket.onCallOffer = { [weak self] from, callId, kind, sdp in
            Task { @MainActor in self?.handleIncomingOffer(from: from, callId: callId, kind: kind, sdp: sdp) }
        }
        socket.onCallAnswer = { [weak self] _, callId, sdp in
            Task { @MainActor in self?.handleAnswer(callId: callId, sdp: sdp) }
        }
        socket.onCallIce = { [weak self] _, callId, cand, mline, mid in
            Task { @MainActor in self?.handleRemoteIce(callId: callId, candidate: cand, sdpMLineIndex: mline, sdpMid: mid) }
        }
        socket.onCallHangup = { [weak self] _, callId in
            Task { @MainActor in self?.handleRemoteEnd(callId: callId, state: .ended) }
        }
        socket.onCallBusy = { [weak self] _, callId in
            Task { @MainActor in self?.handleRemoteEnd(callId: callId, state: .ended) }
        }
        socket.onCallDecline = { [weak self] _, callId in
            Task { @MainActor in self?.handleRemoteEnd(callId: callId, state: .ended) }
        }
    }

    private var socket: WebSocketClient { WebSocketClient.shared }

    // MARK: - System observers (background / interruption / route / termination)

    /// Everything a call needs to survive leaving the foreground. All handlers are
    /// no-ops when there is no active call, so this is safe to install once at
    /// startup and leave running for the life of the process.
    private func installSystemObservers() {
        guard !systemObserversInstalled else { return }
        systemObserversInstalled = true
        let nc = NotificationCenter.default

        // Camera capture is suspended by iOS once we leave the foreground: stop it
        // deliberately so we never publish a stale/frozen local frame.
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CallService.shared.handleEnteredBackground() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CallService.shared.handleWillEnterForeground() }
        }
        // Don't leave the peer ringing/talking to a zombie call if we're killed.
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CallService.shared.handleWillTerminate() }
        }
        nc.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CallService.shared.handleWillTerminate() }
        }
        // PSTN call / Siri / alarm takes the audio session away and gives it back.
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { CallService.shared.handleAudioInterruption(note) }
        }
        // Headphones / Bluetooth connected or yanked mid-call.
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { CallService.shared.handleRouteChange(note) }
        }
    }

    private func handleEnteredBackground() {
        guard let call = active, call.state != .ended, call.isVideo else { return }
        guard let capturer = videoCapturer, !captureSuspendedForBackground else { return }
        captureSuspendedForBackground = true
        capturer.stopCapture()
        // Publish "no video" rather than a frozen last frame while we're away.
        localVideoTrack?.isEnabled = false
    }

    private func handleWillEnterForeground() {
        guard captureSuspendedForBackground else { return }
        captureSuspendedForBackground = false
        guard let call = active, call.state != .ended, let capturer = videoCapturer else { return }
        startCapture(capturer: capturer, front: usingFrontCamera)
        localVideoTrack?.isEnabled = videoEnabled && call.isVideo
    }

    /// Best-effort clean shutdown on termination. Kept synchronous — the app is
    /// being torn down and any `Task` we schedule here will likely never run.
    private func handleWillTerminate() {
        guard let call = active else { return }
        if !call.peerUserId.isEmpty {
            socket.sendCallHangup(toUserId: call.peerUserId, callId: call.id)
        }
        CallManager.shared.endCall(uuid: call.uuid)
        videoCapturer?.stopCapture()
        pc?.close()
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    private func handleAudioInterruption(_ note: Notification) {
        guard active != nil else { return }
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let rtc = RTCAudioSession.sharedInstance()
        switch type {
        case .began:
            // Something else (a phone call, Siri) owns audio now.
            rtc.isAudioEnabled = false
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            guard options.contains(.shouldResume) else { return }
            rtc.lockForConfiguration()
            try? rtc.setActive(true)
            rtc.unlockForConfiguration()
            rtc.isAudioEnabled = true
            applyOutputOverride(speaker: speakerOn)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let call = active, call.state != .ended else { return }
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .newDeviceAvailable:
            // A headset / Bluetooth device appeared — let audio follow it by
            // dropping any speaker override we had forced.
            speakerOn = false
            applyOutputOverride(speaker: false)
        case .oldDeviceUnavailable:
            // Headset removed. A video call belongs on the speaker; a voice call
            // falls back to the receiver (what the user expects at their ear).
            let wantSpeaker = call.isVideo
            speakerOn = wantSpeaker
            applyOutputOverride(speaker: wantSpeaker)
        default:
            break
        }
    }

    /// Force the output port. Centralised so route changes and the speaker button
    /// go through the same locked configuration path.
    private func applyOutputOverride(speaker: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.overrideOutputAudioPort(speaker ? .speaker : .none)
        session.unlockForConfiguration()
    }

    /// Told by the call screen whether it is on screen (drives PiP restore + the
    /// in-app floating window).
    func setCallUIVisible(_ visible: Bool) { callUIVisible = visible }

    /// Shrink the call to the in-app floating window (call keeps running).
    func minimizeCallUI() { callUIMinimized = true }
    /// Bring the full-screen call UI back (floating-window or PiP tap).
    func restoreCallUI() { callUIMinimized = false }

    // MARK: - Outgoing

    /// Place a 1:1 call. Builds the peer connection, creates an offer, signals it,
    /// and asks the backend to ring (wake) the callee.
    func startCall(peerUserId: String, title: String, isVideo: Bool) {
        guard active == nil else { return }   // one call at a time
        let callId = UUID().uuidString
        let uuid = UUID()
        active = ActiveCall(id: callId, uuid: uuid, peerUserId: peerUserId, title: title,
                            isVideo: isVideo, isOutgoing: true, state: .outgoingRinging)
        videoEnabled = isVideo
        callUIMinimized = false

        Task {
            await setupPeerConnection(isVideo: isVideo)
            CallManager.shared.startOutgoingCall(uuid: uuid, handle: peerUserId, displayName: title, hasVideo: isVideo)
            CallManager.shared.reportOutgoingConnecting(uuid: uuid)
            await createAndSendOffer(callId: callId, peerUserId: peerUserId, isVideo: isVideo)
            // Wake an offline/backgrounded callee via push.
            struct RingBody: Encodable { let to_user_id: String; let call_id: String; let call_kind: String; let conversation_id: String? }
            _ = try? await api.request("POST", "calls/ring",
                                       body: RingBody(to_user_id: peerUserId, call_id: callId,
                                                      call_kind: isVideo ? "video" : "voice", conversation_id: nil),
                                       as: EmptyResponse.self)
        }
    }

    private func createAndSendOffer(callId: String, peerUserId: String, isVideo: Bool) async {
        guard let pc else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            let offer = try await pc.offer(for: constraints)
            try await pc.setLocalDescription(offer)
            socket.sendCallOffer(toUserId: peerUserId, callId: callId,
                                 callKind: isVideo ? "video" : "voice", sdp: offer.sdp)
        } catch {
            NSLog("[VOIID] call offer failed: \(error.localizedDescription)")
            endActiveCall(notifyPeer: true, fromCallKit: false)
        }
    }

    // MARK: - Incoming

    /// Ring an incoming call straight from a PushKit VoIP push, BEFORE any SDP has
    /// arrived. iOS requires `reportNewIncomingCall` to happen inside the push
    /// handler, so this is deliberately synchronous up to the CallKit report and
    /// only then calls `completion` (which PushKit demands we call).
    ///
    /// Everything here is best-effort metadata: the real peer identity arrives with
    /// the authenticated `call_offer` frame and overwrites it.
    func reportIncomingCallFromVoIPPush(callId: String,
                                        callerId: String,
                                        kind: String,
                                        conversationId: String?,
                                        displayName: String?,
                                        completion: @escaping () -> Void) {
        // The WS offer beat the push (app was alive), or this is a duplicate push —
        // the call is already ringing, nothing to do. Still must call completion.
        if let active, active.id == callId { completion(); return }

        // Already busy on a different call. iOS still requires us to report a call
        // for this push, so report it and immediately end it as busy.
        if let active, active.id != callId {
            let uuid = UUID()
            let peer = callerId
            // CallKit rejects an empty handle — fall back to a non-empty routing id.
            let handle = peer.isEmpty ? (conversationId ?? callId) : peer
            CallManager.shared.reportIncomingCall(uuid: uuid, handle: handle,
                                                  displayName: displayName ?? handle,
                                                  hasVideo: kind == "video") { _ in
                CallManager.shared.endCall(uuid: uuid)
                completion()
            }
            if !peer.isEmpty { socket.sendCallBusy(toUserId: peer, callId: callId) }
            return
        }

        let isVideo = (kind == "video")
        let uuid = UUID()
        let handle = callerId.isEmpty ? (conversationId ?? callId) : callerId
        active = ActiveCall(id: callId, uuid: uuid, peerUserId: callerId,
                            title: displayName ?? handle,
                            isVideo: isVideo, isOutgoing: false, state: .incomingRinging)
        videoEnabled = isVideo
        pendingIncomingOfferSDP = nil
        answerWhenOfferArrives = false
        awaitingOfferCallIds.insert(callId)

        // THE mandatory bit: report to CallKit, complete the push from its callback.
        CallManager.shared.reportIncomingCall(uuid: uuid, handle: handle,
                                              displayName: displayName ?? handle,
                                              hasVideo: isVideo) { ok in
            if !ok { NSLog("[VOIID] VoIP push: CallKit refused call \(callId)") }
            completion()
        }

        // Now get the socket up so the offer (and ICE) can actually reach us — the
        // app may have been cold-launched by this push with no live connection.
        WebSocketClient.shared.reconnect()
        startOfferTimeout(for: callId)
    }

    /// If no `call_offer` follows the push (caller cancelled, or the push raced a
    /// hangup we'll never see), stop ringing instead of hanging forever.
    private func startOfferTimeout(for callId: String) {
        offerTimeoutTask?.cancel()
        offerTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.offerTimeout)
            guard !Task.isCancelled, let self else { return }
            guard let call = self.active, call.id == callId,
                  self.awaitingOfferCallIds.contains(callId) else { return }
            NSLog("[VOIID] VoIP push: no offer for \(callId) within timeout — ending")
            self.awaitingOfferCallIds.remove(callId)
            CallManager.shared.endCall(uuid: call.uuid)
            self.endActiveCall(notifyPeer: false, fromCallKit: false)
        }
    }

    private func handleIncomingOffer(from: String, callId: String, kind: String, sdp: String) {
        // The offer for a call we already rang from a VoIP push: attach the SDP to
        // the EXISTING call rather than reporting a second one to CallKit.
        if var call = active, call.id == callId {
            guard awaitingOfferCallIds.contains(callId), pendingIncomingOfferSDP == nil else { return }
            awaitingOfferCallIds.remove(callId)
            offerTimeoutTask?.cancel(); offerTimeoutTask = nil
            pendingIncomingOfferSDP = sdp
            // `from` is stamped server-side and authenticated — trust it over the push.
            call.peerUserId = from
            if call.title.isEmpty || call.title == call.id { call.title = from }
            active = call
            // The user already tapped Answer in CallKit while we had no SDP; now we can.
            if answerWhenOfferArrives {
                answerWhenOfferArrives = false
                callKitAnswer(uuid: call.uuid)
            }
            return
        }
        // Busy: already in a different call → tell the caller.
        if let active, active.id != callId {
            socket.sendCallBusy(toUserId: from, callId: callId)
            return
        }
        guard active == nil else { return }
        // No push (app was foregrounded, or VoIP push undelivered) — ring from the WS.
        let isVideo = (kind == "video")
        let uuid = UUID()
        pendingIncomingOfferSDP = sdp
        active = ActiveCall(id: callId, uuid: uuid, peerUserId: from, title: from,
                            isVideo: isVideo, isOutgoing: false, state: .incomingRinging)
        videoEnabled = isVideo
        // Ask the OS to show the native incoming-call UI.
        CallManager.shared.reportIncomingCall(uuid: uuid, handle: from, displayName: from, hasVideo: isVideo) { _ in }
    }

    /// Called by CallManager when the user accepts via CallKit (or the in-app button
    /// routes through CallKit). Builds the answer and completes negotiation.
    func callKitAnswer(uuid: UUID) {
        guard var call = active, call.uuid == uuid else { return }
        guard let offerSDP = pendingIncomingOfferSDP else {
            // Answered from the lock screen after a VoIP push but the offer hasn't
            // landed yet. Remember the intent; `handleIncomingOffer` finishes the
            // answer the moment the SDP arrives.
            if awaitingOfferCallIds.contains(call.id) {
                answerWhenOfferArrives = true
                call.state = .connecting
                active = call
            }
            return
        }
        call.state = .connecting
        active = call
        Task {
            await setupPeerConnection(isVideo: call.isVideo)
            guard let pc else { return }
            do {
                try await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offerSDP))
                hasRemoteDescription = true
                drainPendingCandidates()
                let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
                try await pc.setLocalDescription(answer)
                socket.sendCallAnswer(toUserId: call.peerUserId, callId: call.id, sdp: answer.sdp)
            } catch {
                NSLog("[VOIID] call answer failed: \(error.localizedDescription)")
                endActiveCall(notifyPeer: true, fromCallKit: false)
            }
        }
        pendingIncomingOfferSDP = nil
    }

    /// Accept from the in-app UI (routes through CallKit for the audio session).
    func accept() {
        guard let call = active, call.state == .incomingRinging else { return }
        callKitAnswer(uuid: call.uuid)
    }

    /// Decline an incoming call.
    func decline() {
        guard let call = active, !call.isOutgoing else { return }
        // peerUserId can still be empty if a VoIP push rang us with no caller_id and
        // the offer hasn't arrived — nothing to send the decline to in that case.
        if !call.peerUserId.isEmpty { socket.sendCallDecline(toUserId: call.peerUserId, callId: call.id) }
        endActiveCall(notifyPeer: false, fromCallKit: false)
    }

    // MARK: - Answer / ICE inbound

    private func handleAnswer(callId: String, sdp: String) {
        guard let call = active, call.id == callId, let pc else { return }
        Task {
            do {
                try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                hasRemoteDescription = true
                drainPendingCandidates()
            } catch {
                NSLog("[VOIID] setRemoteDescription(answer) failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleRemoteIce(callId: String, candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        guard let call = active, call.id == callId else { return }
        let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        if hasRemoteDescription, let pc {
            pc.add(ice) { err in if let err { NSLog("[VOIID] add ICE failed: \(err.localizedDescription)") } }
        } else {
            pendingRemoteCandidates.append(ice)   // buffer until remote description is set
        }
    }

    private func drainPendingCandidates() {
        guard let pc else { return }
        for ice in pendingRemoteCandidates {
            pc.add(ice) { err in if let err { NSLog("[VOIID] add buffered ICE failed: \(err.localizedDescription)") } }
        }
        pendingRemoteCandidates.removeAll()
    }

    // MARK: - Teardown

    private func handleRemoteEnd(callId: String, state: CallState) {
        guard let call = active, call.id == callId else { return }
        CallManager.shared.endCall(uuid: call.uuid)
        endActiveCall(notifyPeer: false, fromCallKit: false)
    }

    /// Hang up from the in-app button.
    func hangUp() {
        guard let call = active else { return }
        CallManager.shared.requestEnd(uuid: call.uuid)   // routes back via callKitEnd
    }

    func callKitStart(uuid: UUID) { /* audio session handled by CallKit didActivate */ }

    func callKitEnd(uuid: UUID) {
        endActiveCall(notifyPeer: true, fromCallKit: true)
    }

    /// Tear down the call. `notifyPeer` sends a hangup; `fromCallKit` avoids
    /// re-entering the CallKit end transaction.
    func endActiveCall(notifyPeer: Bool, fromCallKit: Bool) {
        guard let call = active else { return }
        offerTimeoutTask?.cancel(); offerTimeoutTask = nil
        awaitingOfferCallIds.remove(call.id)
        answerWhenOfferArrives = false
        if notifyPeer, !call.peerUserId.isEmpty { socket.sendCallHangup(toUserId: call.peerUserId, callId: call.id) }
        if !fromCallKit { CallManager.shared.endCall(uuid: call.uuid) }

        // Best-effort call-record status update.
        let callId = call.id
        Task {
            struct StatusBody: Encodable { let status: String }
            _ = try? await api.request("POST", "calls/\(callId)/status",
                                       body: StatusBody(status: "ended"), as: EmptyResponse.self)
        }

        timer?.invalidate(); timer = nil
        connectedSeconds = 0
        captureSuspendedForBackground = false
        callUIMinimized = false
        videoCapturer?.stopCapture()
        videoCapturer = nil
        videoSource = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        localAudioTrack = nil
        pc?.close()
        pc = nil
        hasRemoteDescription = false
        pendingRemoteCandidates.removeAll()
        pendingIncomingOfferSDP = nil
        RTCAudioSession.sharedInstance().isAudioEnabled = false

        var ended = call; ended.state = .ended
        active = ended
        // Clear after a beat so the UI can show "ended".
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if self.active?.id == call.id { self.active = nil }
        }
    }

    // MARK: - Media controls

    func setMuted(_ m: Bool) {
        muted = m
        localAudioTrack?.isEnabled = !m
    }
    func toggleMute() { setMuted(!muted) }

    func toggleSpeaker() {
        speakerOn.toggle()
        applyOutputOverride(speaker: speakerOn)
    }

    func toggleVideo() {
        videoEnabled.toggle()
        localVideoTrack?.isEnabled = videoEnabled
    }

    func switchCamera() {
        guard let capturer = videoCapturer else { return }
        usingFrontCamera.toggle()
        startCapture(capturer: capturer, front: usingFrontCamera)
    }

    // MARK: - Peer connection setup

    private func setupPeerConnection(isVideo: Bool) async {
        let iceServers = await fetchIceServers()
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)

        // Local audio (always).
        let audioSource = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audio = Self.factory.audioTrack(with: audioSource, trackId: "voiid_audio0")
        localAudioTrack = audio
        pc?.add(audio, streamIds: ["voiid_stream"])

        // Local video (video calls only).
        if isVideo {
            let source = Self.factory.videoSource()
            videoSource = source
            let capturer = RTCCameraVideoCapturer(delegate: source)
            videoCapturer = capturer
            let track = Self.factory.videoTrack(with: source, trackId: "voiid_video0")
            track.isEnabled = videoEnabled
            localVideoTrack = track
            pc?.add(track, streamIds: ["voiid_stream"])
            startCapture(capturer: capturer, front: usingFrontCamera)
        }
    }

    private func startCapture(capturer: RTCCameraVideoCapturer, front: Bool) {
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
                ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // Pick a ~720p format with the highest supported fps.
        let target = formats.min(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) - 1280) < abs(Int(db.width) - 1280)
        }) ?? formats.first
        guard let format = target else { return }
        let fps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(fps, 30)))
    }

    private func fetchIceServers() async -> [RTCIceServer] {
        struct TurnServer: Decodable { let urls: [String]; let username: String?; let credential: String? }
        struct TurnResponse: Decodable { let ice_servers: [TurnServer] }
        do {
            let resp: TurnResponse = try await api.request("GET", "calls/turn", as: TurnResponse.self)
            return resp.ice_servers.map { s in
                if let u = s.username, let c = s.credential {
                    return RTCIceServer(urlStrings: s.urls, username: u, credential: c)
                }
                return RTCIceServer(urlStrings: s.urls)
            }
        } catch {
            NSLog("[VOIID] /calls/turn failed, using public STUN: \(error.localizedDescription)")
            return [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        }
    }

    private func markConnected() {
        guard var call = active, call.state != .connected else { return }
        call.state = .connected
        active = call
        CallManager.shared.reportOutgoingConnected(uuid: call.uuid)
        // A video call held at arm's length belongs on the speaker, not the
        // earpiece. Only forced once, on connect — the user can still toggle.
        if call.isVideo, !speakerOn {
            speakerOn = true
            applyOutputOverride(speaker: true)
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.connectedSeconds += 1 }
            }
        }
        let callId = call.id
        Task {
            struct StatusBody: Encodable { let status: String }
            _ = try? await api.request("POST", "calls/\(callId)/status",
                                       body: StatusBody(status: "connected"), as: EmptyResponse.self)
        }
    }
}

// MARK: - RTCPeerConnectionDelegate (nonisolated; hops to main actor)

extension CallService: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard let call = self.active else { return }
            self.socket.sendCallIce(toUserId: call.peerUserId, callId: call.id,
                                    candidate: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex,
                                    sdpMid: candidate.sdpMid)
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected, .completed: self.markConnected()
            case .failed, .closed, .disconnected:
                if newState == .failed || newState == .closed {
                    self.endActiveCall(notifyPeer: true, fromCallKit: false)
                }
            default: break
            }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        // Unified-plan remote track arrival.
        if let video = rtpReceiver.track as? RTCVideoTrack {
            Task { @MainActor in self.remoteVideoTrack = video }
        }
    }

    // Unused but required by the protocol.
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
