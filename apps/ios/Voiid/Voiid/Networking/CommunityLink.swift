//
//  CommunityLink.swift
//  Voiid
//
//  The community invite link — `https://voiid.app/c/<handle>?i=<token>`.
//
//  Mirrors Android `CommunityLink.kt`; the two parsers must agree, because the same printed QR
//  code has to mean the same thing on both phones.
//
//  WHY A PLAIN SERVER TOKEN AND NOT SIGNAL'S SCHEME
//  -----------------------------------------------
//  Signal's group links carry the group master key and a join password in the URL FRAGMENT,
//  which never leaves the browser and never reaches its server — it can do that because Signal's
//  group STATE is encrypted too (zkgroup). Voiid's community roster is server-visible by design
//  (030_communities.sql: the server gates joins and fans MLS Welcome/Commit out per member), so
//  there is no encrypted group state for a fragment to protect. What we take from Signal is the
//  part that still applies: an unguessable token, revocable, with expiry and a use cap
//  (`community_invites`). A key in a fragment cannot be revoked; a row in a table can.
//
//  THE LINK IS NOT A MEMBERSHIP CLAIM
//  ----------------------------------
//  Holding this URL proves nothing and reveals nothing on its own. Everything the user is shown
//  comes back from the server — `GET /v1/communities/<handle>` for the card and
//  `GET /v1/communities/invites/<token>` for whether the token is still live. The server decides
//  what a link-holder may see, and the public card it returns contains no roster. In particular the client
//  must never infer "you are a member" from the fact that a link opened: whether you are in is
//  `CommunityCard.membership_state`, which only the server can answer. Nothing here is decoded,
//  decrypted or trusted locally.
//
//  The token is a bearer capability, so it is treated like one: it travels only to the API host
//  over TLS, it is never logged, and it is never rendered back into the UI.
//

import Foundation
import Combine

struct CommunityLink: Identifiable, Equatable {
    let handle: String
    /// Nil for an open community whose link needs no capability (join_policy != 'invite_only').
    let inviteToken: String?

    /// Identity for `.sheet(item:)`. Includes the token so that tapping a SECOND link for the
    /// same community — say, a fresh one after the first expired — actually re-presents the
    /// sheet instead of being treated as the same item and ignored.
    var id: String { "\(handle)|\(inviteToken ?? "")" }

    /// The apex the Universal Links entitlement is verified against.
    static let host = "voiid.app"
    static let hostWWW = "www.voiid.app"
    /// First path segment. Kept short because these end up on posters and stickers.
    static let pathSegment = "c"
    /// Query parameter carrying the invite token.
    static let queryToken = "i"

    /// Same grammar as `communities_handle_format` in 030_communities.sql, restated here on
    /// purpose. This is not cosmetic validation: the handle is interpolated into an API path,
    /// so anything that is not [a-z0-9_] must be rejected BEFORE a request is built. A crafted
    /// link whose "handle" decodes to `../users/me` would otherwise walk the client onto a
    /// different endpoint while the user believes they are looking at a community.
    private static let handlePattern = "^[a-z][a-z0-9_]{2,19}$"

    /// 32 bytes of CSPRNG output in base64url, per `community_invites.token`. The length bounds
    /// mirror the `community_invites_token_len` check (22..64) so a garbage query string is
    /// discarded here rather than spent as a failed redemption attempt server-side.
    private static let tokenPattern = "^[A-Za-z0-9_-]{22,64}$"

    /// Parse an inbound URL, or nil if it is not a community link we recognise.
    ///
    /// HTTPS ONLY, and only our own hosts. An `http://` variant is refused rather than upgraded:
    /// the token is a bearer capability and must not be recoverable from a plaintext request
    /// that a captive portal or a coffee-shop router can read. There is also deliberately no
    /// `voiid://` custom-scheme fallback — any app on the device can claim a custom scheme and
    /// would then be handed live invite tokens, which is exactly what Universal Links exist to
    /// prevent.
    static func parse(_ url: URL?) -> CommunityLink? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https",
              let host = components.host?.lowercased(),
              host == Self.host || host == Self.hostWWW
        else { return nil }

        // `pathComponents` is already percent-decoded, so this compares the real segments and
        // not their encoding; the handle pattern below is what makes the decoding safe.
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 2, segments[0] == pathSegment else { return nil }
        let handle = segments[1].lowercased()
        guard handle.range(of: handlePattern, options: .regularExpression) != nil else { return nil }

        // A malformed token is dropped, NOT passed through: sending it would burn a redemption
        // attempt and teach the user nothing. The link then behaves as a plain "look at this
        // community" link, and the server refuses the join if one was needed.
        let raw = components.queryItems?.first { $0.name == queryToken }?.value
        let token = raw.flatMap { $0.range(of: tokenPattern, options: .regularExpression) != nil ? $0 : nil }
        return CommunityLink(handle: handle, inviteToken: token)
    }

    /// Build a shareable link. The counterpart to `parse`; used by the invite-share UI.
    ///
    /// No percent-encoding: the token is base64url by construction and every character in
    /// `tokenPattern` is already legal in a query value. Anything that WOULD have needed
    /// escaping is not a token this app will ever hold, because `parse` rejects it.
    static func format(handle: String, inviteToken: String?) -> String {
        let base = "https://\(host)/\(pathSegment)/\(handle)"
        guard let inviteToken, !inviteToken.isEmpty else { return base }
        return "\(base)?\(queryToken)=\(inviteToken)"
    }
}

/// Process-global parking spot for a tapped community link, observed by `ContentView`.
///
/// The iOS counterpart of Android's `DeepLinkRouter.pendingCommunityInvite`, and it exists for
/// the same reason: a universal link is delivered to the App scene, which is nowhere near the
/// view that has to show something about it.
///
/// It is HELD, not consumed on read, because a cold launch from a link on a fresh install lands
/// on onboarding. The link must survive sign-in rather than being thrown away at the moment
/// there is nobody to resolve it for — a brand-new user who taps an invite and gets dropped on
/// an empty Chats screen has no idea what the link did.
@MainActor
final class CommunityLinkRouter: ObservableObject {
    static let shared = CommunityLinkRouter()
    private init() {}

    /// The link waiting to be shown; nil once the sheet has been dismissed.
    @Published private(set) var pending: CommunityLink?

    /// Called with whatever URL the OS handed us. A URL that is not a community link is
    /// silently ignored rather than clearing `pending`: unrelated activities (Siri call
    /// intents, Firebase's reCAPTCHA redirect) also flow through the app's URL handling and
    /// must not discard a link the user is mid-way through.
    func handle(_ url: URL?) {
        guard let link = CommunityLink.parse(url) else { return }
        pending = link
    }

    func consume() { pending = nil }
}
