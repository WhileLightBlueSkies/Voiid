//
//  TournamentService.swift
//  Voiid
//
//  Client for the tournament API (plan item 3.22). The backend shipped complete — brackets,
//  seeding, registration, standings — and nothing on either app referenced it, so no user
//  could see a tournament existed. This is the half that makes it reachable.
//
//  ── NOT E2EE, AND THAT IS THE DESIGN ─────────────────────────────────────────────
//  A bracket is a shared public structure inside a community: the server seeds it, advances
//  it and decides who won, which it can only do by reading it. Game MOVES are refereed by
//  `backend/games`; the bracket around them is ordinary server state, exactly like the
//  community container itself. Nothing on this screen claims otherwise.
//
//  ── MEMBERSHIP IS THE GATE ───────────────────────────────────────────────────────
//  Every endpoint here is community-scoped and the server checks membership on each one; a
//  non-member gets 403 rather than an empty list. This client does not pre-filter on top of
//  that — one authority, not two.
//

import Foundation

@MainActor
final class TournamentService {
    static let shared = TournamentService()
    private let api = APIClient()

    private init() {}

    /// One tournament, as the list and detail endpoints both return it.
    ///
    /// Every field the server may omit is optional. Swift's `Codable` throws `keyNotFound`
    /// on an absent key, so a required field here would turn one added-or-removed server
    /// field into a screen that fails to load rather than one that renders slightly less.
    struct Tournament: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        /// single_elim | double_elim | round_robin — decides what the bracket looks like.
        let format: String?
        /// draft | registering | running | finished | cancelled.
        let status: String?
        let game_name: String?
        let game_slug: String?
        let max_players: Int?
        let player_count: Int?
        let starts_at: String?
        let winner_user_id: String?
        /// Whether YOU are on the roster — decides Register vs Withdraw.
        let registered: Bool?
    }

    private struct ListResponse: Decodable { let tournaments: [Tournament]? }

    func list(communityId: String) async throws -> [Tournament] {
        let r = try await api.request("GET", "communities/\(communityId)/tournaments",
                                      as: ListResponse.self)
        return r.tournaments ?? []
    }

    func detail(id: String) async throws -> Tournament {
        try await api.request("GET", "tournaments/\(id)", as: Tournament.self)
    }

    /// Join the roster. The server owns capacity and the registration window, so a full or
    /// closed tournament is refused there — this client does not gate on `player_count`,
    /// which it read some seconds ago and which several people may be racing to fill.
    func register(id: String) async throws {
        _ = try await api.request("POST", "tournaments/\(id)/register", as: EmptyResponse.self)
    }

    func withdraw(id: String) async throws {
        _ = try await api.request("POST", "tournaments/\(id)/withdraw", as: EmptyResponse.self)
    }
}
