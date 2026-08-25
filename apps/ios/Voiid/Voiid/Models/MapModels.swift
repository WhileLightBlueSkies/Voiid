//
//  MapModels.swift
//  Voiid
//
//  Feature (B) — The Map. The data types behind a Snapchat-Map-style surface that
//  shows ONLY the contacts who have explicitly chosen to be visible to you, and behind
//  your own opt-in visibility (which is OFF — "ghost" — until you name individuals).
//
//  These types are deliberately SEPARATE from the in-conversation live-share types owned
//  by the location workstream (Feature (A)). The two features share a protocol substrate
//  (a fresh random shareKey per share; fixes streamed as `encryptBackup(shareKey, fix)`
//  over the WS relay; a versioned self-describing plaintext envelope) but never share a
//  key or a share id at runtime, so keeping the map's model surface in its own file keeps
//  the two workstreams from colliding on a shared symbol.
//
//  THE PRIVACY RULE, restated where it bites: a coordinate is rounded HERE, on the
//  sending device, before it is ever encrypted — to 3 decimals (~110 m) for Map presence,
//  which is coarse on purpose (§5). The rounded coordinate is then sealed under a per-share
//  key with `encryptBackup`; the server only ever relays the ciphertext.
//

import Foundation
import CoreLocation

// MARK: - Envelope

/// The plaintext of a map control- or fix-message. Versioned and self-describing because
/// no AEAD here accepts AAD: the discriminator and the share id live INSIDE the
/// authenticated plaintext, where GCM covers them.
///
/// `_vloc == 1` is the envelope discriminator. It is what makes a location message safe to
/// distinguish from a plain text body even on the group/MLS path where `content_type` is
/// always `"group"`. The map uses only three of the envelope kinds:
///   - `map_key` : a durable control message carrying a fresh `key` + `expiresAt` + `cadence`.
///                 This is where authorization actually happens — only a device with a live
///                 ratchet session receives the key, and the server never sees it.
///   - `map_off` : a durable control message that ends your visibility to that recipient.
///   - `fix`     : one coarse position update, streamed over the WS relay (never a message row).
struct MapEnvelope: Codable {
    // Optionals carry explicit `= nil` defaults so the synthesized memberwise initializer
    // lets each call site pass only the fields that kind needs (a fix omits key/cadence; a
    // map_key omits lat/lon).
    // Optional so a decode SUCCEEDS when `_vloc` is absent from the wire. Android omits it
    // (encodeDefaults=false); a non-optional property makes Swift's synthesized decoder THROW
    // on the missing key (it does NOT fall back to the default), which silently dropped every
    // Android-sent fix on iOS. `k` is the real discriminator. Still emitted as 1 when we send.
    var vloc: Int? = 1
    var k: String            // "map_key" | "map_off" | "fix"
    var s: String? = nil     // share_id (uuid)
    var t: Int64? = nil      // millis
    var lat: Double? = nil
    var lon: Double? = nil
    var acc: Double? = nil
    // Int64 (not Int) to match Android's `Long` exactly. The whole guard chain in
    // receiveFix() hard-requires `n`, and a decode throw there returns silently with no log,
    // so a width mismatch would drop every fix from that peer invisibly — the same failure
    // shape as the t/expiresAt bug. Narrowed to the store's Int at the boundary.
    var n: Int64? = nil      // monotonic fix sequence — an out-of-order relay frame is dropped
    var expiresAt: Int64? = nil   // map_key only
    var key: String? = nil        // map_key only — base64 of the 32-byte shareKey
    var cadence: Int? = nil       // seconds; map_key only

