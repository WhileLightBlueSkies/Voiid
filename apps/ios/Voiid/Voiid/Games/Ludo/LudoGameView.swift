//
//  LudoGameView.swift
//  Voiid
//
//  The Ludo match screen (§11): responsive portrait chrome — top bar (close / help / network
//  capsule), two pod rows, the generated board as the vertically-centred visual anchor, and ONE
//  global die resting inside the active player's home quadrant.
//
//  NO TEXTUAL TURN BANNER EXISTS. Ownership is shown only by border hue + die pip color; the
//  pod ring communicates HOW LONG. Legal-pawn halos and the die affordance teach the next
//  action (§1, §11.1).
//

import SwiftUI

struct LudoGameView: View {
    let matchId: String
    var conversationId: String?
    var onClose: () -> Void
    var onRematch: (String) -> Void

    @StateObject private var engine = GamesEngine.shared
    @StateObject private var coordinator = LudoPresentationCoordinator()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var showExitConfirm = false
    @State private var showHelp = false

    /// Board square side, set by the layout pass and reused for tap math + animation centers.
    @State private var boardSide: CGFloat = 0

    var body: some View {
        let state = engine.ludoV2?.state

        ZStack {
            LudoColorPaletteBridge.color(scheme).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar(connected: state != nil)

                if let s = state {
                    // The board is the screen's optical centre: equal Spacers above and below
                    // the pod/board/pod block centre it vertically, and the board's own
                    // aspectRatio(1) centres it horizontally.
                    Spacer(minLength: 0)
                    VStack(spacing: 8) {
                        PodRow(state: s, top: true)
                        boardArea(state: s)
                            .frame(maxWidth: .infinity)
                        PodRow(state: s, top: false)
                    }
                    Spacer(minLength: 0)
                } else if let err = engine.joinError {
                    Spacer()
                    Text(err).font(VoiidFont.rounded(15)).foregroundStyle(VoiidColor.error)
                    Spacer()
                } else {
                    // Cold start draws the NEUTRAL generated board; never a token flash (§9).
                    Spacer(minLength: 0)
                    NeutralBoardSkeleton()
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)

            VStack {
                skipBanner
                    .padding(.top, 52)
                Spacer()
            }
            .animation(.easeOut(duration: 0.18), value: skipNotice)
            .allowsHitTesting(false)

            // Exit confirmation ONLY during an active match (§11.5); backgrounding is not this.
            if showExitConfirm, state?.isActive == true {
                exitSheet
            }
            if showHelp {
                LudoWalkthroughView(
                    mode: .sandbox,
                    clockNote: state?.isActive == true,
                    onDismiss: { showHelp = false })
            }
            if engine.ludoRequiresUpdate {
                VStack(spacing: 16) {
                    Text("Update Voiid to continue this game")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Button("Back to chat", action: onClose)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 14).fill(LudoColors.resolve(scheme).podSurface))
            }

            // Result sheet over scrim; final board stays visible underneath (§11.5).
            if let s = state, s.isFinished {
                ResultSheet(
                    state: s, matchId: matchId,
                    onRematch: { id in onRematch(id) },
                    onBack: { onClose() })
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await open() }
        // Every NEW authoritative action enqueues its presentation beats exactly once;
        // reconnects reset lastPresentedActionID so stale motion never replays (§9).
        .onChange(of: engine.ludoV2?.state.lastAction?.id) { _, _ in
            presentBeatsIfNeeded()
        }
        .onChange(of: reduceMotion) { _, enabled in
            coordinator.setReduceMotion(enabled || ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
                coordinator.setReduceMotion(
                    reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
        // ONE legal token means there is no decision to make, so the move plays itself once the
        // die has settled — the way Ludo King does it. Waiting for the roll animation to finish
        // keeps the number readable before the board moves under it.
        .onChange(of: autoMoveKey(state)) { _, key in
            guard let key else { return }
            Task { await autoMoveIfForced(key: key) }
        }
        .onDisappear { coordinator.cancelAll() }
    }

    // MARK: Open / resync (§9)

    private func open() async {
        LudoBoardGeometry.selfCheck()          // DEBUG parity assertion against the fixture
        coordinator.setReduceMotion(reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled)
        await engine.openLudo(matchId: matchId)
        presentBeatsIfNeeded()
    }

    // MARK: Chrome

    private func topBar(connected: Bool) -> some View {
        let colors = LudoColors.resolve(scheme)
        return HStack {
            Button(action: { stateIsActive ? (showExitConfirm = true) : onClose() }) {
                Text("×").font(.system(size: 26, weight: .regular))
            }
            .accessibilityLabel("Close")
            .foregroundStyle(colors.textPrimary)

            Spacer()

            if !connected || engine.joinError != nil {
                HStack(spacing: 4) {
                    Circle().fill(VoiidColor.error).frame(width: 6, height: 6)
                    Text("reconnecting")
                        .font(VoiidFont.rounded(11))
                        .foregroundStyle(VoiidColor.error)
                }
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(VoiidColor.error.opacity(0.12)))
                .accessibilityLabel("Reconnecting to the game server")
            }

            Spacer()

            Button { showHelp = true } label: {
                Text("?").font(VoiidFont.rounded(18, .semibold))
            }
            .accessibilityLabel("How to play")
            .foregroundStyle(colors.textPrimary)
        }
        .frame(height: 44)
    }

    private var stateIsActive: Bool { engine.ludoV2?.state.isActive == true }

    /// Fixed seats around the board (§11.2): green+yellow above, red+blue below. A pod sits at
    /// the board corner of the seat it belongs to — left pod hard left, right pod hard right —
    /// so each name reads as a label ON its own quadrant. A duel has NO pod for unassigned seats.
    @ViewBuilder
    private func PodRow(state: LudoGameStateV2, top: Bool) -> some View {
        let seats = top ? [1, 2] : [0, 3]
        HStack(spacing: 0) {
            pod(state: state, seat: seats[0], trayTrailing: true)
            Spacer(minLength: 8)
            pod(state: state, seat: seats[1], trayTrailing: false)
        }
        .frame(maxWidth: .infinity)
    }

    /// A pod and its die tray. The tray is ALWAYS reserved so the row never reflows when the
    /// turn moves; only the active seat's tray actually holds the die.
    @ViewBuilder
    private func pod(state: LudoGameStateV2, seat: Int, trayTrailing: Bool) -> some View {
        if let sv = state.seat(bySeat: seat) {
            HStack(spacing: 6) {
                if !trayTrailing { dieTray(state: state, seat: seat) }
                LudoPlayerPod(
                    seatView: sv,
                    active: !state.isFinished && state.turn?.seat == seat,
                    ringFraction: ringFraction(state, seat),
                    ringColorOverride: timerOverride(state, seat),
                    compact: compactLayout,
                    accessibilityLabel: podAccessibility(sv, state))
                if trayTrailing { dieTray(state: state, seat: seat) }
            }
        } else {
            // Keeps the opposite pod pinned to its own corner in a duel.
            Color.clear.frame(width: 0, height: LudoDimens.podSizeCompact.height)
        }
    }

    /// The die's home: a tray beside the owning pod, OUTSIDE the board.
    ///
    /// The die used to be drawn inside the board's own square — first past its edge, where it
    /// was clipped away entirely, then inside the active seat's home yard, where it sat on top
    /// of that seat's four resting pawns. It belongs next to the player it belongs to, the way
    /// Ludo King seats it beside the profile.
    @ViewBuilder
    private func dieTray(state: LudoGameStateV2, seat: Int) -> some View {
        let side = compactLayout ? LudoDimens.dieSizeCompact : LudoDimens.dieSizeStandard
        // No surface behind it: the die is an object thrown on the spot, not a chip in a slot.
        ZStack {
            if holdsDie(state: state, seat: seat) {
                dieView(state: state)
            }
        }
        .frame(width: side + 8, height: side + 8)
    }

    /// Which seat the die belongs beside right now.
    ///
    /// A roll in the air outranks the live turn. The server advances `activeSeat` the instant a
    /// roll produces no legal move, so following live state made the die disappear from the
    /// roller's side mid-tumble and reappear next to the following player — you never got to
    /// see what you had rolled.
    private func holdsDie(state: LudoGameStateV2, seat: Int) -> Bool {
        if let rolling = coordinator.animatingRollSeat { return rolling == seat }
        return !state.isFinished && state.turn?.seat == seat
    }

    /// A seat's countdown, human or bot.
    ///
    /// Bots carry `botActionAt` instead of `deadlineAt`, so following only the human deadline
    /// left a bot's pod and the board border with no clock at all — a bot turn looked identical
    /// to a stalled one. Both now render the same way; only the underlying clock differs.
    private func ringFraction(_ state: LudoGameStateV2, _ seat: Int) -> Double? {
        guard !state.isFinished, let turn = state.turn, turn.seat == seat else { return nil }
        return LudoTimerRing.state(opensAt: turn.opensAt,
                                   deadlineAt: turn.deadlineAt ?? turn.botActionAt,
                                   estimatedNowMs: engine.estimatedServerNowMs())?
            .fractionRemaining
    }

    private func timerOverride(_ state: LudoGameStateV2, _ seat: Int) -> Color? {
        guard !state.isFinished, let turn = state.turn, turn.seat == seat else { return nil }
        let colors = LudoColors.resolve(scheme)
        // Only a HUMAN window turns amber and then red. A bot's clock is pacing, not pressure,
        // so warning colours on it would be a lie about a deadline nobody can miss.
        guard let deadlineAt = turn.deadlineAt else { return nil }
        let remaining = deadlineAt - engine.estimatedServerNowMs()
        if remaining <= 2_000 { return colors.timerCritical }
        if remaining <= 5_000 { return colors.timerWarning }
        return nil
    }

    private func podAccessibility(_ sv: LudoSeatViewV2, _ state: LudoGameStateV2) -> String {
        var s = "\(sv.displayName), \(sv.color.name)"
        if !state.isFinished && state.turn?.seat == sv.seat { s += ", action" }
        s += ", \(sv.finishedPawns) of 4 pawns home"
        if sv.isBot { s += ", bot" }
        else if sv.connection == "disconnected" { s += ", disconnected" }
        return s
    }

    // MARK: Board + die

    @ViewBuilder
    private func boardArea(state: LudoGameStateV2) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                // TimelineView drives the perimeter clock. Without a per-frame tick the border
                // would only redraw when a new server frame landed, so it would jump in whole
                // seconds instead of shortening.
                TimelineView(.animation(minimumInterval: 1.0 / 30,
                                        paused: !boardNeedsFrames(state))) { timeline in
                    Canvas { ctx, size in
                        let colors = LudoColors.resolve(scheme)
                        drawBoard(&ctx, size: size, colors: colors, state: state,
                                  now: timeline.date)
                    }
                    .frame(width: side, height: side)
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                // A tap has to carry WHERE it landed, and TapGesture does not report a
                // location — so `lastTapPoint` was never written and every tap on the board
                // bailed out. A zero-distance drag gives the position, which is the whole input
                // for choosing a pawn.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { g in handleBoardTap(at: g.location, in: side) }
                )
                .onAppear { if boardSide == 0 { boardSide = side } }
                .onChange(of: side) { _, new in boardSide = new }

                accessiblePawnActions(state: state, side: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// True while anything on the board needs per-frame redrawing: a decision window counting
    /// down, or a playable token whose dashes are marching.
    private func boardNeedsFrames(_ state: LudoGameStateV2) -> Bool {
        guard !reduceMotion, !state.isFinished, let turn = state.turn else { return false }
        return turn.deadlineAt != nil || turn.botActionAt != nil || !turn.legalTokenIds.isEmpty
    }

    /// 0...1 of the active seat's window still left, over the SMOOTHED server clock.
    private func boardTimerFraction(_ state: LudoGameStateV2) -> CGFloat? {
        guard !state.isFinished, let turn = state.turn else { return nil }
        guard let ring = LudoTimerRing.state(
            opensAt: turn.opensAt, deadlineAt: turn.deadlineAt ?? turn.botActionAt,
            estimatedNowMs: engine.estimatedServerNowMs()) else { return nil }
        return CGFloat(ring.fractionRemaining)
    }

    @ViewBuilder
    private func accessiblePawnActions(state: LudoGameStateV2, side: CGFloat) -> some View {
        if let turn = state.turn, turn.phase == "awaitingMove",
           state.viewerRole == "controller", state.viewerSeat == turn.seat,
           state.seat(bySeat: turn.seat)?.isBot == false {
            let layout = LudoBoardGeometry.Layout(sideLength: side)
            let placed = LudoPawnLayer.layout(state: state, layout: layout, droppedSeats: [])
            let name = state.seat(bySeat: turn.seat)?.displayName ?? "Player"
            ForEach(turn.legalTokenIds, id: \.self) { token in
                if let pawn = placed.first(where: { $0.seat == turn.seat && $0.pawnIndex == token }) {
                    Button { engine.moveLudoV2(token: token) } label: { Color.clear }
                        .frame(width: max(44, layout.unit * 1.5), height: max(44, layout.unit * 1.5))
                        .position(pawn.center)
                        .accessibilityLabel(LudoAccessibility.pawnLabel(
                            state: state, seat: turn.seat, pawn: token, displayName: name))
                        .accessibilityHint(LudoAccessibility.legalHint(state: state, token: token) ?? "Move pawn")
                }
            }
        }
    }

    private func drawBoard(
        _ ctx: inout GraphicsContext,
        size: CGSize,
        colors: LudoColors,
        state: LudoGameStateV2,
        now: Date = Date(),
    ) {
        // Display-pawn overrides from the coordinator. A move that captures has TWO pawns in
        // transit at once — the mover hopping and the victim still standing where it was hit —
        // so these accumulate rather than replacing one another. Authoritative state already
        // holds every destination and is never fed back by animation.
        var overrides: [(seat: Int, pawn: Int, center: CGPoint)] = []
        if let h = coordinator.hopOverride {
            overrides.append((h.seat == -1 ? (state.turn?.seat ?? 0) : h.seat, h.pawn, h.center))
        }
        if let c = coordinator.captureReturn {
            overrides.append((c.seat, c.pawn, c.center))
        }

        LudoBoardCanvas.draw(
            &ctx,
            size: size,
            colors: colors,
            state: state,
            sweep: sweepVisual,
            displayOverrides: overrides,
            highContrast: contrast == .increased,
            dashPhase: CGFloat(now.timeIntervalSinceReferenceDate),
            timerFraction: boardTimerFraction(state),
            timerTint: timerOverride(state, state.turn?.seat ?? -1))
    }

    private var sweepVisual: LudoBoardSweep? { coordinator.sweep }

    private func dieView(state: LudoGameStateV2) -> some View {
        // No rolling while a roll is still in the air, even if the server has already opened the
        // next window — otherwise a fast tap fires the next roll before this one is readable.
        let canRoll = state.isActive &&
            coordinator.animatingRollSeat == nil &&
            state.turn?.phase == "awaitingRoll" &&
            state.viewerRole == "controller" && state.viewerSeat == state.turn?.seat
        let value = rollDisplayValue(state)
        let dieSeat = coordinator.animatingRollSeat ?? state.turn?.seat
        let pipsNeutral = state.isFinished || dieSeat == nil
        let pose = coordinator.rollPose.map { rp in
            LudoDiePose(rotationXDeg: rp.rotationXDeg, rotationYDeg: rp.rotationYDeg,
                        liftPx: rp.liftPx, scaleX: rp.scaleX, scaleY: rp.scaleY,
                        depthScale: rp.depthScale)
        } ?? LudoDiePose.resting(value: value)

        return ZStack {
            Rectangle().fill(Color.clear).contentShape(Rectangle())
            LudoDieCanvas(value: value, pose: pose, pipsNeutral: pipsNeutral,
                          activeSeat: dieSeat, side: dieSide)
        }
        .onTapGesture {
            guard canRoll else { return }   // second tap while animating fast-forwards upstream
            if coordinator.isAnimating { coordinator.cancelAll(); return }
            engine.rollLudoV2()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LudoAccessibility.dieLabel(state: state, displayedValue: value))
        .accessibilityAddTraits(canRoll ? [.isButton] : [])
        .accessibilityHint(canRoll ? "Rolls the die" : "")
    }

    private var dieSide: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad { return LudoDimens.dieSizeTablet }
        return compactLayout ? LudoDimens.dieSizeCompact : LudoDimens.dieSizeStandard
    }

    private var compactLayout: Bool { UIScreen.main.bounds.height < 700 }

    /// The face the die shows.
    ///
    /// `turn.value` is cleared the moment the turn advances, which blanked the die back to 1 as
    /// soon as a roll resolved — you never got to see what you rolled. The last committed roll
    /// is held here until a NEW roll replaces it, so the number stays readable while you choose
    /// a pawn, and through a skip.
    private func rollDisplayValue(_ state: LudoGameStateV2) -> Int {
        // A roll in the air outranks live state. `turn.value` is cleared the instant the move
        // commits, and the next action can land while the die is still tumbling, which is what
        // made the die appear to settle on one number and then change to another.
        coordinator.animatingRollValue ?? state.turn?.value ?? lastRolledValue ?? 1
    }

    @State private var lastRolledValue: Int?

    // MARK: Taps on the board

    private func handleBoardTap(at point: CGPoint, in side: CGFloat) {
        guard let state = engine.ludoV2?.state else { return }

        // A tap during a hop chain fast-forwards the moving pawn (§15); sends NO input.
        if coordinator.isAnimating {
            coordinator.cancelAll()
            return
        }

        // Resolve ONLY among server-legal tokens (§17), and only for a seat this viewer really
        // controls. Seat ownership is checked here as well as on the server so that tapping your
        // own colour during someone else's turn — including a bot's — does nothing at all rather
        // than firing an intent the server will reject.
        guard let turn = state.turn, turn.phase == "awaitingMove",
              state.viewerRole == "controller", state.viewerSeat == turn.seat,
              state.seat(bySeat: turn.seat)?.isBot == false else { return }

        let layout = LudoBoardGeometry.Layout(sideLength: side)
        let dropped = Set<Int>()
        let placed = LudoPawnLayer.layout(state: state, layout: layout, droppedSeats: dropped)
        let legalBySeat: [Int: Set<Int>] = [turn.seat: Set(turn.legalTokenIds)]

        if let hit = LudoPawnLayer.hitTest(placed: placed, unit: layout.unit,
                                           point: point,
                                           legalTokensBySeat: legalBySeat) {
            engine.moveLudoV2(token: hit.pawn)
        }
    }

    // MARK: Beats wiring (§12.3, §15)

    /// Called whenever a NEW authoritative action lands. Animates an action AT MOST ONCE via
    /// `lastRenderedActionId`, and never replays stale motion after reconnect (§9).
    private func presentBeatsIfNeeded() {
        guard let frame = engine.ludoV2 else { return }
        let s = frame.state
        let actionID = s.lastAction?.id
        guard actionID != lastPresentedActionID else { return }
        lastPresentedActionID = actionID
        coordinator.setReduceMotion(reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled)

        guard let action = s.lastAction else { return }
        // §9: animate only when ≥200 ms of the intended window remains; else final positions.
        let windowRemaining = action.presentationEndsAt - engine.estimatedServerNowMs()
        guard windowRemaining >= 200 || action.type == "turnChanged" || action.type == "roll" else { return }

        switch action.type {
        case "turnChanged":
            coordinator.enqueueTurnChange(fromSeat: action.fromSeat ?? action.actorSeat,
                                          toSeat: action.actorSeat)
        case "roll":
            if let r = action.roll {
                lastRolledValue = r.value
                // A roll that produced no legal move ALSO ends the turn, and the server commits
                // that as one action whose actorSeat is already the next player. `fromSeat` is
                // the seat that actually rolled, and that is where the die has to stay.
                coordinator.enqueueRoll(rollId: r.rollId, value: r.value,
                                        seat: action.fromSeat ?? action.actorSeat,
                                        matchId: matchId)
            }
        case "move", "capture", "autoTurn":
            // THE ACTOR IS `fromSeat` WHENEVER THE MOVE ALSO ENDED THE TURN. The server commits
            // the move with the mover's seat and then rewrites actorSeat to the next player,
            // leaving the move payload describing the OUTGOING seat's pawn. Reading actorSeat
            // resolved the home lane against the wrong seat, so a pawn heading for its own
            // victory route walked off toward another colour's start instead, and only snapped
            // back when the animation ended and authoritative state took over.
            let mover = action.fromSeat ?? action.actorSeat
            // A timeout that produced no move is a skip; say so, because otherwise the turn
            // simply moves on and the player who ran out of time is never told why.
            if action.type == "autoTurn" {
                if let r = action.roll {
                    lastRolledValue = r.value
                    coordinator.enqueueRoll(rollId: r.rollId, value: r.value,
                                            seat: mover, matchId: matchId)
                }
                announceSkip(seat: mover, moved: action.move != nil)
            }
            if let m = action.move {
                enqueueMoveBeat(m, actorSeat: mover)
            }
        default:
            break   // drop/end carry no mandatory motion beyond final positions
        }
    }

    private func enqueueMoveBeat(_ m: LudoActionMove, actorSeat: Int) {
        guard boardSide > 0 else { return }
        let layout = LudoBoardGeometry.Layout(sideLength: boardSide)

        func center(of pos: Int) -> CGPoint? {
            if pos >= 0 && pos < LudoRules.trackCount {
                let c = LudoBoardGeometry.trackCoords[pos]
                return layout.rect(of: LudoBoardGeometry.cell(c.0, c.1)).midPoint
            }
            if pos >= LudoRules.homeLaneBase,
               pos < LudoRules.homeLaneBase + LudoRules.homeLaneCount {
                let c = LudoBoardGeometry.homeLaneCoords[actorSeat][pos - LudoRules.homeLaneBase]
                return layout.rect(of: LudoBoardGeometry.cell(c.0, c.1)).midPoint
            }
            return nil
        }

        var centers: [CGPoint] = []
        // A pawn LEAVING THE YARD starts from its resting circle, not from nowhere. `from` is
        // the YARD sentinel, which is neither a track index nor a home-lane step, so it used to
        // resolve to nil and the chain was left with a single point — below the two needed to
        // animate. The move then played no motion at all and the pawn simply appeared on its
        // start square.
        if m.from == LudoRules.yard {
            centers.append(layout.yardSlotCenter(seat: actorSeat, pawn: m.tokenId))
        } else if let start = center(of: m.from) {
            centers.append(start)
        }
        centers.append(contentsOf: m.path.compactMap { center(of: $0) })

        // A captured pawn walks HOME THE WAY IT CAME: backward along the exact track cells it
        // advanced through, then into its yard slot. A straight arc across the board read as
        // teleporting; retracing the route shows the player what they just undid.
        var captureRoute: [CGPoint] = []
        if let cap = m.captured {
            let slot = layout.yardSlotCenter(seat: cap.seat, pawn: cap.tokenId)
            if let fromC = center(of: cap.from) {
                captureRoute.append(fromC)
                let start = LudoRules.startIndex(cap.seat)
                let travelled = ((cap.from - start) % LudoRules.trackCount
                                 + LudoRules.trackCount) % LudoRules.trackCount
                if travelled > 0 {
                    for step in 1...travelled {
                        let idx = ((cap.from - step) % LudoRules.trackCount
                                   + LudoRules.trackCount) % LudoRules.trackCount
                        if let c = center(of: idx) { captureRoute.append(c) }
                    }
                }
            }
            captureRoute.append(slot)
        }
        coordinator.enqueueMove(tokenId: m.tokenId, actorSeat: actorSeat, centers: centers,
                                captured: m.captured, captureRoute: captureRoute)
    }

    @State private var lastPresentedActionID: String?

    // MARK: Forced move

    /// Identifies a decision window that has exactly one legal answer, for a seat this viewer
    /// controls. Nil whenever the player genuinely has a choice — or none at all.
    private func autoMoveKey(_ state: LudoGameStateV2?) -> String? {
        guard let state, !state.isFinished, let turn = state.turn,
              turn.phase == "awaitingMove",
              state.viewerRole == "controller", state.viewerSeat == turn.seat,
              state.seat(bySeat: turn.seat)?.isBot == false,
              turn.legalTokenIds.count == 1,
              let token = turn.legalTokenIds.first else { return nil }
        return "\(turn.seat):\(turn.serial):\(turn.rollId ?? ""):\(token)"
    }

    @State private var autoMovedKey: String?

    private func autoMoveIfForced(key: String) async {
        guard autoMovedKey != key else { return }
        autoMovedKey = key

        // Wait for the die to actually finish. Firing on a fixed delay meant the move committed
        // while the roll was still in the air: the turn advanced under the animation, and the
        // token started moving before the number was readable — it looked like the token had
        // jumped somewhere on its own.
        let deadline = Date().addingTimeInterval(3.0)
        while coordinator.isAnimating && Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        // Then a beat to read the settled number before the board moves under it.
        try? await Task.sleep(nanoseconds: UInt64(LudoMotion.forcedMoveHoldMs * 1_000_000))

        // Re-check: the window may have closed while we waited (timeout, disconnect, resync).
        guard autoMoveKey(engine.ludoV2?.state) == key,
              let token = Int(key.split(separator: ":").last ?? "") else { return }
        engine.moveLudoV2(token: token)
    }

    // MARK: Skip announcement

    /// Transient line naming the seat whose window expired. Auto-clears; never blocks input.
    @State private var skipNotice: String?
    @State private var skipNoticeToken = 0

    private func announceSkip(seat: Int, moved: Bool) {
        let name = engine.ludoV2?.state.seat(bySeat: seat)?.displayName ?? "Player"
        skipNotice = moved ? "\(name) ran out of time — moved automatically"
                           : "\(name) ran out of time — turn skipped"
        skipNoticeToken += 1
        let token = skipNoticeToken
        UIAccessibility.post(notification: .announcement, argument: skipNotice)
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if token == skipNoticeToken { skipNotice = nil }
        }
    }

    @ViewBuilder
    private var skipBanner: some View {
        if let notice = skipNotice {
            let colors = LudoColors.resolve(scheme)
            Text(notice)
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundStyle(colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(colors.podSurface))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityHidden(true)   // already posted as a VoiceOver announcement
        }
    }

    // MARK: Sheets

    private var exitSheet: some View {
        let colors = LudoColors.resolve(scheme)
        return ZStack {
            colors.scrim.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Leave this game?")
                    .font(VoiidFont.rounded(18, .semibold))
                Text("You will forfeit this match.")
                    .font(VoiidFont.rounded(13))
                    .foregroundStyle(colors.textSecondary)
                Button { showExitConfirm = false } label: { Text("Keep playing") }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                Button(role: .destructive) {
                    showExitConfirm = false
                    Task {
                        await engine.forfeitLudo()
                        onClose()
                    }
                } label: { Text("Forfeit and leave") }
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 20).fill(VoiidColor.surfaceCard))
            .padding(.horizontal, 24)
        }
    }
}

