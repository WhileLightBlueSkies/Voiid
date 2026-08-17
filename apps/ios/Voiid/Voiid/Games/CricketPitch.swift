//
//  CricketPitch.swift
//  Voiid
//
//  The pitch: a styled ground that animates what a ball did (docs/GAMES_HAND_CRICKET.md §5).
//
//  WHY TRANSFORMS AND NOT SceneKit. The depth comes from layered gradients, shadows, scale and
//  rotation — the same trick the game cards use. A real 3D engine would be a new dependency and a
//  new build surface for two seconds of motion per ball, and would still need art to look like
//  anything.
//
//  EVERY SCORING SHOT SWINGS THE BAT, and the motion is what separates them: a single is a short
//  push into the infield, a six is a full arc over the rope. An earlier version animated only 4s
//  and 6s on the theory that restraint made the big hits land — in practice it made most balls feel
//  dead, so the distinction now lives in the SCALE of the motion (distance, arc height, trail,
//  haptic strength) rather than in whether anything moves at all.
//
//  Mirrors Android `CricketPitch.kt`.
//

import SwiftUI

/// What just happened on a ball, in the vocabulary the pitch animates.
///
/// An enum rather than a bag of booleans: exactly one of these is true per ball, and the compiler
/// enforcing that is what stops a "six AND wicket" frame from ever being drawable.
enum BallEvent: Equatable {
    /// A scoring shot, 1-6. Every one gets a bat strike; the MOTION scales with runs.
    case runs(Int)
    /// 0 — bat played, ball goes nowhere.
    case dot
    /// Matched on 0-2: a soft edge into hands.
    case caught
    /// Matched on 3-6: a big swing that missed.
    case bowled

    /// Derive the event from a resolved ball. The single mapping used by BOTH the bot and online
    /// screens, so the two can never drift into animating the same ball differently.
    static func of(runs: Int, wicket: Bool, matchedPick: Int) -> BallEvent {
        if wicket { return CricketBot.wicketIsCatch(matchedPick: matchedPick) ? .caught : .bowled }
        return runs == 0 ? .dot : .runs(runs)
    }

    var banner: String {
        switch self {
        case .runs(let r): return r == 6 ? "SIX!" : r == 4 ? "FOUR!" : "\(r)"
        case .dot:         return "Dot ball"
        case .caught:      return "Caught!"
        case .bowled:      return "Bowled!"
        }
    }

    var isWicket: Bool { self == .caught || self == .bowled }

    /// How far out the ball travels, as a fraction of the frame. Bigger hits go further.
    var reach: CGFloat {
        switch self {
        case .runs(let r):
            switch r {
            case 6: return 0.88
            case 5: return 0.74
            case 4: return 0.80
            case 3: return 0.55
            case 2: return 0.42
            default: return 0.30
            }
        case .dot:    return 0.05
        case .caught: return 0.40
        case .bowled: return 0.74
        }
    }

    /// Arc height. A four stays deliberately FLAT — along the ground, unlike the airborne six.
    var arc: CGFloat {
        switch self {
        case .runs(let r):
            switch r {
            case 6: return 0.66
            case 5: return 0.44
            case 4: return 0.10
            case 3: return 0.26
            case 2: return 0.20
            default: return 0.14
            }
        case .dot:    return 0
        case .caught: return 0.42
        case .bowled: return 0
        }
    }

    /// Bigger hits travel longer, so the ball is in the air proportionally longer.
    var flightDuration: Double {
        switch self {
        case .runs(let r):
            switch r {
            case 6: return 0.90
            case 5: return 0.78
            case 4: return 0.64
            case 3: return 0.54
            case 2: return 0.46
            default: return 0.38
            }
        case .dot:    return 0.28
        case .caught: return 0.52
        case .bowled: return 0.40
        }
    }
}

struct CricketPitch: View {
    let event: BallEvent?
    /// Changes on every resolved ball, so two consecutive sixes replay the motion instead of the
    /// second being swallowed as "same state".
    let ballToken: Int

    /// A match announcement to deliver ON THE PITCH — the innings changing, your role changing.
    ///
    /// IN HERE RATHER THAN OVER THE SCREEN. These first shipped as a card on a dimmed scrim and
    /// looked exactly like what they were: a system alert dropped on top of a game. The pitch is
    /// already the thing the player watches for "what just happened", so the announcement
    /// belongs in that same window — the ground clears, the message is delivered where the ball
    /// would be, and play resumes. Same surface, same place to look, no modal.
    var announcement: CricketAnnouncement?

