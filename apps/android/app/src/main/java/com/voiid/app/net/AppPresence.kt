package com.voiid.app.net

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Where the user is RIGHT NOW, for the one decision that needs it: whether an arriving
 * message should raise a notification.
 *
 * ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────
 * `VoiidMessagingService` runs as a background service and cannot see Compose state, so it
 * had no way to know the app was open — let alone which chat was on screen. Every push
 * posted a banner, including for the conversation the user was actively reading. That is
 * the one case every messaging app suppresses, because a notification for a message already
 * visible on screen is noise the user cannot act on.
 *
 * ── WHY IT IS PLAIN STATICS AND NOT A LIFECYCLE OBSERVER ─────────────────────────
 * The reader is a service that may be woken with no Activity alive at all. Process-global
 * atomics answer correctly in that case (foreground=false, no open chat) without needing a
 * LifecycleOwner to exist, and they cost nothing to read on the notification path.
 *
 * Both values are set from the UI and only ever read here. They are advisory: a stale
 * `true` at worst suppresses one banner for a chat the user just left, which is a far
 * smaller failure than the reverse — buzzing someone about a message they are looking at.
 */
object AppPresence {

    private val foreground = AtomicBoolean(false)

    /** The conversation whose thread is on screen, or null. */
    private val openConversation = AtomicReference<String?>(null)

    fun isForeground(): Boolean = foreground.get()

    /**
     * Set when the app returns to or leaves the foreground, from MainActivity's
     * onStart/onStop.
     *
     * Returning to the foreground also drains queued read receipts. A receipt whose POST
     * failed is released and queued, but the only thing that re-sends one is markRead,
     * which is gated on the chat being OPEN — so a user who read a message, lost signal for
     * a moment and then left the chat had it dropped with nothing to retry it, and the
     * sender sat on Delivered until they happened to reopen that conversation. Coming back
     * to the foreground is when connectivity has typically returned, which is why iOS uses
     * the same trigger for the same job.
     */
    fun setForeground(value: Boolean) {
        val wasBackground = !foreground.get()
        foreground.set(value)
        if (value && wasBackground) {
            onForeground?.invoke()
        }
        // Leaving the app closes whatever chat was open. Without this, backgrounding while
        // inside a thread would leave the id set, and a push for that chat would be silently
        // dropped for as long as the app stayed backgrounded — the exact opposite of what
        // this class is for.
        if (!value) {
            openConversation.set(null)
            InAppMessageNotifications.clear()
        }
    }

    /**
     * Invoked on a background→foreground transition. Set once at startup by the code that
     * owns the retry (ChatEngine); kept as a callback rather than a direct call so this
     * object stays free of dependencies it would otherwise have to construct.
     */
    @Volatile var onForeground: (() -> Unit)? = null

    /** Called when a chat thread opens (id) or closes (null). */
    fun setOpenConversation(id: String?) {
        openConversation.set(id)
    }

    /**
     * True when a notification for [conversationId] would tell the user something they can
     * already see: the app is in front of them AND that exact thread is open.
     *
     * Deliberately narrow. An app in the foreground on the CHAT LIST still gets a banner —
     * the message is not on screen there, and the list only shows a preview once it syncs.
     */
    fun shouldSuppressNotification(conversationId: String?): Boolean =
        foreground.get() && conversationId != null && openConversation.get() == conversationId
}
