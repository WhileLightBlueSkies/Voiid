//
//  GameLobbyAPI.swift
//  Voiid
//
//  The PARTY lobby (database/migrations/052_game_lobbies.sql, backend/api routes/games.ts).
//
//  ── A SECOND LOBBY SHAPE, NOT A REPLACEMENT ─────────────────────────────────────
//  `GamesAPI` covers the DIRECT invite: create a match naming its seats, the invitee accepts,
//  the match starts when the last named seat is filled. `Games/GameLobbyView.swift` renders
//  that, it still works, and it is untouched.
//
//  This file covers the other thing: a lobby a HOST deliberately opens on a match, which adds
//  the three facts the invite path structurally cannot carry — per-member ready-states, a join
//  code for someone who was never named in `player_ids`, and a chat while you wait.
//
//  WHICH SCREEN THE CLIENT SHOWS: the party lobby iff `GET /games/matches/:id/lobby` returns a
//  lobby (404 means the host never opened one), otherwise the existing 1:1 invite-and-wait
//  view. One fact decides it, so the two can never both claim the screen.
//
//  ── SEPARATE FILE, NOT AN EXTENSION OF GamesAPI ─────────────────────────────────
//  GamesAPI is the match lifecycle and is read by every game. The lobby is one screen's
//  surface with its own models, its own live channel and its own authorization story
//  (server-readable chat). Folding eight routes and six DTOs into GamesAPI would make the file
//  that Ludo, Snake and Cricket all depend on carry a party screen's vocabulary.
//
//  ── EVERY DECODABLE FIELD IS OPTIONAL OR DEFAULTED, AND DECODED BY HAND ─────────
//  Same rule, and the same scar, as `GamesAPI.PendingInvite` and `GamesAPI.MatchRow`: Swift's
//  synthesized `Decodable` IGNORES property default values, so one absent key throws
//  `keyNotFound`, one throw fails the whole payload, and a `try?` upstream turns that into a
//  screen that is silently and permanently empty with nothing anywhere to say why. That has
//  bitten this codebase twice. Only the ids that make a row identifiable are `decode`d; every
//  other field is `decodeIfPresent` with a default.
//

import Foundation

struct GameLobbyAPI {
    private let api = APIClient()

    // MARK: - Models

    /// The lobby row itself: who hosts it, how to get in, and the host's chosen options.
    struct Lobby: Decodable {
        let match_id: String
        /// Who may start the match and whose departure ends the party. Compared against
        /// `TokenStore.shared.userId` rather than trusted from an `is_host` the client could
        /// not verify — though the server sends that too, and they must agree.
        var host_user_id: String = ""
        /// Nil only if the server ever stops minting one. Rendered as the copyable team code.
        var join_code: String?
        /// A private lobby refuses its own code — the flag is checked first, server-side.
        var is_public: Bool = false
        /// Host-set free text (the reference's "3 overs"). Empty means the game has no such
        /// setting; nothing is invented to fill the line.
        var format: String?
        /// Start with empty seats rather than blocking on one nobody claimed. It relaxes the
        /// SEAT count only — every member present must still be ready.
        var fill_empty: Bool = false
        /// From `games.max_players` in the catalog, never from this client. It is what makes
        /// "full" a fact rather than an opinion.
        var max_players: Int = 0
        /// Epoch millis once the host has started. Non-nil means the lobby is history.
        var started_at: Int64?
        var created_at: Int64 = 0

        private enum CodingKeys: String, CodingKey {
            case match_id, host_user_id, join_code, is_public, format
            case fill_empty, max_players, started_at, created_at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The one genuinely required field: without it there is no lobby to address.
            match_id = try c.decode(String.self, forKey: .match_id)

            host_user_id = try c.decodeIfPresent(String.self, forKey: .host_user_id) ?? ""
            join_code    = try c.decodeIfPresent(String.self, forKey: .join_code)
            is_public    = try c.decodeIfPresent(Bool.self,   forKey: .is_public) ?? false
            format       = try c.decodeIfPresent(String.self, forKey: .format)
            fill_empty   = try c.decodeIfPresent(Bool.self,   forKey: .fill_empty) ?? false
            max_players  = try c.decodeIfPresent(Int.self,    forKey: .max_players) ?? 0
            started_at   = try c.decodeIfPresent(Int64.self,  forKey: .started_at)
            created_at   = try c.decodeIfPresent(Int64.self,  forKey: .created_at) ?? 0
        }
    }

