package com.voiid.app.net

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.voiid.app.MainActivity
import com.voiid.app.R
import com.voiid.app.store.UserDirectory
import com.voiid.app.store.displayName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Receives the backend's content-free "wake" data push (Section 4.14) and turns it
 * into a real, on-device notification WITHOUT any plaintext ever leaving the phone.
 *
 * The push carries only routing metadata:
 *     data: { type: "wake", message_id, conversation_id }
 * On receipt we authenticate with the app's stored session, fetch the conversation's
 * new ciphertext and DECRYPT IT LOCALLY by reusing [ChatEngine.sync] (the exact same
 * fetch + `decryptInbound` path the foreground app uses), then post a notification
 * whose title is the sender and whose body is the decrypted preview. Nothing is
 * reimplemented and no content is ever sent off-device.
 *
 * If anything fails (not logged in, network, decrypt) we fall back to a generic
 * "New message" — we never crash and never leak.
 */
class VoiidMessagingService : FirebaseMessagingService() {

    // onNewToken can arrive while the app is backgrounded; a small IO scope handles it.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onNewToken(token: String) {
        // Persist + push the FCM token to the backend on this device's row. Safe before
        // login/bootstrap (cached and attached later by E2EManager.register()).
        scope.launch {
            runCatching { E2EManager.get(applicationContext).registerPushToken(token) }
                .onFailure { android.util.Log.e("VOIID", "onNewToken register failed", it) }
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data

        // Incoming 1:1 call: wake the incoming-call UI (full-screen ring). The matching
        // call_offer arrives over the WebSocket once the app/socket is live.
        if (data["type"] == "call") {
            val ctx = applicationContext
            // A signed-out device whose token the server has not cleared yet must not raise a
            // ring it cannot possibly answer — the accept path needs a JWT to bring the socket
            // up. The story branch below has always checked this; the call branches did not.
            if (!TokenStore.get(ctx).isAuthenticated) return
            val callId = data["call_id"] ?: return
            val callerId = data["caller_id"] ?: return
            val conversationId = data["conversation_id"]
            val kind = if (data["call_kind"] == "video") com.voiid.app.main.CallKind.VIDEO
            else com.voiid.app.main.CallKind.VOICE
            CallManager.init(ctx)
            // RING FIRST, NAME SECOND. The push deliberately carries no caller name (that would
            // tell Google who calls whom), and resolving one used to block here on the directory
            // load plus a 6-second network lookup — up to six seconds of a 45-second ring window
            // during which a cold-started callee saw and heard nothing at all. Ring with what the
            // local mirror can answer synchronously (never the raw caller id — see
            // [UserDirectory]) and refine it below. Signal-Android starts its service before any
            // fetch work for exactly this reason.
            UserDirectory.init(ctx)
            CallManager.onRingPush(callId, callerId, UserDirectory.displayName(callerId), kind, conversationId)
            scope.launch {
                UserDirectory.ready(ctx)
                val better = UserDirectory.user(callerId)?.displayName()
                    ?: withTimeoutOrNull(6_000L) {
                        conversationId?.let { runCatching { ChatService(ctx).resolvePeer(it).title }.getOrNull() }
                    }?.takeIf { it.isNotBlank() && it != callerId }
                CallManager.refinePeerName(callId, better)
            }
            return
        }

        // A group call started — post a "join" notification (a group call has no single callee,
        // so this is a tappable invite, not a full-screen 1:1 ring).
        if (data["type"] == "group_call") {
            val ctx = applicationContext
            if (!TokenStore.get(ctx).isAuthenticated) return
            val conversationId = data["conversation_id"] ?: return
            val video = data["call_kind"] == "video"
            // Same reasoning as the 1:1 branch: post immediately with no title (the notification
            // reads "Group call"), then re-post in place — same id, so it updates — once the
            // conversation name is known.
            Notifier.postGroupCallNotification(ctx, conversationId, null, video)
            scope.launch {
                UserDirectory.ready(ctx)
                val name = withTimeoutOrNull(6_000L) {
                    runCatching { ChatService(ctx).resolvePeer(conversationId).title }.getOrNull()
                }?.takeIf { it.isNotBlank() } ?: return@launch
                Notifier.postGroupCallNotification(ctx, conversationId, name, video)
            }
            return
        }

        // A story wake (`type: "story"`, story_id only — no content) was IGNORED here, so a
        // story arriving while the app was backgrounded/killed did not sync until the user
        // happened to open the Stories tab. Sync the feed so the tray is already correct when
        // they next look. No notification is posted: a story is ambient, and the tray's unread
        // dot is the surface for it (matching iOS, whose NSE does not draw one either).
        if (data["type"] == "story") {
            val ctx = applicationContext
            if (!TokenStore.get(ctx).isAuthenticated) return
            runBlocking {
                withTimeoutOrNull(20_000L) {
                    runCatching { StoryEngine.get(ctx).syncFeed() }
                        .onFailure { android.util.Log.w("VOIID", "story wake sync failed", it) }
                }
            }
            return
        }
        if (data["type"] != "wake") return
        val conversationId = data["conversation_id"] ?: return
        val messageId = data["message_id"]
        val ctx = applicationContext

        // onMessageReceived runs on an FCM background thread. Do the fetch+decrypt
        // synchronously (bounded) so the process stays alive until the notification is
        // posted; the work is quick (one authed GET + local ratchet decrypt).
        runBlocking {
            val outcome = withTimeoutOrNull(20_000L) {
                runCatching { fetchAndDecrypt(ctx, conversationId, messageId) }.getOrNull()
            }
            if (outcome != null) {
                // A protocol control message (map_key/map_off/live_*) is NOT a message: the
                // user never sent it and must never be told about it. Enabling Map visibility
                // fans a map_key out to the whole audience, and each one used to surface as a
                // "New message" for a message that does not exist. The wake still did its job
                // — the envelope was fetched and decrypted above — so there is simply nothing
                // left to post.
                if (!outcome.isControl) {
                    Notifier.postMessage(ctx, conversationId, messageId, outcome.title, outcome.body)
                }
            } else {
                // Not logged in? Then don't surface anything (avoid noise for a signed-out app).
                if (TokenStore.get(ctx).isAuthenticated) {
                    Notifier.postMessage(ctx, conversationId, messageId, title = null, body = null)
                }
            }
        }
    }

