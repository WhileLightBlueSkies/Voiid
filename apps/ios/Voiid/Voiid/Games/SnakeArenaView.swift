//
//  SnakeArenaView.swift
//  Voiid
//
//  Snake — the first CONTINUOUS game screen (docs/GAMES.md §70, §80).
//
//  THIS FILE IS NOW A SHELL. The arena is drawn by `SnakeMetalView`, which owns its own
//  display link and all of its mutable state. Everything here is chrome: the leaderboard,
//  the clock, the joystick, the boost pedal.
//
//  THAT SPLIT IS THE POINT, not a stylistic preference. The previous version drew with a
//  SwiftUI `Canvas` and mutated its body-trail store from inside the draw closure, while
//  `@Published` frames arriving re-entered the same view — SwiftUI's render pass must be a
//  pure function of state, and it froze. A continuous renderer owns motion between frames,
//  so it cannot live inside that render pass at all.
//
//  Everything drawn is still server truth interpolated slightly into the past. Nothing here
//  predicts — the client remains a renderer, not a referee.
//
//  Mirrors Android `SnakeArenaScreen.kt`.
//

import SwiftUI

struct SnakeArenaView: View {
    let matchId: String
    let onClose: () -> Void

    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = GamesEngine.shared
    @StateObject private var hud = SnakeHudModel()

    @State private var boosting = false
    /// Live joystick vector, normalized to the ring radius. `.zero` at rest.
    @State private var stick: CGVector = .zero
    /// Last heading committed, so releasing boost cannot also change direction.
    @State private var lastHeading: Double = 0

    private var me: String? { TokenStore.shared.userId }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SnakeMetalView(engine: engine, me: me, hud: hud, stick: $stick)
                .ignoresSafeArea()

            // The chrome deliberately does NOT ignore the safe area, unlike the arena behind
            // it. The arena should bleed to the edges; the controls must not — the boost
            // pedal was rendering under the home indicator, where the system swallows the
            // touch, so the button was visible but unpressable at the bottom of the screen.
            overlay
                .safeAreaPadding(.bottom)
        }
        .navigationBarBackButtonHidden(true)
        // The tab bar is app chrome and this is a full-screen game — every other game view
        // hides it the same way. Without this it sat over the arena and ate touches along
        // the bottom edge.
        .onAppear { session.hideTabBar = true }
        .task { await engine.open(matchId: matchId) }
        // Flush pending steering on its own clock. A send is a side effect and must not ride
        // inside a draw pass.
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

    // MARK: - Chrome

    private var overlay: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Button {
                        session.hideTabBar = false
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer()

                    leaderboard
                }
                Spacer()
            }
            .padding(14)

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VirtualJoystick(vector: $stick) { vector in
                        // Deadzone: below this the thumb is resting, not steering, and atan2
                        // on a near-zero vector is meaningless noise.
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
            .padding(.bottom, 18)
        }
    }

    /// Top ten, live. Rank is the whole point of the board, so it is shown explicitly rather
    /// than implied by row order.
    private var leaderboard: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(hud.timeRemaining)
                .font(.system(size: 13, weight: .heavy).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, 3)

            ForEach(hud.board) { row in
                HStack(spacing: 6) {
                    Text("#\(row.rank)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 20, alignment: .trailing)

                    Circle()
                        .fill(Self.swiftColor(row.colorIndex))
                        .frame(width: 7, height: 7)

                    Text(row.name)
                        .font(.system(size: 11, weight: row.isMe ? .heavy : .semibold))
                        .foregroundStyle(.white.opacity(row.isMe ? 1 : 0.78))
                        .lineLimit(1)

                    Text("\(row.mass)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 170)
    }

    private static func swiftColor(_ index: Int) -> Color {
        let c = SnakeRenderer.palette(index)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
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
struct VirtualJoystick: View {
    @Binding var vector: CGVector
    let onChange: (CGVector) -> Void

    @State private var knob: CGSize = .zero

    private static let radius: CGFloat = 62
    private static let knobRadius: CGFloat = 27

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 2))
                .frame(width: Self.radius * 2, height: Self.radius * 2)

            // A faint centre mark, so the rest position is visible before the thumb lands.
            Circle()
                .fill(.white.opacity(0.10))
                .frame(width: 14, height: 14)

            Circle()
                .fill(.white.opacity(0.9))
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                .frame(width: Self.knobRadius * 2, height: Self.knobRadius * 2)
                .offset(knob)
                .shadow(color: .black.opacity(0.4), radius: 7, y: 2)
        }
        // A hit area larger than the ring: a thumb reaching for a joystick lands near it as
        // often as on it, and requiring a precise hit is what makes an on-screen stick feel
        // unresponsive.
        .frame(width: Self.radius * 2.8, height: Self.radius * 2.8)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Measured from the ring's own centre, because the view is centred on it
                    // and `translation` alone would ignore where inside the hit area the
                    // touch began.
                    let dx = value.location.x - Self.radius * 1.4
                    let dy = value.location.y - Self.radius * 1.4
                    let dist = hypot(dx, dy)

                    // Clamp to the rim: normalize and scale by R past the edge.
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
                    // keeps its heading, matching the server model and the genre.
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        knob = .zero
                    }
                    vector = .zero
                }
        )
    }
}

// MARK: - Trail store

/// Per-snake body polylines, rebuilt on the client from interpolated head motion.
///
/// WHY NOT JUST DRAW THE SERVER'S PATH: the server prepends a head point every tick and
/// decimates the tail of long snakes, so the same array index is a different piece of snake
/// from one frame to the next. Interpolating those against each other made the whole body
/// crawl and twitch.
///
/// A trail is appended at RENDER rate from the smoothly interpolated head, so the body is
/// built out of 60 fps of motion. The server's path only seeds a new snake, re-seeds after a
/// respawn, and re-syncs if the two drift apart.
///
/// Owned by the Metal renderer, never by SwiftUI state — see the note at the top of this file.
final class TrailStore {
    private var trails: [String: [CGPoint]] = [:]
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
                trails[snake.id] = snake.path.isEmpty ? [head] : snake.path
                continue
            }

            // Re-sync if the local trail has drifted from where the server says the head is.
            if let first = trail.first,
               hypot(head.x - first.x, head.y - first.y) > Self.resyncDistance {
                trails[snake.id] = snake.path.isEmpty ? [head] : snake.path
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
