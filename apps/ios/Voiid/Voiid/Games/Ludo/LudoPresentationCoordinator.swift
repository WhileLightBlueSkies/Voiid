//
//  LudoPresentationCoordinator.swift
//  Voiid
//
//  Ordered animation timeline (§15, §18.1). Beats are queued NAMED SEQUENCE STEPS instead of
//  independent onChange animations, so the required §12.3 order never overlaps: the border
//  sweep finishes before die relocation; hops finish before capture return; the next border
//  sweep begins only after the last mandatory beat of the previous action.
//
//  GAME STATE NEVER WAITS FOR A CLIENT ANIMATION (§1): authoritative frames replace state
//  immediately; this coordinator schedules only what is SEEN. `cancelAll()` on reconnect means
//  no stale motion ever replays (§9). The ~60 fps loop runs ONLY while a beat is active (§19).
//

import Combine
import SwiftUI
import UIKit

@MainActor
final class LudoPresentationCoordinator: ObservableObject {

    /// One frame of die-roll visual state (§14.3 choreography).
    struct RollPose {
        var rotationXDeg: CGFloat
        var rotationYDeg: CGFloat
        var liftPx: CGFloat
        var scaleX: CGFloat
        var scaleY: CGFloat
        /// Shrinks the airborne cube so its corners stay inside the tray, and doubles as depth:
        /// small while thrown, full size once it lands.
        var depthScale: CGFloat = 1
    }

    // MARK: Published visual state

    @Published private(set) var sweep: LudoBoardSweep?
    @Published private(set) var rollPose: RollPose?
    @Published private(set) var hopOverride: (seat: Int, pawn: Int, center: CGPoint)?
    @Published private(set) var captureReturn: (seat: Int, pawn: Int, center: CGPoint)?
    @Published private(set) var isAnimating = false

    /// The value of the roll currently in the air. The die must render THIS, not whatever the
    /// live turn happens to hold: the turn advances the moment the move is committed, so a
    /// later action — a bot's roll lands within a couple of hundred milliseconds — would
    /// otherwise re-label the die while it is still tumbling.
    @Published private(set) var animatingRollValue: Int?

    /// The seat whose roll is in the air. The server advances `activeSeat` the moment a roll
    /// produces no legal move, so binding the die to the live turn made it vanish from the
    /// roller's side and reappear on the next player's — the number never got read.
    @Published private(set) var animatingRollSeat: Int?

    // MARK: State

    private var queue: [@MainActor () async -> Void] = []
    private var running = false
    private var reduceMotion = false

    func setReduceMotion(_ enabled: Bool) { reduceMotion = enabled }

    // MARK: Beat entry points

    /// §12.3 turn-change sequence: sweep 0–360 ms → die relocate 360–480 ms → pip cross-fade.
    /// A six that keeps the same seat performs NO sweep and NO relocation (§12.3).
    func enqueueTurnChange(fromSeat: Int, toSeat: Int) {
        guard fromSeat != toSeat else { return }
        enqueue { [weak self] in
            await self?.animateBorder(from: fromSeat, to: toSeat)
            try? await Task.sleep(nanoseconds: UInt64(LudoMotion.dieRelocateMs * 1_000_000))
            try? await Task.sleep(nanoseconds: UInt64(LudoMotion.pipCrossFadeMs * 1_000_000))
        }
    }

    /// §14.3 roll choreography. Whole turns derive from hash(matchId+rollId), never the value;
    /// every path lands on the already-known face.
    func enqueueRoll(rollId: String, value: Int, seat: Int, matchId: String?) {
        enqueue { [weak self] in
            await self?.animateRoll(rollId: rollId, value: value, seat: seat, matchId: matchId)
        }
    }

