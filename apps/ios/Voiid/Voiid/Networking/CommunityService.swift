//
//  CommunityService.swift
//  Voiid
//
//  Resolving and joining a community from an invite link. Mirrors Android `CommunityService.kt`.
//
//  RESOLUTION IS SERVER-SIDE, ON PURPOSE
//  -------------------------------------
//  The link (`CommunityLink`) carries a handle and an opaque capability token and nothing else.
//  Every fact shown on the join card — the name, the member count, whether the token is still
//  live, whether the caller is already in — is answered by the server, because those are the
//  only answers that can be trusted and because the alternative leaks. A client that decided
//  locally "this link works, so you're in" would be showing membership to anyone who was
//  forwarded the URL.
//
//  WHAT THE SERVER MAY RETURN, AND WHAT IT MUST NOT
//  ------------------------------------------------
//  `GET /v1/communities/<handle>` returns the PUBLIC CARD — the same fields a stranger browsing
//  the directory sees. 030_communities.sql declares those fields (name, description, avatar,
//  member count) server-readable broadcast identity, the same argument 029_creator_profiles.sql
//  makes for creator pages. The ROSTER is not in the card and must never be added to it: the
//  whole point of the container not being a conversation is that outsiders can read the card,
//  and an outsider reading the roster would be a membership leak dressed up as a feature.
//
//  Channel messages, the member↔host DM, calls, locations and moments are all still end-to-end
//  encrypted. Nothing on this path touches them.
//
//  A JOIN GRANTS NO MESSAGING RIGHT. Joining puts the caller in the community's MLS channels;
//  it does not open a 1:1 with anyone. The single narrow exception is member→community OWNER
//  (`POST /communities/:id/host-thread`, 030_communities.sql), and it is not on this path.
//

import Foundation

@MainActor
// Not ObservableObject: nothing here is @Published. The join sheet owns its own state and
// awaits these calls, so conformance would be inert weight — same shape as ContactPinService.
final class CommunityService {
    static let shared = CommunityService()
    private init() {}

    private let api = APIClient()

    /// The public info card — the object the server nests under `community`, plus the two facts
    /// the join sheet needs that arrive ALONGSIDE it rather than inside it.
    ///
    /// EVERY FIELD EXCEPT THE IDENTITY TRIO IS OPTIONAL, and that is not laziness. Swift's
    /// synthesised `Codable` throws `keyNotFound` on an ABSENT key, so a non-optional field is
    /// a hard decode failure against any server that has not grown it yet — and this app ships
    /// ahead of the backend routinely. The failure mode is the worst kind: a working link turns
    /// into "something went wrong" with nothing in it naming the missing field.
    ///
    /// `membership_state` and `invite_valid` are NOT part of the nested `community` object on
    /// the wire and always decode as absent from it. They are filled in by `resolve`, from the
    /// envelope's sibling field and from a separate probe respectively, because that is where
    /// the server puts them — deliberately: the card is a property of the community, whereas
    /// both of these are properties of the CALLER holding this link.
    struct CommunityCard: Decodable {
        let id: String
        let handle: String
        let name: String
        let description: String?
        /// Plaintext presigned R2 URL, like creator avatars (029). NOT the E2EE photo from 021.
        let avatar_url: String?
        let member_count: Int?
        /// open | approval | invite_only — decides what the join button promises.
        let join_policy: String?
        /// Whether it appears in search. A link works regardless; that is what links are for.
        let discoverable: Bool?
        /// The host. Present so a card can offer "Message host" (3.18) without a roster query.
        let owner_id: String?
        /// Suspended communities still resolve so the card can say why joining is refused.
        let suspended: Bool?
        /// What the directory files this community under (046). Free text, not an enum — the
        /// picker offers six, but the server takes any string, so never switch exhaustively
        /// on this and never assume it is one of the six a given build happens to know.
        let category: String?
        /// Whether an ordinary member may create invites (046). ALWAYS false in an invite-only
        /// community — the server forces it, because an invite-only community where everyone
        /// invites is not invite-only. Read it, never infer it from the policy.
        let members_can_invite: Bool?

