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

@MainActor
enum AvatarCache {
    private static var cache: [String: UIImage] = [:]

    /// Synchronous cache hit — use in a SwiftUI body for an instant first paint.
    static func cached(_ ref: String?) -> UIImage? {
        guard let ref, !ref.isEmpty else { return nil }
        return cache[ref]
    }

    /// Resolve a photo reference to an image, caching the result. Returns the cached image
    /// immediately if present; otherwise fetches (absolute URL, or R2 key via presigned GET).
    static func resolve(_ ref: String?) async -> UIImage? {
        guard let ref, !ref.isEmpty else { return nil }
        if let hit = cache[ref] { return hit }
        let image: UIImage?
        if ref.hasPrefix("http"), let url = URL(string: ref) {
            image = (try? await URLSession.shared.data(from: url)).flatMap { UIImage(data: $0.0) }
        } else {
            image = (try? await MediaService.shared.download(key: ref)).flatMap { UIImage(data: $0) }
        }
        if let image { cache[ref] = image }
        return image
    }

    /// Drop everything (sign-out): the next account must not see the previous one's faces.
    static func clear() { cache.removeAll() }
}
