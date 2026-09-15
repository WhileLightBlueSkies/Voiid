//
//  AvatarCache.swift
//  Voiid
//
//  One shared cache for profile/avatar images, so a photo is fetched ONCE and then
//  rendered instantly everywhere it appears (own profile, chat grid, contact card,
//  call screen, map markers). Before this, every ProfileAvatarButton re-ran a
//  two-request presigned download on each appearance.
//
//  A `photo_url` may be an ABSOLUTE URL (older/profile CDN) or an opaque R2 OBJECT KEY
//  (uploaded via MediaService, needs a presigned GET). This resolves both.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  I02 — WHAT WAS WRONG, AND WHY IT ONLY HURT AT SCALE
//  ─────────────────────────────────────────────────────────────────────────────
//
//  This was a `[String: UIImage]` on the main actor with no bound of any kind, and
//  five separate problems that all pointed the same way — they were invisible with
//  a handful of contacts and progressively worse with a real address book:
//
//  1. UNBOUNDED MEMORY. Nothing was ever evicted. A full-resolution avatar decoded
//     to a UIImage is ~4 bytes/pixel: one 1024x1024 photo is 4MB in memory, not the
//     ~100KB its JPEG suggests. Scrolling a few hundred contacts was hundreds of
//     megabytes, and the OS resolves that by killing the app.
//  2. SYNCHRONOUS DISK IN A VIEW BODY. `cached(_:)` did `Data(contentsOf:)` on a
//     miss, and it is called from `.onAppear`/body. Every miss was a blocking file
//     read on the rendering thread — exactly the stall I02 names.
//  3. NO DOWNSAMPLING. A 4000x3000 camera photo was decoded at full size to be
//     drawn in a 40pt circle: ~48MB resident to show 1600 pixels.
//  4. NO COALESCING. Ten cells appearing at once for the same ref started ten
//     downloads of the same bytes.
//  5. NO VALIDATION. Any HTTP response body was handed to `UIImage(data:)` with no
//     status check and no size limit, so an error page or a huge body was decoded.
//
//  THE SHAPE OF THE FIX. `NSCache` for memory (cost-bounded in BYTES, and it drops
//  entries under memory pressure on its own, which a Dictionary cannot). Disk reads,
//  decoding and JPEG encoding move off the main actor to a dedicated actor. The
//  synchronous accessor stays — SwiftUI needs something for the first paint — but it
//  is now a MEMORY-ONLY lookup that never touches the disk, with the disk read
//  promoted to the async path.
//

import UIKit
import CryptoKit

