//
//  LocationModels.swift
//  Voiid
//
//  Feature (A): location sharing INSIDE conversations — the one-off pin and
//  time-bounded live sharing (docs/LOCATION.md §4). Coordinates NEVER leave a device
//  unencrypted: a pin/live-control message is an ordinary E2EE message whose PLAINTEXT
//  is the `LocationEnvelope` below (1:1 over the Double Ratchet, group over MLS), and a
//  live position fix is `encryptBackup(shareKey, fix)` streamed over the WS relay.
//
//  Two representations, kept deliberately separate:
//   • LocationEnvelope — the on-the-wire plaintext. Self-describing + versioned because
//     no AEAD here takes AAD, so the discriminator and ids must live INSIDE the
//     authenticated plaintext. Carries `key` (the shareKey) for control messages.
//   • LocationRef — what is PERSISTED in the local message store as part of a
//     DecryptedMessage. It must NEVER hold the shareKey: the message store is plaintext
//     at rest, and the key belongs in the Keychain (LocationKeyStore) only.
//

import Foundation

/// Envelope discriminator kinds (docs/LOCATION.md §4). `pin`/`live_start`/`live_stop`
/// RENDER a chat bubble; `live_rekey`/`map_key`/`map_off`/`fix` are SILENT control,
/// consumed by the engine and never shown as a message.
enum LocationKind: String, Codable {
    case pin
    case live_start
    case live_stop
    case live_rekey
    case map_key
    case map_off
    case fix

    /// True for the kinds that produce a visible chat bubble. Everything else is
    /// silent control that the UI must drop (but the store still records, so the
    /// decrypt-once ledger stays correct).
    var rendersBubble: Bool {
        switch self {
        case .pin, .live_start, .live_stop: return true
        default: return false
        }
    }
}

/// The plaintext of a location message. `vloc` maps to the wire key `_vloc` and is the
/// discriminator that makes a location envelope recognisable on the GROUP/MLS path,
/// where `content_type` is always "group" and cannot be used to tag it.
struct LocationEnvelope: Codable {
    // Optional so decoding SUCCEEDS when `_vloc` is absent — Android omits it from the wire
    // (encodeDefaults=false), and a non-optional would make Swift's synthesized decoder throw
    // on the missing key, dropping every Android-sent pin/live/fix. `k` (a required, typed
    // enum) is the real discriminator. Still emitted as 1 on our own sends.
    var vloc: Int? = 1
    var k: LocationKind
    var s: String?              // share_id (uuid); omitted for k == .pin
    var t: Double               // epoch MILLIS this envelope was produced
    var lat: Double?
    var lon: Double?
    var acc: Double?
    var alt: Double?            // reserved (§10.14) — never drawn in v1
    var hdg: Double?            // reserved
    var spd: Double?            // reserved
    var n: Int?                 // monotonic sequence, fixes only
    var label: String?          // user-typed only — NEVER reverse-geocoded (§10.3)
    var expiresAt: Double?      // epoch MILLIS; live_start / map_key only
    var key: String?            // base64 32-byte shareKey; live_start / live_rekey / map_key only
    var cadence: Int?           // seconds; live_start / map_key

    enum CodingKeys: String, CodingKey {
        case vloc = "_vloc"
        case k, s, t, lat, lon, acc, alt, hdg, spd, n, label, expiresAt, key, cadence
    }

    /// Parse a decrypted plaintext string as a location envelope, or nil if it is not
    /// one. Requires `_vloc == 1`, so an ordinary text body that merely happens to be
    /// JSON is never mistaken for a location.
    static func parse(_ plain: String) -> LocationEnvelope? {
        guard let data = plain.data(using: .utf8),
              let env = try? JSONDecoder().decode(LocationEnvelope.self, from: data),
              (env.vloc ?? 1) == 1 else { return nil }
        return env
    }

    /// Encode to the compact JSON string that becomes the E2EE message plaintext.
    ///
    /// `t` / `expiresAt` are normalised to WHOLE MILLISECONDS first. They are `Double`
    /// here only because the internal fix/store plumbing is Double, but the WIRE contract
    /// is an integer epoch-millis: Android decodes both as `Long`, and kotlinx-serialization
    /// THROWS on a fractional literal like `1785154289733.0242`. Every Android decode site
    /// swallows that throw (`runCatching{}.getOrNull()`), so an un-rounded value made every
    /// iOS pin / live_start / live_stop / fix vanish on Android with no error and no log.
    /// `Date().timeIntervalSince1970 * 1000` is essentially never integral, so this is not
    /// an edge case — it is every message. Normalise at the single choke point rather than
    /// at each call site, so a new sender cannot reintroduce the bug.
    func encoded() -> Data {
        var wire = self
        wire.t = wire.t.rounded()
        wire.expiresAt = wire.expiresAt?.rounded()
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }

    /// The reference persisted in the message store (KEY STRIPPED). nil for a fix (fixes
    /// are never messages) — everything else that reaches the store carries one.
    var ref: LocationRef {
        LocationRef(kind: k.rawValue, shareId: s, lat: lat, lon: lon, acc: acc,
                    label: label, expiresAt: expiresAt, cadence: cadence)
    }

