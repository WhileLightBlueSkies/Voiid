//
//  SnakeArenaView.swift
//  Voiid
//
//  Snake — the first CONTINUOUS game screen (docs/GAMES.md §70, §80).
//
//  WHY THIS ONE IS DIFFERENT FROM EVERY OTHER GAME VIEW HERE. Tic Tac Toe, RPS and cricket
//  redraw when a frame lands and are done: their state changes a few times a minute. Snake's
//  server ticks 10 times a second, so drawing frames on arrival would show visible 10 fps
//  stepping. This view therefore runs its own 60 fps clock (TimelineView) and INTERPOLATES
//  between the last two server frames.
//
//  That is interpolation, not prediction. It only ever draws positions the server has already
//  confirmed, rendered ~100 ms in the past. It cannot invent a position, so the
//  "client is a renderer, not a referee" rule in GamesEngine.swift still holds exactly.
//
//  Everything visible is server truth: where snakes are, who died, who ate. The finger only
//  produces a heading, which is sent as `game_input` and may be ignored.
//
//  Mirrors Android `SnakeArenaScreen.kt`.
//

import SwiftUI

struct SnakeArenaView: View {
    let matchId: String
    let onClose: () -> Void

    @ObservedObject private var engine = GamesEngine.shared
    @Environment(\.colorScheme) private var scheme

