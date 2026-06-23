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
    }

    private val tokens = TokenStore.get(context)
    private val client = OkHttpClient.Builder()
        .pingInterval(30, TimeUnit.SECONDS)   // OkHttp-level keepalive
        .build()
    private val scope = CoroutineScope(Dispatchers.Main)

    private var socket: WebSocket? = null
    @Volatile private var connected = false
    @Volatile private var closedByUs = false
    private var heartbeatJob: kotlinx.coroutines.Job? = null

    /** New message arrived for a conversation -> the app should fetch + decrypt it. */
    var onMessageRef: ((conversationId: String) -> Unit)? = null
    /** Typing updates: conversationId, fromUserId, isTyping. */
    var onTyping: ((conversationId: String, userId: String, isTyping: Boolean) -> Unit)? = null
    /** Receipt for one of OUR sent messages: messageId, status ("delivered"|"read"). */
    var onReceipt: ((messageId: String, status: String) -> Unit)? = null
    /** Peer couldn't decrypt our message → reset (re-establish) the session for this conversation. */
    var onSessionReset: ((conversationId: String) -> Unit)? = null

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
        socket?.close(1000, "client closing")
        socket = null
        connected = false
    }

    /** App-level heartbeat the BACKEND understands (keeps `online` fresh + updates
     *  last_seen). OkHttp's pingInterval is only a protocol PING the server ignores. */
    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (true) {
                kotlinx.coroutines.delay(25_000)
                socket?.send("""{"type":"heartbeat"}""")
            }
        }
    }

    fun sendTyping(conversationId: String, recipientIds: List<String>, isStart: Boolean) {
        val recips = recipientIds.joinToString(",") { "\"" + it + "\"" }
        val frame = """{"type":"typing","conversation_id":"$conversationId","recipient_ids":[$recips],"state":"${if (isStart) "start" else "stop"}"}"""
        socket?.send(frame)
    }

    /** Ask the message's sender to re-establish the E2E session (we couldn't decrypt). */
    fun sendSessionReset(conversationId: String, recipientIds: List<String>) {
        val recips = recipientIds.joinToString(",") { "\"" + it + "\"" }
        socket?.send("""{"type":"session_reset","conversation_id":"$conversationId","recipient_ids":[$recips]}""")
    }

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            scope.launch { handle(text) }
        }
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            android.util.Log.w("VOIID", "WS disconnected: ${t.message} — reconnecting")
            connected = false
            if (!closedByUs) scope.launch { delay(2000); connect() }
        }
        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            connected = false
            if (!closedByUs) scope.launch { delay(2000); connect() }
        }
    }

    private fun handle(text: String) {
        val obj: JsonObject = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        val t = (obj["type"] as? JsonPrimitive)?.contentOrNull
        android.util.Log.i("VOIID", "WS recv type=$t")
        when (t) {
            "message" -> obj["conversation_id"]?.jsonPrimitive?.contentOrNull?.let { onMessageRef?.invoke(it) }
            "typing" -> {
                val cid = obj["conversation_id"]?.jsonPrimitive?.contentOrNull ?: return
                val uid = obj["user_id"]?.jsonPrimitive?.contentOrNull ?: ""
                val state = obj["state"]?.jsonPrimitive?.contentOrNull
                onTyping?.invoke(cid, uid, state == "start")
            }
            "receipt" -> {
                val mid = obj["message_id"]?.jsonPrimitive?.contentOrNull ?: return
                val status = obj["status"]?.jsonPrimitive?.contentOrNull ?: return
                onReceipt?.invoke(mid, status)
            }
            "session_reset" -> obj["conversation_id"]?.jsonPrimitive?.contentOrNull?.let { onSessionReset?.invoke(it) }
            else -> Unit   // "connected" etc.
        }
    }
}
