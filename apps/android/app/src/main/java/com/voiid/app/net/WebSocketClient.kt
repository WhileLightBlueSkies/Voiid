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

    /** New message arrived for a conversation -> the app should fetch + decrypt it. */
    var onMessageRef: ((conversationId: String) -> Unit)? = null
    /** Typing updates: conversationId, fromUserId, isTyping. */
    var onTyping: ((conversationId: String, userId: String, isTyping: Boolean) -> Unit)? = null
    /** Receipt for one of OUR sent messages: messageId, status ("delivered"|"read"). */
    var onReceipt: ((messageId: String, status: String) -> Unit)? = null

    fun connect() {
        if (connected) return
        val jwt = tokens.jwt ?: return
        closedByUs = false
        val url = ApiConfig.wsUrl.trimEnd('/') + "?token=" + jwt
        val req = Request.Builder().url(url).build()
        socket = client.newWebSocket(req, listener)
        connected = true
    }

    fun disconnect() {
        closedByUs = true
        socket?.close(1000, "client closing")
        socket = null
        connected = false
    }

    fun sendTyping(conversationId: String, recipientIds: List<String>, isStart: Boolean) {
        val recips = recipientIds.joinToString(",") { "\"" + it + "\"" }
        val frame = """{"type":"typing","conversation_id":"$conversationId","recipient_ids":[$recips],"state":"${if (isStart) "start" else "stop"}"}"""
        socket?.send(frame)
    }

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            scope.launch { handle(text) }
        }
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
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
        when ((obj["type"] as? JsonPrimitive)?.contentOrNull) {
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
            else -> Unit   // "connected" etc.
        }
    }
}