/// Bridge so the screen's root background uses the ludo screen ground without leaking the
/// whole palette into VoiidColor.
enum LudoColorPaletteBridge {
    static func color(_ scheme: ColorScheme) -> Color {
        LudoColors.resolve(scheme).screenBackground
    }
}

// NOT #if DEBUG. This is the cold-start board every player sees before the first snapshot
// arrives — load-bearing UI, not debug scaffolding. It was inside a DEBUG guard while being
// used unconditionally at the top of this file, so Debug built and RELEASE DID NOT, which is
// invisible until someone tries to archive for TestFlight.
/// Cold-start skeleton: neutral generated board until the snapshot arrives (§9).
struct NeutralBoardSkeleton: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors = LudoColors.resolve(scheme)
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size),
                           cornerRadius: LudoDimens.boardCornerRadius(side: size.width)),
                     with: .color(colors.boardSurface))
            let unit = size.width / CGFloat(LudoBoardGeometry.side)
            for node in LudoBoardGeometry.cells {
                switch node.role {
                case .unused, .yard, .yardPocket:
                    continue
                default:
                    let r = CGRect(x: CGFloat(node.x) * unit + 1,
                                   y: CGFloat(node.y) * unit + 1,
                                   width: unit - 2, height: unit - 2)
                    ctx.fill(RoundedRectangle(cornerRadius: 3).path(in: r),
                             with: .color(colors.trackCellFill.opacity(0.4)))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // The clip has to know the resolved side, and the Canvas above only learns it at draw
        // time — so the radius is measured here rather than baked in as a constant.
        .modifier(LudoBoardClip())
    }
}

