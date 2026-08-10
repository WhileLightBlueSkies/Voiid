//
//  SnakeSkins.swift
//  Voiid
//
//  Snake skin catalogue (docs/GAMES_SNAKE_VISUALS.md §2).
//
//  THE SERVER SENDS AN ID, NOTHING ELSE. What a skin looks like lives here, so adding a
//  colourway is a client release and never a server one — and a client meeting an id it has
//  never heard of falls back to the plain palette colour rather than to nothing.
//
//  MUST STAY IN SYNC WITH Android `SnakeSkins.kt`. Band colours and band lengths are the
//  values that decide whether two players see the same arena, so they are duplicated
//  deliberately and identically rather than derived.
//

import simd

/// One skin: how a body is banded, and what sits on the head.
struct SnakeSkin {
    /// Colours repeated along the body, head-first.
    let bands: [SIMD4<Float>]
    /// World units per band. Roughly one segment (14) unless a pattern wants finer stripes.
    let bandLength: Float
    /// Additive halo tint, or nil for the body colour's own glow.
    let glow: SIMD4<Float>?
    /// Face glyph drawn on the head, or nil to keep the default eyes.
    let face: String?

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> SIMD4<Float> {
        SIMD4(Float(r), Float(g), Float(b), 1)
    }
}

enum SnakeSkins {
    /// The launch set. Five are pure colour data; four carry a face.
    static let catalogue: [String: SnakeSkin] = [
        "rainbow": SnakeSkin(
            bands: [
                rgb(1.00, 0.23, 0.28), rgb(1.00, 0.54, 0.17), rgb(1.00, 0.85, 0.24),
                rgb(0.36, 0.90, 0.36), rgb(0.30, 0.66, 1.00), rgb(0.35, 0.35, 0.95),
                rgb(0.61, 0.36, 1.00),
            ],
            bandLength: 14, glow: nil, face: nil),

        "candy": SnakeSkin(
            bands: [rgb(1, 1, 1), rgb(1.00, 0.44, 0.72)],
            bandLength: 10, glow: nil, face: nil),

        "lava": SnakeSkin(
            bands: [rgb(1.00, 0.23, 0.00), rgb(1.00, 0.54, 0.17), rgb(1.00, 0.85, 0.24)],
            bandLength: 12, glow: rgb(1.00, 0.45, 0.10), face: nil),

        "frost": SnakeSkin(
            bands: [rgb(0.55, 0.97, 0.78), rgb(0.30, 0.66, 1.00), rgb(1, 1, 1)],
            bandLength: 16, glow: rgb(0.40, 0.85, 1.00), face: nil),

        "shadow": SnakeSkin(
            bands: [rgb(0.17, 0.17, 0.25), rgb(0.29, 0.29, 0.42)],
            bandLength: 18, glow: rgb(0.45, 0.35, 0.75), face: nil),

        "bunny": SnakeSkin(
            bands: [rgb(1, 1, 1), rgb(0.96, 0.96, 1.00)],
            bandLength: 13, glow: nil, face: "bunny"),

        "corgi": SnakeSkin(
            bands: [rgb(0.91, 0.63, 0.36), rgb(1.00, 0.95, 0.86)],
            bandLength: 13, glow: nil, face: "corgi"),

        "lion": SnakeSkin(
            bands: [rgb(0.85, 0.57, 0.25), rgb(0.71, 0.46, 0.18)],
            bandLength: 15, glow: nil, face: "lion"),

        "unicorn": SnakeSkin(
            bands: [
                rgb(1.00, 0.75, 0.85), rgb(0.85, 0.80, 1.00),
                rgb(0.75, 0.95, 1.00), rgb(1.00, 0.95, 0.75),
            ],
            bandLength: 12, glow: rgb(1.00, 0.45, 0.85), face: "unicorn"),
    ]

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> SIMD4<Float> {
        SnakeSkin.rgb(r, g, b)
    }

    /// Resolve a skin id, falling back to a CHECKERED skin in the snake's palette colour.
    ///
    /// The fallback is what lets an old client meet a new skin without breaking — and it is
    /// checkered rather than solid so an unknown skin still reads as a snake with segments
    /// rather than as a featureless tube.
    static func resolve(_ id: String?, fallback: SIMD4<Float>) -> SnakeSkin {
        if let id, let skin = catalogue[id] { return skin }
        // `custom:RRGGBB` from the colour picker. Rendered as a checkered two-band skin like
        // any other, which is why a custom colour needs no catalogue entry at all.
        if let id, id.hasPrefix("custom:"), let rgb = UInt32(id.dropFirst(7), radix: 16) {
            return checkered(SIMD4(
                Float((rgb >> 16) & 0xFF) / 255,
                Float((rgb >> 8) & 0xFF) / 255,
                Float(rgb & 0xFF) / 255,
                1))
        }
        return checkered(fallback)
    }

    /// A single colour turned into a box-box pattern.
    ///
    /// User testing asked for the checker "all ways through" even on a plain snake — a solid
    /// body reads as a featureless tube and gives the eye nothing to judge length or speed
    /// against. Alternating the colour with a darker shade of ITSELF keeps it recognisably
    /// one colour (which is the point of picking it) while still segmenting, and it is what
    /// lets a custom picked colour work without its own catalogue entry.
    static func checkered(_ base: SIMD4<Float>) -> SnakeSkin {
        SnakeSkin(
            bands: [base, SIMD4(base.x * 0.72, base.y * 0.72, base.z * 0.72, base.w)],
            bandLength: 13, glow: nil, face: nil)
    }
}