        /// THE ONLY SOURCE OF TRUTH FOR "AM I IN THIS". Nil means not a member. Never infer this
        /// from the fact that a link resolved; a forwarded link resolves for everyone.
        var membership_state: String?
        /// Whether the token in the link is currently redeemable. Nil when the link carried no
        /// token.
        ///
        /// There is deliberately no accompanying reason code. The server answers revoked,
        /// expired, used-up and never-existed with ONE identical 404, because a probe that
        /// distinguishes them is an oracle for guessing tokens — and the user's next move is the
        /// same in every case: ask the host for a new link.
        var invite_valid: Bool?

        var members: Int { member_count ?? 0 }
        var policy: String { join_policy ?? "open" }
        /// Defaults to TRUE to match the column's `not null default true` (046), so a card
        /// from a server that has not grown the key yet reads as the schema's default rather
        /// than as "off" — the wrong default here would show every host their members cannot
        /// invite when they can.
        var membersCanInvite: Bool { members_can_invite ?? true }
        var isDiscoverable: Bool { discoverable ?? true }
        var isSuspended: Bool { suspended ?? false }
        var isMember: Bool { membership_state == "active" }
        var isPending: Bool { membership_state == "pending" }
        var isBanned: Bool { membership_state == "banned" }
    }

    /// What both read endpoints actually return: the card, plus the caller's own relationship to
    /// it as SIBLING fields. The nesting is the server's way of keeping the two apart — a card is
    /// the same for everybody, a membership state is not.
    private struct CommunityEnvelope: Decodable {
        let community: CommunityCard
        let membership_state: String?
        let membership_role: String?

        func merged(inviteValid: Bool?) -> CommunityCard {
            var card = community
            card.membership_state = membership_state
            card.invite_valid = inviteValid
            return card
        }
    }

    private struct JoinBody: Encodable {
        /// Nil when the link carried no token. `JSONEncoder` emits an explicit `null` for a nil
        /// Optional rather than omitting the key, which is fine here — the server reads an
        /// absent and a null token identically as "no capability presented".
        let invite_token: String?
    }

    /// `state` is what the caller's membership row landed on: 'active' or 'pending'.
    /// `existed` is true when the caller was already in.
    struct JoinResult: Decodable {
        let state: String?
        let existed: Bool?
    }

    /// Resolve a link to the card the join sheet shows.
    ///
    /// TWO ENDPOINTS, because the server splits the two questions on purpose:
    ///   GET /communities/<handle>          — what is this community (works for non-members)
    ///   GET /communities/invites/<token>   — is this token live, WITHOUT redeeming it
    ///
    /// The invite probe is tried first when the link carries a token, because it answers both
    /// questions in one round trip and because a resolve must never spend a use of a max_uses
    /// link — a link preview or an accidental tap would otherwise burn it.
    ///
    /// A FAILED PROBE IS NOT A FAILED LINK. Falling back to the handle lookup is what lets an
    /// open community still be joined from a poster whose printed token expired months ago: the
    /// user is told the invite is dead and handed the Join button anyway, because the community's
    /// own policy — not the link — is what decides who may join.
    ///
    /// THE HANDLE IN THE URL WINS. If the probe resolves a token minted for a DIFFERENT community
    /// than the handle names, the token is treated as not applying here. Otherwise a link reading
    /// `voiid.app/c/friendly_book_club?i=<token for something else>` would show one community's
    /// name and enrol the user in another.
    ///
    /// The token is presented here and nowhere else. It is not persisted, not logged, and not
    /// echoed back into the UI. No escaping is applied because both halves were pattern-checked
    /// in `CommunityLink.parse` against the same grammars the database enforces; a value needing
    /// escaping never becomes a `CommunityLink` in the first place.
    func resolve(_ link: CommunityLink) async throws -> CommunityCard {
        if let token = link.inviteToken {
            let probe: CommunityEnvelope? = try? await api.request(
                "GET", "communities/invites/\(token)")
            if let probe, probe.community.handle.caseInsensitiveCompare(link.handle) == .orderedSame {
                return probe.merged(inviteValid: true)
            }
            return try await byHandle(link.handle).merged(inviteValid: false)
        }
        return try await byHandle(link.handle).merged(inviteValid: nil)
    }

    private func byHandle(_ handle: String) async throws -> CommunityEnvelope {
        try await api.request("GET", "communities/\(handle)")
    }

