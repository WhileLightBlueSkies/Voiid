//
//  BackupService.swift
//  Voiid
//
//  Transport for the encrypted message-history backup blob. The blob is sealed
//  on-device (`encryptBackup`, e2e-core) under the backup master secret before it
//  ever leaves — the server stores opaque ciphertext in R2 and never sees the key
//  or the plaintext. This service mirrors MediaService's raw-URLSession pattern for
//  the octet-stream PUT and the presigned R2 download; the metadata GET goes through
//  the JSON APIClient.
//
//    GET /v1/backup  → { download_url, size_bytes, updated_at }  | 404 no backup
//    PUT /v1/backup  (application/octet-stream, ≤ 50 MiB)        → { stored, size_bytes }
//    download_url    plain GET from R2 (presigned, unauthenticated)
//

import Foundation

/// Backup metadata returned by GET /backup. `download_url` is a short-lived presigned
/// R2 URL fetched with a plain (unauthenticated) GET.
struct BackupMeta: Decodable, Identifiable {
    let download_url: String
    let size_bytes: Int
    let updated_at: String

    /// Identity for SwiftUI `.sheet/.fullScreenCover(item:)`. The presigned URL is
    /// unique per fetch; that's fine for transient presentation.
    var id: String { download_url }

    /// `updated_at` parsed as a Date (ISO-8601), for display.
    var updatedAtDate: Date? { ISO8601DateFormatter().date(from: updated_at) }
}

@MainActor
final class BackupService {
    static let shared = BackupService()
    private let api = APIClient()
    private init() {}

    /// Server-side cap. We reject oversized blobs client-side with a clear message
    /// rather than letting the PUT fail opaquely.
    static let maxBytes = 50 * 1024 * 1024

    /// Fetch backup metadata, or nil when there is no backup yet (404).
    func fetchBackupMeta() async throws -> BackupMeta? {
        do { return try await api.request("GET", "backup") as BackupMeta }
        catch APIError.http(let status, _) where status == 404 { return nil }
    }

    /// Raw octet-stream upload of the sealed blob. Mirrors MediaService: manual
    /// bearer auth + URLSession (the JSON APIClient can't send a raw body).
    func uploadBackup(_ blob: Data) async throws {
        guard blob.count <= Self.maxBytes else {
            throw APIError.http(status: 413, message: "Backup is too large to upload.")
        }
        guard let token = TokenStore.shared.jwt else { throw APIError.notAuthenticated }
        let base = APIConfig.baseURL.absoluteString
        let full = (base.hasSuffix("/") ? base : base + "/") + "\(APIConfig.apiVersion)/backup"
        guard let url = URL(string: full) else { throw APIError.http(status: 0, message: "bad backup url") }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = blob

        let resp: URLResponse
        do { (_, resp) = try await URLSession.shared.data(for: req) }
        catch { throw APIError.transport(error) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: "Backup upload failed (\(status)).")
        }
    }

    /// Download the sealed blob: GET metadata for the presigned URL, then a plain GET
    /// of the ciphertext from R2. Throws 404 if there is no backup.
    func downloadBackup() async throws -> Data {
        guard let meta = try await fetchBackupMeta() else {
            throw APIError.http(status: 404, message: "No backup to download.")
        }
        guard let url = URL(string: meta.download_url) else {
            throw APIError.http(status: 0, message: "bad download url")
        }
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(from: url) }
        catch { throw APIError.transport(error) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: "Backup download failed (\(status)).")
        }
        return data
    }
}
