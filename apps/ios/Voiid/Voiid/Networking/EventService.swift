//
//  EventService.swift
//  Voiid
//
//  Client for community events and ticketing (plan item 3.23). Like tournaments, the backend
//  shipped complete — events, orders, tickets, rotating QR codes, check-in — and neither app
//  referenced it, so no user could see an event existed.
//
//  ── FREE EVENTS ONLY, TODAY ──────────────────────────────────────────────────────
//  `POST /events/:id/orders` answers **501 for a paid event**: the payment provider is not
//  wired up. That is a real, current server state, so this client says so plainly rather than
//  offering an RSVP button that cannot work. When payments land, the paid branch of the same
//  endpoint starts answering and the client needs the checkout handoff added here.
//
//  ── WHAT IS AND IS NOT PRIVATE ───────────────────────────────────────────────────
//  An event is server-readable by construction: the server has to hold capacity, orders and
//  check-in state to enforce any of them. It is scoped to the community and gated on
//  membership, but it is NOT end-to-end encrypted, and nothing in this flow implies it is.
//

import Foundation

@MainActor
final class EventService {
    static let shared = EventService()
    private let api = APIClient()

    private init() {}

    /// One event, as the list endpoint returns it. Optionals throughout: Swift's `Codable`
    /// throws `keyNotFound` on an absent key, so a required field would turn one changed
    /// server field into a screen that fails to load.
    struct Event: Decodable, Identifiable, Equatable {
        let id: String
        let title: String
        let description: String?
        let starts_at: String?
        let ends_at: String?
        let location_text: String?
        let capacity: Int?
        /// Price in the currency's minor unit (paise, cents). 0 means free.
        let price_minor: Int?
        let currency: String?
        /// draft | published | cancelled — only `published` takes orders.
        let status: String?
        let is_free: Bool?
        /// Your existing order, if any: pending | paid | refunded | cancelled.
        let your_order_status: String?

        /// Trust the server's own verdict when it sends one, and fall back to the price only
        /// when it does not — the two cannot disagree, but the server is the authority.
        var free: Bool { is_free ?? ((price_minor ?? 0) == 0) }
    }

    private struct ListResponse: Decodable { let events: [Event]? }

    func list(communityId: String) async throws -> [Event] {
        let r = try await api.request("GET", "communities/\(communityId)/events",
                                      as: ListResponse.self)
        return r.events ?? []
    }

    /// Claim a ticket. Quantity is fixed at 1 here: multi-ticket ordering is a real server
    /// capability (up to 10) but it needs a quantity picker and a paid flow to be worth
    /// anything, and neither exists yet.
    func rsvp(eventId: String) async throws {
        struct Body: Encodable { let quantity: Int }
        _ = try await api.request("POST", "events/\(eventId)/orders",
                                  body: Body(quantity: 1), as: EmptyResponse.self)
    }
}
