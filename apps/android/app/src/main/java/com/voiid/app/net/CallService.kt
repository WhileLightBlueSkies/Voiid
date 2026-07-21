package com.voiid.app.net

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.voiid.app.main.CallKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoCapturer
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import java.util.concurrent.Executors

/**
 * Real 1:1 WebRTC voice/video engine (clean-room; no Signal code).
 *
 * Owns a single [PeerConnection] for the active call, wires DTLS-SRTP encrypted
 * media directly peer-to-peer (the server only ever relays signaling + at most TURN
 * media), and drives call setup over the existing [WebSocketClient] relay
 * (`call_offer` / `call_answer` / `call_ice` / `call_hangup` / `call_decline`).
 *
 * State machine:
 *   outgoing: RINGING_OUT -> CONNECTING -> CONNECTED -> ENDED
 *   incoming: RINGING_IN  -> CONNECTING -> CONNECTED -> ENDED
 *
 * All PeerConnection mutation happens on a dedicated single thread ([exec]); UI reads
 * the immutable [state] StateFlow. Video frames are rendered by binding
 * [SurfaceViewRenderer]s via [setLocalRenderer] / [setRemoteRenderer].
 *
 * Group calls are OUT OF SCOPE for v1 (group SRTP keys come from GroupSession.callKeys
 * later); [startOutgoing] no-ops for a group request.
 */
object CallManager {

    enum class Phase { RINGING_OUT, RINGING_IN, CONNECTING, CONNECTED, ENDED }

    data class CallState(
        val callId: String,
        val peerUserId: String,
        val peerName: String,
        val conversationId: String?,
        val kind: CallKind,
        val incoming: Boolean,
        val phase: Phase,
        val muted: Boolean = false,
        val speaker: Boolean = false,
        val videoEnabled: Boolean = true,
        val connectedAtMs: Long? = null,
        val hasRemoteVideo: Boolean = false,
        /** We put the call on hold: our mic (and camera) are off and the peer knows. */
        val onHold: Boolean = false,
        /** The PEER told us they put us on hold (`call_hold`). */
        val peerOnHold: Boolean = false,
        /**
         * ICE has lost its path and we are re-gathering. Purely a UI signal: media may resume at
         * any moment, so this must never be confused with ENDED. Cleared on ICE recovery.
         */
        val reconnecting: Boolean = false,
    )

    /**
     * A SECOND incoming call that arrived while we were already on one — "call waiting".
     * It has no PeerConnection of its own; it is a pending offer we are alerting the user
     * about, and it either gets declined or is promoted into the one live call slot.
     */
    data class WaitingCall(
        val callId: String,
        val peerUserId: String,
        val peerName: String,
        val conversationId: String?,
        val kind: CallKind,
    )

    private const val STREAM_ID = "voiid_stream"
    private const val AUDIO_TRACK_ID = "voiid_audio"
    private const val VIDEO_TRACK_ID = "voiid_video"

    private val json = Json { ignoreUnknownKeys = true }

    private val _state = MutableStateFlow<CallState?>(null)
    val state: StateFlow<CallState?> = _state.asStateFlow()

    private val _waiting = MutableStateFlow<WaitingCall?>(null)
    /** Non-null while a second call is ringing us during an active call. See [WaitingCall]. */
    val waiting: StateFlow<WaitingCall?> = _waiting.asStateFlow()

    private lateinit var appContext: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    // All WebRTC/PeerConnection work is serialized onto this single thread.
    private val exec = Executors.newSingleThreadExecutor()

    private var initialized = false
    private lateinit var eglBase: EglBase
    private lateinit var factory: PeerConnectionFactory
    val eglBaseContext: EglBase.Context get() = eglBase.eglBaseContext

    private var pc: PeerConnection? = null
    private var audioSource: AudioSource? = null
    private var localAudioTrack: AudioTrack? = null
    private var videoSource: VideoSource? = null
    private var localVideoTrack: VideoTrack? = null
    private var videoCapturer: VideoCapturer? = null
    private var surfaceHelper: SurfaceTextureHelper? = null
    private var remoteVideoTrack: VideoTrack? = null

    private var localRenderer: SurfaceViewRenderer? = null
    private var remoteRenderer: SurfaceViewRenderer? = null

    // Trickle ICE received before we've applied the remote description.
    private val pendingRemoteCandidates = ArrayList<IceCandidate>()
    private var remoteDescSet = false
    // Incoming: user tapped Accept before the call_offer arrived over WS.
    private var acceptPending = false
    private var frontCamera = true

    // ---- network resilience ----------------------------------------------------

    /** Give up after this many ICE restarts and end the call honestly rather than hanging. */
    private const val MAX_ICE_RESTARTS = 3
    /**
     * ICE DISCONNECTED is usually a transient blip — a couple of lost STUN checks, a brief
     * radio stall — and heals itself within a second or two. Renegotiating on every blip
     * causes far more disruption than it fixes, so DISCONNECTED only escalates to a restart
     * if it is *still* disconnected after this grace period. FAILED is terminal and skips it.
     */
    private const val DISCONNECT_GRACE_MS = 3_000L
    /** TURN credentials are short-lived; re-fetch rather than restart with expired ones. */
    private const val ICE_SERVER_TTL_MS = 4 * 60_000L

    private val mainHandler = Handler(Looper.getMainLooper())

    private var cachedIceServers: List<PeerConnection.IceServer> = emptyList()
    private var iceServersFetchedAtMs = 0L

    private var iceRestartAttempts = 0
    /** An ICE-restart offer is out and we're waiting to see ICE come back up. */
    private var restartInFlight = false
    /**
     * True once this call has completed a full offer/answer exchange. It is the discriminator
     * that lets the answerer tell a *renegotiation* offer (same call_id, call already up —
     * apply silently) from a genuine new incoming call (ring the user).
     */
    @Volatile private var hasNegotiated = false
    private var disconnectGrace: Runnable? = null
    private var restartWatchdog: Runnable? = null

    private var netMonitor: CallNetworkMonitor? = null
    private var metrics: CallMetricsCollector? = null
    private var qualityJob: kotlinx.coroutines.Job? = null
    private var endReason: String? = null

    private val _quality = MutableStateFlow(CallStatsSnapshot())
    /** Live connection health for a weak-signal indicator in the call UI. */
    val quality: StateFlow<CallStatsSnapshot> = _quality.asStateFlow()

    // ---- lifecycle -------------------------------------------------------------

