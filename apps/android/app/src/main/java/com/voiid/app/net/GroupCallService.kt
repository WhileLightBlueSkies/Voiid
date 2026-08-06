package com.voiid.app.net

import android.content.Context
import android.media.AudioManager
import android.media.AudioDeviceInfo
import android.os.Build
import android.util.Log
import com.voiid.app.main.CallKind
import io.livekit.android.LiveKit
import io.livekit.android.RoomOptions
import io.livekit.android.e2ee.E2EEOptions
import io.livekit.android.events.RoomEvent
import io.livekit.android.room.Room
import io.livekit.android.room.track.LocalVideoTrack
import io.livekit.android.room.track.Track
import io.livekit.android.room.track.VideoTrack
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

/**
 * GROUP voice/video calls over a LiveKit SFU, with frame-level E2EE keyed from our own MLS
 * group session. Companion to [CallManager], which owns 1:1 peer-to-peer calls.
 *
 * ## Why an SFU (and not the 1:1 stack)
 * A full mesh makes every participant upload one stream per peer, so upload and CPU grow
 * with n² — it collapses past ~4 people on mobile. An SFU takes ONE upload per client and
 * forwards it. See `docs/LIVEKIT_SETUP.md`.
 *
 * ## Two WebRTC builds, deliberately
 * [CallManager] uses Stream's libwebrtc under the original `org.webrtc` package. LiveKit
 * ships its own build relocated to `livekit.org.webrtc` (native lib
 * `liblkjingle_peerconnection_so.so`). They share no classes and no symbols, so both live on
 * the classpath at once and the 1:1 stack is untouched by this file. **Any renderer used with
 * group video must be `livekit.org.webrtc.SurfaceViewRenderer`** — the two are not
 * interchangeable.
 *
 * ## E2EE — the SFU never sees plaintext
 * The media key comes from [GroupEngine.callKey], derived from the MLS exporter secret. Every
 * member at the same epoch derives the same key locally; it is never sent to the API and never
 * reaches the SFU, which forwards opaque frames. The join token from `POST /calls/group/token`
 * is pure authorization — no key material rides on it.
 *
 * ## Mutual exclusion with 1:1
 * A device may be in a group call or a 1:1 call, never both — they would fight over the mic,
 * the audio route and the foreground service. [join] refuses while [CallManager] holds a call,
 * and CallManager refuses while [isActive] here.
 */
object GroupCallManager {

    enum class Phase { CONNECTING, CONNECTED, RECONNECTING, ENDED }

    /** One tile in the grid. [videoTrack] is a LiveKit track — render with a LiveKit renderer. */
    data class Participant(
        val identity: String,
        val name: String,
        val isLocal: Boolean,
        val speaking: Boolean,
        val micMuted: Boolean,
        val cameraOn: Boolean,
        val videoTrack: VideoTrack?,
    ) {
        /** Backend identity is `"<userId>:<deviceId>"`; the user half is what we display against. */
        val userId: String get() = identity.substringBefore(':')
    }

    data class GroupCallState(
        val conversationId: String,
        val title: String,
        val kind: CallKind,
        val phase: Phase,
        val participants: List<Participant> = emptyList(),
        val muted: Boolean = false,
        /** Speaker vs earpiece. Group calls default to SPEAKER — a conference held to the
         *  ear is not how anyone uses one, and a video call has the phone on a table. */
        val speakerOn: Boolean = true,
        val videoEnabled: Boolean = false,
        val connectedAtMs: Long? = null,
        /** Non-null when the call could not start/continue — shown to the user, then dismissed. */
        val error: String? = null,
        /** False when we could not derive an MLS key; the UI must say so loudly. */
        val e2ee: Boolean = false,
    )

    private val _state = MutableStateFlow<GroupCallState?>(null)
    val state: StateFlow<GroupCallState?> = _state.asStateFlow()

    /** True whenever a group call is being set up or is live. Read by [CallManager] to refuse 1:1. */
    val isActive: Boolean get() = _state.value != null

