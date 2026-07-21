//
//  GoogleDriveBackupService.swift
//  Voiid
//
//  Google Drive destination for the encrypted backup blob. The blob stored here is
//  the exact `encryptBackup(masterSecret, plaintext)` ciphertext — Google only ever
//  sees the opaque blob; the master secret and plaintext never leave the device.
//
//  The file lives in the Drive **appDataFolder** — a hidden, app-private folder that
//  the `https://www.googleapis.com/auth/drive.appdata` scope grants. That scope is
//  app-private: it does NOT see or touch the user's other Drive files. Fixed name
//  `voiid-backup.enc`; we PATCH the existing file id in place (no duplicates).
//
//  --- Dependency / SDK path taken ---------------------------------------------------
//  The Drive v3 REST calls below are implemented directly on URLSession (the same
//  raw-REST approach BackupService/MediaService already use for R2), so this file is
//  real, compiling Drive logic with NO third-party SDK required. The one thing REST
//  cannot do by itself is acquire the OAuth access token — that's what the GoogleSignIn
//  SDK provides. Rather than hand-wire GoogleSignIn-iOS's multi-package graph (AppAuth,
//  GTMAppAuth, GTMSessionFetcher) into the project here, token acquisition is abstracted
//  behind `GoogleDriveTokenProvider`. The default provider is a stub that reports
//  "not signed in", so the feature compiles and is safely disabled until GoogleSignIn
//  is wired. TODO(GoogleSignIn): add the SPM package `https://github.com/google/GoogleSignIn-iOS`,
//  request the `drive.appdata` scope, and set `GoogleDriveBackupService.shared.tokenProvider`
//  to an adapter whose `accessToken()` returns `GIDSignIn ... .accessToken.tokenString`
//  (refreshing as needed). The reversed-client-id URL scheme is already in Info.plist.
//

import Foundation

// MARK: - OAuth token provider (the seam GoogleSignIn fills)

/// Supplies a valid Drive access token scoped to `drive.appdata`. GoogleSignIn implements
/// this once it's wired; until then the stub below reports "not signed in".
protocol GoogleDriveTokenProvider: Sendable {
    /// Whether a Google account is currently authorized for Drive backup.
    var isSignedIn: Bool { get }
    /// A fresh, valid OAuth access token, refreshing if necessary. Throws if not signed in.
    func accessToken() async throws -> String
}

/// Default provider used until GoogleSignIn is integrated: always "signed out". This keeps
/// the whole Drive feature compiling and visibly disabled (no client secret, no network).
struct StubGoogleDriveTokenProvider: GoogleDriveTokenProvider {
    var isSignedIn: Bool { false }
    func accessToken() async throws -> String { throw GoogleDriveError.signInRequired }
}

// MARK: - Errors

enum GoogleDriveError: LocalizedError {
    case signInRequired
    case noBackup
    case http(status: Int, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .signInRequired:            return "Sign in with Google to use Google Drive backup."
        case .noBackup:                  return "No Google Drive backup was found."
        case .http(let status, let msg): return "Google Drive request failed (\(status)). \(msg)"
        case .badResponse:               return "Unexpected response from Google Drive."
        }
    }
}

// MARK: - Service

/// Drive v3 REST client for the encrypted backup blob, targeting `appDataFolder`.
///
/// `@unchecked Sendable`: `tokenProvider` is only swapped once at startup (when GoogleSignIn
/// is wired); all network work is stateless URLSession calls.
final class GoogleDriveBackupService: BackupDestinationService, @unchecked Sendable {
    static let shared = GoogleDriveBackupService()
    private init() {}

    /// Injected by GoogleSignIn wiring; defaults to the "signed out" stub.
    var tokenProvider: GoogleDriveTokenProvider = StubGoogleDriveTokenProvider()

    /// Whether Drive backup can run right now (a Google account is authorized).
    var isSignedIn: Bool { tokenProvider.isSignedIn }

    /// The app-private Drive scope. Least-privilege: sees only our own appDataFolder, never
    /// the user's other files. Referenced by the (future) GoogleSignIn authorization request.
    static let scope = "https://www.googleapis.com/auth/drive.appdata"

    /// Fixed backup filename inside appDataFolder.
    private static let filename = "voiid-backup.enc"