    /** Idempotent one-time init: WebRTC factory + WS call-signal handler. Safe to call often. */
    fun init(context: Context) {
        if (initialized) return
        appContext = context.applicationContext
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(appContext)
                .createInitializationOptions(),
        )
        eglBase = EglBase.create()
        val encoder = DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true)
        val decoder = DefaultVideoDecoderFactory(eglBase.eglBaseContext)
        factory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(encoder)
            .setVideoDecoderFactory(decoder)
            .createPeerConnectionFactory()

        // Route inbound call signaling from the WS relay to us. Distinct callback slot
        // from ChatStore's message/typing handlers, so both coexist on the one socket.
        WebSocketClient.get(appContext).onCallSignal = { sig -> onSignal(sig) }
        initialized = true
    }

    // ---- outbound (this device starts the call) --------------------------------

    fun startOutgoing(conversationId: String, peerUserId: String?, peerName: String, kind: CallKind) {
        if (peerUserId.isNullOrBlank()) return   // 1:1 only — no peer, nothing to dial
        if (_state.value != null) return          // one call at a time
        // A group call owns the mic, the audio route and the foreground service. Never run both.
        if (GroupCallManager.isActive) return
        init(appContextOrNull() ?: return)
        val callId = java.util.UUID.randomUUID().toString()
        _state.value = CallState(
            callId = callId, peerUserId = peerUserId, peerName = peerName,
            conversationId = conversationId, kind = kind, incoming = false,
            phase = Phase.RINGING_OUT, videoEnabled = kind == CallKind.VIDEO,
            speaker = kind == CallKind.VIDEO,
        )
        startForegroundService()
        beginCallSession()
        // Wake an offline callee via push (best effort) in parallel with WS offer.
        scope.launch(Dispatchers.IO) {
            runCatching { CallApi(appContext).ring(peerUserId, callId, kind, conversationId) }
        }
        exec.execute {
            val servers = iceServers()
            createPeerConnection(servers) ?: return@execute
            addLocalMedia(kind)
            applyAudioRoute(kind == CallKind.VIDEO)
            val p = pc ?: return@execute
            p.createOffer(object : SdpObserverAdapter() {
                override fun onCreateSuccess(sdp: SessionDescription) {
                    val tuned = tune(sdp)
                    p.setLocalDescription(SdpObserverAdapter(), tuned)
                    WebSocketClient.get(appContext).sendCallOffer(peerUserId, callId, kind, tuned.description)
                }
            }, offerAnswerConstraints(kind))
        }
    }

    // ---- inbound signaling -----------------------------------------------------

    private fun onSignal(sig: WebSocketClient.CallSignal) {
        when (sig.type) {
            "call_offer" -> onRemoteOffer(sig)
            "call_answer" -> onRemoteAnswer(sig)
            "call_ice" -> onRemoteIce(sig)
            "call_ringing" -> onRemoteRinging(sig)
            "call_hold" -> onRemoteHold(sig, held = true)
            "call_unhold" -> onRemoteHold(sig, held = false)
            "call_hangup", "call_decline", "call_busy" -> onRemoteEnd(sig)
        }
    }

    /**
     * The callee's device is genuinely alerting -> start ringback. This is the ONLY trigger for
     * ringback: starting it when we sent the offer would have us ring for a phone that is off,
     * out of coverage, or whose push never landed.
     */
    private fun onRemoteRinging(sig: WebSocketClient.CallSignal) {
        val s = _state.value ?: return
        if (s.callId != sig.callId) return
        if (s.incoming) return                      // we're the callee; nothing to ring back at
        if (s.phase != Phase.RINGING_OUT) return    // already connecting/connected/ended
        CallTones.startRingback()
    }

    /** The peer put us on hold, or took us off it. Their media stops either way. */
    private fun onRemoteHold(sig: WebSocketClient.CallSignal, held: Boolean) {
        val s = _state.value ?: return
        if (s.callId != sig.callId) return
        update { it.copy(peerOnHold = held) }
    }

    /** A ring push (FCM) arrived before/independent of the WS offer — show incoming UI now. */
    fun onRingPush(callId: String, callerId: String, callerName: String, kind: CallKind, conversationId: String?) {
        appContextOrNull()?.let { init(it) }
        if (_state.value?.callId == callId) return
        if (_waiting.value?.callId == callId) return
        // Busy in a group call — don't ring over it or we'd tear down live group media.
        if (GroupCallManager.isActive) {
            runCatching { WebSocketClient.get(appContext).sendCallBusy(callerId, callId) }
            return
        }
        if (_state.value != null) {
            raiseWaiting(WaitingCall(callId, callerId, callerName, conversationId, kind))
            return
        }
        _state.value = CallState(
            callId = callId, peerUserId = callerId, peerName = callerName,
            conversationId = conversationId, kind = kind, incoming = true,
            phase = Phase.RINGING_IN, videoEnabled = kind == CallKind.VIDEO,
            speaker = kind == CallKind.VIDEO,
        )
        CallForegroundService.showIncoming(appContext, _state.value!!)
        announceRinging(callerId, callId)
    }

    /**
     * Tell the caller our device is alerting, so they get a ringback. Sent exactly where the
     * user-visible alert is raised, never earlier — the frame's whole meaning is "a human is
     * being notified right now". It rides the normal outbox, so a momentarily-down socket
     * delays the ringback rather than losing it.
     */
    private fun announceRinging(callerId: String, callId: String) {
        runCatching { WebSocketClient.get(appContext).sendCallRinging(callerId, callId) }
    }

    private fun onRemoteOffer(sig: WebSocketClient.CallSignal) {
        val current = _state.value
        // RENEGOTIATION, not a new call: same call_id on a call that has already completed an
        // offer/answer exchange. This is the peer's ICE restart after their network moved.
        // It must be applied silently — no ring, no incoming UI, no notification, no state
        // reset. Missing this case is what turns one handover into a second phantom call.
        if (current != null && current.callId == sig.callId && hasNegotiated && pc != null) {
            onRenegotiationOffer(sig, current)
            return
        }
        val kind = if (sig.callKind == "video") CallKind.VIDEO else CallKind.VOICE

        // The offer for a call we are already alerting the user about as call-waiting. Keep the
        // SDP: if they choose to take it, we replay this exact offer into the freed call slot.
        if (_waiting.value?.callId == sig.callId) {
            waitingOfferSdp = sig.sdp ?: waitingOfferSdp
            return
        }

        // A second call while we're already on one.
        if (current != null && current.callId != sig.callId) {
            if (canOfferCallWaiting(current)) {
                waitingOfferSdp = sig.sdp
                raiseWaiting(
                    WaitingCall(
                        callId = sig.callId, peerUserId = sig.fromUserId,
                        peerName = sig.fromUserId, conversationId = sig.conversationId, kind = kind,
                    ),
                )
            } else {
                // Genuinely busy — see canOfferCallWaiting for why this is deliberate.
                WebSocketClient.get(appContext).sendCallBusy(sig.fromUserId, sig.callId)
            }
            return
        }
        val name = current?.peerName?.takeIf { it.isNotBlank() } ?: sig.fromUserId
        _state.value = CallState(
            callId = sig.callId, peerUserId = sig.fromUserId, peerName = name,
            conversationId = sig.conversationId ?: current?.conversationId, kind = kind,
            incoming = true, phase = Phase.RINGING_IN,
            videoEnabled = kind == CallKind.VIDEO, speaker = kind == CallKind.VIDEO,
        )
        CallForegroundService.showIncoming(appContext, _state.value!!)
        announceRinging(sig.fromUserId, sig.callId)
        beginCallSession()
        val sdp = sig.sdp ?: return
        exec.execute {
            val servers = iceServers()
            createPeerConnection(servers) ?: return@execute
            pc?.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() { remoteDescSet = true; drainCandidates(); if (acceptPending) doAnswer() }
            }, SessionDescription(SessionDescription.Type.OFFER, sdp))
        }
    }

    /**
     * Apply a renegotiation (ICE-restart) offer for the call we are ALREADY on.
     *
     * Deliberately minimal: set the remote description, answer, done. No ring, no incoming
     * notification, no media re-attach (the tracks and their senders are still live), no
     * phase change — from the user's point of view nothing happened, which is the entire goal.
     */
    private fun onRenegotiationOffer(sig: WebSocketClient.CallSignal, s: CallState) {
        val sdp = sig.sdp ?: return
        exec.execute {
            val p = pc ?: return@execute
            // Glare: both ends restarted at the same instant, so we hold a local offer and are
            // being handed a remote one. Someone has to yield. We use a fixed, symmetric rule —
            // the side that originally received the call yields — so both ends always agree on
            // who backs down and we can't deadlock trading offers.
            if (restartInFlight) {
                if (!s.incoming) return@execute       // we win: keep our own offer in flight
                runCatching {
                    p.setLocalDescription(
                        SdpObserverAdapter(),
                        SessionDescription(SessionDescription.Type.ROLLBACK, ""),
                    )
                }
                restartInFlight = false
                cancelRestartWatchdog()
            }
            p.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    exec.execute {
                        remoteDescSet = true
                        drainCandidates()
                        answerRenegotiation(s)
                    }
                }
            }, SessionDescription(SessionDescription.Type.OFFER, sdp))
        }
    }

    /** Build + send the answer to a renegotiation offer. Runs on [exec]. */
    private fun answerRenegotiation(s: CallState) {
        val p = pc ?: return
        p.createAnswer(object : SdpObserverAdapter() {
            override fun onCreateSuccess(sdp: SessionDescription) {
                val tuned = tune(sdp)
                p.setLocalDescription(SdpObserverAdapter(), tuned)
                WebSocketClient.get(appContext).sendCallAnswer(s.peerUserId, s.callId, tuned.description)
            }
        }, offerAnswerConstraints(s.kind))
    }

    private fun onRemoteAnswer(sig: WebSocketClient.CallSignal) {
        val sdp = sig.sdp ?: return
        // Answered: kill ringback now, not when media arrives, so it can never overlap voice.
        CallTones.stopRingback()
        // An answer to a restart offer resolves it; an answer to the first offer means the
        // session is negotiated and any later same-call_id offer is a renegotiation.
        val wasRestart = restartInFlight
        exec.execute {
            pc?.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    exec.execute {
                        remoteDescSet = true
                        hasNegotiated = true
                        restartInFlight = false
                        drainCandidates()
                    }
                }
            }, SessionDescription(SessionDescription.Type.ANSWER, sdp))
        }
        // A restart answer must not drag a live call back to the CONNECTING spinner.
        if (!wasRestart && _state.value?.phase != Phase.CONNECTED) {
            update { it.copy(phase = Phase.CONNECTING) }
        }
    }

    private fun onRemoteIce(sig: WebSocketClient.CallSignal) {
        val c = sig.candidate ?: return
        val cand = (c["candidate"] as? JsonPrimitive)?.contentOrNull ?: return
        val mid = (c["sdpMid"] as? JsonPrimitive)?.contentOrNull
        val idx = (c["sdpMLineIndex"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0
        // Candidates for a call-waiting offer we haven't taken must not be fed into the live
        // PeerConnection — they belong to a session that does not exist yet.
        if (_state.value?.callId != sig.callId) return
        val ice = IceCandidate(mid, idx, cand)
        exec.execute {
            if (remoteDescSet) pc?.addIceCandidate(ice) else pendingRemoteCandidates.add(ice)
        }
    }

    private fun onRemoteEnd(sig: WebSocketClient.CallSignal) {
        // The second caller gave up (or cancelled) before we chose — drop the waiting slot.
        if (_waiting.value?.callId == sig.callId) { clearWaiting(); return }
        if (_state.value?.callId != sig.callId) return
        val reason = when (sig.type) {
            "call_decline" -> "declined"
            "call_busy" -> "busy"
            else -> "remote-hangup"
        }
        // Audible feedback while the ENDED frame is on screen: a declined or busy call should
        // sound different from one the peer simply hung up on.
        CallTones.stopRingback()
        when (reason) {
            "declined", "busy" -> CallTones.playBusy()
            else -> if (_state.value?.connectedAtMs != null) CallTones.playEnded()
        }
        endInternal(notifyPeer = false, reason = reason)
    }

    // ---- call waiting ----------------------------------------------------------

    /**
     * The pending offer behind [_waiting], kept so accepting it can be served without asking
     * the caller to re-offer. Cleared with the waiting slot.
     */
    @Volatile private var waitingOfferSdp: String? = null

    /**
     * Whether a second incoming call should be offered to the user rather than refused.
     *
     * We only offer call waiting over a call that is actually *up*. Over a call still ringing or
     * mid-setup, `call_busy` is the honest answer: there is no established call to hold, the
     * user is already looking at a ringing screen, and stacking a second alert on top of it is
     * confusing rather than useful. One waiting call at a time, for the same reason.
     */
    private fun canOfferCallWaiting(current: CallState): Boolean =
        _waiting.value == null &&
            (current.phase == Phase.CONNECTED || current.phase == Phase.CONNECTING) &&
            current.phase != Phase.ENDED

    /** Publish the waiting call and alert the user (notification + in-call banner). */
    private fun raiseWaiting(call: WaitingCall) {
        _waiting.value = call
        CallForegroundService.showWaiting(appContext, call)
        // We ARE alerting, so the second caller gets a truthful ringback like anyone else.
        announceRinging(call.peerUserId, call.callId)
    }

    private fun clearWaiting() {
        _waiting.value = null
        waitingOfferSdp = null
        runCatching { CallForegroundService.cancelWaiting(appContext) }
    }

    /** Reject the waiting call; the call in progress is untouched. */
    fun declineWaiting() {
        val w = _waiting.value ?: return
        runCatching { WebSocketClient.get(appContext).sendCallDecline(w.peerUserId, w.callId) }
        clearWaiting()
    }

    /**
     * Take the waiting call.
     *
     * Android has no CallKit/Telecom multi-call surface unless the app adopts
     * `ConnectionService`, and this engine holds exactly one [PeerConnection], one mic capture
     * and one audio route — deliberately, because that invariant is what keeps routing,
     * ICE restart and the foreground service simple and correct. So "answer the second call"
     * is implemented as an explicit **swap**: the current call is hung up (the peer is properly
     * notified, never left on a zombie call), and the waiting offer is then replayed into the
     * freed slot exactly as if it had just arrived.
     *
     * The user always chooses. That is the substantive change over the old behaviour, where a
     * second call was silently refused with `call_busy` and the user never learned it happened.
     */
    fun acceptWaiting() {
        val w = _waiting.value ?: return
        val sdp = waitingOfferSdp
        _waiting.value = null
        waitingOfferSdp = null
        runCatching { CallForegroundService.cancelWaiting(appContext) }

        if (_state.value != null) endInternal(notifyPeer = true, reason = "swapped")

        // Let teardown settle first: releaseWebRtc is queued on exec and restoreAudioRoute runs
        // now, so the replayed offer must land after both. exec serializes the WebRTC half; this
        // short hop covers the audio-route half and the ENDED frame the UI is showing.
        scope.launch {
            kotlinx.coroutines.delay(250)
            if (_state.value != null) return@launch    // something else claimed the slot
            onRemoteOffer(
                WebSocketClient.CallSignal(
                    type = "call_offer",
                    fromUserId = w.peerUserId,
                    callId = w.callId,
                    callKind = if (w.kind == CallKind.VIDEO) "video" else "voice",
                    sdp = sdp,
                    candidate = null,
                    conversationId = w.conversationId,
                ),
            )
            // The offer path raises the incoming UI; the user already said yes, so answer it.
            if (sdp != null) accept()
        }
    }

    // ---- user actions (from the call UI) --------------------------------------

    /** Answer an incoming call. */
    fun accept() {
        val s = _state.value ?: return
        if (!s.incoming) return
        update { it.copy(phase = Phase.CONNECTING) }
        CallForegroundService.cancelIncoming(appContext)
        startForegroundService()
        exec.execute {
            if (remoteDescSet && pc != null) doAnswer() else acceptPending = true
        }
    }

    private fun doAnswer() {
        val s = _state.value ?: return
        acceptPending = false
        addLocalMedia(s.kind)
        applyAudioRoute(s.kind == CallKind.VIDEO)
        pc?.createAnswer(object : SdpObserverAdapter() {
            override fun onCreateSuccess(sdp: SessionDescription) {
                val tuned = tune(sdp)
                pc?.setLocalDescription(SdpObserverAdapter(), tuned)
                // We've now completed offer/answer: any further offer on this call_id is a
                // renegotiation to apply silently, not a new call to ring.
                hasNegotiated = true
                WebSocketClient.get(appContext).sendCallAnswer(s.peerUserId, s.callId, tuned.description)
            }
        }, offerAnswerConstraints(s.kind))
    }

    /** Reject an incoming call. */
    fun decline() {
        val s = _state.value ?: return
        WebSocketClient.get(appContext).sendCallDecline(s.peerUserId, s.callId)
        endInternal(notifyPeer = false, reason = "declined")
    }

    /** Hang up an active/outgoing call. */
    fun hangup() = endInternal(notifyPeer = true, reason = "local-hangup")

    /**
     * End the call because the OS is tearing us down (task swiped from Recents). Identical to
     * [hangup] but safe to call from a service callback: the peer is always notified so they
     * aren't left on a zombie call.
     */
    fun hangupFromSystem() {
        if (_state.value == null) return
        endInternal(notifyPeer = true, reason = "local-hangup")
    }

    fun toggleMute() {
        val s = _state.value ?: return
        val muted = !s.muted
        // Hold outranks mute: un-muting while held must not quietly start sending audio again.
        exec.execute { localAudioTrack?.setEnabled(!muted && !(_state.value?.onHold ?: false)) }
        update { it.copy(muted = muted) }
    }

    /**
     * Put the call on hold, or take it off hold.
     *
     * Hold is implemented at the track level rather than by renegotiating to `sendonly`/
     * `inactive`: disabling a track stops it producing media immediately, keeps the
     * PeerConnection and its ICE state completely intact (so hold costs nothing to undo and
     * cannot interact with an in-flight ICE restart), and needs no SDP round trip. The peer is
     * told over signaling so their UI can say "On hold" instead of silently hearing nothing —
     * which is exactly the difference between hold and a broken call.
     */
    fun toggleHold() {
        val s = _state.value ?: return
        if (s.phase != Phase.CONNECTED && s.phase != Phase.CONNECTING) return
        val hold = !s.onHold
        exec.execute {
            runCatching { localAudioTrack?.setEnabled(!hold && !(_state.value?.muted ?: false)) }
            if (s.kind == CallKind.VIDEO) {
                runCatching { localVideoTrack?.setEnabled(!hold && (_state.value?.videoEnabled ?: false)) }
                // Release the camera while held; nobody is watching and it costs battery.
                if (hold) runCatching { videoCapturer?.stopCapture() }
                else if (_state.value?.videoEnabled == true) runCatching { startCapture() }
            }
        }
        runCatching {
            val ws = WebSocketClient.get(appContext)
            if (hold) ws.sendCallHold(s.peerUserId, s.callId) else ws.sendCallUnhold(s.peerUserId, s.callId)
        }
        update { it.copy(onHold = hold) }
    }

    fun toggleSpeaker() {
        val s = _state.value ?: return
        val on = !s.speaker
        applyAudioRoute(on)
        update { it.copy(speaker = on) }
    }

    fun toggleVideo() {
        val s = _state.value ?: return
        if (s.kind != CallKind.VIDEO) return
        if (s.onHold) return   // held calls send nothing; resume first
        val on = !s.videoEnabled
        exec.execute {
            localVideoTrack?.setEnabled(on)
            if (on) runCatching { startCapture() } else runCatching { videoCapturer?.stopCapture() }
        }
        update { it.copy(videoEnabled = on) }
    }

    fun switchCamera() {
        exec.execute {
            (videoCapturer as? CameraVideoCapturer)?.switchCamera(null)
            frontCamera = !frontCamera
        }
    }

    // ---- host-activity lifecycle (background camera correctness) ----------------

    /** True while capture was stopped because the app went to the background without a FGS. */
    private var videoPausedForBackground = false

    /**
     * The call host left the foreground (and is *not* in PiP — PiP keeps the activity visible
     * and capturing). Android only permits background camera access while a camera-type
     * foreground service is live; if that service isn't running, keep publishing a frozen or
     * black frame is worse than nothing, so stop capture cleanly and resume on return.
     */
    fun onHostBackground() {
        val s = _state.value ?: return
        if (s.kind != CallKind.VIDEO) return
        if (CallForegroundService.running) return   // camera FGS holds the capture legally
        exec.execute {
            if (videoCapturer != null && !videoPausedForBackground) {
                runCatching { videoCapturer?.stopCapture() }
                videoPausedForBackground = true
            }
        }
    }

    /** Back in the foreground: restart capture if we paused it, so no frozen/black frames. */
    fun onHostForeground() {
        val s = _state.value ?: return
        if (s.kind != CallKind.VIDEO) return
        exec.execute {
            if (!videoPausedForBackground) return@execute
            videoPausedForBackground = false
            if (_state.value?.videoEnabled == true) startCapture()
        }
    }

    fun setLocalRenderer(r: SurfaceViewRenderer?) {
        val old = localRenderer
        localRenderer = r
        exec.execute {
            if (old != null && old !== r) runCatching { localVideoTrack?.removeSink(old) }
            if (r != null) runCatching { localVideoTrack?.addSink(r) }
        }
    }

    fun setRemoteRenderer(r: SurfaceViewRenderer?) {
        val old = remoteRenderer
        remoteRenderer = r
        exec.execute {
            if (old != null && old !== r) runCatching { remoteVideoTrack?.removeSink(old) }
            if (r != null) runCatching { remoteVideoTrack?.addSink(r) }
        }
    }

    /**
     * Detach and release a renderer that is leaving the composition for good.
     *
     * Sink removal and `release()` are both serialized onto [exec] so a frame can never be
     * delivered to a half-released surface. Renderers are only detached when the call UI
     * actually leaves the composition — never merely because the app was backgrounded or
     * entered PiP, where rendering must continue.
     */
    fun detachRenderer(r: SurfaceViewRenderer, remote: Boolean) {
        if (remote && remoteRenderer === r) remoteRenderer = null
        if (!remote && localRenderer === r) localRenderer = null
        exec.execute {
            runCatching { if (remote) remoteVideoTrack?.removeSink(r) else localVideoTrack?.removeSink(r) }
            runCatching { r.release() }
        }
    }

    // ---- WebRTC plumbing -------------------------------------------------------

    /**
     * The one place RTCConfiguration is built, so an ICE restart re-applies exactly the same
     * policies with only the ICE servers refreshed. GATHER_CONTINUALLY matters here: it lets
     * WebRTC surface candidates from a newly-arrived interface without a full restart.
     */
    private fun rtcConfig(iceServers: List<PeerConnection.IceServer>) =
        PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
        }

    private fun createPeerConnection(iceServers: List<PeerConnection.IceServer>): PeerConnection? {
        pc = factory.createPeerConnection(rtcConfig(iceServers), pcObserver)
        return pc
    }

    private fun addLocalMedia(kind: CallKind) {
        val p = pc ?: return
        if (localAudioTrack == null) {
            val aSource = factory.createAudioSource(MediaConstraints())
            val aTrack = factory.createAudioTrack(AUDIO_TRACK_ID, aSource).apply { setEnabled(true) }
            audioSource = aSource
            localAudioTrack = aTrack
            p.addTrack(aTrack, listOf(STREAM_ID))
        }
        if (kind == CallKind.VIDEO && localVideoTrack == null) {
            val capturer = createCameraCapturer() ?: return
            val helper = SurfaceTextureHelper.create("VoiidCapture", eglBase.eglBaseContext)
            val vSource = factory.createVideoSource(capturer.isScreencast)
            capturer.initialize(helper, appContext, vSource.capturerObserver)
            val vTrack = factory.createVideoTrack(VIDEO_TRACK_ID, vSource).apply { setEnabled(true) }
            videoCapturer = capturer
            surfaceHelper = helper
            videoSource = vSource
            localVideoTrack = vTrack
            localRenderer?.let { vTrack.addSink(it) }
            p.addTrack(vTrack, listOf(STREAM_ID))
            startCapture()
        }
    }

    private fun startCapture() {
        runCatching { videoCapturer?.startCapture(1280, 720, 30) }
    }

    private fun createCameraCapturer(): VideoCapturer? {
        val enumerator = Camera2Enumerator(appContext)
        val names = enumerator.deviceNames
        names.firstOrNull { enumerator.isFrontFacing(it) }?.let { return enumerator.createCapturer(it, null) }
        names.firstOrNull()?.let { return enumerator.createCapturer(it, null) }
        return null
    }

    private fun drainCandidates() {
        pendingRemoteCandidates.forEach { pc?.addIceCandidate(it) }
        pendingRemoteCandidates.clear()
    }

    private val pcObserver = object : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) {
            val s = _state.value ?: return
            val obj = buildString {
                append("{")
                append("\"candidate\":").append(JsonPrimitive(candidate.sdp))
                append(",\"sdpMid\":").append(JsonPrimitive(candidate.sdpMid))
                append(",\"sdpMLineIndex\":").append(candidate.sdpMLineIndex)
                append("}")
            }
            WebSocketClient.get(appContext).sendCallIce(s.peerUserId, s.callId, obj)
        }

        /**
         * The heart of surviving a real network. The old behaviour — end the call on FAILED —
         * is exactly the drop we're fixing: a WiFi→cellular handover reliably produces FAILED
         * once the old candidates die, and the correct response is to re-gather, not hang up.
         */
        override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) {
            when (newState) {
                PeerConnection.IceConnectionState.CONNECTED,
                PeerConnection.IceConnectionState.COMPLETED -> {
                    // Whatever we were worried about resolved itself (or our restart worked).
                    cancelDisconnectGrace()
                    cancelRestartWatchdog()
                    exec.execute { restartInFlight = false; iceRestartAttempts = 0 }
                    markConnected()
                }
                // Transient by nature — give it a moment to heal before touching anything.
                PeerConnection.IceConnectionState.DISCONNECTED -> armDisconnectGrace()
                // Terminal: ICE has given up on every pair. Re-gather immediately.
                PeerConnection.IceConnectionState.FAILED -> {
                    cancelDisconnectGrace()
                    requestIceRestart("ice_failed")
                }
                // CLOSED only happens once we've disposed the PC ourselves.
                PeerConnection.IceConnectionState.CLOSED ->
                    if (_state.value?.phase != Phase.ENDED) endInternal(notifyPeer = true, reason = "ice-closed")
                else -> Unit
            }
        }

        override fun onTrack(transceiver: RtpTransceiver) {
            val track = transceiver.receiver?.track() ?: return
            if (track is VideoTrack) {
                remoteVideoTrack = track
                exec.execute { remoteRenderer?.let { track.addSink(it) } }
                update { it.copy(hasRemoteVideo = true) }
            }
        }

        override fun onAddTrack(receiver: RtpReceiver, streams: Array<out org.webrtc.MediaStream>?) {
            val track = receiver.track()
            if (track is VideoTrack) {
                remoteVideoTrack = track
                exec.execute { remoteRenderer?.let { track.addSink(it) } }
                update { it.copy(hasRemoteVideo = true) }
            }
        }

        override fun onSignalingChange(p0: PeerConnection.SignalingState?) {}
        override fun onIceConnectionReceivingChange(p0: Boolean) {}
        override fun onIceGatheringChange(p0: PeerConnection.IceGatheringState?) {}
        override fun onIceCandidatesRemoved(p0: Array<out IceCandidate>?) {}
        override fun onAddStream(p0: org.webrtc.MediaStream?) {}
        override fun onRemoveStream(p0: org.webrtc.MediaStream?) {}
        override fun onDataChannel(p0: org.webrtc.DataChannel?) {}
        override fun onRenegotiationNeeded() {}
    }

    private fun markConnected() {
        val s = _state.value ?: return
        metrics?.onConnected()
        CallTones.stopRingback()
        // ICE is up: whatever we were reconnecting from is over. Routed through the same main
        // -thread post as the set, so a DISCONNECTED->CONNECTED flap can't land out of order
        // and leave the banner stuck on.
        markReconnecting(false)
        if (s.phase == Phase.CONNECTED) return
        update { it.copy(phase = Phase.CONNECTED, connectedAtMs = System.currentTimeMillis()) }
        startForegroundService()
        scope.launch(Dispatchers.IO) {
            runCatching { CallApi(appContext).status(s.callId, "connected") }
        }
    }

    // ---- teardown --------------------------------------------------------------

    private fun endInternal(notifyPeer: Boolean, reason: String) {
        val s = _state.value ?: return
        endReason = endReason ?: reason
        // Ringback must die here no matter which path ended the call — timeout, local hangup,
        // ICE giving up. A tone that outlives its call is the worst version of this feature.
        CallTones.stopRingback()
        if (reason == "ice-failed" || reason == "ice-closed") CallTones.playFailed()
        if (notifyPeer && s.phase != Phase.ENDED) {
            runCatching { WebSocketClient.get(appContext).sendCallHangup(s.peerUserId, s.callId) }
        }
        scope.launch(Dispatchers.IO) {
            runCatching { CallApi(appContext).status(s.callId, "ended") }
        }
        // Anonymous aggregate — counters only, and it can never fail the call (see CallStats).
        runCatching {
            metrics?.report(
                callId = s.callId,
                connected = s.connectedAtMs != null,
                endReason = endReason ?: reason,
            )
        }
        endCallSession()
        update { it.copy(phase = Phase.ENDED, reconnecting = false) }
        exec.execute { releaseWebRtc() }
        restoreAudioRoute()
        CallForegroundService.stop(appContext)
        // Let the UI show the ENDED frame briefly, then clear.
        scope.launch {
            kotlinx.coroutines.delay(600)
            if (_state.value?.phase == Phase.ENDED) _state.value = null
        }
    }

    private fun releaseWebRtc() {
        runCatching { videoCapturer?.stopCapture() }
        runCatching { videoCapturer?.dispose() }
        runCatching { videoSource?.dispose() }
        runCatching { surfaceHelper?.dispose() }
        runCatching { localAudioTrack?.dispose() }
        runCatching { audioSource?.dispose() }
        runCatching { pc?.dispose() }
        videoCapturer = null; videoSource = null; surfaceHelper = null
        localVideoTrack = null; localAudioTrack = null; audioSource = null
        remoteVideoTrack = null; pc = null
        pendingRemoteCandidates.clear(); remoteDescSet = false; acceptPending = false
        videoPausedForBackground = false
        localRenderer = null; remoteRenderer = null
        hasNegotiated = false; restartInFlight = false; iceRestartAttempts = 0
    }

    // ---- network resilience: session, ICE restart, SDP tuning ------------------

    /**
     * Start the per-call resilience machinery: watch the device's transport for handovers,
     * begin sampling stats, and tell the signaling socket a call is up so it reconnects
     * aggressively. Idempotent — both call directions funnel through here.
     */
    private fun beginCallSession() {
        endReason = null
        iceRestartAttempts = 0
        restartInFlight = false
        hasNegotiated = false

        runCatching { WebSocketClient.get(appContext).callActive = true }

        if (netMonitor == null) {
            netMonitor = CallNetworkMonitor(appContext) { reason ->
                // Fires on a binder thread; requestIceRestart hops to exec itself.
                requestIceRestart(reason)
            }.also { runCatching { it.start() } }
        }

        if (metrics == null) {
            val collector = CallMetricsCollector(appContext, exec)
            metrics = collector
            runCatching { collector.start { pc } }
            // Mirror the collector's snapshot so the UI can observe CallManager alone.
            // StateFlow.collect never completes, so this job is cancelled in endCallSession.
            qualityJob?.cancel()
            qualityJob = scope.launch {
                runCatching { collector.snapshot.collect { _quality.value = it } }
            }
        }
    }

    /** Tear the resilience machinery down. Safe to call more than once. */
    private fun endCallSession() {
        // Drop the looping ringback but let a busy/failed/ended cue play out — it is feedback
        // *about* this teardown, so cutting it off here would silence the thing we just started.
        CallTones.release(keepOneShots = true)
        cancelDisconnectGrace()
        cancelRestartWatchdog()
        runCatching { WebSocketClient.get(appContext).callActive = false }
        qualityJob?.cancel(); qualityJob = null
        netMonitor?.let { runCatching { it.stop() } }
        netMonitor = null
        // The collector is stopped but NOT nulled here — endInternal already asked it to
        // upload, and that POST runs on its own IO scope after sampling has stopped.
        metrics?.let { runCatching { it.stop() } }
        metrics = null
        _quality.value = CallStatsSnapshot()
    }

    /**
     * ICE servers with a short TTL cache. TURN credentials are deliberately short-lived, so a
     * restart that happens minutes into a call must not reuse the ones we fetched at dial time —
     * expired credentials mean the relay candidate silently fails to allocate, which on a
     * symmetric-NAT cellular network is the difference between reconnecting and not.
     */
    private fun iceServers(forceRefresh: Boolean = false): List<PeerConnection.IceServer> {
        val now = System.currentTimeMillis()
        val fresh = cachedIceServers.isNotEmpty() && (now - iceServersFetchedAtMs) < ICE_SERVER_TTL_MS
        if (!forceRefresh && fresh) return cachedIceServers
        val servers = fetchIceServers()
        if (servers.isNotEmpty()) {
            cachedIceServers = servers
            iceServersFetchedAtMs = now
        }
        return servers
    }

    /** Apply our local-SDP tweaks (Opus FEC + DTX) to a freshly created offer/answer. */
    private fun tune(sdp: SessionDescription): SessionDescription =
        SessionDescription(sdp.type, SdpTweaks.enableOpusFecDtx(sdp.description))

    /**
     * Ask for an ICE restart. Callable from any thread; the actual PeerConnection work is
     * serialized onto [exec] like everything else.
     */
    private fun requestIceRestart(reason: String) {
        val s = _state.value ?: return
        if (s.phase != Phase.CONNECTING && s.phase != Phase.CONNECTED) return
        markReconnecting(true)
        exec.execute { doIceRestart(reason) }
    }

    /** Publish/clear the UI's "Reconnecting…" flag. Callable from any thread. */
    private fun markReconnecting(on: Boolean) {
        mainHandler.post {
            val s = _state.value ?: return@post
            if (s.phase == Phase.ENDED || s.reconnecting == on) return@post
            _state.value = s.copy(reconnecting = on)
        }
    }

    /**
     * Re-gather ICE for the SAME call: create an offer with `IceRestart=true` and send it as a
     * normal `call_offer` under the existing call_id. The peer recognises the call_id and
     * applies it silently via [onRenegotiationOffer] — critically, it does not re-ring.
     *
     * Runs on [exec].
     */
    private fun doIceRestart(reason: String) {
        val s = _state.value ?: return
        if (s.phase == Phase.ENDED) return
        val p = pc ?: return
        // Nothing to restart until the first offer/answer has completed.
        if (!hasNegotiated) return
        if (restartInFlight) return
        if (iceRestartAttempts >= MAX_ICE_RESTARTS) {
            android.util.Log.w("VOIID", "ICE restart budget exhausted ($reason) — ending call")
            mainHandler.post { endInternal(notifyPeer = true, reason = "ice-failed") }
            return
        }

        iceRestartAttempts++
        restartInFlight = true
        metrics?.iceRestarts = iceRestartAttempts
        android.util.Log.i("VOIID", "ICE restart #$iceRestartAttempts ($reason)")

        // Refresh TURN credentials and push them into the live PeerConnection before we
        // re-gather, so the restart can allocate a fresh relay candidate if it needs one.
        runCatching {
            val servers = iceServers(forceRefresh = true)
            if (servers.isNotEmpty()) p.setConfiguration(rtcConfig(servers))
        }

        val constraints = offerAnswerConstraints(s.kind).apply {
            mandatory.add(MediaConstraints.KeyValuePair("IceRestart", "true"))
        }
        p.createOffer(object : SdpObserverAdapter() {
            override fun onCreateSuccess(sdp: SessionDescription) {
                val tuned = tune(sdp)
                p.setLocalDescription(object : SdpObserverAdapter() {
                    override fun onSetSuccess() {
                        // Queued by WebSocketClient if the socket happens to be down — a
                        // handover often takes the signaling socket with it.
                        WebSocketClient.get(appContext)
                            .sendCallOffer(s.peerUserId, s.callId, s.kind, tuned.description)
                        armRestartWatchdog()
                    }
                    override fun onSetFailure(error: String?) {
                        exec.execute { restartInFlight = false }
                    }
                }, tuned)
            }
            override fun onCreateFailure(error: String?) {
                exec.execute { restartInFlight = false }
            }
        }, constraints)
    }

    /**
     * A restart offer can be lost outright (the peer is mid-handover too, or the relay dropped
     * it). If ICE hasn't come back by the time this fires, try again — with a widening delay —
     * until the attempt budget runs out.
     */
    private fun armRestartWatchdog() {
        cancelRestartWatchdog()
        val backoffMs = 4_000L * iceRestartAttempts.coerceAtLeast(1)   // 4s, 8s, 12s
        val r = Runnable {
            restartWatchdog = null
            exec.execute {
                val s = _state.value ?: return@execute
                if (s.phase == Phase.ENDED) return@execute
                if (!restartInFlight) return@execute      // ICE recovered; nothing to do
                restartInFlight = false
                if (iceRestartAttempts >= MAX_ICE_RESTARTS) {
                    mainHandler.post { endInternal(notifyPeer = true, reason = "ice-failed") }
                } else {
                    doIceRestart("restart_timeout")
                }
            }
        }
        restartWatchdog = r
        mainHandler.postDelayed(r, backoffMs)
    }

    private fun cancelRestartWatchdog() {
        restartWatchdog?.let { mainHandler.removeCallbacks(it) }
        restartWatchdog = null
    }

    /** Start the DISCONNECTED grace timer — see [DISCONNECT_GRACE_MS]. */
    private fun armDisconnectGrace() {
        // Show "Reconnecting…" as soon as the path is lost, not only once we escalate to a
        // restart: the freeze the user is hearing starts *now*, and a call that looks dead for
        // three silent seconds is the thing this state exists to prevent. It costs nothing if
        // the blip heals — CONNECTED clears it again.
        markReconnecting(true)
        if (disconnectGrace != null) return
        val r = Runnable {
            disconnectGrace = null
            requestIceRestart("ice_disconnected")
        }
        disconnectGrace = r
        mainHandler.postDelayed(r, DISCONNECT_GRACE_MS)
    }

    private fun cancelDisconnectGrace() {
        disconnectGrace?.let { mainHandler.removeCallbacks(it) }
        disconnectGrace = null
    }

    // ---- audio routing ---------------------------------------------------------

    private var savedAudioMode = AudioManager.MODE_NORMAL
    private var audioConfigured = false
    private var routeWatcher: AudioDeviceCallback? = null

    /**
     * Put the device into communication mode and pick an output.
     *
     * A plugged-in headset or connected Bluetooth headset always wins over the speaker/earpiece
     * choice — that's what users expect, and it matches every other calling app. [speaker] only
     * decides between the built-in speaker and the earpiece when nothing external is attached.
     *
     * `MODE_IN_COMMUNICATION` is (re)asserted here, and this runs again on every device
     * add/remove, so the mode survives backgrounding and mid-call route changes.
     */
    private fun applyAudioRoute(speaker: Boolean) {
        val am = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (!audioConfigured) { savedAudioMode = am.mode; audioConfigured = true }
        runCatching { am.mode = AudioManager.MODE_IN_COMMUNICATION }
        registerRouteWatcher(am)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Modern, explicit routing: pick the device rather than toggling global flags.
            runCatching {
                val devices = am.availableCommunicationDevices
                val preferred = devices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        it.type == AudioDeviceInfo.TYPE_HEARING_AID ||
                        it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
                } ?: devices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                        it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                        it.type == AudioDeviceInfo.TYPE_USB_HEADSET
                } ?: devices.firstOrNull {
                    if (speaker) {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                    } else {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                    }
                } ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                preferred?.let { am.setCommunicationDevice(it) }
            }
            return
        }

        @Suppress("DEPRECATION")
        runCatching {
            val bluetooth = hasDevice(am, AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
            val wired = hasDevice(am, AudioDeviceInfo.TYPE_WIRED_HEADSET) ||
                hasDevice(am, AudioDeviceInfo.TYPE_WIRED_HEADPHONES) ||
                hasDevice(am, AudioDeviceInfo.TYPE_USB_HEADSET)
            if (bluetooth) {
                am.startBluetoothSco()
                am.isBluetoothScoOn = true
                am.isSpeakerphoneOn = false
            } else {
                am.isBluetoothScoOn = false
                am.stopBluetoothSco()
                am.isSpeakerphoneOn = speaker && !wired
            }
        }
    }

    private fun hasDevice(am: AudioManager, type: Int): Boolean =
        runCatching {
            am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type == type }
        }.getOrDefault(false)

    /**
     * Follow headset/Bluetooth connect + disconnect for the life of the call. Without this a
     * headset plugged in mid-call keeps playing out of the speaker.
     */
    private fun registerRouteWatcher(am: AudioManager) {
        if (routeWatcher != null) return
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = reapplyRoute()
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) = reapplyRoute()
        }
        runCatching { am.registerAudioDeviceCallback(cb, Handler(Looper.getMainLooper())) }
            .onSuccess { routeWatcher = cb }
    }

    private fun reapplyRoute() {
        val s = _state.value ?: return
        if (s.phase == Phase.ENDED) return
        applyAudioRoute(s.speaker)
    }

    private fun restoreAudioRoute() {
        val am = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        routeWatcher?.let { cb -> runCatching { am.unregisterAudioDeviceCallback(cb) } }
        routeWatcher = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { am.clearCommunicationDevice() }
        }
        @Suppress("DEPRECATION")
        runCatching {
            am.isBluetoothScoOn = false
            am.stopBluetoothSco()
            am.isSpeakerphoneOn = false
        }
        runCatching { am.mode = savedAudioMode }
        audioConfigured = false
    }

    // ---- helpers ---------------------------------------------------------------

    private fun startForegroundService() {
        val s = _state.value ?: return
        CallForegroundService.start(appContext, s)
    }

    private fun offerAnswerConstraints(kind: CallKind) = MediaConstraints().apply {
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", if (kind == CallKind.VIDEO) "true" else "false"))
    }

    private inline fun update(block: (CallState) -> CallState) {
        val cur = _state.value ?: return
        _state.value = block(cur)
    }

    private fun appContextOrNull(): Context? = if (::appContext.isInitialized) appContext else null

    /** GET /calls/turn -> WebRTC ICE servers (STUN + TURN with short-lived credentials). */
    private fun fetchIceServers(): List<PeerConnection.IceServer> {
        return runCatching {
            kotlinx.coroutines.runBlocking { CallApi(appContext).turn() }.mapNotNull { dto ->
                val urls = when (val u = dto.urls) {
                    is JsonArray -> u.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                    is JsonPrimitive -> listOf(u.content)
                    else -> emptyList()
                }
                if (urls.isEmpty()) return@mapNotNull null
                val b = PeerConnection.IceServer.builder(urls)
                if (dto.username != null) b.setUsername(dto.username)
                if (dto.credential != null) b.setPassword(dto.credential)
                b.createIceServer()
            }
        }.getOrElse {
            // Fallback to a public STUN server so ICE can still gather on open networks.
            listOf(PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer())
        }
    }
}

