//
//  SnakeArenaView.swift
//  Voiid
//
//  Snake — the first CONTINUOUS game screen (docs/GAMES.md §70, §80).
//
//  WHY THIS ONE IS DIFFERENT FROM EVERY OTHER GAME VIEW HERE. Tic Tac Toe, RPS and cricket
//  redraw when a frame lands and are done: their state changes a few times a minute. Snake's
//  server ticks 10 times a second, so drawing frames on arrival would show visible 10 fps
//  stepping. This view runs its own 60 fps clock (TimelineView) and reconstructs the motion
//  between server frames.
//
//  THREE THINGS MAKE IT SMOOTH, and the first version shipped without any of them:
//
//  1. A JITTER BUFFER, not a frame pair. Interpolating between "current" and "previous" timed
//     by ARRIVAL means network jitter is rendered directly: frames do not land evenly, so the
//     snake held and then jumped. The engine now keeps the last few frames stamped with the
//     SERVER's own clock (`t`), and this view renders ~150 ms in the past, interpolating
//     between whichever pair brackets that instant. Uneven arrivals are absorbed.
//
//  2. CLIENT-BUILT TRAILS. The body is NOT drawn by interpolating the server's path points.
//     The server prepends a head point each tick and decimates long tails, so index i is a
//     DIFFERENT piece of snake between frames — interpolating them against each other made
//     the whole body crawl and twitch. Instead each snake keeps a local trail: the smoothly
//     interpolated head is appended every render frame and the trail is arc-trimmed to the
//     body length. The curve is then built from 60 fps of head motion, and the server path is
//     used only to seed or re-sync it.
//
//  3. A REAL JOYSTICK. Steering toward the finger's offset from screen centre gave no fixed
//     reference and read as "the snake doesn't go where my hand goes". A fixed ring with a
//     clamped knob does.
//
//  This is all interpolation and input, never prediction: no position is drawn that the
//  server did not send, so "the client is a renderer, not a referee" still holds exactly.
//
//  Mirrors Android `SnakeArenaScreen.kt`.
//

import SwiftUI

struct SnakeArenaView: View {
    let matchId: String
    let onClose: () -> Void

    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = GamesEngine.shared

    @State private var boosting = false
    /// Live joystick vector, normalized to the ring radius. `.zero` at rest.
    @State private var stick: CGVector = .zero
    /// Last heading actually committed, so releasing boost cannot also change direction.
    @State private var lastHeading: Double = 0
    /// Per-snake body trails, rebuilt locally from interpolated head motion.
    @State private var trails = TrailStore()

    private var me: String? { TokenStore.shared.userId }

    /// Distinct, high-contrast body colours. Index comes from the server so a snake keeps its
    /// colour for the whole match and both devices agree on who is who.
    private static let palette: [Color] = [
        Color(red: 1.00, green: 0.23, blue: 0.28),
        Color(red: 0.13, green: 0.88, blue: 0.94),
        Color(red: 0.61, green: 0.36, blue: 1.00),
        Color(red: 0.36, green: 0.90, blue: 0.36),
        Color(red: 1.00, green: 0.54, blue: 0.17),
        Color(red: 1.00, green: 0.85, blue: 0.24),
        Color(red: 1.00, green: 0.31, blue: 0.85),
        Color(red: 0.07, green: 0.79, blue: 0.55),
        Color(red: 0.30, green: 0.66, blue: 1.00),
        Color(red: 0.78, green: 0.96, blue: 0.24),
        Color(red: 1.00, green: 0.69, blue: 0.13),
        Color(red: 0.55, green: 0.97, blue: 0.78),
    ]

    private static func color(_ index: Int) -> Color {
        palette[((index % palette.count) + palette.count) % palette.count]
    }

