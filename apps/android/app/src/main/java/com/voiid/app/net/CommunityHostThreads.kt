package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.Serializable

/**
 * The member → HOST private line. THE ONE SCOPED EXCEPTION TO 020_reachability.sql.
 *
 * WHAT THIS CLIENT IS ALLOWED TO ASK FOR, AND NOTHING ELSE
 * --------------------------------------------------------
 * 020_reachability.sql defines exactly three ways to open a conversation: mutual contacts,
 * a one-way contact (as a request), and @username + the 6-digit PIN (as a request). This adds
 * a fourth and it is member → COMMUNITY OWNER only.
 *
 * Joining a space is consent to be ASKED QUESTIONS BY ITS MEMBERS. It is not consent to be
 * messaged by every other member. A 5,000-member community must never become 5,000 mutual
 * messaging rights; that is a spam amplifier with a friendly name.
 *
 * MEMBER → MEMBER IS IMPOSSIBLE HERE, NOT MERELY UNIMPLEMENTED
 * ------------------------------------------------------------
 * Look at [open]. Its only argument is a COMMUNITY ID. There is no peer parameter, because the
 * peer is not a parameter: the server reads it from `communities.owner_id`, which
 * 030_communities.sql makes the single authority on who the host is precisely so this lookup
 * cannot return two rows or be pointed anywhere else. Adding a `targetUserId` to this class
 * would be the bug, and it would show up in the diff of this file as a new argument — which is
 * the point of keeping the surface this small.
 *
 * IF YOU EVER FIND CODE — HERE, IN A VIEW MODEL, OR ON THE SERVER — THAT READS COMMUNITY
 * MEMBERSHIP TO AUTHORISE A MESSAGE BETWEEN TWO ORDINARY MEMBERS, THAT IS A BUG. It is the same
 * rule 029_creator_profiles.sql states for follows: membership is a SOCIAL graph, and a social
 * graph quietly becoming a MESSAGING graph is the exact failure mode these gates exist to
 * prevent. Fix the caller. Do not widen this.
 *
 * ENCRYPTION: ZERO NEW CRYPTOGRAPHY
 * ---------------------------------
 * The thread the server hands back is an ordinary `type='direct'` conversation carried by the
 * Double Ratchet that [ChatEngine] already implements. Nothing on this path encrypts, decrypts
 * or transports a message; it only obtains the conversation id to send into. The server holds
 * opaque ciphertext here exactly as it does for every other 1:1.
 *
 * SERIALIZATION (repair-plan item 3.24)
 * -------------------------------------
 * Two rules, both learned the hard way in this repo:
 *
 *  * REQUEST BODIES: kotlinx omits any property equal to its default because ApiClient's Json
 *    leaves `encodeDefaults` off (see ReceiptEncodingTest, and ChatService.createSelfChat, which
 *    had to build its own Json to stop `{"type":"self"}` shipping as `{}`). This class dodges the
 *    hazard by having NO REQUEST BODY AT ALL — the server's POST handler documents that the body
 *    is ignored, since there is nothing a client is allowed to say about who the host is. If a
 *    body is ever added here, every defaulted field in it needs `@EncodeDefault`.
 *  * RESPONSE MODELS: every field below is nullable or defaulted, so a server that has not yet
 *    grown a field (this build can ship ahead of the backend, and did — see the mount note in
 *    routes/communityHostThreads.ts) decodes instead of throwing MissingFieldException. This is
 *    the Kotlin half of the same asymmetry that makes Swift's Codable throw `keyNotFound`.
 */
class CommunityHostThreads(context: Context) {
    private val app = context.applicationContext
    private val api = ApiClient(TokenStore.get(app))

    /**
     * The result of opening (or re-opening) a line to a host.
     *
     * `conversationId` is nullable ONLY to survive decoding a truncated response; a successful
     * call always carries one, and [open] throws rather than hand a caller a half-answer.
     *
     * `openedVia` is `"community"` for a thread created by this exception and NULL when the
     * server reused a 1:1 that already existed between these two people for ordinary reasons.
     * That distinction is deliberate and must be preserved in the UI: a personal chat that
     * happens to be with a host is not a host thread, and re-labelling it would move someone's
     * private conversation into a Community inbox section and lie about how it started.
     */
    @Serializable
    data class HostThread(
        val conversation_id: String? = null,
        val host_user_id: String? = null,
        /** False for a thread this call created, true when an existing one was handed back. */
        val existed: Boolean = false,
        val opened_via: String? = null,
    ) {
        val isCommunityThread: Boolean get() = opened_via == "community"
    }

