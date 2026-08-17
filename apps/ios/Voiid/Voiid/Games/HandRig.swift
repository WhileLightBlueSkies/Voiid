//
//  HandRig.swift
//  Voiid
//
//  A 2D skeletal hand for Rock Paper Scissors
//  (docs/games/VISUALS_AUDIO_AND_PARITY.md §3).
//
//  WHAT THIS REPLACES: two emoji in a spotlit panel, rotated ±18° to fake a shake. The
//  CHOREOGRAPHY was already right — three beats at 110 ms with a rising fist-pump pitch — and it
//  survives untouched. The thing being choreographed was a glyph.
//
//  A HAND IS A PALM PLUS FIVE FINGER CHAINS, and a pose is ONE CURL SCALAR PER FINGER. Every RPS
//  shape is a different vector of five numbers, so morphing between shapes is interpolating five
//  floats — which is what makes the transition read as fingers moving rather than as one picture
//  cross-fading into another. Four static hand images could not do that at any price.
//
//  THIS FILE IS A LOOKUP TABLE, NOT DRAWING CODE, for the same reason `LudoBoard.swift` is: two
//  rigs that disagree by a few degrees is exactly the parity drift ANDROID_IOS_PARITY.md exists
//  to prevent, and a table is checkable where drawing code is not.
//
//  Mirrors Android `HandRig.kt`. Port every number literally.
//

import CoreGraphics
import Foundation

enum HandRig {

    // MARK: - Skeleton

    /// Bone lengths as fractions of total finger length. Anatomically real ratios — they matter
    /// more than they sound, because a hand with even segments reads as a cartoon claw.
    static let proximal: CGFloat = 0.42
    static let middle: CGFloat = 0.32
    static let distal: CGFloat = 0.26

    /// Maximum flexion per joint, in degrees, at `curl = 1`. The actual angle is
    /// `curl * maxFlexion`, so ONE scalar drives a whole finger and a half-curl looks like a
    /// half-curl rather than a straight finger at an angle.
    static let mcpMax: Double = 88     // knuckle
    static let pipMax: Double = 100
    static let dipMax: Double = 70

    /// Finger lengths relative to palm width (1.0), and the rest angles they fan out at from the
    /// knuckle line. Index 0 = index finger … 3 = pinky.
    static let fingerLength: [CGFloat] = [1.00, 1.08, 0.98, 0.80]
    static let restSplay: [Double] = [-13, -2, 9, 21]

    /// Where each knuckle sits along the top of the palm, in palm-width units from its centre.
    static let knuckleX: [CGFloat] = [-0.30, -0.06, 0.17, 0.38]

    // MARK: - Poses

    /// A hand pose: four finger curls plus the thumb's own two degrees of freedom.
    ///
    /// THE THUMB IS NOT A FIFTH FINGER and must not be treated as one. It rotates ACROSS the palm
    /// rather than curling in plane, which is why it gets `adduction` — the swing from out
    /// (paper) to folded over the fingers (rock) — on top of its own curl.
    struct Pose: Equatable {
        /// index, middle, ring, pinky. 0 = straight, 1 = fully curled.
        var curls: [Double]
        var thumbCurl: Double
        /// Degrees. Negative swings the thumb away from the palm, positive across it.
        var thumbAdduction: Double
        /// Scales `restSplay`. 1 fans paper's fingers wide, 0 packs rock's together.
        var splay: Double

        static func lerp(_ a: Pose, _ b: Pose, _ t: Double) -> Pose {
            let k = max(0, min(1, t))
            return Pose(
                curls: zip(a.curls, b.curls).map { $0 + ($1 - $0) * k },
                thumbCurl: a.thumbCurl + (b.thumbCurl - a.thumbCurl) * k,
                thumbAdduction: a.thumbAdduction + (b.thumbAdduction - a.thumbAdduction) * k,
                splay: a.splay + (b.splay - a.splay) * k)
        }
    }

    /// Between rounds, and throughout the three pumps. A relaxed hand, not a fist — the fist
    /// forms on the way down into the reveal, which is what makes the reveal an event.
    static let neutral = Pose(
        curls: [0.34, 0.30, 0.32, 0.38],
        thumbCurl: 0.28, thumbAdduction: -6, splay: 0.30)

