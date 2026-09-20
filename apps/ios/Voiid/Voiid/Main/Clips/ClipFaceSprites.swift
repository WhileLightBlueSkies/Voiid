//
//  ClipFaceSprites.swift
//  Voiid
//
//  Photoreal filter art and its placement. The Swift half of the same table Android
//  carries in ClipFaceSprites.kt, against the same 19 PNGs — the two platforms must
//  agree on where a dog's ear goes, so the numbers live in one shape on both.
//
//  Everything is expressed in units of D, the interocular distance, which is the only
//  measurement that scales with the face and is independent of camera resolution, lens
//  and distance. Height is never specified: it comes from each bitmap's aspect ratio.
//
//  Reference proportions, measured on device:
//    top of head  ~1.9 D above the eye line   (NOT the detector's box, which stops at the brow)
//    head width   ~2.6 D
//    nose base    ~0.55 D below the eye line
//    mouth        ~1.0 D below the eye line
//

import CoreImage
import UIKit

enum FxAnchor {
    case eyes
    case nose
    case mouth
}

/// One drawn piece.
///
/// - `pivotX` / `pivotYFromTop`: where the anchor sits INSIDE the bitmap, as a fraction.
///   Measured, not guessed — the tiger mask's eye holes are at 0.42 of its height and the
///   tiger muzzle's nose pad at 0.22, so pinning either by its centre hangs the feature
///   off the face. Stated from the TOP to match the Android table; Core Image's y axis
///   points up, so the renderer converts.
/// - `mirrored`: one bitmap, drawn twice, flipped on the far side. Two ears cut from one
///   sprite can never drift apart.
struct FxLayer {
    let asset: String
    let anchor: FxAnchor
    let widthD: CGFloat
    var riseD: CGFloat = 0
    var outD: CGFloat = 0
    var mirrored: Bool = false
    var flipBase: Bool = false
    var wobble: Bool = false
    var openMouth: CGFloat? = nil
    var pivotX: CGFloat = 0.5
    var pivotYFromTop: CGFloat = 0.5
}

enum ClipFaceArt {

    /// Drawn in order, so anything meant to sit behind the face comes first.
    static let layers: [ClipFaceEffect: [FxLayer]] = [
        .none: [],

        .dog: [
            FxLayer(asset: "dog_ear_left", anchor: .eyes, widthD: 0.95, riseD: 1.35,
                    outD: 0.95, mirrored: true, wobble: true),
            FxLayer(asset: "dog_nose", anchor: .nose, widthD: 0.82, riseD: -0.04,
                    pivotYFromTop: 0.47),
            // Only once the mouth actually opens, which is the whole joke.
            FxLayer(asset: "dog_tongue", anchor: .mouth, widthD: 0.50, riseD: -0.42,
                    openMouth: 0.15, pivotYFromTop: 0.10),
        ],

        .tiger: [
            FxLayer(asset: "tiger_ear_left", anchor: .eyes, widthD: 0.85, riseD: 1.28,
                    outD: 0.86, mirrored: true, wobble: true),
            // Mask and muzzle together make the face, each pinned by its own feature.
            FxLayer(asset: "tiger_stripes", anchor: .eyes, widthD: 2.50, riseD: 0,
                    pivotYFromTop: 0.42),
            FxLayer(asset: "tiger_nose", anchor: .nose, widthD: 1.60, riseD: -0.02,
                    pivotYFromTop: 0.22),
        ],

        .party: [
            FxLayer(asset: "party_hat", anchor: .eyes, widthD: 1.15, riseD: 2.55),
        ],

        .cyber: [
            FxLayer(asset: "cyber_visor", anchor: .eyes, widthD: 2.35, riseD: 0.06),
        ],

        .bunny: [
            FxLayer(asset: "bunny_ear_left", anchor: .eyes, widthD: 0.46, riseD: 2.10,
                    outD: 0.48, mirrored: true, wobble: true),
            FxLayer(asset: "bunny_nose", anchor: .nose, widthD: 1.10, riseD: -0.02,
                    pivotYFromTop: 0.29),
        ],

        .koala: [
            FxLayer(asset: "koala_ear_left", anchor: .eyes, widthD: 1.15, riseD: 1.45,
                    outD: 1.20, mirrored: true, wobble: true),
            FxLayer(asset: "koala_nose", anchor: .nose, widthD: 0.86, riseD: -0.02,
                    pivotYFromTop: 0.58),
        ],

        .cat: [
            FxLayer(asset: "cat_ear_left", anchor: .eyes, widthD: 0.88, riseD: 1.50,
                    outD: 0.88, mirrored: true, flipBase: true, wobble: true),
            // A muzzle, not a nose: it has to reach the mouth.
            FxLayer(asset: "cat_nose", anchor: .nose, widthD: 1.50, riseD: -0.02,
                    pivotYFromTop: 0.44),
            FxLayer(asset: "cat_whiskers", anchor: .nose, widthD: 2.45, riseD: -0.02),
        ],

        .sunglasses: [
            FxLayer(asset: "sunglasses", anchor: .eyes, widthD: 2.35, riseD: 0.06),
        ],

        // Sized to the head (~2.6 D) rather than the face box, and low enough that the
        // band beds into the hair instead of hovering above it.
        .crown: [
            FxLayer(asset: "crown", anchor: .eyes, widthD: 2.85, riseD: 1.95),
        ],

        .halo: [
            FxLayer(asset: "halo", anchor: .eyes, widthD: 2.45, riseD: 2.50),
        ],

        // flipBase: the source horn curves one way, and drawn unflipped on the left the
        // pair curled inward at each other like ram's horns.
        .devil: [
            FxLayer(asset: "devil_horn_left", anchor: .eyes, widthD: 0.60, riseD: 1.85,
                    outD: 0.60, mirrored: true, flipBase: true),
        ],
    ]
}

/// Loads and holds the filter bitmaps.
///
/// A miss returns nil and the layer is skipped rather than trapping: a filter with one
/// missing piece is still usable, a camera that crashes is not.
enum ClipFaceAssets {

    private static var cache: [String: CIImage] = [:]
    private static let lock = NSLock()

    static func image(named name: String) -> CIImage? {
        lock.lock()
        if let hit = cache[name] { lock.unlock(); return hit }
        lock.unlock()

        // The PNGs live in Resources/Filters, which is inside a synchronized folder, so
        // they land at the bundle root.
        guard let url = Bundle.main.url(forResource: name, withExtension: "png",
                                        subdirectory: "Filters")
                ?? Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let ui = UIImage(data: data),
              let cg = ui.cgImage
        else { return nil }

        let ci = CIImage(cgImage: cg)
        lock.lock(); cache[name] = ci; lock.unlock()
        return ci
    }

    /// Warms the cache off the render path.
    static func preload() {
        let names = Set(ClipFaceArt.layers.values.flatMap { $0 }.map { $0.asset })
        for n in names { _ = image(named: n) }
    }
}