    // Network + crypto never touch the main thread.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var room: Room? = null
    /** Held so [refreshCallKey] can re-key without reaching through the SDK's manager. */
    @Volatile private var keyProvider: io.livekit.android.e2ee.KeyProvider? = null
    @Volatile private var eventJob: Job? = null
    /** Collects [GroupEngine.epochChanges] for the active conversation and re-keys on epoch advance. */
    @Volatile private var epochJob: Job? = null
    /** Last key handed to [keyProvider]; guards against redundant re-keys and no-op commits. */
    @Volatile private var lastAppliedKey: String? = null
    @Volatile private var appContext: Context? = null
    /** Guards join/leave against double-taps and overlapping teardown. */
    private val lifecycle = Any()

    // MARK: - Join

    /**
     * Fetch a join token, connect to the room, publish mic (+camera for a video call) and
     * start mirroring participant state. Safe to call twice — the second call is ignored.
     */
    fun join(context: Context, conversationId: String, title: String, kind: CallKind) {
        synchronized(lifecycle) {
            if (_state.value != null) return                    // already in a group call
            if (CallManager.state.value != null) {              // 1:1 call in progress
                Log.w("VOIID", "group call: refused — a 1:1 call is active")
                return
            }
            if (conversationId.isBlank()) return
            appContext = context.applicationContext
            _state.value = GroupCallState(
                conversationId = conversationId,
                title = title,
                kind = kind,
                phase = Phase.CONNECTING,
                videoEnabled = kind == CallKind.VIDEO,
            )
        }
        val ctx = appContext ?: return
        CallForegroundService.startGroup(ctx, title, video = kind == CallKind.VIDEO)
        scope.launch { connect(ctx, conversationId, kind) }
    }

