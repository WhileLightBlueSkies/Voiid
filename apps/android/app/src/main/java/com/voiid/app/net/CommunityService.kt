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
     * The public info card.
     *
     * EVERY FIELD EXCEPT THE IDENTITY TRIO IS DEFAULTED. The shared Json has
     * `ignoreUnknownKeys = true`, so a server that adds fields is fine — but a server that has
     * not yet grown one of these (this client can ship ahead of the backend) would otherwise
     * throw on decode and turn a working link into "something went wrong".
     */
    @Serializable
    data class CommunityCard(
        val id: String,
        val handle: String,
        val name: String,
        val description: String? = null,
        /** Plaintext R2 URL, like creator avatars (029). NOT the E2EE profile photo from 021. */
        val avatar_url: String? = null,
        val member_count: Int = 0,
        /** open | approval | invite_only — decides what the join button promises. */
        val join_policy: String = "open",
        /**
         * THE ONLY SOURCE OF TRUTH FOR "AM I IN THIS". Null means not a member. Never infer
         * this from the fact that a link resolved; a forwarded link resolves for everyone.
         */
        val membership_state: String? = null,
        /**
         * Whether the token in the link is currently redeemable. Null when the link carried no
         * token. False for revoked / expired / exhausted, with [invite_error] explaining which
         * — the user needs to know whether to ask for a new link or to give up.
         */
        val invite_valid: Boolean? = null,
        val invite_error: String? = null,
        /** Suspended communities still resolve so the card can say why joining is refused. */
        val suspended: Boolean = false,
    ) {
        val isMember: Boolean get() = membership_state == "active"
        val isPending: Boolean get() = membership_state == "pending"
        val isBanned: Boolean get() = membership_state == "banned"
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

    /** `state` is what the caller's membership row landed on: 'active' or 'pending'. */
    @Serializable
    data class JoinResult(val state: String = "active")

    /**
     * Resolve a link to its card. The token rides as a query parameter so the server can report
     * whether it is live — a non-discoverable or invite_only community is otherwise invisible,
     * and the person holding the link would be told "no such community" for one that exists.
     *
     * The token is presented here and nowhere else. It is not persisted, not logged, and not
     * echoed back into the UI.
     */
    suspend fun resolve(link: CommunityLink): CommunityCard {
        val query = link.inviteToken
            ?.let { "?" + CommunityLink.QUERY_TOKEN + "=" + android.net.Uri.encode(it) }
            ?: ""
        return api.requestAs("GET", "communities/${link.handle}$query")
    }

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