    // MARK: Move (journey / ETA) — rides the SAME `fix` frame, under the SAME shareKey.
    //
    // WHY HERE AND NOT A NEW SHARE KIND: a destination and an arrival time are at least as
    // sensitive as the position itself — "where they will be, and when" is the one thing a
    // position trail cannot give you. Putting them on a server-visible surface would recreate
    // exactly the leak `location.ts` refuses to build (there is DELIBERATELY no
    // POST /location/update), and `018_location_shares.sql` constrains `kind` to
    // ('conversation','map') on purpose. So Move is carried entirely inside the authenticated
    // plaintext of a fix the server already relays as an opaque blob. Zero server surface.
    //
    // EVERY FIELD BELOW IS OPTIONAL WITH AN EXPLICIT `= nil`, and each is absent from the wire
    // for an ordinary (non-Move) fix. That is not tidiness — it is the fix for the two
    // documented decode bugs above: a non-optional property makes Swift's synthesized decoder
    // THROW on a missing key rather than fall back to its default, and `receiveFix` treats a
    // decode throw as "drop the frame". A required Move field would therefore have silently
    // dropped EVERY fix from every peer that isn't moving, and every fix from Android and from
    // any client older than this change.

    /// Destination latitude. Rounded to presence precision (3 dp, ~110 m) by `moveFix`, for the
    /// same reason the live coordinate is: a destination pinned to 6 dp is a doorstep.
    var dlat: Double? = nil
    /// Destination longitude. Same rounding.
    var dlon: Double? = nil
    /// Human-readable destination name ("Central Market"). Chosen by the TRAVELLER and shown
    /// verbatim to the viewer — we never reverse-geocode a coordinate on the receiving side
    /// (docs/LOCATION.md §10), so if this is absent the viewer shows no name rather than
    /// inventing one.
    var dname: String? = nil
    /// Optional street address for the destination. Optional twice over: a peer may omit it,
    /// and MapKit may not have supplied one for the place the traveller picked.
    var daddr: String? = nil
    /// ABSOLUTE epoch millis of predicted arrival — NOT a relative countdown.
    ///
    /// A "12 minutes" sent over a relay is already wrong by the time it renders, and gets more
    /// wrong the longer the frame sits; the viewer would count down from a number that stopped
    /// being true. An absolute instant is self-correcting: the viewer subtracts its own clock
    /// and is right at every frame, and a stale frame visibly decays toward zero instead of
    /// lying at a constant.
    ///
    /// Int64, NOT Int, to match Android's `Long` exactly — the same width mismatch documented
    /// on `n` and `t` above, which drops frames invisibly.
    var eta: Int64? = nil
    /// Epoch millis the journey STARTED, i.e. when the traveller began this Move. The arrival
    /// progress bar is (now - start) / (eta - start), which is why this must be on the wire:
    /// derived from the viewer's first-seen frame instead, the bar would restart at 0% every
    /// time the viewer reopened the screen. Int64 for Android's `Long`.
    var mstart: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case vloc = "_vloc"
        case k, s, t, lat, lon, acc, n, expiresAt, key, cadence
        // Move fields. Present here so they encode/decode at all — a CodingKeys enum that
        // omits a property silently drops it from BOTH directions.
        case dlat, dlon, dname, daddr, eta, mstart
    }

    enum Kind: String { case mapKey = "map_key", mapOff = "map_off", fix }
    var kind: Kind? { Kind(rawValue: k) }
}

// MARK: - Fix rounding

extension MapEnvelope {
    /// Map presence is coarse by design (§5): round to 3 decimals (~110 m) at the SOURCE,
    /// before encryption, so the precise coordinate never exists in the ciphertext at all.
    static func roundedForPresence(_ degrees: Double) -> Double {
        (degrees * 1000).rounded() / 1000
    }

    /// Build a `fix` envelope from a raw fix, rounding coordinates on the way in.
    static func presenceFix(shareId: String, seq: Int, coord: CLLocationCoordinate2D,
                            accuracy: CLLocationAccuracy) -> MapEnvelope {
        MapEnvelope(
            vloc: 1, k: Kind.fix.rawValue, s: shareId,
            t: Int64(Date().timeIntervalSince1970 * 1000),
            lat: roundedForPresence(coord.latitude),
            lon: roundedForPresence(coord.longitude),
            // Accuracy is coarsened too — a precise accuracy ring leaks precision the
            // rounded coordinate was meant to remove.
            acc: max(accuracy, 100).rounded(),
            n: Int64(seq)
        )
    }

