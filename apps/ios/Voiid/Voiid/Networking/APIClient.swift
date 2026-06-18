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
}

enum APIError: Error, LocalizedError {
    case http(status: Int, message: String)
    case transport(Error)
    case decoding(Error)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .http(_, let m): return m
        case .transport(let e): return e.localizedDescription
        case .decoding: return "Unexpected server response."
        case .notAuthenticated: return "Please sign in again."
        }
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
        as: Response.Type = Response.self
    ) async throws -> Response {
        // Build the URL from a string so query strings (e.g. "?username=foo")
        // survive — appendingPathComponent would percent-encode the "?" and "="
        // and break the request.
        let base = APIConfig.baseURL.absoluteString
        let full = base.hasSuffix("/") ? base + path : base + "/" + path
        guard let url = URL(string: full) else {
            throw APIError.http(status: 0, message: "Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "Request failed (\(status))."
            if status == 401 { tokenStore.clear() }
            throw APIError.http(status: status, message: message)
        }

        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    private struct ErrorBody: Decodable { let error: String }
}

/// For endpoints that return `{ ok: true }`-style bodies we don't need to read.
struct EmptyResponse: Decodable {}

/// Type-erasing wrapper so `request(body:)` can take any Encodable.
private struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encode = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