/** Base SdpObserver so subclasses override only what they need. */
private open class SdpObserverAdapter : SdpObserver {
    override fun onCreateSuccess(sdp: SessionDescription) {}
    override fun onSetSuccess() {}
    override fun onCreateFailure(error: String?) {}
    override fun onSetFailure(error: String?) {}
}

/** Thin REST client for the call-record + TURN endpoints. */
private class CallApi(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    @Serializable
    data class IceServerDTO(val urls: JsonElement, val username: String? = null, val credential: String? = null)
    @Serializable
    private data class TurnEnvelope(val ice_servers: List<IceServerDTO> = emptyList())

    suspend fun turn(): List<IceServerDTO> =
        api.requestAs<TurnEnvelope>("GET", "calls/turn").ice_servers

    suspend fun ring(toUserId: String, callId: String, kind: CallKind, conversationId: String?) {
        val body = buildString {
            append("{\"to_user_id\":").append(JsonPrimitive(toUserId))
            append(",\"call_id\":").append(JsonPrimitive(callId))
            append(",\"call_kind\":").append(JsonPrimitive(if (kind == CallKind.VIDEO) "video" else "voice"))
            append(",\"conversation_id\":").append(JsonPrimitive(conversationId))
            append("}")
        }
        api.request("POST", "calls/ring", jsonBody = body)
    }

    suspend fun status(callId: String, status: String) {
        val body = "{\"status\":${JsonPrimitive(status)}}"
        api.request("POST", "calls/$callId/status", jsonBody = body)
    }
}
