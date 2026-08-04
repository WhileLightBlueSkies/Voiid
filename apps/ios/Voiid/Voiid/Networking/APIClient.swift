//
//  APIClient.swift
//  Voiid
//
//  Thin URLSession JSON client for the VOIID backend. Injects the bearer JWT,
//  decodes JSON, surfaces clean errors. See docs/API_CONTRACT.md.
//

import Foundation

/// Backend configuration. Override `baseURL` per environment (dev/staging/prod).
enum APIConfig {
    /// Hosted DEV backend (Vultr + Caddy TLS). WebSocket is proxied on the /ws
    /// path of the same host. For local-only work, swap to http://localhost:4000
    /// + ws://localhost:4001.
    static var baseURL = URL(string: "https://api-dev.voiid.app")!
    static var wsURL = URL(string: "wss://api-dev.voiid.app/ws")!
    /// API version this build talks (path-versioned: /v1/...). Bumped per major contract.
    static var apiVersion = "v1"
    /// This build's app version (for force-update gating).
    static var appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
}

/// Posted when the backend returns 426 (client below minSupportedVersion). The
/// root view observes this to show a blocking "update required" screen.
extension Notification.Name { static let voiidUpdateRequired = Notification.Name("voiidUpdateRequired") }

enum APIError: Error, LocalizedError {
    /// `code` is the backend's stable machine-readable discriminator (e.g. "profile_required"),
    /// carried alongside the human `message`. Matching on a bare status is not enough: 428 is a
    /// generic "precondition required" that any future endpoint may reuse, so a client keying
    /// off the status alone would fire the handle picker for an unrelated precondition.
    case http(status: Int, message: String, code: String? = nil)
    case transport(Error)
    case decoding(Error)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .http(_, let m, _): return m
        case .transport(let e): return e.localizedDescription
        case .decoding: return "Unexpected server response."
        case .notAuthenticated: return "Please sign in again."
        }
    }

    /// The backend error code, when the server sent one.
    var serverCode: String? {
        if case .http(_, _, let code) = self { return code }
        return nil
    }
}

/// Async JSON API client. Stateless except for the shared token store.
struct APIClient {
    var config = APIConfig.self
    var tokenStore: TokenStore = .shared

    /// GET/POST/etc. returning a decoded `Response`. `auth` controls whether the
    /// bearer token is attached (false for /auth/firebase).
    func request<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Encodable? = nil,
        auth: Bool = true,
        versioned: Bool = true,
        as: Response.Type = Response.self
    ) async throws -> Response {
        // Build the URL from a string so query strings (e.g. "?username=foo")
        // survive — appendingPathComponent would percent-encode the "?" and "="
        // and break the request. Versioned calls go under /v1; pass versioned:false
        // for unversioned endpoints (e.g. /config).
        let base = APIConfig.baseURL.absoluteString
        let prefix = versioned ? "\(APIConfig.apiVersion)/" : ""
        let full = (base.hasSuffix("/") ? base : base + "/") + prefix + path
        guard let url = URL(string: full) else {
            throw APIError.http(status: 0, message: "Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // Fail fast: never let a single stuck request hang the UI (the default is 60s). The
        // local-first render should take over almost immediately if the network is slow.
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Version negotiation / force-update headers (read by the backend gate).
        req.setValue("ios", forHTTPHeaderField: "X-Voiid-Platform")
        req.setValue(APIConfig.appVersion, forHTTPHeaderField: "X-Voiid-App-Version")
        req.setValue(APIConfig.apiVersion, forHTTPHeaderField: "X-Voiid-Api-Version")

        if auth {
            guard let token = tokenStore.jwt else { throw APIError.notAuthenticated }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.transport(error)
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 426 Upgrade Required → this build is below minSupportedVersion. Tell the
        // app to show a blocking forced-update screen.
        if status == 426 {
            let storeURL = (try? JSONDecoder().decode(UpdateBody.self, from: data))?.update_url
            await MainActor.run {
                NotificationCenter.default.post(name: .voiidUpdateRequired, object: storeURL)
            }
            throw APIError.http(status: 426, message: "Update required")
        }
        guard (200..<300).contains(status) else {
            let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
            let message = parsed?.error ?? "Request failed (\(status))."
            if status == 401 { tokenStore.clear() }
            throw APIError.http(status: status, message: message, code: parsed?.code)
        }

        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    /// `code` is optional — most endpoints send only `error`.
    private struct ErrorBody: Decodable { let error: String; var code: String? }
    private struct UpdateBody: Decodable { let update_url: String? }
}

/// For endpoints that return `{ ok: true }`-style bodies we don't need to read.
struct EmptyResponse: Decodable {}

/// Type-erasing wrapper so `request(body:)` can take any Encodable.
private struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encode = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
