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
    /** Intent extras for a "join group call" deep link (from a group_call push). */
    const val EXTRA_GROUP_CALL_CONVERSATION = "voiid.group_call.conversation_id"
    const val EXTRA_GROUP_CALL_KIND = "voiid.group_call.kind"

    /** Set when a notification asks the app to open a conversation; null once handled. */
    val pendingConversationId = MutableStateFlow<String?>(null)

    fun open(conversationId: String) { pendingConversationId.value = conversationId }
    fun consume() { pendingConversationId.value = null }

    /** A group call the user tapped to join (conversationId + "voice"/"video"); null once handled. */
    data class GroupCallInvite(val conversationId: String, val video: Boolean)
    val pendingGroupCall = MutableStateFlow<GroupCallInvite?>(null)
    fun joinGroupCall(conversationId: String, video: Boolean) {
        pendingGroupCall.value = GroupCallInvite(conversationId, video)
    }
    fun consumeGroupCall() { pendingGroupCall.value = null }

    /**
     * A game match the user tapped Join on, from an invite bubble in a chat.
     *
     * Routed here rather than through a callback threaded down to the bubble: the board is a
     * full-screen sibling owned by the root composable, so the bubble has no way to open it
     * directly, and every layer in between (list, bubble row, bubble inner) would otherwise
     * grow a parameter it does nothing with. The same reasoning as the group-call link above.
     */
    val pendingGameMatch = MutableStateFlow<String?>(null)
    fun openGameMatch(matchId: String) { pendingGameMatch.value = matchId }
    fun consumeGameMatch() { pendingGameMatch.value = null }
}
