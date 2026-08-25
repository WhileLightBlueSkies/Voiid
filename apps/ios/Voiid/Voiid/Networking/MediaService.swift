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
import UIKit

@MainActor
final class MediaService {
    static let shared = MediaService()
    private let api = APIClient()
    private init() {}

    private struct PresignUploadBody: Encodable { let mime: String }
    private struct PresignUploadResp: Decodable { let key: String; let upload_url: String }
    private struct PresignDownloadBody: Encodable { let key: String }
    private struct PresignDownloadResp: Decodable { let download_url: String }

    /// Push `body` to R2 via a presigned PUT and return the opaque object key.
    ///
    /// The parameter is `body`, NOT `ciphertext`. It used to be the latter, which asserted at
    /// every call site that the bytes were already encrypted — and the avatar path passed a
    /// raw JPEG straight into it. The name made that read as correct, which is exactly why the
    /// plaintext-avatar bug survived review. This transport is agnostic: whether the bytes are
    /// encrypted is the CALLER's responsibility, and the two callers now say which they are.
    func upload(body: Data, mime: String) async throws -> String {
        let presign: PresignUploadResp = try await api.request(
            "POST", "media/presign-upload", body: PresignUploadBody(mime: mime))
        guard let url = URL(string: presign.upload_url) else {
            throw APIError.http(status: 0, message: "bad upload url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (_, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: "media upload failed (\(status))")
        }
        return presign.key
    }

    /// Profile photo upload — ⚠️ NOT ENCRYPTED. The server can read these bytes.
    ///
    /// Unlike message media, an avatar has no fixed audience: it is shown to anyone who might
    /// contact you, including a stranger who found your @username and has never had a ratchet
    /// session with you. There is therefore no established channel to deliver a key over.
    ///
    /// The fix is a Signal-style PROFILE KEY — one long-lived key per user, wrapped to each
    /// contact over the ratchet. It is blocked on `encryptMediaWithKey` (e2e-core has only
    /// `encryptMedia`, which always mints a fresh key) and on regenerated uniffi bindings.
    /// See `generate_profile_key` / `encrypt_media_with_key` in packages/e2e-core/src/media.rs.
    ///
    /// Until that ships, the privacy copy must NOT claim avatars are encrypted. It does not.
    func uploadProfilePhoto(_ imageData: Data, mime: String = "image/jpeg") async throws -> String {
        // Named local: the plaintext-ness is stated where it happens, not inferred.
        let plaintextJpeg = imageData
        return try await upload(body: plaintextJpeg, mime: mime)
    }

    /// Community image upload — ⚠️ NOT ENCRYPTED. The server can read these bytes.
    ///
    /// Used by post photos (community_posts.media_url) and community avatars
    /// (communities.avatar_r2_key). Named separately from `uploadProfilePhoto` even though the
    /// transport is identical, because the REASON they are plaintext is different and the
    /// difference matters:
    ///
    ///   A profile photo is plaintext because there is no channel to deliver a key over to a
    ///   stranger who might contact you — a gap that a Signal-style profile key would close,
    ///   and that `uploadProfilePhoto`'s comment tracks as work still to do.
    ///
    ///   A community image is plaintext because it is a BROADCAST and there is nothing to fix.
    ///   047's header: a post is addressed to everyone who might later look, including
    ///   non-members of a discoverable community who hold no MLS key, and there is no key that
    ///   means "everyone who might later look". 030 says the same of the avatar, which is shown
    ///   to strangers deciding whether to join. Encrypting either is not a deferred improvement;
    ///   it is a thing that cannot be done and would break the surface if it were.
    ///
    /// Returns the OPAQUE R2 KEY. It is not fetchable as-is — `MediaKeyResolver` turns it back
    /// into a URL on demand, and `publicCard()` server-side presigns the avatar column before
    /// the card goes on the wire.
    ///
    /// ── DOWNSCALED BEFORE UPLOAD ────────────────────────────────────────────────────
    /// A full-resolution capture from a modern iPhone is several megabytes and the feed card
    /// draws it at 172pt. Uploading the original would spend the poster's data, and every
    /// reader's, on detail no screen in the app can show.
    func uploadCommunityImage(_ image: UIImage, maxDimension: CGFloat = 1600,
                              quality: CGFloat = 0.82) async throws -> String {
        let plaintextJpeg = try Self.downscaledJPEG(image, maxDimension: maxDimension,
                                                    quality: quality)
        return try await upload(body: plaintextJpeg, mime: "image/jpeg")
    }

    /// Fit inside `maxDimension` on the long edge, preserving aspect ratio, then JPEG.
    ///
    /// An image already smaller than the bound is NOT upscaled — enlarging a small photo to hit
    /// a target adds bytes and no detail.
    static func downscaledJPEG(_ image: UIImage, maxDimension: CGFloat,
                               quality: CGFloat) throws -> Data {
        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > maxDimension ? maxDimension / longEdge : 1
        let target = CGSize(width: (image.size.width * scale).rounded(),
                            height: (image.size.height * scale).rounded())

        let rendered = scale < 1
            ? UIGraphicsImageRenderer(size: target).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            : image

        guard let data = rendered.jpegData(compressionQuality: quality) else {
            throw APIError.http(status: 0, message: "couldn’t prepare that image")
        }
        return data
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