    private suspend fun connect(ctx: Context, conversationId: String, kind: CallKind) {
        // 1) Authorization: exchange the conversation for a room token.
        val creds = try {
            fetchToken(conversationId)
        } catch (e: ApiError.Http) {
            // 503 + livekit_configured:false means this deployment has no SFU — that is a
            // configuration state, not an error the user did anything to cause.
            fail(
                if (e.status == 503) "Group calling isn't configured on this server."
                else e.message ?: "Couldn't start the group call.",
            )
            return
        } catch (e: Exception) {
            Log.e("VOIID", "group call: token fetch failed", e)
            fail("Couldn't reach the server to start the group call.")
            return
        }

        // 2) Derive the MLS call key BEFORE connecting, so the room is E2EE from frame one.
        //    First process any pending group events (Welcome/Commit): a device that was added
        //    to the group but hasn't opened the chat yet holds NO local MLS state, so callKey
        //    would return null and the call would be refused with "encryption not set up".
        //    Establishing the group here makes the call work without the user first opening
        //    the chat (which is what the old error message told them to do by hand).
        runCatching { GroupEngine.get(ctx).syncGroupEvents() }
        val keyB64 = runCatching { GroupEngine.get(ctx).callKey(conversationId) }.getOrNull()
        if (keyB64 == null) {
            // Connecting without E2EE would hand plaintext media to the SFU. That contradicts
            // the entire product; refuse rather than silently downgrade.
            Log.e("VOIID", "group call: no MLS call key for conv=$conversationId — refusing to join")
            fail("Secure keys for this group aren't ready yet. Open the chat to sync, then try again.")
            return
        }
        val e2eeOptions = runCatching {
            // CRITICAL ORDERING: E2EEOptions() eagerly constructs a native FrameCryptor key
            // provider (JNI, in liblkjingle_peerconnection). That native library is only loaded
            // once LiveKit initializes WebRTC — so on the FIRST group call in a process,
            // constructing E2EEOptions() BEFORE any LiveKit init threw UnsatisfiedLinkError and
            // surfaced as "Couldn't set up encryption for this call." Force WebRTC init first.
            io.livekit.android.LiveKit.init(ctx)
            E2EEOptions().also {
                it.keyProvider.setSharedKey(keyB64, KEY_INDEX)
                keyProvider = it.keyProvider
                lastAppliedKey = keyB64
            }
        }.getOrElse {
            Log.e("VOIID", "group call: E2EE setup failed", it)
            fail("Couldn't set up encryption for this call.")
            return
        }

        // 3) Connect.
        val r = try {
            withContext(Dispatchers.Main) {
                LiveKit.create(
                    appContext = ctx,
                    options = RoomOptions(
                        adaptiveStream = true,   // drop resolution for tiles that aren't visible
                        dynacast = true,         // stop publishing layers nobody subscribes to
                        e2eeOptions = e2eeOptions,
                    ),
                )
            }
        } catch (e: Exception) {
            Log.e("VOIID", "group call: room create failed", e)
            fail("Couldn't start the call engine.")
            return
        }
        if (_state.value == null) { runCatching { r.disconnect() }; return }   // left during setup
        room = r
        _state.value = _state.value?.copy(e2ee = true)
        startEventMirror(r)
        startEpochWatch(ctx, conversationId)

        try {
            r.connect(creds.url, creds.token)
        } catch (e: Exception) {
            Log.e("VOIID", "group call: connect failed", e)
            fail("Couldn't connect to the call.")
            return
        }
        if (_state.value == null) { teardown(); return }

        // Advertise the call to the other members so they get a "join" notification — without
        // this the call is join-only and nobody else ever learns it started.
        runCatching { ringGroup(ctx, conversationId, kind) }
            .onFailure { Log.w("VOIID", "group call: ring fan-out failed (call still usable)", it) }

        startPresenceHeartbeat(ctx, conversationId)

        // 4) Publish. Mic always; camera only for a video call.
        runCatching { r.localParticipant.setMicrophoneEnabled(true) }
            .onFailure { Log.e("VOIID", "group call: mic publish failed", it) }
        if (kind == CallKind.VIDEO) {
            runCatching { r.localParticipant.setCameraEnabled(true) }
                .onFailure { Log.e("VOIID", "group call: camera publish failed", it) }
        }

        // ASSERT THE ROUTE ON JOIN. The state defaults to speakerOn = true, but a default is
        // only a claim until something applies it — without this the call would report
        // "speaker" while the audio came out of the earpiece, and the first tap of the new
        // button would appear to do nothing (it would toggle to `false`, which is where the
        // hardware already was).
        applySpeaker(_state.value?.speakerOn ?: true)

        _state.value = _state.value?.copy(
            phase = Phase.CONNECTED,
            connectedAtMs = System.currentTimeMillis(),
        )
        publishSnapshot()
        Log.i("VOIID", "group call: connected room=${creds.room} e2ee=true")
    }

    // MARK: - Event mirror
    //
    // Rather than tracking a dozen individual property flows, we re-derive the whole
    // participant snapshot on every RoomEvent. Rooms are small (tens of people at most) and
    // this makes it impossible for the UI to drift out of sync with the SDK's own state.
    private fun startEventMirror(r: Room) {
        eventJob?.cancel()
        eventJob = scope.launch {
            r.events.events.collect { ev ->
                when (ev) {
                    is RoomEvent.Disconnected -> {
                        // The SDK exhausted its own reconnect policy.
                        Log.i("VOIID", "group call: disconnected reason=${ev.reason}")
                        endInternal(userInitiated = false)
                        return@collect
                    }
                    is RoomEvent.Reconnecting ->
                        _state.value = _state.value?.copy(phase = Phase.RECONNECTING)
                    is RoomEvent.Reconnected ->
                        _state.value = _state.value?.copy(phase = Phase.CONNECTED)
                    is RoomEvent.FailedToConnect -> {
                        Log.e("VOIID", "group call: failed to connect", ev.error)
                        fail("Couldn't connect to the call.")
                        return@collect
                    }
                    // Secondary/opportunistic trigger: an SFU membership change often coincides
                    // with an MLS commit. The authoritative trigger is startEpochWatch (driven by
                    // the actual exporter-secret rotation); refreshCallKey de-dups so re-applying
                    // an unchanged key here is a no-op.
                    is RoomEvent.ParticipantConnected,
                    is RoomEvent.ParticipantDisconnected,
                    -> refreshCallKey()
                    else -> Unit
                }
                publishSnapshot()
            }
        }
    }

