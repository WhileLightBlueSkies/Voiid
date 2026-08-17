//
//  CricketFigures.swift
//  Voiid
//
//  A rigged batter and bowler for the pitch
//  (docs/games/VISUALS_AUDIO_AND_PARITY.md §4).
//
//  WHAT THIS REPLACES: the batter was ONE rounded rectangle and the bat was another, and there
//  was no bowler at all — on a bowled the ball simply appeared at x = 0.86 and travelled left.
//
//  SAME TECHNIQUE AS THE HAND (§3): a skeleton of bones, a pose is one angle per bone, and a
//  shot is four keyframes interpolated across the ball's own flight. Tapered capsules, one dark
//  outline over the silhouette, two-colour fill. At the 210 pt pitch height these run at, the
//  SILHOUETTE is everything and internal detail is wasted.
//
//  WHAT DRIVES IT IS THE EXISTING TABLE, NOT A NEW ONE. `BallEvent.reach`, `.arc` and
//  `.flightDuration` already encode that a six travels 0.88 of the frame with 0.66 arc over
//  0.90 s while a four stays deliberately flat — that is real design, it is shared by the bot and
//  online screens through one mapping, and these figures are driven BY it. If a port ever needs
//  those tables changed, the port is wrong.
//
//  DELIBERATELY NOT 3D (§4.5). WCC-style 3D means a model pipeline, a rig, an animation set and a
//  renderer on both platforms — and the repo already made this call correctly for the coin. A
//  well-drawn 2D side-on figure with real weight transfer reads better at 210 pt than a low-poly
//  3D one, and it ships on both platforms from one spec.
//
//  Mirrors Android `CricketFigures.kt`. Port every angle literally.
//

import SwiftUI

enum CricketFigures {

    // MARK: - The pose

    /// Seven bones, in degrees. 0 is the rest stance; positive rotates toward the bowler.
    struct BatterPose {
        var torso: Double = 0
        var head: Double = 0
        var frontArm: Double = 0
        var backArm: Double = 0
        /// The bat's own angle, which is what the eye actually tracks.
        var bat: Double = 24
        var frontLeg: Double = 0
        var backLeg: Double = 0
        /// How far the front foot strides down the pitch, in figure heights.
        var stride: Double = 0

        static func lerp(_ a: BatterPose, _ b: BatterPose, _ t: Double) -> BatterPose {
            let k = max(0, min(1, t))
            func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
            return BatterPose(
                torso: m(a.torso, b.torso), head: m(a.head, b.head),
                frontArm: m(a.frontArm, b.frontArm), backArm: m(a.backArm, b.backArm),
                bat: m(a.bat, b.bat),
                frontLeg: m(a.frontLeg, b.frontLeg), backLeg: m(a.backLeg, b.backLeg),
                stride: m(a.stride, b.stride))
        }
    }

    static let stance = BatterPose()

    // MARK: - The shot table (§4.3)
    //
    // Backlift -> contact -> follow-through, per event. Contact stays pinned at the existing
    // `strike` timing (170 ms ease-out), so the bat still meets the ball on the frame it does
    // now and none of the ball maths moves.

