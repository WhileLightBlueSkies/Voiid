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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        drawGroundShadow(ctx: ctx, center: feet, width: scale * 0.72)
        drawFigure(ctx: ctx, pose: pose, feet: feet, scale: scale, kit: CricketFigures.kit)
    }

    private func drawGroundShadow(ctx: GraphicsContext, center: CGPoint, width: CGFloat) {
        let rect = CGRect(x: center.x - width * 0.5, y: center.y - width * 0.07,
                          width: width, height: width * 0.16)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [Color.black.opacity(0.28), Color.black.opacity(0)]),
            center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0, endRadius: width * 0.5))
    }

    /// One side-on figure: legs, torso, head, arms and bat, drawn as tapered capsules.
    ///
    /// JOINTS SHARE COORDINATES, which is what closes the gaps. The previous version drew each
    /// bone from a point it computed independently — the torso fill started at `shoulder.y` while
    /// the hip sat a third of a figure below it, and the arms rooted at a bare `shoulder` point
    /// whose covering ellipse was thinner than the arm strokes themselves. At rest that reads as
    /// one body; at a six's +66° arm and +30° torso the limbs swing clear of the mass they are
    /// supposed to grow out of and the figure comes apart at the neck and shoulder.
    ///
    /// So: the torso is drawn as a QUAD between the actual hip and the actual shoulder (it
    /// leans with the bone instead of staying an upright rectangle), the head rides the torso's
    /// own direction, and every joint gets a cap disc sized to the THICKER of the two bones it
    /// joins. A cap that is smaller than its limb is not a joint, it is a hole.
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

        /// A bone between two KNOWN points, rather than from a point at an angle. The arms need
        /// this because their far end (the grip) is positioned by the shot, not by the arm.
        func bone(_ from: CGPoint, _ to: CGPoint, _ width: CGFloat, _ colour: Color) {
            var seg = Path()
            seg.move(to: from)
            seg.addLine(to: to)
            ctx.stroke(seg, with: .color(CricketFigures.ink),
                       style: StrokeStyle(lineWidth: width + 2.2, lineCap: .round))
            ctx.stroke(seg, with: .color(colour),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
        }

        /// A joint cap: outline disc under a fill disc, at least as wide as the widest bone
        /// meeting here. This is the piece that was missing.
        func joint(_ at: CGPoint, _ width: CGFloat, _ colour: Color) {
            let r = width * 0.5
            ctx.fill(Path(ellipseIn: CGRect(x: at.x - r - 1.1, y: at.y - r - 1.1,
                                            width: width + 2.2, height: width + 2.2)),
                     with: .color(CricketFigures.ink))
            ctx.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r,
                                            width: width, height: width)),
                     with: .color(colour))
        }

        // The skeleton is solved BEFORE anything is drawn, so every part is placed against the
        // same joint positions rather than against its own guess at them.
        let hip = CGPoint(x: feet.x, y: feet.y - scale * 0.34)
        let torsoRad = (pose.torso - 90) * .pi / 180
        let torsoLen = scale * 0.40
        let shoulder = CGPoint(x: hip.x + CGFloat(cos(torsoRad)) * torsoLen,
                               y: hip.y + CGFloat(sin(torsoRad)) * torsoLen)
        // The torso's own axes, so the body and head lean WITH the bone.
        let up = CGVector(dx: (shoulder.x - hip.x) / torsoLen, dy: (shoulder.y - hip.y) / torsoLen)
        let side = CGVector(dx: -up.dy, dy: up.dx)

        // Legs first — they sit behind the torso, and both are rooted at the same hip.
        let legW = scale * 0.13
        let backFoot = limb(hip, 180 + pose.backLeg, scale * 0.34, legW, kit)
        let frontFoot = limb(hip, 180 - pose.frontLeg, scale * 0.34, legW, kit)
        // Shoes at the ACTUAL foot positions. These used to be pinned to `feet`, so a striding
        // front leg left its shoe behind at the crease.
        for f in [backFoot, frontFoot] {
            ctx.fill(Path(ellipseIn: CGRect(x: f.x - scale * 0.14, y: f.y - scale * 0.05,
                                            width: scale * 0.28, height: scale * 0.10)),
                     with: .color(CricketFigures.shoe))
        }
        // Pads over the shins, oriented along each leg rather than as a fixed upright box.
        for (f, ang) in [(backFoot, 180 + pose.backLeg), (frontFoot, 180 - pose.frontLeg)] {
            var pad = Path()
            let r = (ang - 90) * .pi / 180
            pad.move(to: CGPoint(x: f.x - CGFloat(cos(r)) * scale * 0.22,
                                 y: f.y - CGFloat(sin(r)) * scale * 0.22))
            pad.addLine(to: CGPoint(x: f.x - CGFloat(cos(r)) * scale * 0.02,
                                    y: f.y - CGFloat(sin(r)) * scale * 0.02))
            ctx.stroke(pad, with: .color(Color.white.opacity(0.96)),
                       style: StrokeStyle(lineWidth: scale * 0.14, lineCap: .round))
        }
        joint(hip, legW * 1.35, kit)

        // TORSO AS A QUAD between the two real joints, tapering from hip to shoulder. A rectangle
        // pinned to `shoulder.y` (what was here) cannot lean, so any torso rotation tore it open
        // at the hip.
        let hipHalf = scale * 0.15
        let shoulderHalf = scale * 0.19
        var body = Path()
        body.move(to: CGPoint(x: hip.x + side.dx * hipHalf, y: hip.y + side.dy * hipHalf))
        body.addLine(to: CGPoint(x: shoulder.x + side.dx * shoulderHalf,
                                 y: shoulder.y + side.dy * shoulderHalf))
        body.addLine(to: CGPoint(x: shoulder.x - side.dx * shoulderHalf,
                                 y: shoulder.y - side.dy * shoulderHalf))
        body.addLine(to: CGPoint(x: hip.x - side.dx * hipHalf, y: hip.y - side.dy * hipHalf))
        body.closeSubpath()
        ctx.fill(body, with: .color(CricketFigures.ink))
        ctx.stroke(body, with: .color(CricketFigures.ink),
                   style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
        // Inset fill, so the ink reads as an outline rather than a second body.
        var inner = Path()
        let ih = hipHalf - 1.6, ish = shoulderHalf - 1.6
        inner.move(to: CGPoint(x: hip.x + side.dx * ih, y: hip.y + side.dy * ih))
        inner.addLine(to: CGPoint(x: shoulder.x + side.dx * ish, y: shoulder.y + side.dy * ish))
        inner.addLine(to: CGPoint(x: shoulder.x - side.dx * ish, y: shoulder.y - side.dy * ish))
        inner.addLine(to: CGPoint(x: hip.x - side.dx * ih, y: hip.y - side.dy * ih))
        inner.closeSubpath()
        ctx.fill(inner, with: .linearGradient(
            Gradient(colors: [CricketFigures.jersey, CricketFigures.jerseyShadow]),
            startPoint: shoulder, endPoint: hip))

        // Head, riding the torso's own direction so the neck stays closed at any rotation. It
        // used to hang at a fixed offset below `shoulder`, which opened a gap the moment the
        // body turned.
        let headR = scale * 0.11
        let neck = CGPoint(x: shoulder.x + up.dx * headR * 0.35, y: shoulder.y + up.dy * headR * 0.35)
        joint(shoulder, shoulderHalf * 2, CricketFigures.jersey)
        // The neck itself — a short bone, so head and shoulders are never two separate objects.
        var neckPath = Path()
        neckPath.move(to: shoulder)
        neckPath.addLine(to: CGPoint(x: shoulder.x + up.dx * headR * 0.9,
                                     y: shoulder.y + up.dy * headR * 0.9))
        ctx.stroke(neckPath, with: .color(CricketFigures.ink),
                   style: StrokeStyle(lineWidth: scale * 0.11 + 2.2, lineCap: .round))
        ctx.stroke(neckPath, with: .color(CricketFigures.skin),
                   style: StrokeStyle(lineWidth: scale * 0.11, lineCap: .round))

        // The head sits a full radius up the torso axis from the neck, tilted by `head`.
        let headC = CGPoint(x: neck.x + up.dx * headR * 1.55, y: neck.y + up.dy * headR * 1.55)
        ctx.fill(Path(ellipseIn: CGRect(x: headC.x - headR - 1.4, y: headC.y - headR - 1.4,
                                        width: headR * 2 + 2.8, height: headR * 2 + 2.8)),
                 with: .color(CricketFigures.ink))
        ctx.fill(Path(ellipseIn: CGRect(x: headC.x - headR, y: headC.y - headR,
                                        width: headR * 2, height: headR * 2)),
                 with: .color(CricketFigures.skin))
        // Helmet shell over the top half, rotated with the head so it never floats off.
        var helmet = Path(ellipseIn: CGRect(x: headC.x - headR * 1.14, y: headC.y - headR * 1.30,
                                            width: headR * 2.28, height: headR * 1.70))
        helmet = helmet.applying(CGAffineTransform(translationX: -headC.x, y: -headC.y)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(pose.head) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: headC.x, y: headC.y)))
        ctx.fill(helmet, with: .color(CricketFigures.helmet))
        // The grille, which is what makes it read as a batter rather than a bare head.
        var grille = Path()
        grille.move(to: CGPoint(x: headC.x - headR * 1.05, y: headC.y + headR * 0.10))
        grille.addLine(to: CGPoint(x: headC.x - headR * 0.20, y: headC.y + headR * 0.62))
        ctx.stroke(grille, with: .color(CricketFigures.ink),
                   style: StrokeStyle(lineWidth: max(1.4, scale * 0.035), lineCap: .round))

        // ARMS, rooted at the shoulder joint that now has a cap wide enough to cover them. Front
        // arm last so the hands land on top.
        // THE HANDS TRAVEL, AND THE ARMS FOLLOW THEM. The arm is no longer a fixed-length spoke
        // whose tip happens to be the grip — the grip is placed first (shoulder, plus the shot's
        // own drop/drive along the torso's axes) and the arms are then drawn TO it. That is what
        // moves the pivot, and a moving pivot is the difference between a swing and a rotation.
        let armW = scale * 0.10
        let hands = CGPoint(
            x: shoulder.x + side.dx * CGFloat(pose.handDrive) * scale * 2.2
                          - up.dx * CGFloat(pose.handDrop) * scale * 2.2
                          + CGFloat(cos((150 + pose.frontArm - 90) * .pi / 180)) * scale * 0.30,
            y: shoulder.y + side.dy * CGFloat(pose.handDrive) * scale * 2.2
                          - up.dy * CGFloat(pose.handDrop) * scale * 2.2
                          + CGFloat(sin((150 + pose.frontArm - 90) * .pi / 180)) * scale * 0.30)
        // Back arm reaches to the same grip from a slightly different shoulder point, so the two
        // arms converge on the bat instead of splaying off it.
        let backShoulder = CGPoint(x: shoulder.x - side.dx * scale * 0.05,
                                   y: shoulder.y - side.dy * scale * 0.05)
        bone(backShoulder, hands, armW, CricketFigures.skin)
        bone(shoulder, hands, armW, CricketFigures.skin)
        // Gloves, at the hands, covering the arm ends — the joint the bat grows out of.
        joint(hands, armW * 1.55, Color.white.opacity(0.96))

        // The bat, from inside the gloves so the handle is never seen to start in mid-air.
        let batRad = (pose.bat - 90) * .pi / 180
        let grip = CGPoint(x: hands.x - CGFloat(cos(batRad)) * scale * 0.05,
                           y: hands.y - CGFloat(sin(batRad)) * scale * 0.05)
        let shoulderOfBat = CGPoint(x: hands.x + CGFloat(cos(batRad)) * scale * 0.20,
                                    y: hands.y + CGFloat(sin(batRad)) * scale * 0.20)
        let batTip = CGPoint(x: hands.x + CGFloat(cos(batRad)) * scale * 0.54,
                             y: hands.y + CGFloat(sin(batRad)) * scale * 0.54)
        // Handle and blade are drawn as two widths — a bat is not a uniform stick, and the
        // taper is most of what reads as "bat" at this size.
        var handle = Path()
        handle.move(to: grip)
        handle.addLine(to: shoulderOfBat)
        ctx.stroke(handle, with: .color(CricketFigures.ink),
                   style: StrokeStyle(lineWidth: scale * 0.075 + 2.2, lineCap: .round))
        ctx.stroke(handle, with: .color(CricketFigures.ink.opacity(0.85)),
                   style: StrokeStyle(lineWidth: scale * 0.075, lineCap: .round))
        var blade = Path()
        blade.move(to: shoulderOfBat)
        blade.addLine(to: batTip)
        ctx.stroke(blade, with: .color(CricketFigures.ink),
                   style: StrokeStyle(lineWidth: scale * 0.155, lineCap: .round))
        ctx.stroke(blade, with: .linearGradient(
            Gradient(colors: [CricketFigures.batFace, CricketFigures.batEdge]),
            startPoint: shoulderOfBat, endPoint: batTip),
            style: StrokeStyle(lineWidth: scale * 0.115, lineCap: .round))
    }

    /// The bowler: a figure running in with a rotating arm. Off-frame until a ball begins.
    private func drawBowler(ctx: GraphicsContext, size: CGSize) {
        guard shown != nil, delivery > 0 else { return }
        let t = Double(delivery)
        let scale = size.height * 0.28
        let x = size.width * CGFloat(CricketFigures.bowlerRun(t, full: fullRunUp))
        let feet = CGPoint(x: x, y: size.height * 0.60)
        drawGroundShadow(ctx: ctx, center: feet, width: scale * 0.72)

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

    /// Same joint-closing construction as the batter, minus the bat.
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

        func joint(_ at: CGPoint, _ width: CGFloat, _ colour: Color) {
            let r = width * 0.5
            ctx.fill(Path(ellipseIn: CGRect(x: at.x - r - 1.0, y: at.y - r - 1.0,
                                            width: width + 2.0, height: width + 2.0)),
                     with: .color(CricketFigures.ink))
            ctx.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r,
                                            width: width, height: width)),
                     with: .color(colour))
        }

        let hip = CGPoint(x: feet.x, y: feet.y - scale * 0.34)
        let torsoRad = (pose.torso - 90) * .pi / 180
        let torsoLen = scale * 0.38
        let shoulder = CGPoint(x: hip.x + CGFloat(cos(torsoRad)) * torsoLen,
                               y: hip.y + CGFloat(sin(torsoRad)) * torsoLen)
        let up = CGVector(dx: (shoulder.x - hip.x) / torsoLen, dy: (shoulder.y - hip.y) / torsoLen)
        let side = CGVector(dx: -up.dy, dy: up.dx)

        let legW = scale * 0.12
        let backFoot = limb(hip, 180 + pose.backLeg, scale * 0.34, legW, CricketFigures.bowlerKit)
        let frontFoot = limb(hip, 180 - pose.frontLeg, scale * 0.34, legW, CricketFigures.bowlerKit)
        for f in [backFoot, frontFoot] {
            ctx.fill(Path(ellipseIn: CGRect(x: f.x - scale * 0.14, y: f.y - scale * 0.05,
                                            width: scale * 0.28, height: scale * 0.10)),
                     with: .color(CricketFigures.shoe))
        }
        joint(hip, legW * 1.35, CricketFigures.bowlerKit)

        let hipHalf = scale * 0.14
        let shoulderHalf = scale * 0.18
        var body = Path()
        body.move(to: CGPoint(x: hip.x + side.dx * hipHalf, y: hip.y + side.dy * hipHalf))
        body.addLine(to: CGPoint(x: shoulder.x + side.dx * shoulderHalf,
                                 y: shoulder.y + side.dy * shoulderHalf))
        body.addLine(to: CGPoint(x: shoulder.x - side.dx * shoulderHalf,
                                 y: shoulder.y - side.dy * shoulderHalf))
        body.addLine(to: CGPoint(x: hip.x - side.dx * hipHalf, y: hip.y - side.dy * hipHalf))
        body.closeSubpath()
        ctx.fill(body, with: .color(CricketFigures.ink))
        var inner = Path()
        let ih = hipHalf - 1.5, ish = shoulderHalf - 1.5
        inner.move(to: CGPoint(x: hip.x + side.dx * ih, y: hip.y + side.dy * ih))
        inner.addLine(to: CGPoint(x: shoulder.x + side.dx * ish, y: shoulder.y + side.dy * ish))
        inner.addLine(to: CGPoint(x: shoulder.x - side.dx * ish, y: shoulder.y - side.dy * ish))
        inner.addLine(to: CGPoint(x: hip.x - side.dx * ih, y: hip.y - side.dy * ih))
        inner.closeSubpath()
        ctx.fill(inner, with: .linearGradient(
            Gradient(colors: [CricketFigures.bowlerKit, CricketFigures.jerseyShadow]),
            startPoint: shoulder, endPoint: hip))

        joint(shoulder, shoulderHalf * 2, CricketFigures.bowlerKit)

        let headR = scale * 0.10
        var neckPath = Path()
        neckPath.move(to: shoulder)
        neckPath.addLine(to: CGPoint(x: shoulder.x + up.dx * headR * 0.9,
                                     y: shoulder.y + up.dy * headR * 0.9))
        ctx.stroke(neckPath, with: .color(CricketFigures.ink),
                   style: StrokeStyle(lineWidth: scale * 0.10 + 2.0, lineCap: .round))
        ctx.stroke(neckPath, with: .color(CricketFigures.skin),
                   style: StrokeStyle(lineWidth: scale * 0.10, lineCap: .round))

        let headC = CGPoint(x: shoulder.x + up.dx * headR * 1.85,
                            y: shoulder.y + up.dy * headR * 1.85)
        ctx.fill(Path(ellipseIn: CGRect(x: headC.x - headR - 1.3, y: headC.y - headR - 1.3,
                                        width: headR * 2 + 2.6, height: headR * 2 + 2.6)),
                 with: .color(CricketFigures.ink))
        ctx.fill(Path(ellipseIn: CGRect(x: headC.x - headR, y: headC.y - headR,
                                        width: headR * 2, height: headR * 2)),
                 with: .color(CricketFigures.skin))
        ctx.fill(Path(ellipseIn: CGRect(x: headC.x - headR * 1.02, y: headC.y - headR * 1.20,
                                        width: headR * 2.04, height: headR * 1.30)),
                 with: .color(CricketFigures.hair))

        let armW = scale * 0.09
        let back = limb(shoulder, pose.backArm, scale * 0.30, armW, CricketFigures.skin)
        let front = limb(shoulder, pose.frontArm, scale * 0.32, armW, CricketFigures.skin)
        joint(back, armW * 1.1, CricketFigures.skin)
        joint(front, armW * 1.1, CricketFigures.skin)
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
        withAnimation(reduceMotion ? .none : .timingCurve(0.23, 1, 0.32, 1, duration: runUp)) { delivery = 1 }

        // Bat first, ball after contact — in that order, or the ball appears to move before it
        // was hit.
        //
        // A BOWLED SWINGS TOO, and that is a change. The old code skipped the swing entirely on
        // a bowled, so a player watched their batter stand perfectly still while the stumps fell
        // over. A batter who is bowled DID play a shot; the miss is the drama (§4.3).
        // LINEAR, because `strike` is a clock and not a position. CricketFigures.pose() now
        // shapes the swing itself — ease out into the backlift, hold, accelerate into contact,
        // decelerate through the follow-through. Easing the animation on TOP of that curve
        // double-eases it, which flattens the differences between shots back into one generic
        // ramp: exactly the "toy on a key" motion this is meant to stop.
        //
        // It also runs for the ball's OWN duration rather than a fixed 170 ms, so a six's
        // follow-through takes as long as a six's flight instead of snapping to its end pose
        // while the ball is still climbing.
        let swing = 0.17 + e.flightDuration * 0.75
        withAnimation(reduceMotion ? .none : .linear(duration: swing).delay(runUp * 0.7)) { strike = 1 }

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
        withAnimation(reduceMotion ? .none : .linear(duration: e.flightDuration)
            .delay(release + (e == .bowled ? 0 : 0.12))) {
            flight = 1
        }
        // After the first ball the bowler is already at the crease. A full run-up before all six
        // balls of an over gets old by the third (§4.4).
        withAnimation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.55).delay(release + 0.1)) {
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
    ///
    /// WHY THE EASING LIVES HERE AND NOT IN THE ANIMATION. `flight` is driven linearly on
    /// purpose — it is a clock, not a position. A hit ball does not travel at a constant rate:
    /// it leaves the bat fast and is dragged down by air the whole way, so the horizontal
    /// component decays while the vertical follows a real parabola. Easing the ANIMATION instead
    /// would ease both axes together, which bends the arc itself and is what made the flight look
    /// like a tweened sprite rather than a struck ball.
    private func ballPosition(_ e: BallEvent, _ p: CGFloat, w: CGFloat, h: CGFloat) -> CGPoint {
        let t = max(0, min(1, p))
        if e == .bowled {
            // A DELIVERY ACCELERATES. It is thrown, so it gains ground into the stumps rather
            // than covering the pitch at one rate — the old linear travel read as a sliding dot.
            let speed = t * t * (3 - 2 * t) * 0.35 + t * 0.65
            let travel: CGFloat = 0.86 - (0.74 * speed)
            // A pitched ball bounces once, about two thirds of the way down.
            let bounce = abs(sin(Double(speed) * .pi * 1.15))
            return CGPoint(x: w * travel, y: h * 0.50 - h * 0.05 * CGFloat(bounce))
        }
        // Horizontal: decaying, because drag never stops acting on it.
        let ease = 1 - pow(1 - t, 2.2)
        let x = w * (CGFloat(0.24) + e.reach * ease)
        // Vertical: a true parabola against the eased horizontal, so the apex sits where the
        // ball has actually travelled furthest per unit time rather than at the halfway frame.
        let lift = -(h * e.arc) * (4 * ease * (1 - ease))
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
            // UNDER THE FEET, NOT THROUGH THE WAIST. At 0.55 alpha this read as a translucent
            // bar laid over the pitch rather than as ground the players stand on.
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.79, green: 0.66, blue: 0.48).opacity(0.32))
                .frame(width: w * 0.72, height: h * 0.22)
                .position(x: w * 0.42, y: h * 0.66)

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
            // A ball in the air is FURTHER AWAY, so it reads smaller. Without this the six's
            // apex looks like the ball is sliding up a wall rather than going over the field.
            let height = max(0, (h * 0.46 - pos.y) / max(h * e.arc, 1))
            let depth = 1 - 0.22 * min(1, height)
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(red: 1.0, green: 0.54, blue: 0.42),
                                 Color(red: 0.78, green: 0.16, blue: 0.16)],
                        center: .topLeading, startRadius: 1, endRadius: 16))
                // The seam, which is the only thing that can show the ball SPINNING. A plain
                // disc rotating is indistinguishable from a disc standing still.
                Capsule()
                    .stroke(Color.white.opacity(0.65), lineWidth: 1.2)
                    .frame(width: 13, height: 6)
            }
            .frame(width: 15, height: 15)
            .rotationEffect(.degrees(Double(flight) * 900))
            .scaleEffect(depth)
            .position(pos)
        }
    }

    /// Motion trail — fading echoes behind the ball. Sells speed on the big hits and is invisible
    /// on a push, because it scales with the same distance the ball travels.
    @ViewBuilder
    private func trail(w: CGFloat, h: CGFloat) -> some View {
        if case .runs(let r) = shown, r >= 3 {
            // MORE ECHOES, CLOSER TOGETHER. Four widely-spaced dots read as four dots; a denser
            // tail reads as one blurred streak, which is the point of a trail.
            let count = r >= 6 ? 7 : 5
            ForEach(0..<count, id: \.self) { i in
                let lag = CGFloat(i + 1) * 0.035
                let tp = max(0, flight - lag)
                // Nothing until the ball has actually travelled far enough to have a past —
                // otherwise the whole tail stacks up on the bat at the moment of contact.
                if tp > 0 {
                    let pos = ballPosition(.runs(r), tp, w: w, h: h)
                    let fade = 1 - Double(i) / Double(count)
                    Circle()
                        .fill(Color(red: 1.0, green: 0.48, blue: 0.36))
                        .opacity(0.34 * fade * fade)
                        .frame(width: 14 * CGFloat(fade), height: 14 * CGFloat(fade))
                        .position(pos)
                }
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
            // OUT OF THE FLIGHT CORRIDOR. This used to sit dead centre, which is exactly where
            // the ball travels (baseY is 0.46h and the arc lifts from there) — so on the two
            // shots that matter most, a four and a six, the banner covered the entire flight
            // from the bat to the rope. The animation ran correctly and could not be seen.
            //
            // Up here it reads as a scoreboard call over the ground rather than a label pinned
            // on top of the action, and the whole corridor stays clear.
            Text(e.banner)
                .font(.system(size: big ? 34 : (e.isWicket ? 24 : 20), weight: .black))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: VoiidRadius.md)
                        .fill(e.isWicket
                              ? Color(red: 0.56, green: 0.11, blue: 0.11).opacity(0.85)
                              : Color.black.opacity(0.38)))
                // Overshoots then settles — the pop is what makes a six feel loud.
                .scaleEffect(0.7 + 0.45 * bannerPop)
                .opacity(Double(min(1, bannerPop)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 10)
        }
    }
}
