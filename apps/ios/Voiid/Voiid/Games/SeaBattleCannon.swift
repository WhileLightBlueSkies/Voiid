//
//  SeaBattleCannon.swift
//  Voiid
//
//  The launcher, the rocket and the blast (docs/games/VISUALS_AUDIO_AND_PARITY.md §6.4).
//
//  WHY THIS IS A FILE AND NOT MORE OF `SeaBattleBoard.swift`.
//
//  The board renderer's job is to answer "what does square 47 show" a hundred times. The
//  ordnance is the opposite shape of problem: one object, continuous position, four phases, and
//  none of it is per-cell. Mixed into the cell loop it was 90 lines of trigonometry inside a
//  `for index in 0..<100`, and every change to a fireball risked the grid.
//
//  THE FOUR PHASES, and which of them is in the latency budget:
//
//    | Phase     | Budget | What it is                                                     |
//    |-----------|--------|----------------------------------------------------------------|
//    | Charge    | 140 ms | Launcher swings onto the bearing and pulls back. Starts on the |
//    |           |        | FIRE tap, so it overlaps the round trip and costs nothing.      |
//    | Flight    | 380 ms | The rocket. This IS the round-trip window (§3.3).               |
//    | Impact    | 140 ms | Fireball, shockwave, debris. AFTER the reveal, so free.         |
//    | Aftermath | 380 ms | Smoke drifts off and the marker settles into its final form.    |
//
//  Only the flight is in the budget. Charge overlaps the network and impact runs after the
//  result is already on screen, so the total added latency of all of this is zero — which is
//  the entire reason it is safe to make a turn-based game this loud.
//
//  A ROCKET, NOT A TUMBLING BOMB. A bomb is a passive object and its read is "it fell"; a rocket
//  is an object under power and its read is "it was sent". The difference is entirely in two
//  details: the rocket is ORIENTED ALONG ITS OWN VELOCITY (so it noses over at the top of the
//  arc rather than spinning), and it leaves an EXHAUST TRAIL, which is what makes the arc
//  legible as a path instead of a position.
//
//  Mirrors Android `SeaBattleCannon.kt`. Every constant here is a parity surface.
//

import SwiftUI

enum SeaBattleCannon {

    // MARK: - Phase durations
    //
    // Read by `SeaBattleMotion`, which owns the clocks; this file owns only the drawing. Keeping
    // the numbers here means the drawing and the timing cannot drift apart.

    static let chargeDuration: TimeInterval = 0.140
    static let flightDuration: TimeInterval = 0.380
    /// Impact plus aftermath. The blast is one clock: the fireball owns the first quarter of it
    /// and the smoke owns the rest, which is cheaper than two overlapping timers.
    static let blastDuration: TimeInterval = 0.520
    /// A sunk ship gets a longer blast with a second detonation in it (§6.3).
    static let sunkBlastDuration: TimeInterval = 0.720

    // MARK: - Geometry
    //
    // Shared by the drawing below AND by anything that needs to know where the rocket is —
    // there must be exactly one answer to "where is it at t", or the shadow drifts off the body.

    /// The launcher sits at the near edge of the board being fired at, centred.
    ///
    /// JUST INSIDE THE BOARD, not below it. The grid draws into a square canvas that clips at its
    /// own edge, so a muzzle at `board + 0.35` put the whole base plate outside the clip and left
    /// a tube stub apparently growing out of nothing. Sitting it 0.16 of a cell inside the bottom
    /// rim costs a sliver of the two centre squares of row 10 and is the layout the reference art
    /// has anyway.
    static func muzzle(board: CGFloat, cellSize: CGFloat) -> CGPoint {
        CGPoint(x: board / 2, y: board - cellSize * 0.16)
    }

    /// Arc height scales with distance, clamped so a near shot still lobs and a far one does not
    /// leave the board.
    static func arcHeight(muzzle m: CGPoint, target: CGPoint, cellSize: CGFloat) -> CGFloat {
        let distanceCells = hypot(target.x - m.x, target.y - m.y) / cellSize
        return min(max(distanceCells * 0.28, 0.9), 3.2) * cellSize
    }

    /// Where the rocket is at `t`. A straight ground track plus a parabola that is zero at both
    /// ends — so the rocket leaves the muzzle and arrives at the cell exactly, whatever the arc.
    static func position(muzzle m: CGPoint, target: CGPoint, arc: CGFloat, t: Double) -> CGPoint {
        let ground = groundTrack(muzzle: m, target: target, t: t)
        return CGPoint(x: ground.x, y: ground.y - arc * 4 * CGFloat(t * (1 - t)))
    }

