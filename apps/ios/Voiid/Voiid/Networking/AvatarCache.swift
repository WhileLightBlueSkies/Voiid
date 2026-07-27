//
//  AvatarCache.swift
//  Voiid
//
//  One shared in-memory cache for profile/avatar images, so a photo is fetched ONCE and
//  then rendered instantly everywhere it appears (own profile, chat grid, contact card,
//  call screen, map markers). Before this, every ProfileAvatarButton re-ran a two-request
//  presigned download on each appearance — which is why your own profile photo took a
//  couple of seconds to show and peer photos never cached.
//
//  A `photo_url` may be an ABSOLUTE URL (older/profile CDN) or an opaque R2 OBJECT KEY
//  (uploaded via MediaService, needs a presigned GET). This resolves both.
//

import UIKit
import CryptoKit

@MainActor
enum AvatarCache {
    private static var cache: [String: UIImage] = [:]

    /// `<app-group>/avatars/` — avatars persisted to disk so a face (yours or a peer's)
    /// renders instantly on the next launch and OFFLINE, never re-downloaded. Nil only if the
    /// app-group entitlement is missing (then memory-only).
    private static let dir: URL? = {
        guard let base = AppGroup.containerURL else { return nil }
        let d = base.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static func fileURL(_ ref: String) -> URL? {
        guard let dir else { return nil }
        let name = SHA256.hash(data: Data(ref.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name)
    }

    /// Synchronous cache hit (memory → disk) — use in a SwiftUI body for an instant first
    /// paint. The disk read happens at most once per ref per launch; it's then memoized.
    static func cached(_ ref: String?) -> UIImage? {
        guard let ref, !ref.isEmpty else { return nil }
        if let hit = cache[ref] { return hit }
        guard let url = fileURL(ref), let d = try? Data(contentsOf: url),
              let img = UIImage(data: d) else { return nil }
        cache[ref] = img
        return img
    }

    /// Resolve a photo reference to an image, caching the result (memory + disk). Returns a
    /// cached image immediately if present; otherwise fetches (absolute URL, or R2 key via
    /// presigned GET) and persists it.
    static func resolve(_ ref: String?) async -> UIImage? {
        guard let ref, !ref.isEmpty else { return nil }
        if let hit = cached(ref) { return hit }
        let data: Data?
        if ref.hasPrefix("http"), let url = URL(string: ref) {
            data = (try? await URLSession.shared.data(from: url))?.0
        } else {
            data = try? await MediaService.shared.download(key: ref)
        }
        guard let data, let image = UIImage(data: data) else { return nil }
        store(image, data: data, forKey: ref)
        return image
    }

    /// Cache an avatar we ALREADY hold the bytes for (e.g. one we just uploaded), so it
    /// renders instantly and offline with no download — this is what fixes the 15–20s wait
    /// after changing your profile photo.
    static func store(_ image: UIImage, data: Data? = nil, forKey ref: String) {
        guard !ref.isEmpty else { return }
        cache[ref] = image
        let bytes = data ?? image.jpegData(compressionQuality: 0.9)
        if let bytes, let url = fileURL(ref) {
            try? bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Drop everything (sign-out), memory AND disk: the next account must not see the
    /// previous one's faces.
    static func clear() {
        cache.removeAll()
        if let dir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
