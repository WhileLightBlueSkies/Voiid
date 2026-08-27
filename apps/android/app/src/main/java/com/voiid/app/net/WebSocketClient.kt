package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

/**
 * Realtime connection to the backend WS relay (wss://…/ws?token=JWT). Mirrors iOS.
 * The server pushes only *references* — {type:"message", conversation_id} and
 * {type:"typing", …} — so on a message ref we tell the app to fetch+decrypt that
 * conversation. Also sends heartbeat + typing frames.
 */
class WebSocketClient private constructor(context: Context) {

    companion object {
        @Volatile private var instance: WebSocketClient? = null
        fun get(context: Context): WebSocketClient =
            instance ?: synchronized(this) {
                instance ?: WebSocketClient(context.applicationContext).also { instance = it }
            }
        private val json = Json { ignoreUnknownKeys = true }

        /** Upper bound on parked outbound frames during a signaling outage. */
        private const val MAX_OUTBOX = 256
        private const val CALL_BACKOFF_CAP_MS = 5_000L
        private const val IDLE_BACKOFF_CAP_MS = 30_000L
    }

    private val tokens = TokenStore.get(context)
    private val client = OkHttpClient.Builder()
        .pingInterval(30, TimeUnit.SECONDS)   // OkHttp-level keepalive
        .build()
    private val scope = CoroutineScope(Dispatchers.Main)

    private var socket: WebSocket? = null
    /** A socket object exists and we have not given up on it (attempting OR established). */
    @Volatile private var connected = false
    /** The WS handshake actually completed — only then can frames go out on the wire. */
    @Volatile private var open = false
    @Volatile private var closedByUs = false
    private var heartbeatJob: kotlinx.coroutines.Job? = null
    private var reconnectJob: kotlinx.coroutines.Job? = null
    private var reconnectAttempts = 0

    /**
     * True while a call is up. Media (SRTP) flows peer-to-peer and survives a signaling
     * outage untouched, so a dropped socket must never end a call — but we do want to get
     * the relay back fast, because trickle ICE and hangup ride on it. During a call we cap
     * the backoff far lower than we would for idle chat sync.
     */
    @Volatile var callActive = false

    /**
     * Outbound frames that could not be written because the socket was down. Flushed **in
     * order** on reconnect — ordering matters for signaling, where an answer must not
     * overtake the offer it answers. Bounded so a long outage can't grow without limit;
     * ICE candidates are the bulk of the traffic and stale ones are worthless anyway.
     */
    private val outbox = ArrayDeque<String>()
    private val outboxLock = Any()

    /** New message arrived for a conversation -> the app should fetch + decrypt it. */
    var onMessageRef: ((conversationId: String) -> Unit)? = null
    /** Typing updates: conversationId, fromUserId, isTyping. */
    var onTyping: ((conversationId: String, userId: String, isTyping: Boolean) -> Unit)? = null
    /** Receipt for one of OUR sent messages: messageId, status ("delivered"|"read"). */
    var onReceipt: ((messageId: String, status: String) -> Unit)? = null
    /** Peer couldn't decrypt our message → reset (re-establish) the session for this conversation. */
    var onSessionReset: ((conversationId: String) -> Unit)? = null
    /** An MLS group control event (welcome/commit) was relayed for one of our groups. */
    var onMlsEvent: ((conversationId: String?) -> Unit)? = null

    /**
     * A story arrived, was viewed, or was deleted — the signal to re-sync the story feed.
     *
     * Android had NO handler for these frames: they fell through to `else -> Unit`, so a story
     * only ever appeared when the user manually opened the Stories tab (a one-shot
     * `LaunchedEffect(Unit)`). iOS has consumed them since day one via `.voiidStorySignal`.
     * Carries no payload because the client re-fetches through the authenticated feed anyway —
     * the frame is a nudge, not data.
     */
    var onStorySignal: (() -> Unit)? = null
    /** A call-signaling frame (offer/answer/ice/hangup/decline/busy/ringing/hold) was relayed to us. */
    var onCallSignal: ((CallSignal) -> Unit)? = null
    /**
     * Another of YOUR devices answered or declined this call. `(callId, reason)`.
     *
     * Server-originated on your own channel, so it has no peer — see the dispatch branch.
     */
    var onCallTaken: ((String, String) -> Unit)? = null