    private static let apiBase = "https://www.googleapis.com/drive/v3"
    private static let uploadBase = "https://www.googleapis.com/upload/drive/v3"

    // MARK: BackupDestinationService

    /// Create-or-update the backup file. If it already exists we PATCH its bytes in place
    /// (no duplicates); otherwise we multipart-create it in `appDataFolder`. Always the
    /// encrypted ciphertext blob.
    func uploadBackup(_ blob: Data) async throws {
        let token = try await tokenProvider.accessToken()
        if let existing = try await findBackupFile(token: token) {
            try await updateFile(id: existing.id, blob: blob, token: token)
        } else {
            try await createFile(blob: blob, token: token)
        }
    }

    func fetchSnapshot() async throws -> BackupSnapshot? {
        // Not signed in → destination simply unavailable (nil), not an error.
        guard tokenProvider.isSignedIn else { return nil }
        let token = try await tokenProvider.accessToken()
        guard let file = try await findBackupFile(token: token) else { return nil }
        let size = Int(file.size ?? "0") ?? 0
        let modified = file.modifiedTime.flatMap { ISO8601DateFormatter().date(from: $0) }
        return BackupSnapshot(sizeBytes: size, modified: modified)
    }

    func downloadBackup() async throws -> Data {
        let token = try await tokenProvider.accessToken()
        guard let file = try await findBackupFile(token: token) else { throw GoogleDriveError.noBackup }
        var req = URLRequest(url: url("\(Self.apiBase)/files/\(file.id)", query: [("alt", "media")]))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await send(req)
        try Self.ensureOK(resp, data)
        return data
    }

    /// Delete the Drive backup (used by "disable / delete Drive backup"). No-op if none.
    func deleteBackup() async throws {
        let token = try await tokenProvider.accessToken()
        guard let file = try await findBackupFile(token: token) else { return }
        var req = URLRequest(url: url("\(Self.apiBase)/files/\(file.id)"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await send(req)
        try Self.ensureOK(resp, data)
    }

    // MARK: REST helpers

    private struct DriveFile: Decodable { let id: String; let name: String?; let size: String?; let modifiedTime: String? }
    private struct DriveFileList: Decodable { let files: [DriveFile] }

    /// List appDataFolder for our fixed-name file. Returns nil if absent.
    private func findBackupFile(token: String) async throws -> DriveFile? {
        var req = URLRequest(url: url("\(Self.apiBase)/files", query: [
            ("spaces", "appDataFolder"),
            ("q", "name = '\(Self.filename)'"),
            ("fields", "files(id,name,size,modifiedTime)"),
            ("pageSize", "1"),
        ]))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await send(req)
        try Self.ensureOK(resp, data)
        let list = try JSONDecoder().decode(DriveFileList.self, from: data)
        return list.files.first
    }

    /// Multipart create in appDataFolder (metadata part + media part).
    private func createFile(blob: Data, token: String) async throws {
        let boundary = "voiid-\(UUID().uuidString)"
        let metadata = #"{"name":"\#(Self.filename)","parents":["appDataFolder"]}"#

        var body = Data()
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8Data)
        body.append(metadata.utf8Data)
        body.append("\r\n--\(boundary)\r\n".utf8Data)
        body.append("Content-Type: application/octet-stream\r\n\r\n".utf8Data)
        body.append(blob)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)

        var req = URLRequest(url: url("\(Self.uploadBase)/files", query: [("uploadType", "multipart")]))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await send(req)
        try Self.ensureOK(resp, data)
    }

    /// PATCH the existing file's bytes in place (media upload; metadata/name unchanged).
    private func updateFile(id: String, blob: Data, token: String) async throws {
        var req = URLRequest(url: url("\(Self.uploadBase)/files/\(id)", query: [("uploadType", "media")]))
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = blob
        let (data, resp) = try await send(req)
        try Self.ensureOK(resp, data)
    }

    private func url(_ base: String, query: [(String, String)] = []) -> URL {
        var comps = URLComponents(string: base)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return comps.url!
    }

    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: req) }
        catch { throw GoogleDriveError.http(status: 0, message: error.localizedDescription) }
    }

    private static func ensureOK(_ resp: URLResponse, _ data: Data) throws {
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.http(status: status, message: String(msg.prefix(200)))
        }
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
