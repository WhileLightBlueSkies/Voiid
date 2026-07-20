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
import Network

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
    /// Live connection quality derived from packet loss + RTT. The call UI can
    /// show a weak-connection indicator off this without knowing about stats.
    @Published private(set) var quality: CallQuality = .unknown
    /// True while we're re-gathering ICE after a network change. The UI can show
    /// "Reconnecting…" — the call is NOT over and media may still be flowing.
    @Published private(set) var isReconnecting = false
    /// Latest parsed stats sample, for a debug overlay if we ever want one.
    @Published private(set) var latestStats: CallStatsSample?

    // MARK: Network resilience
    //
    // The problem: WebRTC gathers ICE candidates bound to whichever interface was
    // up at the time. Walk out of WiFi range onto LTE and those candidates point
    // at an address the device no longer owns; the selected pair goes silent and
    // the call dies. Recovering means re-gathering — an ICE restart — over the
    // same signaling channel and the same call_id.
    //
    // Three things can ask for a restart, in descending order of how much we
    // trust them:
    //   1. NWPathMonitor says the interface changed  — fastest and most reliable.
    //   2. RTCIceConnectionState == .failed          — terminal, restart now.
    //   3. RTCIceConnectionState == .disconnected    — usually transient; wait out
    //      a grace period first, because most of these self-heal and a needless
    //      renegotiation is itself disruptive.

    /// How many restarts we'll attempt before giving up on the call.
    private static let maxIceRestarts = 3
    /// `.disconnected` is noisy; give ICE this long to recover on its own.
    private static let disconnectGrace: Duration = .seconds(3)

    private var iceRestartAttempts = 0
    /// Total restarts across the call, for telemetry (not reset on success).
    private var iceRestartsTotal = 0
    /// A restart offer is out and we're waiting for the answer.
    private var restartInFlight = false
    /// Pending "`.disconnected` didn't heal" timer.
    private var disconnectGraceTask: Task<Void, Never>?
    /// Backoff between restart attempts.
    private var restartBackoffTask: Task<Void, Never>?
    private var networkObserverInstalled = false

    // MARK: Telemetry
    private let stats = CallStatsCollector()
    private var callStartedAt: Date?
    private var callConnectedAt: Date?
    /// Set by whichever teardown path runs first; read when building metrics.
    private var pendingEndReason: CallEndReason = .unknown
    private var everConnected = false

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
        installNetworkObserver(socket: socket)
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
            Task { @MainActor in self?.handleRemoteEnd(callId: callId, reason: .remoteHangup) }
        }
        socket.onCallBusy = { [weak self] _, callId in
            Task { @MainActor in self?.handleRemoteEnd(callId: callId, reason: .busy) }
        }
        socket.onCallDecline = { [weak self] _, callId in
            Task { @MainActor in self?.handleRemoteEnd(callId: callId, reason: .declined) }
        }
    }

    private var socket: WebSocketClient { WebSocketClient.shared }

    // MARK: - Network path + signaling liveness

    /// Hook up NWPathMonitor and socket liveness. Both handlers are no-ops when
    /// there's no live call, so this is installed once and left running.
    private func installNetworkObserver(socket: WebSocketClient) {
        guard !networkObserverInstalled else { return }
        networkObserverInstalled = true

        CallNetworkMonitor.shared.onPathChange = { [weak self] path, isHandover in
            guard let self else { return }
            let iface = path.interface?.voiidLabel ?? "none"
            NSLog("[VOIID] network path changed → \(iface) satisfied=\(path.isSatisfied) handover=\(isHandover)")
            guard let call = self.active, call.state == .connected || call.state == .connecting else { return }

            // Path went away entirely — don't restart into a dead network, just
            // wait. The call is not over; media resumes if the gap is short and
            // the ICE-state handlers cover us if it isn't.
            guard path.isSatisfied else {
                NSLog("[VOIID] network unsatisfied during call — holding, not ending")
                return
            }
            // The signaling socket is bound to the old interface too. Rebuild it
            // regardless, so a restart offer has somewhere to go.
            self.socket.reconnect()
            guard isHandover else { return }
            self.requestIceRestart(reason: "network handover to \(iface)")
        }
        CallNetworkMonitor.shared.start()

        socket.onLivenessChange = { [weak self] live in
            guard let self, let call = self.active, call.state != .ended else { return }
            NSLog("[VOIID] signaling liveness=\(live) during active call \(call.id)")
            // NOTE: we deliberately do NOT end the call when the socket drops.
            // SRTP media flows peer-to-peer and survives a signaling outage; only
            // renegotiation and hangup need the socket. WebSocketClient queues
            // outbound call frames and flushes them here.
        }

        stats.onUpdate = { [weak self] quality, sample in
            guard let self else { return }
            self.quality = quality
            self.latestStats = sample
        }
    }

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
        // A group call already owns the audio route (see GroupCallService).
        guard !GroupCallService.shared.isActive else { return }
        let callId = UUID().uuidString
        let uuid = UUID()
        active = ActiveCall(id: callId, uuid: uuid, peerUserId: peerUserId, title: title,
                            isVideo: isVideo, isOutgoing: true, state: .outgoingRinging)
        videoEnabled = isVideo
        callUIMinimized = false
        beginCallTelemetry()

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
            // Turn on Opus FEC/DTX before the SDP becomes our local description.
            let tuned = RTCSessionDescription(type: .offer,
                                              sdp: CallSDPTuning.tuneLocalDescription(offer.sdp))
            try await pc.setLocalDescription(tuned)
            socket.sendCallOffer(toUserId: peerUserId, callId: callId,
                                 callKind: isVideo ? "video" : "voice", sdp: tuned.sdp)
        } catch {
            NSLog("[VOIID] call offer failed: \(error.localizedDescription)")
            pendingEndReason = .setupFailed
            endActiveCall(notifyPeer: true, fromCallKit: false)
        }
    }

    // MARK: - Telemetry lifecycle

    /// Reset per-call counters. Called for both outgoing and incoming calls at
    /// the moment the call becomes real, so `setup_ms` measures the same thing
    /// on both sides: intent-to-call until media actually flows.
    private func beginCallTelemetry() {
        stats.reset()
        quality = .unknown
        latestStats = nil
        callStartedAt = Date()
        callConnectedAt = nil
        everConnected = false
        pendingEndReason = .unknown
        iceRestartAttempts = 0
        iceRestartsTotal = 0
        restartInFlight = false
        isReconnecting = false
    }

    /// Fire-and-forget the anonymous aggregate. See CallStatsCollector's privacy
    /// note for what may and may not go in here.
    ///
    /// This is called from the teardown path, so it captures its values up front
    /// and never touches `self` state that teardown is about to clear. A failure
    /// — including a 404 while the backend endpoint is still being built — is
    /// swallowed completely. Telemetry never affects a call.
    private func postCallMetrics(callId: String, endReason: CallEndReason) {
        let durationMs: Int? = callConnectedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        let setupMs: Int? = {
            guard let started = callStartedAt, let connected = callConnectedAt else { return nil }
            return Int(connected.timeIntervalSince(started) * 1000)
        }()
        let metrics = stats.buildMetrics(callId: callId,
                                         connected: everConnected,
                                         setupMs: setupMs,
                                         durationMs: durationMs,
                                         endReason: endReason,
                                         iceRestarts: iceRestartsTotal)
        let client = api
        Task.detached {
            _ = try? await client.request("POST", "calls/metrics", body: metrics, as: EmptyResponse.self)
        }
    }

    // MARK: - ICE restart (network handover recovery)

    /// Ask for an ICE restart. Safe to call from anywhere and from several
    /// triggers at once — it de-duplicates, backs off, and enforces the attempt
    /// cap. Only the offerer role drives the restart; see below.
    private func requestIceRestart(reason: String) {
        guard let call = active, call.state == .connected || call.state == .connecting else { return }
        guard pc != nil else { return }

        // A restart already in flight will either succeed or time out into
        // another attempt — piling on more offers just creates glare.
        guard !restartInFlight else {
            NSLog("[VOIID] ICE restart already in flight, ignoring: \(reason)")
            return
        }

        guard iceRestartAttempts < Self.maxIceRestarts else {
            NSLog("[VOIID] ICE restart cap (\(Self.maxIceRestarts)) exhausted — ending call")
            pendingEndReason = .iceFailed
            endActiveCall(notifyPeer: true, fromCallKit: false)
            return
        }

        // ICE restart is an offer/answer exchange, and only one side may offer.
        // Both peers see the same network events, so without a rule they'd both
        // offer and collide. The ORIGINAL CALLER always drives; the answerer
        // just waits for the offer to arrive (its own network change will have
        // been noticed by the caller as an ICE failure if it matters). This
        // avoids needing full rollback/perfect-negotiation glare handling.
        guard call.isOutgoing else {
            NSLog("[VOIID] ICE restart needed (\(reason)) but we're the answerer — awaiting peer's offer")
            isReconnecting = true
            return
        }

        let attempt = iceRestartAttempts
        iceRestartAttempts += 1
        iceRestartsTotal += 1
        restartInFlight = true
        isReconnecting = true
        NSLog("[VOIID] ICE restart attempt \(attempt + 1)/\(Self.maxIceRestarts): \(reason)")

        restartBackoffTask?.cancel()
        restartBackoffTask = Task { [weak self] in
            // First attempt fires immediately; later ones back off (0s, 2s, 4s).
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                guard !Task.isCancelled else { return }
            }
            await self?.performIceRestart(callId: call.id, peerUserId: call.peerUserId, isVideo: call.isVideo)
        }
    }

    /// Build and send the restart offer. Refreshes TURN credentials first — they
    /// are short-lived, and a handover is exactly the moment a stale credential
    /// would leave us with no relay candidates and no way to recover.
    private func performIceRestart(callId: String, peerUserId: String, isVideo: Bool) async {
        guard let pc, let call = active, call.id == callId, call.state != .ended else {
            restartInFlight = false
            return
        }

        // Re-fetch ICE servers and push them into the existing peer connection.
        // setConfiguration keeps the connection (and its media) alive; only the
        // candidate gathering is affected.
        let fresh = await fetchIceServers()
        let config = pc.configuration
        config.iceServers = fresh
        if !pc.setConfiguration(config) {
            NSLog("[VOIID] setConfiguration for ICE restart failed — restarting with cached servers")
        }

        // Rates measured across a reconnect gap are meaningless.
        stats.resetRateBaseline()

        let constraints = RTCMediaConstraints(mandatoryConstraints: ["IceRestart": "true"],
                                              optionalConstraints: nil)
        do {
            let offer = try await pc.offer(for: constraints)
            let tuned = RTCSessionDescription(type: .offer,
                                              sdp: CallSDPTuning.tuneLocalDescription(offer.sdp))
            try await pc.setLocalDescription(tuned)
            // Same channel, same call_id — the peer treats this as renegotiation,
            // not a new incoming call (see handleIncomingOffer).
            socket.sendCallOffer(toUserId: peerUserId, callId: callId,
                                 callKind: isVideo ? "video" : "voice", sdp: tuned.sdp)
            NSLog("[VOIID] ICE restart offer sent for \(callId)")
        } catch {
            NSLog("[VOIID] ICE restart offer failed: \(error.localizedDescription)")
            restartInFlight = false
            // Don't end the call here — the ICE state handlers will trigger
            // another attempt, and the cap decides when to actually give up.
        }
    }

    /// A restart worked: clear the reconnect UI and let the call earn a fresh
    /// budget of attempts if the network misbehaves again later.
    private func handleIceRecovered() {
        guard restartInFlight || isReconnecting || iceRestartAttempts > 0 else { return }
        NSLog("[VOIID] ICE recovered — resetting restart budget")
        restartInFlight = false
        isReconnecting = false
        iceRestartAttempts = 0
        disconnectGraceTask?.cancel(); disconnectGraceTask = nil
        restartBackoffTask?.cancel(); restartBackoffTask = nil
    }

    /// `.failed` means this candidate set is dead. Restart now — no grace period.
    private func handleIceFailed() {
        guard let call = active, call.state != .ended else { return }
        disconnectGraceTask?.cancel(); disconnectGraceTask = nil
        // A failure invalidates any in-flight restart's assumptions; let the next
        // attempt through rather than waiting on an answer that isn't coming.
        restartInFlight = false
        requestIceRestart(reason: "ice connection failed")
        // As the answerer we don't send the restart offer (the caller does), so we
        // need a backstop or we'd sit in "Reconnecting…" forever if the caller is
        // gone. The caller's own path is bounded by the attempt cap.
        if !call.isOutgoing { startAnswererRecoveryWatchdog(callId: call.id) }
    }

    /// Answerer-side backstop: if the caller's restart offer never arrives and ICE
    /// never comes back, end the call instead of hanging in limbo.
    private func startAnswererRecoveryWatchdog(callId: String) {
        guard restartBackoffTask == nil else { return }
        restartBackoffTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            guard let call = self.active, call.id == callId, call.state != .ended else { return }
            if let pc = self.pc, pc.iceConnectionState == .connected || pc.iceConnectionState == .completed {
                self.handleIceRecovered()
                return
            }
            NSLog("[VOIID] no recovery from peer within watchdog — ending call \(callId)")
            self.pendingEndReason = .iceFailed
            self.endActiveCall(notifyPeer: true, fromCallKit: false)
        }
    }

    /// `.disconnected` fires constantly on mobile and usually heals itself within
    /// a second or two. Wait it out; only escalate if it's still bad afterwards.
    private func handleIceDisconnected() {
        guard disconnectGraceTask == nil else { return }
        guard let call = active, call.state == .connected || call.state == .connecting else { return }
        NSLog("[VOIID] ICE disconnected — \(Self.disconnectGrace) grace before restart")
        isReconnecting = true
        disconnectGraceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.disconnectGrace)
            guard !Task.isCancelled, let self else { return }
            self.disconnectGraceTask = nil
            guard let pc = self.pc, let current = self.active, current.id == call.id,
                  current.state != .ended else { return }
            let state = pc.iceConnectionState
            if state == .connected || state == .completed {
                self.handleIceRecovered()   // healed on its own, as most do
                return
            }
            self.requestIceRestart(reason: "ice disconnected past grace period")
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
        // RENEGOTIATION: an offer for a call that is already up. This is the peer
        // performing an ICE restart after a network handover — it is NOT a new
        // call. Do not ring, do not touch CallKit; just apply it and answer.
        // Without this branch the restart offer would ring the user again
        // mid-conversation and the recovery would never complete.
        if let call = active, call.id == callId, pc != nil,
           !awaitingOfferCallIds.contains(callId),
           call.state == .connected || call.state == .connecting {
            handleRenegotiationOffer(from: from, call: call, sdp: sdp)
            return
        }

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

    /// Apply a mid-call re-offer (the peer's ICE restart) and answer it in place.
    /// Never rings, never reports to CallKit, never rebuilds the peer connection —
    /// the media tracks and the CallKit call must survive untouched.
    private func handleRenegotiationOffer(from: String, call: ActiveCall, sdp: String) {
        NSLog("[VOIID] renegotiation offer for active call \(call.id) — answering in place")
        isReconnecting = true
        Task {
            guard let pc, let current = active, current.id == call.id, current.state != .ended else { return }
            do {
                try await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp))
                hasRemoteDescription = true
                drainPendingCandidates()
                let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil,
                                                                         optionalConstraints: nil))
                let tuned = RTCSessionDescription(type: .answer,
                                                  sdp: CallSDPTuning.tuneLocalDescription(answer.sdp))
                try await pc.setLocalDescription(tuned)
                socket.sendCallAnswer(toUserId: from.isEmpty ? current.peerUserId : from,
                                      callId: current.id, sdp: tuned.sdp)
                stats.resetRateBaseline()
                iceRestartsTotal += 1
            } catch {
                // A failed renegotiation is NOT a reason to drop a call whose
                // media may still be flowing. Log it; the ICE state machine will
                // decide whether this call is actually dead.
                NSLog("[VOIID] renegotiation failed (call continues): \(error.localizedDescription)")
            }
        }
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
                let tuned = RTCSessionDescription(type: .answer,
                                                  sdp: CallSDPTuning.tuneLocalDescription(answer.sdp))
                try await pc.setLocalDescription(tuned)
                socket.sendCallAnswer(toUserId: call.peerUserId, callId: call.id, sdp: tuned.sdp)
            } catch {
                NSLog("[VOIID] call answer failed: \(error.localizedDescription)")
                pendingEndReason = .setupFailed
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
        pendingEndReason = .declined
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
                // If this answered an ICE-restart offer, the exchange is done —
                // clear the in-flight flag so a later handover can restart again.
                // The attempt budget is only refunded once ICE actually connects.
                restartInFlight = false
            } catch {
                NSLog("[VOIID] setRemoteDescription(answer) failed: \(error.localizedDescription)")
                restartInFlight = false
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

    private func handleRemoteEnd(callId: String, reason: CallEndReason) {
        guard let call = active, call.id == callId else { return }
        pendingEndReason = reason
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
        isReconnecting = false
        if callConnectedAt == nil { callConnectedAt = Date() }
        everConnected = true
        if let pc { stats.start(pc: pc) }
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
            case .connected, .completed:
                self.handleIceRecovered()
                self.markConnected()

            case .disconnected:
                // Transient far more often than not — most of these heal in under
                // a second. Restarting immediately would cause more dropped calls
                // than it saves, so wait out a grace period first.
                self.handleIceDisconnected()

            case .failed:
                // Terminal for this candidate set. Restart immediately; only the
                // attempt cap inside requestIceRestart ends the call.
                self.handleIceFailed()

            case .closed:
                // We (or the peer connection itself) tore this down. Nothing to
                // recover — but only end if the call isn't already ending.
                if let call = self.active, call.state != .ended {
                    self.pendingEndReason = .iceFailed
                    self.endActiveCall(notifyPeer: true, fromCallKit: false)
                }

            default:
                break
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