    static let rock = Pose(
        curls: [1.00, 1.00, 1.00, 1.00],
        thumbCurl: 0.55, thumbAdduction: 34, splay: 0.00)

    static let paper = Pose(
        curls: [0.00, 0.00, 0.00, 0.00],
        thumbCurl: 0.05, thumbAdduction: -38, splay: 1.00)

    /// Index and middle out, ring and pinky curled, thumb folded across them. The 0.55 splay is
    /// what gives the V its opening — at 0 the two extended fingers touch and it reads as a
    /// two-finger point rather than as scissors.
    static let scissors = Pose(
        curls: [0.00, 0.00, 1.00, 1.00],
        thumbCurl: 0.70, thumbAdduction: 22, splay: 0.55)

    /// Wire index -> pose. 0 rock, 1 paper, 2 scissors, matching `RpsBot`'s ordering.
    static func pose(for index: Int?) -> Pose {
        switch index {
        case 0: return rock
        case 1: return paper
        case 2: return scissors
        default: return neutral
        }
    }

    // MARK: - Choreography (§3.5)

    /// The three fist-pump beats. Unchanged from the emoji version — already tuned, and the
    /// sound files are already generated against this cadence.
    static let pumpBeat: Double = 0.110
    static let pumpCount = 3

    /// Forearm rotation at the top and bottom of a pump, in degrees.
    static let pumpUp: Double = -24
    static let pumpDown: Double = 9

    /// THE HAND LAGS THE FOREARM. One extra interpolation with a delayed target, and it is the
    /// single detail that makes this look human rather than mechanical: a real hand is dragged
    /// by the wrist, it does not rotate in lockstep with it.
    static let handLag: Double = 0.040

    /// Neutral -> thrown, on the third downstroke.
    static let revealDuration: Double = 0.130

    /// Paper hyperextends slightly past straight before settling; rock's knuckles pop. Overshoot
    /// is what stops the reveal reading as a cut.
    static let paperOvershoot: Double = -0.10
    static let rockKnucklePop: CGFloat = 1.04

    // MARK: - Joint solve

    /// The three joint positions of one finger, in palm-width units from its knuckle.
    ///
    /// Walks the chain accumulating rotation, which is what makes a curl bend rather than shrink.
    /// `direction` is -1 for a mirrored (right-hand) draw.
    static func fingerJoints(
        _ finger: Int, curl: Double, splay: Double, direction: CGFloat = 1
    ) -> [CGPoint] {
        let length = fingerLength[min(finger, fingerLength.count - 1)]
        let splayAngle = restSplay[min(finger, restSplay.count - 1)] * splay

        // Fingers point UP the screen at rest, so the base angle is -90°.
        var angle = (-90 + splayAngle) * .pi / 180
        var point = CGPoint(x: knuckleX[min(finger, knuckleX.count - 1)] * direction, y: 0)
        var joints = [point]

        for (index, fraction) in [proximal, middle, distal].enumerated() {
            let flex = [mcpMax, pipMax, dipMax][index] * curl
            angle += flex * .pi / 180 * Double(direction)
            let segment = length * fraction
            point = CGPoint(
                x: point.x + cos(angle) * segment * direction,
                y: point.y + sin(angle) * segment)
            joints.append(point)
        }
        return joints
    }

    /// The thumb: two bones, swinging across the palm rather than curling in plane.
    static func thumbJoints(
        curl: Double, adduction: Double, direction: CGFloat = 1
    ) -> [CGPoint] {
        var angle = (-152 + adduction) * .pi / 180
        var point = CGPoint(x: -0.46 * direction, y: 0.30)
        var joints = [point]
        for (index, segment) in [CGFloat(0.40), 0.30].enumerated() {
            angle += (index == 0 ? 52.0 : 44.0) * curl * .pi / 180 * Double(direction)
            point = CGPoint(
                x: point.x + cos(angle) * segment * direction,
                y: point.y + sin(angle) * segment)
            joints.append(point)
        }
        return joints
    }

    /// Stroke width along a finger: thicker at the knuckle, tapering to the tip. Three widths
    /// beat one, because the taper is most of what makes it read as a finger.
    static func segmentWidth(_ index: Int) -> CGFloat {
        [0.30, 0.26, 0.21][min(index, 2)]
    }
}
