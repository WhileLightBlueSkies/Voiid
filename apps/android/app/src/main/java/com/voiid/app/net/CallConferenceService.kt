package com.voiid.app.net

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * AD-HOC CONFERENCE ENGINE — escalate a live 1:1 call to three or more people (repair plan
 * §3.3 keying, §3.4 make-before-break, §3.5 identity disclosure).
 *
 * ## What this is NOT
 * It is **not** [GroupCallManager]. That engine's room is keyed on a conversation id and its media
 * key comes from that conversation's MLS epoch, so escalating through it would require creating a
 * group CONVERSATION — handing an added stranger permanent messaging rights, which the product
 * forbids. This engine's room is keyed on the CALL id (`voiid-call-<call_id>`), its authorization
 * is a `call_participants` row, and its media key is a per-call secret distributed pairwise over
 * the Double Ratchet. **Nothing here writes to a conversation table.** See the header of
 * [CallConference.kt] for why that sentence is load-bearing rather than decorative.
 *
 * ## Make-before-break (§3.4)
 * ```
 *   inviter:  CONNECTED ──escalate──► ESCALATING ──both on the SFU──► CONFERENCE
 *                            │
 *                            └── SFU never came up ──► back to the still-standing 1:1 call
 * ```
 * During ESCALATING the 1:1 PeerConnection **and** the LiveKit room are both alive. The 1:1 leg is
 * hung up with an ordinary `call_hangup` only once both original participants are visibly in the
 * room; if the SFU never comes up, the escalation is abandoned and the 1:1 call is untouched. The
 * peer is told with `call_migrate`, shows "Adding <name>…", and keeps 1:1 audio the whole time.
 *
 * ## THE AUDIO-SESSION HANDOVER, which is the hard part
 * [CallManager] uses Stream's libwebrtc under `org.webrtc`; LiveKit ships its own build relocated
 * to `livekit.org.webrtc`. Both can be on the classpath at once — they share no symbols — but they
 * emphatically cannot both hold the microphone: two `AudioRecord` clients on one device produce
 * silence, a capture failure, or an OEM-specific mess that will not reproduce on a dev machine.
 *
 * So during ESCALATING this engine connects **subscribe-only**: it publishes no mic and no camera,
 * and the 1:1 stack keeps the single capture. The invitee is already audible (playback mixes
 * freely; only capture is exclusive). At cutover — after the 1:1 leg is torn down and its capture
 * released — the mic is published and the audio route re-asserted here. That is the entire reason
 * "SFU-connected" is defined as CONNECTION state rather than media flow: media cannot flow both
 * ways until exactly one owner holds the mic.
 */
object ConferenceManager {

    enum class Stage {
        /** Both legs alive: the 1:1 PeerConnection AND the SFU room. Subscribe-only here. */
        ESCALATING,

        /** The 1:1 leg is gone; this engine owns the mic, the route and the media. */
        CONFERENCE,

        /** Terminal. Held briefly so the UI can show an error before it clears. */
        ENDED,
    }

    /** One rendered tile. [videoTrack] is a LiveKit track — render it with a LiveKit renderer. */
    data class Tile(
        val identity: String,
        val userId: String,
        val name: String,
        val isLocal: Boolean,
        val speaking: Boolean,
        val micMuted: Boolean,
        val cameraOn: Boolean,
        val videoTrack: VideoTrack?,
    )

    data class ConferenceState(
        val callId: String,
        val room: String,
        val kind: CallKind,
        val stage: Stage,
        /** True on the device that pressed "add person" — the one that mints and re-fans keys. */
        val isInviter: Boolean,
        /** Server roster: @username only. THE identity surface — see [CallRosterEntry.displayName]. */
        val roster: List<CallRosterEntry> = emptyList(),
        val tiles: List<Tile> = emptyList(),
        /** We are on the SFU. During ESCALATING this is true well before the 1:1 leg goes away. */
        val sfuConnected: Boolean = false,
        /** False until a per-call secret has actually been applied. Never join without one. */
        val e2ee: Boolean = false,
        val muted: Boolean = false,
        val speakerOn: Boolean = true,
        val videoEnabled: Boolean = false,
        /** Transient banner text — "Adding Sam…". */
        val notice: String? = null,
        /** Non-null when the escalation failed. The 1:1 call, if any, is still up. */
        val error: String? = null,
    ) {
        /** Everyone the server says is on this call, ourselves excluded. */
        val others: List<CallRosterEntry> get() = roster.filterNot { it.is_self }
        val canAddMore: Boolean get() = roster.size < MAX_CALL_PARTICIPANTS
    }

    private val _state = MutableStateFlow<ConferenceState?>(null)
    val state: StateFlow<ConferenceState?> = _state.asStateFlow()

    /** True from the first moment of an escalation until teardown. Read by the other engines. */
    val isActive: Boolean get() = _state.value != null

    /** The call this engine is bound to, or null. Lets [CallManager] scope its carve-outs. */
    val activeCallId: String? get() = _state.value?.callId

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycle = Any()

    @Volatile private var appContext: Context? = null
    @Volatile private var room: Room? = null
    @Volatile private var keyProvider: io.livekit.android.e2ee.KeyProvider? = null
    @Volatile private var eventJob: Job? = null
    @Volatile private var rekeyJob: Job? = null
    @Volatile private var cutoverJob: Job? = null

