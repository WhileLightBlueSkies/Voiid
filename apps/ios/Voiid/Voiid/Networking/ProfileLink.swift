//
//  ProfileLink.swift
//  Voiid
//
//  The personal link behind your QR code — `https://voiid.app/u/<username>`.
//
//  Sibling of `CommunityLink`, and deliberately built the same way: same host check, same
//  HTTPS-only rule, same "validate before the handle ever reaches an API path" discipline.
//
//  ── WHAT THE LINK CARRIES, AND WHAT IT MUST NEVER CARRY ─────────────────────────
//  A username. That is all.
//
//  It does NOT carry the Contact PIN, and this is the single most important decision in the
//  QR feature. `ContactPinService` states the design: username and PIN are TWO INDEPENDENT
//  GATES, "so a leaked PIN alone is not enough" to reach someone. A QR code is a photograph
//  waiting to happen — screenshotted, posted, shoulder-surfed, printed on a poster. Putting
//  the PIN inside it would collapse both gates into one image and hand anyone who ever saw
//  your code the ability to open a request.
//
//  The PIN travels out of band, spoken or typed ("my Voiid is @nehal, PIN 418302"). The QR
//  replaces the tedious half — spelling a handle correctly — and nothing else.
//
//  ── AND IT IS NOT AN INTRODUCTION ───────────────────────────────────────────────
//  Scanning proves someone showed you a code. It does not prove the owner wants to hear from
//  them, so a scan lands in exactly the same place a typed handle lands: the PIN step, then a
//  REQUEST the owner still has to accept. `FindByUsernameView` is reused rather than copied
//  precisely so the two routes cannot drift apart and quietly gain different gates.
//
//  ── HTTPS ONLY, NO CUSTOM SCHEME ────────────────────────────────────────────────
//  Same reasoning as CommunityLink, plus one that is specific to this link: an `https://` URL
//  degrades gracefully. Someone without Voiid who scans this with their camera lands on the
//  website instead of an "cannot open page" error — which matters more here than anywhere
//  else, because a personal QR is the one link most often scanned by people who do not have
//  the app yet.
//

import Foundation
import Combine

struct ProfileLink: Identifiable, Equatable {
    /// Lowercased, and already validated against the server's own grammar.
    let username: String

    var id: String { username }

    private static let host = "voiid.app"
    private static let hostWWW = "www.voiid.app"
    private static let pathSegment = "u"

    /// `010_username.sql`'s check constraint, restated. Not cosmetic: the handle is
    /// interpolated into an API query, so anything outside [a-z0-9_] must be rejected BEFORE
    /// a request is built — a crafted link whose "username" decodes to a path traversal would
    /// otherwise walk the client onto a different endpoint while the user believes they are
    /// looking at a person.
    private static let usernamePattern = "^[a-z][a-z0-9_]{2,19}$"

    /// Parse an inbound URL, or nil if it is not a profile link we recognise.
    static func parse(_ url: URL?) -> ProfileLink? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https",
              let host = components.host?.lowercased(),
              host == Self.host || host == Self.hostWWW
        else { return nil }

        // `pathComponents` is already percent-decoded, so this compares real segments rather
        // than their encoding; the pattern below is what makes that decoding safe.
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 2, segments[0] == pathSegment else { return nil }

        let username = segments[1].lowercased()
        guard username.range(of: usernamePattern, options: .regularExpression) != nil else {
            return nil
        }
        return ProfileLink(username: username)
    }

    /// Build the link for a username — the value encoded into the QR and shared by the
    /// share sheet. No percent-encoding: the grammar above admits no character that needs it.
    static func url(for username: String) -> URL? {
        let clean = username.lowercased()
        guard clean.range(of: usernamePattern, options: .regularExpression) != nil else {
            return nil
        }
        return URL(string: "https://\(host)/\(pathSegment)/\(clean)")
    }
}

/// Parks an inbound profile link until a view with a signed-in session can act on it.
///
/// Twin of `CommunityLinkRouter`, and the same reasoning applies: the OS can hand us a link
/// during a cold launch, long before there is a session to look anything up with. Nothing here
/// is trusted or requested — the router holds a validated username and waits.
@MainActor
final class ProfileLinkRouter: ObservableObject {
    static let shared = ProfileLinkRouter()
    private init() {}

    /// The link waiting to be shown; nil once the flow has taken it.
    @Published private(set) var pending: ProfileLink?

    /// A URL that is not a profile link is silently ignored rather than clearing `pending`:
    /// unrelated activities (Siri call intents, Firebase's reCAPTCHA redirect) flow through
    /// the same handling and must not discard a link the user is mid-way through.
    func handle(_ url: URL?) {
        guard let link = ProfileLink.parse(url) else { return }
        pending = link
    }

    func consume() { pending = nil }
}
