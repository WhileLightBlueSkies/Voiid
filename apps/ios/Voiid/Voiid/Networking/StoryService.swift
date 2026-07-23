//
//  StoryService.swift
//  Voiid
//
//  Thin API layer for the Stories endpoints (backend/api/src/routes/stories.ts). Pure
//  transport + DTOs — it never touches crypto and never sees a media key. The per-device
//  ciphertexts it ships are built by ChatEngine's fan-out; the blob it presigns is already
//  ciphertext. See docs/STORIES_PROTOCOL.md.
//

import Foundation

@MainActor
final class StoryService {
    static let shared = StoryService()
    private let api = APIClient()
    private init() {}

    // MARK: - Wire DTOs

    /// One target device's key material in a fan-out (POST /stories and /:id/keys, and
    /// receipts). Matches the server's `{recipient_device_id, ciphertext(b64)}` shape.
    struct KeyEntry: Codable {
        let recipient_device_id: String
        let ciphertext: String
    }

    struct PresignUploadResp: Decodable { let key: String; let upload_url: String }

    struct PostStoryResp: Decodable {
        let story_id: String
        let created_at: String
        let expires_at: String
        var delivered_devices: Int = 0
    }

    /// A story row as the feed hands it back, plus THIS device's own key blob.
    struct FeedStory: Decodable {
        let story_id: String
        let author_id: String
        var author_device_id: String?
        let r2_key: String
        let media_mime: String
        var byte_size: Int?
        let created_at: String
        let expires_at: String
        let ciphertext: String        // Session.encrypt(envelope) for this device
    }
    struct FeedResp: Decodable { let stories: [FeedStory] }

    struct MineStory: Decodable {
        let story_id: String
        let r2_key: String
        let media_mime: String
        var byte_size: Int?
        let created_at: String
        let expires_at: String
        var recipient_device_count: Int = 0
        var delivered_device_count: Int = 0
    }
    struct MineResp: Decodable { let stories: [MineStory] }

    struct PresignDownloadResp: Decodable { let download_url: String }

    struct ReceiptRow: Decodable {
        let id: String
        let story_id: String
        let ciphertext: String
        let created_at: String
    }
    struct ReceiptsResp: Decodable { let receipts: [ReceiptRow] }

    // MARK: - Endpoints

    /// §7.1 — a presigned PUT for the story ciphertext. `mime` is the WRAPPER type; the
    /// real media type rides encrypted in the envelope.
    func presignUpload(mime: String = "application/octet-stream") async throws -> PresignUploadResp {
        struct Body: Encodable { let mime: String }
        return try await api.request("POST", "stories/presign-upload", body: Body(mime: mime))
    }

    /// §7.2 — create the story row + fan out per-device key blobs.
    func postStory(storyId: String, r2Key: String, mediaMime: String, byteSize: Int,
                   senderDeviceId: String?, keys: [KeyEntry]) async throws -> PostStoryResp {
        struct Body: Encodable {
            let story_id: String; let r2_key: String; let media_mime: String
            let byte_size: Int; let sender_device_id: String?; let keys: [KeyEntry]
        }
        return try await api.request("POST", "stories", body: Body(
            story_id: storyId, r2_key: r2Key, media_mime: mediaMime, byte_size: byteSize,
            sender_device_id: senderDeviceId, keys: keys))
    }

    /// §7.3 — this device's pending story key blobs (atomic mark-and-return).
    /// `includeDelivered` re-fetches already-delivered live rows after a reinstall.
    func feed(deviceId: String, includeDelivered: Bool = false) async throws -> [FeedStory] {
        var path = "stories/feed?device_id=\(deviceId)"
        if includeDelivered { path += "&include_delivered=1" }
        let resp: FeedResp = try await api.request("GET", path)
        return resp.stories
    }

    /// §7.4 — my own live stories + delivered-device counts.
    func mine(deviceId: String) async throws -> [MineStory] {
        let resp: MineResp = try await api.request("GET", "stories/mine?device_id=\(deviceId)")
        return resp.stories
    }

    /// §7.5 — a presigned GET for a story's ciphertext, entitlement-checked server-side.
    func presignDownload(storyId: String) async throws -> String {
        struct Body: Encodable { let story_id: String }
        let resp: PresignDownloadResp = try await api.request("POST", "stories/presign-download", body: Body(story_id: storyId))
        return resp.download_url
    }

    /// §7.6 — author-only delete. Not a security operation (already-downloaded copies survive).
    func delete(storyId: String) async throws {
        _ = try await api.request("DELETE", "stories/\(storyId)") as EmptyResponse
    }

    /// §7.7 — post a view receipt fanned out to the author's devices.
    func postReceipt(storyId: String, receipts: [KeyEntry]) async throws {
        struct Body: Encodable { let receipts: [KeyEntry] }
        _ = try await api.request("POST", "stories/\(storyId)/receipt", body: Body(receipts: receipts)) as EmptyResponse
    }

    /// §7.8 — append key material for devices skipped at post time / newly registered.
    func addKeys(storyId: String, keys: [KeyEntry]) async throws {
        struct Body: Encodable { let keys: [KeyEntry] }
        _ = try await api.request("POST", "stories/\(storyId)/keys", body: Body(keys: keys)) as EmptyResponse
    }

    /// §7.9 — an author device pulls pending view receipts (atomic mark-and-return).
    func receipts(deviceId: String) async throws -> [ReceiptRow] {
        let resp: ReceiptsResp = try await api.request("GET", "stories/receipts?device_id=\(deviceId)")
        return resp.receipts
    }
}
