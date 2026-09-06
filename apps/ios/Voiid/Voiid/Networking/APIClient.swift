//
//  APIClient.swift
//  Voiid
//
//  Thin URLSession JSON client for the VOIID backend. Injects the bearer JWT,
//  decodes JSON, surfaces clean errors. See docs/API_CONTRACT.md.
//

import Foundation

/// Backend configuration, resolved per build type (Q03).
///
/// ── WHAT THIS REPLACES ───────────────────────────────────────────────────────────
///
/// Two literals pointing at `https://api-dev.voiid.app`, with nothing anywhere assigning
/// anything else. There was no environment boundary: a release build would have been compiled
/// against the development backend, signed and shipped, and the only thing preventing that was
/// somebody remembering to edit these lines first.
///
/// DEBUG keeps the dev host as a working default so local development is unchanged. RELEASE has
/// no default at all — it reads `VoiidApiBaseURL` / `VoiidWebSocketURL` from Info.plist, which
/// are populated by the `VOIID_API_BASE_URL` / `VOIID_WS_URL` build settings, and refuses to run
/// if they are missing, still point at a development host, or are not TLS.
///
/// THE PRODUCTION HOSTNAME IS NOT WRITTEN DOWN HERE. This audit does not know it, and guessing
/// one would replace a visible misconfiguration with an invisible one.
enum APIConfig {
    /// Hosts a release must never talk to, however it was configured.
    private static let developmentHosts = ["api-dev.voiid.app", "localhost", "127.0.0.1"]

    /// Read an endpoint from Info.plist, or fall back in DEBUG only.
    ///
    /// An unset build setting leaves the literal `$(VOIID_API_BASE_URL)` in the plist rather
    /// than an empty string, so the check below has to reject anything that is not a real
    /// https/wss URL — not merely anything empty.
    private static func endpoint(_ key: String, debugDefault: String, scheme: String) -> URL {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let usable = raw.hasPrefix(scheme) && !developmentHosts.contains(where: raw.contains)

        #if DEBUG
        // Local development is unchanged: an unset or dev-pointing value is expected here.
        let chosen = usable || raw.hasPrefix("http://") || raw.hasPrefix("ws://") ? raw : debugDefault
        return URL(string: chosen) ?? URL(string: debugDefault)!
        #else
        // A release that cannot say where it is pointing must not start. Crashing at launch is
        // a bad outcome; silently talking to the development backend from the App Store is a
        // worse one, and it is the one that goes unnoticed.
        precondition(
            usable,
            "\(key) is missing, points at a development host, or is not \(scheme). Set the " +
            "VOIID_API_BASE_URL / VOIID_WS_URL build settings for the Release configuration."
        )
        return URL(string: raw)!
        #endif
    }

    static var baseURL = endpoint("VoiidApiBaseURL", debugDefault: "https://api-dev.voiid.app", scheme: "https://")
    static var wsURL = endpoint("VoiidWebSocketURL", debugDefault: "wss://api-dev.voiid.app/ws", scheme: "wss://")
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
    /// A 409 the caller can RESOLVE rather than report.
    ///
    /// Sent by POST /messages/send when a `client_message_id` already produced a message with
    /// different bytes — which is what a legitimate retry looks like, because re-encrypting
    /// advances the Olm ratchet. Carries the message the key already produced, so the caller
    /// can reconcile instead of showing a failure for something the recipient already has.
    case alreadySent(messageId: String)
    case transport(Error)
    case decoding(Error)
    case notAuthenticated

