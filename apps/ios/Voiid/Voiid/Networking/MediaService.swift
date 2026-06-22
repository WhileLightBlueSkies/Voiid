//
//  MediaService.swift
//  Voiid
//
//  Media blob transport. The blob is encrypted ON-DEVICE (e2e-core encryptMedia)
//  before it ever leaves; the server only signs short-lived R2 URLs and never
//  sees the bytes or the media key. This service:
//    - asks the backend for a presigned PUT url (POST /media/presign-upload)
//    - PUTs the CIPHERTEXT straight to R2
//    - asks for a presigned GET url (POST /media/presign-download) and downloads
//  The per-message media key travels INSIDE the E2EE message (see ChatEngine),
//  not here.
//

import Foundation

@MainActor
final class MediaService {
    static let shared = MediaService()
    private let api = APIClient()
    private init() {}

    private struct PresignUploadBody: Encodable { let mime: String }
    private struct PresignUploadResp: Decodable { let key: String; let upload_url: String }
    private struct PresignDownloadBody: Encodable { let key: String }
    private struct PresignDownloadResp: Decodable { let download_url: String }

    /// Encrypted upload: get a presigned PUT, push the ciphertext to R2, return
    /// the opaque object key (which the caller embeds in the E2EE message).
    func upload(ciphertext: Data, mime: String) async throws -> String {
        let presign: PresignUploadResp = try await api.request(
            "POST", "media/presign-upload", body: PresignUploadBody(mime: mime))
        guard let url = URL(string: presign.upload_url) else {
            throw APIError.http(status: 0, message: "bad upload url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.httpBody = ciphertext
        let (_, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: "media upload failed (\(status))")
        }
        return presign.key
    }

    /// Encrypted download: get a presigned GET for `key`, fetch the ciphertext.
    func download(key: String) async throws -> Data {
        let presign: PresignDownloadResp = try await api.request(
            "POST", "media/presign-download", body: PresignDownloadBody(key: key))
        guard let url = URL(string: presign.download_url) else {
            throw APIError.http(status: 0, message: "bad download url")
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: "media download failed (\(status))")
        }
        return data
    }
}
