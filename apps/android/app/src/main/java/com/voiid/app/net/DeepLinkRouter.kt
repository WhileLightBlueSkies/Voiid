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

    /** Intent extra: the ringing call the user tapped Accept on. */
    const val EXTRA_ACCEPT_CALL_ID = "voiid.call.accept_id"
    /** Intent extra: the *waiting* call the user chose over the one in progress. */
    const val EXTRA_ACCEPT_WAITING_CALL_ID = "voiid.call.accept_waiting_id"

    /** Set when a notification asks the app to open a conversation; null once handled. */
    val pendingConversationId = MutableStateFlow<String?>(null)

    fun open(conversationId: String) { pendingConversationId.value = conversationId }
    fun consume() { pendingConversationId.value = null }

    /**
     * A call the user answered from the ring notification.
     *
     * Answering has to run from the Activity (Android 12 bans notification trampolines), but
     * NOT from `onCreate`: [com.voiid.app.net.CallManager.accept] starts a foreground service,
     * and Android only reliably permits that once the Activity is actually visible. So the tap
     * is parked here and the root composable performs it — the same pattern the conversation
     * deep link above uses, for a different reason.
     */
    data class CallAnswer(val callId: String, val waiting: Boolean)
    val pendingCallAnswer = MutableStateFlow<CallAnswer?>(null)
    fun answerCall(callId: String, waiting: Boolean = false) {
        pendingCallAnswer.value = CallAnswer(callId, waiting)
    }
    fun consumeCallAnswer() { pendingCallAnswer.value = null }

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
    data class GameInviteTap(val matchId: String, val slug: String)
    val pendingGameMatch = MutableStateFlow<GameInviteTap?>(null)
    /** [slug] rides along because it selects the board renderer, not just the match. */
    fun openGameMatch(matchId: String, slug: String) {
        pendingGameMatch.value = GameInviteTap(matchId, slug)
    }
    fun consumeGameMatch() { pendingGameMatch.value = null }

    /**
     * A community invite link the user tapped — `https://voiid.app/c/<handle>?i=<token>`,
     * arriving as an ACTION_VIEW Intent from the App Links filter in the manifest.
     *
     * The FIRST entry here that is not a notification bridge, so it is worth saying what it
     * parks and what it does not: only the parsed [CommunityLink], which is a handle and an
     * opaque token. It carries no card, no membership and no roster, because the client has
     * learned nothing yet — the sheet that observes this flow resolves the link against the
     * server and shows whatever the server says a link-holder may see. Anyone who was forwarded
     * the URL gets exactly the same answer, which is the property that keeps a link from
     * leaking who is in a community.
     *
     * It is held (not consumed on read) until the sheet has actually shown, because a cold
     * launch from a link on a fresh install lands on onboarding: the link must survive sign-in
     * rather than being thrown away at the moment there is nobody to resolve it for.
     */
    val pendingCommunityInvite = MutableStateFlow<CommunityLink?>(null)
    fun openCommunityInvite(link: CommunityLink) { pendingCommunityInvite.value = link }
    fun consumeCommunityInvite() { pendingCommunityInvite.value = null }
}
