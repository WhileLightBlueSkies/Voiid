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
