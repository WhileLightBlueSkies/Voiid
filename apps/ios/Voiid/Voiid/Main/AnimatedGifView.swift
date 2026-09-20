//
//  AnimatedGifView.swift
//  Voiid
//
//  A GIF that actually moves.
//
//  ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────
//  SwiftUI has no animated-GIF view. `AsyncImage` and `UIImage(data:)` both decode a
//  GIF to its FIRST FRAME and stop, so every GIF in this app — in the picker grid and
//  in the chat bubble after sending — was a still image. The bytes were always the
//  full animation; nothing was playing them.
//
//  ── WHY UIImageView AND NOT A SwiftUI TIMER ─────────────────────────────────────
//  `UIImage.animatedImage(with:duration:)` hands the whole sequence to UIKit, which
//  drives it on the render server. Animating from a SwiftUI `Timer` would re-run the
//  view body once per frame — for a 30-frame GIF at 20fps, on every visible cell of a
//  scrolling grid — and would stutter under exactly the scrolling this is used in.
//
//  ── PER-FRAME DELAYS ────────────────────────────────────────────────────────────
//  A GIF stores its own delay per frame and they are often unequal. UIKit's animated
//  UIImage takes one total duration and divides it evenly, so the honest way to keep
//  the timing is to repeat frames in proportion to their delay against a fixed tick.
//  Reaction GIFs lean on a long hold at the end, which even division destroys.
//

import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AnimatedGif {

    /// The tick the frame sequence is quantised to. 50fps is finer than any GIF delay in
    /// practice (the format stores delay in hundredths, and browsers clamp anything under
    /// 0.02s), so quantising here does not visibly alter timing.
    private static let tick = 0.02

    /// Decoded sequences, keyed by the caller's cache key. A GIF is decoded once and reused
    /// across the picker grid, the bubble and the full-screen viewer.
    private static var cache = NSCache<NSString, UIImage>()

    /// True when these bytes are a GIF with more than one frame. A single-frame GIF is just
    /// an image and should take the ordinary still path.
    static func isAnimated(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src),
              UTType(type as String) == .gif
        else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// Build an animated `UIImage`, or nil when these bytes are not a multi-frame GIF.
    static func image(from data: Data, key: String? = nil) -> UIImage? {
        if let key, let hit = cache.object(forKey: key as NSString) { return hit }

        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return nil }

        var frames: [UIImage] = []
        var total = 0.0

        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let delay = frameDelay(src, i)
            total += delay

            // Repeat each frame in proportion to its own delay, so a long final hold stays
            // long instead of being averaged away across the sequence.
            let repeats = max(Int((delay / tick).rounded()), 1)
            let frame = UIImage(cgImage: cg)
            frames.append(contentsOf: repeatElement(frame, count: repeats))
        }

        guard let animated = UIImage.animatedImage(with: frames,
                                                   duration: max(total, tick)) else { return nil }
        if let key { cache.setObject(animated, forKey: key as NSString) }
        return animated
    }

    /// A frame's delay in seconds.
    ///
    /// `UnclampedDelayTime` is the true authored value; `DelayTime` is the clamped one. Both
    /// can be zero or absent — GIFs written by older encoders often say 0 meaning "as fast as
    /// possible", which every renderer treats as 0.1s rather than as an infinitely fast loop.
    private static func frameDelay(_ src: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil)
                as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }

        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }

    static func clearCache() { cache.removeAllObjects() }
}

/// Plays an animated `UIImage`. Falls back to drawing a still when the bytes turn out not to
/// be animated, so one call site handles both.
struct AnimatedGifView: UIViewRepresentable {
    let image: UIImage
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = contentMode
        v.clipsToBounds = true
        // PURELY DECORATIVE, AND IT MUST STAY THAT WAY.
        //
        // This view is used as the label of a Button in the GIF picker. A UIKit view hosted
        // in SwiftUI takes part in hit-testing, so without this it eats the tap and the
        // Button never fires — tapping a GIF did nothing at all. UIImageView already
        // defaults this to false, but it is set explicitly because the whole interaction
        // depends on it and a future edit should not be able to flip it by accident.
        v.isUserInteractionEnabled = false
        // Without these the intrinsic size of a large GIF forces the cell wider than its
        // column and the grid's layout breaks.
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.image = image
        v.startAnimating()
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        guard v.image !== image else { return }
        v.contentMode = contentMode
        v.image = image
        v.startAnimating()
    }
}

/// A GIF loaded from a URL, for the picker grid. Shows a placeholder until it arrives, and
/// animates as soon as it does.
struct RemoteGifView: View {
    let url: String
    var contentMode: UIView.ContentMode = .scaleAspectFill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                if image.images == nil {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    AnimatedGifView(image: image, contentMode: contentMode)
                }
            } else {
                Rectangle().fill(VoiidColor.fieldFill)
            }
        }
        // Belt and braces with `isUserInteractionEnabled` on the UIImageView: this view is a
        // Button label in the picker, so nothing inside it may absorb a touch.
        .allowsHitTesting(false)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let u = URL(string: url) else { return }
        // The preview renditions are small and the grid is scrolled quickly; the shared URL
        // cache is what stops a scroll back up from refetching every cell.
        guard let (data, _) = try? await URLSession.shared.data(from: u) else { return }
        guard !Task.isCancelled else { return }
        image = AnimatedGif.image(from: data, key: url) ?? UIImage(data: data)
    }
}
