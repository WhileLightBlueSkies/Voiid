//
//  GameInvite.swift
//  Voiid
//
//  The wire form of a game invite (docs/GAMES.md §3).
//
//  WHY A TEXT-CARRIED JSON ENVELOPE AND NOT A NEW MESSAGE TYPE: the invite must arrive with a push,
//  survive the recipient being offline, and be end-to-end encrypted. The ordinary text pipe already
//  does all three, correctly, including the retry-on-reconnect queue. A bespoke content_type would
//  mean a second server contract, a second push path, and a second thing to get wrong.
//
//  SO AN INVITE IS A TEXT MESSAGE whose body is a readable line followed by a JSON payload. The
//  readable line matters for two reasons: an older build that doesn't know this format shows a
//  sensible sentence instead of a blank bubble, and the SERVER never sees any of it — the whole body
//  is inside the ratchet, which is what lets the notification name the game without Apple or Google
//  ever learning who invited whom to what.
//
//  FORMAT:
//    <human line>
//    voiid:game/<slug>/<matchId>
//    voiid:gamemeta/<JSON>
//
//  The marker lines go LAST and are matched by prefix, so text before them is harmless. The meta
//  line is OPTIONAL: `parse` succeeds on the slug/matchId pair alone, so invites sent by an older
//  client still open the right board.
//
//  Mirrors Android `GameInvite.kt`.
//

import Foundation

enum GameInvite {

    private static let scheme = "voiid:game/"
    private static let metaScheme = "voiid:gamemeta/"

    /// How long an invite stays live before it counts as missed.
    static let expiryMs: Int64 = 10 * 60 * 1000

    /// Everything the poster bubble and the rich notification need, so neither has to guess.
    ///
    /// All of it travels INSIDE the E2EE body. That is the reason a notification can say
    /// "Nehal invited you to Hand Cricket · 3 overs" while the push that woke the device said only
    /// "New message": the device decrypts, then rewrites its own banner.
    struct Meta: Codable, Equatable {
        var game: String = ""
        /// Who sent it, for the poster and the banner.
        var from: String = ""
        /// Bot difficulty label if relevant, else empty. Online games have no level.
        var level: String = ""
        /// Overs for hand cricket; 0 when the game has no such setting.
        var overs: Int = 0
        /// "first to 3" style summary, or empty.
        var format: String = ""
        /// Epoch millis the invite was created — the expiry clock starts here.
        var sentAt: Int64 = 0

        /// One line of game settings for the poster, assembled from whatever is set. Built here
        /// rather than in each UI so Android and iOS describe an invite identically.
        func detailLine() -> String {
            var parts: [String] = []
            if overs > 0 { parts.append("\(overs) \(overs == 1 ? "over" : "overs")") }
            if !format.isEmpty { parts.append(format) }
            if !level.isEmpty { parts.append(level) }
            return parts.joined(separator: " · ")
        }

        var isExpired: Bool {
            guard sentAt > 0 else { return false }
            return nowMs() - sentAt > GameInvite.expiryMs
        }

        /// Millis remaining, floored at zero. Drives the countdown on the home-screen banner.
        var remainingMs: Int64 {
            guard sentAt > 0 else { return GameInvite.expiryMs }
            return max(0, sentAt + GameInvite.expiryMs - nowMs())
        }
    }

    /// A parsed invite. `matchId` is what `POST /games/matches/:id/join` needs.
    struct Parsed: Equatable {
        let slug: String
        let matchId: String
        /// Nil when the sender was an older build that didn't attach meta.
        let meta: Meta?
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Build the message body for an invite to `matchId`.
    static func encode(slug: String, matchId: String, meta: Meta) -> String {
        var head = "🎮 \(meta.from.isEmpty ? "Someone" : meta.from) invited you to \(meta.game)"
        let details = meta.detailLine()
        if !details.isEmpty { head += " · \(details)" }

        var body = head + "\n" + scheme + slug + "/" + matchId
        if let data = try? JSONEncoder().encode(meta),
           let json = String(data: data, encoding: .utf8) {
            body += "\n" + metaScheme + json
        }
        return body
    }

    /// Recover the invite from a message body, or nil if this isn't one.
    ///
    /// Tolerant of trailing whitespace and of text before the markers. A malformed meta line
    /// degrades to `meta = nil` rather than failing the whole parse — the match id is what matters.
    static func parse(_ text: String) -> Parsed? {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let idLine = lines.last(where: { $0.hasPrefix(scheme) }) else { return nil }
        let parts = String(idLine.dropFirst(scheme.count)).split(separator: "/")
        guard parts.count == 2 else { return nil }
        let slug = String(parts[0]), matchId = String(parts[1])
        guard !slug.isEmpty, !matchId.isEmpty else { return nil }

        var meta: Meta?
        if let metaLine = lines.last(where: { $0.hasPrefix(metaScheme) }) {
            let json = String(metaLine.dropFirst(metaScheme.count))
            meta = try? JSONDecoder().decode(Meta.self, from: Data(json.utf8))
        }
        return Parsed(slug: slug, matchId: matchId, meta: meta)
    }

    /// True if `text` carries an invite. Cheap enough for a render path.
    static func isInvite(_ text: String) -> Bool { parse(text) != nil }

    /// What a notification or the chat list shows. Never the marker lines — a raw `voiid:game/...`
    /// in a banner or conversation preview is noise.
    static func preview(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix(scheme) && !$0.hasPrefix(metaScheme) }
            ?? "🎮 Game invite"
    }

    /// Notification body for a game invite, or nil if this isn't one.
    ///
    /// THIS IS WHY THE PUSH IS WORTH DECRYPTING. The wake push carried no content — the server never
    /// knew what it was for. The NSE decrypts the envelope locally, so it can name the game and its
    /// settings here, and the only string Apple's servers ever saw was "New message".
    static func notificationBody(_ text: String) -> String? {
        guard let invite = parse(text) else { return nil }
        guard let meta = invite.meta else { return String(preview(text).prefix(140)) }
        if meta.isExpired { return "Game invite expired" }
        let game = meta.game.isEmpty ? "a game" : meta.game
        let details = meta.detailLine()
        return details.isEmpty
            ? "🎮 Invited you to \(game)"
            : "🎮 Invited you to \(game) · \(details)"
    }
}
