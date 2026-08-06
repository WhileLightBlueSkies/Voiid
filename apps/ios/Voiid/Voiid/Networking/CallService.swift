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
import CallKit
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
    /// The conversation this call belongs to, when we know it. Carried on the call
    /// because three separate things downstream are keyed by conversation and not by
    /// user: `POST /calls/ring`, the local call-history row, and the missed-call
    /// notification's thread + tap deep-link.
    var conversationId: String?
    /// This call arrived as an invitation into an existing CONFERENCE rather than as a 1:1
    /// ring. It gates the "add someone" affordance: a conference cannot be escalated again,
    /// and offering it would try to migrate a call that is already on the SFU.
    ///
    /// Note it is deliberately possible for this to be true while `conversationId` is nil —
    /// a conference is keyed on the CALL and belongs to no conversation, which is what keeps
    /// an invited stranger outside the contact-PIN gate in 020_reachability.sql.
    var isConferenceInvite: Bool = false
}

@MainActor
final class CallService: NSObject, ObservableObject {
    static let shared = CallService()

    // MARK: Published UI state
    @Published private(set) var active: ActiveCall?
    @Published private(set) var muted = false
    @Published private(set) var speakerOn = false
    /// The audio-output routes available RIGHT NOW (earpiece/speaker always; Bluetooth and
    /// wired appear only while such a device is connected) and which one is live. Drives the
    /// in-call route picker. Refreshed on every AVAudioSession route change.
    @Published var audioRoutes: [CallAudioRoute] = [.earpiece, .speaker]
    @Published var currentRoute: CallAudioRoute = .earpiece
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

    // MARK: Hold / call waiting
    /// WE put the call on hold (via CallKit's CXSetHeldCallAction, the in-app
    /// hold button, or implicitly by answering a second waiting call).
    @Published private(set) var isOnHold = false
    /// The PEER told us they're holding (inbound `call_hold`). Their media has
    /// stopped; the UI says so rather than looking frozen.
    @Published private(set) var peerOnHold = false
    /// A second inbound call is waiting while this one is up. The user chooses in
    /// CallKit's native call-waiting UI; see `reportWaitingCall`.
    @Published private(set) var hasWaitingCall = false

    /// call_ids we've already told the caller we're alerting for, so a VoIP push
    /// and the WS offer for the same call don't send `call_ringing` twice.
    private var ringingSentCallIds: Set<String> = []

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

    // MARK: Incoming ring cap
    //
    // An offer-backed incoming call used to have NO local bound at all — only the
    // push-without-offer window was timed (`startOfferTimeout`) — so a caller who let
    // it ring for two minutes made us ring for two minutes. That is now a problem as
    // well as a nuisance: the missed-call notification is scheduled at ring time, and
    // it must never be able to fire while the phone is still ringing.

    /// The longest we will alert for an inbound call before calling it missed.
    private static let incomingRingCap: Duration = .seconds(45)
    /// Margin between the ring ending and the backstop notification firing.
    private static let missedNotificationSlack: TimeInterval = 2
    private var ringCapTask: Task<Void, Never>?
    /// The user tapped Answer (even if the SDP hadn't landed yet and the call later
    /// died before connecting). An answered call is NEVER a missed call, so this
    /// survives independently of `everConnected`.
    private var localAnswerGiven = false

    // MARK: Call waiting
    //
    // A second inbound call arriving mid-call used to be answered with an
    // immediate `call_busy` — the user never learned anyone had called. Instead
    // we report it to CallKit so the OS shows its native call-waiting UI and the
    // user gets the choice. See `answerWaitingCall` for the (deliberately
    // bounded) semantics of accepting it.

