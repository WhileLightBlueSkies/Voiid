//
//  MapMoveEngine.swift
//  Voiid
//
//  Feature (B), Move — "I'm on my way to you." The traveller picks a destination; their
//  existing Map fixes start carrying it, plus a measured arrival time; the people who can
//  already see them on the Map get a live journey screen.
//
//  ── WHY THIS ADDS NOTHING TO THE SERVER ────────────────────────────────────────────────
//  It rides entirely on machinery that already exists. There is no new share kind, no new
//  route, no new column:
//    - `location.ts` refuses, in writing, to own a POST /location/update, so that a
//      coordinate can never be put in one. A destination is a FUTURE coordinate and is worse.
//    - `018_location_shares.sql` constrains `kind` to ('conversation','map'). A third kind
//      would be a server-visible "this person is travelling somewhere" signal.
//  So Move is six optional fields on `MapEnvelope`, sealed under the SAME per-share `mapKey`
//  as the fix that carries them, relayed as the same opaque ciphertext. The server learns
//  nothing it did not already relay: one blob, same size class, same cadence.
//
//  ── WHY THE ETA IS MEASURED AND NEVER GUESSED ──────────────────────────────────────────
//  MKDirections is asked for a real route from the traveller's live position to the chosen
//  destination, and re-asked as they move. Until it answers, `arrivalAt` is nil and every
//  surface says "Calculating" — there is deliberately no straight-line fallback. A fabricated
//  ETA is the one failure mode that is worse than no ETA: someone waits on a number nobody
//  measured, and the feature's entire value is that the number is true.
//
//  ── WHY NOTHING HERE IS PERSISTED ──────────────────────────────────────────────────────
//  Presence keeps exactly one fix per contact and no history, ever (§8, §10). A Move is a
//  destination, which is strictly more revealing than a position, so it gets the stricter
//  treatment: in memory only. A process death ends the Move on both sides — the traveller
//  stops sending the fields, and the viewer's copy is simply gone.
//

import Foundation
import CoreLocation
import MapKit
import Combine

@MainActor
final class MapMoveEngine: ObservableObject {

    static let shared = MapMoveEngine()

    // MARK: - Outbound (I am travelling)

    /// My own active journey, or nil. `MapPresenceEngine.emitFix` reads this to decide whether
    /// the next fix is a plain presence fix or a Move fix, which is the whole integration
    /// surface on the sending side.
    @Published private(set) var outbound: MapMoveOutbound?

    /// True while an MKDirections request is in flight and we have no route yet — the
    /// difference between "still calculating" and "we tried and could not route", which the UI
    /// must show as two distinct states rather than one indefinite spinner.
    @Published private(set) var calculating = false

    /// Set when routing FAILED (no route, no network, destination unreachable by the chosen
    /// mode). The Move stays live — the destination is still shared, the pin still moves — but
    /// the ETA reads as unavailable instead of quietly showing nothing.
    @Published private(set) var routingError: String?

    // MARK: - Inbound (someone is travelling to me)

    /// Live Moves by sender user id, newest payload wins. Populated from decrypted fixes by
    /// `MapPresenceEngine.receiveFix`; a fix that arrives WITHOUT the Move fields clears the
    /// entry, which is how "they arrived / cancelled" propagates with no extra message kind.
    @Published private(set) var inbound: [String: MapMoveInbound] = [:]

    // MARK: - Internals

    /// The in-flight route request, cancelled before each recompute so a slow response can
    /// never overwrite a newer one.
    private var directions: MKDirections?
    private var recomputeTimer: Timer?

    /// How often the route is re-measured while travelling. Deliberately slower than the fix
    /// cadence: a route is an expensive, rate-limited MapKit call, and an ETA that is 60 s old
    /// is still honest (it is absolute — the viewer's own clock keeps counting it down between
    /// recomputes). Recomputing per fix would burn the throttle and change nothing on screen.
    private static let recomputeInterval: TimeInterval = 60

    /// A Move is abandoned if no route has been recomputed in this long AND the traveller has
    /// stopped emitting — see `noteArrivedIfClose`.
    private static let arrivalRadius: CLLocationDistance = 120

    private init() {}

    // MARK: - Starting and ending a Move (traveller side)