    /// How far behind the newest frame to render, in seconds.
    ///
    /// Slightly more than one 10 Hz tick, so there is virtually always a NEWER frame to
    /// interpolate towards. Less than a tick and the buffer runs dry constantly, which is the
    /// stutter this is meant to remove; much more and the controls start to feel remote.
    private static let interpDelay: Double = 0.15

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(context: context, size: size, now: timeline.date)
                    }
                    .ignoresSafeArea()
                }

                controlsOverlay(geo: geo)
            }
            .background(Color.black)
        }
        .navigationBarBackButtonHidden(true)
        // The tab bar is app chrome and this is a full-screen game — every other game view
        // hides it the same way (TicTacToeView, CricketBotView, ...). Without this the bar
        // sat over the arena and ate touches along the bottom edge.
        .onAppear { session.hideTabBar = true }
        .task { await engine.open(matchId: matchId) }
        // Flush pending steering on its own clock rather than from inside the Canvas draw
        // closure. A send is a side effect, and SwiftUI may call a draw closure more or less
        // often than once per frame — the previous version worked only by accident.
        .task {
            while !Task.isCancelled {
                engine.flushSteering()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        .onDisappear {
            session.hideTabBar = false
            engine.leave()
        }
    }

    // MARK: - Interpolation

    /// The pair of frames bracketing the render instant, plus the blend between them.
    private struct Sample {
        let from: SnakeState
        let to: SnakeState
        let t: Double
    }

    /// Pick the two frames to draw between.
    ///
    /// The render clock is derived from the SERVER's `t` values, offset by how long the
    /// newest frame has been sitting here. Arrival jitter therefore moves the offset, not the
    /// snake. When the buffer runs dry the newest frame is HELD rather than extrapolated —
    /// extrapolation looks smoother right up until the real frame lands somewhere else and
    /// everything snaps, which reads far worse than a brief pause.
    private func sample() -> Sample? {
        let frames = engine.snakeFrames
        guard let newest = frames.last else { return nil }
        guard frames.count >= 2 else {
            return Sample(from: newest.state, to: newest.state, t: 1)
        }

        let elapsed = CACurrentMediaTime() - newest.arrivedAt
        let renderT = newest.state.time + elapsed - Self.interpDelay

        // Oldest bracketing pair whose span contains renderT.
        for i in stride(from: frames.count - 2, through: 0, by: -1) {
            let a = frames[i].state
            let b = frames[i + 1].state
            if renderT >= a.time {
                let span = b.time - a.time
                let t = span > 1e-6 ? min(max((renderT - a.time) / span, 0), 1) : 1
                return Sample(from: a, to: b, t: t)
            }
        }

        // renderT is older than everything buffered (a long stall). Show the oldest pair's
        // start rather than jumping to the newest.
        return Sample(from: frames[0].state, to: frames[1].state, t: 0)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private func lerpPoint(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
    }

    /// Angular interpolation on the SHORT arc, so a snake crossing the -pi/pi wrap does not
    /// spin the long way round.
    private func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var delta = b - a
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return a + delta * t
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, size: CGSize, now: Date) {
        guard let s = sample() else { return }
        let state = s.to

        // Interpolated head positions for every snake this frame, keyed by id.
        var heads: [String: CGPoint] = [:]
        var headings: [String: Double] = [:]
        for snake in state.snakes {
            let prev = s.from.snakes.first { $0.id == snake.id }
            heads[snake.id] = lerpPoint(
                prev.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: snake.x, y: snake.y),
                CGPoint(x: snake.x, y: snake.y), s.t)
            headings[snake.id] = lerpAngle(prev?.heading ?? snake.heading, snake.heading, s.t)
        }

        trails.update(state: state, heads: heads)

        let focus = heads[me ?? ""] ?? .zero
        let mass = state.snakes.first { $0.id == me }?.mass ?? 10

        // Zoom out as the snake grows so it stays framed, easing off so growth is not
        // nauseating.
        let zoom = 1.0 / (1.0 + log10(1 + mass / 30) * 0.42)
        let scale = (min(size.width, size.height) / 900.0) * zoom

        var ctx = context
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -focus.x, y: -focus.y)

        drawArena(ctx: &ctx, radius: state.arenaRadius)
        drawFood(ctx: &ctx, state: state)

        // Others first, the local player last, so your own body is never buried under
        // someone else's in a scrum.
        for snake in state.snakes where snake.alive && snake.id != me {
            drawSnake(ctx: &ctx, snake: snake, head: heads[snake.id] ?? .zero,
                      heading: headings[snake.id] ?? 0, isMe: false, time: state.time)
        }
        if let mine = state.snakes.first(where: { $0.id == me }), mine.alive {
            drawSnake(ctx: &ctx, snake: mine, head: heads[mine.id] ?? .zero,
                      heading: headings[mine.id] ?? 0, isMe: true, time: state.time)
        }
    }

    private func drawArena(ctx: inout GraphicsContext, radius: Double) {
        let rect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)

        ctx.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.07, green: 0.06, blue: 0.16),
                    Color(red: 0.02, green: 0.02, blue: 0.05),
                ]),
                center: .zero, startRadius: 0, endRadius: radius))

        // Drawn EXACTLY at the lethal line, not inside or outside it. A wall whose visible
        // edge disagrees with the killing surface makes every border death feel unfair, and
        // players cannot learn a boundary they cannot see precisely.
        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 22, dy: 22)),
                   with: .color(Color(red: 0.35, green: 0.85, blue: 1.0).opacity(0.16)),
                   lineWidth: 40)
        ctx.stroke(Path(ellipseIn: rect), with: .color(Color(red: 0.35, green: 0.85, blue: 1.0)),
                   lineWidth: 6)
    }

    private func drawFood(ctx: inout GraphicsContext, state: SnakeState) {
        // Food never moves, so it is drawn from the newest frame with no interpolation.
        for item in state.food {
            let radius: Double = item.value >= 2 ? 7 : item.value < 1 ? 4.5 : 5.5
            let color: Color = item.value >= 2
                ? Color(red: 1.0, green: 0.72, blue: 0.45)
                : Color(red: 1.0, green: 0.93, blue: 0.62)

            let rect = CGRect(
                x: item.position.x - radius, y: item.position.y - radius,
                width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: -radius, dy: -radius)),
                     with: .color(color.opacity(0.18)))
            ctx.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    private func drawSnake(
        ctx: inout GraphicsContext,
        snake: SnakeState.Snake,
        head: CGPoint,
        heading: Double,
        isMe: Bool,
        time: Double
    ) {
        let points = trails.points(for: snake.id)
        guard points.count >= 2 else { return }

        let color = Self.color(snake.colorIndex)

        // Sub-linear thickness: linear growth would have a long snake filling the screen, and
        // length is meant to dominate by covering space, not by being fat.
        let width = 20.0 * (1 + log10(1 + snake.mass / 25) * 0.55)

        var path = Path()
        path.move(to: points[0])
        if points.count > 2 {
            // Quadratic smoothing through midpoints — the trail is a polyline of per-frame
            // samples, and drawing it as straight segments would show every corner.
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(
                    x: (points[i].x + points[i + 1].x) / 2,
                    y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
        }
        path.addLine(to: points[points.count - 1])

        // Spawn invulnerability reads as translucency, so a player knows not to bother
        // attacking and knows why they were not killed.
        let alpha = time < snake.invulnUntil ? 0.55 : 1.0

        ctx.stroke(path, with: .color(color.opacity(0.22 * alpha)),
                   style: StrokeStyle(lineWidth: width * 2.1, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: .color(color.opacity(alpha)),
                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))

        if isMe {
            // A rim no one else has. In a crowded arena hue alone is not enough to find
            // yourself quickly.
            ctx.stroke(path, with: .color(.white.opacity(0.85 * alpha)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        if snake.boosting {
            ctx.stroke(path, with: .color(.white.opacity(0.35)),
                       style: StrokeStyle(lineWidth: width * 0.45, lineCap: .round, lineJoin: .round))
        }

        drawHead(ctx: &ctx, at: head, heading: heading, width: width,
                 color: color, opacity: alpha, isMe: isMe)
    }

    private func drawHead(
        ctx: inout GraphicsContext,
        at head: CGPoint,
        heading: Double,
        width: Double,
        color: Color,
        opacity: Double,
        isMe: Bool
    ) {
        let r = width * 0.62
        let rect = CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)

        ctx.fill(Path(ellipseIn: rect.insetBy(dx: -r * 1.4, dy: -r * 1.4)),
                 with: .color(color.opacity(0.28 * opacity)))
        ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))

        // The local player's eyes follow the JOYSTICK rather than the confirmed heading, so
        // the aim responds on the same frame the thumb moves. Purely cosmetic — the body and
        // every collision still come from the server — but it is most of what makes the
        // control feel connected across a 10 Hz link.
        var look = heading
        if isMe, stick != .zero {
            look = atan2(stick.dy, stick.dx)
        }

        let eyeR = r * 0.3
        for side in [-1.0, 1.0] {
            let ex = head.x + cos(look) * r * 0.35 - sin(look) * side * r * 0.42
            let ey = head.y + sin(look) * r * 0.35 + cos(look) * side * r * 0.42
            ctx.fill(
                Path(ellipseIn: CGRect(x: ex - eyeR, y: ey - eyeR, width: eyeR * 2, height: eyeR * 2)),
                with: .color(.white.opacity(opacity)))
            let pr = eyeR * 0.52
            let px = ex + cos(look) * eyeR * 0.4
            let py = ey + sin(look) * eyeR * 0.4
            ctx.fill(
                Path(ellipseIn: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2)),
                with: .color(.black.opacity(opacity)))
        }
    }

    // MARK: - Controls

    private func controlsOverlay(geo: GeometryProxy) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(action: {
                        session.hideTabBar = false
                        onClose()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    scoreboard
                }
                Spacer()
            }
            .padding(14)

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VirtualJoystick(vector: $stick) { vector in
                        // Deadzone: below this the thumb is resting, not steering, and
                        // atan2 on a near-zero vector is meaningless noise.
                        guard hypot(vector.dx, vector.dy) >= 0.15 else { return }
                        let heading = atan2(vector.dy, vector.dx)
                        lastHeading = heading
                        engine.steer(heading: heading, boost: boosting)
                    }
                    Spacer()
                    boostButton
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 34)
        }
    }

    private var scoreboard: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let state = engine.snake {
                let ranked = state.snakes.sorted { $0.mass > $1.mass }.prefix(4)
                ForEach(Array(ranked), id: \.id) { snake in
                    HStack(spacing: 6) {
                        Circle().fill(Self.color(snake.colorIndex)).frame(width: 7, height: 7)
                        Text(snake.id == me ? "You" : displayName(snake))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(snake.id == me ? 1 : 0.75))
                        Text("\(Int(snake.mass))")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                Text(timeRemaining(state))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func displayName(_ snake: SnakeState.Snake) -> String {
        // Bots are named plausibly and never labelled as bots — a "BOT" tag would change how
        // players treat them, and practice is more useful when it feels like a real arena.
        snake.isBot
            ? String(snake.id.dropFirst(4)).uppercased()
            : UserDirectory.shared.displayName(snake.id, fallback: "Player")
    }

    private func timeRemaining(_ state: SnakeState) -> String {
        let left = max(0, state.duration - state.time)
        return String(format: "%d:%02d", Int(left) / 60, Int(left) % 60)
    }

    private var boostButton: some View {
        Circle()
            .fill(boosting ? Color.white.opacity(0.3) : Color.white.opacity(0.12))
            .overlay(Circle().stroke(.white.opacity(boosting ? 0.9 : 0.35), lineWidth: 2))
            .overlay(
                Text("BOOST")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white.opacity(0.9)))
            .frame(width: 78, height: 78)
            .scaleEffect(boosting ? 0.93 : 1)
            .animation(.easeOut(duration: 0.08), value: boosting)
            // Press-and-hold, not a toggle: boost is a held commitment, and a toggle costs a
            // tap to release at exactly the moment a player is busy steering.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !boosting else { return }
                        boosting = true
                        Haptics.rigid()
                        engine.steer(heading: lastHeading, boost: true)
                    }
                    .onEnded { _ in
                        boosting = false
                        engine.steer(heading: lastHeading, boost: false)
                    })
    }
}