    @State private var strike: CGFloat = 0
    /// 0...1 through the bowler's run-up and delivery, ahead of the ball's own flight.
    @State private var delivery: CGFloat = 0
    /// A full run-up only on the first ball of an over; after that the bowler is already at the
    /// crease (§4.4). A full run-up before all six balls gets old by the third one.
    @State private var fullRunUp = true
    @State private var flight: CGFloat = 0
    @State private var bannerPop: CGFloat = 0
    @State private var shown: BallEvent?
    /// 0 = pitch as normal, 1 = ground fully cleared for the announcement.
    @State private var clear: CGFloat = 0
    /// 1 = full time remaining, 0 = about to dismiss. Drives the countdown bar.
    @State private var countdown: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                background(w: w, h: h)

                // THE PLAYERS FADE FOR AN ANNOUNCEMENT, THE GROUND STAYS. One group, one
                // opacity — so nothing the pitch happened to be animating can show through the
                // message. The grass itself is deliberately left up: this is a message ON the
                // pitch, not a panel replacing it.
                Group {
                    // Stumps. Knocked over on a bowled.
                    Capsule()
                        .fill(Color(red: 0.96, green: 0.92, blue: 0.82))
                        .frame(width: 7, height: 48)
                        .rotationEffect(.degrees(shown == .bowled ? 68 * Double(flight) : 0),
                                        anchor: .bottom)
                        .position(x: w * 0.11, y: h * 0.52)

                    // THE BATTER, RIGGED (§4). Seven bones driven by the shot table in
                    // CricketFigures, which is itself driven by the SAME reach/arc/duration
                    // tables the ball uses — so a six's pose and a six's flight cannot disagree.
                    Canvas { ctx, size in
                        drawBatter(ctx: ctx, size: size)
                    }
                    .frame(width: w, height: h)

                    // THE BOWLER, which did not exist at all. The ball used to appear at
                    // x = 0.86 with nothing to have bowled it.
                    Canvas { ctx, size in
                        drawBowler(ctx: ctx, size: size)
                    }
                    .frame(width: w, height: h)

                    trail(w: w, h: h)
                    ball(w: w, h: h)
                    fielder(w: w, h: h)
                    banner()
                        .frame(width: w, height: h, alignment: .center)
                }
                .opacity(1 - Double(clear))