    /**
     * The bits we need to render a notification, all derived on-device.
     *
     * [isControl] distinguishes "this wake carried a silent protocol envelope, post nothing"
     * from "we fetched but couldn't decrypt, post the generic fallback". Both leave [body]
     * null, so without the flag a map_key was indistinguishable from a failed decrypt and
     * produced a phantom "New message".
     */
    private data class Preview(val title: String?, val body: String?, val isControl: Boolean = false)

    /**
     * Reuse the app's real receive path: ensure the E2E identity is ready, resolve the
     * peer (sender display name), then [ChatEngine.sync] to fetch + decrypt any new
     * messages. Returns the sender name + decrypted preview for the just-arrived message.
     */
    private suspend fun fetchAndDecrypt(ctx: Context, conversationId: String, messageId: String?): Preview {
        val tokens = TokenStore.get(ctx)
        if (!tokens.isAuthenticated) throw ApiError.NotAuthenticated

        val e2e = E2EManager.get(ctx)
        e2e.bootstrap()   // idempotent — guarantees identity is loaded for decrypt

        val chatService = ChatService(ctx)
        val engine = ChatEngine.get(ctx)
        val groupEngine = GroupEngine.get(ctx)

        // Always process MLS control events first — a wake may signify a Welcome (we were
        // added to a group) or a Commit, and a group we're not yet tracking must join.
        runCatching { groupEngine.syncGroupEvents() }

        // Snapshot before so we can identify what's NEW after the sync.
        val before = engine.messages(conversationId).map { it.id }.toHashSet()

        // Group conversation: decrypt pending MLS app messages into the shared store.
        val peer = if (groupEngine.hasGroup(conversationId)) {
            runCatching { groupEngine.receiveGroupMessages(conversationId) }
            null
        } else {
            val p = runCatching { chatService.resolvePeer(conversationId) }.getOrNull()
            p?.peerUserId?.let { engine.sync(conversationId, it) }
            p
        }

        // The sync above consumed the pushed message as a silent location-protocol control
        // envelope (map_key / map_off / live_*) — it deliberately never becomes a chat
        // message. Stop here: falling through would pick the newest UNRELATED inbound message
        // as `target` and re-notify about an old chat, or post the generic fallback for a
        // message the user never received. Enabling Map visibility fans one of these to every
        // person in the audience.
        if (messageId != null && engine.wasControlMessage(messageId)) {
            return Preview(title = null, body = null, isControl = true)
        }

        val after = engine.messages(conversationId)
        // Prefer the exact pushed message; else the newest new inbound; else newest inbound.
        val target = after.firstOrNull { it.id == messageId && !it.isMine }
            ?: after.lastOrNull { !it.isMine && it.id !in before }
            ?: after.lastOrNull { !it.isMine }

        // Same precedence as everywhere else: the address-book name wins over the name the
        // sender chose for themselves, so a notification says "Mum" too.
        val title = peer?.let { p ->
            p.peerUserId?.let { UserDirectory.displayName(it, fallback = p.title) }
                ?: p.title?.takeIf { it.isNotBlank() }
        }
        val body = when {
            target == null -> null                       // fetched but nothing to show → generic
            target.media != null -> "📎 Media" // 📎 Media (no caption/plaintext detail)
            target.failed -> null                        // couldn't decrypt → generic fallback
            else -> gameInviteBody(target.text) ?: target.text.take(140)
        }
        return Preview(title, body)
    }