    /// A human, non-JSON string for the message's `text` field — so the chat-list
    /// preview and any notification body read sensibly instead of showing raw JSON.
    var displayText: String {
        switch k {
        case .pin:        return (label?.isEmpty == false ? label! : "Location")
        case .live_start: return "Live location"
        case .live_stop:  return "Live location ended"
        default:          return ""   // silent control — never rendered anyway
        }
    }
}

/// The location payload PERSISTED with a DecryptedMessage / VMessage. Never holds the
/// shareKey. `lat`/`lon` are optional because a `live_stop` control message may arrive
/// with no coordinate (the recipient freezes the last KNOWN fix, which it already holds).
struct LocationRef: Codable, Equatable, Hashable {
    var kind: String            // LocationKind rawValue
    var shareId: String?
    var lat: Double?
    var lon: Double?
    var acc: Double?
    var label: String?
    var expiresAt: Double?      // epoch MILLIS
    var cadence: Int?

    var locationKind: LocationKind? { LocationKind(rawValue: kind) }
    var hasCoordinate: Bool { lat != nil && lon != nil }
    var expiresAtDate: Date? { expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// A single live position fix — the plaintext of one `encryptBackup(shareKey, fix)` blob
/// streamed over the WS relay. Never a message, never persisted beyond the single most
/// recent fix per (share, sender).
struct LocationFix: Codable, Equatable {
    var shareId: String
    var seq: Int
    var timestampMillis: Double
    var lat: Double
    var lon: Double
    var acc: Double?

    var date: Date { Date(timeIntervalSince1970: timestampMillis / 1000) }

    /// Build the fix envelope for the wire (`k == .fix`).
    func envelope() -> LocationEnvelope {
        LocationEnvelope(vloc: 1, k: .fix, s: shareId, t: timestampMillis,
                         lat: lat, lon: lon, acc: acc, n: seq)
    }

    /// Decode a fix from a decrypted fix-envelope plaintext, or nil if it is not a fix.
    static func from(plaintext: String) -> LocationFix? {
        guard let env = LocationEnvelope.parse(plaintext), env.k == .fix,
              let s = env.s, let lat = env.lat, let lon = env.lon else { return nil }
        return LocationFix(shareId: s, seq: env.n ?? 0, timestampMillis: env.t,
                           lat: lat, lon: lon, acc: env.acc)
    }
}

/// The three recipient-visible states of a live share (docs/LOCATION.md §3). Every state
/// is derivable from `expiresAt` ALONE, so a recipient who never receives the stop
/// message still ends the share at the timer — offline, with no network at all.
enum ShareState: String, Codable {
    case live       // last fix newer than 2×cadence + 30s
    case stale      // older than that, but now < expiresAt and no stop received
    case ended      // a live_stop arrived, OR now >= expiresAt
}

/// Allowed live-share durations. No indefinite option (docs/LOCATION.md §3).
enum ShareDuration: Int, CaseIterable, Identifiable {
    case fifteenMinutes = 900
    case oneHour = 3600
    case eightHours = 28800

    var id: Int { rawValue }
    var seconds: Int { rawValue }
    var label: String {
        switch self {
        case .fifteenMinutes: return "15 minutes"
        case .oneHour:        return "1 hour"
        case .eightHours:     return "8 hours"
        }
    }
    /// Durations over 15 minutes escalate the OS authorization ladder to Always
    /// (docs/LOCATION.md §5) so the share keeps running in the background.
    var needsAlways: Bool { self != .fifteenMinutes }
}

/// An outbound share this device is currently emitting for. Held in memory by
/// LocationShareEngine and rendered by the persistent "you are sharing" banner.
struct OutboundShare: Identifiable, Equatable {
    let id: String              // share_id
    let conversationId: String
    let isGroup: Bool
    let audienceCount: Int
    var expiresAt: Date
    let cadenceSeconds: Int

    var timeRemaining: TimeInterval { max(0, expiresAt.timeIntervalSinceNow) }
    var hasEnded: Bool { timeRemaining <= 0 }
}

/// Coordinate privacy: round at the SOURCE, before encryption (docs/LOCATION.md §1).
/// Live shares round to 5 decimals (~1.1 m); Map presence (feature B) to 3 (~110 m).
enum LocationRounding {
    static func round(_ value: Double, decimals: Int) -> Double {
        let f = pow(10.0, Double(decimals))
        return (value * f).rounded() / f
    }
    static let liveDecimals = 5
    /// 4 decimals (~11 m), up from 3 (~110 m).
    ///
    /// 3 decimals quantised every position onto a ~110 m grid, so two people standing
    /// together could show a block apart and moving within a building never moved the pin.
    /// That is more imprecision than the privacy model asks for: the defence here is the
    /// coarse cadence, the audience gate and the encryption — not blurring the coordinate
    /// past usefulness. 11 m rounds away noise rather than signal. Matches Android's
    /// PRESENCE_COORD_DECIMALS.
    static let mapDecimals = 4
}
