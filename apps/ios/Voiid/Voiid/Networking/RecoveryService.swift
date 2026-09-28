//
//  RecoveryService.swift
//  Voiid
//
//  Transport for the PIN-wrapped backup master secret. The wrap itself is opaque
//  to the server — it's produced by `wrapMasterSecretWithPin` (e2e-core) and only
//  ever unwrapped on-device with the user's PIN. This service stores/fetches that
//  opaque blob and reports each unwrap attempt.
//
//  ── WHAT THE ATTEMPT REPORT IS, AND IS NOT (S04) ───────────────────────────────
//  This header used to say the report let the server "enforce online guess-limiting".
//  It does not, and the backend retracted the same claim in `routes/recovery.ts` —
//  read the threat model there before relying on anything here.
//
//  The counter moves only when a client chooses to POST `success:false`. An attacker
//  holding the wrap can fetch once and guess OFFLINE forever, report nothing, or POST
//  `success:true` to clear an active lock. A control the attacker can decline to
//  trigger and can reset at will is not a security boundary; it is abuse telemetry
//  about HONEST clients. Keep reporting attempts — that telemetry is still worth
//  having — but do not present the 429 to the user as protection it is not.
//
//  What actually defends the secret is the BIP39 phrase (high entropy, never sent)
//  and, weakly, Argon2id raising the cost per guess on a ~20-bit PIN. Replacing this
//  with a real boundary is S04, and it needs a cryptographic reviewer.
//
//    PUT  /v1/recovery/key             { version, salt, nonce, ciphertext }  → { stored }
//    GET  /v1/recovery/key             → { wrapped_key: {…} }  | 404 never-set | 429 locked
//    POST /v1/recovery/attempt-result  { success: Bool }
//
//  ── THE V PIN, WHICH REPLACES ALL OF THE ABOVE FOR NEW PINS ───────────────────────────
//  The server now checks the PIN itself — via a proof, never the PIN — and releases the
//  locked key only when it is right, counting every wrong try: 5 wrong, locked 24 hours.
//  That is a real limit, unlike the client-reported counter described above. Design and
//  threat model: backend/api/src/vpin.ts.
//
//    GET  /v1/recovery/status          → { has_pin_wrap, vpin: { auth_salt, attempts_left, locked_until } | null }
//    PUT  /v1/recovery/pin             { wrapped_key, auth_salt, proof }       → { stored }
//    POST /v1/recovery/pin/unlock      { proof } → { wrapped_key } | 401 wrong | 429 locked
//

import Foundation

/// Codable mirror of the (non-Codable) FFI `PinWrappedSecret`, matching the backend
/// JSON shape 1:1. Convert with `init(_:)` / `toFFI`.
struct PinWrappedSecretDTO: Codable {
    let version: UInt8
    let salt: String
    let nonce: String
    let ciphertext: String

    init(_ w: PinWrappedSecret) {
        version = w.version; salt = w.salt; nonce = w.nonce; ciphertext = w.ciphertext
    }

    var toFFI: PinWrappedSecret {
        PinWrappedSecret(version: version, salt: salt, nonce: nonce, ciphertext: ciphertext)
    }
}

/// Errors specific to the recovery-key flow (distinct from generic APIError so the
/// UI can render "never set up" vs "locked, try again in N" precisely).
enum RecoveryError: Error, LocalizedError {
    /// Too many failed PIN attempts — server is rate-locking. `retryAfter` (seconds)
    /// comes from the 429 Retry-After header when present.
    case locked(retryAfter: TimeInterval?)
    /// No recovery key has ever been stored for this account (404).
    case notSet
    /// V PIN: the server checked the proof and it was wrong. `attemptsLeft` before the lock.
    case wrongVPin(attemptsLeft: Int)
    /// V PIN: locked by the server after 5 wrong tries, until `until`.
    case vpinLocked(until: Date?)
    /// V PIN: the right PIN, but the server can no longer open what it stored (its key
    /// changed). Only the recovery phrase can restore now.
    case vpinUnreadable
    /// V PIN: the server has no key to protect a PIN with, so it will not store one.
    case vpinUnavailable

