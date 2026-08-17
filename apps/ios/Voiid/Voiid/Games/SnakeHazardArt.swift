//
//  SnakeHazardArt.swift
//  Voiid
//
//  Shapes for the arena's rocks, spikes and slicks
//  (docs/games/VISUALS_AUDIO_AND_PARITY.md §7).
//
//  WHAT WAS WRONG. Every hazard was three stacked flat circles — a rock, a retracted spike and a
//  slick were the same shape in three colours, so "I don't know what those obstacles are" was the
//  expected outcome. The INTENT was already right and is preserved here: a rock is opaque because
//  it kills like the wall, a spike's state is the whole point, and a slick must never read as a
//  wall because a player who steers around one has paid for nothing.
//
//  DETERMINISM IS A HARD REQUIREMENT, NOT A NICETY (§7.6). Every shape below is a pure function
//  of data both clients already have — the hazard's index and its (x, y) — computed through
//  `GameSurface.noise`, which Android implements identically. If a rock were a different shape on
//  two devices, two players in the same match would see different cover and different escape
//  routes, and Snake's entire netcode design rests on both clients agreeing about the world
//  (SNAKE.md §2). NEVER use `Double.random` in this file.
//
//  WHY POLYGONS AND NOT SPRITES. The Metal renderer already has a triangle pipeline — the one
//  that draws snake bodies from CPU-triangulated polylines — so a faceted boulder is a vertex
//  buffer, not a new texture, a new atlas or a new fragment shader. It also stays crisp at every
//  zoom, and this camera zooms constantly as the snake grows.
//
//  Mirrors Android `SnakeHazardArt.kt`. Port every constant literally.
//

import CoreGraphics
import Foundation

enum SnakeHazardArt {

    // MARK: - Shared constants (the parity surface)

    /// One light direction for the whole app, top-left, shared with `GameSurface.inset`.
    static let lightX = -0.6
    static let lightY = -0.8

    /// FOUR ROCK SILHOUETTES, chosen by `index % 4`. A field of eight identical boulders reads as
    /// UI; four shapes is enough that it reads as terrain, and four is cheap.
    static let rockVariants = 4
    /// A rock's outline has CORNERS. Nine of them — smooth enough to be a boulder, angular enough
    /// never to be mistaken for the circle it used to be.
    static let rockSides = 9
    /// Oil does not have a radius, so a slick's boundary wanders.
    static let slickSides = 12
    /// Six teeth around a socket.
    static let spikeTeeth = 6

    /// How long a spike takes to rise and to drop. The old renderer cut between the two states in
    /// a single frame, which is what made a spike death read as bad luck rather than a mistake.
    static let spikeRise: Double = 0.18
    static let spikeFall: Double = 0.14
    /// The socket brightens over the last quarter-second before the teeth come up. The phase is
    /// already known client-side (it is a pure function of simulation time), so this costs
    /// nothing and converts a surprise into a mistake the player can own.
    static let spikeTell: Double = 0.25

    // MARK: - Outlines

    /// A rock's outline in unit space (radius 1), as a closed loop of points.
    ///
    /// Radius jitter in 0.78...1.18 and angular jitter of ±0.12 rad. The two together are what
    /// stop it reading as a polygon-approximated circle.
    static func rockOutline(variant: Int) -> [CGPoint] {
        (0..<rockSides).map { i in
            let base = Double(i) / Double(rockSides) * 2 * .pi
            let angle = base + (GameSurface.noise(i, variant, seed: 41) - 0.5) * 0.24
            let radius = 0.78 + GameSurface.noise(i, variant, seed: 42) * 0.40
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
    }

    /// A slick's boundary in unit space. Softer jitter than a rock and no corners worth the name —
    /// it has to read as a puddle, never as an edge you could crash into.
    static func slickOutline(variant: Int) -> [CGPoint] {
        (0..<slickSides).map { i in
            let base = Double(i) / Double(slickSides) * 2 * .pi
            let radius = 0.85 + GameSurface.noise(i, variant, seed: 55) * 0.30
            return CGPoint(x: cos(base) * radius, y: sin(base) * radius)
        }
    }

    /// One tooth of a spike, in unit space, at `extended` 0...1.
    ///
    /// Returns the triangle's three points: two at the socket rim, one at the tip. At extension 0
    /// the tip sits flush with the rim, which is what makes a retracted spike show WHERE it is
    /// without pretending to be dangerous.
    static func spikeTooth(_ index: Int, extended: Double) -> (CGPoint, CGPoint, CGPoint) {
        let step = 2 * .pi / Double(spikeTeeth)
        let centre = Double(index) * step
        let halfBase = step * 0.34
        let rim = 0.45
        let tip = rim + (1.0 - rim) * max(0, min(1, extended))
        return (
            CGPoint(x: cos(centre - halfBase) * rim, y: sin(centre - halfBase) * rim),
            CGPoint(x: cos(centre + halfBase) * rim, y: sin(centre + halfBase) * rim),
            CGPoint(x: cos(centre) * tip, y: sin(centre) * tip)
        )
    }

    // MARK: - Facets

    /// Which of three facets a point belongs to, from the light direction.
    ///
    /// HARD EDGES BETWEEN THEM, no gradient. Faceting is what makes a shape read as stone rather
    /// than as a blob, and a smooth shade would put us back where we started.
    ///
    /// 0 = lit top face, 1 = side, 2 = shadow face.
    static func facet(_ p: CGPoint) -> Int {
        let d = p.x * lightX + p.y * lightY
        if d > 0.35 { return 0 }
        if d > -0.30 { return 1 }
        return 2
    }

    /// Lightness multiplier per facet: +22% on the lit face, base on the side, -30% in shadow.
    static func facetShade(_ facet: Int) -> Double {
        switch facet {
        case 0:  return 1.22
        case 1:  return 1.0
        default: return 0.70
        }
    }

    // MARK: - Spike phase

    /// How far a spike is extended right now, 0...1, with the rise and fall eased rather than cut.
    ///
    /// Derived from the SAME `period`/`offset` the server sent and the same simulation clock the
    /// engine uses, so it cannot desync — `spikeExtended` in hazards.ts remains the authority for
    /// whether the spike KILLS; this only decides how far out it is drawn.
    static func extended(period: Double, offset: Double, duty: Double, time: Double) -> Double {
        let p = max(period, 0.001)
        let phase = ((time + offset).truncatingRemainder(dividingBy: p) + p)
            .truncatingRemainder(dividingBy: p) / p
        if phase < duty {
            // Rising, then held out for the rest of the duty window.
            let elapsed = phase * p
            return min(1, elapsed / spikeRise)
        }
        // Retracting, then held down.
        let elapsed = (phase - duty) * p
        return max(0, 1 - elapsed / spikeFall)
    }

    /// 0...1 over the last `spikeTell` seconds before the teeth rise. Drives the socket's warning
    /// glow; 0 at every other moment.
    static func tell(period: Double, offset: Double, duty: Double, time: Double) -> Double {
        let p = max(period, 0.001)
        let phase = ((time + offset).truncatingRemainder(dividingBy: p) + p)
            .truncatingRemainder(dividingBy: p) / p
        guard phase >= duty else { return 0 }
        let untilNext = (1 - phase) * p
        guard untilNext < spikeTell else { return 0 }
        return 1 - untilNext / spikeTell
    }
}
