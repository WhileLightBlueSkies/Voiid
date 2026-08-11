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

    /// How hard the shot is played, 0-1. Drives backlift depth, swing timing and follow-through.
    ///
    /// This is the one number that makes a six look different from a single. Before it, every
    /// connecting shot used an identical swing and only the BALL's travel changed — so the
    /// batter played the same stroke whether they blocked or cleared the rope.
    var swingPower: Double {
        switch self {
        case .runs(let r):
            switch r {
            case 6: return 1.0
            case 5: return 0.85
            case 4: return 0.8
            case 3: return 0.55
            case 2: return 0.42
            default: return 0.32
            }
        // A dot is a defensive push: a real stroke, deliberately a small one.
        case .dot:    return 0.22
        // Caught is a mistimed drive — full commitment, bad contact. It has to look like a shot
        // worth playing or the dismissal reads as bad luck rather than a mistake.
        case .caught: return 0.7
        case .bowled: return 0
        }
    }

    /// When the bat meets the ball, in seconds from the start of the animation. The ball's
    /// flight is delayed by this so it never moves before it was hit.
    var contactDelay: Double { 0.10 + 0.05 * swingPower + 0.085 }

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
    @State private var flight: CGFloat = 0
    @State private var bannerPop: CGFloat = 0
    @State private var shown: BallEvent?
    /// 0 = pitch as normal, 1 = ground fully cleared for the announcement.
    @State private var clear: CGFloat = 0

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

                    // The batter: a simple figure that leans into the shot. Reads as a person at
                    // a glance without needing art.
                    //
                    // THE BODY COUNTER-ROTATES INTO THE BACKLIFT. `strike` is negative while
                    // loading, so this leans AWAY as the bat goes up and then drives through —
                    // which is the coiling that makes a swing look powered rather than waved.
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.93, green: 0.91, blue: 0.96))
                        .frame(width: 13, height: 40)
                        .rotationEffect(.degrees(12 * Double(strike)), anchor: .bottom)
                        // WEIGHT SHIFT. A batter steps INTO the ball; the body moving forward a
                        // few points as the bat comes through is most of what separates effort
                        // from a hinge rotating in place. Sideways only — a vertical bob would
                        // read as a jump.
                        .offset(x: CGFloat(max(strike, 0)) * 5)
                        .position(x: w * 0.165, y: h * 0.50)

                    // The bat. Swings through on any shot; stays down on a bowled.
                    //
                    // The arc runs from +24° (address, angled back) through 0 to well past
                    // vertical on the follow-through. Because `strike` now reaches ~1.3 on a
                    // six, the same expression finishes the bat high over the shoulder without
                    // any extra case — and at -1 it is fully cocked behind the head.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.91, green: 0.75, blue: 0.46),
                                     Color(red: 0.73, green: 0.51, blue: 0.18)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 11, height: 56)
                        .rotationEffect(.degrees(24 - 78 * Double(strike)), anchor: .bottom)
                        .offset(x: CGFloat(max(strike, 0)) * 5)
                        .position(x: w * 0.215, y: h * 0.52)

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
            }
            .padding(.horizontal, VoiidSpacing.lg)
            // Rises slightly as it arrives, the way the score banner does — same surface, so
            // the same motion language.
            .offset(y: (1 - clear) * 10)
        }
    }

    // MARK: - Motion

    private func play() {
        guard let e = event else { return }
        shown = e
        strike = 0
        flight = 0
        bannerPop = 0

        // A REAL SHOT IS THREE MOVEMENTS, NOT ONE.
        //
        // This used to be a single easeOut from 0 to 1 that stopped dead at contact, identical
        // for every outcome — which is why a six felt no different from a single. A stroke is a
        // BACKLIFT (weight loads, bat goes up and back), a STRIKE (fast, accelerating into the
        // ball), then a FOLLOW-THROUGH that overshoots and settles. The pause at the top of the
        // backlift is what makes the strike read as fast: speed is only visible against
        // stillness.
        //
        // `strike` is now a phase cursor rather than a 0-1 ramp:
        //      -1  fully loaded at the top of the backlift
        //       0  address, bat down
        //       1  contact
        //     1.3  end of the follow-through, before it settles back
        //
        // A bowled has no connecting swing — the whole point is that the bat missed.
        if e != .bowled {
            let power = e.swingPower

            // 1. BACKLIFT. Bigger shots load further and take slightly longer, which is most of
            // what separates a defensive push from a heave.
            withAnimation(.easeOut(duration: 0.10 + 0.05 * power)) {
                strike = -power
            }

            // 2. STRIKE. easeIn, not easeOut: a bat ACCELERATES into the ball. Using easeOut
            // here (as the old version did) makes the fastest part of the motion happen first
            // and the bat appears to decelerate into contact, which reads as a poke.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10 + 0.05 * power) {
                withAnimation(.easeIn(duration: 0.085)) { strike = 1 }
            }

            // 3. FOLLOW-THROUGH, overshooting past contact then settling. Scaled by power, so a
            // dot ball barely continues and a six finishes high with the bat over the shoulder.
            let contactAt = 0.10 + 0.05 * power + 0.085
            DispatchQueue.main.asyncAfter(deadline: .now() + contactAt) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                    strike = 1 + 0.3 * power
                }
            }
        }

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

        // The ball leaves on CONTACT, not on a fixed 0.12s — the swing's timing now varies with
        // the shot, and a hardcoded delay would have the ball departing before the bat arrives
        // on the slower, bigger swings.
        withAnimation(.linear(duration: e.flightDuration)
            .delay(e == .bowled ? 0 : e.contactDelay)) {
            flight = 1
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)
            .delay(e == .bowled ? 0.1 : e.contactDelay)) {
            bannerPop = 1
        }
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