    /**
     * One row of "my host threads, from both ends".
     *
     * IDS AND COMMUNITY CARD FIELDS ONLY. There is no last message, no preview and no member
     * name in here, because the messages are end-to-end encrypted and the server could not
     * describe them if it wanted to. Everything a chat row shows beyond the community badge
     * comes from the local decrypted store.
     */
    @Serializable
    data class HostThreadSummary(
        /** The join key against the chat list. Defaulted rather than required for the same
         *  forward-compatibility reason as the rest; callers drop rows with a blank id. */
        val conversation_id: String = "",
        val community_id: String? = null,
        val community_handle: String? = null,
        val community_name: String? = null,
        val community_avatar_r2_key: String? = null,
        /** "host" when the caller owns the community, "member" when they opened the thread. */
        val role: String? = null,
        val member_user_id: String? = null,
        val created_at: String? = null,
    ) {
        val amHost: Boolean get() = role == "host"
    }

    @Serializable
    private data class ThreadsEnvelope(val threads: List<HostThreadSummary> = emptyList())

    /**
     * Open the caller's private line to this community's host, or return the existing one.
     *
     * IDEMPOTENT, and safe to call from the button handler every time: the server reuses the
     * recorded thread when one exists and only throttles CREATIONS, so re-entering a
     * conversation you already have is free forever (a rate limit that locked you out of your
     * own chat would be a self-inflicted outage, not a defence).
     *
     * Refuses with 403 when the caller is not an ACTIVE member — pending applicants included,
     * because letting an applicant message the owner would make an approval queue a formality.
     * The 403 body is deliberately the same for "never joined", "pending", "left" and "banned":
     * the server will not act as an oracle for moderation state, so do not try to infer one.
     */
    suspend fun open(communityId: String): HostThread {
        val res: HostThread = api.requestAs("POST", "communities/$communityId/host-thread")
        if (res.conversation_id.isNullOrEmpty() || res.host_user_id.isNullOrEmpty()) {
            throw ApiError.Http(502, "The server did not return a host conversation.")
        }
        return res
    }

    /**
     * Does a line to this host already exist? Answers the info card's "Message host" vs
     * "Open chat" without creating anything.
     *
     * This is a GET on purpose. A card that minted a conversation just by being LOOKED AT would
     * make every impression an act of contact — and would hand the host a chat list full of
     * people who only ever browsed. `conversation_id == null` is the normal state, not an error.
     */
    suspend fun existing(communityId: String): HostThread =
        api.requestAs("GET", "communities/$communityId/host-thread")

    /**
     * Every host thread the caller is on, from BOTH ends — the ones they opened as a member and
     * the ones opened with them as the host.
     *
     * This is what lets the chat list group these into a Community section: `GET /conversations`
     * does not return `opened_via`, so the grouping is keyed on conversation_id, which a chat row
     * already has. Build a map once per list load rather than calling per row.
     */
    suspend fun all(): List<HostThreadSummary> =
        api.requestAs<ThreadsEnvelope>("GET", "community-host-threads")
            .threads.filter { it.conversation_id.isNotEmpty() }

    /**
     * "Ask host about this" — send a question about an announcement into the host thread.
     *
     * THE ENVELOPE IS THE EXISTING `msg_reply`. Nothing new is defined, nothing new has to be
     * added to the receiver's discriminator probe, and old builds already render it: a quoted
     * text message is a shape both platforms have shipped since the message-actions work.
     *
     * WHY THE QUOTE STILL MAKES SENSE ACROSS TWO CONVERSATIONS. [quotedServerId] is the SERVER
     * message id of the announcement, which lives in the community's announcement channel — a
     * different conversation from the host thread this send lands in. That resolves for the host
     * because both people are members of the announcement channel, and it renders even when the
     * original is gone, because [quotedPreview] travels inside the envelope. The preview is a
     * snippet of the DECRYPTED announcement taken from the local store; the server never sees it
     * in the clear, in this send or in the original.
     *
     * @param quotedPreview a short snippet of the announcement, already decrypted locally.
     * @param quotedSender display name to attribute the quote to.
     * @return the conversation id the question was sent into, so the caller can navigate to it.
     */
    suspend fun askHost(
        communityId: String,
        text: String,
        quotedServerId: String,
        quotedPreview: String,
        quotedSender: String,
    ): String {
        val thread = open(communityId)
        val conversationId = thread.conversation_id!!
        val hostId = thread.host_user_id!!
        ChatEngine.get(app).sendReply(
            text = text,
            quotedId = quotedServerId,
            quotedPreview = quotedPreview,
            quotedSender = quotedSender,
            conversationId = conversationId,
            peerUserId = hostId,
        )
        return conversationId
    }
}
