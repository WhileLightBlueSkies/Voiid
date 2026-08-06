//
//  StoryMedia.swift
//  Voiid
//
//  Media plumbing for the story viewer: a downsampling still-image loader, an
//  AVPlayerLayer host, and a two-deep player pool.
//
//  These are Stories siblings of the Clips equivalents rather than shared code. Clips
//  loads remote URLs into a looping reels feed; a story is an already-decrypted LOCAL
//  file that plays once and then advances. `ClipPlayerLayerView` is the one real
//  duplicate — it is private to ClipFullscreenView.swift and both screens need the same
//  thing from it (a settable `videoGravity`).
//
//  Everything here operates on plaintext that StoryEngine has already decrypted to the
//  app's own cache directory. Nothing in this file touches the network.
//

import AVFoundation
import ImageIO
import SwiftUI
import UIKit
import Combine

// MARK: - Downsampled stills

/// Decodes story stills OFF the main thread and at DISPLAY size.
///
/// A story image is capped at 10MB, i.e. easily 12MP. Decoding one full-size inside a
/// `@ViewBuilder` stalled the main thread for hundreds of milliseconds — and the viewer's
/// 30 Hz progress tick invalidates that body, so the same photo was read and decoded up to
/// thirty times a second for as long as it was on screen. `CGImageSourceCreateThumbnailAtIndex`
/// bounded to the screen's longest edge gives us exactly one decode at the size we draw.
@MainActor
final class StoryImageCache {
    static let shared = StoryImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Deliberately tiny: the story on screen, its neighbours in this context, and
        // whatever the user just stepped back through. A story viewer is a walk, not a grid.
        //
        // The count is generous relative to the cost because the prefetch window also stores a
        // ~96px backdrop per story — a dozen of those together cost less than half a megabyte,
        // and a count of 6 would have let them evict the screen-sized still they sit behind.
        // The COST is the real bound: two screen-sized stills, which is the two-deep window.
        cache.countLimit = 12
        cache.totalCostLimit = 48 << 20
    }

    /// Longest edge of the blurred backdrop copy. Tiny on purpose: it is blurred past
    /// recognition and stretched to fill, so the upscale does most of the blurring for free.
    static let backdropPixel: CGFloat = 96

    func image(at url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.path)|\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let decoded = await Task.detached(priority: .userInitiated) {
            StoryImageCache.downsample(url, maxPixel: maxPixel)
        }.value

        guard let decoded else { return nil }
        cache.setObject(decoded, forKey: key, cost: decoded.decodedCost)
        return decoded
    }

    /// The source for the blurred fill behind a story that does not match the screen's aspect.
    /// A video's comes from its first frame, which is also why this cannot just be `image(at:)`.
    ///
    /// Deliberately a SEPARATE, tiny decode rather than a reuse of the display-size copy: the
    /// blur is re-rasterised whenever the view body is invalidated, and the viewer's body is
    /// invalidated 30 times a second by the progress tick.
    func backdrop(at url: URL, isVideo: Bool) async -> UIImage? {
        guard isVideo else { return await image(at: url, maxPixel: Self.backdropPixel) }

        let key = "\(url.path)|backdrop" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let frame = await StoryImageCache.firstFrame(url, maxPixel: Self.backdropPixel) else {
            return nil
        }
        cache.setObject(frame, forKey: key, cost: frame.decodedCost)
        return frame
    }

    nonisolated private static func firstFrame(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // Zero tolerance forces an exact-PTS seek, which long-GOP H.264 often fails outright;
        // any frame near the top is indistinguishable once it has been blurred.
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let (cg, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// `static` so it runs on the detached task's thread rather than hopping back to the
    /// main actor, which is the entire point of the exercise.
    /// NONISOLATED on purpose. The class is @MainActor so the cache is only ever touched from
    /// the main thread, but this is a pure CGImageSource decode with no shared state — and it is
    /// called from a detached task precisely so the decode does NOT happen on the main thread.
    /// Inheriting the actor here would put the work straight back where the bug was.
    nonisolated private static func downsample(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bake in the EXIF orientation: the thumbnail is a raw CGImage, so a photo shot
            // in portrait would otherwise come back on its side.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode here, on this thread, instead of lazily on first draw — deferring it
            // would just move the stall back onto the main thread.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}

private extension UIImage {
    var decodedCost: Int { Int(size.width * size.height * scale * scale * 4) }
}

// MARK: - AVPlayerLayer host

/// A UIView backed by `AVPlayerLayer` so `videoGravity` is settable.
///
/// SwiftUI's `VideoPlayer` cannot do this — it always letterboxes and always brings its own
/// transport controls, which `.disabled(true)` hides from touch but still lays out and
/// composites. `.resizeAspect` shows the whole frame at its true aspect ratio.
struct StoryPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Player pool

/// Holds the player for the story on screen and, when it is a video, the one after it.
///
/// Before this, `loadCurrent()` built a fresh `AVPlayer(url:)` per step and threw the old
/// one away, so every forward tap onto a video paid a cold asset load plus a first-frame
/// decode behind a spinner. Keeping the NEXT one warm turns that into a resume.
///
/// The bound matters as much as the warmth: an unreleased player per story is a live
/// decoder and an audio session participant, and audio bleeding from a page the user has
/// already left is the classic failure here — every exit path calls `releaseAll()`.
@MainActor
final class StoryPlayerPool: ObservableObject {
    @Published private var players: [String: AVPlayer] = [:]

    func player(for id: String) -> AVPlayer? { players[id] }

    /// `url` is a local plaintext file StoryEngine has already downloaded and decrypted.
    func prepare(id: String, url: URL, muted: Bool) {
        if let existing = players[id] {
            existing.isMuted = muted
            return
        }
        let player = AVPlayer(url: url)
        player.isMuted = muted
        players[id] = player
    }

    /// Makes `id` the only player running. `restart` replays from the top, which is what
    /// stepping back onto a story the user already watched has to do.
    func activate(_ id: String, restart: Bool) {
        for (key, player) in players where key != id { player.pause() }
        guard let player = players[id] else { return }
        if restart { player.seek(to: .zero) }
        player.play()
    }

    func pauseAll() {
        for (_, player) in players { player.pause() }
    }

    func retainOnly(_ ids: [String]) {
        let keep = Set(ids)
        for (id, player) in players where !keep.contains(id) {
            player.pause()
            player.replaceCurrentItem(with: nil)
            players[id] = nil
        }
    }

    func releaseAll() { retainOnly([]) }
}

// MARK: - Safe area

enum StorySafeArea {
    /// The viewer's pages ignore the safe area so media fills the physical screen, which
    /// means the chrome has to re-apply the insets by hand. `GeometryProxy.safeAreaInsets`
    /// is the right source, but it reads zero once the region it measures has already been
    /// expanded, so fall back to the window's own insets — anything hardcoded (the previous
    /// `.padding(.top, 44)`) is wrong on an SE and wrong again on a Dynamic Island.
    static func resolve(_ proxy: EdgeInsets) -> EdgeInsets {
        if proxy.top > 0 || proxy.bottom > 0 { return proxy }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
        return EdgeInsets(top: window.top, leading: window.left,
                          bottom: window.bottom, trailing: window.right)
    }
}