    /// Join. `communityId` comes from the resolved card, never from the URL — the link names a
    /// handle, and handles can be released and re-registered, so redeeming against an id the
    /// server just handed us is what keeps a stale poster from enrolling someone in whatever
    /// community inherited the handle.
    ///
    /// Redemption itself is one conditional UPDATE server-side (030_communities.sql): a
    /// select-then-update loses the race on the last use of a max_uses link and lets two people
    /// spend it.
    /// Communities this account belongs to. The tab's own list.
    /// A community's Spaces. The name lives on the conversation, so the server joins for it.
    struct Channel: Decodable, Identifiable {
        let conversation_id: String
        let kind: String?
        let position: Int?
        let name: String?

        var id: String { conversation_id }
        /// Announcement channels are host-writes-everyone-reads; chat is everyone.
        var isAnnouncement: Bool { kind == "announcement" }
    }

    func channels(communityId: String) async throws -> [Channel] {
        struct Envelope: Decodable { let channels: [Channel] }
        let env: Envelope = try await api.request("GET", "communities/\(communityId)/channels")
        return env.channels
    }

    /// One row of the roster. NO display name and no avatar: the server returns ids, and
    /// resolving them is the directory's job, not this endpoint's.
    struct Member: Decodable, Identifiable {
        let user_id: String
        let role: String?
        let state: String?
        let joined_at: String?

        var id: String { user_id }
        var isOwner: Bool { role == "owner" }
        var isAdmin: Bool { role == "admin" || role == "owner" }
    }

    /// `state` filters the roster. Anything but `active` is manager-only — the server refuses
    /// a plain member asking who is banned, which is moderation state they are not entitled to.
    func members(communityId: String, state: String = "active") async throws -> [Member] {
        struct Envelope: Decodable { let members: [Member] }
        let env: Envelope = try await api.request(
            "GET", "communities/\(communityId)/members?state=\(state)")
        return env.members
    }

    func mine() async throws -> [CommunityCard] {
        struct Envelope: Decodable { let communities: [CommunityCard] }
        let env: Envelope = try await api.request("GET", "communities/mine")
        return env.communities
    }

    /// Discovery. The server refuses a query under two characters rather than returning the
    /// whole directory, so this returns empty for a short term instead of round-tripping.
    func search(_ term: String) async throws -> [CommunityCard] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        struct Envelope: Decodable { let communities: [CommunityCard] }
        let env: Envelope = try await api.request(
            "GET", "communities/search?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        return env.communities
    }

    /// Create one. `handle` shares the single namespace with usernames and creator handles
    /// (029/030), so the server may refuse it as taken — surfaced rather than pre-checked,
    /// because only the database can settle that race.
    /// Everything the five-step wizard collects (046). All of it past `handle` and `name` is
    /// optional, because every step but the first is skippable — a community created without
    /// rules or extra Spaces is a real community, not an incomplete one.
    struct RuleInput: Encodable { let title: String; let detail: String? }

    func create(handle: String, name: String, description: String?,
                joinPolicy: String = "open",
                discoverable: Bool = true,
                category: String? = nil,
                membersCanInvite: Bool = true,
                extraChannels: [String] = [],
                rules: [RuleInput] = []) async throws -> CommunityCard {
        struct Body: Encodable {
            let id: String
            let handle: String
            let name: String
            let description: String?
            let join_policy: String
            let discoverable: Bool
            let category: String?
            let members_can_invite: Bool
            let extra_channels: [String]
            let rules: [RuleInput]
        }
        struct Envelope: Decodable { let community: CommunityCard }
        // Client-supplied id makes a retry idempotent — the same reasoning as clips.
        let env: Envelope = try await api.request(
            "POST", "communities",
            body: Body(id: UUID().uuidString.lowercased(), handle: handle,
                       name: name, description: description,
                       join_policy: joinPolicy, discoverable: discoverable,
                       category: category, members_can_invite: membersCanInvite,
                       extra_channels: extraChannels, rules: rules))
        return env.community
    }

    /// A PATCH body that can OMIT a key, which no ordinary `Encodable` struct can do.
    ///
    /// Swift's synthesised encoding emits every declared property — nil becomes an explicit
    /// `null`. On these routes `null` means CLEAR THIS COLUMN and an absent key means LEAVE IT
    /// ALONE, so a struct with `let description: String?` would wipe the description of every
    /// community whose settings screen saved only a name. That is silent data loss, and it is
    /// the reason this type exists rather than six near-identical body structs.
    ///
    /// Values are held as a small closed enum rather than as `Any`: `JSONEncoder` cannot encode
    /// `Any`, and the three cases below are the only shapes these routes accept.
    private struct PatchBody: Encodable {
        private enum Value { case string(String), bool(Bool), int(Int), null }
        /// Insertion-ordered so the JSON is stable and diffable in a proxy log. A dictionary
        /// would reorder between runs for no gain.
        private var fields: [(key: String, value: Value)] = []