// MARK: - Trail store

/// Per-snake body polylines, rebuilt on the client from interpolated head motion.
///
/// WHY NOT JUST DRAW THE SERVER'S PATH: the server prepends a head point every tick and
/// decimates the tail of long snakes, so the same array index is a different piece of snake
/// from one frame to the next. Interpolating those against each other made the whole body
/// crawl and twitch — the single worst part of how the first version looked.
///
/// A trail is appended at RENDER rate from the smoothly interpolated head, so the body is
/// built out of 60 fps of motion. The server's path is used only to seed a new snake, to
/// re-seed after a respawn, and to re-sync if the two ever drift apart.
///
/// A class, not a struct: it is mutated from inside the Canvas draw closure and must persist
/// across frames without SwiftUI treating each append as a state change to diff.
private final class TrailStore {
    private var trails: [String: [CGPoint]] = [:]
    /// Alive-ness last frame, so a respawn (false -> true) can reset the trail.
    private var wasAlive: [String: Bool] = [:]

    /// Matches the server's SEGMENT_SPACING. Body length in world units is mass x this.
    private static let segmentSpacing: Double = 14
    /// Minimum head movement before a new point is recorded, to bound the polyline length.
    private static let minStep: Double = 1.5
    /// Head-vs-trail divergence beyond which the local trail is wrong and gets re-seeded.
    private static let resyncDistance: Double = 60