    var errorDescription: String? {
        switch self {
        case .locked(let ra):
            if let ra, ra > 0 {
                let mins = Int((ra / 60).rounded(.up))
                return "Too many attempts. Try again in about \(mins) minute\(mins == 1 ? "" : "s")."
            }
            return "Too many attempts. Try again later."
        case .notSet:
            return "No recovery key is set up for this account."
        case .wrongVPin(let left):
            // Said plainly, with the count — the person should know how close the lock is.
            return left == 1
                ? "Wrong V PIN. 1 try left before it locks for 24 hours."
                : "Wrong V PIN. \(left) tries left."
        case .vpinLocked(let until):
            if let until {
                let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
                let day = Calendar.current.isDateInToday(until) ? "" : " tomorrow"
                return "V PIN locked after 5 wrong tries. Try again\(day) at \(f.string(from: until)), or use your recovery phrase now."
            }
            return "V PIN locked after 5 wrong tries. Try again in 24 hours, or use your recovery phrase now."
        case .vpinUnreadable:
            return "This V PIN can no longer be used. Restore with your recovery phrase, then set a new V PIN."
        case .vpinUnavailable:
            return "V PIN isn't available right now. Your recovery phrase still protects your backup."
        }
    }
}

/// The server's view of this account's V PIN (GET /recovery/status → `vpin`).
struct VPinStatus: Decodable {
    let auth_salt: String
    let max_attempts: Int
    let attempts_left: Int
    let locked_until: Date?
    let retry_after: Int?

    var isLocked: Bool { (retry_after ?? 0) > 0 }
}

@MainActor
final class RecoveryService {
    static let shared = RecoveryService()
    private let api = APIClient()
    private init() {}

    private struct StoredResp: Decodable { let stored: Bool }
    private struct WrappedKeyResp: Decodable { let wrapped_key: PinWrappedSecretDTO }

    /// Whether a LEGACY PIN wrap exists for this account. Not a fetch: the server answers
    /// without handing the wrap out, so asking never counts toward the fetch limit.
    func hasPinWrap() async throws -> Bool {
        try await status().legacy
    }

    /// Both PIN states in one call: a legacy wrap, and/or a V PIN with its salt and lock.
    func status() async throws -> (legacy: Bool, vpin: VPinStatus?) {
        let (data, code, _) = try await raw("GET", "recovery/status", body: nil)
        guard (200..<300).contains(code) else {
            throw APIError.http(status: code, message: "Couldn’t check your PIN (\(code)).")
        }
        struct Resp: Decodable { let has_pin_wrap: Bool; let vpin: VPinStatus? }
        let r = try Self.decoder.decode(Resp.self, from: data)
        return (r.has_pin_wrap, r.vpin)
    }

    // MARK: V PIN

    /// Store (or replace) the V PIN. `wrapped` is the backup key locked with the PIN on this
    /// phone; `proof` is `VPinProof.proof(pin:authSalt:)`. The PIN itself is never sent.
    func setVPin(wrapped: PinWrappedSecret, authSalt: Data, proof: Data) async throws {
        struct Body: Encodable { let wrapped_key: PinWrappedSecretDTO; let auth_salt: String; let proof: String }
        let body = try JSONEncoder().encode(Body(wrapped_key: PinWrappedSecretDTO(wrapped),
                                                 auth_salt: authSalt.base64EncodedString(),
                                                 proof: proof.base64EncodedString()))
        let (_, code, json) = try await raw("PUT", "recovery/pin", body: body)
        if code == 503 { throw RecoveryError.vpinUnavailable }
        guard (200..<300).contains(code) else {
            throw APIError.http(status: code, message: (json?["error"] as? String) ?? "Couldn’t save your V PIN (\(code)).")
        }
    }