    /// What the USER sees. Deliberately not the raw server or URLSession text.
    ///
    /// A backend message is written for whoever reads the logs: "peer has no available prekeys",
    /// "Request failed (502)." — accurate, and meaningless to the person holding the phone, who
    /// can only act on whether to wait, retry, or check their connection. Shipping the internal
    /// string also leaks the shape of the system to anyone who cares to read it.
    ///
    /// So RELEASE builds map to plain language by status class, and DEBUG builds keep the raw
    /// text — the detail is exactly what you want while developing, and exactly what you do not
    /// want in front of a user.
    ///
    /// A 4xx that carries a server `code` is the one exception: those messages are written FOR
    /// the user (a taken username, an invalid invite) and are already specific and actionable,
    /// so they pass through in both builds.
    var errorDescription: String? {
        switch self {
        case .http(let status, let m, let code):
            #if DEBUG
            return m
            #else
            // Server-authored, user-facing copy — pass through.
            if code != nil, (400..<500).contains(status) { return m }
            switch status {
            case 401, 403: return "Please sign in again."
            case 404:      return "That’s not available any more."
            case 408, 429: return "Too many attempts. Please wait a moment."
            case 400..<500: return "Something didn’t look right. Please try again."
            default:        return "Voiid is having trouble right now. Please try again."
            }
            #endif
        case .transport(let e):
            #if DEBUG
            return e.localizedDescription
            #else
            // URLError's own copy is decent for the cases a user can act on, and vague for the
            // rest — so name the actionable ones and give everything else one honest sentence.
            let code = (e as? URLError)?.code
            switch code {
            case .some(.notConnectedToInternet), .some(.dataNotAllowed):
                return "You’re offline. Check your connection."
            case .some(.timedOut):
                return "That took too long. Please try again."
            case .some(.cannotFindHost), .some(.cannotConnectToHost), .some(.networkConnectionLost):
                return "Can’t reach Voiid right now. Please try again."
            default:
                return "Something went wrong. Please try again."
            }
            #endif
        case .decoding:
            #if DEBUG
            return "Unexpected server response."
            #else
            return "Something went wrong. Please try again."
            #endif
        case .notAuthenticated: return "Please sign in again."
        // Not a user-facing failure: the caller resolves it. If it ever reaches a screen,
        // saying "sent" is the truthful thing, because it was.
        case .alreadySent: return "Already sent."
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
    /// `bearer` overrides the stored token. Exactly one caller needs this: logout revokes
    /// the session server-side while the local token is being cleared, so the credential has
    /// to be carried by value rather than read back from a store that is already empty.
    func request<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Encodable? = nil,
        auth: Bool = true,
        versioned: Bool = true,
        bearer: String? = nil,
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
            guard let token = bearer ?? tokenStore.jwt else { throw APIError.notAuthenticated }
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
            // A 401 normally means the credential is finished — clear it and the app returns
            // to sign-in. `device_session_required` is the one exception: the token is a
            // VALID bootstrap credential that simply has not been traded for a device
            // session yet, and POST /devices/register still accepts it. Clearing here would
            // destroy the only credential that can complete registration, turning a
            // recoverable state into a forced re-verification of the phone number.
            if status == 401, parsed?.code != "device_session_required" { tokenStore.clear() }
            throw APIError.http(status: status, message: message, code: parsed?.code)
        }

        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    /// `code` is optional — most endpoints send only `error`.
    ///
    /// `reason` is a SECOND spelling of the same field, and it exists because the event
    /// check-in route answers a refusal as `{ ok: false, reason: "expired" }` rather than as
    /// `{ error }`. Without this the message would be synthesised as "Request failed (409)."
    /// and the volunteer at the door would be told nothing they could act on. Additive: a
    /// body carrying `error` decodes exactly as it did before.
    private struct ErrorBody: Decodable {
        let error: String
        var code: String?
        /// Present on the send conflict above; absent everywhere else.
        var messageId: String?

        private enum CodingKeys: String, CodingKey { case error, reason, code, message_id }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let message = try c.decodeIfPresent(String.self, forKey: .error)
                    ?? c.decodeIfPresent(String.self, forKey: .reason) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.error,
                    .init(codingPath: c.codingPath, debugDescription: "no error or reason"))
            }
            error = message
            code = try c.decodeIfPresent(String.self, forKey: .code)
            messageId = try c.decodeIfPresent(String.self, forKey: .message_id)
        }
    }
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
