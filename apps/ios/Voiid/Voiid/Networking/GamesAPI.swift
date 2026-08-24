//
//  GamesAPI.swift
//  Voiid
//
//  Match lifecycle only (docs/GAMES.md §3): the catalog, creating a match, joining one,
//  history. This is the durable, authorized half of the games system.
//
//  There is deliberately NO move endpoint. Moves are WS-only (GamesEngine), for the same
//  reason LocationAPI has no position endpoint: a move is a tiny frame in a stream of
//  them, and an HTTP round-trip per tap would add latency to the one interaction that has
//  to feel immediate.
//

import Foundation

struct GamesAPI {
    private let api = APIClient()

    // MARK: - DTOs

    struct CatalogGame: Decodable, Identifiable {
        let id: String
        let slug: String
        let name: String
        let category: String
        let min_players: Int
        let max_players: Int
        var icon_key: String?
    }
    struct CatalogResponse: Decodable { let games: [CatalogGame] }

    struct CreateBody: Encodable {
        let slug: String
        let opponent_ids: [String]
        /// Per-game settings chosen at creation (hand cricket's over count). Stored on the
        /// match row and validated by the engine — this client sends, it does not police.
        let options: [String: Int]
        /// Snake's chosen skin id. A separate field because `options` is [String: Int] across
        /// every game, and widening that for one game's cosmetic would touch four others.
        let skin: String?
    }
    struct CreateResponse: Decodable {
        let match_id: String
        let players: [String]
    }
    struct JoinResponse: Decodable { let ok: Bool; let match_id: String }

    // MARK: - Daily challenge

    struct DailyBody: Encodable { let skin: String? }
    struct DailyStartResponse: Decodable { let match_id: String; let day: String }

    /// One row of today's board. GLOBAL, unlike `LeaderboardRow` — see the route header: the
    /// comparison is meaningful precisely because everyone played the same arena.
    struct DailyRow: Decodable, Identifiable {
        let user_id: String
        let full_name: String?
        let username: String?
        let score: Int
        var id: String { user_id }
    }
    struct DailyMine: Decodable {
        /// Null while a run is still in progress — which is how "playing" is told from "played".
        let score: Int?
        let status: String
    }
    struct DailyResponse: Decodable {
        let day: String
        let seed: Int
        let leaderboard: [DailyRow]
        let mine: DailyMine?
    }

    /// Start today's run. Throws on 409 — they already played, which is the rule, not an error
    /// to retry.
    func startDaily(skin: String?) async throws -> DailyStartResponse {
        try await api.request("POST", "games/daily", body: DailyBody(skin: skin))
    }

    func daily() async throws -> DailyResponse {
        try await api.request("GET", "games/daily")
    }

    /// One opponent's head-to-head record with the caller. Scoped to people actually
    /// played — never a global ranking (see the route header for why).
    struct LeaderboardRow: Decodable, Identifiable {
        let opponent_id: String
        var full_name: String?
        var username: String?
        let played: Int
        let wins: Int
        let draws: Int
        let losses: Int

        var id: String { opponent_id }
        var displayName: String { full_name ?? username ?? "Unknown" }
    }
    private struct LeaderboardResponse: Decodable { let leaderboard: [LeaderboardRow] }

    // MARK: - Calls

    /// Wins per person among people the caller has finished matches with.
    func leaderboard(slug: String? = nil) async throws -> [LeaderboardRow] {
        let path = slug.map { "games/leaderboard?game=\($0)" } ?? "games/leaderboard"
        let res: LeaderboardResponse = try await api.request("GET", path)
        return res.leaderboard
    }

    /// The catalog. Static and small; a caller may cache it for the session.
    func catalog() async throws -> [CatalogGame] {
        let res: CatalogResponse = try await api.request("GET", "games")
        return res.games
    }

    /// Mint a match. The CALLER then sends the invite as an ordinary E2EE message
    /// carrying this id — this endpoint deliberately sends no notification of its own, so
    /// an invite produces exactly one alert, from the message path that already does wake
    /// and push correctly.
    func create(
        slug: String,
        opponentIds: [String],
        options: [String: Int] = [:],
        skin: String? = nil
    ) async throws -> String {
        let res: CreateResponse = try await api.request(
            "POST", "games/matches",
            body: CreateBody(slug: slug, opponent_ids: opponentIds, options: options, skin: skin))
        return res.match_id
    }

    /// Enter a match. The opening board does NOT come back here — the server builds it and
    /// broadcasts a `game_state` frame to every player.
    @discardableResult
    func join(matchId: String) async throws -> JoinResponse {
        try await api.request("POST", "games/matches/\(matchId)/join",
                              body: EmptyBody())
    }