    /** The user who owns key minting for this call. Falls back to the lowest user id present. */
    @Volatile private var inviterUserId: String? = null

    /** The ORIGINAL 1:1 peer, if we escalated out of one. Null on the invitee's device. */
    @Volatile private var originalPeerUserId: String? = null

    /** Current per-call secret + its epoch. Never persisted, never leaves memory. */
    @Volatile private var currentSecret: String? = null
    @Volatile private var keyEpoch: Int = 0

    /** Guards against re-applying an unchanged key, exactly like the group engine's dedup. */
    @Volatile private var lastAppliedKey: String? = null

    private var courier: CallKeyCourier? = null

    // MARK: - Constants

    /** LiveKit key-ring slot. One slot, like group calls: the shared per-call secret. */
    private const val KEY_INDEX = 0

    /**
     * How long an escalation may sit in ESCALATING before we give up and fall back to the 1:1
     * call. Generous — a cold-started invitee has to be woken by a push, fetch a token and connect
     * — but finite, because a call stuck "Adding…" forever is worse than one that says it failed.
     */
    private const val ESCALATION_TIMEOUT_MS = 30_000L

    /** Coalesce a burst of membership changes (two people joining at once) into one rekey. */
    private const val REKEY_DEBOUNCE_MS = 400L

    private const val ERROR_LINGER_MS = 4_000L

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Inbound signaling
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /**
     * Subscribed once, for the life of the process, by [CallManager.init]. Every frame is scoped
     * to a call id we are actually on; anything else is dropped without a trace, because a known
     * call_id must never be a way into a room.
     */
    private val relaySink = ConferenceRelay.Sink { frame -> onFrame(frame) }

    @Volatile private var subscribed = false

    /** Idempotent. Safe to call from any entry point. */
    fun init(context: Context) {
        appContext = context.applicationContext
        if (courier == null) courier = CallKeyCourier(context.applicationContext)
        if (!subscribed) {
            ConferenceRelay.subscribe(relaySink)
            subscribed = true
        }
    }

    private fun onFrame(frame: ConferenceRelay.Frame) {
        when (frame.type) {
            // Someone is adding us. The RING is raised by the push path (CallManager.onRingPush),
            // which works whether the app was alive or not; this frame is the socket-side twin and
            // exists so a foregrounded app rings instantly rather than waiting for FCM.
            "call_invite" -> onInvited(frame)
            // Our peer is being migrated onto the SFU by the inviter.
            "call_migrate" -> onMigrate(frame)
            // The invitee took it (or refused). Either way the roster moved — re-key.
            "call_invite_accept" -> scheduleRekey("invitee accepted")
            "call_invite_decline" -> onInviteDeclined(frame)
            // A copy of the per-call secret addressed to this device.
            "call_key" -> onCallKey(frame)
        }
    }

    private fun onInvited(frame: ConferenceRelay.Frame) {
        val ctx = appContext ?: return
        // Deliberately routed through the SAME incoming-call surface as a 1:1 ring, so Telecom,
        // the full-screen intent, the system call log and the tones all keep working unchanged.
        val kind = if (frame.callKind == "video") CallKind.VIDEO else CallKind.VOICE
        CallManager.onConferenceInvitePush(
            callId = frame.callId,
            inviterUserId = frame.fromUserId,
            kind = kind,
            context = ctx,
        )
    }

    private fun onInviteDeclined(frame: ConferenceRelay.Frame) {
        val s = _state.value ?: return
        if (s.callId != frame.callId) return
        val who = com.voiid.app.store.UserDirectory.callRosterName(
            frame.fromUserId,
            s.roster.firstOrNull { it.user_id == frame.fromUserId }?.username,
        )
        _state.value = s.copy(notice = "$who declined")
        scheduleRekey("invitee declined")
        scope.launch {
            delay(ERROR_LINGER_MS)
            _state.value?.let { if (it.notice?.endsWith("declined") == true) _state.value = it.copy(notice = null) }
        }
    }

    /**
     * A per-call secret arrived for a call we are on (or are being added to).
     *
     * The epoch guard is what makes rekey safe under reordering: the relay makes no ordering
     * promise across a reconnect, and applying a STALE key would silently drop us out of the media
     * that everyone else has already rotated to.
     */
    private fun onCallKey(frame: ConferenceRelay.Frame) {
        // 1:1 FALLBACK. A frame whose call_id matches the live P2P call (not a
        // conference) belongs to the 1:1 frame-E2EE layer — route it there instead of
        // dropping it because this engine has no state.
        val oneToOne = CallManager.state.value
        if (oneToOne?.callId == frame.callId && !oneToOne.isConferenceInvite) {
            CallManager.onOneToOneCallKey(
                ciphertexts = mapOf(frame.deviceId.toString() to (frame.ciphertextB64 ?: "")),
                senderDeviceId = frame.senderDeviceId,
                fromUserId = frame.fromUserId,
                callId = frame.callId,
            )
            return
        }
        val callId = _state.value?.callId ?: pendingKeyCallId ?: return
        if (frame.callId != callId) return
        val c = courier ?: return
        scope.launch {
            val env = c.open(frame, callId) ?: return@launch
            if (env.epoch < keyEpoch) {
                Log.i("VOIID", "conference: ignoring stale call key epoch=${env.epoch} < $keyEpoch")
                return@launch
            }
            keyEpoch = env.epoch
            currentSecret = env.secret
            applySecret(env.secret)
        }
    }