    /// Present a proof; the server counts it. Returns the locked backup key only when right.
    func unlockVPin(proof: Data) async throws -> PinWrappedSecret {
        struct Body: Encodable { let proof: String }
        let (data, code, json) = try await raw("POST", "recovery/pin/unlock",
                                               body: try JSONEncoder().encode(Body(proof: proof.base64EncodedString())))
        switch code {
        case 200..<300:
            return try Self.decoder.decode(WrappedKeyResp.self, from: data).wrapped_key.toFFI
        case 401:
            throw RecoveryError.wrongVPin(attemptsLeft: (json?["attempts_left"] as? Int) ?? 0)
        case 429:
            // Either the V PIN lock (has locked_until) or the plain request rate limit.
            let until = (json?["locked_until"] as? String).flatMap(Self.isoDate)
            if json?["code"] as? String == "vpin_locked" { throw RecoveryError.vpinLocked(until: until) }
            throw RecoveryError.locked(retryAfter: nil)
        case 404:
            throw RecoveryError.notSet
        case 409 where json?["code"] as? String == "vpin_unreadable":
            throw RecoveryError.vpinUnreadable
        case 503:
            throw RecoveryError.vpinUnavailable
        default:
            throw APIError.http(status: code, message: (json?["error"] as? String) ?? "Couldn’t check your V PIN (\(code)).")
        }
    }

    // MARK: Plumbing

    /// A request that keeps the status code and body, which the V PIN answers need: "wrong,
    /// 3 left" and "locked until" are carried in 401/429 bodies that APIClient would discard.
    private func raw(_ method: String, _ path: String, body: Data?) async throws
        -> (data: Data, code: Int, json: [String: Any]?) {
        guard let token = TokenStore.shared.jwt else { throw APIError.notAuthenticated }
        let base = APIConfig.baseURL.absoluteString
        let full = (base.hasSuffix("/") ? base : base + "/") + "\(APIConfig.apiVersion)/\(path)"
        guard let url = URL(string: full) else { throw APIError.http(status: 0, message: "bad recovery url") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw APIError.transport(error) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (data, code, json)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = isoDate(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
            }
            return date
        }
        return d
    }()

    /// The server's ISO-8601 timestamps, with or without fractional seconds.
    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Remove the legacy PIN wrap from the server (S04). Called once the person has saved
    /// their recovery phrase — new backups never create one.
    func deleteKey() async throws {
        struct DeletedResp: Decodable { let deleted: Bool }
        let _: DeletedResp = try await api.request("DELETE", "recovery/key")
    }

    /// Fetch the PIN-wrapped master secret. Uses a raw URLSession request (not the
    /// JSON APIClient) so we can read the 429 Retry-After header and distinguish
    /// 404 (never set) from 429 (locked). Throws `RecoveryError` for those.
    func getKey() async throws -> PinWrappedSecret {
        guard let token = TokenStore.shared.jwt else { throw APIError.notAuthenticated }
        let base = APIConfig.baseURL.absoluteString
        let full = (base.hasSuffix("/") ? base : base + "/") + "\(APIConfig.apiVersion)/recovery/key"
        guard let url = URL(string: full) else { throw APIError.http(status: 0, message: "bad recovery url") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw APIError.transport(error) }

        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 404 { throw RecoveryError.notSet }
        if status == 429 {
            let ra = http?.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw RecoveryError.locked(retryAfter: ra)
        }
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: "Couldn’t fetch recovery key (\(status)).")
        }
        do { return try JSONDecoder().decode(WrappedKeyResp.self, from: data).wrapped_key.toFFI }
        catch { throw APIError.decoding(error) }
    }

    /// Report a PIN unwrap attempt so the server can enforce online guess-limiting.
    /// Best-effort: a failure to report never blocks the user-visible outcome.
    func reportAttempt(success: Bool) async {
        struct Body: Encodable { let success: Bool }
        _ = try? await api.request("POST", "recovery/attempt-result", body: Body(success: success)) as EmptyResponse
    }
}