    /// The three keyframes for an event: (backlift, contact, followThrough).
    static func keyframes(for event: BallEvent) -> (BatterPose, BatterPose, BatterPose) {
        switch event {
        case .runs(let r) where r >= 5:
            // LOFTED. The front leg plants, the torso rotates, the head tilts up and the bat
            // sweeps over the shoulder — the whole body goes.
            return (
                BatterPose(torso: -14, head: -6, frontArm: -40, backArm: -30, bat: 72,
                           frontLeg: -6, backLeg: 4, stride: 0.02),
                BatterPose(torso: 18, head: -12, frontArm: 30, backArm: 22, bat: -30,
                           frontLeg: 16, backLeg: -8, stride: 0.16),
                BatterPose(torso: 30, head: -16, frontArm: 66, backArm: 54, bat: -156,
                           frontLeg: 18, backLeg: -12, stride: 0.18)
            )
        case .runs(let r) where r == 4:
            // ALONG THE GROUND. A FLAT bat and high bat speed, head still — this is the one
            // shot whose arc table says 0.10, and the pose has to agree with that.
            return (
                BatterPose(torso: -10, head: -2, frontArm: -34, backArm: -26, bat: 58,
                           frontLeg: -4, backLeg: 2, stride: 0.02),
                BatterPose(torso: 12, head: -2, frontArm: 26, backArm: 18, bat: -8,
                           frontLeg: 12, backLeg: -6, stride: 0.14),
                BatterPose(torso: 20, head: -4, frontArm: 52, backArm: 40, bat: -124,
                           frontLeg: 14, backLeg: -8, stride: 0.16)
            )
        case .runs(let r) where r == 3:
            // A DRIVE. Full extension, front leg strides.
            return (
                BatterPose(torso: -9, head: -2, frontArm: -30, backArm: -22, bat: 52,
                           frontLeg: -3, backLeg: 2, stride: 0.02),
                BatterPose(torso: 10, head: -3, frontArm: 22, backArm: 16, bat: -14,
                           frontLeg: 11, backLeg: -5, stride: 0.13),
                BatterPose(torso: 16, head: -5, frontArm: 40, backArm: 30, bat: -100,
                           frontLeg: 12, backLeg: -6, stride: 0.14)
            )
        case .runs:
            // A PUSH. Short backlift, weight stays back, nothing past vertical.
            return (
                BatterPose(torso: -5, head: 0, frontArm: -18, backArm: -12, bat: 28,
                           frontLeg: -1, backLeg: 1, stride: 0.01),
                BatterPose(torso: 5, head: -1, frontArm: 12, backArm: 8, bat: -16,
                           frontLeg: 6, backLeg: -2, stride: 0.07),
                BatterPose(torso: 6, head: -1, frontArm: 16, backArm: 10, bat: -2,
                           frontLeg: 6, backLeg: -2, stride: 0.07)
            )
        case .dot:
            // A DEFENSIVE BLOCK. Bat straight down, soft hands, no follow-through at all.
            return (
                BatterPose(torso: -3, head: 0, frontArm: -10, backArm: -8, bat: 20,
                           frontLeg: 0, backLeg: 0, stride: 0.01),
                BatterPose(torso: 2, head: 0, frontArm: 4, backArm: 2, bat: 2,
                           frontLeg: 4, backLeg: -1, stride: 0.05),
                BatterPose(torso: 2, head: 0, frontArm: 4, backArm: 2, bat: 4,
                           frontLeg: 4, backLeg: -1, stride: 0.05)
            )
        case .caught:
            // A LEADING EDGE. Bat face open, the shot truncated.
            return (
                BatterPose(torso: -8, head: -2, frontArm: -26, backArm: -20, bat: 44,
                           frontLeg: -2, backLeg: 1, stride: 0.02),
                BatterPose(torso: 8, head: -4, frontArm: 18, backArm: 12, bat: 20,
                           frontLeg: 9, backLeg: -4, stride: 0.11),
                BatterPose(torso: 10, head: -6, frontArm: 24, backArm: 16, bat: -60,
                           frontLeg: 9, backLeg: -4, stride: 0.11)
            )
        case .bowled:
            // A SWING AND A MISS — and the miss is the drama.
            //
            // The old pitch skipped the swing entirely on a bowled (`if e != .bowled`), which
            // meant a player who was bowled watched their batter stand perfectly still while the
            // stumps fell over. A batter who is bowled DID play a shot; they missed it.
            return (
                BatterPose(torso: -12, head: -4, frontArm: -36, backArm: -28, bat: 62,
                           frontLeg: -5, backLeg: 3, stride: 0.02),
                BatterPose(torso: 14, head: -6, frontArm: 28, backArm: 20, bat: -20,
                           frontLeg: 13, backLeg: -7, stride: 0.15),
                BatterPose(torso: 24, head: -10, frontArm: 58, backArm: 46, bat: -140,
                           frontLeg: 15, backLeg: -9, stride: 0.16)
            )
        }
    }

    /// The pose at progress `t` through a ball, blending backlift -> contact -> follow-through.
    ///
    /// Contact lands at `contactAt`, matching the pitch's existing 170 ms bat strike against the
    /// event's own flight duration — so the bat meets the ball, not a moment either side.
    static func pose(for event: BallEvent, t: Double) -> BatterPose {
        let (backlift, contact, follow) = keyframes(for: event)
        let contactAt = min(0.55, 0.17 / max(event.flightDuration, 0.2))
        if t <= 0 { return BatterPose.lerp(stance, backlift, 0) }
        if t < contactAt {
            // Into the backlift, then down into contact. Two halves, so the bat visibly goes UP
            // before it comes down — a single blend would slide it sideways.
            let local = t / contactAt
            return local < 0.5
                ? BatterPose.lerp(stance, backlift, local * 2)
                : BatterPose.lerp(backlift, contact, (local - 0.5) * 2)
        }
        let local = min(1, (t - contactAt) / max(1 - contactAt, 0.01))
        return BatterPose.lerp(contact, follow, local)
    }

    // MARK: - The bowler (§4.4)

    /// Bowler arm rotation in degrees at progress `t` through the delivery, plus how far down
    /// the pitch they have run, in fractions of the frame width.
    ///
    /// RELEASE IS AT THE TOP OF THE ARM'S ARC, which is what makes the ball look bowled rather
    /// than spawned. `CricketPitch` starts the ball at the release frame.
    static let releaseAt: Double = 0.72

    static func bowlerArm(_ t: Double) -> Double {
        // One full rotation, accelerating into release.
        let eased = t * t * (3 - 2 * t)
        return -90 + eased * 360
    }

    static func bowlerRun(_ t: Double, full: Bool) -> Double {
        // A full run-up crosses from off-frame; a shortened one starts at the crease.
        let from = full ? 1.25 : 0.94
        return from + (0.86 - from) * min(1, t / releaseAt)
    }

    // MARK: - Palette

    static let kit = Color(red: 0.94, green: 0.94, blue: 0.96)
    static let kitShade = Color(red: 0.78, green: 0.79, blue: 0.84)
    static let skin = Color(red: 0.80, green: 0.60, blue: 0.46)
    static let ink = Color(red: 0.10, green: 0.12, blue: 0.14)
    static let batFace = Color(red: 0.91, green: 0.75, blue: 0.46)
    static let batEdge = Color(red: 0.73, green: 0.51, blue: 0.18)
    static let bowlerKit = Color(red: 0.90, green: 0.91, blue: 0.94)
}