    /// An invite the caller has received but not joined. Drives the home-screen banners.
    ///
    /// DECODED BY HAND, and it has to be. Swift's synthesized `Decodable` ignores property
    /// default values: with the synthesized conformance every one of `overs`, `sent_at`,
    /// `expires_at` and `missed` throws `keyNotFound` the moment the server omits it, one throw
    /// fails the whole array, and the poll's `try?` swallows it — the user just never sees a
    /// banner again, with nothing anywhere to say why. Android's kotlinx defaults DO apply, so
    /// the same payload would work there and the two platforms would diverge silently.
    struct PendingInvite: Decodable, Identifiable {
        let match_id: String
        let slug: String
        let name: String
        var icon_key: String?
        /// Lifted out of the options bag by the server; 0 when the game has no such setting.
        var overs: Int = 0
        var inviter_id: String?
        var inviter_name: String?
        var sent_at: Int64 = 0
        var expires_at: Int64 = 0
        /// Server's verdict on whether the window has passed — not the client's clock.
        var missed: Bool = false

        var id: String { match_id }

        private enum CodingKeys: String, CodingKey {
            case match_id, slug, name, icon_key, overs
            case inviter_id, inviter_name, sent_at, expires_at, missed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Required: without these there is no invite to show or join.
            match_id = try c.decode(String.self, forKey: .match_id)
            slug     = try c.decode(String.self, forKey: .slug)
            name     = try c.decode(String.self, forKey: .name)

            icon_key      = try c.decodeIfPresent(String.self, forKey: .icon_key)
            overs         = try c.decodeIfPresent(Int.self,    forKey: .overs) ?? 0
            inviter_id    = try c.decodeIfPresent(String.self, forKey: .inviter_id)
            inviter_name  = try c.decodeIfPresent(String.self, forKey: .inviter_name)
            sent_at       = try c.decodeIfPresent(Int64.self,  forKey: .sent_at) ?? 0
            expires_at    = try c.decodeIfPresent(Int64.self,  forKey: .expires_at) ?? 0
            missed        = try c.decodeIfPresent(Bool.self,   forKey: .missed) ?? false
        }
    }

    private struct InvitesResponse: Decodable { let invites: [PendingInvite] }

    /// Invites waiting on the caller: live ones to accept, missed ones to acknowledge.
    func invites() async throws -> [PendingInvite] {
        let res: InvitesResponse = try await api.request("GET", "games/invites")
        return res.invites
    }

    /// Decline an invite, or abandon a lobby nobody joined. Same call for both — they are the same
    /// state change (a 'waiting' match that will never start).
    @discardableResult
    func decline(matchId: String) async throws -> JoinResponse {
        try await api.request("POST", "games/matches/\(matchId)/decline", body: EmptyBody())
    }

    /// Tell the server a player is deliberately backing out of a LIVE match screen — as
    /// opposed to `decline`, which is for a match that never started. Without this a
    /// continuous game's tick loop had nothing telling it a player left, so backing out of
    /// Snake left the match ticking (and broadcasting `game_state` at full rate) for up to its
    /// full duration. See docs/GAMES_SNAKE_BUGS.md.
    ///
    /// Fire-and-forget from the caller's perspective — `GamesEngine.leave()` clears local
    /// state unconditionally regardless of whether this network call lands, exactly like
    /// every other "tell the server, but don't block the UI on it" pattern in this app.
    @discardableResult
    func leave(matchId: String) async throws -> JoinResponse {
        try await api.request("POST", "games/matches/\(matchId)/leave", body: EmptyBody())
    }

    /// Play the same people again, at the same settings.
    ///
    /// Mints a NEW match rather than reopening the finished one: the old row holds a result the
    /// leaderboard already counted, and rewriting it would change something a player has seen.
    /// The server re-checks permission exactly as it does for a fresh invite, so a stale match
    /// id is not a bypass.
    ///
    /// Returns the new match id, which the caller opens exactly as it would after `create`.
    func rematch(matchId: String) async throws -> CreateResponse {
        try await api.request("POST", "games/matches/\(matchId)/rematch", body: EmptyBody())
    }

    /// One row of `GET /games/matches` — the caller's own recent matches, newest first.
    ///
    /// THE SERVER SENDS IDS, NOT NAMES. The route selects `m.id, g.slug, g.name, m.status,
    /// m.player_ids, m.winner_id, m.created_at, m.started_at, m.ended_at` and joins nothing
    /// else, so there is no opponent display name in this payload and none is invented here.
    /// The history screen resolves the other player id against `leaderboard()`, which is the
    /// one call that does carry `full_name`/`username`, and falls back to nothing rather than
    /// showing a raw uuid.
    ///
    /// DECODED BY HAND for the same reason `PendingInvite` is: Swift's synthesized `Decodable`
    /// ignores property defaults, so a single omitted key (`winner_id` on an unfinished match,
    /// `ended_at` on a live one — both routinely null here) would throw `keyNotFound`, fail the
    /// whole array, and turn a full history into an empty one with nothing to say why.
    struct MatchRow: Decodable, Identifiable {
        let id: String
        let slug: String
        let name: String
        /// 'waiting' | 'active' | 'finished' | 'abandoned'. Only 'finished' has a result.
        var status: String = ""
        /// Everyone in the match, the caller included. Two entries for the duel games.
        var player_ids: [String] = []
        /// Null on a draw AND on anything unfinished — the two are told apart by `status`,
        /// never by this field alone.
        var winner_id: String?
        /// Timestamps arrive as ISO-8601 strings from pg's json encoding, not epoch numbers
        /// (contrast `PendingInvite.sent_at`, which the invites route computes as millis).
        var created_at: String?
        var started_at: String?
        var ended_at: String?