    /// Build a `fix` envelope that ALSO carries an active Move. Identical to `presenceFix` in
    /// every existing respect — same kind, same rounding, same sequence — with the journey
    /// fields appended, so a receiver that predates Move decodes it as an ordinary fix and
    /// draws the pin exactly as before.
    static func moveFix(shareId: String, seq: Int, coord: CLLocationCoordinate2D,
                        accuracy: CLLocationAccuracy, move: MapMoveOutbound) -> MapEnvelope {
        var env = presenceFix(shareId: shareId, seq: seq, coord: coord, accuracy: accuracy)
        env.dlat = roundedForPresence(move.destination.latitude)
        env.dlon = roundedForPresence(move.destination.longitude)
        env.dname = move.name
        env.daddr = move.address
        // nil when MKDirections has not answered yet — the viewer then renders "Calculating
        // ETA" rather than a fabricated number. See MapMoveEngine.
        env.eta = move.arrivalAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        env.mstart = Int64(move.startedAt.timeIntervalSince1970 * 1000)
        return env
    }
}

// MARK: - Move (a journey toward someone)

/// The traveller's own active journey — the state that turns each outgoing fix into a Move
/// frame. Local only: it is never persisted and never leaves the device except inside the
/// encrypted `fix` plaintext above, so ending the app ends the Move.
struct MapMoveOutbound: Equatable {
    let destination: CLLocationCoordinate2D
    let name: String
    let address: String?
    let startedAt: Date
    /// Absolute predicted arrival, or nil until the first MKDirections route resolves. NEVER
    /// guessed from straight-line distance — an ETA the user did not measure is a lie told
    /// with a straight face, and a wrong "5 min" is worse than no number at all.
    var arrivalAt: Date?
    /// Remaining route distance in metres, from the same MKDirections response as `arrivalAt`.
    /// Not sent on the wire: the viewer holds the traveller's live position AND the
    /// destination, so a receiver-side straight-line remainder would be the only derivable
    /// figure — and we choose to show the honest route figure only on the sender's own screen.
    var remainingMetres: CLLocationDistance?

    static func == (l: MapMoveOutbound, r: MapMoveOutbound) -> Bool {
        l.destination.latitude == r.destination.latitude &&
        l.destination.longitude == r.destination.longitude &&
        l.name == r.name && l.address == r.address &&
        l.startedAt == r.startedAt && l.arrivalAt == r.arrivalAt
    }
}

/// A Move as the VIEWER sees it: everything the traveller put on the wire, plus the viewer's
/// own live `MapPresence` for that person. Assembled per-frame in `MapPresenceEngine`.
///
/// Held in memory only, for the same §8/§10 reason presence keeps exactly one fix: a Move is a
/// live thing, and a persisted destination history is precisely the trail the whole feature is
/// built to not have.
struct MapMoveInbound: Equatable {
    let senderUserId: String
    let shareId: String
    let destination: CLLocationCoordinate2D
    let name: String?
    let address: String?
    /// Absolute arrival instant, or nil while the traveller's device is still computing it.
    let arrivalAt: Date?
    let startedAt: Date
    /// When this Move payload arrived — drives the "ETA is going stale" read, distinct from
    /// the presence pin's own freshness.
    let receivedAt: Date

    /// Whole minutes until arrival from `now`, or nil if no ETA has been received. Clamped at
    /// zero: a negative countdown means overdue, which reads as "Arriving now", never "-3 min".
    func minutesRemaining(now: Date = Date()) -> Int? {
        guard let arrivalAt else { return nil }
        return max(0, Int((arrivalAt.timeIntervalSince(now) / 60).rounded()))
    }

    /// 0…1 along the journey, or nil without an ETA. Time-based, not distance-based, because
    /// time is what both endpoints of the bar are expressed in — and a distance-based bar
    /// crawls then leaps on a route that ends with a motorway.
    func progress(now: Date = Date()) -> Double? {
        guard let arrivalAt else { return nil }
        let total = arrivalAt.timeIntervalSince(startedAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(startedAt) / total))
    }

    /// Straight-line metres from a live position to the destination. The viewer holds no route,
    /// so this is labelled "as the crow flies" in the UI rather than passed off as road
    /// distance.
    func directMetres(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: destination.latitude,
                                       longitude: destination.longitude))
    }

    static func == (l: MapMoveInbound, r: MapMoveInbound) -> Bool {
        l.senderUserId == r.senderUserId && l.shareId == r.shareId &&
        l.arrivalAt == r.arrivalAt && l.startedAt == r.startedAt &&
        l.destination.latitude == r.destination.latitude &&
        l.destination.longitude == r.destination.longitude &&
        l.name == r.name && l.address == r.address && l.receivedAt == r.receivedAt
    }
}

