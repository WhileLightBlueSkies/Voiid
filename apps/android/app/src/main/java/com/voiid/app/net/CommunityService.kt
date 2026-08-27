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
    @Serializable
    data class CommunityListEnvelope(val communities: List<CommunityCard> = emptyList())

    /** Communities this account belongs to — the tab's own list. */
    suspend fun mine(): List<CommunityCard> =
        api.requestAs<CommunityListEnvelope>("GET", "communities/mine").communities

    /**
     * Discovery. The server refuses a query under two characters rather than returning the
     * whole directory, so a short term short-circuits here instead of round-tripping.
     */
    suspend fun search(term: String): List<CommunityCard> {
        val q = term.trim()
        if (q.length < 2) return emptyList()
        return api.requestAs<CommunityListEnvelope>(
            "GET", "communities/search?q=" + java.net.URLEncoder.encode(q, "UTF-8")
        ).communities
    }

    data class RuleInput(val title: String, val detail: String?)

    /**
     * Create one. `handle` shares a single namespace with usernames and creator handles
     * (029/030), so the server may refuse it as taken — surfaced rather than pre-checked,
     * because only the database can settle that race.
     * Everything the five-step wizard collects (046) is optional past handle/name, mirroring
     * iOS: a community created without rules or extra Spaces is a real community.
     */
    suspend fun create(
        handle: String,
        name: String,
        description: String?,
        joinPolicy: String = "open",
        discoverable: Boolean = true,
        category: String? = null,
        membersCanInvite: Boolean = true,
        extraChannels: List<String> = emptyList(),
        rules: List<RuleInput> = emptyList(),
    ): CommunityCard {
        // Client-supplied id makes a retry idempotent, the same reasoning as clips.
        @Serializable
        data class RuleBody(val title: String, val detail: String?)
        @Serializable
        data class Body(
            val id: String,
            val handle: String,
            val name: String,
            val description: String?,
            val join_policy: String = "open",
            val discoverable: Boolean = true,
            val category: String? = null,
            val members_can_invite: Boolean = true,
            val extra_channels: List<String> = emptyList(),
            val rules: List<RuleBody> = emptyList(),
        )
        // encodeDefaults matters here: the optional fields carry DEFAULTS the server must see
        // (its own schema defaults differ), so an omitted-default would silently diverge from
        // the iOS payload.
        val body = ApiClient.json.encodeToString(
            Body.serializer(),
            Body(
                id = java.util.UUID.randomUUID().toString(),
                handle = handle, name = name, description = description,
                join_policy = joinPolicy, discoverable = discoverable,
                category = category, members_can_invite = membersCanInvite,
                extra_channels = extraChannels,
                rules = rules.map { RuleBody(it.title, it.detail) },
            ),
        )
        return api.requestAs<CommunityEnvelope>("POST", "communities", jsonBody = body).community
    }

    suspend fun join(communityId: String, inviteToken: String?): JoinResult {
        val body = ApiClient.json.encodeToString(JoinBody.serializer(), JoinBody(inviteToken))
        return api.requestAs("POST", "communities/$communityId/join", body)
    }

    /** One Space (channel) of the community. */
    @Serializable
    data class Channel(
        val conversation_id: String,
        val kind: String? = null,
        val position: Int? = null,
        val name: String? = null,
    ) {
        /** Announcement channels are host-writes-everyone-reads; chat is everyone. */
        val isAnnouncement: Boolean get() = kind == "announcement"
    }

    suspend fun channels(communityId: String): List<Channel> {
        @Serializable
        data class Envelope(val channels: List<Channel> = emptyList())
        return api.requestAs<Envelope>("GET", "communities/$communityId/channels").channels
    }

    /**
     * One row of the roster. NO display name and no avatar: the server returns ids, and
     * resolving them is UserDirectory's job.
     */
    @Serializable
    data class Member(
        val user_id: String,
        val role: String? = null,
        val state: String? = null,
        val joined_at: String? = null,
    ) {
        val isOwner: Boolean get() = role == "owner"
        val isAdmin: Boolean get() = role == "admin" || role == "owner"
    }

    /** `state` filters the roster. Anything but `active` is manager-only server-side. */
    suspend fun members(communityId: String, state: String = "active"): List<Member> {
        @Serializable
        data class Envelope(val members: List<Member> = emptyList())
        return api.requestAs<Envelope>("GET", "communities/$communityId/members?state=$state").members
    }

    // ══════════════════════════════════════════════════════════════════════════════
    //  THE HOME TAB: posts, the pinned announcement, About links
    //
    //  Ported from iOS `CommunityService.swift`. Every type below mirrors the Swift one
    //  FIELD FOR FIELD and keeps its optionality: the server may omit anything but `id`,
    //  and with `ignoreUnknownKeys = true` a client that ships ahead of the backend must
    //  not throw on a missing column. The computed helpers (`text`, `likes`, `displayName`)
    //  exist so the UI never writes `?: 0` at the call site.
    // ══════════════════════════════════════════════════════════════════════════════

    @Serializable
    data class Post(
        val id: String,
        val author_id: String? = null,
        val author_name: String? = null,
        val author_username: String? = null,
        val author_photo_url: String? = null,
        val body: String? = null,
        val media_url: String? = null,
        val like_count: Int? = null,
        val comment_count: Int? = null,
        val liked_by_me: Boolean? = null,
        val created_at: String? = null,
        val edited_at: String? = null,
    ) {
        val text: String get() = body ?: ""
        val likes: Int get() = like_count ?: 0
        val comments: Int get() = comment_count ?: 0
        val isLiked: Boolean get() = liked_by_me ?: false
        /**
         * A deleted author is a NORMAL row (047 sets author_id null on delete), so this
         * never renders an empty byline. Falls back name → @username → "Deleted account".
         */
        val displayName: String get() = when {
            !author_name.isNullOrEmpty() -> author_name
            !author_username.isNullOrEmpty() -> "@$author_username"
            else -> "Deleted account"
        }
    }

    @Serializable
    data class PostPage(
        val posts: List<Post> = emptyList(),
        val next_cursor: String? = null,
    )

    /** One page of the feed. `cursor` null loads the first page. */
    suspend fun posts(communityId: String, cursor: String? = null, limit: Int = 20): PostPage {
        val q = StringBuilder("communities/$communityId/posts?limit=$limit")
        if (!cursor.isNullOrEmpty()) q.append("&cursor=").append(cursor)
        return api.requestAs("GET", q.toString())
    }

    @Serializable
    private data class CreatePostBody(val body: String, val media_url: String?)

    suspend fun createPost(communityId: String, body: String, mediaUrl: String? = null): Post {
        val payload = ApiClient.json.encodeToString(
            CreatePostBody.serializer(), CreatePostBody(body, mediaUrl))
        return api.requestAs("POST", "communities/$communityId/posts", payload)
    }

    suspend fun deletePost(communityId: String, postId: String): Boolean {
        api.request("DELETE", "communities/$communityId/posts/$postId")
        return true
    }

    /**
     * The server returns the AUTHORITATIVE like count, not a delta. The UI applies an
     * optimistic bump for responsiveness and then overwrites it with this — otherwise two
     * devices liking at once drift apart and never reconcile.
     */
    @Serializable
    data class LikeResult(val like_count: Int? = null, val liked: Boolean? = null) {
        val count: Int get() = like_count ?: 0
    }

    suspend fun likePost(communityId: String, postId: String): LikeResult =
        api.requestAs("POST", "communities/$communityId/posts/$postId/like")

    suspend fun unlikePost(communityId: String, postId: String): LikeResult =
        api.requestAs("DELETE", "communities/$communityId/posts/$postId/like")

    @Serializable
    data class Announcement(
        val id: String,
        val author_id: String? = null,
        val author_name: String? = null,
        val author_username: String? = null,
        val author_photo_url: String? = null,
        val title: String? = null,
        val body: String? = null,
        val pinned_at: String? = null,
        val created_at: String? = null,
    ) {
        val headline: String get() = title ?: ""
        val text: String get() = body ?: ""
        val displayName: String get() = when {
            !author_name.isNullOrEmpty() -> author_name
            !author_username.isNullOrEmpty() -> "@$author_username"
            else -> "Deleted account"
        }
    }

    /**
     * At most ONE announcement is pinned at a time. The route returns a list; taking the
     * first is the contract, not a shortcut — pinning a second unpins the first server-side.
     */
    suspend fun announcement(communityId: String): Announcement? {
        @Serializable
        data class Envelope(val announcements: List<Announcement> = emptyList())
        return api.requestAs<Envelope>("GET", "communities/$communityId/announcements")
            .announcements.firstOrNull()
    }

    @Serializable
    private data class AnnouncementBody(val title: String, val body: String)

    suspend fun pinAnnouncement(communityId: String, title: String, body: String): Announcement {
        val payload = ApiClient.json.encodeToString(
            AnnouncementBody.serializer(), AnnouncementBody(title, body))
        return api.requestAs("POST", "communities/$communityId/announcements", payload)
    }

    suspend fun unpinAnnouncement(communityId: String, announcementId: String): Boolean {
        api.request("DELETE", "communities/$communityId/announcements/$announcementId")
        return true
    }

    /**
     * A link on the About tab. `value` is FREE TEXT, not a URL — a contact address and a
     * "read the handbook" label both live there — so the UI must not assume it is openable.
     * `icon` is a client-chosen symbol name; Android maps it in `CommunityIcons`.
     */
    @Serializable
    data class AboutLink(
        val id: String,
        val label: String? = null,
        val value: String? = null,
        val icon: String? = null,
        val position: Int? = null,
    ) {
        val title: String get() = label ?: ""
        val subtitle: String get() = value ?: ""
    }

    suspend fun links(communityId: String): List<AboutLink> {
        @Serializable
        data class Envelope(val links: List<AboutLink> = emptyList())
        return api.requestAs<Envelope>("GET", "communities/$communityId/links").links
    }

    @Serializable
    private data class LinkBody(val label: String, val value: String, val icon: String?)

    suspend fun createLink(
        communityId: String, label: String, value: String, icon: String? = null,
    ): AboutLink {
        val payload = ApiClient.json.encodeToString(
            LinkBody.serializer(), LinkBody(label, value, icon))
        return api.requestAs("POST", "communities/$communityId/links", payload)
    }

    suspend fun deleteLink(communityId: String, linkId: String): Boolean {
        api.request("DELETE", "communities/$communityId/links/$linkId")
        return true
    }

    // ══════════════════════════════════════════════════════════════════════════════
    //  RULES — 046 has the table; the routes are live (GET/POST/PATCH/DELETE).
    // ══════════════════════════════════════════════════════════════════════════════

    @Serializable
    data class Rule(
        val id: String,
        val title: String? = null,
        val detail: String? = null,
        val position: Int? = null,
    ) {
        val text: String get() = title ?: ""
        val explanation: String get() = detail ?: ""
        val order: Int get() = position ?: 0
    }

    suspend fun rules(communityId: String): List<Rule> {
        @Serializable
        data class Envelope(val rules: List<Rule> = emptyList())
        return api.requestAs<Envelope>("GET", "communities/$communityId/rules")
            .rules.sortedBy { it.order }
    }

    @Serializable
    private data class RuleBody(val title: String, val detail: String?, val position: Int?)

    suspend fun createRule(
        communityId: String, title: String, detail: String?, position: Int? = null,
    ): Rule {
        val payload = ApiClient.json.encodeToString(
            RuleBody.serializer(), RuleBody(title, detail, position))
        return api.requestAs("POST", "communities/$communityId/rules", payload)
    }

    suspend fun updateRule(
        communityId: String, ruleId: String,
        title: String?, detail: String?, position: Int? = null,
    ): Rule {
        val payload = ApiClient.json.encodeToString(
            RuleBody.serializer(), RuleBody(title ?: "", detail, position))
        return api.requestAs("PATCH", "communities/$communityId/rules/$ruleId", payload)
    }

    suspend fun deleteRule(communityId: String, ruleId: String): Boolean {
        api.request("DELETE", "communities/$communityId/rules/$ruleId")
        return true
    }

    // ══════════════════════════════════════════════════════════════════════════════
    //  HOST TOOLS — stats, the moderation queue, roster actions, leaving
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * THERE IS NO "ACTIVE TODAY" FIELD, and that is deliberate rather than an omission to
     * fill in later: nothing in the schema records a per-user last-seen, so the number is
     * not computable, and every way of faking it looks precise and is wrong. The server
     * omits the key; do not add one here.
     */
    @Serializable
    data class Stats(
        val members: Int? = null,
        val posts: Int? = null,
        val pending_members: Int? = null,
        val reported_posts: Int? = null,
        val open_reports: Int? = null,
    ) {
        val memberCount: Int get() = members ?: 0
        val postCount: Int get() = posts ?: 0
        val pendingCount: Int get() = pending_members ?: 0
        val reportedCount: Int get() = reported_posts ?: 0
        val openReports: Int get() = open_reports ?: 0
    }

    suspend fun stats(communityId: String): Stats =
        api.requestAs("GET", "communities/$communityId/stats")

    /**
     * `kind` is FREE TEXT on the wire, not an enum, so an unknown future kind decodes
     * instead of failing the whole page. [resolvedKind] is where it becomes a case, and an
     * unrecognised one is DROPPED by the caller rather than drawn as something it is not.
     */
    @Serializable
    data class QueueItem(
        val id: String,
        val kind: String? = null,
        val user_id: String? = null,
        val post_id: String? = null,
        val subject: String? = null,
        val username: String? = null,
        val detail: String? = null,
        val reporter_count: Int? = null,
        val reason: String? = null,
        val at: String? = null,
    ) {
        enum class Kind(val wire: String) { JOIN_REQUEST("join_request"), REPORTED_POST("reported_post") }

        val resolvedKind: Kind? get() = Kind.entries.firstOrNull { it.wire == kind }
        val name: String get() = subject ?: "Someone"
    }

    suspend fun moderationQueue(communityId: String): List<QueueItem> {
        @Serializable
        data class Envelope(val items: List<QueueItem> = emptyList())
        return api.requestAs<Envelope>("GET", "communities/$communityId/moderation-queue").items
    }

    suspend fun approveMember(communityId: String, userId: String) {
        api.request("POST", "communities/$communityId/members/$userId/approve")
    }

    suspend fun removeMember(communityId: String, userId: String) {
        api.request("POST", "communities/$communityId/members/$userId/remove")
    }

    suspend fun banMember(communityId: String, userId: String) {
        api.request("POST", "communities/$communityId/members/$userId/ban")
    }

    suspend fun unbanMember(communityId: String, userId: String) {
        api.request("POST", "communities/$communityId/members/$userId/unban")
    }

    @Serializable
    private data class RoleBody(val role: String)

    /** `role` is "admin" or "member". Only an owner may call this. */
    suspend fun setRole(communityId: String, userId: String, role: String) {
        val payload = ApiClient.json.encodeToString(RoleBody.serializer(), RoleBody(role))
        api.request("POST", "communities/$communityId/members/$userId/role", payload)
    }

    suspend fun leave(communityId: String): Boolean {
        api.request("POST", "communities/$communityId/leave")
        return true
    }

    // ══════════════════════════════════════════════════════════════════════════════
    //  SETTINGS — PATCH /:id
    //
    //  PARTIAL UPDATE, AND WHY IT IS HAND-BUILT.
    //  ApiClient.json sets `explicitNulls = false`, so a null property is DROPPED from the
    //  wire rather than sent as JSON null. A settings body built from one data class with
    //  five nullable fields would therefore omit whatever the host did not touch — which is
    //  what a PATCH wants — but it gives no way to distinguish "leave this alone" from
    //  "clear this", and it would send `{}` for a no-op save. So the body is assembled key
    //  by key and only the keys the caller actually passed are written. Mirrors the iOS
    //  `PartialBody` encoder, which exists for the same reason.
    // ══════════════════════════════════════════════════════════════════════════════

    suspend fun update(
        communityId: String,
        name: String? = null,
        description: String? = null,
        joinPolicy: String? = null,
        discoverable: Boolean? = null,
        avatarUrl: String? = null,
    ): CommunityCard {
        val fields = mutableMapOf<String, kotlinx.serialization.json.JsonElement>()
        fun put(k: String, v: String?) {
            if (v != null) fields[k] = kotlinx.serialization.json.JsonPrimitive(v)
        }
        put("name", name)
        put("description", description)
        put("join_policy", joinPolicy)
        put("avatar_url", avatarUrl)
        if (discoverable != null) {
            fields["discoverable"] = kotlinx.serialization.json.JsonPrimitive(discoverable)
        }
        val payload = kotlinx.serialization.json.JsonObject(fields).toString()
        val env: CommunityEnvelope = api.requestAs("PATCH", "communities/$communityId", payload)
        return env.merged(null)
    }

    // ══════════════════════════════════════════════════════════════════════════════
    //  SPACES (channels) — create, rename, delete
    // ══════════════════════════════════════════════════════════════════════════════

    @Serializable
    private data class ChannelBody(val name: String, val kind: String?)

    suspend fun createChannel(communityId: String, name: String, kind: String? = null): Channel {
        val payload = ApiClient.json.encodeToString(
            ChannelBody.serializer(), ChannelBody(name, kind))
        return api.requestAs("POST", "communities/$communityId/channels", payload)
    }

    suspend fun renameChannel(communityId: String, conversationId: String, name: String): Channel {
        val payload = ApiClient.json.encodeToString(
            ChannelBody.serializer(), ChannelBody(name, null))
        return api.requestAs("PATCH", "communities/$communityId/channels/$conversationId", payload)
    }

    suspend fun deleteChannel(communityId: String, conversationId: String): Boolean {
        api.request("DELETE", "communities/$communityId/channels/$conversationId")
        return true
    }

    // ══════════════════════════════════════════════════════════════════════════════
    //  INVITES
    // ══════════════════════════════════════════════════════════════════════════════

    @Serializable
    data class Invite(
        val token: String,
        val uses: Int? = null,
        val max_uses: Int? = null,
        val expires_at: String? = null,
        val created_at: String? = null,
    )

    suspend fun invites(communityId: String): List<Invite> {
        @Serializable
        data class Envelope(val invites: List<Invite> = emptyList())
        return api.requestAs<Envelope>("GET", "communities/$communityId/invites").invites
    }

    @Serializable
    private data class InviteBody(val max_uses: Int?, val expires_in_hours: Int?)

    suspend fun createInvite(
        communityId: String, maxUses: Int? = null, expiresInHours: Int? = null,
    ): Invite {
        val payload = ApiClient.json.encodeToString(
            InviteBody.serializer(), InviteBody(maxUses, expiresInHours))
        return api.requestAs("POST", "communities/$communityId/invites", payload)
    }

    suspend fun revokeInvite(communityId: String, token: String): Boolean {
        api.request("DELETE", "communities/$communityId/invites/$token")
        return true
    }
}