    /**
     * Watch the MLS epoch for the active conversation. When a membership commit is applied or
     * merged locally, [GroupEngine.epochChanges] fires and we re-derive + re-apply the call key.
     * This is the authoritative trigger: it follows the ACTUAL exporter-secret rotation, unlike
     * the LiveKit participant events (which can fire before/without the local commit landing).
     * [debounce] coalesces a burst of consecutive commits (e.g. adding several people) into one
     * re-key. Runs on [scope] (Dispatchers.IO), off the main thread, and is cancelled on leave.
     */
    private fun startEpochWatch(ctx: Context, conversationId: String) {
        epochJob?.cancel()
        epochJob = scope.launch {
            GroupEngine.get(ctx).epochChanges
                .filter { it == conversationId }
                .debounce(EPOCH_DEBOUNCE_MS)
                .collect {
                    Log.i("VOIID", "group call: MLS epoch advanced conv=$conversationId — re-keying")
                    refreshCallKey()
                }
        }
    }

    /**
     * Re-derive the MLS call key and hand it to the key provider. MLS rekeys on every
     * membership commit, so the media key must follow or members at the new epoch can't be
     * decrypted. Never throws: on failure we log and keep the call up on the CURRENT key rather
     * than tearing it down. Skips the SDK call when the key is unchanged (idempotent).
     */
    fun refreshCallKey() {
        val ctx = appContext ?: return
        val conversationId = _state.value?.conversationId ?: return
        scope.launch {
            val key = runCatching { GroupEngine.get(ctx).callKey(conversationId) }.getOrNull() ?: return@launch
            if (key == lastAppliedKey) return@launch                 // epoch unchanged → no-op
            val provider = keyProvider ?: return@launch
            runCatching { provider.setSharedKey(key, KEY_INDEX) }
                .onSuccess {
                    lastAppliedKey = key
                    Log.i("VOIID", "group call: re-keyed to new MLS epoch")
                }
                .onFailure { Log.e("VOIID", "group call: key refresh failed — staying on current key", it) }
        }
    }

    /** Rebuild the participant list from the SDK's current state (local tile first). */
    private fun publishSnapshot() {
        val r = room ?: return
        val cur = _state.value ?: return
        val speakers = runCatching { r.activeSpeakers.mapNotNull { it.identity?.value }.toSet() }
            .getOrDefault(emptySet())

        val local = runCatching {
            val lp = r.localParticipant
            val camPub = lp.getTrackPublication(Track.Source.CAMERA)
            val micPub = lp.getTrackPublication(Track.Source.MICROPHONE)
            Participant(
                identity = lp.identity?.value ?: "me",
                name = lp.name?.takeIf { it.isNotBlank() } ?: "You",
                isLocal = true,
                speaking = lp.isSpeaking,
                micMuted = micPub?.muted ?: true,
                cameraOn = camPub != null && !camPub.muted,
                videoTrack = camPub?.track as? VideoTrack,
            )
        }.getOrNull()

        val remotes = runCatching {
            r.remoteParticipants.values.map { p ->
                val camPub = p.getTrackPublication(Track.Source.CAMERA)
                val micPub = p.getTrackPublication(Track.Source.MICROPHONE)
                val ident = p.identity?.value ?: ""
                Participant(
                    identity = ident,
                    name = p.name?.takeIf { it.isNotBlank() } ?: ident.substringBefore(':'),
                    isLocal = false,
                    speaking = p.isSpeaking || ident in speakers,
                    micMuted = micPub?.muted ?: true,
                    cameraOn = camPub != null && !camPub.muted,
                    videoTrack = camPub?.track as? VideoTrack,
                )
            }.sortedBy { it.identity }
        }.getOrDefault(emptyList())

        _state.value = cur.copy(
            participants = listOfNotNull(local) + remotes,
            muted = local?.micMuted ?: cur.muted,
            videoEnabled = local?.cameraOn ?: cur.videoEnabled,
        )
    }