    /// One person in the lobby.
    ///
    /// THE SERVER NAMES THEM, unlike `GamesAPI.MatchRow` which sends bare ids for the client to
    /// resolve. It has to: a join-code member is by definition someone the viewer may never
    /// have messaged, so the local contact directory cannot name them and the roster would
    /// render as raw uuids.
    struct Member: Decodable, Identifiable {
        let user_id: String
        /// "waiting" | "ready". A value this client does not recognize reads as waiting, which
        /// is the safe direction — it never claims someone is ready who is not.
        var state: String = "waiting"
        /// STORED INTENT ONLY. There is NO VOICE TRANSPORT behind this flag anywhere in Voiid:
        /// no lobby audio room, no SFU, nothing. The migration and the route both say so. The
        /// mic glyph the reference draws must therefore never be presented as live audio — see
        /// `PartyMember.micOn` in ReferenceGamesModels for how that is honoured on screen.
        var mic_on: Bool = false
        /// Which seat they took, when the game cares (Ludo's colours). Nil is a plain slot.
        var seat: Int?
        /// Display name or @username, already resolved server-side. Nil for a deleted account.
        var name: String?
        var username: String?
        var joined_at: Int64 = 0

        var id: String { user_id }
        var isReady: Bool { state == "ready" }

        private enum CodingKeys: String, CodingKey {
            case user_id, state, mic_on, seat, name, username, joined_at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            user_id = try c.decode(String.self, forKey: .user_id)

            state     = try c.decodeIfPresent(String.self, forKey: .state) ?? "waiting"
            mic_on    = try c.decodeIfPresent(Bool.self,   forKey: .mic_on) ?? false
            seat      = try c.decodeIfPresent(Int.self,    forKey: .seat)
            name      = try c.decodeIfPresent(String.self, forKey: .name)
            username  = try c.decodeIfPresent(String.self, forKey: .username)
            joined_at = try c.decodeIfPresent(Int64.self,  forKey: .joined_at) ?? 0
        }
    }

    /// One lobby chat line.
    ///
    /// NOT E2EE, and deliberately so — see the migration header. Ephemeral, dies with the
    /// match, and its members may hold no ratchet session with one another. Nothing about this
    /// applies to the message pipe, which is unchanged.
    struct Message: Decodable, Identifiable {
        let id: String
        /// Nil when the author's account was deleted (the schema's ON DELETE SET NULL). The
        /// message is neither hidden nor rewritten — other people were part of that exchange.
        var user_id: String?
        var name: String?
        var body: String = ""
        var created_at: Int64 = 0

        private enum CodingKeys: String, CodingKey {
            case id, user_id, name, body, created_at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Sent as a string by the route (bigserial does not fit a JS number safely), but an
            // older or future server sending a number must not fail the whole chat.
            if let s = try? c.decode(String.self, forKey: .id) {
                id = s
            } else if let n = try? c.decode(Int64.self, forKey: .id) {
                id = String(n)
            } else {
                id = UUID().uuidString
            }
            user_id    = try c.decodeIfPresent(String.self, forKey: .user_id)
            name       = try c.decodeIfPresent(String.self, forKey: .name)
            body       = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
            created_at = try c.decodeIfPresent(Int64.self,  forKey: .created_at) ?? 0
        }
    }

    /// The whole screen in one payload: `GET` and `POST /lobby` both answer in this shape.
    struct LobbySnapshot: Decodable {
        let lobby: Lobby
        var members: [Member] = []
        var messages: [Message] = []
        /// The server's own verdict, kept alongside the derived one. They must agree; if they
        /// ever do not, the server is right — it is the only side that authorizes anything.
        var is_host: Bool = false
        var is_member: Bool = false

        private enum CodingKeys: String, CodingKey {
            case lobby, members, messages, is_host, is_member
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lobby     = try c.decode(Lobby.self, forKey: .lobby)
            members   = try c.decodeIfPresent([Member].self,  forKey: .members) ?? []
            messages  = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
            is_host   = try c.decodeIfPresent(Bool.self, forKey: .is_host) ?? false
            is_member = try c.decodeIfPresent(Bool.self, forKey: .is_member) ?? false
        }
    }

    /// `POST /games/lobbies/join` — the code path answers with the match id it resolved to.
    struct JoinByCodeResponse: Decodable {
        let match_id: String
        var lobby: Lobby?
        var members: [Member] = []