                announcementText()
                    .frame(width: w, height: h, alignment: .center)
                    .opacity(Double(clear))
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg))
        }
        .frame(height: 210)
        .onChange(of: ballToken) { _, _ in play() }
        .onChange(of: announcement) { _, a in
            withAnimation(.easeInOut(duration: 0.3)) { clear = a == nil ? 0 : 1 }
            guard let a else { return }
            // Reset instantly, then drain linearly over the announcement's own lifetime — so
            // the bar can never disagree with when the message actually leaves.
            withAnimation(.none) { countdown = 1 }
            withAnimation(.linear(duration: a.duration)) { countdown = 0 }
        }
        .onAppear { clear = announcement == nil ? 0 : 1 }
    }

    /// The announcement, drawn on the cleared ground.
    ///
    /// Plain type on the grass — no card, no panel, no scrim. A container here would put a
    /// rectangle inside a rectangle and undo the whole point of moving this into the pitch.
    @ViewBuilder
    private func announcementText() -> some View {
        if let a = announcement {
            VStack(spacing: 6) {
                Text(a.title)
                    .font(.system(size: 25, weight: .black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    // The ground is a mid-green gradient and the text sits directly on it, so
                    // it needs its own separation rather than borrowing a panel's.
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)

                Text(a.detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)

                // HOW LONG IS LEFT. A message that vanishes with no warning reads as a glitch —
                // the player is mid-sentence and the screen changes under them. A bar draining
                // to empty says "this is going, and here is how long you have", which turns a
                // disappearance into an expected end.
                //
                // A thin line rather than a ring or a number: it has to be legible in peripheral
                // vision while the eye is on the words, and a countdown you have to READ defeats
                // the purpose of a countdown.
                GeometryReader { bar in
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: bar.size.width * countdown, height: 3)
                }
                .frame(width: 132, height: 3)
                .background(Capsule().fill(.white.opacity(0.22)).frame(height: 3))
                .padding(.top, VoiidSpacing.sm)
            }
            .padding(.horizontal, VoiidSpacing.lg)
            // Rises slightly as it arrives, the way the score banner does — same surface, so
            // the same motion language.
            .offset(y: (1 - clear) * 10)
        }
    }

    // MARK: - Figures

    private func drawBatter(ctx: GraphicsContext, size: CGSize) {
        guard let e = shown else { return }
        let pose = CricketFigures.pose(for: e, t: Double(strike))
        let scale = size.height * 0.30
        // Feet on the batting crease, which is where the old rectangles stood.
        let feet = CGPoint(x: size.width * (0.175 + pose.stride * 0.35), y: size.height * 0.62)
        drawFigure(ctx: ctx, pose: pose, feet: feet, scale: scale, kit: CricketFigures.kit)
    }

    /// One side-on figure: legs, torso, head, arms and bat, drawn as tapered capsules.
    private func drawFigure(
        ctx: GraphicsContext, pose: CricketFigures.BatterPose,
        feet: CGPoint, scale: CGFloat, kit: Color
    ) {
        func limb(_ from: CGPoint, _ angle: Double, _ length: CGFloat,
                  _ width: CGFloat, _ colour: Color) -> CGPoint {
            let rad = (angle - 90) * .pi / 180
            let to = CGPoint(x: from.x + CGFloat(cos(rad)) * length,
                             y: from.y + CGFloat(sin(rad)) * length)
            var seg = Path()
            seg.move(to: from)
            seg.addLine(to: to)
            ctx.stroke(seg, with: .color(CricketFigures.ink),
                       style: StrokeStyle(lineWidth: width + 2.2, lineCap: .round))
            ctx.stroke(seg, with: .color(colour),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
            return to
        }

        // Legs first — they sit behind the torso.
        _ = limb(feet, 180 + pose.backLeg, scale * 0.34, scale * 0.13, kit)
        let hip = CGPoint(x: feet.x, y: feet.y - scale * 0.34)
        _ = limb(feet, 180 - pose.frontLeg, scale * 0.34, scale * 0.13, kit)

        // Torso and head.
        let shoulder = limb(hip, pose.torso, scale * 0.40, scale * 0.19, kit)
        let headR = scale * 0.11
        ctx.fill(
            Path(ellipseIn: CGRect(x: shoulder.x - headR, y: shoulder.y - headR * 2.1,
                                   width: headR * 2, height: headR * 2)),
            with: .color(CricketFigures.ink))
        ctx.fill(
            Path(ellipseIn: CGRect(x: shoulder.x - headR * 0.82,
                                   y: shoulder.y - headR * 2.0,
                                   width: headR * 1.64, height: headR * 1.64)),
            with: .color(CricketFigures.skin))

        // Arms, then the bat from the hands. The bat is what the eye tracks, so it is drawn last
        // and widest.
        let hands = limb(shoulder, 150 + pose.frontArm, scale * 0.30, scale * 0.10,
                         CricketFigures.skin)
        _ = limb(shoulder, 160 + pose.backArm, scale * 0.28, scale * 0.10, CricketFigures.skin)

        let batRad = (pose.bat - 90) * .pi / 180
        let batTip = CGPoint(x: hands.x + CGFloat(cos(batRad)) * scale * 0.52,
                             y: hands.y + CGFloat(sin(batRad)) * scale * 0.52)
        var bat = Path()
        bat.move(to: hands)
        bat.addLine(to: batTip)
        ctx.stroke(bat, with: .color(CricketFigures.ink),
                   style: StrokeStyle(lineWidth: scale * 0.15, lineCap: .round))
        ctx.stroke(bat, with: .linearGradient(
            Gradient(colors: [CricketFigures.batFace, CricketFigures.batEdge]),
            startPoint: hands, endPoint: batTip),
            style: StrokeStyle(lineWidth: scale * 0.11, lineCap: .round))
    }

    /// The bowler: a figure running in with a rotating arm. Off-frame until a ball begins.
    private func drawBowler(ctx: GraphicsContext, size: CGSize) {
        guard shown != nil, delivery > 0 else { return }
        let t = Double(delivery)
        let scale = size.height * 0.28
        let x = size.width * CGFloat(CricketFigures.bowlerRun(t, full: fullRunUp))
        let feet = CGPoint(x: x, y: size.height * 0.60)

        // Legs stride as they run — a two-phase alternation, enough at this size.
        let phase = sin(t * 18) * 14
        var pose = CricketFigures.BatterPose()
        pose.frontLeg = phase
        pose.backLeg = -phase
        pose.torso = -6
        // The arm carries the ball over the top and releases at the apex.
        pose.frontArm = CricketFigures.bowlerArm(t) - 150
        pose.backArm = CricketFigures.bowlerArm(t) - 330
        // No bat: the bowler's "bat" bone is collapsed to nothing.
        pose.bat = 0

        drawBowlerFigure(ctx: ctx, pose: pose, feet: feet, scale: scale)
    }

    /// Same limb construction as the batter, minus the bat.
    private func drawBowlerFigure(
        ctx: GraphicsContext, pose: CricketFigures.BatterPose,
        feet: CGPoint, scale: CGFloat
    ) {
        func limb(_ from: CGPoint, _ angle: Double, _ length: CGFloat,
                  _ width: CGFloat, _ colour: Color) -> CGPoint {
            let rad = (angle - 90) * .pi / 180
            let to = CGPoint(x: from.x + CGFloat(cos(rad)) * length,
                             y: from.y + CGFloat(sin(rad)) * length)
            var seg = Path()
            seg.move(to: from)
            seg.addLine(to: to)
            ctx.stroke(seg, with: .color(CricketFigures.ink),
                       style: StrokeStyle(lineWidth: width + 2.0, lineCap: .round))
            ctx.stroke(seg, with: .color(colour),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
            return to
        }

        _ = limb(feet, 180 + pose.backLeg, scale * 0.34, scale * 0.12, CricketFigures.bowlerKit)
        let hip = CGPoint(x: feet.x, y: feet.y - scale * 0.34)
        _ = limb(feet, 180 - pose.frontLeg, scale * 0.34, scale * 0.12, CricketFigures.bowlerKit)

        let shoulder = limb(hip, pose.torso, scale * 0.38, scale * 0.18, CricketFigures.bowlerKit)
        let headR = scale * 0.10
        ctx.fill(
            Path(ellipseIn: CGRect(x: shoulder.x - headR, y: shoulder.y - headR * 2.0,
                                   width: headR * 2, height: headR * 2)),
            with: .color(CricketFigures.skin))

        _ = limb(shoulder, pose.frontArm, scale * 0.32, scale * 0.09, CricketFigures.skin)
        _ = limb(shoulder, pose.backArm, scale * 0.30, scale * 0.09, CricketFigures.skin)
    }

    // MARK: - Motion

    private func play() {
        guard let e = event else { return }
        shown = e
        strike = 0
        flight = 0
        bannerPop = 0

        // THE BOWLER RUNS IN FIRST. Release is at the top of the arm's arc, and the ball's own
        // flight starts from there — so the ball is seen to be bowled rather than to appear.
        delivery = 0
        let runUp = fullRunUp ? 0.50 : 0.26
        withAnimation(.easeIn(duration: runUp)) { delivery = 1 }

        // Bat first, ball after contact — in that order, or the ball appears to move before it
        // was hit.
        //
        // A BOWLED SWINGS TOO, and that is a change. The old code skipped the swing entirely on
        // a bowled, so a player watched their batter stand perfectly still while the stumps fell
        // over. A batter who is bowled DID play a shot; the miss is the drama (§4.3).
        withAnimation(.easeOut(duration: 0.17).delay(runUp * 0.7)) { strike = 1 }

        // Haptics graded by how big the event is: a mini tick for small runs, a light knock for a
        // four, a rising thump for a six. A wicket gets its own signature so it never feels like
        // a reward.
        switch e {
        case .runs(let r) where r >= 6: Haptics.boundary()
        case .runs(let r) where r == 4: Haptics.soft()
        case .runs:                     Haptics.tap()
        case .dot:                      Haptics.tap()
        case .caught, .bowled:          Haptics.rigid()
        }

        // Delayed past the bowler's release, so the ball leaves a hand rather than a coordinate.
        let release = runUp * CricketFigures.releaseAt
        withAnimation(.linear(duration: e.flightDuration)
            .delay(release + (e == .bowled ? 0 : 0.12))) {
            flight = 1
        }
        // After the first ball the bowler is already at the crease. A full run-up before all six
        // balls of an over gets old by the third (§4.4).
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55).delay(release + 0.1)) {
            bannerPop = 1
        }

        // After the first ball the bowler is already at the crease. A full run-up before all six
        // balls of an over gets old by the third (§4.4).
        //
        // SET LAST, deliberately: `runUp` and `release` above are THIS ball's timings, and
        // flipping the flag before they are read would give this ball the next one's pacing.
        fullRunUp = false
    }

    /// Where the ball is at progress `p`.
    ///
    /// ONE FUNCTION FOR BALL AND TRAIL, deliberately: the trail is the same path sampled slightly
    /// in the past, so computing them separately could let the echoes drift off the ball.
    private func ballPosition(_ e: BallEvent, _ p: CGFloat, w: CGFloat, h: CGFloat) -> CGPoint {
        if e == .bowled {
            // Comes from the bowler's end INTO the stumps.
            let travel: CGFloat = 0.86 - (0.74 * p)
            return CGPoint(x: w * travel, y: h * 0.50)
        }
        let x = w * (CGFloat(0.24) + e.reach * p)
        let lift = -(h * e.arc) * (4 * p * (1 - p))
        let baseY: CGFloat = (e == .dot) ? 0.58 : (e == .caught ? 0.44 : 0.46)
        return CGPoint(x: x, y: h * baseY + lift)
    }

    // MARK: - Layers

    private func background(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Sky over outfield over pitch — three bands, so the strip reads as ground receding
            // rather than a flat green rectangle.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.07, green: 0.24, blue: 0.42), location: 0),
                    .init(color: Color(red: 0.09, green: 0.32, blue: 0.18), location: 0.30),
                    .init(color: Color(red: 0.14, green: 0.50, blue: 0.29), location: 0.62),
                    .init(color: Color(red: 0.08, green: 0.28, blue: 0.16), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)

            // Crowd band along the skyline. Cheap, but it stops the top reading as empty sky.
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.18, blue: 0.32),
                         Color(red: 0.08, green: 0.25, blue: 0.43),
                         Color(red: 0.05, green: 0.18, blue: 0.32)],
                startPoint: .leading, endPoint: .trailing)
                .frame(height: h * 0.16)

            // The pitch strip.
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.79, green: 0.66, blue: 0.48).opacity(0.55))
                .frame(width: w * 0.72, height: h * 0.26)
                .position(x: w * 0.42, y: h * 0.60)

            // Boundary rope — the thing a shot travels toward, so motion has a target.
            Capsule()
                .fill(Color.white.opacity(0.40))
                .frame(width: 4, height: h * 0.62)
                .position(x: w * 0.97, y: h * 0.50)
        }
    }

    @ViewBuilder
    private func ball(w: CGFloat, h: CGFloat) -> some View {
        if let e = shown {
            let pos = ballPosition(e, flight, w: w, h: h)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 1.0, green: 0.54, blue: 0.42),
                             Color(red: 0.78, green: 0.16, blue: 0.16)],
                    center: .topLeading, startRadius: 1, endRadius: 16))
                .frame(width: 15, height: 15)
                .position(pos)
        }
    }

    /// Motion trail — fading echoes behind the ball. Sells speed on the big hits and is invisible
    /// on a push, because it scales with the same distance the ball travels.
    @ViewBuilder
    private func trail(w: CGFloat, h: CGFloat) -> some View {
        if case .runs(let r) = shown, r >= 3 {
            let count = r >= 6 ? 4 : 2
            ForEach(0..<count, id: \.self) { i in
                let lag = CGFloat(i + 1) * 0.07
                let tp = max(0, flight - lag)
                let pos = ballPosition(.runs(r), tp, w: w, h: h)
                Circle()
                    .fill(Color(red: 1.0, green: 0.48, blue: 0.36))
                    .opacity(0.28 * (1 - Double(i) / Double(count)))
                    .frame(width: CGFloat(13 - i * 2), height: CGFloat(13 - i * 2))
                    .position(pos)
            }
        }
    }

    /// A fielder's hands where a catch ends, so "Caught" has something to be caught by.
    @ViewBuilder
    private func fielder(w: CGFloat, h: CGFloat) -> some View {
        if shown == .caught {
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .scaleEffect(0.75 + 0.45 * flight)
                .position(x: w * 0.60, y: h * 0.30)
        }
    }

    @ViewBuilder
    private func banner() -> some View {
        if let e = shown, bannerPop > 0 {
            let big: Bool = {
                if case .runs(let r) = e { return r >= 4 }
                return false
            }()
            Text(e.banner)
                .font(.system(size: big ? 40 : (e.isWicket ? 26 : 22), weight: .black))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: VoiidRadius.md)
                        .fill(e.isWicket
                              ? Color(red: 0.56, green: 0.11, blue: 0.11).opacity(0.85)
                              : Color.black.opacity(0.32)))
                // Overshoots then settles — the pop is what makes a six feel loud.
                .scaleEffect(0.7 + 0.45 * bannerPop)
                .opacity(Double(min(1, bannerPop)))
        }
    }
}
