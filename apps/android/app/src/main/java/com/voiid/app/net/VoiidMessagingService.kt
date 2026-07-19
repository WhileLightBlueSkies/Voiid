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
                Notifier.postMessage(ctx, conversationId, messageId, outcome.title, outcome.body)
            } else {
                // Not logged in? Then don't surface anything (avoid noise for a signed-out app).
                if (TokenStore.get(ctx).isAuthenticated) {
                    Notifier.postMessage(ctx, conversationId, messageId, title = null, body = null)
                }
            }
        }
    }

    /** The bits we need to render a notification, all derived on-device. */
    private data class Preview(val title: String?, val body: String?)

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

        val after = engine.messages(conversationId)
        // Prefer the exact pushed message; else the newest new inbound; else newest inbound.
        val target = after.firstOrNull { it.id == messageId && !it.isMine }
            ?: after.lastOrNull { !it.isMine && it.id !in before }
            ?: after.lastOrNull { !it.isMine }

        val title = peer?.title?.takeIf { it.isNotBlank() }
        val body = when {
            target == null -> null                       // fetched but nothing to show → generic
            target.media != null -> "📎 Media" // 📎 Media (no caption/plaintext detail)
            target.failed -> null                        // couldn't decrypt → generic fallback
            else -> target.text.take(140)
        }
        return Preview(title, body)
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
}