    /// Begin a journey to `coordinate`. Does NOT touch visibility, keys, or the share
    /// lifecycle: a Move is only ever an annotation on fixes that were already being sent, so
    /// starting one while ghosted correctly shares nothing at all. The caller is responsible
    /// for making sure the user is visible to whoever they want to see it — the Move screen
    /// says so plainly rather than silently turning sharing on.
    func startMove(to coordinate: CLLocationCoordinate2D, name: String, address: String?) {
        outbound = MapMoveOutbound(destination: coordinate, name: name, address: address,
                                   startedAt: Date(), arrivalAt: nil, remainingMetres: nil)
        routingError = nil
        recomputeETA()
        // A repeating timer rather than recomputing per fix — see `recomputeInterval`.
        recomputeTimer?.invalidate()
        recomputeTimer = Timer.scheduledTimer(withTimeInterval: Self.recomputeInterval,
                                              repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recomputeETA() }
        }
    }

    /// End my journey. The very next fix goes out WITHOUT the Move fields, and that absence is
    /// what tells every viewer the journey is over — no new message kind, and it works even if
    /// a dedicated "cancelled" frame would have been lost.
    func endMove() {
        outbound = nil
        calculating = false
        routingError = nil
        directions?.cancel()
        directions = nil
        recomputeTimer?.invalidate()
        recomputeTimer = nil
    }

    /// Re-measure the route from wherever the traveller is right now. Called on a timer and
    /// whenever the Move screen appears, so an ETA is never left to rot while someone watches.
    func recomputeETA() {
        guard let move = outbound else { return }
        guard let here = MapLocationProvider.shared.lastFix else {
            // No position yet — nothing to route FROM. Not an error: the provider is still
            // warming up, and the next fix retriggers this.
            calculating = true
            return
        }

        directions?.cancel()
        calculating = true

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: move.destination))
        // Automobile is MapKit's most broadly routable mode; a walking request fails outright
        // over any distance, and a failed route means no ETA at all rather than a rough one.
        request.transportType = .automobile
        // We want the current best answer, not a menu — `expectedTravelTime` on one route.
        request.requestsAlternateRoutes = false

        let d = MKDirections(request: request)
        directions = d
        d.calculate { [weak self] response, error in
            Task { @MainActor in
                guard let self, let current = self.outbound,
                      // Discard a response for a destination we have since changed or ended.
                      current.destination.latitude == move.destination.latitude,
                      current.destination.longitude == move.destination.longitude else { return }
                self.calculating = false

                guard let route = response?.routes.first else {
                    // HONEST FAILURE. We do not fall back to distance / an assumed speed — see
                    // the file header. The Move continues; only the ETA is unavailable.
                    self.routingError = (error as? MKError)?.localizedDescription
                        ?? "Couldn’t work out a route right now."
                    return
                }
                self.routingError = nil
                var updated = current
                updated.arrivalAt = Date().addingTimeInterval(route.expectedTravelTime)
                updated.remainingMetres = route.distance
                self.outbound = updated
            }
        }
    }

    /// The traveller's own remaining distance, from the last measured route. nil until one
    /// resolves — never a straight-line stand-in.
    var outboundRemainingMetres: CLLocationDistance? { outbound?.remainingMetres }

    /// True once the traveller is within `arrivalRadius` of the destination. Used only to
    /// offer "You've arrived — end Move?"; it never ends the Move on its own, because a
    /// wrongly-auto-ended share is a promise broken without the user's say-so.
    func hasArrived(at coordinate: CLLocationCoordinate2D) -> Bool {
        guard let move = outbound else { return false }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let dest = CLLocation(latitude: move.destination.latitude,
                              longitude: move.destination.longitude)
        return here.distance(from: dest) <= Self.arrivalRadius
    }

    // MARK: - Inbound (viewer side)

    /// Record the Move carried on a decrypted fix — or CLEAR it when that fix carries none.
    ///
    /// The clear is load-bearing: it is how a viewer learns the journey ended, using only
    /// frames that were already flowing. Absence is the signal, so there is nothing extra to
    /// lose in transit.
    func ingest(_ env: MapEnvelope, fromUserId: String, shareId: String) {
        guard let dlat = env.dlat, let dlon = env.dlon, let mstart = env.mstart else {
            if inbound[fromUserId] != nil { inbound[fromUserId] = nil }
            return
        }
        inbound[fromUserId] = MapMoveInbound(
            senderUserId: fromUserId,
            shareId: shareId,
            destination: CLLocationCoordinate2D(latitude: dlat, longitude: dlon),
            name: env.dname,
            address: env.daddr,
            // nil while the sender's own MKDirections is still calculating — passed through as
            // nil so the viewer shows "Calculating ETA" rather than a number nobody measured.
            arrivalAt: env.eta.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
            startedAt: Date(timeIntervalSince1970: TimeInterval(mstart) / 1000),
            receivedAt: Date())
    }

    /// Forget a sender's Move entirely — called when their share stops or is revoked, so a
    /// journey never outlives the presence it was attached to.
    func forget(senderUserId: String) {
        if inbound[senderUserId] != nil { inbound[senderUserId] = nil }
    }

    func forgetAll() { inbound = [:] }

    /// The Move a given contact is on, if any.
    func move(from senderUserId: String) -> MapMoveInbound? { inbound[senderUserId] }
}
