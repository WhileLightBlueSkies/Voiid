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
    /// Start a fresh practice match. Nil hides the Restart action.
    var onRestart: (() -> Void)? = nil

    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = GamesEngine.shared
    @StateObject private var hud = SnakeHudModel()

    @State private var boosting = false
    /// Read once when the arena opens. A scheme that changed mid-match would move the controls
    /// out from under a thumb that is already steering.
    @State private var scheme: SnakeChoiceStore.ControlScheme = SnakeChoiceStore.controlScheme
    /// Live joystick vector, normalized to the ring radius. `.zero` at rest.
    @State private var stick: CGVector = .zero
    /// Last heading committed, so releasing boost cannot also change direction.
    @State private var lastHeading: Double = 0
    /// Whether the finished match set a new personal best.
    @State private var beatBest = false
    /// Set to open the share sheet with a challenge message.
    @State private var shareText: String?
    /// Teaches the game once, on top of a real match. Finishes immediately for a player who
    /// has already been through it, so the wiring below is identical either way.
    @StateObject private var coach = SnakeCoach(enabled: true)

    private var me: String? { TokenStore.shared.userId }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SnakeMetalView(engine: engine, me: me, hud: hud, stick: $stick, boosting: boosting)

            // SPEED LINES while boost is actually taking effect.
            //
            // The arena camera stays locked to the head, so a snake at 510 u/s looks almost
            // exactly like a snake at 300 — everything moves together and there is no fixed
            // reference to read speed against. Streaks at the edge of the frame supply that
            // reference, which is why every racing game has them.
            //
            // DRIVEN BY `hud.boostActive`, NOT the button: below the boost floor the engine
            // ignores the input, and drawing speed lines for a boost that is not happening
            // would be the client lying about the game state.
            SpeedLines(active: hud.boostActive)
                .allowsHitTesting(false)

                .ignoresSafeArea()

            // SWIPE STEERING, when chosen. A drag anywhere on the arena steers toward the
            // direction of the drag — no fixed ring, so the whole screen is the control and
            // the bottom-left corner (the hardest place for a thumb on a large phone) is free.
            //
            // The vector is the drag TRANSLATION, normalised: direction is what matters, and
            // treating distance as magnitude would make a long drag steer harder than a short
            // one in the same direction, which is not how steering works.
            if scheme == .swipe {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let t = g.translation
                                let len = hypot(t.width, t.height)
                                guard len > 6 else { return }
                                steer(CGVector(dx: t.width / len, dy: t.height / len))
                            }
                            // NOT released on end. A joystick springs back because the thumb
                            // physically leaves it; a swipe is a direction you set and the
                            // snake keeps. Releasing here would stop the snake dead every time
                            // the finger lifted.
                    )
            }

            // The chrome deliberately does NOT ignore the safe area, unlike the arena behind
            // it. The arena should bleed to the edges; the controls must not — the boost
            // pedal was rendering under the home indicator, where the system swallows the
            // touch, so the button was visible but unpressable at the bottom of the screen.
            overlay
                .safeAreaPadding(.bottom)

            // Death is not the end of a match here — Largest Snake respawns you — so the
            // notice reports it and gets out of the way, while the END of the match is the
            // one that actually blocks with Restart / Quit.
            if let state = engine.snake {
                let mine = state.snakes.first { $0.id == me }
                if state.finished {
                    gameOverPanel(mass: mine.map { Int($0.mass) })
                        .onAppear {
                            // Record ONCE. onAppear fires when the panel enters, and the
                            // panel only enters on the transition into `finished`.
                            guard let m = mine else { return }
                            beatBest = SnakeRecordStore.record(length: Int(m.mass))
                        }
                } else if let mine, !mine.alive {
                    deathPanel(mass: Int(mine.mass), deaths: mine.deaths,
                               canRespawn: mine.canRespawn)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        // The tab bar is app chrome and this is a full-screen game — every other game view
        // hides it the same way. Without this it sat over the arena and ate touches along
        // the bottom edge.
        .onAppear {
            session.hideTabBar = true
            GameAudio.shared.preload(for: "snake")
        }
        .onChange(of: hud.myMass) { _, _ in
            coach.update(head: hud.myHead, mass: hud.myMass, boostActive: hud.boostActive)
        }
        // Mass is the coarse signal; the head moves on every publish, so it is what actually
        // ticks the coach's timers. Both feed the same call — `update` is idempotent for a
        // step whose condition is not yet met.
        .onChange(of: hud.myHead) { _, _ in
            coach.update(head: hud.myHead, mass: hud.myMass, boostActive: hud.boostActive)
        }
        .task { await engine.open(matchId: matchId) }
        // Flush pending steering on its own clock. A send is a side effect and must not ride
        // inside a draw pass.
        .task {
            while !Task.isCancelled {
                engine.flushSteering()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        .sheet(isPresented: Binding(
            get: { shareText != nil },
            set: { if !$0 { shareText = nil } }
        )) {
            if let shareText {
                ShareSheet(items: [shareText])
            }
        }
        .onDisappear {
            session.hideTabBar = false
            engine.leave()
            GameAudio.shared.release(for: "snake")
        }
    }

    /// Shown when the player is dead.
    ///
    /// BLOCKING, and the player stays dead until they choose. The server used to auto-respawn
    /// humans after 2.5 s, which meant this panel appeared and vanished before it could be
    /// read, and being teleported back into play unprompted felt like the match had restarted
    /// itself. Bots still respawn on a timer; a human decides.
    private func deathPanel(mass: Int, deaths: Int, canRespawn: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()

            VStack(spacing: 0) {
                Text("You died")
                    .font(.system(size: 30, weight: .black))
                Text("Length \(mass)  -  Deaths \(deaths)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 6)

                Button {
                    engine.requestRespawn()
                } label: {
                    Text(canRespawn ? "Respawn" : "Respawning...")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(canRespawn
                            ? Color(red: 0.03, green: 0.02, blue: 0.06)
                            : .white.opacity(0.5))
                        .padding(.horizontal, 42)
                        .padding(.vertical, 14)
                        .background(canRespawn
                            ? Color(red: 0.13, green: 0.88, blue: 0.94)
                            : Color.white.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!canRespawn)
                .padding(.top, 26)

                Button {
                    session.hideTabBar = false
                    onClose()
                } label: {
                    Text("Quit")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 50)
                        .padding(.vertical, 13)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.top, 12)
            }
            .foregroundStyle(.white)
        }
    }

    /// The match itself is over.
    ///
    /// THIS USED TO BE A BESPOKE PANEL — "Match over", a mass, a share button, Restart and
    /// Quit — and it was the BEST end screen in the app; the other five games showed a line of
    /// text (CROSS_CUTTING.md §2). It now goes through the same MatchEndOverlay as everything
    /// else, so a Snake result and a Ludo result are the same screen with different numbers.
    ///
    /// The death panel below is deliberately NOT routed here: dying is not the end of a match
    /// in Largest Snake, you respawn, and giving a respawn the full result treatment would be
    /// the loudest possible lie about what just happened.
    private func gameOverPanel(mass: Int?) -> some View {
        MatchEndOverlay(
            result: snakeResult(mass: mass),
            onPlayAgain: onRestart.map { restart in { restart() } },
            onExit: {
                session.hideTabBar = false
                onClose()
            })
    }

    /// Built from the final frame plus the local record store.
    private func snakeResult(mass: Int?) -> MatchEndResult {
        let length = mass ?? 0
        let mine = engine.snake?.snakes.first { $0.id == me }
        // Rank by mass across the final frame — the same ordering the live rank badge uses.
        let ordered = (engine.snake?.snakes ?? []).sorted { $0.mass > $1.mass }
        let rank = (ordered.firstIndex { $0.id == me }.map { $0 + 1 }) ?? 1
        return .snake(
            length: length,
            kills: mine.map { Int($0.kills) } ?? 0,
            rank: rank,
            of: max(ordered.count, 1),
            best: SnakeRecordStore.best,
            isBest: beatBest)
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

                    VStack(alignment: .trailing, spacing: 8) {
                        leaderboard
                        // UNDER the leaderboard, sharing its column. Both answer "what is
                        // happening to everyone else", and the eye already goes to this corner
                        // for that — a feed on the opposite side would be a second place to
                        // look during the exact seconds a player has none to spare.
                        killFeed
                    }
                }
                // UNDER the top HUD, not over the middle of the board. The middle is where
                // the snake is, and covering the thing you are teaching someone to look at
                // defeats the purpose.
                SnakeCoachBanner(step: coach.step)
                    .padding(.top, VoiidSpacing.sm)
                    .animation(.spring(response: 0.38, dampingFraction: 0.82), value: coach.step)

                Spacer()
            }
            .padding(14)

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    // The joystick is a VIEW; swipe is a gesture on the arena itself (attached
                    // above). Only one is ever mounted, so the two can never fight over the
                    // same touch.
                    if scheme == .joystick {
                        VirtualJoystick(vector: $stick, onChange: steer)
                    } else {
                        // Keeps the boost button in its corner without the joystick's width.
                        Color.clear.frame(width: 1, height: 1)
                    }
                    Spacer()
                    boostButton
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 18)
        }
    }

    /// Recent kills, newest at the top.
    ///
    /// `kill` events were already parsed and rendered as NOTHING textual, so the most dramatic
    /// thing in a match left no trace: you would see a body burst into food with no idea whose
    /// it was or who did it. SNAKE.md §3.2 lists this next to the boost meter for the same
    /// reason — information the game has and does not show.
    private var killFeed: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(hud.killFeed) { entry in
                Text(entry.text)
                    .font(.system(size: 11, weight: entry.mine ? .heavy : .semibold))
                    // Lines involving the player are brighter. In a six-snake match most kills
                    // are somebody else's business, and undifferentiated text means the one
                    // line that IS your business gets skimmed past with the rest.
                    .foregroundStyle(entry.mine
                                     ? Color(red: 0.13, green: 0.88, blue: 0.94)
                                     : .white.opacity(0.62))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.28), in: Capsule())
                    // Arrives from the right, the direction the column is anchored to, so it
                    // slides in from off-screen rather than appearing over the arena.
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: hud.killFeed)
        .allowsHitTesting(false)
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

    /// Turn a stick/drag vector into a heading and send it.
    ///
    /// ONE HANDLER FOR BOTH SCHEMES. Joystick and swipe differ only in how the vector is
    /// produced; the deadzone, the release behaviour and the resend all have to be identical or
    /// the two would feel like different games.
    private func steer(_ vector: CGVector) {
        // A zero vector means the thumb lifted: stop the resend loop rather than steering
        // toward atan2(0, 0).
        guard hypot(vector.dx, vector.dy) >= 0.15 else {
            engine.releaseSteering()
            return
        }
        let heading = atan2(vector.dy, vector.dx)
        lastHeading = heading
        engine.steer(heading: heading, boost: boosting)
    }

    private var boostButton: some View {
        Circle()
            .fill(boosting ? Color.white.opacity(0.3) : Color.white.opacity(0.12))
            .overlay(Circle().stroke(.white.opacity(boosting ? 0.9 : 0.35), lineWidth: 2))
            // THE FUEL RING — how much boost is left, drawn around the button that spends it.
            //
            // Boost costs mass and cuts out below a floor, and neither was visible: you held
            // the button, nothing obvious happened, and later you were shorter for reasons you
            // never saw. SNAKE.md §3.2 calls that "an unfair-feeling mechanic purely because it
            // is invisible".
            //
            // ON THE BUTTON rather than in the corner, because that is where the thumb and the
            // eye already are at the moment it matters. A meter elsewhere is a meter nobody
            // reads mid-fight.
            .overlay(
                Circle()
                    .trim(from: 0, to: hud.boostFuel)
                    .stroke(
                        // Amber as it runs down: the colour change is what carries "about to
                        // cut out" at a glance, without a number to read.
                        hud.boostFuel < 0.25
                            ? Color(red: 1.0, green: 0.55, blue: 0.20)
                            : Color(red: 0.13, green: 0.88, blue: 0.94),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    // Starts at twelve o'clock and runs clockwise, the way every fuel gauge
                    // and cooldown ring in the genre does.
                    .rotationEffect(.degrees(-90))
                    .padding(-5)
                    .animation(.easeOut(duration: 0.2), value: hud.boostFuel))
            .overlay(
                Text("BOOST")
                    .font(.system(size: 10, weight: .black))
                    // Dimmed when boost cannot fire, so the button reads as unavailable rather
                    // than as broken when a small snake holds it and nothing happens.
                    .foregroundStyle(.white.opacity(hud.boostFuel <= 0 ? 0.35 : 0.9)))
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
/// Carries the joystick hit area's measured size out of its own layout.
private struct JoystickSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct VirtualJoystick: View {
    @Binding var vector: CGVector
    let onChange: (CGVector) -> Void

    @State private var knob: CGSize = .zero
    /// The gesture area's real size, measured rather than assumed.
    @State private var hitSize: CGSize = .zero

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
        // MEASURE the hit area rather than assuming it. `location` is reported in the
        // coordinate space of the view the gesture is attached to, and hardcoding the centre
        // as `radius * 1.4` silently assumed that space matched the frame above it. When it
        // did not, every touch was measured from the wrong origin — which is what made the
        // stick feel reversed on iOS while Android (which measures `size.width`) was correct.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: JoystickSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(JoystickSizeKey.self) { hitSize = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Measured from the MEASURED centre of the hit area.
                    let cx = hitSize.width / 2
                    let cy = hitSize.height / 2
                    guard cx > 0, cy > 0 else { return }
                    let dx = value.location.x - cx
                    let dy = value.location.y - cy
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
                trails[snake.id] = Self.seed(from: snake.path, head: head)
                continue
            }

            // Re-sync if the local trail has drifted from where the server says the head is.
            if let first = trail.first,
               hypot(head.x - first.x, head.y - first.y) > Self.resyncDistance {
                trails[snake.id] = Self.seed(from: snake.path, head: head)
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

    /// Build a trail from a server path, RESAMPLED to a fixed fine spacing.
    ///
    /// The server decimates long tails — points near the tail arrive 24+ units apart, far
    /// wider than a colour band. Seeding a trail directly from that made long snakes render
    /// as a solid tube while short ones banded correctly, because the band walk was cutting
    /// several bands inside one straight segment and their round caps merged into each other.
    /// Two snakes with the same skin looked like two different skins.
    ///
    /// Resampling first means band geometry no longer depends on how aggressively the server
    /// compressed that particular snake.
    private static func seed(from path: [CGPoint], head: CGPoint) -> [CGPoint] {
        guard path.count >= 2 else { return [head] }

        var out: [CGPoint] = [path[0]]
        var cursor = path[0]
        var i = 1

        while i < path.count {
            let target = path[i]
            let segLen = hypot(target.x - cursor.x, target.y - cursor.y)
            if segLen < 1e-6 { i += 1; continue }

            if segLen <= resampleStep {
                out.append(target)
                cursor = target
                i += 1
            } else {
                // Walk along this segment in fixed steps rather than jumping to its end.
                let t = resampleStep / segLen
                let next = CGPoint(x: cursor.x + (target.x - cursor.x) * t,
                                   y: cursor.y + (target.y - cursor.y) * t)
                out.append(next)
                cursor = next
            }
        }
        return out
    }

    /// Trail resolution. Must be comfortably FINER than the narrowest band (10 units on the
    /// candy skin), or a band can span an entire segment and the pattern collapses.
    private static let resampleStep: Double = 4

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



/// Radial streaks at the edge of the frame while boosting.
///
/// WHY THE ARENA NEEDS THEM. The camera follows the head, so at boost speed the whole world
/// slides at once and there is nothing stationary to judge speed against — a boosting snake and
/// a cruising one look nearly identical. Streaks anchored to the SCREEN rather than the world
/// give the eye that fixed reference back.
///
/// Deliberately at the edges only. A full-screen effect would sit on top of the arena the player
/// is trying to read, and the one thing worse than not seeing your speed is not seeing the snake
/// about to kill you.
private struct SpeedLines: View {
    let active: Bool

    /// Enough to read as motion, few enough to stay cheap and not crowd the frame.
    private static let count = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ForEach(0..<Self.count, id: \.self) { i in
                    // Spread around a circle, with a fixed per-index jitter so the fan is
                    // irregular rather than a clock face. Derived from the index rather than
                    // random, so streaks do not reshuffle on every state change.
                    let angle = Double(i) / Double(Self.count) * 2 * .pi
                        + Double(i % 5) * 0.09
                    let dx = cos(angle), dy = sin(angle)
                    // Anchored past the middle so the inner end stays clear of the arena's
                    // centre, where the snake and the action are.
                    let inner = min(w, h) * 0.42

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0), .white.opacity(0.55)],
                                startPoint: .leading, endPoint: .trailing))
                        .frame(width: active ? 90 : 0, height: 2.5)
                        .rotationEffect(.radians(angle))
                        .offset(x: dx * inner, y: dy * inner)
                        .position(x: w / 2, y: h / 2)
                }
            }
            // FAST IN, SLOWER OUT. Boost engages instantly and the lines must arrive with it;
            // on release they trail off, which reads as momentum bleeding away rather than as
            // an effect being switched off.
            .animation(
                active ? .easeOut(duration: 0.12) : .easeIn(duration: 0.28),
                value: active)
            .opacity(active ? 1 : 0)
        }
    }
}