    /// The point on the sea directly under the rocket. The shadow walks this, which is what
    /// makes the arc read as height rather than as sideways drift.
    static func groundTrack(muzzle m: CGPoint, target: CGPoint, t: Double) -> CGPoint {
        CGPoint(x: m.x + (target.x - m.x) * CGFloat(t),
                y: m.y + (target.y - m.y) * CGFloat(t))
    }

    /// Which way the rocket is pointing: the tangent of the flight path, not the muzzle-to-target
    /// bearing. THIS is the detail that separates a rocket from a thrown object — it climbs
    /// nose-up, levels at apex, and noses over into the target.
    static func heading(muzzle m: CGPoint, target: CGPoint, arc: CGFloat, t: Double) -> CGFloat {
        let dx = target.x - m.x
        let dy = (target.y - m.y) - arc * 4 * CGFloat(1 - 2 * t)
        return atan2(dy, dx)
    }

    // MARK: - The launcher

    /// The launcher at the near edge: a base, and a tube on it that swings onto the bearing
    /// during the charge and recoils when the rocket leaves.
    ///
    /// `charge` is 0...1 through the swing, `flight` is 0...1 through the rocket's travel (or 0
    /// when nothing is in the air). Drawn even at rest so the player can see what fires — a
    /// launcher that materialises only during a shot reads as a glitch.
    static func launcher(
        in ctx: GraphicsContext, board: CGFloat, cellSize: CGFloat,
        target: CGPoint?, charge: Double, flight: Double, team: SeaBattleTeam, ink: Color
    ) {
        let p = team.palette
        let m = muzzle(board: board, cellSize: cellSize)

        // At rest the tube points straight up the board. `charge` eases it onto the bearing, and
        // it STAYS there for the whole flight — a tube that snaps back while its own rocket is
        // still in the air is the single most common way this kind of animation reads as fake.
        let rest = -CGFloat.pi / 2
        let aim = target.map { atan2($0.y - m.y, $0.x - m.x) } ?? rest
        let swing = charge <= 0 && flight <= 0 ? 0 : max(charge, flight > 0 ? 1 : 0)
        let angle = rest + (aim - rest) * CGFloat(ease(swing))

        // Recoil: pulled back through the charge, snapped out on launch, settling over the first
        // third of the flight.
        let pullback = cellSize * 0.10 * CGFloat(ease(charge))
        let kick = flight > 0 ? cellSize * 0.22 * CGFloat(max(0, 1 - flight / 0.30)) : 0
        let recoil = pullback + kick

        var tube = ctx
        tube.translateBy(x: m.x, y: m.y)
        tube.rotate(by: .radians(Double(angle)))

        // The tube itself, drawn pointing along +x so the rotation above aims it.
        //
        // IT STOWS WHEN NOTHING IS HAPPENING. At rest the tube is a stub barely taller than its
        // own base; committing to a shot runs it out to full length. That is what keeps a
        // permanent fixture from covering the two squares it sits on for the whole match — a
        // launcher you cannot fire past would be a worse problem than no launcher at all.
        let len = cellSize * (0.40 + 0.58 * CGFloat(ease(swing)))
        let halfBeam = cellSize * 0.135
        tube.fill(
            Path(roundedRect: CGRect(x: -cellSize * 0.20 - recoil, y: -halfBeam,
                                     width: len, height: halfBeam * 2),
                 cornerRadius: halfBeam * 0.5),
            with: .linearGradient(
                Gradient(colors: [p.deck, p.body]),
                startPoint: CGPoint(x: 0, y: -halfBeam),
                endPoint: CGPoint(x: 0, y: halfBeam)))
        tube.stroke(
            Path(roundedRect: CGRect(x: -cellSize * 0.20 - recoil, y: -halfBeam,
                                     width: len, height: halfBeam * 2),
                 cornerRadius: halfBeam * 0.5),
            with: .color(p.ink.opacity(0.85)), lineWidth: 1)
        // The muzzle ring, so the tube has a front.
        tube.stroke(
            Path(ellipseIn: CGRect(x: len - cellSize * 0.26 - recoil, y: -halfBeam * 0.85,
                                   width: halfBeam * 0.7, height: halfBeam * 1.7)),
            with: .color(p.stripe.opacity(0.9)), lineWidth: 1.2)

        // MUZZLE FLASH — only in the first 60 ms of the flight, and drawn in the tube's frame so
        // it sits on the muzzle whichever way the tube is aimed.
        if flight > 0, flight < 0.16 {
            let f = 1 - flight / 0.16
            let r = cellSize * 0.34 * CGFloat(f)
            let nose = CGPoint(x: len - cellSize * 0.20 - recoil, y: 0)
            tube.fill(
                Path(ellipseIn: CGRect(x: nose.x - r, y: nose.y - r * 0.8,
                                       width: r * 2, height: r * 1.6)),
                with: .radialGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.95 * f),
                        Color(red: 1.0, green: 0.82, blue: 0.35).opacity(0.85 * f),
                        Color(red: 0.95, green: 0.42, blue: 0.10).opacity(0),
                    ]),
                    center: nose, startRadius: 0, endRadius: r))
        }

        // The base plate, in the BOARD's frame — it does not rotate with the tube.
        let baseW = cellSize * 0.80, baseH = cellSize * 0.30
        let baseRect = CGRect(x: m.x - baseW / 2, y: m.y - baseH * 0.5,
                              width: baseW, height: baseH)
        ctx.fill(
            Path(roundedRect: baseRect, cornerRadius: baseH * 0.42),
            with: .linearGradient(
                Gradient(colors: [p.lit, p.body]),
                startPoint: CGPoint(x: m.x, y: baseRect.minY),
                endPoint: CGPoint(x: m.x, y: baseRect.maxY)))
        ctx.stroke(
            Path(roundedRect: baseRect, cornerRadius: baseH * 0.42),
            with: .color(ink.opacity(0.5)), lineWidth: 1)
    }

    // MARK: - The rocket

    /// The rocket in flight, its exhaust trail and its shadow.
    ///
    /// THREE DETAILS SELL IT, and none is optional (§6.4):
    ///   * it SCALES along the flight (1.0 -> 1.55 -> 0.85), which is perspective in a top-down
    ///     view and the difference between "launched" and "slid";
    ///   * a SHADOW tracks the straight muzzle->target line at sea level while the rocket arcs
    ///     above it — without it the arc reads as sideways drift;
    ///   * it is ORIENTED ALONG ITS VELOCITY and leaves a fading EXHAUST TRAIL, which is what
    ///     makes the arc read as a path rather than as a position.
    static func rocket(
        in ctx: GraphicsContext, cellSize: CGFloat,
        muzzle m: CGPoint, target: CGPoint, t: Double, team: SeaBattleTeam, ink: Color
    ) {
        let p = team.palette
        let arc = arcHeight(muzzle: m, target: target, cellSize: cellSize)
        let ground = groundTrack(muzzle: m, target: target, t: t)
        let pos = position(muzzle: m, target: target, arc: arc, t: t)
        let angle = heading(muzzle: m, target: target, arc: arc, t: t)
        let scale = 1.0 + 0.55 * sin(t * .pi) - 0.15 * t

        // SMOKE TRAIL, oldest first so newer puffs overlap older ones. Sampled backwards along
        // the same parabola the rocket is on, so the trail is the flight path by construction
        // and cannot drift away from it.
        for k in 1...7 {
            let age = Double(k) * 0.055
            let tk = t - age
            guard tk > 0.01 else { continue }
            let q = position(muzzle: m, target: target, arc: arc, t: tk)
            let r = cellSize * (0.070 + 0.034 * CGFloat(k))
            // Fades with age AND with the whole flight, so nothing is left hanging at impact.
            let a = 0.42 * (1 - Double(k) / 8.0) * min(1, t * 5) * (1 - t * 0.55)
            ctx.fill(
                Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)),
                with: .color(Color(red: 0.78, green: 0.78, blue: 0.80).opacity(a)))
        }

        // Shadow on the sea, shrinking as the rocket climbs away from it.
        let shadowR = cellSize * 0.15 * (1 - 0.35 * CGFloat(sin(t * .pi)))
        ctx.fill(
            Path(ellipseIn: CGRect(x: ground.x - shadowR, y: ground.y - shadowR * 0.5,
                                   width: shadowR * 2, height: shadowR)),
            with: .color(ink.opacity(0.26)))

        var body = ctx
        body.translateBy(x: pos.x, y: pos.y)
        body.rotate(by: .radians(Double(angle)))

        let len = cellSize * 0.62 * CGFloat(scale)
        let r = cellSize * 0.105 * CGFloat(scale)

        // EXHAUST, behind the tail. Flickers on a fast sine so the flame is alive over a 380 ms
        // flight — a static cone reads as a paper cutout.
        let flick = 0.72 + 0.28 * sin(t * 46)
        let flameLen = len * 0.85 * CGFloat(flick)
        var flame = Path()
        flame.move(to: CGPoint(x: -len * 0.44, y: -r * 0.85))
        flame.addQuadCurve(to: CGPoint(x: -len * 0.44 - flameLen, y: 0),
                           control: CGPoint(x: -len * 0.60, y: -r * 0.55))
        flame.addQuadCurve(to: CGPoint(x: -len * 0.44, y: r * 0.85),
                           control: CGPoint(x: -len * 0.60, y: r * 0.55))
        flame.closeSubpath()
        body.fill(flame, with: .linearGradient(
            Gradient(colors: [
                Color.white.opacity(0.95),
                Color(red: 1.0, green: 0.78, blue: 0.26).opacity(0.85),
                Color(red: 0.94, green: 0.34, blue: 0.08).opacity(0.0),
            ]),
            startPoint: CGPoint(x: -len * 0.44, y: 0),
            endPoint: CGPoint(x: -len * 0.44 - flameLen, y: 0)))

        // FUSELAGE: a body that stops short of the nose, then a cone. Drawn as one path so the
        // outline runs round the whole silhouette rather than showing a seam at the shoulder.
        var hull = Path()
        hull.move(to: CGPoint(x: -len * 0.44, y: -r))
        hull.addLine(to: CGPoint(x: len * 0.12, y: -r))
        hull.addQuadCurve(to: CGPoint(x: len * 0.50, y: 0),
                          control: CGPoint(x: len * 0.40, y: -r * 0.72))
        hull.addQuadCurve(to: CGPoint(x: len * 0.12, y: r),
                          control: CGPoint(x: len * 0.40, y: r * 0.72))
        hull.addLine(to: CGPoint(x: -len * 0.44, y: r))
        hull.closeSubpath()

        // FINS at the tail, one up one down. Two is enough in a top-down view and a third only
        // muddies the silhouette at this size.
        var fins = Path()
        fins.move(to: CGPoint(x: -len * 0.26, y: -r))
        fins.addLine(to: CGPoint(x: -len * 0.48, y: -r * 2.15))
        fins.addLine(to: CGPoint(x: -len * 0.48, y: -r * 0.9))
        fins.closeSubpath()
        fins.move(to: CGPoint(x: -len * 0.26, y: r))
        fins.addLine(to: CGPoint(x: -len * 0.48, y: r * 2.15))
        fins.addLine(to: CGPoint(x: -len * 0.48, y: r * 0.9))
        fins.closeSubpath()
        body.fill(fins, with: .color(p.body))
        body.stroke(fins, with: .color(p.ink.opacity(0.8)), lineWidth: 0.8)

        body.fill(hull, with: .linearGradient(
            Gradient(colors: [Color(red: 0.90, green: 0.91, blue: 0.93), p.body]),
            startPoint: CGPoint(x: 0, y: -r),
            endPoint: CGPoint(x: 0, y: r)))
        body.stroke(hull, with: .color(p.ink.opacity(0.9)), lineWidth: 0.9)

        // The team band and the warhead tip: the rocket is the firing team's colour, which is
        // how a spectator knows whose shot is in the air.
        body.fill(
            Path(roundedRect: CGRect(x: -len * 0.06, y: -r, width: len * 0.14, height: r * 2),
                 cornerRadius: r * 0.3),
            with: .color(p.stripe))
        body.fill(
            Path(ellipseIn: CGRect(x: len * 0.28, y: -r * 0.42,
                                   width: r * 0.84, height: r * 0.84)),
            with: .color(p.stripe.opacity(0.9)))
    }

    // MARK: - The blast

    /// The impact. `kind` is the server's own `lastResult` — 0 miss, 1 hit, 2 hit-and-sunk —
    /// so the explosion can never disagree with the board about what happened.
    ///
    /// `t` runs 0...1 over `blastDuration`. The fireball owns roughly the first quarter and the
    /// smoke owns the rest, on one clock: two overlapping timers is two things to cancel when a
    /// screen goes away mid-shot.
    ///
    /// `seed` is the cell index, so every speck of debris is deterministic per square — a
    /// re-render mid-blast must not reshuffle the shrapnel.
    static func blast(
        in ctx: GraphicsContext, at c: CGPoint, cellSize: CGFloat,
        t: Double, kind: Int, seed: Int, ink: Color
    ) {
        guard t > 0, t < 1 else { return }
        if kind == 0 {
            splash(in: ctx, at: c, cellSize: cellSize, t: t, seed: seed, ink: ink)
        } else {
            detonation(in: ctx, at: c, cellSize: cellSize, t: t, seed: seed, ink: ink, scale: 1)
            // A SUNK SHIP GETS A SECOND DETONATION, 40% of the way through and offset off the
            // impact point — a magazine going up. It is the only thing on this board that ever
            // happens twice, which is what makes a sink feel different from a hit rather than
            // just louder.
            if kind == 2, t > 0.34 {
                let t2 = (t - 0.34) / 0.66
                let dx = CGFloat(GameSurface.noise(seed, 71, seed: 31) - 0.5) * cellSize * 0.7
                let dy = CGFloat(GameSurface.noise(seed, 72, seed: 32) - 0.5) * cellSize * 0.7
                detonation(in: ctx, at: CGPoint(x: c.x + dx, y: c.y + dy),
                           cellSize: cellSize, t: t2, seed: seed &+ 977, ink: ink, scale: 0.8)
            }
        }
    }

    /// A HIT: white core, fireball, shockwave, debris, smoke.
    private static func detonation(
        in ctx: GraphicsContext, at c: CGPoint, cellSize: CGFloat,
        t: Double, seed: Int, ink: Color, scale: CGFloat
    ) {
        // FLASH — the first 70 ms only. It is what gives the blast an onset; without it the
        // fireball reads as growing rather than as detonating.
        if t < 0.14 {
            let f = 1 - t / 0.14
            let r = cellSize * scale * (0.30 + 1.10 * CGFloat(t / 0.14))
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(0.85 * f)))
        }

        // FIREBALL — expands hard then holds and fades. `pow(t, 0.42)` is the deceleration:
        // an explosion is fastest at the instant it starts.
        let grow = pow(min(t / 0.34, 1), 0.42)
        let fr = cellSize * scale * (0.18 + 0.72 * CGFloat(grow))
        let fade = t < 0.34 ? 1.0 : max(0, 1 - (t - 0.34) / 0.30)
        if fade > 0 {
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - fr, y: c.y - fr, width: fr * 2, height: fr * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.95 * fade),
                        Color(red: 1.00, green: 0.83, blue: 0.30).opacity(0.95 * fade),
                        Color(red: 0.93, green: 0.38, blue: 0.09).opacity(0.85 * fade),
                        Color(red: 0.42, green: 0.09, blue: 0.05).opacity(0.0),
                    ]),
                    center: c, startRadius: 0, endRadius: fr))
        }

        // SHOCKWAVE — a thin ring that outruns the fireball and thins as it goes. This is the
        // part that makes the blast feel like it has force rather than volume.
        let sw = cellSize * scale * (0.22 + 2.10 * CGFloat(pow(t, 0.55)))
        let swAlpha = max(0, 1 - t / 0.62)
        if swAlpha > 0 {
            ctx.stroke(
                Path(ellipseIn: CGRect(x: c.x - sw, y: c.y - sw, width: sw * 2, height: sw * 2)),
                with: .color(.white.opacity(0.55 * swAlpha * swAlpha)),
                lineWidth: max(0.4, 2.4 * CGFloat(swAlpha)))
        }

        // DEBRIS — six specks thrown clear and pulled down. §6.4 asks for six; they are seeded
        // per cell so a re-render mid-blast cannot reshuffle them.
        for k in 0..<6 {
            let a = GameSurface.noise(seed, k, seed: 41) * 6.28318
            let speed = 1.5 + GameSurface.noise(seed, k, seed: 42) * 1.5
            let d = cellSize * scale * CGFloat(speed) * CGFloat(t) * CGFloat(1.15 - 0.35 * t)
            // Gravity, so shrapnel falls back rather than flying off in a straight line.
            let drop = cellSize * scale * 1.5 * CGFloat(t * t)
            let px = c.x + CoreGraphics.cos(a) * d
            let py = c.y + CoreGraphics.sin(a) * d * 0.75 + drop
            let sz = cellSize * scale * 0.075 * CGFloat(1 - t * 0.6)
            let alpha = max(0, 1 - t / 0.85)
            ctx.fill(
                Path(ellipseIn: CGRect(x: px - sz, y: py - sz, width: sz * 2, height: sz * 2)),
                with: .color(ink.opacity(0.65 * alpha)))
        }

        // SMOKE — the aftermath, drifting up and dissipating (§6.4). Starts only once the
        // fireball is past its peak, so the two never fight for the same pixels.
        guard t > 0.26 else { return }
        let st = (t - 0.26) / 0.74
        for k in 0..<4 {
            let off = Double(k) * 0.16
            let q = st - off
            guard q > 0 else { continue }
            let dx = CGFloat(GameSurface.noise(seed, k, seed: 43) - 0.5) * cellSize * 0.9 * CGFloat(q)
            let rise = cellSize * scale * 0.9 * CGFloat(q)
            let r = cellSize * scale * (0.18 + 0.42 * CGFloat(q))
            let alpha = 0.36 * (1 - q) * (1 - q)
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x + dx - r, y: c.y - rise - r,
                                       width: r * 2, height: r * 2)),
                with: .color(Color(red: 0.34, green: 0.34, blue: 0.36).opacity(alpha)))
        }
    }

    /// A MISS: a water column, not a small explosion.
    ///
    /// §8.4 requires hit and miss to differ in SHAPE before they differ in colour, and that rule
    /// has to survive into the animation or the board stops working in greyscale for the one
    /// second per turn when something is actually happening. A splash is hollow rings and a
    /// falling column; a hit is a filled expanding disc. They are opposite shapes on purpose.
    private static func splash(
        in ctx: GraphicsContext, at c: CGPoint, cellSize: CGFloat,
        t: Double, seed: Int, ink: Color
    ) {
        // The column: up fast, back down under gravity, gone by 60% of the clock.
        if t < 0.62 {
            let ct = t / 0.62
            let h = cellSize * 1.15 * CGFloat(sin(ct * .pi) * 0.9 + ct * 0.1)
            let w = cellSize * (0.30 - 0.10 * CGFloat(ct))
            var column = Path()
            column.move(to: CGPoint(x: c.x - w, y: c.y))
            column.addQuadCurve(to: CGPoint(x: c.x, y: c.y - h),
                                control: CGPoint(x: c.x - w * 0.8, y: c.y - h * 0.55))
            column.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y),
                                control: CGPoint(x: c.x + w * 0.8, y: c.y - h * 0.55))
            column.closeSubpath()
            ctx.fill(column, with: .linearGradient(
                Gradient(colors: [
                    Color.white.opacity(0.0),
                    Color.white.opacity(0.55 * (1 - ct)),
                    Color(red: 0.86, green: 0.93, blue: 0.96).opacity(0.75 * (1 - ct)),
                ]),
                startPoint: CGPoint(x: c.x, y: c.y - h),
                endPoint: CGPoint(x: c.x, y: c.y)))
        }

        // Droplets thrown off the top of the column and falling back.
        for k in 0..<5 {
            let a = (GameSurface.noise(seed, k, seed: 51) - 0.5) * 3.0
            let q = min(1, t / 0.75)
            let d = cellSize * 1.0 * CGFloat(q) * CGFloat(0.6 + GameSurface.noise(seed, k, seed: 52))
            let px = c.x + CGFloat(a) * d * 0.6
            let py = c.y - cellSize * 0.85 * CGFloat(sin(Double(q) * .pi)) + cellSize * 0.5 * CGFloat(q * q)
            let sz = cellSize * 0.05 * CGFloat(1 - q * 0.5)
            ctx.fill(
                Path(ellipseIn: CGRect(x: px - sz, y: py - sz, width: sz * 2, height: sz * 2)),
                with: .color(Color.white.opacity(0.7 * (1 - q))))
        }

        // THREE HOLLOW RINGS spreading out. The permanent miss marker is a hollow ring too, so
        // the animation resolves INTO the marker rather than being replaced by it.
        for k in 0..<3 {
            let delay = Double(k) * 0.14
            let q = (t - delay) / (1 - delay)
            guard q > 0 else { continue }
            let rr = cellSize * (0.14 + 0.62 * CGFloat(q))
            let alpha = max(0, 0.60 * (1 - q))
            ctx.stroke(
                Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr * 0.62,
                                       width: rr * 2, height: rr * 1.24)),
                with: .color(ink.opacity(alpha)),
                lineWidth: max(0.4, 1.4 * CGFloat(1 - q)))
        }
    }

    // MARK: - Helpers

    /// Ease-out-cubic. The launcher swings quickly and settles; a linear swing reads as a
    /// mechanism being driven rather than one aiming.
    private static func ease(_ x: Double) -> Double {
        let c = max(0, min(1, x))
        return 1 - pow(1 - c, 3)
    }
}