/// Off-main-actor owner of everything slow: disk reads, image decoding, downsampling
/// and JPEG encoding. Serialized by being an actor, so concurrent avatar requests
/// cannot pile up on the rendering thread.
actor AvatarStorage {
    static let shared = AvatarStorage()

    /// `<app-group>/avatars/` — avatars persisted so a face renders instantly on the
    /// next launch and OFFLINE. Nil only if the app-group entitlement is missing
    /// (then memory-only).
    private let dir: URL? = {
        guard let base = AppGroup.containerURL else { return nil }
        let d = base.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// In-flight downloads by ref, so N cells appearing at once share ONE request.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Avatars are drawn small. 256pt at 3x covers every call site (the largest is a
    /// profile header) with room to spare, and caps a 4000x3000 camera photo at ~3MB
    /// resident instead of ~48MB.
    static let maxPixelSize: CGFloat = 768

    /// Refuse a body larger than this before decoding it. A profile photo is not 20MB,
    /// and `UIImage(data:)` on an attacker-chosen body is not somewhere to find out.
    static let maxBytes = 20 * 1024 * 1024

    private func fileURL(_ ref: String) -> URL? {
        guard let dir else { return nil }
        let name = SHA256.hash(data: Data(ref.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name)
    }

    /// Decode at a bounded pixel size. ImageIO downsamples while decoding, so the
    /// full-size bitmap never exists — unlike `UIImage(data:)` then resize, which
    /// allocates the full thing first and is what made this expensive.
    nonisolated static func downsample(_ data: Data, pixelLimit: CGFloat = maxPixelSize) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else {
            return nil
        }
        // Generate from the source pixels rather than an embedded low-resolution thumbnail.
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else {
            // Not something ImageIO recognises. Do NOT fall back to UIImage(data:) —
            // that is the unbounded decode this exists to avoid.
            return nil
        }
        // scale 1: the CGImage is already at its final pixel size, and letting UIImage
        // apply the screen scale would misreport both its size and its cost.
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// Read one avatar from disk, off the main actor. Returns nil on a miss.
    func loadFromDisk(_ ref: String) -> UIImage? {
        guard let url = fileURL(ref),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return Self.downsample(data)
    }

    func writeToDisk(_ data: Data, ref: String) {
        guard let url = fileURL(ref) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Encode for disk off the main actor — this was a main-thread JPEG encode before.
    nonisolated static func encode(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: 0.9)
    }

    /// Fetch, validate, downsample and persist — coalescing concurrent callers for the
    /// same ref onto a single task.
    func fetch(_ ref: String) async -> UIImage? {
        if let existing = inFlight[ref] { return await existing.value }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            if let onDisk = await self.loadFromDisk(ref) { return onDisk }
            guard let data = await Self.download(ref), data.count <= Self.maxBytes,
                  let image = Self.downsample(data)
            else { return nil }
            await self.writeToDisk(data, ref: ref)
            return image
        }
        inFlight[ref] = task
        let image = await task.value
        inFlight[ref] = nil
        return image
    }

    /// Absolute URL, or an R2 key via presigned GET. Validates the HTTP status before
    /// returning a body — an error page is not an avatar.
    private nonisolated static func download(_ ref: String) async -> Data? {
        if ref.hasPrefix("http"), let url = URL(string: ref) {
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            return data
        }
        return try? await MediaService.shared.download(key: ref)
    }

    func expandedPhoto(_ ref: String) async -> UIImage? {
        if let url = fileURL(ref), let data = try? Data(contentsOf: url), data.count <= Self.maxBytes,
           let image = Self.downsample(data, pixelLimit: 1200) { return image }
        guard let data = await Self.download(ref), data.count <= Self.maxBytes else { return nil }
        return Self.downsample(data, pixelLimit: 1200)
    }

    func removeAll() {
        inFlight.removeAll()
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

@MainActor
enum AvatarCache {
    /// Cost-bounded in BYTES, not entry count: avatars differ in size by orders of
    /// magnitude, so counting entries bounds nothing that matters. NSCache also evicts
    /// under system memory pressure by itself, which is why it is here rather than a
    /// Dictionary plus a hand-rolled LRU.
    private static let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 48 * 1024 * 1024   // ~48MB of decoded avatars
        c.countLimit = 512
        return c
    }()

    /// Approximate resident bytes of a decoded image: 4 bytes per pixel.
    private static func cost(_ image: UIImage) -> Int {
        let px = image.size.width * image.scale * image.size.height * image.scale
        return Int(px * 4)
    }

    /// Synchronous cache hit — safe to call from a SwiftUI body for an instant first
    /// paint.
    ///
    /// MEMORY ONLY, deliberately. This used to fall through to `Data(contentsOf:)` on a
    /// miss, which put a blocking disk read and a full-size image decode on the
    /// rendering thread every time an uncached avatar scrolled into view. A miss now
    /// simply returns nil; the caller shows its placeholder and awaits `resolve`, which
    /// does the disk read off the main actor.
    static func cached(_ ref: String?) -> UIImage? {
        guard let ref, !ref.isEmpty else { return nil }
        return memory.object(forKey: ref as NSString)
    }

    /// Resolve a photo reference to an image, caching the result (memory + disk).
    /// Concurrent callers for the same ref share one download.
    static func resolve(_ ref: String?) async -> UIImage? {
        guard let ref, !ref.isEmpty else { return nil }
        if let hit = cached(ref) { return hit }
        guard let image = await AvatarStorage.shared.fetch(ref) else { return nil }
        memory.setObject(image, forKey: ref as NSString, cost: cost(image))
        return image
    }

    /// Cache an avatar we ALREADY hold the bytes for (e.g. one we just uploaded), so it
    /// renders instantly and offline with no download.
    ///
    /// The disk write and any JPEG encoding happen off the main actor; only the memory
    /// insert is synchronous, so the caller sees the new photo immediately.
    static func store(_ image: UIImage, data: Data? = nil, forKey ref: String) {
        guard !ref.isEmpty else { return }
        let display = data.flatMap { AvatarStorage.downsample($0) } ?? image
        memory.setObject(display, forKey: ref as NSString, cost: cost(display))
        Task.detached(priority: .utility) {
            guard let bytes = data ?? AvatarStorage.encode(image) else { return }
            await AvatarStorage.shared.writeToDisk(bytes, ref: ref)
        }
    }

    /// Drop everything (sign-out), memory AND disk: the next account must not see the
    /// previous one's faces.
    ///
    /// Memory is cleared SYNCHRONOUSLY. The disk wipe is async, but the memory cache is
    /// emptied before this returns, so no already-decoded face can be handed out while
    /// the files are still being removed.
    static func clear() {
        memory.removeAllObjects()
        Task.detached(priority: .utility) { await AvatarStorage.shared.removeAll() }
    }
}
