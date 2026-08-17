//
//  HandView.swift
//  Voiid
//
//  Draws a `HandRig.Pose` (docs/games/VISUALS_AUDIO_AND_PARITY.md §3.4).
//
//  TWO COLOURS AND ONE OUTLINE. Skin fill, dark ink outline, one soft highlight on the palm —
//  the flat pop-art look of the reference, not a rendered hand. Shading the fingers individually
//  was tried and muddies at the ~56 pt these run at; the silhouette is what carries the read.
//
//  LAYER ORDER IS LOAD-BEARING (§3.4): shadow, forearm, back fingers, palm, front fingers, thumb.
//  Ring and pinky pass BEHIND the palm in a fist, and drawing them in front is the single thing
//  that makes a closed hand look like a mitten.
//
//  Mirrors Android `HandView.kt`.
//

import SwiftUI

struct HandView: View {
    let pose: HandRig.Pose
    /// Forearm rotation in degrees, from the pump choreography.
    var forearm: Double = 0
    /// The hand's own rotation, which LAGS the forearm — see HandRig.handLag.
    var wrist: Double = 0
    /// Mirrored for the opponent, so the two hands face each other.
    var mirrored: Bool = false
    /// Rock's knuckles pop on reveal.
    var knucklePop: CGFloat = 1
    /// Drains colour on a lost round.
    var dimmed: Bool = false

    private let skin = Color(red: 0.98, green: 0.82, blue: 0.69)
    private let skinShade = Color(red: 0.93, green: 0.72, blue: 0.58)
    private let ink = Color(red: 0.16, green: 0.12, blue: 0.14)

    var body: some View {
        GeometryReader { geo in
            // Palm width is the unit everything in HandRig is expressed in.
            let unit = min(geo.size.width, geo.size.height) * 0.42
            let origin = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.60)
            let direction: CGFloat = mirrored ? -1 : 1

            Canvas { ctx, _ in
                draw(ctx: ctx, unit: unit, origin: origin, direction: direction)
            }
            .rotationEffect(.degrees(mirrored ? -wrist : wrist), anchor: .bottom)
        }
        .saturation(dimmed ? 0.85 : 1)
        .opacity(dimmed ? 0.88 : 1)
    }

    private func draw(ctx: GraphicsContext, unit: CGFloat, origin: CGPoint, direction: CGFloat) {
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + p.x * unit, y: origin.y + p.y * unit)
        }

        // Contact shadow on the panel. Shrinks and softens as the hand lifts, which is most of
        // what sells the pump as the hand actually moving rather than the image rotating.
        let lift = max(0, -forearm) / 24
        let shadowW = unit * (1.5 - lift * 0.35)
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: origin.x - shadowW / 2,
                y: origin.y + unit * 0.92,
                width: shadowW, height: unit * 0.22)),
            with: .color(.black.opacity(0.22 - lift * 0.07)))

        // Forearm: a tapered capsule entering from the panel edge.
        var arm = Path()
        arm.move(to: place(CGPoint(x: -0.32 * direction, y: 0.55)))
        arm.addLine(to: place(CGPoint(x: 0.32 * direction, y: 0.55)))
        arm.addLine(to: place(CGPoint(x: 0.40 * direction, y: 1.85)))
        arm.addLine(to: place(CGPoint(x: -0.40 * direction, y: 1.85)))
        arm.closeSubpath()
        ctx.fill(arm, with: .color(skin))
        ctx.stroke(arm, with: .color(ink), lineWidth: unit * 0.055)

        // BACK FINGERS FIRST — ring and pinky pass behind the palm in a fist.
        for finger in [2, 3] {
            strokeFinger(ctx: ctx, finger: finger, unit: unit, place: place, direction: direction)
        }

        // The palm: a rounded quad with a slight barrel on the outer edge.
        let palm = Path(roundedRect: CGRect(
            x: origin.x - unit * 0.52,
            y: origin.y - unit * 0.10,
            width: unit * 1.04, height: unit * 0.78),
            cornerRadius: unit * 0.26)
        ctx.fill(palm, with: .color(skin))
        ctx.stroke(palm, with: .color(ink), lineWidth: unit * 0.055)

        // One soft top-left highlight, matching the app-wide light direction.
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: origin.x - unit * 0.34,
                y: origin.y + unit * 0.02,
                width: unit * 0.42, height: unit * 0.30)),
            with: .color(.white.opacity(0.22)))

        // FRONT FINGERS AND THUMB.
        for finger in [0, 1] {
            strokeFinger(ctx: ctx, finger: finger, unit: unit, place: place,
                         direction: direction, scale: knucklePop)
        }
        strokeThumb(ctx: ctx, unit: unit, place: place, direction: direction)
    }

    private func strokeFinger(
        ctx: GraphicsContext, finger: Int, unit: CGFloat,
        place: (CGPoint) -> CGPoint, direction: CGFloat, scale: CGFloat = 1
    ) {
        let joints = HandRig.fingerJoints(
            finger,
            curl: pose.curls[min(finger, pose.curls.count - 1)],
            splay: pose.splay,
            direction: direction)

        // Three strokes at three widths rather than one — the taper is what reads as a finger.
        for i in 0..<(joints.count - 1) {
            var seg = Path()
            seg.move(to: place(CGPoint(x: joints[i].x * scale, y: joints[i].y * scale)))
            seg.addLine(to: place(CGPoint(x: joints[i + 1].x * scale, y: joints[i + 1].y * scale)))
            // Outline first, fill over it — one pass, and the stroke's round cap gives the
            // knuckle its curve for free.
            ctx.stroke(seg, with: .color(ink),
                       style: StrokeStyle(lineWidth: unit * (HandRig.segmentWidth(i) + 0.055),
                                          lineCap: .round))
            ctx.stroke(seg, with: .color(i == 2 ? skinShade : skin),
                       style: StrokeStyle(lineWidth: unit * HandRig.segmentWidth(i),
                                          lineCap: .round))
        }
    }

    private func strokeThumb(
        ctx: GraphicsContext, unit: CGFloat,
        place: (CGPoint) -> CGPoint, direction: CGFloat
    ) {
        let joints = HandRig.thumbJoints(
            curl: pose.thumbCurl, adduction: pose.thumbAdduction, direction: direction)
        for i in 0..<(joints.count - 1) {
            var seg = Path()
            seg.move(to: place(joints[i]))
            seg.addLine(to: place(joints[i + 1]))
            ctx.stroke(seg, with: .color(ink),
                       style: StrokeStyle(lineWidth: unit * 0.38, lineCap: .round))
            ctx.stroke(seg, with: .color(skin),
                       style: StrokeStyle(lineWidth: unit * 0.32, lineCap: .round))
        }
    }
}
