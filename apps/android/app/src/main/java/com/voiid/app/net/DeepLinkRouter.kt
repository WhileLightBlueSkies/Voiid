package com.voiid.app.net

import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Process-global bridge for notification deep-links. A notification's content
 * PendingIntent launches [com.voiid.app.MainActivity] with a conversation id extra;
 * the Activity publishes it here and the root composable (MainScreen) observes it,
 * opens that conversation, then calls [consume].
 *
 * Mirrors the pattern used by [UpdateGate] — a tiny observable the single-Activity
 * Compose UI reacts to, without threading an Intent through the whole tree.
 */
object DeepLinkRouter {
    /** Intent extra carrying the conversation id to open. */
    const val EXTRA_CONVERSATION_ID = "voiid.conversation_id"

    /** Set when a notification asks the app to open a conversation; null once handled. */
    val pendingConversationId = MutableStateFlow<String?>(null)

    fun open(conversationId: String) { pendingConversationId.value = conversationId }

    fun consume() { pendingConversationId.value = null }
}