// MARK: - Presence (a contact on the map)

/// One contact's most-recent known position. EXACTLY ONE of these is ever retained per
/// contact — the map draws the latest fix and nothing else. There is no trail, no history,
/// ever (§8, §10). `fixedAt` drives the live/stale/aged-out state machine entirely on the
/// receiver, so a contact whose phone died still ages out correctly with zero network.
struct MapPresence: Identifiable, Equatable {
    let senderUserId: String
    let shareId: String
    let coordinate: CLLocationCoordinate2D
    let accuracy: CLLocationAccuracy
    let seq: Int
    let fixedAt: Date

    var id: String { senderUserId }

    static func == (l: MapPresence, r: MapPresence) -> Bool {
        l.senderUserId == r.senderUserId && l.shareId == r.shareId &&
        l.seq == r.seq && l.fixedAt == r.fixedAt
    }
}

/// How a contact's presence renders on the map. The distinction between "lost signal"
/// (stale / aged out — keep the last position) and "turned it off" (not sharing — DISCARD
/// the last position) is a safety property, not polish (§8): a viewer must always be able
/// to tell "their phone is dead" from "they stopped sharing".
enum MapPresenceState: Equatable {
    /// Fix < 15 min old — full-colour avatar on the map.
    case live
    /// Fix 15 min – 8 h old — desaturated avatar + "last seen", last position retained.
    case stale
    /// Fix > 8 h old, no stop received — avatar leaves the map, keeps last position in a list.
    case agedOut
    /// A `map_off` arrived or the share expired — the cached position is ERASED and the
    /// contact appears only in the "Not sharing" list with NO position.
    case notSharing

    /// Map presence cadence is ~5 min; these thresholds are the §8 Map table, not §3's
    /// tighter conversation thresholds.
    static let liveWindow: TimeInterval = 15 * 60
    static let staleWindow: TimeInterval = 8 * 60 * 60

    static func forFix(at fixedAt: Date, now: Date = Date()) -> MapPresenceState {
        let age = now.timeIntervalSince(fixedAt)
        if age < liveWindow { return .live }
        if age < staleWindow { return .stale }
        return .agedOut
    }
}

// MARK: - Audience (the (B) allow-list)

/// One person you have explicitly chosen to be visible to. The allow-list is EMPTY by
/// default and only ever grows by explicit per-contact selection. "Members of a group" is
/// a selection-time convenience that expands to individuals and is stored as individuals,
/// so leaving a group never silently keeps someone on your list (§8).
struct MapAudienceMember: Identifiable, Equatable {
    let userId: String
    let addedAt: Date
    var id: String { userId }
}

// MARK: - Visibility mode

/// Your own standing state on the map. `ghost` is the default and the safe state: while
/// ghosted, no location request is issued at all — it is a hard local gate, not a
/// server-side filter (§8).
enum MapVisibilityMode: String {
    case ghost      // hidden from everyone — the default
    case visible    // emitting coarse fixes to the named audience
}

/// A timed-ghost expiry. Turning Ghost Mode on defaults to `.untilOff`.
enum GhostDuration: Equatable {
    case oneHour
    case untilTomorrow
    case untilOff

    var label: String {
        switch self {
        case .oneHour:        return "For 1 hour"
        case .untilTomorrow:  return "Until tomorrow"
        case .untilOff:       return "Until I turn it off"
        }
    }

    /// Absolute instant the ghost lifts, or nil for `.untilOff`.
    func expiry(from now: Date = Date()) -> Date? {
        switch self {
        case .oneHour:       return now.addingTimeInterval(3600)
        case .untilTomorrow:
            var cal = Calendar.current
            cal.timeZone = .current
            let start = cal.startOfDay(for: now)
            return cal.date(byAdding: .day, value: 1, to: start)
        case .untilOff:      return nil
        }
    }
}
