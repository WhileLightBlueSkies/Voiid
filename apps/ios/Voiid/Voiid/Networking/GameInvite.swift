//
//  GameInvite.swift
//  Voiid
//
//  The wire form of a game invite (docs/GAMES.md §3).
//
//  WHY A TEXT TOKEN AND NOT A NEW MESSAGE TYPE: the invite must arrive with a push, survive
//  the recipient being offline, and be end-to-end encrypted. The ordinary text pipe already
//  does all three, correctly, including the retry-on-reconnect queue. A bespoke content_type
//  would mean a second server contract, a second push path, and a second thing to get wrong
//  — for a payload that is two ids.
//
//  So an invite IS a text message whose body happens to be recognisable. Clients that
//  understand the token draw a Join button; an older build shows a readable line of text
//  rather than a blank bubble, which is the whole reason the human-readable prefix is part
//  of the format instead of a bare URI.
//
//  FORMAT: `<human text>\nvoiid:game/<slug>/<matchId>`
//  The marker goes LAST so the final matching line finds it regardless of what precedes it.
//
//  Mirrors Android `GameInvite.kt`.
//

import Foundation

enum GameInvite {

    private static let scheme = "voiid:game/"

    /// A parsed invite. `matchId` is what `POST /games/matches/:id/join` needs.
    struct Parsed: Equatable {
        let slug: String
        let matchId: String
    }

    /// Build the message body for an invite to `matchId`.
    ///
    /// `gameName` is the display name from the catalog ("Tic Tac Toe"), so the readable half
    /// names the actual game rather than a slug.
    static func encode(slug: String, matchId: String, gameName: String) -> String {
        "🎮 Let's play \(gameName)!\n\(scheme)\(slug)/\(matchId)"
    }

    /// Recover the invite from a message body, or nil if this isn't one.
    ///
    /// Tolerant of trailing whitespace and of text before the marker, because the body is a
    /// user-visible string that other code (previews, forwarding) may have touched.
    static func parse(_ text: String) -> Parsed? {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix(scheme) }
        guard let line else { return nil }
        let parts = String(line.dropFirst(scheme.count)).split(separator: "/")
        guard parts.count == 2 else { return nil }
        let slug = String(parts[0]), matchId = String(parts[1])
        guard !slug.isEmpty, !matchId.isEmpty else { return nil }
        return Parsed(slug: slug, matchId: matchId)
    }

    /// True if `text` carries an invite. Cheap enough for a render path.
    static func isInvite(_ text: String) -> Bool { parse(text) != nil }

    /// What the chat LIST shows for an invite. The raw token in a conversation preview would
    /// be noise, so the marker never reaches the list.
    static func preview(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .first { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(scheme)
                     && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? "🎮 Game invite"
    }
}