        var isEmpty: Bool { fields.isEmpty }

        /// A plain optional: nil means the caller is not touching this field, so nothing is
        /// written. There is no way to express "clear it" here, which is correct for the
        /// non-nullable columns (`name`, `discoverable`, `join_policy`, `position`).
        mutating func set(_ key: String, _ value: String?) {
            if let value { fields.append((key, .string(value))) }
        }
        mutating func set(_ key: String, _ value: Bool?) {
            if let value { fields.append((key, .bool(value))) }
        }
        mutating func set(_ key: String, _ value: Int?) {
            if let value { fields.append((key, .int(value))) }
        }

        /// The doubly-optional one, for the NULLABLE columns. The outer nil omits the key; an
        /// inner nil writes an explicit `null`, which is how a host clears a description or a
        /// category they no longer want.
        mutating func setNullable(_ key: String, _ value: String??) {
            guard let value else { return }
            fields.append((key, value.map { Value.string($0) } ?? .null))
        }

        /// `CodingKeys` cannot be an enum here — the keys are decided at runtime — so this is
        /// the `CodingKey`-by-string escape hatch the protocol provides for exactly this case.
        private struct Key: CodingKey {
            let stringValue: String
            init(_ s: String) { stringValue = s }
            init?(stringValue s: String) { stringValue = s }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            for (key, value) in fields {
                let k = Key(key)
                switch value {
                case .string(let s): try c.encode(s, forKey: k)
                case .bool(let b):   try c.encode(b, forKey: k)
                case .int(let i):    try c.encode(i, forKey: k)
                // `encodeNil` writes a real `null`, as opposed to `encodeIfPresent(nil)` which
                // would drop the key — the distinction this whole type exists to preserve.
                case .null:          try c.encodeNil(forKey: k)
                }
            }
        }
    }

    // MARK: - Settings (PATCH /communities/:id, and rules CRUD from 046)
    //
    // ── WHY THIS DID NOT EXIST ──────────────────────────────────────────────────────
    // `PATCH /communities/:id` has been on the server the whole time and this class had no
    // caller for it, so a host could create a community and then change NOTHING about it —
    // not its name, not whether it was discoverable, not how people join. The settings screen
    // is built on this method; there was no screen because there was no method.
    //
    // ── ABSENT MEANS "LEAVE IT ALONE", AND THAT IS WHY EVERY ARGUMENT IS DOUBLY OPTIONAL ──
    // The route distinguishes an ABSENT key (do not touch this column) from an explicit NULL
    // (clear it). `JSONEncoder` emits `null` for a nil Optional rather than omitting the key,
    // so a plain `String?` cannot express "absent" at all — sending nil would CLEAR the
    // description of every community whose settings screen saved a name.
    //
    // Hence `String??`: the outer nil means the caller is not touching the field and the key
    // is dropped from the body entirely; `.some(nil)` means clear it. That is the only shape
    // that can say both things, and getting it wrong here is silent data loss.

    /// Change a community's settings. Manager only server-side (`requireManager`: active owner
    /// or active admin) — the client gate is convenience, this is the enforcement.
    ///
    /// Covers all seven fields the route accepts. `avatar_r2_key` is deliberately NOT among
    /// them: it is an opaque R2 key needing an upload flow, and no helper in this app produces
    /// one a community card can render back. See the note on `CommunitySettingsView`.
    ///
    /// THE RETURNED CARD IS THE TRUTH, not the values that were sent. The server forces
    /// `members_can_invite` off for an invite-only community, so a caller that assumed its own
    /// input had been stored would display a setting the server had already overridden.
    func update(communityId: String,
                name: String? = nil,
                description: String?? = nil,
                discoverable: Bool? = nil,
                joinPolicy: String? = nil,
                category: String?? = nil,
                membersCanInvite: Bool? = nil) async throws -> CommunityCard {
        var body = PatchBody()
        body.set("name", name)
        // `.some(nil)` encodes an explicit `null`: clear it. An outer nil leaves the key out
        // entirely, which is the route's "leave this column alone".
        body.setNullable("description", description)
        body.set("discoverable", discoverable)
        body.set("join_policy", joinPolicy)
        body.setNullable("category", category)
        body.set("members_can_invite", membersCanInvite)
        // The server answers an empty body with a 400 `nothing to update`. Nothing to send is
        // not an error the user caused, so it never becomes a round trip.
        guard !body.isEmpty else { return try await byId(communityId) }

        struct Envelope: Decodable { let community: CommunityCard }
        let env: Envelope = try await api.request(
            "PATCH", "communities/\(communityId)", body: body)
        return env.community
    }