    func points(for id: String) -> [CGPoint] { trails[id] ?? [] }

    func update(state: SnakeState, heads: [String: CGPoint]) {
        var seen = Set<String>()

        for snake in state.snakes {
            seen.insert(snake.id)
            let alive = snake.alive
            let respawned = alive && !(wasAlive[snake.id] ?? false)
            wasAlive[snake.id] = alive

            guard alive, let head = heads[snake.id] else {
                if !alive { trails[snake.id] = [] }
                continue
            }

            var trail = trails[snake.id] ?? []

            // Seed from the server path on first sight or after a respawn — a trail has to
            // start as a whole body, not grow from a dot over the first second.
            if trail.isEmpty || respawned {
                trail = snake.path.isEmpty ? [head] : snake.path
                trails[snake.id] = trail
                continue
            }

            // Re-sync if the local trail has drifted from where the server says the head is.
            // Happens after a stall or a big correction; without it a wrong trail persists
            // for the rest of the match.
            if let first = trail.first,
               hypot(head.x - first.x, head.y - first.y) > Self.resyncDistance {
                trail = snake.path.isEmpty ? [head] : snake.path
                trails[snake.id] = trail
                continue
            }

            if let first = trail.first,
               hypot(head.x - first.x, head.y - first.y) >= Self.minStep {
                trail.insert(head, at: 0)
            } else if !trail.isEmpty {
                // Keep the drawn head exactly on the interpolated position even when it has
                // not moved far enough to earn its own point.
                trail[0] = head
            }

            Self.trim(&trail, maxLength: snake.mass * Self.segmentSpacing)
            trails[snake.id] = trail
        }

        // Drop snakes that are no longer in the match at all.
        for id in trails.keys where !seen.contains(id) {
            trails.removeValue(forKey: id)
            wasAlive.removeValue(forKey: id)
        }
    }

