//
//  RecoveryService.swift
//  Voiid
//
//  Transport for the PIN-wrapped backup master secret. The wrap itself is opaque
//  to the server — it's produced by `wrapMasterSecretWithPin` (e2e-core) and only
//  ever unwrapped on-device with the user's PIN. This service just stores/fetches
//  that opaque blob and reports every unwrap attempt so the server can enforce
//  online guess-limiting (locks after 10 consecutive failures → 429 on GET).
//
//    PUT  /v1/recovery/key             { version, salt, nonce, ciphertext }  → { stored }
//    GET  /v1/recovery/key             → { wrapped_key: {…} }  | 404 never-set | 429 locked
//    POST /v1/recovery/attempt-result  { success: Bool }
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
        }
    }
}

@MainActor
final class RecoveryService {
    static let shared = RecoveryService()
    private let api = APIClient()
    private init() {}

    private struct StoredResp: Decodable { let stored: Bool }
    private struct WrappedKeyResp: Decodable { let wrapped_key: PinWrappedSecretDTO }

    /// Store (or replace) the PIN-wrapped master secret on the server.
    func putKey(_ wrapped: PinWrappedSecret) async throws {
        let _: StoredResp = try await api.request("PUT", "recovery/key", body: PinWrappedSecretDTO(wrapped))
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