        private enum CodingKeys: String, CodingKey {
            case id, slug, name, status, player_ids, winner_id
            case created_at, started_at, ended_at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Required: without these there is no row to render or identify.
            id   = try c.decode(String.self, forKey: .id)
            slug = try c.decode(String.self, forKey: .slug)
            name = try c.decode(String.self, forKey: .name)

            status     = try c.decodeIfPresent(String.self,   forKey: .status) ?? ""
            player_ids = try c.decodeIfPresent([String].self, forKey: .player_ids) ?? []
            winner_id  = try c.decodeIfPresent(String.self,   forKey: .winner_id)
            created_at = try c.decodeIfPresent(String.self,   forKey: .created_at)
            started_at = try c.decodeIfPresent(String.self,   forKey: .started_at)
            ended_at   = try c.decodeIfPresent(String.self,   forKey: .ended_at)
        }

        /// The other player, from the caller's seat. Nil for a solo run (Snake, the daily),
        /// which genuinely has no opponent — not a lookup failure.
        func opponentId(me: String?) -> String? {
            guard let me else { return nil }
            return player_ids.first { $0 != me }
        }
    }

    private struct MatchesResponse: Decodable { let matches: [MatchRow] }

    /// The caller's recent matches, newest first, capped at 50 by the server.
    ///
    /// TAKES NO PARAMETERS, because the route accepts none — no game filter, no paging cursor,
    /// no limit override. Adding a query string here would be inventing a contract the server
    /// does not implement, so callers filter client-side over the 50 rows they get.
    func matches() async throws -> [MatchRow] {
        let res: MatchesResponse = try await api.request("GET", "games/matches")
        return res.matches
    }

    // ── LUDO SCHEMA V2 (LUDO_GAME_SPEC.md §7.1) ─────────────────────────────────────────

    /// Create a Ludo match from a chat conversation. The SERVER re-verifies membership,
    /// blocks and exact counts; the client list is convenience only.
    func createLudo(
        mode: String,
        opponentIds: [String],
        conversationId: String,
        idempotencyKey: String? = nil,
    ) async throws -> CreateResponse {
        try await api.request("POST", "games/matches", body: LudoCreateBody(
            mode: mode,
            opponent_ids: opponentIds,
            conversation_id: conversationId,
            idempotency_key: idempotencyKey ?? UUID().uuidString,
            options: ["mode": mode]))
    }

    struct LudoSnapshot {
        let seq: Int
        let payload: [String: Any]
    }

    /** Durable truth for one match, projected for THIS viewer (§9). */
    func ludoSnapshot(matchId: String) async throws -> LudoSnapshot {
        let env = try await api.request("GET", "games/matches/\(matchId)/snapshot",
                                        as: LudoSnapshotEnvelope.self)
        return LudoSnapshot(seq: env.seq,
                            payload: (env.payload.value as? [String: Any]) ?? [:])
    }

    /** Deliberate exit from an ACTIVE match; backgrounding is never this call (§11.5). */
    @discardableResult
    func forfeit(matchId: String) async throws -> JoinResponse {
        try await api.request("POST", "games/matches/\(matchId)/forfeit", body: EmptyBody())
    }

    /// Persist the first-run walkthrough seen version cross-device (§10). Fire-and-forget.
    struct WalkthroughBody: Encodable { let version: Int }
    @discardableResult
    func setWalkthroughSeen(version: Int) async throws -> JoinResponse {
        try await api.request("PUT", "users/me/preferences/ludo-walkthrough",
                              body: WalkthroughBody(version: version))
    }

    struct LudoCreateBody: Encodable {
        let slug = "ludo"
        let mode: String
        let opponent_ids: [String]
        let conversation_id: String
        let idempotency_key: String?
        let options: [String: String]
    }

    private struct EmptyBody: Encodable {}
}

/// Untyped-but-decodable envelope so a game-owned snapshot payload can flow through the
/// typed pipeline into LudoWireParser.
struct LudoSnapshotEnvelope: Decodable {
    let seq: Int
    let payload: JSONAny
}

struct JSONAny: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode([String: JSONAny].self) {
            var out: [String: Any] = [:]
            for (k, v) in d { out[k] = v.value }
            value = out
            return
        }
        if let arr = try? c.decode([JSONAny].self) {
            value = arr.map { $0.value }
            return
        }
        if let b = try? c.decode(Bool.self) { value = b; return }
        if let n = try? c.decode(Double.self) { value = n; return }
        if let s = try? c.decode(String.self) { value = s; return }
        value = NSNull()
    }

    var anyDictionary: [String: Any] {
        (value as? [String: Any]) ?? [:]
    }

    var normalized: Any {
        if let d = value as? Double, d == d.rounded() { return Int(d) }
        return value
    }
}