    /// §15 hop chain along the server's EXACT path; capture return follows when present.
    func enqueueMove(
        tokenId: Int,
        actorSeat: Int,
        centers: [CGPoint],
        captured: LudoActionMove.CapturedPawn?,
        /// The captured pawn's way home: its current cell, every track cell it came through in
        /// reverse, then its yard slot.
        captureRoute: [CGPoint],
    ) {
        // PIN BOTH PAWNS NOW, not when the beat reaches the front of the queue.
        //
        // Authoritative state already holds the finished positions: the mover is on its
        // destination and a captured pawn is back in its yard. If nothing holds them, they snap
        // there the moment the frame lands and only animate back once the queue drains — a
        // captured token appeared to teleport home, reappear out on the track, and walk back.
        // Holding them at their starting points keeps the board honest until the motion runs.
        if let first = centers.first {
            hopOverride = (actorSeat, tokenId, first)
        }
        if let cap = captured, let start = captureRoute.first {
            captureReturn = (cap.seat, cap.tokenId, start)
        }
        enqueue { [weak self] in
            await self?.runMoveBeat(tokenId: tokenId, actorSeat: actorSeat, centers: centers,
                                    captured: captured, captureRoute: captureRoute)
        }
    }

    func cancelAll() {
        beatTask?.cancel()
        beatTask = nil
        queue.removeAll()
        running = false
        sweep = nil
        rollPose = nil
        animatingRollValue = nil
        animatingRollSeat = nil
        hopOverride = nil
        captureReturn = nil
        isAnimating = false
    }

    // MARK: Beat bodies

    /// §15 hops (120 ms each, staggered every 92 ms so adjacent arcs overlap by 28 ms) then the
    /// capture return: 70 ms hold → 150 ms squash window → 260 ms quadratic arc home.
    private func runMoveBeat(
        tokenId: Int,
        actorSeat: Int,
        centers: [CGPoint],
        captured: LudoActionMove.CapturedPawn?,
        captureRoute: [CGPoint],
    ) async {
        // RELEASE THE PINS ON EVERY EXIT. enqueueMove holds both pawns at their pre-move
        // positions the instant the action lands, and the two guards below return early on
        // perfectly ordinary moves — a pawn leaving the yard has only one usable centre. Those
        // returns used to skip the cleanup, so the pin stayed forever: another player's pawn
        // sat frozen at a stale cell through later turns and then jumped when something finally
        // cleared it, which looked like a second token moving on its own.
        defer {
            hopOverride = nil
            captureReturn = nil
        }
        let hopEasing = CubicBezierEasing(x1: 0.22, y1: 0, x2: 0.20, y2: 1)
        guard centers.count >= 2 else { return }
        for i in 1..<centers.count {
            if i > 1 { try? await Task.sleep(nanoseconds: 92_000_000) }
            let from = centers[i - 1]
            let to = centers[i]
            let isLast = i == centers.count - 1

            // One cell, measured from the leg itself: adjacent centres are exactly a unit apart,
            // and the coordinator never sees the board's geometry. Legs that turn a corner or
            // enter a home lane are still ~1 unit, so this stays stable along a whole walk.
            let unit = max(hypot(to.x - from.x, to.y - from.y), 0.001)

            await tween(ms: LudoMotion.hopMs, easing: hopEasing) { t in
                let cx = from.x + (to.x - from.x) * t
                var cy = from.y + (to.y - from.y) * t

                // ARC. A half-sine peaks at the midpoint and returns to zero at both ends, so
                // the token leaves the board and comes back to exactly its mark — no drift to
                // correct at the end of the leg.
                cy -= sin(CGFloat(t) * .pi) * unit * LudoMotion.hopArcFactor

                // LANDING OVERSHOOT, final leg only: the token dips a little past its mark in
                // the second half of the hop and settles back, so it lands with weight instead
                // of stopping dead. Scaled by (1-t) so it is exactly zero on arrival.
                if isLast, t > 0.5 {
                    let settle = (CGFloat(t) - 0.5) * 2          // 0 -> 1 over the back half
                    cy += sin(settle * .pi) * unit * LudoMotion.hopLandOvershootFactor
                }

                self.hopOverride = (actorSeat, tokenId, CGPoint(x: cx, y: cy))
            }
        }
        hopOverride = nil

        guard let cap = captured, captureRoute.count >= 2 else { return }
        try? await Task.sleep(nanoseconds: 70_000_000)                       // hold after landing
        await tween(ms: LudoMotion.captureScaleMs,
                    easing: CubicBezierEasing(x1: 0, y1: 0, x2: 1, y2: 1)) { _ in }

        // Retrace the route at a FIXED total duration, so a pawn sent back from two cells out
        // and one sent back from forty both take about the same beat — long returns would
        // otherwise stall the game for seconds.
        let legs = captureRoute.count - 1
        let perLeg = max(LudoMotion.captureLegMinMs,
                         LudoMotion.captureReturnTotalMs / Double(legs))
        let linear = CubicBezierEasing(x1: 0, y1: 0, x2: 1, y2: 1)
        for i in 1..<captureRoute.count {
            let from = captureRoute[i - 1]
            let to = captureRoute[i]
            // The final leg leaves the track for the yard slot; ease it out so the pawn settles
            // rather than slamming into its circle.
            let isLast = i == captureRoute.count - 1
            await tween(ms: perLeg * (isLast ? 2.0 : 1.0),
                        easing: isLast ? CubicBezierEasing(x1: 0.30, y1: 0, x2: 0.10, y2: 1)
                                       : linear) { t in
                let cx = from.x + (to.x - from.x) * t
                let cy = from.y + (to.y - from.y) * t
                self.captureReturn = (cap.seat, cap.tokenId, CGPoint(x: cx, y: cy))
            }
        }
        captureReturn = nil
    }