    /**
     * The call we expect a key for BEFORE this engine has any state — an invitee is keyed while
     * still on the ringing screen, so the key can (and usually does) arrive first.
     */
    @Volatile private var pendingKeyCallId: String? = null

    /** Called by [CallManager] the moment a conference invite starts ringing. */
    fun expectKeyFor(callId: String) { pendingKeyCallId = callId }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Inviter: add a person to a live 1:1 call
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /**
     * Add [inviteeUserId] to the live call [callId].
     *
     * [onResult] is handed a user-facing message on failure and null on success, so the caller can
     * surface a 403 ("not permitted to add this user") without this engine owning a snackbar.
     *
     * ORDER MATTERS. The server is asked FIRST: it is the authority on whether we may reach this
     * person, on whether the call is live, on the 8-person ceiling and on whether the deployment
     * has an SFU at all — and it is the thing that rewrites the Redis relay grant. Only once it has
     * said yes do we mint a key, tell the peer, and start bringing the room up. A client that
     * connected first and asked later would show "Adding…" for someone who was never invited.
     */
    fun addPerson(
        context: Context,
        callId: String,
        kind: CallKind,
        peerUserId: String?,
        inviteeUserId: String,
        onResult: (String?) -> Unit = {},
    ) {
        init(context)
        val ctx = appContext ?: return
        scope.launch {
            val api = ConferenceApi(ctx)
            val res = try {
                api.escalate(callId, inviteeUserId)
            } catch (e: ApiError.Http) {
                // 503 means the deployment has no SFU. That is a configuration state, not
                // something the user did — and the add-person button should already be hidden.
                val msg = when (e.status) {
                    503 -> "Conference calling isn't configured on this server."
                    403 -> e.message ?: "You can't add this person."
                    409 -> e.message ?: "This call can't take another person right now."
                    else -> e.message ?: "Couldn't add that person."
                }
                Log.w("VOIID", "conference: escalate refused (${e.status})")
                withContext(Dispatchers.Main) { onResult(msg) }
                return@launch
            } catch (e: Exception) {
                Log.e("VOIID", "conference: escalate failed", e)
                withContext(Dispatchers.Main) { onResult("Couldn't reach the server to add that person.") }
                return@launch
            }

            val myId = TokenStore.get(ctx).userId
            val inviteeName = com.voiid.app.store.UserDirectory
                .callRosterName(inviteeUserId, res.invitee?.username)

            synchronized(lifecycle) {
                if (_state.value == null) {
                    inviterUserId = myId
                    originalPeerUserId = peerUserId
                    _state.value = ConferenceState(
                        callId = callId,
                        room = res.room.ifBlank { adhocRoomName(callId) },
                        kind = kind,
                        stage = Stage.ESCALATING,
                        isInviter = true,
                        roster = res.participants,
                        videoEnabled = kind == CallKind.VIDEO,
                        notice = "Adding $inviteeName…",
                    )
                } else {
                    // A SECOND person added to an existing conference: no new escalation state
                    // machine, just a roster refresh and a rekey.
                    _state.value = _state.value?.copy(roster = res.participants, notice = "Adding $inviteeName…")
                }
            }

            // §3.3 — mint a FRESH secret and fan it pairwise. Every participant, including the
            // original peer, gets the new epoch: a key the invitee never had is not a key.
            val secret = mintAndFan(callId, res.participants)
            if (secret == null) {
                fail("Couldn't share the call's encryption key.", keepCall = true)
                withContext(Dispatchers.Main) { onResult("Couldn't set up encryption for the new participant.") }
                return@launch
            }

            // Tell the two other legs. Both frames are dropped by today's relay (§3.2 has not
            // landed); the invite also travels as a push, and the migrate is re-derivable by the
            // peer from the roster, so neither is load-bearing for correctness.
            val ws = WebSocketClient.get(ctx)
            runCatching { ws.sendCallInvite(inviteeUserId, callId, kind, adhocRoomName(callId)) }
            peerUserId?.let { runCatching { ws.sendCallMigrate(it, callId, adhocRoomName(callId)) } }

            connectRoom(ctx, callId, publishMedia = false)
            armCutover(callId)
            withContext(Dispatchers.Main) { onResult(null) }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Peer: "you are being moved onto a conference"
    // ─────────────────────────────────────────────────────────────────────────────────────────

    private fun onMigrate(frame: ConferenceRelay.Frame) {
        val ctx = appContext ?: return
        val live = CallManager.state.value
        // Only for the call we are actually on. A migrate naming any other call is someone
        // guessing at call ids and is dropped without a reply.
        if (live == null || live.callId != frame.callId) return
        if (_state.value != null) return                          // already escalating
        init(ctx)
        synchronized(lifecycle) {
            if (_state.value != null) return
            inviterUserId = frame.fromUserId
            originalPeerUserId = frame.fromUserId
            _state.value = ConferenceState(
                callId = frame.callId,
                room = frame.room?.ifBlank { null } ?: adhocRoomName(frame.callId),
                kind = live.kind,
                stage = Stage.ESCALATING,
                isInviter = false,
                videoEnabled = live.kind == CallKind.VIDEO,
                notice = "Adding someone to the call…",
            )
        }
        scope.launch {
            refreshRoster(frame.callId)
            // Subscribe-only, exactly like the inviter: the 1:1 stack still owns the microphone
            // and will until the inviter's `call_hangup` retires that leg.
            connectRoom(ctx, frame.callId, publishMedia = false)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Invitee: accept / decline
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /**
     * The invitee took the call. There is no 1:1 leg on this device, so this goes straight to
     * CONFERENCE and publishes media immediately — nothing else holds the microphone.
     *
     * WE NEVER JOIN UNKEYED. If the per-call secret has not arrived (the inviter is offline, the
     * `call_key` frame was dropped, our prekeys ran out), this fails loudly instead of connecting
     * to the SFU with no frame encryption — connecting would hand plaintext media to the server,
     * which contradicts the entire product.
     */
    fun acceptInvite(context: Context, callId: String, kind: CallKind, inviterUserId: String) {
        init(context)
        val ctx = appContext ?: return
        synchronized(lifecycle) {
            if (_state.value != null) return
            this.inviterUserId = inviterUserId
            this.originalPeerUserId = null
            _state.value = ConferenceState(
                callId = callId,
                room = adhocRoomName(callId),
                kind = kind,
                stage = Stage.CONFERENCE,
                isInviter = false,
                videoEnabled = kind == CallKind.VIDEO,
                notice = "Joining…",
            )
        }
        scope.launch {
            runCatching { WebSocketClient.get(ctx).sendCallInviteAccept(inviterUserId, callId) }
            // invited => joined. This is the membership event the inviter hangs its rekey off,
            // so it must happen before we expect to be able to decrypt anyone.
            val joined = runCatching { ConferenceApi(ctx).join(callId) }.getOrElse {
                Log.e("VOIID", "conference: join failed", it)
                fail("Couldn't join the call.", keepCall = false)
                return@launch
            }
            _state.value = _state.value?.copy(roster = joined.participants, notice = null)
            connectRoom(ctx, callId, publishMedia = true)
        }
    }

    /**
     * The invitee refused. `POST /leave` IS the decline path — it is idempotent and never fails a
     * teardown retry, so it is safe to call from a notification action that may fire twice.
     */
    fun declineInvite(context: Context, callId: String, inviterUserId: String) {
        init(context)
        val ctx = appContext ?: return
        pendingKeyCallId = null
        scope.launch {
            runCatching { WebSocketClient.get(ctx).sendCallInviteDecline(inviterUserId, callId) }
            runCatching { ConferenceApi(ctx).leave(callId) }
                .onFailure { Log.w("VOIID", "conference: decline leave failed (harmless)", it) }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Keying (§3.3)
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /**
     * True when THIS device is responsible for minting the next secret: the inviter, or — if the
     * inviter has left — the lowest user id still on the roster. A deterministic rule both ends
     * evaluate identically is what stops two devices minting competing secrets on the same event.
     */
    private fun shouldMint(): Boolean {
        val ctx = appContext ?: return false
        val myId = TokenStore.get(ctx).userId ?: return false
        val roster = _state.value?.roster.orEmpty()
        val inviter = inviterUserId
        if (inviter != null && roster.any { it.user_id == inviter }) return inviter == myId
        val lowest = roster.map { it.user_id }.filter { it.isNotBlank() }.minOrNull() ?: return false
        return lowest == myId
    }

    /** Mint the next epoch, fan it to everyone else, apply it locally. Returns the secret. */
    private suspend fun mintAndFan(callId: String, roster: List<CallRosterEntry>): String? {
        val c = courier ?: return null
        val ctx = appContext ?: return null
        val myId = TokenStore.get(ctx).userId
        val recipients = roster.map { it.user_id }.filter { it.isNotBlank() && it != myId }
        val epoch = ++keyEpoch
        val secret = runCatching { c.mintAndDistribute(callId, epoch, recipients) }.getOrElse {
            Log.e("VOIID", "conference: minting/distributing the call key failed", it)
            return null
        }
        currentSecret = secret
        applySecret(secret)
        return secret
    }

    /**
     * Re-derive and hand the LiveKit key provider the media key for [secret].
     *
     * Idempotent: an unchanged key is not re-applied, so the opportunistic triggers below cost
     * nothing. Never throws — a failure keeps the call on the CURRENT key rather than tearing it
     * down, which is the same trade the group engine makes.
     */
    private fun applySecret(secret: String) {
        val keyB64 = CallKeyCourier.liveKitSharedKey(secret) ?: run {
            Log.e("VOIID", "conference: could not derive SRTP keys from the call secret")
            return
        }
        if (keyB64 == lastAppliedKey) return
        val provider = keyProvider
        if (provider == null) {
            // The room is not up yet. connectRoom() seeds the provider from currentSecret, so the
            // key is not lost — this is the normal ordering for an invitee, who is keyed while
            // still on the ringing screen.
            lastAppliedKey = null
            return
        }
        runCatching { provider.setSharedKey(keyB64, KEY_INDEX) }
            .onSuccess {
                lastAppliedKey = keyB64
                _state.value = _state.value?.copy(e2ee = true)
                Log.i("VOIID", "conference: media key applied (epoch=$keyEpoch)")
            }
            .onFailure { Log.e("VOIID", "conference: key apply failed — staying on the current key", it) }
    }

    /**
     * REKEY ON EVERY JOIN AND EVERY LEAVE. A leaver who keeps the key keeps the media; a joiner
     * who is handed the old key can decrypt what was said before they arrived. Debounced so a
     * burst of membership changes costs one rotation, exactly like the MLS epoch rekey.
     */
    private fun scheduleRekey(reason: String) {
        val callId = _state.value?.callId ?: return
        rekeyJob?.cancel()
        rekeyJob = scope.launch {
            delay(REKEY_DEBOUNCE_MS)
            refreshRoster(callId)
            if (!shouldMint()) return@launch
            Log.i("VOIID", "conference: re-keying ($reason)")
            mintAndFan(callId, _state.value?.roster.orEmpty())
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Roster (§3.5)
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /**
     * Pull the roster from `GET /v1/calls/:id/participants`.
     *
     * THIS IS THE ONLY IDENTITY SOURCE FOR A CONFERENCE. It returns `username` and `state` and
     * nothing else — no full name, no photo, no phone, no bio — and the result is NEVER written
     * into [com.voiid.app.store.UserDirectory]. Upserting it would make a stranger "known" for
     * every future call and quietly convert a shared call into a persistent identity edge, which
     * is precisely what "a shared call grants no messaging rights" forbids.
     */
    private suspend fun refreshRoster(callId: String) {
        val ctx = appContext ?: return
        val res = runCatching { ConferenceApi(ctx).participants(callId) }.getOrElse {
            Log.w("VOIID", "conference: roster refresh failed (keeping the last one)", it)
            return
        }
        _state.value = _state.value?.copy(roster = res.participants)
        publishSnapshot()
    }

    /** For the "add person" sheet and any surface that wants the current roster on demand. */
    fun refreshRosterNow() {
        val callId = _state.value?.callId ?: return
        scope.launch { refreshRoster(callId) }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // LiveKit room
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /**
     * Fetch an ad-hoc token and connect.
     *
     * [publishMedia] is false for both original participants during ESCALATING — see the
     * audio-session note in this object's header. It is true for an invitee, who has no competing
     * capture, and is flipped on at cutover.
     */
    private suspend fun connectRoom(ctx: Context, callId: String, publishMedia: Boolean) {
        if (room != null) {
            if (publishMedia) publishLocalMedia()
            return
        }
        val creds = try {
            ConferenceApi(ctx).adhocToken(callId)
        } catch (e: ApiError.Http) {
            fail(
                if (e.status == 503) "Conference calling isn't configured on this server."
                else e.message ?: "Couldn't join the conference.",
                keepCall = true,
            )
            return
        } catch (e: Exception) {
            Log.e("VOIID", "conference: adhoc token failed", e)
            fail("Couldn't reach the server to join the conference.", keepCall = true)
            return
        }

        // NEVER JOIN WITHOUT A KEY. Both group clients already refuse; so does this one. A room
        // joined with no frame encryption hands plaintext media to the SFU.
        val secret = currentSecret
        val keyB64 = secret?.let { CallKeyCourier.liveKitSharedKey(it) }
        if (keyB64 == null) {
            Log.e("VOIID", "conference: no per-call secret for $callId — refusing to join unkeyed")
            fail("Encryption keys for this call aren't ready yet.", keepCall = true)
            return
        }

        // Claim the foreground service BEFORE the room goes live.
        //
        // Started here rather than at accept time because this is the point where media
        // actually gets published — and it must be running before that, or Android may
        // suspend capture the moment the app backgrounds. `startGroup` is the same call the
        // group engine makes; the conference is a multi-party room by the same rules.
        appContext?.let { c ->
            runCatching {
                // ConferenceState carries no title — the roster is @usernames only by
                // design (see CallRosterEntry.displayName), so there is no name to show
                // that would not leak an identity the roster deliberately withholds.
                CallForegroundService.startGroup(
                    c,
                    "Voiid call",
                    video = _state.value?.kind == CallKind.VIDEO
                )
            }
        }

        val e2eeOptions = runCatching {
            // CRITICAL ORDERING, inherited verbatim from the group engine: E2EEOptions() eagerly
            // constructs a native FrameCryptor key provider via JNI, and that native library is
            // only loaded once LiveKit has initialized WebRTC. Constructing it first throws
            // UnsatisfiedLinkError on the first conference in a process.
            LiveKit.init(ctx)
            E2EEOptions().also {
                it.keyProvider.setSharedKey(keyB64, KEY_INDEX)
                keyProvider = it.keyProvider
                lastAppliedKey = keyB64
            }
        }.getOrElse {
            Log.e("VOIID", "conference: E2EE setup failed", it)
            fail("Couldn't set up encryption for this call.", keepCall = true)
            return
        }

        val r = try {
            withContext(Dispatchers.Main) {
                LiveKit.create(
                    appContext = ctx,
                    options = RoomOptions(adaptiveStream = true, dynacast = true, e2eeOptions = e2eeOptions),
                )
            }
        } catch (e: Exception) {
            Log.e("VOIID", "conference: room create failed", e)
            fail("Couldn't start the conference engine.", keepCall = true)
            return
        }
        if (_state.value == null) { runCatching { r.disconnect() }; return }   // torn down during setup
        room = r
        _state.value = _state.value?.copy(e2ee = true)
        startEventMirror(r)

        try {
            r.connect(creds.url, creds.token)
        } catch (e: Exception) {
            Log.e("VOIID", "conference: connect failed", e)
            fail("Couldn't connect to the conference.", keepCall = true)
            return
        }
        if (_state.value == null) { teardownRoom(); return }
        _state.value = _state.value?.copy(sfuConnected = true)
        Log.i("VOIID", "conference: on the SFU room=${creds.room} publishing=$publishMedia")

        if (publishMedia) publishLocalMedia()
        publishSnapshot()
    }

    /**
     * Take ownership of the microphone (and camera for a video call) and assert the route.
     *
     * Only ever called when NOTHING ELSE holds the capture: either we are an invitee with no 1:1
     * leg, or the 1:1 leg has just been torn down at cutover.
     */
    private suspend fun publishLocalMedia() {
        val r = room ?: return
        val s = _state.value ?: return
        runCatching { r.localParticipant.setMicrophoneEnabled(true) }
            .onFailure { Log.e("VOIID", "conference: mic publish failed", it) }
        if (s.kind == CallKind.VIDEO) {
            runCatching { r.localParticipant.setCameraEnabled(true) }
                .onFailure { Log.e("VOIID", "conference: camera publish failed", it) }
        }
        applySpeaker(s.speakerOn)
        publishSnapshot()
    }

    private fun startEventMirror(r: Room) {
        eventJob?.cancel()
        eventJob = scope.launch {
            r.events.events.collect { ev ->
                when (ev) {
                    is RoomEvent.Disconnected -> {
                        Log.i("VOIID", "conference: disconnected reason=${ev.reason}")
                        // During ESCALATING the 1:1 call is still standing — losing the SFU means
                        // the escalation failed, NOT that the call ended.
                        if (_state.value?.stage == Stage.ESCALATING) {
                            fail("Couldn't add anyone to this call.", keepCall = true)
                        } else {
                            endInternal(userInitiated = false)
                        }
                        return@collect
                    }
                    is RoomEvent.FailedToConnect -> {
                        Log.e("VOIID", "conference: failed to connect", ev.error)
                        fail("Couldn't connect to the conference.", keepCall = true)
                        return@collect
                    }
                    is RoomEvent.ParticipantConnected,
                    is RoomEvent.ParticipantDisconnected,
                    -> {
                        // Membership moved: re-key (§3.3) and re-check whether both original
                        // participants are now on the SFU, which is the cutover condition.
                        scheduleRekey("SFU membership changed")
                        maybeCutOver()
                    }
                    else -> Unit
                }
                publishSnapshot()
            }
        }
    }

    /**
     * Rebuild the tile list from the SDK's state.
     *
     * NAMES COME FROM THE ROSTER, NOT FROM LIVEKIT. The SDK's `participant.name` is whatever the
     * token carried — and the ad-hoc token deliberately carries no `name` claim, which used to
     * leave the group grid falling back to `identity.substringBefore(':')`: a raw user id on
     * screen, the exact house-rule violation §3.5 exists to end. Every tile resolves through
     * [CallRosterEntry.displayName], so a stranger reads "@handle" and a saved contact reads
     * whatever you saved them as.
     */
    private fun publishSnapshot() {
        val r = room ?: return
        val cur = _state.value ?: return
        val speakers = runCatching { r.activeSpeakers.mapNotNull { it.identity?.value }.toSet() }
            .getOrDefault(emptySet())

        fun label(userId: String, isLocal: Boolean): String {
            if (isLocal) return "You"
            val entry = cur.roster.firstOrNull { it.user_id == userId }
            return entry?.displayName()
                ?: com.voiid.app.store.UserDirectory.callRosterName(userId, null)
        }

        val local = runCatching {
            val lp = r.localParticipant
            val ident = lp.identity?.value ?: ""
            val camPub = lp.getTrackPublication(Track.Source.CAMERA)
            val micPub = lp.getTrackPublication(Track.Source.MICROPHONE)
            Tile(
                identity = ident,
                userId = ident.substringBefore(':'),
                name = "You",
                isLocal = true,
                speaking = lp.isSpeaking,
                micMuted = micPub?.muted ?: true,
                cameraOn = camPub != null && !camPub.muted,
                videoTrack = camPub?.track as? VideoTrack,
            )
        }.getOrNull()

        val remotes = runCatching {
            r.remoteParticipants.values.map { p ->
                val ident = p.identity?.value ?: ""
                val uid = ident.substringBefore(':')
                val camPub = p.getTrackPublication(Track.Source.CAMERA)
                val micPub = p.getTrackPublication(Track.Source.MICROPHONE)
                Tile(
                    identity = ident,
                    userId = uid,
                    name = label(uid, isLocal = false),
                    isLocal = false,
                    speaking = p.isSpeaking || ident in speakers,
                    micMuted = micPub?.muted ?: true,
                    cameraOn = camPub != null && !camPub.muted,
                    videoTrack = camPub?.track as? VideoTrack,
                )
            }.sortedBy { it.identity }
        }.getOrDefault(emptyList())

        _state.value = cur.copy(
            tiles = listOfNotNull(local) + remotes,
            muted = local?.micMuted ?: cur.muted,
            videoEnabled = local?.cameraOn ?: cur.videoEnabled,
        )
    }

    /** Every user id currently visible on the SFU, ourselves included. */
    private fun sfuUserIds(): Set<String> {
        val r = room ?: return emptySet()
        val out = mutableSetOf<String>()
        runCatching { r.localParticipant.identity?.value }.getOrNull()?.let { out += it.substringBefore(':') }
        runCatching { r.remoteParticipants.values.mapNotNull { it.identity?.value } }
            .getOrDefault(emptyList())
            .forEach { out += it.substringBefore(':') }
        return out
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Make-before-break cutover (§3.4)
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /** Start the clock on an escalation. If the SFU never comes up we fall back to the 1:1 call. */
    private fun armCutover(callId: String) {
        cutoverJob?.cancel()
        cutoverJob = scope.launch {
            delay(ESCALATION_TIMEOUT_MS)
            val s = _state.value ?: return@launch
            if (s.callId != callId || s.stage != Stage.ESCALATING) return@launch
            Log.w("VOIID", "conference: escalation timed out — falling back to the 1:1 call")
            fail("Couldn't add anyone to this call.", keepCall = true)
        }
    }

    /**
     * Retire the 1:1 leg once **both original participants are on the SFU** — never before.
     *
     * That ordering is the whole of make-before-break: the peer-to-peer call is the fallback, and
     * a fallback you have already hung up is not one. Only the INVITER performs the cutover, and
     * it does so by sending an ordinary `call_hangup`; the peer recognises a hangup arriving mid-
     * escalation and retires its own leg the same way (see [CallManager.retire1to1LegForConference]).
     * One owner of the decision means the two sides cannot disagree about which leg is live.
     */
    private fun maybeCutOver() {
        val s = _state.value ?: return
        if (s.stage != Stage.ESCALATING) return
        if (!s.isInviter) return
        val ctx = appContext ?: return
        val myId = TokenStore.get(ctx).userId ?: return
        val peer = originalPeerUserId ?: return
        val onSfu = sfuUserIds()
        if (myId !in onSfu || peer !in onSfu) return

        cutoverJob?.cancel(); cutoverJob = null
        Log.i("VOIID", "conference: both original participants on the SFU — retiring the 1:1 leg")
        _state.value = s.copy(stage = Stage.CONFERENCE, notice = null)
        // Ordinary hangup: the peer's engine already knows this call is escalating and will treat
        // it as "retire the leg", while a peer that somehow missed the migrate simply ends the
        // call — which is the honest outcome for a client that never made it onto the SFU.
        CallManager.retire1to1LegForConference(notifyPeer = true)
        scope.launch { publishLocalMedia() }
    }

    /**
     * The 1:1 leg has gone away on THIS device (the inviter hung it up). Called by [CallManager].
     * Promotes us to CONFERENCE and takes over the microphone.
     */
    fun on1to1LegRetired() {
        val s = _state.value ?: return
        if (s.stage != Stage.ESCALATING) return
        cutoverJob?.cancel(); cutoverJob = null
        _state.value = s.copy(stage = Stage.CONFERENCE, notice = null)
        scope.launch { publishLocalMedia() }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Controls
    // ─────────────────────────────────────────────────────────────────────────────────────────

    fun toggleMute() {
        val r = room ?: return
        val target = !(_state.value?.muted ?: false)
        scope.launch {
            runCatching { r.localParticipant.setMicrophoneEnabled(!target) }
                .onFailure { Log.e("VOIID", "conference: toggle mute failed", it) }
            publishSnapshot()
        }
    }

    fun toggleVideo() {
        val r = room ?: return
        val target = !(_state.value?.videoEnabled ?: false)
        scope.launch {
            runCatching { r.localParticipant.setCameraEnabled(target) }
                .onFailure { Log.e("VOIID", "conference: toggle video failed", it) }
            publishSnapshot()
        }
    }

    fun switchCamera() {
        val r = room ?: return
        scope.launch {
            runCatching {
                (r.localParticipant.getTrackPublication(Track.Source.CAMERA)?.track as? LocalVideoTrack)
                    ?.switchCamera()
            }.onFailure { Log.e("VOIID", "conference: switch camera failed", it) }
        }
    }

    fun toggleSpeaker() {
        val on = !(_state.value?.speakerOn ?: true)
        applySpeaker(on)
        _state.value = _state.value?.copy(speakerOn = on)
    }

    /**
     * Assert the audio route. Only meaningful once this engine owns the capture — during
     * ESCALATING the 1:1 stack (and, when it took the call, Telecom) owns the route, and two
     * owners fighting over it produces device-specific bugs that never reproduce on a dev machine.
     */
    /** The device's audio mode before this call touched it, so teardown can put it back. */
    @Volatile private var savedAudioMode: Int? = null

    /**
     * Undo everything [applySpeaker] did. See the twin in GroupCallService — the 1:1 engine
     * has always restored the route correctly and both LiveKit engines simply never did, so
     * the device stayed in MODE_IN_COMMUNICATION after every conference call.
     */
    private fun restoreAudioRoute() {
        val mode = savedAudioMode ?: return   // never configured; nothing to undo
        savedAudioMode = null
        val ctx = appContext ?: return
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { am.clearCommunicationDevice() }
        }
        @Suppress("DEPRECATION")
        runCatching {
            am.isBluetoothScoOn = false
            am.stopBluetoothSco()
            am.isSpeakerphoneOn = false
        }
        runCatching { am.mode = mode }
    }

    private fun applySpeaker(on: Boolean) {
        if (_state.value?.stage == Stage.ESCALATING) return
        val ctx = appContext ?: return
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        runCatching {
            // Captured BEFORE the first override, and only once.
            if (savedAudioMode == null) savedAudioMode = am.mode
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val devices = am.availableCommunicationDevices
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

    /** Bind a LiveKit renderer to this room's EGL context. Must be a `livekit.org.webrtc` one. */
    fun initRenderer(renderer: livekit.org.webrtc.SurfaceViewRenderer) {
        runCatching { room?.initVideoRenderer(renderer) }
            .onFailure { Log.e("VOIID", "conference: renderer init failed", it) }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Teardown
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /** The user left the conference. Also the path [CallManager] takes when the call ends. */
    fun leave() = endInternal(userInitiated = true)

    private fun endInternal(userInitiated: Boolean) {
        val s = synchronized(lifecycle) {
            val cur = _state.value ?: return
            _state.value = null
            cur
        }
        Log.i("VOIID", "conference: ended userInitiated=$userInitiated")
        val ctx = appContext
        if (ctx != null) {
            // IDEMPOTENT AND FIRE-AND-FORGET. `POST /leave` never fails a teardown retry, rewrites
            // the Redis grant without us (so our frames stop relaying immediately) and ends the
            // call outright once the last participant is gone. A failure here costs a stale roster
            // row that the grant TTL reaps; it must never block or fail local teardown.
            scope.launch {
                runCatching { ConferenceApi(ctx).leave(s.callId) }
                    .onFailure { Log.w("VOIID", "conference: leave POST failed (grant TTL will reap)", it) }
            }
        }
        teardownRoom()

        // RETIRE THE 1:1 BOOKKEEPING this conference grew out of: an accepted invite (or a
        // completed escalation) parked a CONNECTING/leg state in [CallManager]. Without this
        // it stayed forever — blocking every future call ("one call at a time") and keeping
        // the frame-cryptor keys alive past the call they belong to.
        val leg = CallManager.state.value
        if (leg?.callId == s.callId && leg.isConferenceInvite) {
            CallManager.retireConferenceLeg(callId = s.callId)
        }
    }

    /**
     * The escalation failed.
     *
     * [keepCall] is the difference between "this conference is over" and "the 1:1 call underneath
     * is still perfectly fine": on an SFU failure mid-escalation we abandon the room and hand the
     * user back their original call rather than dropping it. Deliberately does NOT `POST /leave` in
     * that case — our participant row is what keeps the ring grant naming us, and dropping it would
     * take the still-standing 1:1 leg's relay authorization with it.
     */
    private fun fail(message: String, keepCall: Boolean) {
        val cur = _state.value
        if (cur != null) _state.value = cur.copy(stage = Stage.ENDED, error = message, notice = null)
        teardownRoom()
        if (!keepCall) {
            val ctx = appContext
            val callId = cur?.callId
            if (ctx != null && callId != null) {
                scope.launch { runCatching { ConferenceApi(ctx).leave(callId) } }
            }
        }
        scope.launch {
            delay(ERROR_LINGER_MS)
            if (_state.value?.error != null) _state.value = null
        }
    }

    /** Release the room. Never throws — this runs on error paths. */
    private fun teardownRoom() {
        restoreAudioRoute()
        // The conference engine never started or stopped a foreground service — the only
        // FGS was the 1:1 one, and CallManager's teardown actively STOPS that. So an
        // invitee who accepted an ad-hoc conference had a live room and a published mic
        // with no foreground service at all: backgrounding the app let Android suspend
        // capture, and on 12+ kill the process. Stopping here is half of the fix; the
        // start is in connectRoom.
        appContext?.let { runCatching { CallForegroundService.stop(it) } }
        eventJob?.cancel(); eventJob = null
        rekeyJob?.cancel(); rekeyJob = null
        cutoverJob?.cancel(); cutoverJob = null
        val r = room
        room = null
        keyProvider = null
        lastAppliedKey = null
        currentSecret = null
        keyEpoch = 0
        inviterUserId = null
        originalPeerUserId = null
        pendingKeyCallId = null
        runCatching { r?.disconnect() }
        runCatching { r?.release() }
    }
}
