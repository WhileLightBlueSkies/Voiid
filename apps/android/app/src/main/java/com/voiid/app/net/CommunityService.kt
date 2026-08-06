package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.Serializable

/**
 * Resolving and joining a community from an invite link. Mirrors iOS `CommunityService.swift`.
 *
 * RESOLUTION IS SERVER-SIDE, ON PURPOSE
 * -------------------------------------
 * The link ([CommunityLink]) carries a handle and an opaque capability token and nothing else.
 * Every fact shown on the join card — the name, the member count, whether the token is still
 * live, whether the caller is already in — is answered by the server, because those are the
 * only answers that can be trusted and because the alternative leaks. A client that decided
 * locally "this link works, so you're in" would be showing membership to anyone who was
 * forwarded the URL.
 *
 * WHAT THE SERVER MAY RETURN, AND WHAT IT MUST NOT
 * ------------------------------------------------
 * `GET /v1/communities/<handle>` returns the PUBLIC CARD — the same fields a stranger browsing
 * the directory sees. 030_communities.sql declares those fields (name, description, avatar,
 * member count) server-readable broadcast identity, the same argument 029_creator_profiles.sql
 * makes for creator pages. The ROSTER is not in the card and must never be added to it: the
 * whole point of the container not being a conversation is that outsiders can read the card,
 * and an outsider reading the roster would be a membership leak dressed up as a feature.
 *
 * Channel messages, the member↔host DM, calls, locations and moments are all still end-to-end
 * encrypted. Nothing on this path touches them.
 *
 * A JOIN GRANTS NO MESSAGING RIGHT. Joining puts the caller in the community's MLS channels;
 * it does not open a 1:1 with anyone. The single narrow exception is member→community OWNER
 * (`POST /communities/:id/host-thread`, 030_communities.sql), and it is not on this path.
 */