    /// Trim to an exact arc length, cutting THROUGH the final segment.
    ///
    /// Same maths as the server's `trimPath`. Dropping whole segments instead makes the tail
    /// quantise: it holds still while the head travels a segment's worth, then jumps back by
    /// a whole segment — a visible twitch on every snake, every frame.
    private static func trim(_ points: inout [CGPoint], maxLength: Double) {
        guard points.count >= 2, maxLength > 0 else { return }

        var total = 0.0
        for i in 0..<(points.count - 1) {
            let seg = hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y)
            if total + seg >= maxLength {
                let t = seg > 1e-9 ? (maxLength - total) / seg : 0
                points[i + 1] = CGPoint(
                    x: points[i].x + (points[i + 1].x - points[i].x) * t,
                    y: points[i].y + (points[i + 1].y - points[i].y) * t)
                points.removeSubrange((i + 2)...)
                return
            }
            total += seg
        }
    }
}

// MARK: - Joystick

/// A fixed-ring virtual joystick.
///
/// The knob follows the finger, clamped inside the ring: past the edge it pins to the rim in
/// that direction rather than escaping. Release springs it back to centre. Output is a
/// normalized vector in [-1, 1] on each axis, relative to the ring radius.
///
/// FIXED RATHER THAN FLOATING, deliberately: a fixed ring gives the thumb a constant physical
/// reference it can find without looking, which is exactly what was missing when steering was
/// "toward my finger relative to screen centre".
private struct VirtualJoystick: View {
    @Binding var vector: CGVector
    let onChange: (CGVector) -> Void

    @State private var knob: CGSize = .zero

    private static let radius: CGFloat = 60
    private static let knobRadius: CGFloat = 26

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 2))
                .frame(width: Self.radius * 2, height: Self.radius * 2)

            Circle()
                .fill(.white.opacity(0.85))
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                .frame(width: Self.knobRadius * 2, height: Self.knobRadius * 2)
                .offset(knob)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        // A hit area larger than the ring: a thumb reaching for a joystick lands near it as
        // often as on it, and requiring a precise hit is what makes an on-screen stick feel
        // unresponsive.
        .frame(width: Self.radius * 2.8, height: Self.radius * 2.8)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // The gesture is measured from the ring's own centre because the view is
                    // centred on it, so `translation` alone would ignore where the touch
                    // started within the hit area.
                    let dx = value.location.x - Self.radius * 1.4
                    let dy = value.location.y - Self.radius * 1.4
                    let dist = hypot(dx, dy)

                    // Clamp to the rim: normalize and scale by R when the finger goes past it.
                    let clamped = dist > Self.radius
                        ? CGSize(width: dx / dist * Self.radius, height: dy / dist * Self.radius)
                        : CGSize(width: dx, height: dy)

                    knob = clamped
                    let v = CGVector(dx: clamped.width / Self.radius,
                                     dy: clamped.height / Self.radius)
                    vector = v
                    onChange(v)
                }
                .onEnded { _ in
                    // Springs home like a rubber band. No steer is sent on release: the snake
                    // keeps its heading, which matches the server model and the genre.
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        knob = .zero
                    }
                    vector = .zero
                }
        )
    }
}