    @State private var boosting = false

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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // TimelineView(.animation) drives a redraw every display frame, which is what
                // turns 10 Hz of server truth into 60 fps of motion.
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(context: context, size: size, now: timeline.date)
                        // A finger held still stops producing drag callbacks, so the last
                        // heading it chose could otherwise sit unsent until it moved again.
                        engine.flushSteering()
                    }
                    .ignoresSafeArea()
                }

                controlsOverlay(geo: geo)
            }
            .background(Color.black)
            .contentShape(Rectangle())
            .gesture(steerGesture(in: geo.size))
        }
        .navigationBarBackButtonHidden(true)
        .task { await engine.open(matchId: matchId) }
        .onDisappear { engine.leave() }
    }

    // MARK: - Drawing

    /// Interpolation factor between the previous and current server frames.
    ///
    /// Deliberately clamped to 1: if a frame is late, the snake HOLDS at the last known
    /// position rather than extrapolating past it. Extrapolating looks smoother right up to
    /// the moment the real frame arrives somewhere else, and then the snake snaps — which
    /// reads as a much worse glitch than a brief pause.
    private func alpha(now: Date) -> Double {
        let elapsed = CACurrentMediaTime() - engine.snakeFrameAt
        return min(max(elapsed / (1.0 / 10.0), 0), 1)
    }

    private func draw(context: GraphicsContext, size: CGSize, now: Date) {
        guard let state = engine.snake else { return }
        let t = alpha(now: now)
        let previous = engine.snakePrevious

        // Camera follows the local player's head, or the arena centre while dead/spectating.
        let mySnake = state.snakes.first { $0.id == me }
        let prevMine = previous?.snakes.first { $0.id == me }
        let focus = interpolate(
            from: prevMine.map { CGPoint(x: $0.x, y: $0.y) },
            to: mySnake.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero,
            t: t)

        // Zoom so a growing snake stays framed, easing out so growth is not nauseating.
        let mass = mySnake?.mass ?? 10
        let zoom = 1.0 / (1.0 + log10(1 + mass / 30) * 0.42)
        let scale = (min(size.width, size.height) / 900.0) * zoom

        var ctx = context
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -focus.x, y: -focus.y)

        drawArena(ctx: &ctx, radius: state.arenaRadius)
        drawFood(ctx: &ctx, state: state)

        // Other snakes first, the local player last, so the player's own body is never
        // buried under someone else's in a scrum.
        for snake in state.snakes where snake.alive && snake.id != me {
            drawSnake(ctx: &ctx, snake: snake, previous: previous, t: t, isMe: false, time: state.time)
        }
        if let mine = mySnake, mine.alive {
            drawSnake(ctx: &ctx, snake: mine, previous: previous, t: t, isMe: true, time: state.time)
        }
    }

    private func interpolate(from: CGPoint?, to: CGPoint, t: Double) -> CGPoint {
        guard let from else { return to }
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    private func drawArena(ctx: inout GraphicsContext, radius: Double) {
        let rect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)

        // Interior wash, so "inside" reads as a place rather than as empty black.
        ctx.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.07, green: 0.06, blue: 0.16),
                    Color(red: 0.02, green: 0.02, blue: 0.05),
                ]),
                center: .zero, startRadius: 0, endRadius: radius))

        // The boundary is drawn EXACTLY at the lethal line, not inside or outside it. A wall
        // whose visible edge disagrees with the killing surface makes every border death feel
        // unfair, and players cannot learn a boundary they cannot see precisely.
        ctx.stroke(Path(ellipseIn: rect), with: .color(Color(red: 0.35, green: 0.85, blue: 1.0)),
                   lineWidth: 6)
        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 22, dy: 22)),
                   with: .color(Color(red: 0.35, green: 0.85, blue: 1.0).opacity(0.16)),
                   lineWidth: 40)
    }

    private func drawFood(ctx: inout GraphicsContext, state: SnakeState) {
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
        previous: SnakeState?,
        t: Double,
        isMe: Bool,
        time: Double
    ) {
        guard snake.path.count >= 2 else { return }

        let prev = previous?.snakes.first { $0.id == snake.id }
        let color = Self.color(snake.colorIndex)

        // Body width grows sub-linearly with mass: linear growth would have a long snake
        // filling the screen, and length is meant to dominate by covering space, not by
        // being fat.
        let width = 20.0 * (1 + log10(1 + snake.mass / 25) * 0.55)

        // Interpolate the body point-by-point against the previous frame. Points are matched
        // by index, which is correct here because a path only ever grows or shifts by a point
        // per tick, so index i is very nearly the same piece of snake between frames.
        var points: [CGPoint] = []
        points.reserveCapacity(snake.path.count)
        for (i, point) in snake.path.enumerated() {
            if let prev, i < prev.path.count {
                points.append(interpolate(from: prev.path[i], to: point, t: t))
            } else {
                points.append(point)
            }
        }

        var path = Path()
        path.move(to: points[0])
        // Quadratic smoothing through midpoints: the server sends a decimated polyline, and
        // drawing it as straight segments would show every corner.
        if points.count > 2 {
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
        let invulnerable = time < snake.invulnUntil
        let bodyOpacity = invulnerable ? 0.55 : 1.0

        ctx.stroke(path, with: .color(color.opacity(0.22 * bodyOpacity)),
                   style: StrokeStyle(lineWidth: width * 2.1, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: .color(color.opacity(bodyOpacity)),
                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))

        if isMe {
            // The local player's snake carries a rim no one else has. In a crowded arena hue
            // alone is not enough to find yourself quickly.
            ctx.stroke(path, with: .color(.white.opacity(0.85 * bodyOpacity)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }

        if snake.boosting {
            ctx.stroke(path, with: .color(.white.opacity(0.35)),
                       style: StrokeStyle(lineWidth: width * 0.45, lineCap: .round, lineJoin: .round))
        }

        drawHead(ctx: &ctx, at: points[0], snake: snake, prev: prev, t: t,
                 width: width, color: color, opacity: bodyOpacity)
    }

    private func drawHead(
        ctx: inout GraphicsContext,
        at head: CGPoint,
        snake: SnakeState.Snake,
        prev: SnakeState.Snake?,
        t: Double,
        width: Double,
        color: Color,
        opacity: Double
    ) {
        let r = width * 0.62
        let rect = CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)

        ctx.fill(Path(ellipseIn: rect.insetBy(dx: -r * 1.4, dy: -r * 1.4)),
                 with: .color(color.opacity(0.28 * opacity)))
        ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))

        // Eyes, rotated to the interpolated heading. Angles are interpolated on the SHORT arc
        // so a snake crossing the -pi/pi wrap does not spin its eyes the long way round.
        var heading = snake.heading
        if let prev {
            var delta = snake.heading - prev.heading
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            heading = prev.heading + delta * t
        }

        let eyeR = r * 0.3
        for side in [-1.0, 1.0] {
            let ex = head.x + cos(heading) * r * 0.35 - sin(heading) * side * r * 0.42
            let ey = head.y + sin(heading) * r * 0.35 + cos(heading) * side * r * 0.42
            ctx.fill(
                Path(ellipseIn: CGRect(x: ex - eyeR, y: ey - eyeR, width: eyeR * 2, height: eyeR * 2)),
                with: .color(.white.opacity(opacity)))
            let pr = eyeR * 0.52
            let px = ex + cos(heading) * eyeR * 0.4
            let py = ey + sin(heading) * eyeR * 0.4
            ctx.fill(
                Path(ellipseIn: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2)),
                with: .color(.black.opacity(opacity)))
        }
    }

    // MARK: - Input

    /// Steering: the snake turns toward wherever the finger is, relative to screen centre.
    ///
    /// Absolute-direction rather than a virtual joystick, because the snake's head is always
    /// at the centre of the view — so "point at where I want to go" is the most direct mapping
    /// available and needs no on-screen stick to aim.
    private func steerGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.location.x - size.width / 2
                let dy = value.location.y - size.height / 2
                guard dx * dx + dy * dy > 64 else { return }
                let heading = atan2(dy, dx)
                lastHeading = heading
                engine.steer(heading: heading, boost: boosting)
            }
            .onEnded { _ in
                // Releasing does NOT stop the snake — it keeps its heading, which is the
                // genre's expectation. Only boost is released.
                if boosting {
                    boosting = false
                    engine.steer(heading: lastHeading, boost: false)
                }
            }
    }

    /// Last heading actually sent, so releasing boost does not also change direction.
    @State private var lastHeading: Double = 0

    private func controlsOverlay(geo: GeometryProxy) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(action: onClose) {
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
                HStack {
                    Spacer()
                    boostButton
                }
            }
            .padding(24)
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