/// Terminal sheet over scrim (§11.5): winner name, completion count, captures, restrained
/// code-drawn ripple in the winner hue, Rematch + Back to chat. No avatars/coins/confetti.
struct ResultSheet: View {
    let state: LudoGameStateV2
    let matchId: String
    let onRematch: (String) -> Void
    let onBack: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var firedRematch = false

    var body: some View {
        let colors = LudoColors.resolve(scheme)
        let winner = state.seats.first { $0.seat == state.winnerSeat }
        ZStack(alignment: .bottom) {
            colors.scrim.ignoresSafeArea()
            VStack(spacing: 10) {
                Text(winner?.displayName ?? "")
                    .font(VoiidFont.rounded(24, .bold))
                    .foregroundStyle(colors.textPrimary)
                Text("\(winner?.finishedPawns ?? 0)/4 home · \(winner?.captures ?? 0) captures")
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundStyle(colors.textSecondary)

                // Restrained code-drawn ripple in the winner hue, 420 ms equivalent.
                RippleCircle(hue: colors.centerTriangle(state.winnerSeat ?? 0))
                    .frame(width: 56, height: 56)
                    .padding(.vertical, 8)

                HStack(spacing: 12) {
                    Button("Back to chat") { onBack() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    Button("Rematch") {
                        guard !firedRematch else { return }
                        firedRematch = true
                        Task {
                            if let id = try? await GamesAPI().rematch(matchId: matchId).match_id {
                                onRematch(id)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 20).fill(VoiidColor.surfaceCard))
        }
    }
}

/// The §11.5 ripple: one expanding ring + fading fill, drawn in code, runs once.
struct RippleCircle: View {
    let hue: Color
    @State private var animate = false
    var body: some View {
        ZStack {
            Circle().fill(hue.opacity(animate ? 0 : 0.25))
            Circle().stroke(hue, lineWidth: animate ? 1 : 3)
        }
        .scaleEffect(animate ? 1.15 : 0.9)
        .onAppear {
            withAnimation(.easeOut(duration: 0.42)) { animate = true }
        }
        .accessibilityHidden(true)
    }
}
