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
        /// Taken off sale by a moderator. SEPARATE from `status`, which is the host's own
        /// decision — a suspended event is still 'published' and returns to sale unchanged.
        /// Optional because an older server does not send it; absent means not suspended.
        let suspended: Bool?

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

// MARK: - Hosting
//
// The organiser's half of the same router. Every call below is admin-gated ON THE SERVER by
// `communityAccess(..., needsAdmin: true)`; the client hides these controls for convenience
// and is never the enforcement. A member who found a way to call them still gets a 403.
extension EventService {

    /// What `POST /communities/:id/events` and `POST /events/:id/publish|cancel` return.
    /// Nested under `event`, so it is unwrapped here rather than in every caller.
    private struct EventEnvelope: Decodable { let event: Event? }

    /// The create body. Only `title` and `starts_at` are required by the route; the rest are
    /// nil-able and encoded as explicit nulls, which the server reads identically to absent.
    ///
    /// `price_minor` IS ALWAYS 0 HERE. The route refuses a priced event with a 501 while no
    /// payment provider is configured, so the create screen does not offer a price field at
    /// all — see the header. When payments land, this gains a price and the screen a picker.
    struct EventDraft: Encodable {
        var title: String
        var description: String?
        /// ISO-8601. The server parses with `new Date(...)` and 400s on anything it cannot.
        var starts_at: String
        var ends_at: String?
        var location_text: String?
        /// Nil means unlimited. The server requires a positive whole number when present.
        var capacity: Int?
        let price_minor: Int = 0
        let currency: String = "INR"
        /// True creates the event already `published`; false leaves it a `draft`, which only
        /// organisers can see.
        var publish: Bool
    }

    /// Create an event. 201 with the new event; 403 if you do not run this community.
    func create(communityId: String, draft: EventDraft) async throws -> Event? {
        let r = try await api.request("POST", "communities/\(communityId)/events",
                                      body: draft, as: EventEnvelope.self)
        return r.event
    }

    /// draft → published. 409 if the event is not a draft — the server owns that transition
    /// and this client does not pre-check it, because the list it is looking at is stale.
    func publish(eventId: String) async throws -> Event? {
        let r = try await api.request("POST", "events/\(eventId)/publish", as: EventEnvelope.self)
        return r.event
    }

    /// draft|published → cancelled. Tickets are NOT voided and nothing is refunded: the
    /// server says so in its response note, and a cancel button that silently moved other
    /// people's money would be the wrong button.
    func cancel(eventId: String) async throws -> Event? {
        let r = try await api.request("POST", "events/\(eventId)/cancel", as: EventEnvelope.self)
        return r.event
    }

    /// One row of `GET /events/:id/orders` — the organiser's attendee list.
    struct Order: Decodable, Identifiable, Equatable {
        let id: String
        let buyer_id: String?
        let full_name: String?
        let username: String?
        let quantity: Int?
        let amount_minor: Int?
        let currency: String?
        /// pending | paid | cancelled | refunded.
        let status: String?
        let provider: String?
        let created_at: String?
        let tickets: Int?
        let checked_in: Int?

        /// The server returns ids and may return neither name; "Someone" is the honest
        /// fallback rather than an id nobody can read.
        var display: String {
            if let n = full_name, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
            if let u = username, !u.isEmpty { return "@\(u)" }
            return "Someone"
        }
    }

    private struct OrdersResponse: Decodable { let orders: [Order]? }

    /// The attendee list. Organiser only; a member gets 403.
    func orders(eventId: String) async throws -> [Order] {
        let r = try await api.request("GET", "events/\(eventId)/orders", as: OrdersResponse.self)
        return r.orders ?? []
    }

    /// What the door gets back. A refusal is a 4xx with a `reason`, which the caller reads
    /// off `APIError.http`'s message — the reasons are written for the volunteer holding the
    /// scanner ("expired, ask them to refresh" vs "this is not one of ours").
    struct CheckIn: Decodable {
        let ok: Bool?
        let ticket_id: String?
        let holder_name: String?
        let checked_in_at: String?
        /// Present only on a refusal. See `CheckInRefusal`.
        var reason: String?
        /// The refusal in words, resolved from `reason`. Nil on a success.
        var message: String?
    }

