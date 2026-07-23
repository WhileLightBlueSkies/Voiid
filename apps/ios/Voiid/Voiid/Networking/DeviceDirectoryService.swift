//
//  DeviceDirectoryService.swift
//  Voiid
//
//  The device directory for the SIGNED-IN account: list this user's active devices and
//  revoke one. Backs `LinkedDevicesView` (spec §5.3) and nothing else.
//
//  Why a new service rather than reusing what exists
//  ------------------------------------------------
//  `ChatEngine` and `GroupEngine` both already fetch `GET /v1/devices/:user_id`, but each
//  keeps a private `DeviceDTO` that decodes only the two fields the crypto path needs
//  (`id`, `identity_public_key`). Widening either of those types would drag a Settings
//  concern into the message pipeline, and both files depend on the e2e-core bindings, so
//  neither compiles in isolation. This file depends on nothing but `APIClient`.
//
//  Backend surface it maps to (backend/api/src/routes/devices.ts)
//  -------------------------------------------------------------
//   * `GET /v1/devices/:user_id`  → `{ devices: [...] }`, already filtered to
//     `revoked_at is null` and ordered `last_seen_at desc nulls last, created_at desc`.
//   * `DELETE /v1/devices/:device_id` → sets `revoked_at = now()` and drops the device's
//     one-time prekeys.
//
//  TWO THINGS DELIBERATELY NOT MODELLED HERE
//  -----------------------------------------
//  1. `identity_public_key` is returned by the route and is NOT decoded. It has exactly
//     one legitimate consumer — the session-establishment path — and a Settings screen
//     that never displays it has no business holding it.
//
//  2. Device LINKING (`POST /linking/request`, `POST /linking/approve`,
//     `GET /linking/poll/:link_token` in backend/api/src/routes/linking.ts) is not
//     implemented here. That flow is the WhatsApp-Web-style companion pairing: an
//     unauthenticated web client posts its own freshly generated `registration_id` +
//     `identity_public_key` to get a `link_token`, renders it as a QR, and an existing
//     signed-in device scans that QR and approves it. iOS could only ever be the
//     *approver*, and approving requires reading a `link_token` out of a QR code — i.e.
//     AVFoundation capture, a camera-permission string in Info.plist, a scanner surface,
//     and an approval screen that names the device being admitted to the account. That is
//     a feature build, not a settings row (spec §5.3), and a "Link a Device" button with
//     no scanner behind it is exactly the kind of lie this rebuild exists to remove.
//     When the scanner ships, `approve(linkToken:)` belongs on this type.
//
//  SECURITY NOTE FOR THE BACKEND (release blocker there, not here)
//  --------------------------------------------------------------
//  `DELETE /devices/:device_id` is NOT scoped to the caller: it revokes by id alone
//  (devices.ts:104), unlike `POST /devices/voip-token` at :70 which correctly adds
//  `and user_id = $2`. Any authenticated user who learns another user's device id can
//  therefore revoke it. iOS's mitigation is to never render or expose a raw device id —
//  see `LinkedDevice.id` below — but the real fix is one `and user_id = $2` on that
//  query and it must be filed.
//

import Foundation

// MARK: - Model

/// One active device on the signed-in account, reduced to what a settings screen may show.
struct LinkedDevice: Identifiable, Hashable, Sendable {
    /// The server's device id. Used ONLY as a `ForEach` identity and as the path
    /// component of a revoke request. It must never be rendered, logged, put in an
    /// accessibility label or made selectable — see the security note above.
    let id: String

    /// `device_name` from the server, or a platform-derived stand-in when the column is
    /// null (older rows registered before the field was sent).
    let name: String

    /// Raw `platform` string as stored: `"ios"`, `"android"`, `"web"`, …
    let platform: String

    /// `last_seen_at`. Null for a device that has registered but never checked in — in
    /// which case the UI shows no "last active" line rather than inventing one.
    let lastSeen: Date?

    /// SF Symbol for the row. Voiid's Android and iOS clients are both phones; anything
    /// else is the web companion.
    var symbol: String {
        switch platform.lowercased() {
        case "ios", "android": return "iphone"
        default: return "laptopcomputer"
        }
    }
}

// MARK: - Service

@MainActor
final class DeviceDirectoryService {
    static let shared = DeviceDirectoryService()

    private let api = APIClient()
    private init() {}

    // MARK: Wire types

    private struct DeviceDTO: Decodable {
        let id: String
        let platform: String?
        let device_name: String?
        let last_seen_at: String?
    }

    private struct DevicesResponse: Decodable { let devices: [DeviceDTO] }

    // MARK: Reads

    /// Active (non-revoked) devices on this account, in the server's order —
    /// most recently seen first.
    func devices() async throws -> [LinkedDevice] {
        guard let userId = TokenStore.shared.userId else { throw APIError.notAuthenticated }
        let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        let env: DevicesResponse = try await api.request("GET", "devices/\(encoded)")

        // Postgres timestamps arrive as ISO-8601, with fractional seconds via node-postgres
        // and without them if the column was written as a plain timestamp. Try both; a
        // date we cannot parse becomes `nil`, which the UI renders as "no last-active
        // line" rather than as a wrong one.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        return env.devices.map { dto in
            let platform = dto.platform ?? ""
            let trimmed = dto.device_name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmed?.isEmpty == false) ? trimmed! : Self.fallbackName(for: platform)
            let seen = dto.last_seen_at.flatMap { withFraction.date(from: $0) ?? plain.date(from: $0) }
            return LinkedDevice(id: dto.id, name: name, platform: platform, lastSeen: seen)
        }
    }

    // MARK: Writes

    /// Revoke a device: it stops receiving new messages immediately and its one-time
    /// prekeys are dropped, so no peer can open a fresh session with it.
    ///
    /// Never call this with `E2EManager.shared.deviceId` — revoking the device you are
    /// holding leaves a signed-in app that peers can no longer reach. `LinkedDevicesView`
    /// makes that structurally impossible by keeping the current device in a section that
    /// has no remove affordance at all.
    func revoke(deviceID: String) async throws {
        let encoded = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceID
        _ = try await api.request("DELETE", "devices/\(encoded)", as: EmptyResponse.self)
    }

    // MARK: Helpers

    /// Used only when the server has no `device_name` for a row. Deliberately generic —
    /// guessing a model name would be a fabrication.
    private static func fallbackName(for platform: String) -> String {
        switch platform.lowercased() {
        case "ios": return "iPhone"
        case "android": return "Android phone"
        case "web": return "Web"
        default: return "Unknown device"
        }
    }
}