    /// Border sweep: 360 ms clockwise trim, cubic-bezier(.22,0,0,1).
    private func animateBorder(from: Int, to: Int) async {
        await tween(ms: LudoMotion.borderSweepMs,
                    easing: CubicBezierEasing(x1: 0.22, y1: 0, x2: 0, y2: 1)) { t in
            self.sweep = LudoBoardSweep(fromSeat: from, toSeat: to, progress: CGFloat(t))
        }
        sweep = nil
    }

    /// §14.3 four-beat roll: anticipation → tumble → impact → rebound. ONE medium impact
    /// haptic at the 760 ms beat, once per rollId.
    private func animateRoll(rollId: String, value: Int, seat: Int, matchId: String?) async {
        animatingRollValue = value
        animatingRollSeat = seat
        defer {
            animatingRollValue = nil
            animatingRollSeat = nil
        }
        let hash = Self.stableHash("\(matchId ?? ""):\(rollId)")
        let xTurns: Double = 2.5 + Double((hash >> 8) % 1000) / 1000      // 2.5–3.5 turns
        let yTurns: Double = 2.0 + Double((hash >> 20) % 1000) / 1000     // 2–3 turns
        let zDir: Double = hash % 2 == 0 ? -1 : 1
        let rest = LudoDiePose.resting(value: value)

        func makePose(rx: Double, ry: Double, lift: Double, sx: Double, sy: Double,
                      depth: Double = 1) -> RollPose {
            RollPose(rotationXDeg: rx, rotationYDeg: ry, liftPx: lift,
                     scaleX: sx, scaleY: sy, depthScale: depth)
        }

        // A cube spans up to √3 of its own side once it is turning, so the airborne die is
        // drawn smaller and grows back as it lands. That keeps its corners off the tray edge
        // and reads as the throw having depth.
        let airborne = LudoMotion.dieAirborneScale

        // Anticipation 0–120 ms — cubic (.32,0,.67,0).
        await tween(ms: 120, easing: CubicBezierEasing(x1: 0.32, y1: 0, x2: 0.67, y2: 0)) { t in
            self.rollPose = makePose(rx: zDir * -8 * t, ry: 10 * t,
                                     lift: 3 * t, sx: 1 + 0.05 * t, sy: 1 - 0.09 * t,
                                     depth: 1 - (1 - airborne) * t)
        }
        // Tumble/release 120–760 ms — position (.12,.68,.22,1); angular deceleration (.20,0,.38,1).
        // Both axes wind down to the rest pose, which is square-on: the result is already on the
        // cube's front face, so it settles showing the committed number and never re-labels.
        let angular = CubicBezierEasing(x1: 0.20, y1: 0, x2: 0.38, y2: 1)
        await tween(ms: 640, easing: CubicBezierEasing(x1: 0.12, y1: 0.68, x2: 0.22, y2: 1)) { t in
            let remaining = 1 - angular.transform(t)
            self.rollPose = makePose(
                rx: rest.rotationXDeg + zDir * xTurns * 360 * remaining,
                ry: rest.rotationYDeg + yTurns * 360 * remaining,
                lift: (3 - 21 * sin(.pi * t)) * LudoMotion.dieLiftScale,
                sx: 1 + 0.05 * (1 - t), sy: 1 - 0.09 * (1 - t),
                // Grows back only over the last third, while the spin is nearly spent.
                depth: airborne + (1 - airborne) * max(0, (t - 0.66) / 0.34))
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Impact 760–820 ms — squash; shadow collapse reads through lift=0. Cubic (.33,1,.68,1).
        await tween(ms: 60, easing: CubicBezierEasing(x1: 0.33, y1: 1, x2: 0.68, y2: 1)) { t in
            self.rollPose = makePose(rx: rest.rotationXDeg, ry: rest.rotationYDeg,
                                     lift: 0, sx: 1 + 0.08 * t, sy: 1 - 0.10 * t)
        }
        // Rebound/settle 820–940 ms back to the exact result orientation (spring approximated).
        await tween(ms: 120, easing: CubicBezierEasing(x1: 0.20, y1: 0, x2: 0, y2: 1)) { t in
            self.rollPose = makePose(rx: rest.rotationXDeg, ry: rest.rotationYDeg,
                                     lift: 0, sx: 1 + 0.08 * (1 - t), sy: 1 - 0.10 * (1 - t))
        }
        rollPose = nil
    }

    // MARK: Internals

    private func enqueue(_ beat: @escaping @MainActor () async -> Void) {
        guard !reduceMotion else {
            // Reduced motion renders final states instantly, so release any pin taken above.
            hopOverride = nil
            captureReturn = nil
            return
        }
        queue.append(beat)
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        isAnimating = true
        let beat = queue.removeFirst() // escaping by design: held until its beat finishes
        // The running beat is HELD so cancelAll can actually stop it. Clearing the queue alone
        // left the in-flight tween running: it kept writing pawn positions after a
        // fast-forward, so a token that had already snapped to its destination was dragged back
        // along a path that no longer applied.
        beatTask = Task { @MainActor in
            await beat()
            guard !Task.isCancelled else { return }
            self.running = false
            self.isAnimating = !self.queue.isEmpty
            self.beatTask = nil
            self.pump()
        }
    }

    private var beatTask: Task<Void, Never>?

    /// ~60 fps frame loop that runs ONLY while a beat is active; an idle board consumes no
    /// display loop (§19).
    private func tween(ms: Double, easing: CubicBezierEasing,
                       _ frame: (Double) -> Void) async {
        let start = CACurrentMediaTime()
        let duration = ms / 1000
        while true {
            // A cancelled beat stops writing immediately and does NOT jump to its end frame:
            // authoritative state already holds the final positions, so the board is correct
            // the moment the override is released.
            if Task.isCancelled { return }
            let t = (CACurrentMediaTime() - start) / duration
            if t >= 1 { frame(1); break }
            frame(easing.transform(t))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    static func stableHash(_ input: String) -> UInt64 {
        var h: UInt64 = 14_652_730_921_284_997
        for b in input.utf8 { h = h &* 31 &+ UInt64(b) }
        return h
    }
}

/// Minimal cubic-Bézier solver sharing the tokens file's control points.
struct CubicBezierEasing {
    let x1: Double, y1: Double, x2: Double, y2: Double

    func transform(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        var lo = 0.0, hi = 1.0, mid = t
        repeat {
            mid = (lo + hi) / 2
            let x = bezier(mid, x1, x2)
            if x < t { lo = mid } else { hi = mid }
        } while hi - lo > 1e-6
        return bezier(mid, y1, y2)
    }

    private func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }
}