    // MARK: - Controls

    fun toggleMute() {
        val r = room ?: return
        val target = !(_state.value?.muted ?: false)
        scope.launch {
            runCatching { r.localParticipant.setMicrophoneEnabled(!target) }
                .onFailure { Log.e("VOIID", "group call: toggle mute failed", it) }
            publishSnapshot()
        }
    }

    /**
     * Speaker on/off for a group call.
     *
     * GROUP CALLS HAD NO AUDIO CONTROL AT ALL — neither voice nor video. A conference that
     * started on the earpiece could not be moved to the speaker, and a video call had no way
     * back off it. LiveKit owns the media, but the ROUTE is still AudioManager's, so this is
     * the same call the 1:1 path makes.
     */
    fun toggleSpeaker() {
        val on = !(_state.value?.speakerOn ?: true)
        applySpeaker(on)
        _state.value = _state.value?.copy(speakerOn = on)
    }

    /** Assert the route. Called on join too, so the default actually takes effect. */
    private fun applySpeaker(on: Boolean) {
        val ctx = appContext ?: return
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        runCatching {
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val devices = am.availableCommunicationDevices
                // A connected headset WINS over the speaker flag — the user plugged it in for
                // a reason, and forcing the speaker over it would be the wrong default.
                val preferred = devices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                        it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                        it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES
                } ?: devices.firstOrNull {
                    it.type == if (on) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                               else AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                }
                preferred?.let { am.setCommunicationDevice(it) }
            } else {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = on
            }
        }
    }

    fun toggleVideo() {
        val r = room ?: return
        val target = !(_state.value?.videoEnabled ?: false)
        scope.launch {
            runCatching { r.localParticipant.setCameraEnabled(target) }
                .onFailure { Log.e("VOIID", "group call: toggle video failed", it) }
            publishSnapshot()
        }
    }

    fun switchCamera() {
        val r = room ?: return
        scope.launch {
            runCatching {
                val track = r.localParticipant
                    .getTrackPublication(Track.Source.CAMERA)?.track as? LocalVideoTrack
                track?.switchCamera()
            }.onFailure { Log.e("VOIID", "group call: switch camera failed", it) }
        }
    }

    /** Bind a LiveKit renderer to the shared EGL context. Must be a `livekit.org.webrtc` one. */
    fun initRenderer(renderer: livekit.org.webrtc.SurfaceViewRenderer) {
        runCatching { room?.initVideoRenderer(renderer) }
            .onFailure { Log.e("VOIID", "group call: renderer init failed", it) }
    }

    // MARK: - Leave / teardown

    /** User tapped leave. */
    fun leave() = endInternal(userInitiated = true)

    /** Recents-swipe or any other system teardown. */
    fun leaveFromSystem() = endInternal(userInitiated = false)

    private fun endInternal(userInitiated: Boolean) {
        synchronized(lifecycle) {
            if (_state.value == null) return
            _state.value = null
        }
        Log.i("VOIID", "group call: ended userInitiated=$userInitiated")
        teardown()
    }

    /** Surface a message, then clear the call. The UI shows [GroupCallState.error] briefly. */
    private fun fail(message: String) {
        val cur = _state.value
        if (cur != null) _state.value = cur.copy(phase = Phase.ENDED, error = message)
        teardown()
        scope.launch {
            kotlinx.coroutines.delay(ERROR_LINGER_MS)
            if (_state.value?.error != null) _state.value = null
        }
    }

    /** Release the room + service. Never throws — teardown runs on error paths. */
    // ── Ongoing-call presence ───────────────────────────────────────────────────────
    //
    // Backs the in-chat "ongoing call — Join" banner. The server keeps a short-TTL Redis
    // marker per conversation which connected clients re-arm; when everyone stops
    // heartbeating the marker expires and the banner disappears on its own. That is why
    // there is no "call ended" event to deliver — a TTL says it without anyone announcing it.

    /** Comfortably under the server's 60s TTL, so one dropped request does not expire it. */
    private const val PRESENCE_HEARTBEAT_MS = 20_000L

    private var presenceJob: Job? = null

    private fun startPresenceHeartbeat(ctx: Context, conversationId: String) {
        presenceJob?.cancel()
        presenceConversationId = conversationId
        val app = ctx.applicationContext
        presenceJob = scope.launch {
            while (isActive) {
                delay(PRESENCE_HEARTBEAT_MS)
                // Failures are swallowed deliberately: a missed heartbeat costs other members
                // a stale banner, which is not worth disturbing a live call over.
                runCatching {
                    val api = ApiClient(TokenStore.get(app))
                    api.request(
                        "POST", "calls/group/heartbeat",
                        jsonBody = ApiClient.json.encodeToString(
                            GroupTokenBody.serializer(), GroupTokenBody(conversationId)),
                    )
                }
            }
        }
    }

    private fun stopPresenceHeartbeat(conversationId: String?) {
        presenceJob?.cancel()
        presenceJob = null
        val app = appContext ?: return
        if (conversationId.isNullOrBlank()) return
        // Best-effort, and on its OWN scope: teardown may be cancelling `scope`, and a leave
        // launched there would be cancelled before it ever reached the network. A client that
        // is killed rather than closed never sends this at all — which is exactly why the
        // server-side TTL is the mechanism and this is only an optimisation.
        CoroutineScope(Dispatchers.IO).launch {
            runCatching {
                ApiClient(TokenStore.get(app)).request(
                    "POST", "calls/group/leave",
                    jsonBody = ApiClient.json.encodeToString(
                        GroupTokenBody.serializer(), GroupTokenBody(conversationId)),
                )
            }
        }
    }

    /**
     * The conversation we are advertising presence for, tracked separately from `_state`
     * because `endInternal` nulls the state BEFORE calling `teardown()` — reading it there
     * would always find null and we would never clear our presence entry.
     */
    private var presenceConversationId: String? = null

    private fun teardown() {
        stopPresenceHeartbeat(presenceConversationId)
        presenceConversationId = null
        eventJob?.cancel()
        eventJob = null
        epochJob?.cancel()
        epochJob = null
        lastAppliedKey = null
        val r = room
        room = null
        keyProvider = null
        runCatching { r?.disconnect() }
        runCatching { r?.release() }
        appContext?.let { runCatching { CallForegroundService.stop(it) } }
    }

    // MARK: - Token API

    private suspend fun fetchToken(conversationId: String): GroupTokenResponse {
        val ctx = appContext ?: throw ApiError.NotAuthenticated
        val api = ApiClient(TokenStore.get(ctx))
        val body = ApiClient.json.encodeToString(
            GroupTokenBody.serializer(), GroupTokenBody(conversationId),
        )
        return api.requestAs("POST", "calls/group/token", jsonBody = body)
    }

    /** Fan out a "group call started" push to the other members so they can join. */
    private suspend fun ringGroup(ctx: Context, conversationId: String, kind: CallKind) {
        val api = ApiClient(TokenStore.get(ctx))
        val body = ApiClient.json.encodeToString(
            GroupRingBody.serializer(),
            GroupRingBody(conversationId, if (kind == CallKind.VIDEO) "video" else "voice"),
        )
        api.request("POST", "calls/group/ring", jsonBody = body)
    }

    /** Key slot in LiveKit's key ring. We only ever use one (the MLS-derived shared key). */
    private const val KEY_INDEX = 0
    private const val ERROR_LINGER_MS = 4000L
    /** Coalesce a burst of consecutive membership commits into a single re-key. */
    private const val EPOCH_DEBOUNCE_MS = 250L

    @Serializable private data class GroupTokenBody(val conversation_id: String)
    @Serializable private data class GroupRingBody(val conversation_id: String, val call_kind: String)

    @Serializable
    private data class GroupTokenResponse(
        val url: String,
        val token: String,
        val room: String = "",
        val identity: String? = null,
        val ttl_seconds: Long? = null,
    )
}