    /** One inbound call-signaling frame. `from_user_id` is server-stamped (authenticated). */
    data class CallSignal(
        val type: String,
        val fromUserId: String,
        val callId: String,
        val callKind: String?,
        val sdp: String?,
        val candidate: JsonObject?,
        val conversationId: String?,
    )

    fun connect() {
        if (connected) return
        val jwt = tokens.jwt ?: run { android.util.Log.w("VOIID", "WS connect skipped (no JWT)"); return }
        closedByUs = false
        val url = ApiConfig.wsUrl.trimEnd('/') + "?token=" + jwt
        val req = Request.Builder().url(url).build()
        socket = client.newWebSocket(req, listener)
        connected = true
        android.util.Log.i("VOIID", "WS connecting")
        startHeartbeat()
    }

    fun disconnect() {
        closedByUs = true
        heartbeatJob?.cancel(); heartbeatJob = null
        reconnectJob?.cancel(); reconnectJob = null
        socket?.close(1000, "client closing")
        socket = null
        connected = false
        open = false
    }

    /** Force a fresh socket — call when the chats screen appears, so a stale/dead
     *  socket (that silently stopped receiving) is replaced and pushes aren't missed. */
    fun reconnect() {
        disconnect()
        connect()
    }

    /** App-level heartbeat the BACKEND understands (keeps `online` fresh + updates
     *  last_seen). OkHttp's pingInterval is only a protocol PING the server ignores. */
    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (true) {
                kotlinx.coroutines.delay(25_000)
                send("""{"type":"heartbeat"}""", queueIfDown = false)
            }
        }
    }

    /**
     * Write a frame now, or park it in the [outbox] if the socket is down.
     *
     * [queueIfDown] is false for frames whose value expires immediately (heartbeats, typing
     * indicators) — replaying those minutes later is noise. Call signaling always queues.
     */
    private fun send(frame: String, queueIfDown: Boolean) {
        val s = socket
        if (open && s != null && s.send(frame)) return
        if (!queueIfDown) return
        synchronized(outboxLock) {
            // GAME INPUT IS COALESCED, NOT APPENDED. Every other queued frame here is a
            // discrete event with its own identity — a message, an ICE candidate, a call
            // signal — and losing one loses something real. A steering frame is a POSITION:
            // the newest one fully supersedes every older one for the same match, so queuing
            // them as a growing backlog is queuing garbage.
            //
            // Treating it like the others caused two failures. First, the outbox is shared and
            // bounded, dropping from the front — a ~9 second blip at Snake's 10-15 frames/sec
            // fills it completely, so stale headings were evicting queued messages, call offers
            // and ICE candidates to make room for themselves. Second, on reconnect the whole
            // backlog flushed as one burst, instantly spending an entire rate-limit window
            // (docs/GAMES_SNAKE_BUGS.md Part A) and blacking out controls again right as the
            // player regained connectivity — a brief blip alone was enough to retrigger the
            // freeze.
            //
            // Replacing the prior queued input for the SAME match fixes both: steering can
            // never grow the outbox, and reconnect replays exactly one heading, not a burst.
            val matchId = gameInputMatchId(frame)
            val replaced = matchId != null && run {
                val idx = outbox.indexOfFirst { gameInputMatchId(it) == matchId }
                if (idx >= 0) { outbox[idx] = frame; true } else false
            }
            if (!replaced) {
                if (outbox.size >= MAX_OUTBOX) outbox.removeFirst()
                outbox.addLast(frame)
            }
        }
        // A queued frame means we believe we're live but aren't; make sure a retry is pending.
        if (!closedByUs && !connected) scheduleReconnect()
    }

    /** match_id if [frame] is a `game_input` frame, else null. Cheap prefix check before parse. */
    private fun gameInputMatchId(frame: String): String? {
        if (!frame.startsWith("""{"type":"game_input"""")) return null
        return runCatching {
            json.parseToJsonElement(frame).jsonObject["match_id"]?.jsonPrimitive?.contentOrNull
        }.getOrNull()
    }

    /** Drain the outbox in FIFO order. Anything that fails to write goes back at the front. */
    private fun flushOutbox() {
        val pending: List<String> = synchronized(outboxLock) {
            if (outbox.isEmpty()) return
            val copy = outbox.toList()
            outbox.clear()
            copy
        }
        val s = socket
        for ((i, frame) in pending.withIndex()) {
            if (!open || s == null || !s.send(frame)) {
                synchronized(outboxLock) {
                    // Re-queue the unsent tail, preserving order.
                    for (remaining in pending.subList(i, pending.size).reversed()) {
                        if (outbox.size < MAX_OUTBOX) outbox.addFirst(remaining)
                    }
                }
                return
            }
        }
    }

    /**
     * Exponential backoff with jitter, capped. The cap is deliberately short while a call is
     * up: trickle ICE and hangup both need the relay, and a 30 s hole there is user-visible.
     */
    private fun scheduleReconnect() {
        if (closedByUs) return
        if (reconnectJob?.isActive == true) return
        val attempt = reconnectAttempts.coerceAtMost(6)
        val cap = if (callActive) CALL_BACKOFF_CAP_MS else IDLE_BACKOFF_CAP_MS
        val base = (1_000L shl attempt).coerceAtMost(cap)
        val delayMs = base / 2 + (Math.random() * base / 2).toLong()
        reconnectAttempts++
        reconnectJob = scope.launch {
            delay(delayMs)
            reconnectJob = null
            if (!closedByUs && !open) connect()
        }
    }

    fun sendTyping(conversationId: String, recipientIds: List<String>, isStart: Boolean) {
        val recips = recipientIds.joinToString(",") { "\"" + it + "\"" }
        val frame = """{"type":"typing","conversation_id":"$conversationId","recipient_ids":[$recips],"state":"${if (isStart) "start" else "stop"}"}"""
        send(frame, queueIfDown = false)
    }

    // ---- Location fixes (docs/LOCATION.md P3) -----------------------------------
    // The ephemeral position stream. `ciphertext` is an opaque base64 blob (one
    // ciphertext for the whole audience, encrypted under a shareKey the server never
    // holds). NOT queued if the socket is down: a stale position is worse than none, and
    // the server buffers only the latest fix for a genuinely-offline recipient anyway.

    /** Relay one encrypted position fix to the recipient list (P3 stream, never a message row). */
    fun sendLocUpdate(shareId: String, recipientIds: List<String>, ciphertextB64: String) {
        val recips = recipientIds.joinToString(",") { enc(it) }
        send("""{"type":"loc_update","share_id":${enc(shareId)},"recipient_ids":[$recips],"ciphertext":${enc(ciphertextB64)}}""", queueIfDown = false)
    }

    /** Instant stop for live sockets. The durable stop rides the message path separately. */
    fun sendLocStop(shareId: String, recipientIds: List<String>) {
        val recips = recipientIds.joinToString(",") { enc(it) }
        send("""{"type":"loc_stop","share_id":${enc(shareId)},"recipient_ids":[$recips]}""", queueIfDown = false)
    }

    /**
     * Submit one game move (docs/GAMES.md §6). Unlike loc_update there is no recipient
     * list: the relay hands this to backend/games, which knows the roster and answers the
     * players itself.
     *
     * queueIfDown = true, deliberately unlike location: a stale position is worthless, but
     * a move is the player's actual intent, and silently dropping it looks like the tap
     * never registered. The server rejects it if the match has moved on.
     */
    fun sendGameInput(matchId: String, payloadJson: String) {
        send("""{"type":"game_input","match_id":${enc(matchId)},"payload":$payloadJson}""", queueIfDown = true)
    }

    /** Ask the message's sender to re-establish the E2E session (we couldn't decrypt). */
    fun sendSessionReset(conversationId: String, recipientIds: List<String>) {
        val recips = recipientIds.joinToString(",") { "\"" + it + "\"" }
        send("""{"type":"session_reset","conversation_id":"$conversationId","recipient_ids":[$recips]}""", queueIfDown = true)
    }

    // ---- 1:1 call signaling (relayed; server stamps from_user_id) ---------------

    /** Send an SDP offer to start a call. Values are JSON-escaped (SDP has newlines/quotes). */
    fun sendCallOffer(toUserId: String, callId: String, kind: com.voiid.app.main.CallKind, sdp: String) {
        val k = if (kind == com.voiid.app.main.CallKind.VIDEO) "video" else "voice"
        send("""{"type":"call_offer","to_user_id":${enc(toUserId)},"call_id":${enc(callId)},"call_kind":"$k","sdp":${enc(sdp)}}""", queueIfDown = true)
    }

    /** Answer an incoming call with our SDP answer. */
    fun sendCallAnswer(toUserId: String, callId: String, sdp: String) {
        send("""{"type":"call_answer","to_user_id":${enc(toUserId)},"call_id":${enc(callId)},"sdp":${enc(sdp)}}""", queueIfDown = true)
    }

    /** Trickle one ICE candidate. [candidateJson] is a ready JSON object string. */
    fun sendCallIce(toUserId: String, callId: String, candidateJson: String) {
        send("""{"type":"call_ice","to_user_id":${enc(toUserId)},"call_id":${enc(callId)},"candidate":$candidateJson}""", queueIfDown = true)
    }

    fun sendCallHangup(toUserId: String, callId: String) {
        send("""{"type":"call_hangup","to_user_id":${enc(toUserId)},"call_id":${enc(callId)}}""", queueIfDown = true)
    }

    fun sendCallDecline(toUserId: String, callId: String) {
        send("""{"type":"call_decline","to_user_id":${enc(toUserId)},"call_id":${enc(callId)}}""", queueIfDown = true)
    }

    fun sendCallBusy(toUserId: String, callId: String) {
        send("""{"type":"call_busy","to_user_id":${enc(toUserId)},"call_id":${enc(callId)}}""", queueIfDown = true)
    }

    /**
     * "My device is actually alerting now." Sent by the CALLEE the moment the incoming-call
     * notification / full-screen intent goes up, and it is what starts the caller's ringback.
     * Deliberately not sent optimistically by the caller on offer — otherwise the caller hears
     * ringing for a phone that never rang.
     */
    fun sendCallRinging(toUserId: String, callId: String) {
        send("""{"type":"call_ringing","to_user_id":${enc(toUserId)},"call_id":${enc(callId)}}""", queueIfDown = true)
    }

    /** We put the call on hold — the peer should stop expecting media and show "On hold". */
    fun sendCallHold(toUserId: String, callId: String) {
        send("""{"type":"call_hold","to_user_id":${enc(toUserId)},"call_id":${enc(callId)}}""", queueIfDown = true)
    }

    /** We resumed from hold. */
    fun sendCallUnhold(toUserId: String, callId: String) {
        send("""{"type":"call_unhold","to_user_id":${enc(toUserId)},"call_id":${enc(callId)}}""", queueIfDown = true)
    }

    // ---- Conference escalation signaling (repair plan §3.2 wire types) ----------
    //
    // Five NEW unicast frames, built with the identical discipline as the nine above: a single
    // `to_user_id`, `from_user_id` stamped server-side from the socket JWT, and the outbound
    // frame rebuilt by the relay from a fixed field list.
    //
    // *** THE RELAY DOES NOT UNDERSTAND THESE YET. *** `backend/websocket/src/index.ts` is owned
    // by another fleet and its whitelist still lists only the nine 1:1 types, so until §3.2 lands
    // every frame below is dropped at the relay. That is deliberate and safe: the escalation
    // engine treats a missing `call_migrate`/`call_key` as "the SFU leg did not come up" and
    // falls back to the still-standing 1:1 call (see ConferenceManager). Nothing here can break
    // an ordinary 1:1 call, because an ordinary 1:1 call never sends any of it.
    //
    // FIELDS THE RELAY MUST CARRY when it does land (anything else it may drop):
    //   call_invite         : call_id, to_user_id, call_kind, room
    //   call_invite_accept  : call_id, to_user_id
    //   call_invite_decline : call_id, to_user_id
    //   call_migrate        : call_id, to_user_id, room
    //   call_key            : call_id, to_user_id, device_id, sender_device_id, ciphertext
    //
    // `call_key.ciphertext` is pairwise Double-Ratchet output and is OPAQUE — the relay must
    // apply the same base64-only structural check `loc_update` uses so this process can never
    // carry readable key material, and must never log it. Everything the key frame needs to say
    // beyond routing (which call, which rekey epoch) lives INSIDE the ciphertext, so the relay
    // sees routing ids and an opaque blob and nothing else.

    /** Inviter -> invitee: "you are being added to call [callId]". Rides alongside the ring push. */
    fun sendCallInvite(toUserId: String, callId: String, kind: com.voiid.app.main.CallKind, room: String) {
        val k = if (kind == com.voiid.app.main.CallKind.VIDEO) "video" else "voice"
        send("""{"type":"call_invite","to_user_id":${enc(toUserId)},"call_id":${enc(callId)},"call_kind":"$k","room":${enc(room)}}""", queueIfDown = true)
    }

    /** Invitee -> inviter: "I took it." The inviter uses this to start the rekey. */
    fun sendCallInviteAccept(toUserId: String, callId: String) {
        send("""{"type":"call_invite_accept","to_user_id":${enc(toUserId)},"call_id":${enc(callId)}}""", queueIfDown = true)
    }

    /** Invitee -> inviter: "no thanks." Also the invitee's other devices stop ringing. */
    fun sendCallInviteDecline(toUserId: String, callId: String) {
        send("""{"type":"call_invite_decline","to_user_id":${enc(toUserId)},"call_id":${enc(callId)}}""", queueIfDown = true)
    }

    /** Inviter -> current 1:1 peer: "join the SFU room; keep our leg up until you're on it." */
    fun sendCallMigrate(toUserId: String, callId: String, room: String) {
        send("""{"type":"call_migrate","to_user_id":${enc(toUserId)},"call_id":${enc(callId)},"room":${enc(room)}}""", queueIfDown = true)
    }

    /**
     * One participant's copy of the per-call secret, encrypted to ONE of their devices over the
     * existing Double Ratchet. [ciphertextB64] is opaque to us and to the relay.
     *
     * [deviceId] names WHICH of the recipient's devices this copy is for — a user's devices all
     * share one Redis channel, so every device sees every copy and must pick its own.
     */
    fun sendCallKey(
        toUserId: String,
        callId: String,
        deviceId: String,
        senderDeviceId: String?,
        ciphertextB64: String,
    ) {
        send(
            """{"type":"call_key","to_user_id":${enc(toUserId)},"call_id":${enc(callId)},""" +
                """"device_id":${enc(deviceId)},"sender_device_id":${enc(senderDeviceId ?: "")},""" +
                """"ciphertext":${enc(ciphertextB64)}}""",
            queueIfDown = true,
        )
    }

    /** JSON-encode a string as a quoted literal (escapes quotes/newlines). */
    private fun enc(s: String): String = JsonPrimitive(s).toString()

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            open = true
            connected = true
            reconnectAttempts = 0
            android.util.Log.i("VOIID", "WS open")
            // Anything that piled up while we were down goes out now, in the order it was made.
            scope.launch { flushOutbox() }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            scope.launch { handle(text) }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            android.util.Log.w("VOIID", "WS disconnected: ${t.message} — reconnecting")
            onDown(webSocket)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            onDown(webSocket)
        }
    }

    /**
     * A socket died. Note this never touches call state — the peer connection's SRTP flow is
     * independent of the relay, so a connected call keeps its audio and video throughout.
     */
    private fun onDown(dead: WebSocket) {
        // Ignore the death rattle of a socket we already replaced.
        if (socket !== dead) return
        open = false
        connected = false
        if (!closedByUs) scheduleReconnect()
    }

    private fun handle(text: String) {
        val obj: JsonObject = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        val t = (obj["type"] as? JsonPrimitive)?.contentOrNull
        android.util.Log.i("VOIID", "WS recv type=$t")
        when (t) {
            "message" -> obj["conversation_id"]?.jsonPrimitive?.contentOrNull?.let {
                // Diagnostic: distinguishes "the live frame arrived" from "only FCM woke us".
                // Read receipts for a message that lands while the chat is open depend on THIS
                // firing; if it never does, the socket is down and the push is the only path.
                android.util.Log.i("VOIIDWS", "inbound message frame conv=$it")
                onMessageRef?.invoke(it)
            }
            "typing" -> {
                val cid = obj["conversation_id"]?.jsonPrimitive?.contentOrNull ?: return
                val uid = obj["user_id"]?.jsonPrimitive?.contentOrNull ?: ""
                val state = obj["state"]?.jsonPrimitive?.contentOrNull
                onTyping?.invoke(cid, uid, state == "start")
            }
            "receipt" -> {
                val mid = obj["message_id"]?.jsonPrimitive?.contentOrNull ?: return
                val status = obj["status"]?.jsonPrimitive?.contentOrNull ?: return
                // Diagnostic: this is how the SENDER learns their message went Seen. If Android
                // sends a read receipt but the peer never gets this frame, the tick is stuck.
                android.util.Log.i("VOIIDWS", "receipt frame msg=$mid status=$status")
                onReceipt?.invoke(mid, status)
            }
            // Location fixes / stops (docs/LOCATION.md P3). Routed to the shared LocationRelay
            // seam so BOTH location engines (conversation share + Map) can consume them without
            // fighting over a single callback. `ciphertext` is copied to the relay verbatim and
            // never parsed here — the same "treat as opaque" rule as SDP.
            "loc_update" -> {
                val sid = obj["share_id"]?.jsonPrimitive?.contentOrNull ?: return
                val from = obj["from_user_id"]?.jsonPrimitive?.contentOrNull ?: return
                val ct = obj["ciphertext"]?.jsonPrimitive?.contentOrNull ?: return
                val ts = obj["ts"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: System.currentTimeMillis()
                LocationRelay.dispatchFix(sid, from, ct, ts)
            }
            "loc_stop" -> {
                val sid = obj["share_id"]?.jsonPrimitive?.contentOrNull ?: return
                val from = obj["from_user_id"]?.jsonPrimitive?.contentOrNull ?: return
                // Only the API stamps these; a stop relayed from another client has neither.
                val kind = obj["kind"]?.jsonPrimitive?.contentOrNull ?: ""
                val reason = obj["reason"]?.jsonPrimitive?.contentOrNull ?: ""
                LocationRelay.dispatchStop(sid, from, kind, reason)
            }
            // A story was posted to us, viewed, or deleted. All three mean the same thing to
            // this client — re-sync the feed — so they share one seam, exactly as iOS routes
            // all three to `.voiidStorySignal`.
            // Full authoritative state for one match. Routed to the GamesRelay seam so the
            // open game screen consumes it and any other surface can too, exactly as
            // loc_update routes through LocationRelay. Readable, not opaque — the server
            // referees games (docs/GAMES.md §2).
            "game_state" -> {
                val mid = obj["match_id"]?.jsonPrimitive?.contentOrNull ?: return
                val payload = obj["payload"] as? JsonObject ?: return
                val game = obj["game"]?.jsonPrimitive?.contentOrNull ?: ""
                val seq = obj["seq"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 0
                GamesRelay.dispatchState(mid, game, seq, payload)
            }
            // Ludo schema-v2 server-to-client frames (§7.2). Each routes to its own seam so
            // boards and chat invite cards consume exactly what they render.
            "game_command_rejected" -> {
                val mid = obj["match_id"]?.jsonPrimitive?.contentOrNull ?: return
                GamesRelay.dispatchRejected(
                    matchId = mid,
                    commandId = obj["commandId"]?.jsonPrimitive?.contentOrNull,
                    code = obj["code"]?.jsonPrimitive?.contentOrNull ?: "",
                    currentSeq = obj["current_seq"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 0,
                )
            }
            "game_presence" -> {
                val mid = obj["match_id"]?.jsonPrimitive?.contentOrNull ?: return
                GamesRelay.dispatchPresence(
                    matchId = mid,
                    seat = obj["seat"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: return,
                    connection = obj["connection"]?.jsonPrimitive?.contentOrNull ?: "disconnected",
                )
            }
            "game_invite_status" -> {
                val mid = obj["match_id"]?.jsonPrimitive?.contentOrNull ?: return
                GamesRelay.dispatchInviteStatus(
                    matchId = mid,
                    status = obj["status"]?.jsonPrimitive?.contentOrNull ?: "waiting",
                    acceptedSeats = obj["accepted_seats"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 0,
                    totalSeats = obj["total_seats"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 0,
                    expiresAt = obj["expires_at"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 0L,
                )
            }
            "game_ended" -> {
                val mid = obj["match_id"]?.jsonPrimitive?.contentOrNull ?: return
                GamesRelay.dispatchEnded(
                    matchId = mid,
                    winnerSeat = obj["winner_seat"]?.jsonPrimitive?.contentOrNull?.toIntOrNull(),
                    endReason = obj["end_reason"]?.jsonPrimitive?.contentOrNull,
                )
            }
            "story", "story_receipt", "story_deleted" -> onStorySignal?.invoke()
            "session_reset" -> obj["conversation_id"]?.jsonPrimitive?.contentOrNull?.let { onSessionReset?.invoke(it) }
            "mls_event" -> onMlsEvent?.invoke(obj["conversation_id"]?.jsonPrimitive?.contentOrNull)
            // Conference escalation (§3.2). Routed to their own seam — exactly as loc_* goes to
            // LocationRelay and game_state to GamesRelay — rather than widening [CallSignal],
            // so the 1:1 signaling struct keeps meaning "one peer-to-peer session" and the
            // conference engine can consume these without CallManager having to forward them.
            // `ciphertext` is copied to the relay seam verbatim and NEVER parsed or logged here.
            "call_invite", "call_invite_accept", "call_invite_decline", "call_migrate", "call_key" -> {
                val from = obj["from_user_id"]?.jsonPrimitive?.contentOrNull ?: return
                val callId = obj["call_id"]?.jsonPrimitive?.contentOrNull ?: return
                ConferenceRelay.dispatch(
                    type = t,
                    fromUserId = from,
                    callId = callId,
                    callKind = obj["call_kind"]?.jsonPrimitive?.contentOrNull,
                    room = obj["room"]?.jsonPrimitive?.contentOrNull,
                    deviceId = obj["device_id"]?.jsonPrimitive?.contentOrNull,
                    senderDeviceId = obj["sender_device_id"]?.jsonPrimitive?.contentOrNull
                        ?.takeIf { it.isNotBlank() },
                    ciphertextB64 = obj["ciphertext"]?.jsonPrimitive?.contentOrNull,
                )
            }
            // ANSWERED (or DECLINED) ON ANOTHER OF YOUR OWN DEVICES.
            //
            // Deliberately its own branch: this frame comes from the SERVER on your own
            // channel, not from a peer, so it carries no `from_user_id` — the shared branch
            // below would have dropped it on `?: return` even if it were listed there.
            //
            // Android was not handling it at all, and the consequence was severe: a sibling
            // device kept ringing after you answered elsewhere, hit its 45s ring cap, and
            // sent a hangup carrying the SAME call_id the live call is using — tearing down
            // an answered call mid-conversation, and filing a false "missed" row.
            "call_taken" -> {
                val callId = obj["call_id"]?.jsonPrimitive?.contentOrNull ?: return
                val reason = obj["reason"]?.jsonPrimitive?.contentOrNull ?: "answer"
                onCallTaken?.invoke(callId, reason)
            }
            "call_offer", "call_answer", "call_ice", "call_hangup", "call_decline", "call_busy",
            "call_ringing", "call_hold", "call_unhold",
            -> {
                val from = obj["from_user_id"]?.jsonPrimitive?.contentOrNull ?: return
                val callId = obj["call_id"]?.jsonPrimitive?.contentOrNull ?: return
                onCallSignal?.invoke(
                    CallSignal(
                        type = t,
                        fromUserId = from,
                        callId = callId,
                        callKind = obj["call_kind"]?.jsonPrimitive?.contentOrNull,
                        sdp = obj["sdp"]?.jsonPrimitive?.contentOrNull,
                        candidate = obj["candidate"] as? JsonObject,
                        conversationId = obj["conversation_id"]?.jsonPrimitive?.contentOrNull,
                    ),
                )
            }
            else -> Unit   // "connected" etc.
        }
    }
}
