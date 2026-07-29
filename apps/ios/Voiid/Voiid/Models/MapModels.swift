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

    enum CodingKeys: String, CodingKey {
        case vloc = "_vloc"
        case k, s, t, lat, lon, acc, n, expiresAt, key, cadence
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
