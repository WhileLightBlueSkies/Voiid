package com.voiid.app.net

import android.content.Context
import android.media.AudioManager
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
    )

    private const val STREAM_ID = "voiid_stream"
    private const val AUDIO_TRACK_ID = "voiid_audio"
    private const val VIDEO_TRACK_ID = "voiid_video"

    private val json = Json { ignoreUnknownKeys = true }

    private val _state = MutableStateFlow<CallState?>(null)
    val state: StateFlow<CallState?> = _state.asStateFlow()

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
        init(appContextOrNull() ?: return)
        val callId = java.util.UUID.randomUUID().toString()
        _state.value = CallState(
            callId = callId, peerUserId = peerUserId, peerName = peerName,
            conversationId = conversationId, kind = kind, incoming = false,
            phase = Phase.RINGING_OUT, videoEnabled = kind == CallKind.VIDEO,
            speaker = kind == CallKind.VIDEO,
        )
        startForegroundService()
        // Wake an offline callee via push (best effort) in parallel with WS offer.
        scope.launch(Dispatchers.IO) {
            runCatching { CallApi(appContext).ring(peerUserId, callId, kind, conversationId) }
        }
        exec.execute {
            val servers = fetchIceServers()
            createPeerConnection(servers) ?: return@execute
            addLocalMedia(kind)
            applyAudioRoute(kind == CallKind.VIDEO)
            pc?.createOffer(object : SdpObserverAdapter() {
                override fun onCreateSuccess(sdp: SessionDescription) {
                    pc?.setLocalDescription(SdpObserverAdapter(), sdp)
                    WebSocketClient.get(appContext).sendCallOffer(peerUserId, callId, kind, sdp.description)
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
            "call_hangup", "call_decline", "call_busy" -> onRemoteEnd(sig)
        }
    }

    /** A ring push (FCM) arrived before/independent of the WS offer — show incoming UI now. */
    fun onRingPush(callId: String, callerId: String, callerName: String, kind: CallKind, conversationId: String?) {
        appContextOrNull()?.let { init(it) }
        if (_state.value?.callId == callId) return
        if (_state.value != null) return
        _state.value = CallState(
            callId = callId, peerUserId = callerId, peerName = callerName,
            conversationId = conversationId, kind = kind, incoming = true,
            phase = Phase.RINGING_IN, videoEnabled = kind == CallKind.VIDEO,
            speaker = kind == CallKind.VIDEO,
        )
        CallForegroundService.showIncoming(appContext, _state.value!!)
    }

    private fun onRemoteOffer(sig: WebSocketClient.CallSignal) {
        val current = _state.value
        // Busy: already on a different call -> tell the caller.
        if (current != null && current.callId != sig.callId) {
            WebSocketClient.get(appContext).sendCallBusy(sig.fromUserId, sig.callId)
            return
        }
        val kind = if (sig.callKind == "video") CallKind.VIDEO else CallKind.VOICE
        val name = current?.peerName?.takeIf { it.isNotBlank() } ?: sig.fromUserId
        _state.value = CallState(
            callId = sig.callId, peerUserId = sig.fromUserId, peerName = name,
            conversationId = sig.conversationId ?: current?.conversationId, kind = kind,
            incoming = true, phase = Phase.RINGING_IN,
            videoEnabled = kind == CallKind.VIDEO, speaker = kind == CallKind.VIDEO,
        )
        CallForegroundService.showIncoming(appContext, _state.value!!)
        val sdp = sig.sdp ?: return
        exec.execute {
            val servers = fetchIceServers()
            createPeerConnection(servers) ?: return@execute
            pc?.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() { remoteDescSet = true; drainCandidates(); if (acceptPending) doAnswer() }
            }, SessionDescription(SessionDescription.Type.OFFER, sdp))
        }
    }

    private fun onRemoteAnswer(sig: WebSocketClient.CallSignal) {
        val sdp = sig.sdp ?: return
        exec.execute {
            pc?.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() { remoteDescSet = true; drainCandidates() }
            }, SessionDescription(SessionDescription.Type.ANSWER, sdp))
        }
        update { it.copy(phase = Phase.CONNECTING) }
    }

    private fun onRemoteIce(sig: WebSocketClient.CallSignal) {
        val c = sig.candidate ?: return
        val cand = (c["candidate"] as? JsonPrimitive)?.contentOrNull ?: return
        val mid = (c["sdpMid"] as? JsonPrimitive)?.contentOrNull
        val idx = (c["sdpMLineIndex"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0
        val ice = IceCandidate(mid, idx, cand)
        exec.execute {
            if (remoteDescSet) pc?.addIceCandidate(ice) else pendingRemoteCandidates.add(ice)
        }
    }

    private fun onRemoteEnd(sig: WebSocketClient.CallSignal) {
        if (_state.value?.callId != sig.callId) return
        endInternal(notifyPeer = false)
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
                pc?.setLocalDescription(SdpObserverAdapter(), sdp)
                WebSocketClient.get(appContext).sendCallAnswer(s.peerUserId, s.callId, sdp.description)
            }
        }, offerAnswerConstraints(s.kind))
    }

    /** Reject an incoming call. */
    fun decline() {
        val s = _state.value ?: return
        WebSocketClient.get(appContext).sendCallDecline(s.peerUserId, s.callId)
        endInternal(notifyPeer = false)
    }

    /** Hang up an active/outgoing call. */
    fun hangup() = endInternal(notifyPeer = true)

    fun toggleMute() {
        val s = _state.value ?: return
        val muted = !s.muted
        exec.execute { localAudioTrack?.setEnabled(!muted) }
        update { it.copy(muted = muted) }
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

    fun setLocalRenderer(r: SurfaceViewRenderer?) {
        localRenderer = r
        exec.execute { if (r != null) localVideoTrack?.addSink(r) }
    }

    fun setRemoteRenderer(r: SurfaceViewRenderer?) {
        remoteRenderer = r
        exec.execute { if (r != null) remoteVideoTrack?.addSink(r) }
    }

    // ---- WebRTC plumbing -------------------------------------------------------

    private fun createPeerConnection(iceServers: List<PeerConnection.IceServer>): PeerConnection? {
        val cfg = PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
        }
        pc = factory.createPeerConnection(cfg, pcObserver)
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

        override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) {
            when (newState) {
                PeerConnection.IceConnectionState.CONNECTED,
                PeerConnection.IceConnectionState.COMPLETED -> markConnected()
                PeerConnection.IceConnectionState.FAILED,
                PeerConnection.IceConnectionState.CLOSED -> if (_state.value?.phase != Phase.ENDED) endInternal(notifyPeer = true)
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
        if (s.phase == Phase.CONNECTED) return
        update { it.copy(phase = Phase.CONNECTED, connectedAtMs = System.currentTimeMillis()) }
        startForegroundService()
        scope.launch(Dispatchers.IO) {
            runCatching { CallApi(appContext).status(s.callId, "connected") }
        }
    }

    // ---- teardown --------------------------------------------------------------

    private fun endInternal(notifyPeer: Boolean) {
        val s = _state.value ?: return
        if (notifyPeer && s.phase != Phase.ENDED) {
            runCatching { WebSocketClient.get(appContext).sendCallHangup(s.peerUserId, s.callId) }
        }
        scope.launch(Dispatchers.IO) {
            runCatching { CallApi(appContext).status(s.callId, "ended") }
        }
        update { it.copy(phase = Phase.ENDED) }
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
    }

    // ---- audio routing ---------------------------------------------------------

    private var savedAudioMode = AudioManager.MODE_NORMAL
    private var audioConfigured = false

    private fun applyAudioRoute(speaker: Boolean) {
        val am = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (!audioConfigured) { savedAudioMode = am.mode; audioConfigured = true }
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = speaker
    }

    private fun restoreAudioRoute() {
        val am = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = false
        am.mode = savedAudioMode
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