class CommunityService(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    /**
     * The public info card — the object the server nests under `community`, plus the two facts
     * the join sheet needs that arrive ALONGSIDE it rather than inside it.
     *
     * EVERY FIELD EXCEPT THE IDENTITY TRIO IS DEFAULTED. The shared Json has
     * `ignoreUnknownKeys = true`, so a server that adds fields is fine — but a server that has
     * not yet grown one of these (this client can ship ahead of the backend) would otherwise
     * throw on decode and turn a working link into "something went wrong".
     *
     * [membership_state] and [invite_valid] are NOT part of the nested `community` object on the
     * wire and will always decode as absent from it. They are folded in by [resolve], from the
     * envelope's sibling field and from a separate probe respectively, because that is where the
     * server puts them — deliberately: the card is a property of the community, whereas both of
     * these are properties of the CALLER holding this link.
     */
    @Serializable
    data class CommunityCard(
        val id: String,
        val handle: String,
        val name: String,
        val description: String? = null,
        /** Plaintext presigned R2 URL, like creator avatars (029). NOT the E2EE photo from 021. */
        val avatar_url: String? = null,
        val member_count: Int = 0,
        /** open | approval | invite_only — decides what the join button promises. */
        val join_policy: String = "open",
        /** Whether it appears in search. A link works regardless; that is what links are for. */
        val discoverable: Boolean = false,
        /** The host. Present so a card can offer "Message host" (3.18) without a roster query. */
        val owner_id: String? = null,
        /** Suspended communities still resolve so the card can say why joining is refused. */
        val suspended: Boolean = false,
        /**
         * THE ONLY SOURCE OF TRUTH FOR "AM I IN THIS". Null means not a member. Never infer
         * this from the fact that a link resolved; a forwarded link resolves for everyone.
         */
        val membership_state: String? = null,
        /**
         * Whether the token in the link is currently redeemable. Null when the link carried no
         * token.
         *
         * There is deliberately no accompanying reason code. The server answers revoked,
         * expired, used-up and never-existed with ONE identical 404, because a probe that
         * distinguishes them is an oracle for guessing tokens — and the user's next move is the
         * same in every case: ask the host for a new link.
         */
        val invite_valid: Boolean? = null,
    ) {
        val isMember: Boolean get() = membership_state == "active"
        val isPending: Boolean get() = membership_state == "pending"
        val isBanned: Boolean get() = membership_state == "banned"
    }

    /**
     * What both read endpoints actually return: the card, plus the caller's own relationship to
     * it as SIBLING fields. The nesting is the server's way of keeping the two apart — a card is
     * the same for everybody, a membership state is not.
     */
    @Serializable
    data class CommunityEnvelope(
        val community: CommunityCard,
        val membership_state: String? = null,
        val membership_role: String? = null,
    ) {
        fun merged(inviteValid: Boolean?): CommunityCard =
            community.copy(membership_state = membership_state, invite_valid = inviteValid)
    }

    /**
     * NO DEFAULT VALUE, deliberately.
     *
     * The shared Json is built with `encodeDefaults = false` (ApiClient.json), which silently
     * OMITS any property equal to its default — the bug class ChatEngine already documents and
     * that repair-plan item 3.24 generalises. Giving this `= null` would make it a defaulted
     * property; a null token would then be omitted (which is what we want) but the habit is the
     * problem, so the field simply has no default and every caller states the token or `null`.
     * With `explicitNulls = false` a null is dropped from the wire, which is exactly the
     * "no token presented" case.
     */
    @Serializable
    private data class JoinBody(val invite_token: String?)

    /**
     * `state` is what the caller's membership row landed on: 'active' or 'pending'.
     * `existed` is true when the caller was already in — pressing Join twice is idempotent
     * server-side, and the sheet should say "you're in", not "joined!" a second time.
     */
    @Serializable
    data class JoinResult(val state: String = "active", val existed: Boolean = false)

    /**
     * Resolve a link to the card the join sheet shows.
     *
     * TWO ENDPOINTS, because the server splits the two questions on purpose:
     *   GET /communities/<handle>          — what is this community (works for non-members)
     *   GET /communities/invites/<token>   — is this token live, WITHOUT redeeming it
     *
     * The invite probe is tried first when the link carries a token, because it answers both
     * questions in one round trip and because a resolve must never spend a use of a max_uses
     * link — a link preview or an accidental tap would otherwise burn it.
     *
     * A FAILED PROBE IS NOT A FAILED LINK. Falling back to the handle lookup is what lets an
     * open community still be joined from a poster whose printed token expired months ago: the
     * user is told the invite is dead and handed the Join button anyway, because the community's
     * own policy — not the link — is what decides who may join.
     *
     * THE HANDLE IN THE URL WINS. If the probe resolves a token minted for a DIFFERENT community
     * than the handle names, the token is treated as not applying here. Otherwise a link reading
     * `voiid.app/c/friendly_book_club?i=<token for something else>` would show one community's
     * name and enrol the user in another.
     *
     * The token is presented here and nowhere else. It is not persisted, not logged, and not
     * echoed back into the UI.
     */
    suspend fun resolve(link: CommunityLink): CommunityCard {
        val token = link.inviteToken
        if (token != null) {
            val probe = runCatching {
                api.requestAs<CommunityEnvelope>("GET", "communities/invites/$token")
            }.getOrNull()
            if (probe != null && probe.community.handle.equals(link.handle, ignoreCase = true)) {
                return probe.merged(inviteValid = true)
            }
            return byHandle(link.handle).merged(inviteValid = false)
        }
        return byHandle(link.handle).merged(inviteValid = null)
    }

    private suspend fun byHandle(handle: String): CommunityEnvelope =
        api.requestAs("GET", "communities/$handle")

    /**
     * Join. [communityId] comes from the resolved card, never from the URL — the link names a
     * handle, and handles can be released and re-registered, so redeeming against an id the
     * server just handed us is what keeps a stale poster from enrolling someone in whatever
     * community inherited the handle.
     *
     * Redemption itself is one conditional UPDATE server-side (030_communities.sql): a
     * select-then-update loses the race on the last use of a max_uses link and lets two people
     * spend it.
     */
    suspend fun join(communityId: String, inviteToken: String?): JoinResult {
        val body = ApiClient.json.encodeToString(JoinBody.serializer(), JoinBody(inviteToken))
        return api.requestAs("POST", "communities/$communityId/join", body)
    }
}