    /// Why a check-in was refused, in the door's own vocabulary.
    ///
    /// A REFUSAL IS A NON-2xx CARRYING `reason`, NOT `error` — which is the one place this
    /// router departs from the shape `APIClient` decodes, so the raw message would come back
    /// as "Request failed (409)." and tell the volunteer at the door nothing. The reasons are
    /// deliberately distinct because they are DIFFERENT CONVERSATIONS at a door: "ask them to
    /// refresh" is not "this is not one of ours".
    enum CheckInRefusal: String {
        case expired
        case bad_signature
        case malformed
        case wrong_event
        case not_found
        case superseded
        case void
        case unpaid
        case already_checked_in

        var message: String {
            switch self {
            case .expired:           return "That code has expired \u{2014} ask them to refresh it."
            case .bad_signature,
                 .malformed:         return "That isn't a Voiid ticket code."
            case .wrong_event:       return "That ticket is for a different event."
            case .not_found:         return "No ticket matches that code."
            case .superseded:        return "That code was replaced \u{2014} ask them to refresh it."
            case .void:              return "That ticket is no longer valid."
            case .unpaid:            return "That order isn't confirmed."
            case .already_checked_in: return "Already checked in."
            }
        }
    }

    /// Redeem a ticket code at the door. The server verifies the signature, the nonce, the
    /// ticket state, the order state AND that the code belongs to this event — none of which
    /// is checked here, because a door that trusted a signature would honour a revoked ticket.
    ///
    /// Throws `APIError` for a transport or auth failure; returns a `CheckIn` with `ok == nil`
    /// and a populated `reason` for a refusal, because a refused ticket is an ANSWER the door
    /// needs to read, not an exception it needs to recover from.
    /// A ticket in the holder's own wallet.
    struct Ticket: Decodable, Identifiable {
        let id: String
        let event_id: String
        let state: String
        let checked_in_at: String?
        let title: String?
        let starts_at: String?
        let location_text: String?
        let event_status: String?
        let order_status: String?
        let community_id: String?

        var isCheckedIn: Bool { checked_in_at != nil }
        /// The server refuses to mint a code for any of these, so the wallet must not offer
        /// one either — a button that only ever 409s is worse than no button.
        var canShowCode: Bool {
            state == "valid" && order_status == "paid" && event_status != "cancelled"
        }
    }

    /// Every ticket this account holds. `GET /my/event-tickets` shipped complete and had no
    /// caller: an attendee could claim a ticket and never see it again.
    func myTickets() async throws -> [Ticket] {
        struct Envelope: Decodable { let tickets: [Ticket] }
        let env: Envelope = try await api.request("GET", "my/event-tickets")
        return env.tickets
    }

    /// A short-lived signed code for the door.
    ///
    /// Minted per request rather than stored, and the expiry is the server's — the wallet
    /// re-mints as it approaches rather than showing a code that has quietly gone stale in
    /// front of a scanner.
    struct TicketCode: Decodable {
        let code: String
        let expires_at: String
        let ticket_id: String
    }

    func code(ticketId: String) async throws -> TicketCode {
        try await api.request("GET", "event-tickets/\(ticketId)/code")
    }

    /// Revoke a leaked code. The old one stops verifying the moment this returns.
    func rotate(ticketId: String) async throws {
        struct EmptyBody: Encodable {}
        _ = try await api.request("POST", "event-tickets/\(ticketId)/rotate",
                                  body: EmptyBody(), as: EmptyResponse.self)
    }

    func checkIn(eventId: String, code: String) async throws -> CheckIn {
        struct Body: Encodable { let code: String }
        do {
            return try await api.request("POST", "events/\(eventId)/check-in",
                                         body: Body(code: code), as: CheckIn.self)
        } catch let APIError.http(status, message, _) where (400..<500).contains(status) {
            // The refusal body is `{ ok: false, reason, checked_in_at? }`. `APIClient` looked
            // for `error`, did not find it, and synthesised "Request failed (409).", so the
            // reason is re-read from the wire shape here rather than lost.
            let reason = CheckInRefusal(rawValue: message)
            return CheckIn(ok: false, ticket_id: nil,
                           holder_name: nil, checked_in_at: nil,
                           reason: reason?.rawValue,
                           message: reason?.message)
        }
    }
}