    /// A second inbound call reported to CallKit and awaiting the user's choice.
    private struct WaitingCall {
        let id: String
        let uuid: UUID
        var peerUserId: String
        var title: String
        let isVideo: Bool
        /// nil while the VoIP push has rung but the SDP offer hasn't landed yet.
        var sdp: String?
        var conversationId: String?
        /// When the second call started alerting — the history row needs a start time
        /// and the primary call's `callStartedAt` belongs to a different call.
        let startedAt: Date
    }
    private var waitingCall: WaitingCall?
    /// The user answered the waiting call before its offer arrived.
    private var answerWaitingWhenOfferArrives = false
    private var waitingCallTimeoutTask: Task<Void, Never>?

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
        socket.onCallRinging = { [weak self] _, callId in
            Task { @MainActor in self?.handleRemoteRinging(callId: callId) }
        }
        socket.onCallTaken = { [weak self] callId, reason in
            Task { @MainActor in self?.handleCallTakenElsewhere(callId: callId, reason: reason) }
        }
        socket.onCallHold = { [weak self] _, callId in
            Task { @MainActor in self?.handlePeerHold(callId: callId, held: true) }
        }
        socket.onCallUnhold = { [weak self] _, callId in
            Task { @MainActor in self?.handlePeerHold(callId: callId, held: false) }
        }
    }

    // MARK: - Ringback (caller side)

    /// The callee's device is genuinely alerting → start ringback.
    ///
    /// This is the ONLY trigger for ringback. Starting it optimistically when the
    /// offer goes out would mean the caller hears "ringing" for a peer that is
    /// offline, unreachable, or whose push never landed — which is worse than
    /// silence, because it's a lie about the other person's phone.
    private func handleRemoteRinging(callId: String) {
        guard let call = active, call.id == callId, call.isOutgoing,
              call.state == .outgoingRinging else { return }
        CallToneService.shared.startRingback()
    }

    /// Tell the caller we've started alerting. Sent at the moment we report the
    /// call to CallKit (not when the offer is parsed), because that is the moment
    /// the user's phone actually rings.
    private func sendRingingIfNeeded(toUserId: String, callId: String) {
        guard !toUserId.isEmpty, !ringingSentCallIds.contains(callId) else { return }
        ringingSentCallIds.insert(callId)
        socket.sendCallRinging(toUserId: toUserId, callId: callId)
    }

    // MARK: - Hold

    /// Toggle hold from the in-app button. Routed through CallKit so the system
    /// in-call UI and ours never disagree; CallKit calls back into
    /// `callKitSetHeld`.
    func toggleHold() {
        guard let call = active, call.state == .connected else { return }
        CallManager.shared.requestHold(uuid: call.uuid, onHold: !isOnHold)
    }

    /// CallKit performed a hold/unhold — either the user asked, or CallKit did it
    /// implicitly because they answered a second call.
    func callKitSetHeld(uuid: UUID, held: Bool) {
        guard let call = active, call.uuid == uuid, call.state != .ended else { return }
        applyHold(held)
        // Mirror to the peer so their UI can say "on hold" and they can stop
        // rendering/sending into a call nobody is listening to.
        if !call.peerUserId.isEmpty {
            if held { socket.sendCallHold(toUserId: call.peerUserId, callId: call.id) }
            else { socket.sendCallUnhold(toUserId: call.peerUserId, callId: call.id) }
        }
    }

    /// Stop sending while held. Tracks are disabled rather than removed so there
    /// is no renegotiation — unhold is instant and the peer connection, its ICE
    /// state and its stats all survive untouched.
    private func applyHold(_ held: Bool) {
        isOnHold = held
        localAudioTrack?.isEnabled = !held && !muted
        localVideoTrack?.isEnabled = !held && videoEnabled && (active?.isVideo ?? false)
        // Only one call may own the audio route at a time; a held call gives it up.
        // CallKit's didActivate/didDeactivate will also drive this, and both
        // paths are idempotent, so they can't fight.
        RTCAudioSession.sharedInstance().isAudioEnabled = !held
        if held, let capturer = videoCapturer { capturer.stopCapture() }
        else if !held, let capturer = videoCapturer, active?.isVideo == true, !captureSuspendedForBackground {
            startCapture(capturer: capturer, front: usingFrontCamera)
        }
    }

    /// The peer is holding (or resumed). Their media has stopped arriving; say so
    /// instead of showing a frozen frame.
    private func handlePeerHold(callId: String, held: Bool) {
        guard let call = active, call.id == callId, call.state != .ended else { return }
        peerOnHold = held
        remoteVideoTrack?.isEnabled = !held
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
    ///
    /// DELIBERATELY does NOT cancel the pending missed-call notification, and does not
    /// route through `endActiveCall`. Being force-quit while the phone is ringing is
    /// precisely the case the scheduled request exists for: there will be no process
    /// left to notice the call was never answered, so the request the notification
    /// daemon is already holding is the only thing that can tell the user. Cleaning up
    /// here would silently delete the feature.
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
        // Whatever the reason, the set of available routes and the live one may have
        // changed — keep the picker truthful.
        refreshAudioRoutes()
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
    /// The peer's E.164 number, when we know it — CallKit needs this (not a user id)
    /// to match the call to an address-book contact. nil is fine: the call still
    /// works, it just won't link to a contact card.
    private func peerPhone(_ userId: String) -> String? {
        UserDirectory.shared.user(userId)?.phoneE164
    }

    /// `conversationId` is optional only because the system call surfaces (Recents,
    /// Siri) hand us a person, not a conversation — it is resolved from the local
    /// store when not supplied. It is NOT cosmetic: `POST /calls/ring` requires it,
    /// and without it the ring 400s, no VoIP push is sent, and a killed callee never
    /// hears the call at all.
    func startCall(peerUserId: String, title: String, isVideo: Bool, conversationId: String? = nil) {
        guard active == nil else { return }   // one call at a time
        // A group call already owns the audio route (see GroupCallService).
        guard !GroupCallService.shared.isActive else { return }
        let callId = UUID().uuidString
        let uuid = UUID()
        let convId = conversationId ?? LocalStore.conversationId(forPeer: peerUserId)
        active = ActiveCall(id: callId, uuid: uuid, peerUserId: peerUserId, title: title,
                            isVideo: isVideo, isOutgoing: true, state: .outgoingRinging,
                            conversationId: convId)
        videoEnabled = isVideo
        callUIMinimized = false
        beginCallTelemetry()

        Task {
            await setupPeerConnection(isVideo: isVideo)
            CallManager.shared.startOutgoingCall(uuid: uuid, handle: peerUserId, displayName: title,
                                                 hasVideo: isVideo, phoneNumber: peerPhone(peerUserId))
            CallManager.shared.reportOutgoingConnecting(uuid: uuid)
            // ── RING BEFORE OFFER. THIS ORDER IS THE WHOLE CALL. ─────────────────────
            //
            // `POST /calls/ring` does two things, and only one of them is the push:
            //   1. it wakes an offline callee, and
            //   2. it writes the Redis RING GRANT that authorizes this call_id's frames.
            //
            // The WS relay gates EVERY call frame — offer, answer, ICE, hangup — on that
            // grant, and when it is missing it drops the frame and *says nothing*
            // (deliberately: an error would tell a caller which user ids are reachable).
            //
            // This used to send the offer FIRST and ring afterwards. The offer is one WS
            // hop; the ring is an HTTPS round trip plus two Postgres queries. The offer
            // won the race, arrived with no grant written, and was silently discarded —
            // so the callee's phone rang from the push, they tapped accept, and there was
            // no offer to answer. That is the "accepts nothing / stuck on Connecting" bug.
            //
            // Awaited, not fire-and-forget, for the same reason.
            if let convId {
                struct RingBody: Encodable {
                    let to_user_id: String; let call_id: String
                    let call_kind: String; let conversation_id: String
                }
                do {
                    _ = try await api.request(
                        "POST", "calls/ring",
                        body: RingBody(to_user_id: peerUserId, call_id: callId,
                                       call_kind: isVideo ? "video" : "voice",
                                       conversation_id: convId),
                        as: EmptyResponse.self)
                } catch {
                    // The ring failed, so no grant exists and every frame we are about to
                    // send would be dropped in silence. Failing loudly here is the honest
                    // outcome: a call that cannot possibly connect must not present as
                    // ringing forever.
                    NSLog("[VOIID] calls/ring failed — no grant, aborting call: \(error)")
                    hangUp()
                    return
                }
            } else {
                // No conversation means /ring would 400 (it requires conversation_id and
                // checks shared membership), so no grant can exist and the relay will drop
                // everything. Previously this logged "WS offer only" and carried on, which
                // could never work — the offer had nowhere to go.
                NSLog("[VOIID] no conversation for \(peerUserId) — cannot ring, aborting call")
                hangUp()
                return
            }

            await createAndSendOffer(callId: callId, peerUserId: peerUserId, isVideo: isVideo)
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
        localAnswerGiven = false
        pendingEndReason = .unknown
        iceRestartAttempts = 0
        iceRestartsTotal = 0
        restartInFlight = false
        isReconnecting = false
        isOnHold = false
        peerOnHold = false
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
    /// Human-readable name for a peer, for every call surface (CallKit, in-call UI,
    /// call waiting). Resolves address-book name → profile name → phone → username.
    ///
    /// NEVER returns the raw user id. A UUID on the incoming-call screen was the most
    /// visible symptom of the app having no local contact store: the call paths had
    /// nothing to look a name up in, so they displayed the id they were handed.
    ///
    /// Resolution is deliberately LOCAL. The ring push carries no caller name — adding
    /// one would disclose who is calling whom to Apple and Google — so the callee
    /// resolves it here from `caller_id`, which works even on a cold push launch.
    private func peerName(_ userId: String, fallback: String? = nil) -> String {
        UserDirectory.shared.displayName(userId, fallback: fallback)
    }

    func reportIncomingCallFromVoIPPush(callId: String,
                                        callerId: String,
                                        kind: String,
                                        conversationId: String?,
                                        displayName: String?,
                                        completion: @escaping () -> Void) {
        // The WS offer beat the push (app was alive), or this is a duplicate push —
        // the call is already ringing, nothing to do. Still must call completion.
        if let active, active.id == callId { completion(); return }

        // Already on a different call → CALL WAITING. iOS requires us to report a
        // call for this push regardless; rather than reporting it and immediately
        // killing it (which told the user nothing), report it properly so they get
        // the native call-waiting UI and can choose. See `reportWaitingCall`.
        if let active, active.id != callId {
            // CallKit rejects an empty handle — fall back to a non-empty routing id.
            let handle = callerId.isEmpty ? (conversationId ?? callId) : callerId
            reportWaitingCall(callId: callId, from: callerId,
                              title: peerName(callerId, fallback: displayName),
                              isVideo: kind == "video", sdp: nil,
                              conversationId: conversationId,
                              completion: completion)
            // The offer still needs a live socket to reach us.
            WebSocketClient.shared.reconnect()
            return
        }

        let isVideo = (kind == "video")
        let uuid = UUID()
        let handle = callerId.isEmpty ? (conversationId ?? callId) : callerId
        active = ActiveCall(id: callId, uuid: uuid, peerUserId: callerId,
                            title: peerName(callerId, fallback: displayName),
                            isVideo: isVideo, isOutgoing: false, state: .incomingRinging,
                            conversationId: conversationId ?? LocalStore.conversationId(forPeer: callerId))
        videoEnabled = isVideo
        beginCallTelemetry()
        pendingIncomingOfferSDP = nil
        answerWhenOfferArrives = false
        awaitingOfferCallIds.insert(callId)

        // Hand the system the missed-call backstop BEFORE reporting to CallKit, i.e.
        // before anything can invoke PushKit's `completion` — from that moment iOS is
        // free to suspend or jetsam us and no further line here is guaranteed to run.
        // This ordering is the entire reason the notification survives a killed app.
        // (`add` is a cheap async hand-off to the notification daemon, so it does not
        // meaningfully delay the CallKit report.) See MissedCallNotifier.
        scheduleMissedBackstop(for: active)

        // THE mandatory bit: report to CallKit, complete the push from its callback.
        CallManager.shared.reportIncomingCall(uuid: uuid, handle: handle,
                                              displayName: peerName(callerId, fallback: displayName),
                                              hasVideo: isVideo,
                                              phoneNumber: peerPhone(callerId)) { ok in
            if !ok { NSLog("[VOIID] VoIP push: CallKit refused call \(callId)") }
            completion()
        }
        // We are now alerting → let the caller start ringback. `callerId` comes
        // from the (unauthenticated) push payload and may be empty; if it is, the
        // authenticated `call_offer` supplies it and we send from there instead.
        sendRingingIfNeeded(toUserId: callerId, callId: callId)

        // Now get the socket up so the offer (and ICE) can actually reach us — the
        // app may have been cold-launched by this push with no live connection.
        WebSocketClient.shared.reconnect()
        startOfferTimeout(for: callId)
        startIncomingRingCap(for: callId)
    }

    /// Hand the notification daemon the "you missed a call" banner for an inbound
    /// call we are about to start alerting for. Idempotent per call_id: the push and
    /// the WS offer both land here and the second submission REPLACES the first
    /// (usually with a better-resolved caller name).
    private func scheduleMissedBackstop(for call: ActiveCall?) {
        guard let call, !call.isOutgoing else { return }
        // Fire strictly after the ring can still be going, or the user would get a
        // "missed call" banner over a ringing phone.
        let delay = Double(Self.incomingRingCap.components.seconds) + Self.missedNotificationSlack
        MissedCallNotifier.schedule(callId: call.id, peerUserId: call.peerUserId,
                                    displayName: call.title, isVideo: call.isVideo,
                                    conversationId: call.conversationId, after: delay)
    }

    /// Hard bound on how long an inbound call may alert.
    ///
    /// `startOfferTimeout` only covers the push-rang-but-no-offer window; an
    /// offer-backed incoming call had no local bound at all and rang for as long as
    /// the caller cared to wait. Capping it is what makes the scheduled missed-call
    /// notification safe: the ring is guaranteed over before the banner is due.
    private func startIncomingRingCap(for callId: String) {
        ringCapTask?.cancel()
        ringCapTask = Task { [weak self] in
            try? await Task.sleep(for: Self.incomingRingCap)
            guard !Task.isCancelled, let self else { return }
            guard let call = self.active, call.id == callId,
                  call.state == .incomingRinging else { return }
            NSLog("[VOIID] incoming call \(callId) rang past the cap — treating as missed")
            // No decline frame: the user didn't refuse it, they just weren't there.
            self.pendingEndReason = .timeout
            self.endActiveCall(notifyPeer: true, fromCallKit: false)
        }
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
            if call.title.isEmpty || call.title == call.id || call.title == from {
                call.title = peerName(from)
            }
            call.conversationId = call.conversationId ?? LocalStore.conversationId(forPeer: from)
            active = call
            // The push may have rung us with no caller_id to reply to. Now we have
            // an authenticated one, so the caller can finally hear ringback.
            sendRingingIfNeeded(toUserId: from, callId: callId)
            // Re-submit the backstop with the identity we can actually trust: the push
            // payload is unauthenticated and often has no caller_id at all, so the
            // first submission may say "Unknown". Same identifier ⇒ it replaces.
            scheduleMissedBackstop(for: active)
            // The user already tapped Answer in CallKit while we had no SDP; now we can.
            if answerWhenOfferArrives {
                answerWhenOfferArrives = false
                callKitAnswer(uuid: call.uuid)
            }
            return
        }
        // Already on a different call → CALL WAITING (or attaching the SDP to a
        // waiting call a VoIP push already reported).
        if let active, active.id != callId {
            reportWaitingCall(callId: callId, from: from, title: peerName(from),
                              isVideo: kind == "video", sdp: sdp,
                              conversationId: nil)
            return
        }
        guard active == nil else { return }
        // No push (app was foregrounded, or VoIP push undelivered) — ring from the WS.
        let isVideo = (kind == "video")
        let uuid = UUID()
        pendingIncomingOfferSDP = sdp
        active = ActiveCall(id: callId, uuid: uuid, peerUserId: from, title: peerName(from),
                            isVideo: isVideo, isOutgoing: false, state: .incomingRinging,
                            conversationId: LocalStore.conversationId(forPeer: from))
        videoEnabled = isVideo
        beginCallTelemetry()
        // Ask the OS to show the native incoming-call UI.
        CallManager.shared.reportIncomingCall(uuid: uuid, handle: from,
                                              displayName: peerName(from), hasVideo: isVideo,
                                              phoneNumber: peerPhone(from)) { _ in }
        // Alerting now → the caller may start ringback.
        sendRingingIfNeeded(toUserId: from, callId: callId)
        // Even on this path the app can be killed mid-ring (the user force-quits from
        // the switcher), so the backstop is scheduled here too rather than relying on
        // teardown running.
        scheduleMissedBackstop(for: active)
        startIncomingRingCap(for: callId)
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

    // MARK: - Call waiting (second inbound call while busy)

    /// Report a second inbound call to CallKit so the OS shows its native
    /// call-waiting UI, instead of silently bouncing the caller with `call_busy`.
    ///
    /// SCOPE — deliberate and documented. Answering the waiting call ENDS the
    /// first one (see `answerWaitingCall`); it does not park it and let the user
    /// swap back and forth. True two-call hold/swap needs two concurrent
    /// RTCPeerConnections and a second `ActiveCall`, which is a structural change
    /// to this class. What's here gets the user the thing that actually mattered:
    /// they find out someone is calling and get to choose. Hold itself is fully
    /// implemented (`applyHold`) and is what CallKit drives on the first call
    /// during the transition.
    ///
    /// `sdp` is nil when a VoIP push rang us before the offer arrived; it's filled
    /// in later by `handleIncomingOffer`.
    private func reportWaitingCall(callId: String, from: String, title: String,
                                   isVideo: Bool, sdp: String?,
                                   conversationId: String?,
                                   completion: (() -> Void)? = nil) {
        // Offer landing for a waiting call we already reported — just attach it.
        if var waiting = waitingCall, waiting.id == callId {
            if let sdp, waiting.sdp == nil {
                waiting.sdp = sdp
                if !from.isEmpty { waiting.peerUserId = from }
                waiting.conversationId = waiting.conversationId
                    ?? conversationId
                    ?? LocalStore.conversationId(forPeer: waiting.peerUserId)
                waitingCall = waiting
                sendRingingIfNeeded(toUserId: waiting.peerUserId, callId: callId)
                // Authenticated identity at last — replace the backstop so the banner
                // names the caller instead of saying "Unknown".
                scheduleWaitingMissedBackstop(waiting)
                // The user hit Answer before the SDP existed; finish the job now.
                if answerWaitingWhenOfferArrives {
                    answerWaitingWhenOfferArrives = false
                    answerWaitingCall()
                }
            }
            completion?()
            return
        }
        // A THIRD call. One waiting call is as much as the native UI can present
        // meaningfully — this one is genuinely busy.
        guard waitingCall == nil else {
            if !from.isEmpty { socket.sendCallBusy(toUserId: from, callId: callId) }
            // The user is never shown this call at all, so without a record + banner
            // it would vanish completely. Post it immediately: the call is already
            // over (we just sent busy), there is nothing to wait for.
            let convId = conversationId ?? LocalStore.conversationId(forPeer: from)
            LocalStore.recordCall(id: callId, conversationId: convId,
                                  peerUserId: from.isEmpty ? nil : from,
                                  kind: isVideo ? "video" : "voice", direction: "incoming",
                                  outcome: "missed", startedAt: Date(), endedAt: Date())
            MissedCallNotifier.fireNow(callId: callId, peerUserId: from,
                                       displayName: title.isEmpty ? nil : title,
                                       isVideo: isVideo, conversationId: convId)
            completion?()
            return
        }

        let uuid = UUID()
        // Resolve through the directory rather than trusting `title`: callers pass the
        // peer's user id here when they have nothing better, and that must not reach
        // the call-waiting UI as a UUID.
        let handle = peerName(from, fallback: title.isEmpty ? nil : title)
        let waiting = WaitingCall(id: callId, uuid: uuid, peerUserId: from,
                                  title: handle, isVideo: isVideo, sdp: sdp,
                                  conversationId: conversationId
                                      ?? LocalStore.conversationId(forPeer: from),
                                  startedAt: Date())
        waitingCall = waiting
        hasWaitingCall = true
        // Same reasoning as the primary call: a VoIP push can report this one and the
        // app be suspended before anything else runs.
        scheduleWaitingMissedBackstop(waiting)
        CallManager.shared.reportIncomingCall(uuid: uuid, handle: handle, displayName: handle,
                                              hasVideo: isVideo,
                                              phoneNumber: peerPhone(from)) { [weak self] ok in
            Task { @MainActor in
                guard let self else { completion?(); return }
                if !ok {
                    // CallKit refused (Do Not Disturb, capacity). Fall back to the
                    // old behaviour so the caller isn't left ringing into nothing.
                    NSLog("[VOIID] call waiting: CallKit refused \(callId) — falling back to busy")
                    self.clearWaitingCall(sendBusy: true)
                }
                completion?()
            }
        }
        sendRingingIfNeeded(toUserId: from, callId: callId)
        startWaitingCallTimeout(for: callId)
    }

    /// Backstop banner for the SECOND call. Its ring window is bounded by
    /// `startWaitingCallTimeout`, not by the primary call's ring cap.
    private func scheduleWaitingMissedBackstop(_ waiting: WaitingCall) {
        let delay = Double(Self.offerTimeout.components.seconds) + Self.missedNotificationSlack
        MissedCallNotifier.schedule(callId: waiting.id, peerUserId: waiting.peerUserId,
                                    displayName: waiting.title, isVideo: waiting.isVideo,
                                    conversationId: waiting.conversationId, after: delay)
    }

    /// Don't let a waiting call ring forever if the user ignores it.
    private func startWaitingCallTimeout(for callId: String) {
        waitingCallTimeoutTask?.cancel()
        waitingCallTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.offerTimeout)
            guard !Task.isCancelled, let self else { return }
            guard let waiting = self.waitingCall, waiting.id == callId else { return }
            NSLog("[VOIID] call waiting: \(callId) unanswered — ending")
            self.clearWaitingCall(sendBusy: true)
        }
    }

    /// Tear down the waiting-call slot. `sendBusy` tells the second caller we're
    /// not taking it; the primary call is never touched by this.
    ///
    /// `takenElsewhere` is the verdict ("answer"/"decline") one of the user's OTHER
    /// devices already gave: we then say nothing to the caller (they were answered)
    /// and post no banner (nothing was missed).
    private func clearWaitingCall(sendBusy: Bool, decline: Bool = false,
                                  takenElsewhere: String? = nil) {
        guard let waiting = waitingCall else { return }
        // The user hit Answer and the SDP never showed up. That call FAILED; it was
        // not ignored, and telling them they missed it would be a lie.
        let userAnswered = answerWaitingWhenOfferArrives
        waitingCall = nil
        hasWaitingCall = false
        answerWaitingWhenOfferArrives = false
        waitingCallTimeoutTask?.cancel(); waitingCallTimeoutTask = nil
        ringingSentCallIds.remove(waiting.id)
        if !waiting.peerUserId.isEmpty, takenElsewhere == nil {
            if decline { socket.sendCallDecline(toUserId: waiting.peerUserId, callId: waiting.id) }
            else if sendBusy { socket.sendCallBusy(toUserId: waiting.peerUserId, callId: waiting.id) }
        }
        // A second call used to leave NO trace on any exit — five different
        // missed/declined outcomes vanished the moment the call-waiting UI went away.
        LocalStore.recordCall(
            id: waiting.id,
            conversationId: waiting.conversationId,
            peerUserId: waiting.peerUserId.isEmpty ? nil : waiting.peerUserId,
            kind: waiting.isVideo ? "video" : "voice",
            direction: "incoming",
            outcome: {
                if let takenElsewhere { return takenElsewhere == "answer" ? "answered" : "declined" }
                if decline { return "declined" }
                return userAnswered ? "failed" : "missed"
            }(),
            startedAt: waiting.startedAt,
            endedAt: Date()
        )
        // Declining is a deliberate act, not a missed call — drop the backstop. Every
        // other exit (ignored to timeout, second caller gave up, CallKit refused it)
        // genuinely was missed, and we know that NOW, so post it now rather than
        // leaving the timed request to catch up.
        if decline || userAnswered || takenElsewhere != nil {
            MissedCallNotifier.cancel(callId: waiting.id)
        } else {
            MissedCallNotifier.fireNow(callId: waiting.id, peerUserId: waiting.peerUserId,
                                       displayName: waiting.title, isVideo: waiting.isVideo,
                                       conversationId: waiting.conversationId)
        }
        // Same rule as the primary call: an inbound call nobody picked up must file in
        // Recents as `.unanswered`, or it looks like a completed call and the second
        // caller disappears from the phone app entirely.
        let endReason: CXCallEndedReason
        if let takenElsewhere {
            endReason = takenElsewhere == "answer" ? .answeredElsewhere : .declinedElsewhere
        } else if decline {
            endReason = .declinedElsewhere
        } else if userAnswered {
            endReason = .failed
        } else {
            endReason = .unanswered
        }
        CallManager.shared.endCall(uuid: waiting.uuid, reason: endReason)
    }

    /// One of the user's OTHER devices answered or declined this call.
    ///
    /// The WS relay used to tell only the FAR side about an answer, so a second
    /// device of the callee's kept ringing until the caller eventually hung up — and
    /// would then have posted "missed call" for a call that was answered. The server
    /// now fans the verdict back to the user's own channel (`call_taken`); this is the
    /// only path that can distinguish "nobody picked up" from "someone else did".
    private func handleCallTakenElsewhere(callId: String, reason: String) {
        if let waiting = waitingCall, waiting.id == callId {
            clearWaitingCall(sendBusy: false, takenElsewhere: reason)
            return
        }
        guard let call = active, call.id == callId, !call.isOutgoing else { return }
        // WE are the device that resolved it — this frame is the echo of our own
        // answer coming back off our own channel.
        guard !localAnswerGiven, !everConnected, call.state == .incomingRinging else { return }
        NSLog("[VOIID] call \(callId) \(reason)ed on another device — stopping this ring")
        // Nothing was missed and the caller needs no hangup from us: the sibling
        // device is talking to them.
        MissedCallNotifier.cancel(callId: callId)
        pendingEndReason = .declined   // ⇒ outcome "declined", never "missed"
        CallManager.shared.endCall(uuid: call.uuid,
                                   reason: reason == "answer" ? .answeredElsewhere : .declinedElsewhere)
        endActiveCall(notifyPeer: false, fromCallKit: true)
        // recordCall upserts on the call id, so this corrects the row endActiveCall
        // just wrote — a call answered on your tablet belongs in history as answered.
        if reason == "answer" {
            LocalStore.recordCall(id: callId, conversationId: call.conversationId,
                                  peerUserId: call.peerUserId.isEmpty ? nil : call.peerUserId,
                                  kind: call.isVideo ? "video" : "voice", direction: "incoming",
                                  outcome: "answered", startedAt: callStartedAt ?? Date(),
                                  endedAt: Date())
        }
    }

    /// The user chose the waiting call. Ends the first call, then promotes the
    /// second into the single `active` slot and answers it normally.
    private func answerWaitingCall() {
        guard let waiting = waitingCall else { return }
        guard let sdp = waiting.sdp else {
            // Answered from the lock screen before the offer landed — remember the
            // intent; reportWaitingCall finishes this when the SDP arrives.
            answerWaitingWhenOfferArrives = true
            return
        }
        waitingCall = nil
        hasWaitingCall = false
        waitingCallTimeoutTask?.cancel(); waitingCallTimeoutTask = nil
        // Answered — the backstop must die before anything else can go wrong.
        MissedCallNotifier.cancel(callId: waiting.id)

        // Release the first call BEFORE the second takes the audio route — at most
        // one call may own it. endActiveCall's deferred `active = nil` is keyed on
        // the old call_id, so it can't clobber the call we're about to install.
        if let first = active, first.state != .ended {
            NSLog("[VOIID] call waiting: answering \(waiting.id), ending \(first.id)")
            pendingEndReason = .localHangup
            endActiveCall(notifyPeer: true, fromCallKit: false)
        }
        // Silence the first call's end cue — the user is switching calls, not
        // finishing one, and a farewell beep over the new call would be wrong.
        CallToneService.shared.stopAll()

        active = ActiveCall(id: waiting.id, uuid: waiting.uuid, peerUserId: waiting.peerUserId,
                            title: waiting.title, isVideo: waiting.isVideo,
                            isOutgoing: false, state: .incomingRinging)
        videoEnabled = waiting.isVideo
        callUIMinimized = false
        beginCallTelemetry()
        pendingIncomingOfferSDP = sdp
        callKitAnswer(uuid: waiting.uuid)
    }

    /// Called by CallManager when the user accepts via CallKit (or the in-app button
    /// routes through CallKit). Builds the answer and completes negotiation.
    func callKitAnswer(uuid: UUID) {
        // Answering the SECOND, waiting call takes a different route entirely.
        if let waiting = waitingCall, waiting.uuid == uuid {
            answerWaitingCall()
            return
        }
        guard var call = active, call.uuid == uuid else { return }
        // ANSWERED. Kill the backstop here — before any of the work below, which can
        // fail — and remember it, because a call that fails after being answered is a
        // failed call, never a missed one.
        localAnswerGiven = true
        ringCapTask?.cancel(); ringCapTask = nil
        MissedCallNotifier.cancel(callId: call.id)
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
        // The SECOND (waiting) caller gave up before the user chose. Clear the
        // call-waiting UI; the first call carries on completely undisturbed.
        if let waiting = waitingCall, waiting.id == callId {
            clearWaitingCall(sendBusy: false)
            return
        }
        guard let call = active, call.id == callId else { return }
        pendingEndReason = reason
        // Ringback stops first, then the reason gets its own short cue. Both are
        // best-effort: CallKit may deactivate the session underneath a cue, which
        // truncates it. Never worth failing a teardown over.
        CallToneService.shared.stopRingback()
        switch reason {
        case .busy: CallToneService.shared.playBusy()
        case .declined: CallToneService.shared.playDeclined()
        default: break
        }
        CallManager.shared.endCall(uuid: call.uuid)
        endActiveCall(notifyPeer: false, fromCallKit: false)
    }

    /// Hang up from the in-app button.
    // MARK: - Conference migration (1:1 -> SFU)

    /// The call id currently migrating from the 1:1 leg onto the SFU, if any.
    ///
    /// While this is set, an inbound `call_hangup` for that id is the EXPECTED end of the old
    /// leg rather than the end of the call: the conversation continues on the SFU. Without
    /// this distinction the peer's hangup would tear down a call the user is still in.
    private(set) var migratingCallId: String?

    /// Enter the make-before-break window. Both legs run briefly side by side so the user
    /// never hears a gap, and the `calls` row must stay live throughout or `/escalate` and
    /// `/join` would 409 against an ended call.
    func beginMigration(callId: String) {
        guard active?.id == callId else { return }
        migratingCallId = callId
    }

    /// The SFU leg has taken over: retire the 1:1 leg ONLY.
    ///
    /// Emphatically not `endActiveCall` — the call has not ended, it changed transport.
    /// CallKit keeps its session, the audio route stays claimed until the conference layer
    /// calls `adoptAudioSession()`, and no call-history row is written, because writing an
    /// outcome here would file a completed call that is still in progress.
    func finishMigration(callId: String, notifyPeer: Bool) {
        guard let call = active, call.id == callId else { migratingCallId = nil; return }
        if notifyPeer {
            WebSocketClient.shared.sendCallHangup(toUserId: call.peerUserId, callId: callId)
        }
        migratingCallId = nil

        // THE LEG ONLY. Everything the full teardown also does — marking the call .ended,
        // clearing `active`, disabling the RTC audio session, reporting to CallKit — must NOT
        // happen: the user is still on this call, and the SFU is about to take the same audio
        // session over.
        offerTimeoutTask?.cancel(); offerTimeoutTask = nil
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
    }

    /// The escalation failed before handover. The 1:1 leg was never touched, so there is
    /// nothing to undo but the flag — clearing it restores the normal meaning of a hangup.
    func cancelMigration(callId: String) {
        guard migratingCallId == callId else { return }
        migratingCallId = nil
    }

    /// Report an invitation into an existing conference to CallKit, through the same surface
    /// as a 1:1 ring so the native UI, the system call log and the ringtone all work
    /// unchanged. `conversationId` is nil by design: a conference belongs to no conversation.
    func reportConferenceInvite(callId: String, inviterUserId: String, isVideo: Bool) {
        if let active, active.id == callId { return }
        reportIncomingCallFromVoIPPush(
            callId: callId,
            callerId: inviterUserId,
            kind: isVideo ? "video" : "voice",
            conversationId: nil,
            displayName: nil,
            completion: {}
        )
        // Marked after reporting: the report path builds the ActiveCall, and this is the one
        // field it cannot infer from a push that looks identical to a 1:1 ring.
        if active?.id == callId { active?.isConferenceInvite = true }
    }

    func hangUp() {
        guard let call = active else { return }
        CallManager.shared.requestEnd(uuid: call.uuid)   // routes back via callKitEnd
    }

    func callKitStart(uuid: UUID) { /* audio session handled by CallKit didActivate */ }

    func callKitEnd(uuid: UUID) {
        // Declining the waiting call must leave the call we're actually on alone.
        if let waiting = waitingCall, waiting.uuid == uuid {
            clearWaitingCall(sendBusy: false, decline: true)
            return
        }
        // Record WHY. This used to leave `pendingEndReason` at `.unknown`, so tapping
        // Decline in the native CallKit UI — by far the most common way a call is
        // refused — was persisted as outcome "missed". With a notification hanging off
        // that value, the user would be told they missed a call they had just
        // deliberately rejected.
        if let call = active, call.uuid == uuid, pendingEndReason == .unknown {
            pendingEndReason = (!call.isOutgoing && !everConnected && !localAnswerGiven)
                ? .declined
                : .localHangup
        }
        endActiveCall(notifyPeer: true, fromCallKit: true)
    }

    /// Tear down the call. `notifyPeer` sends a hangup; `fromCallKit` avoids
    /// re-entering the CallKit end transaction.
    func endActiveCall(notifyPeer: Bool, fromCallKit: Bool) {
        guard let call = active else { return }
        offerTimeoutTask?.cancel(); offerTimeoutTask = nil
        ringCapTask?.cancel(); ringCapTask = nil
        awaitingOfferCallIds.remove(call.id)
        ringingSentCallIds.remove(call.id)
        answerWhenOfferArrives = false

        // Ringback must never outlive the call it belongs to, on ANY teardown
        // path — that's the guarantee this single line buys, regardless of which
        // of the many callers got here first.
        CallToneService.shared.stopRingback()
        // A short cue on the way out, but only for outcomes the user didn't
        // already hear one for (busy/declined play theirs in handleRemoteEnd) and
        // only where it says something true.
        switch pendingEndReason {
        case .setupFailed, .iceFailed: CallToneService.shared.playFailed()
        case .busy, .declined: break
        default: if everConnected { CallToneService.shared.playEndCue() }
        }
        isOnHold = false
        peerOnHold = false
        if notifyPeer, !call.peerUserId.isEmpty { socket.sendCallHangup(toUserId: call.peerUserId, callId: call.id) }
        // Tell CallKit WHY it ended. An inbound call that never connected is a MISSED
        // call and must be reported as `.unanswered`, or it files in Recents as a
        // normal completed call and the user never sees they were called.
        if !fromCallKit {
            let endReason: CXCallEndedReason
            if everConnected {
                endReason = .remoteEnded
            } else if pendingEndReason == .declined || pendingEndReason == .busy {
                endReason = .declinedElsewhere
            } else {
                // Never connected and not explicitly refused — missed, in both
                // directions (an outgoing call nobody picked up is "unanswered" too).
                endReason = .unanswered
            }
            CallManager.shared.endCall(uuid: call.uuid, reason: endReason)
        }

        // Local call history. Previously calls left NO trace on the device once the
        // CallKit UI went away — a missed call was simply invisible. Recorded before
        // the network call so it survives being offline.
        let outcome: String = {
            if everConnected { return "answered" }
            switch pendingEndReason {
            case .declined: return "declined"
            case .busy: return "declined"
            case .setupFailed, .iceFailed: return "failed"
            // Answered but dead before media flowed: a failure, not a missed call.
            default: return (call.isOutgoing || localAnswerGiven) ? "failed" : "missed"
            }
        }()
        LocalStore.recordCall(
            id: call.id,
            conversationId: call.conversationId,
            peerUserId: call.peerUserId.isEmpty ? nil : call.peerUserId,
            kind: call.isVideo ? "video" : "voice",
            direction: call.isOutgoing ? "outgoing" : "incoming",
            outcome: outcome,
            startedAt: callStartedAt ?? Date(),
            endedAt: Date()
        )

        // The missed-call banner. The scheduled request is only a backstop for the app
        // not being alive; when we ARE alive we know the answer right now, so either
        // replace it with an immediate banner or drop it entirely. `outcome` already
        // encodes every exclusion the banner needs: answered, declined, busy, failed,
        // and outgoing calls are all something other than "missed".
        if outcome == "missed" {
            MissedCallNotifier.fireNow(callId: call.id, peerUserId: call.peerUserId,
                                       displayName: call.title, isVideo: call.isVideo,
                                       conversationId: call.conversationId)
        } else {
            MissedCallNotifier.cancel(callId: call.id)
        }

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
        // Hold already silences us; unmuting while held must not start sending.
        localAudioTrack?.isEnabled = !m && !isOnHold
    }
    func toggleMute() { setMuted(!muted) }

    func toggleSpeaker() {
        // Keep the legacy speaker button working: it now just selects between the two
        // always-present routes, so it and the route picker never disagree.
        selectAudioRoute(speakerOn ? .earpiece : .speaker)
    }

    /// Let the routing extension (a different file, so it can't touch the private setter)
    /// keep `speakerOn` in step with the chosen route.
    func speakerOnChanged(_ on: Bool) { speakerOn = on }

    func toggleVideo() {
        videoEnabled.toggle()
        localVideoTrack?.isEnabled = videoEnabled && !isOnHold
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
        // Answered. Ringback must die here, before any media reaches the speaker —
        // a tone bleeding into the first second of a conversation is exactly the
        // artefact this whole path exists to avoid.
        CallToneService.shared.stopRingback()
        if callConnectedAt == nil { callConnectedAt = Date() }
        everConnected = true
        if let pc { stats.start(pc: pc) }
        CallManager.shared.reportOutgoingConnected(uuid: call.uuid)
        // A video call held at arm's length belongs on the speaker, not the earpiece —
        // UNLESS a headset is connected, in which case it belongs there.
        //
        // This used to force the speaker unconditionally, so answering a video call with
        // AirPods in yanked the audio out of them and onto the phone. The user plugged in or
        // paired a device precisely so the call would go there; overriding that is the one
        // thing the default must not do. Only forced once, on connect — the user can still
        // toggle either way afterwards.
        if call.isVideo, !speakerOn, !hasExternalAudioDevice {
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