    /// The card by uuid. `GET /communities/:idOrHandle` takes either spelling.
    private func byId(_ communityId: String) async throws -> CommunityCard {
        let env: CommunityEnvelope = try await api.request("GET", "communities/\(communityId)")
        return env.merged(inviteValid: nil)
    }

    /// One rule (046). `detail` is nullable BY DESIGN — a short rule does not need explaining —
    /// so a nil detail is a normal row and not a partial decode.
    ///
    /// `position` is the ordering authority: 046 gives the table the column explicitly so a
    /// host can reorder without rules jumping to the end of the list when they edit one.
    struct Rule: Decodable, Identifiable, Hashable {
        let id: String
        var title: String?
        var detail: String?
        var position: Int?

        var text: String { title ?? "" }
        var explanation: String { detail ?? "" }
        var order: Int { position ?? 0 }
    }

    /// The rules, in the host's order. Readable by anyone who may read the community — the
    /// server uses the same `readGate` as the feed, because someone deciding whether to join
    /// needs to see the terms of joining BEFORE they join.
    func rules(communityId: String) async throws -> [Rule] {
        struct Envelope: Decodable { var rules: [Rule]? }
        let env: Envelope = try await api.request("GET", "communities/\(communityId)/rules")
        return env.rules ?? []
    }

    /// Manager only. `position` omitted appends to the END of the list server-side, so adding
    /// a rule never reshuffles the ones already there.
    func createRule(communityId: String, title: String,
                    detail: String? = nil) async throws -> Rule {
        struct Body: Encodable { let title: String; let detail: String? }
        struct Envelope: Decodable { let rule: Rule }
        let env: Envelope = try await api.request(
            "POST", "communities/\(communityId)/rules",
            body: Body(title: title, detail: detail))
        return env.rule
    }

    /// Manager only. Editing and REORDERING are the same endpoint on purpose — an absent key
    /// leaves its column alone, so fixing a typo does not move the rule and dragging a row does
    /// not resend its text. Same `String??` contract as `update` above, for the same reason.
    func updateRule(communityId: String, ruleId: String,
                    title: String? = nil,
                    detail: String?? = nil,
                    position: Int? = nil) async throws -> Rule {
        var body = PatchBody()
        body.set("title", title)
        body.setNullable("detail", detail)
        body.set("position", position)
        guard !body.isEmpty else { throw APIError.http(status: 400, message: "Nothing to save.") }

        struct Envelope: Decodable { let rule: Rule }
        let env: Envelope = try await api.request(
            "PATCH", "communities/\(communityId)/rules/\(ruleId)", body: body)
        return env.rule
    }

    /// Manager only. A HARD delete, like a link: a rule is the host's own standing text, and
    /// 046 gives the table no `removed_at` to soft-delete into.
    @discardableResult
    func deleteRule(communityId: String, ruleId: String) async throws -> Bool {
        struct Envelope: Decodable { var deleted: Bool? }
        let env: Envelope = try await api.request(
            "DELETE", "communities/\(communityId)/rules/\(ruleId)")
        return env.deleted ?? true
    }

    // MARK: - The Home tab (047_community_home.sql)
    //
    // ── NOT E2EE, AND THAT IS THE POINT ─────────────────────────────────────────────
    // Posts, the pinned announcement and the About links are SERVER-READABLE by design. A post
    // is a BROADCAST addressed to everyone who might later look — including, for a discoverable
    // community, people who have not joined and hold no MLS key. There is no key that means
    // "everyone who might later look", so a feed the server cannot read is a feed that cannot
    // be served at all. Channel messages (MLS) and the member↔host DM stay encrypted and share
    // no code path with any of this.
    //
    // ── EVERY FIELD OPTIONAL OR DEFAULTED ───────────────────────────────────────────
    // Swift's synthesised Codable throws `keyNotFound` on an ABSENT key, which fails the WHOLE
    // decode and drops the entire payload — not just the missing field. This app has been bitten
    // by exactly that twice. The server is written to always emit every key as null rather than
    // omit it, and these types are written as though it were not, because a client that depends
    // on the server never regressing is a client that regresses with it.

