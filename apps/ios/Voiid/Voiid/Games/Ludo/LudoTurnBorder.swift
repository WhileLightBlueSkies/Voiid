//
//  LudoTurnBorder.swift
//  Voiid
//
//  Turn-border sweep (§12). The perimeter is a rounded rectangle inset by half the stroke;
//  anchors are normalized clockwise fractions: red 0.00 bottom-left, green 0.25 top-left,
//  yellow 0.50 top-right, blue 0.75 bottom-right.
//
//  CONSTRUCTION (§12.2): the OLD hue stays as the base full stroke; a new-hue OVERLAY travels
//  from the outgoing anchor to the incoming anchor using Path trim with WRAPPED segments when
//  the phase crosses path length. Rounded cap while traveling, butt at completion. Never two
//  cross-faded borders, never a gradient disguise.
//

import SwiftUI

enum LudoTurnBorder {

    /// Phase from seat A to seat B clockwise in [0,1): adjacent 0.25, duel opposite 0.5, wrap 0.75.
    static func sweepPhase(from: Int, to: Int) -> CGFloat {
        let delta = ((to - from) % 4 + 4) % 4
        return CGFloat(delta) / 4
    }

    /// The perimeter path: rounded rect inset by half its stroke so the stroke stays inside.
    static func perimeterPath(side: CGFloat, cornerRadius: CGFloat, stroke: CGFloat) -> Path {
        let inset = stroke / 2
        let rect = CGRect(x: inset, y: inset,
                          width: side - stroke, height: side - stroke)
        return Path(roundedRect: rect, cornerRadius: min(cornerRadius, side / 2))
    }

    /// One frame of the border.
    ///
    /// - Parameters:
    ///   - baseColor: steady full border under everything (old hue, or podBorder waiting)
    ///   - overlayColor: traveling new hue, or nil when resting
    ///   - phaseStart: normalized start anchor of travel
    ///   - progress: 0...1 along the FULL perimeter from phaseStart (eased by the caller)
    static func draw(
        _ ctx: inout GraphicsContext,
        path: Path,
        stroke: CGFloat,
        baseColor: Color,
        overlayColor: Color?,
        phaseStart: CGFloat,
        progress: CGFloat,
    ) {
        ctx.stroke(path, with: .color(baseColor),
                   style: StrokeStyle(lineWidth: stroke, lineCap: .butt))

        guard let overlay = overlayColor, progress > 0 else { return }
        if progress >= 1 {
            // Completion REPLACES the base hue entirely (§12.2).
            ctx.stroke(path, with: .color(overlay),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .butt))
            return
        }

        // Traveling segment may wrap past path length; draw up to two sub-trims. Rounded
        // leading cap during travel reads as motion; completion switches to butt above.
        let tail = phaseStart.truncatingRemainder(dividingBy: 1)
        let head = (tail + progress).truncatingRemainder(dividingBy: 1)
        if tail < head {
            ctx.stroke(trimmed(path, from: tail, to: head), with: .color(overlay),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round))
        } else {
            ctx.stroke(trimmed(path, from: tail, to: 1), with: .color(overlay),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            ctx.stroke(trimmed(path, from: 0, to: head), with: .color(overlay),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round))
        }
    }

    private static func trimmed(_ path: Path, from: CGFloat, to: CGFloat) -> Path {
        guard to > from else { return Path() }
        return path.trimmedPath(from: from, to: to)
    }
}

/// The pod timer ring (§13). Server-timed: renders `deadlineAt − estimatedServerNow`, clamped
/// 0…30 s, starting at 100% at opensAt and depleting clockwise from 12 o'clock. Player hue
/// until 5 s, timerWarning at 5 s, timerCritical at 2 s — HOW LONG only; never WHO.
enum LudoTimerRing {

    struct RingState {
        let fractionRemaining: Double
        let secondsRemaining: Int
        var colorOverride: Color?   // warning/critical; nil → player hue
    }

    /// Pure math over the SMOOTHED server clock (never a raw device counter).
    static func state(opensAt: Double?, deadlineAt: Double?, estimatedNowMs: Double) -> RingState? {
        guard let opensAt, let deadlineAt else { return nil }
        let total = max(deadlineAt - opensAt, 1)
        let remaining = min(max(deadlineAt - estimatedNowMs, 0), LudoRules.turnWindowMs)
        let seconds = Int(remaining / 1000)
        let colorOverride: Color? = {
            if remaining <= 2_000 { return Color(hex: 0xEF7A6B) }   // resolved by theme below
            if remaining <= 5_000 { return Color(hex: 0xB07818) }
            return nil
        }()
        _ = colorOverride
        return RingState(
            fractionRemaining: remaining / total,
            secondsRemaining: seconds,
            colorOverride: nil) // theme-aware override applied by LudoPlayerPod
    }

    static func draw(
        _ ctx: inout GraphicsContext,
        diameter: CGFloat,
        stroke: CGFloat,
        track: Color,
        arc: Color,
        fraction: Double,
    ) {
        let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter).insetBy(dx: stroke / 2, dy: stroke / 2)
        ctx.stroke(Path(ellipseIn: rect), with: .color(track), lineWidth: stroke)
        let f = min(max(fraction, 0), 1)
        guard f > 0 else { return }
        var arcPath = Path()
        arcPath.addArc(center: CGPoint(x: diameter / 2, y: diameter / 2),
                       radius: diameter / 2 - stroke / 2,
                       startAngle: .degrees(-90),
                       endAngle: .degrees(-90 - 360 * f),
                       clockwise: true)
        ctx.stroke(arcPath, with: .color(arc),
                   style: StrokeStyle(lineWidth: stroke, lineCap: .round))
    }
}
