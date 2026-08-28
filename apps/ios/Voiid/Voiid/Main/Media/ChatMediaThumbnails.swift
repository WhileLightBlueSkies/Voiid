//
//  ChatMediaThumbnails.swift
//  Voiid
//
//  Thumbnails for the media viewer's filmstrip.
//
//  ── WHY NOT JUST UIImage(data:) ─────────────────────────────────────────────────
//  A full decode allocates the image at its NATIVE size — a 12MP photo is ~48MB in memory
//  — and then throws almost all of it away to draw a 50pt square. A strip of forty of those
//  is gigabytes of transient allocation and a visible stall on every scroll.
//
//  `CGImageSourceCreateThumbnailAtIndex` decodes DIRECTLY to the requested size, so the
//  large bitmap never exists. `kCGImageSourceCreateThumbnailFromImageAlways` matters: without
//  it, files with no embedded thumbnail silently return nil.
//
//  ── AND WHY OFF THE MAIN THREAD ─────────────────────────────────────────────────
//  Even the cheap decode is milliseconds, and the filmstrip asks for many at once while it
//  is being scrolled. On the main thread that is dropped frames during the exact gesture
//  the thumbnails exist to serve.
//

import UIKit
import ImageIO
import AVFoundation

@MainActor
final class ChatMediaThumbnails {
    static let shared = ChatMediaThumbnails()

    /// Keyed by message id. NSCache rather than a dictionary so the system can evict under
    /// pressure instead of the strip becoming a memory leak on a chat with a thousand photos.
    private let cache = NSCache<NSString, UIImage>()
    /// In-flight requests, so scrolling past the same item twice does not decode it twice.
    private var inFlight: Set<String> = []

    private init() {
        cache.countLimit = 300
    }

    func cached(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }

    /// Decode a thumbnail, or return the cached one. `nil` means the bytes are not available
    /// yet — the caller shows a placeholder and the item stays in the strip.
    func thumbnail(for item: ChatMediaItem, side: CGFloat = 50) async -> UIImage? {
        if let hit = cached(item.id) { return hit }
        guard !inFlight.contains(item.id) else { return nil }
        inFlight.insert(item.id)
        defer { inFlight.remove(item.id) }

        // Local-first, exactly like the bubbles: memory → disk → network. A photo already
        // seen has its plaintext on disk and never touches the network again.
        let data: Data
        if let have = MediaCache.shared.data(item.ref.mediaUrl) {
            data = have
        } else if let fetched = try? await ChatEngine.shared.fetchMedia(item.ref) {
            MediaCache.shared.setData(fetched, item.ref.mediaUrl)
            data = fetched
        } else {
            return nil
        }

        // Retina: the strip draws at `side` points, so decode to the pixel size that
        // actually lands on screen or the thumbnails are visibly soft.
        let pixels = side * (UIScreen.main.scale)
        let kind = item.type
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            kind == .video ? Self.videoFrame(data, pixels: pixels)
                           : Self.imageThumb(data, pixels: pixels)
        }.value

        if let image { cache.setObject(image, forKey: item.id as NSString) }
        return image
    }

    // MARK: - Decoders (off-main)

    private nonisolated static func imageThumb(_ data: Data, pixels: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            // Without this, a file with no embedded thumbnail returns nil rather than
            // decoding one — which is most photos taken on a phone.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            // Honour EXIF rotation here, or portrait photos land sideways in the strip.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    /// A poster frame for a video. Written to a temp file because AVAsset cannot read from
    /// memory — the same constraint the gallery's player has.
    private nonisolated static func videoFrame(_ data: Data, pixels: CGFloat) -> UIImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil else { return nil }

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: tmp))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: pixels, height: pixels)
        // Half a second in, not zero: the first frame of a video is very often black.
        let at = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: at, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}