    /**
     * Notification body for a game invite, or null if this isn't one.
     *
     * THIS IS WHY THE PUSH IS WORTH DECRYPTING. The wake push that reached this device carried no
     * content — the server never knew what it was for. We have just decrypted the envelope
     * locally, so we can name the game and its settings here, and the only string Google's
     * servers ever saw was "New message". Sending these details in the push payload instead would
     * have been simpler and would have leaked who invited whom to what.
     *
     * Without this the banner would show the raw `voiid:game/...` marker lines, which is how the
     * invite looked before: technically a notification, useless to a human.
     */
    private fun gameInviteBody(text: String): String? {
        val invite = GameInvite.parse(text) ?: return null
        val meta = invite.meta ?: return GameInvite.preview(text).take(140)
        if (meta.isExpired) return "Game invite expired"
        val details = meta.detailLine()
        val game = meta.game.ifBlank { "a game" }
        return if (details.isBlank()) "🎮 Invited you to $game"
               else "🎮 Invited you to $game · $details"
    }
}

/**
 * Builds + posts message notifications with a per-conversation [NotificationChannel],
 * grouped by conversation, deep-linking to the chat on tap. Kept as an object so the
 * service and any future foreground caller share one implementation.
 */
object Notifier {

    private fun channelId(conversationId: String) = "voiid_conv_$conversationId"

    /** Create (idempotent) the per-conversation channel. */
    private fun ensureChannel(ctx: Context, conversationId: String, title: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        val id = channelId(conversationId)
        if (nm.getNotificationChannel(id) != null) return
        val channel = NotificationChannel(
            id,
            title?.takeIf { it.isNotBlank() } ?: "Messages",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "New message notifications"
            enableVibration(true)
        }
        nm.createNotificationChannel(channel)
    }

    /**
     * Post a decrypted message notification. [title]/[body] null → generic fallback.
     * Never throws; silently no-ops if the runtime notification permission is missing.
     */
    fun postMessage(
        ctx: Context,
        conversationId: String,
        messageId: String?,
        title: String?,
        body: String?,
    ) {
        // Android 13+: posting without POST_NOTIFICATIONS is a silent no-op — guard it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            android.util.Log.w("VOIID", "notification permission not granted — skipping post")
            return
        }

        ensureChannel(ctx, conversationId, title)

        // Deep-link: tapping opens MainActivity and routes to this conversation.
        val intent = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(DeepLinkRouter.EXTRA_CONVERSATION_ID, conversationId)
        }
        val pi = PendingIntent.getActivity(
            ctx,
            conversationId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val shownTitle = title ?: "VOIID"
        val shownBody = body ?: "New message"

        val notification = NotificationCompat.Builder(ctx, channelId(conversationId))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(shownTitle)
            .setContentText(shownBody)
            .setStyle(NotificationCompat.BigTextStyle().bigText(shownBody))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setGroup(conversationId)   // stack multiple messages of one chat together
            .setContentIntent(pi)
            .build()

        // Stable per-message id so several messages in a chat stack instead of replacing.
        val notifId = (messageId ?: conversationId).hashCode()
        runCatching { NotificationManagerCompat.from(ctx).notify(notifId, notification) }
            .onFailure { android.util.Log.e("VOIID", "notify failed", it) }
    }

    /**
     * A tappable "join group call" notification. Tapping opens the app and joins the room.
     *
     * [name] is null on the first post, before the conversation title has resolved — passing
     * a placeholder instead would permanently name this conversation's notification channel
     * "Group call", since a channel's name is fixed at creation.
     */
    fun postGroupCallNotification(ctx: Context, conversationId: String, name: String?, video: Boolean) {
        ensureChannel(ctx, conversationId, name)
        val intent = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(DeepLinkRouter.EXTRA_GROUP_CALL_CONVERSATION, conversationId)
            putExtra(DeepLinkRouter.EXTRA_GROUP_CALL_KIND, if (video) "video" else "voice")
        }
        val pi = PendingIntent.getActivity(
            ctx, ("gc_$conversationId").hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(ctx, channelId(conversationId))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(name ?: "Group call")
            .setContentText(if (video) "Incoming group video call · tap to join" else "Incoming group call · tap to join")
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pi)
            .build()
        runCatching { NotificationManagerCompat.from(ctx).notify(groupCallNotificationId(conversationId), notification) }
            .onFailure { android.util.Log.e("VOIID", "group-call notify failed", it) }
    }

    /** One stable id per conversation, so a re-post updates in place and a cancel finds it. */
    fun groupCallNotificationId(conversationId: String): Int = ("gc_$conversationId").hashCode()

    /**
     * Clear the "join group call" notification for a conversation.
     *
     * `setAutoCancel(true)` only covers the case where the user TAPS the notification. Joining
     * the same call any other way — the in-chat "ongoing call" banner, the call button, or
     * another device — left it sitting in the shade inviting you to join a call you were
     * already on, and it stayed there after the call ended because nothing ever removed it.
     */
    fun cancelGroupCallNotification(ctx: Context, conversationId: String) {
        runCatching {
            NotificationManagerCompat.from(ctx).cancel(groupCallNotificationId(conversationId))
        }.onFailure { android.util.Log.e("VOIID", "group-call notify cancel failed", it) }
    }
}