    /// One post in the Home feed.
    ///
    /// `author_name` is nullable ON PURPOSE and is not a defect to paper over: 047 makes
    /// `author_id` ON DELETE SET NULL so that deleting an account does not rewrite the
    /// community's history. A null author is a real, expected row and renders as "Deleted
    /// account", which is the honest thing to show.
    struct Post: Decodable, Identifiable, Hashable {
        let id: String
        var author_id: String?
        var author_name: String?
        var author_username: String?
        var author_photo_url: String?
        /// The only field the server cannot omit — a post with no body cannot exist
        /// (community_posts_body_len). Defaulted anyway; see the note above.
        var body: String?
        var media_url: String?
        var like_count: Int?
        var comment_count: Int?
        var liked_by_me: Bool?
        var created_at: String?
        var edited_at: String?

        var text: String { body ?? "" }
        var likes: Int { like_count ?? 0 }
        var comments: Int { comment_count ?? 0 }
        var isLiked: Bool { liked_by_me ?? false }
        /// What the card shows above the body. Falls back through the two identity columns
        /// before admitting the account is gone.
        var displayName: String {
            if let n = author_name, !n.isEmpty { return n }
            if let u = author_username, !u.isEmpty { return "@\(u)" }
            return "Deleted account"
        }
    }

    /// A page of the feed. `next_cursor` is null on the last page — the caller stops on null
    /// rather than fetching an empty page.
    struct PostPage: Decodable {
        var posts: [Post]?
        var next_cursor: String?

        var rows: [Post] { posts ?? [] }
    }

    /// The feed, newest first. Keyset-paginated on `created_at`, not OFFSET: an offset page
    /// shifts under the reader every time somebody posts.
    func posts(communityId: String, cursor: String? = nil, limit: Int = 20) async throws -> PostPage {
        var path = "communities/\(communityId)/posts?limit=\(limit)"
        if let cursor, !cursor.isEmpty {
            let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
            path += "&cursor=\(escaped)"
        }
        return try await api.request("GET", path)
    }

    /// Write a post. MEMBERS ONLY server-side — a stranger reading a discoverable feed is a
    /// visitor, not a participant — so this can 403 even where `posts(...)` succeeded.
    func createPost(communityId: String, body: String, mediaUrl: String? = nil) async throws -> Post {
        struct Body: Encodable { let body: String; let media_url: String? }
        struct Envelope: Decodable { let post: Post }
        let env: Envelope = try await api.request(
            "POST", "communities/\(communityId)/posts",
            body: Body(body: body, media_url: mediaUrl))
        return env.post
    }

    /// Remove a post. The server allows the AUTHOR or a community manager and answers a single
    /// 404 for every refusal, so there is nothing here to branch on.
    ///
    /// It sets `removed_at` rather than deleting: 047 keeps the row so a moderator can see what
    /// they removed and an appeal has something to point at.
    @discardableResult
    func deletePost(communityId: String, postId: String) async throws -> Bool {
        struct Envelope: Decodable { var removed: Bool? }
        let env: Envelope = try await api.request(
            "DELETE", "communities/\(communityId)/posts/\(postId)")
        return env.removed ?? true
    }

    /// The truthful like count after the write, which is why this returns it rather than
    /// letting the caller increment locally: the server only moves the counter when the join
    /// row actually moved, so a double-tap or a retry converges instead of drifting.
    struct LikeResult: Decodable {
        var liked: Bool?
        var like_count: Int?
    }

    func likePost(communityId: String, postId: String) async throws -> LikeResult {
        struct EmptyBody: Encodable {}
        return try await api.request(
            "POST", "communities/\(communityId)/posts/\(postId)/like", body: EmptyBody())
    }

    func unlikePost(communityId: String, postId: String) async throws -> LikeResult {
        try await api.request("DELETE", "communities/\(communityId)/posts/\(postId)/like")
    }