        private enum CodingKeys: String, CodingKey { case match_id, lobby, members }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            match_id = try c.decode(String.self, forKey: .match_id)
            lobby    = try c.decodeIfPresent(Lobby.self, forKey: .lobby)
            members  = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        }
    }

    struct MembersResponse: Decodable {
        var members: [Member] = []
        private enum CodingKeys: String, CodingKey { case members }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        }
    }

    struct MessageResponse: Decodable {
        let message: Message
    }

    struct LeaveResponse: Decodable {
        var ok: Bool = true
        /// True when the HOST left and the whole party was ended — see the route's comment for
        /// why a host's departure cancels rather than transfers. The screen must dismiss on
        /// this, not merely remove a row.
        var cancelled: Bool = false

        private enum CodingKeys: String, CodingKey { case ok, cancelled }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok        = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
            cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        }
    }

    struct StartResponse: Decodable {
        var ok: Bool = true
        var match_id: String = ""
        var started_at: Int64?

        private enum CodingKeys: String, CodingKey { case ok, match_id, started_at }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok         = try c.decodeIfPresent(Bool.self,   forKey: .ok) ?? true
            match_id   = try c.decodeIfPresent(String.self, forKey: .match_id) ?? ""
            started_at = try c.decodeIfPresent(Int64.self,  forKey: .started_at)
        }
    }

    // MARK: - Bodies

    private struct OpenBody: Encodable {
        let is_public: Bool
        let format: String?
        let fill_empty: Bool
    }
    private struct JoinCodeBody: Encodable { let join_code: String }
    private struct ReadyBody: Encodable {
        let ready: Bool
        /// Absent means UNCHANGED server-side, never false — the two toggles share a row and a
        /// ready-up must not silently mute someone.
        let mic_on: Bool?
    }
    private struct MessageBody: Encodable { let body: String }
    private struct EmptyBody: Encodable {}

    // MARK: - Routes

    /// Open a party lobby on a match the caller created. IDEMPOTENT — opening twice returns the
    /// existing lobby with its existing code, so a double-tap cannot mint a second live code.
    func open(matchId: String, isPublic: Bool, format: String?, fillEmpty: Bool)
        async throws -> LobbySnapshot
    {
        try await api.request(
            "POST", "games/matches/\(matchId)/lobby",
            body: OpenBody(is_public: isPublic, format: format, fill_empty: fillEmpty))
    }

    /// The lobby, its roster and the recent chat.
    ///
    /// Throws `APIError.http(status: 404)` when the match has NO party lobby — which is the
    /// ordinary case and the client's signal to fall back to the 1:1 invite view, not a failure
    /// to report. Pass `code` to preview a public lobby you are not yet a member of.
    func lobby(matchId: String, code: String? = nil) async throws -> LobbySnapshot {
        var path = "games/matches/\(matchId)/lobby"
        if let code, !code.isEmpty {
            let escaped = code.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? code
            path += "?code=\(escaped)"
        }
        return try await api.request("GET", path)
    }

    /// Enter a public lobby with its code. The code IS the address — the caller does not know
    /// the match id and does not need to.
    func join(code: String) async throws -> JoinByCodeResponse {
        try await api.request("POST", "games/lobbies/join",
                              body: JoinCodeBody(join_code: code))
    }

    /// The CALLER's own ready state. There is no user id parameter and there must not be one:
    /// marking someone else ready is how a host starts a match into an empty chair.
    @discardableResult
    func setReady(matchId: String, ready: Bool, micOn: Bool? = nil)
        async throws -> MembersResponse
    {
        try await api.request("POST", "games/matches/\(matchId)/lobby/ready",
                              body: ReadyBody(ready: ready, mic_on: micOn))
    }

    /// Step out. If the caller is the HOST the whole party ends (`cancelled: true`) — the route
    /// explains why that is cancel-not-transfer.
    @discardableResult
    func leave(matchId: String) async throws -> LeaveResponse {
        try await api.request("POST", "games/matches/\(matchId)/lobby/leave", body: EmptyBody())
    }

    /// Send a lobby chat line. Members only — holding the join code lets you preview a lobby,
    /// not talk in it.
    @discardableResult
    func send(matchId: String, body: String) async throws -> MessageResponse {
        try await api.request("POST", "games/matches/\(matchId)/lobby/messages",
                              body: MessageBody(body: body))
    }

    /// Host only. Requires every present member ready; `fill_empty` waives only the seat count.
    /// The board itself is built by the games service, which broadcasts the opening
    /// `game_state` — exactly as `GamesAPI.join` does.
    @discardableResult
    func start(matchId: String) async throws -> StartResponse {
        try await api.request("POST", "games/matches/\(matchId)/lobby/start", body: EmptyBody())
    }
}
