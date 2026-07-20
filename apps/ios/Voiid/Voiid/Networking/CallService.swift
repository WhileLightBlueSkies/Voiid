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
    let peerUserId: String
    let title: String
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

    private var timer: Timer?
    private let api = APIClient()

    private override init() { super.init() }

    /// Wire signaling callbacks + CallKit. Call once at app startup.
    func configure(socket: WebSocketClient) {
        CallManager.shared.configure(service: self)

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

    private func handleIncomingOffer(from: String, callId: String, kind: String, sdp: String) {
        // Busy: already in a call → tell the caller.
        if let active, active.id != callId {
            socket.sendCallBusy(toUserId: from, callId: callId)
            return
        }
        guard active == nil else { return }
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
        guard var call = active, call.uuid == uuid, let offerSDP = pendingIncomingOfferSDP else { return }
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
        socket.sendCallDecline(toUserId: call.peerUserId, callId: call.id)
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
        if notifyPeer { socket.sendCallHangup(toUserId: call.peerUserId, callId: call.id) }
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
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
        session.unlockForConfiguration()
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