    /// The pinned announcement.
    ///
    /// 047 makes this a TABLE rather than a flag on a post or a column on the community, so an
    /// announcement outlives the feed and the history survives being replaced. Exactly one is
    /// live at a time, enforced by a partial unique index rather than by sort order.
    struct Announcement: Decodable, Identifiable, Hashable {
        let id: String
        var author_id: String?
        var author_name: String?
        var author_username: String?
        var author_photo_url: String?
        var title: String?
        var body: String?
        var pinned_at: String?
        var created_at: String?

        var headline: String { title ?? "" }
        var text: String { body ?? "" }
        /// Same fallback chain as a post's, and for the same ON DELETE SET NULL reason.
        var displayName: String {
            if let n = author_name, !n.isEmpty { return n }
            if let u = author_username, !u.isEmpty { return "@\(u)" }
            return "Deleted account"
        }
    }

    /// `nil` is the ORDINARY state, not a failure: most communities have nothing pinned, and
    /// the server answers that with a 200 carrying null rather than a 404 — so no screen has to
    /// open by handling an error for the common case.
    func announcement(communityId: String) async throws -> Announcement? {
        struct Envelope: Decodable { var announcement: Announcement? }
        let env: Envelope = try await api.request(
            "GET", "communities/\(communityId)/announcements")
        return env.announcement
    }

    /// Pin a new one. Manager only. The server unpins the current one in the SAME transaction —
    /// it has to, because `community_announcements_one_live_idx` refuses a second live row.
    func pinAnnouncement(communityId: String, title: String, body: String) async throws -> Announcement {
        struct Body: Encodable { let title: String; let body: String }
        struct Envelope: Decodable { let announcement: Announcement }
        let env: Envelope = try await api.request(
            "POST", "communities/\(communityId)/announcements",
            body: Body(title: title, body: body))
        return env.announcement
    }

    /// Unpin. Sets `unpinned_at`; the row and its history stay, by design.
    @discardableResult
    func unpinAnnouncement(communityId: String, announcementId: String) async throws -> Bool {
        struct Envelope: Decodable { var unpinned: Bool? }
        let env: Envelope = try await api.request(
            "DELETE", "communities/\(communityId)/announcements/\(announcementId)")
        return env.unpinned ?? true
    }

    /// One row of the About tab's links list.
    ///
    /// `value` is TEXT, not a URL, and must not be validated as one: 047 says so explicitly —
    /// the About tab also carries a contact address and a "read the handbook" label, and forcing
    /// every row to parse as a URL would exclude both.
    ///
    /// `icon` is free text naming an SF Symbol from a client-side set. The server never invents
    /// one, so nil is normal and the client picks its own fallback.
    struct AboutLink: Decodable, Identifiable, Hashable {
        let id: String
        var label: String?
        var value: String?
        var icon: String?
        var position: Int?

        var title: String { label ?? "" }
        var subtitle: String { value ?? "" }
    }

    func links(communityId: String) async throws -> [AboutLink] {
        struct Envelope: Decodable { var links: [AboutLink]? }
        let env: Envelope = try await api.request("GET", "communities/\(communityId)/links")
        return env.links ?? []
    }

    /// Manager only.
    func createLink(communityId: String, label: String, value: String,
                    icon: String? = nil) async throws -> AboutLink {
        struct Body: Encodable { let label: String; let value: String; let icon: String? }
        struct Envelope: Decodable { let link: AboutLink }
        let env: Envelope = try await api.request(
            "POST", "communities/\(communityId)/links",
            body: Body(label: label, value: value, icon: icon))
        return env.link
    }

    /// Manager only. A HARD delete, unlike a post: a link is a pointer, not a statement, so
    /// there is no appeal to hear and no history worth keeping.
    @discardableResult
    func deleteLink(communityId: String, linkId: String) async throws -> Bool {
        struct Envelope: Decodable { var deleted: Bool? }
        let env: Envelope = try await api.request(
            "DELETE", "communities/\(communityId)/links/\(linkId)")
        return env.deleted ?? true
    }

    func join(communityId: String, inviteToken: String?) async throws -> (state: String, existed: Bool) {
        let res: JoinResult = try await api.request(
            "POST", "communities/\(communityId)/join",
            body: JoinBody(invite_token: inviteToken)
        )
        // An older server that answers 200 without these keys still joined the caller; treating
        // that as a failure would tell the user nothing happened when it did.
        return (res.state ?? "active", res.existed ?? false)
    }
}
