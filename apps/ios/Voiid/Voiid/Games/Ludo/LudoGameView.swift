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
            pod(state: state, seat: seats[0])
            Spacer(minLength: 8)
            pod(state: state, seat: seats[1])
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func pod(state: LudoGameStateV2, seat: Int) -> some View {
        if let sv = state.seat(bySeat: seat) {
            LudoPlayerPod(
                seatView: sv,
                active: !state.isFinished && state.turn?.seat == seat,
                ringFraction: ringFraction(state, seat),
                ringColorOverride: timerOverride(state, seat),
                compact: compactLayout,
                accessibilityLabel: podAccessibility(sv, state))
        } else {
            // Keeps the opposite pod pinned to its own corner in a duel.
            Color.clear.frame(width: 0, height: LudoDimens.podSizeCompact.height)
        }
    }

    private func ringFraction(_ state: LudoGameStateV2, _ seat: Int) -> Double? {
        guard !state.isFinished, let turn = state.turn, turn.seat == seat else { return nil }
        return LudoTimerRing.state(opensAt: turn.opensAt, deadlineAt: turn.deadlineAt,
                                   estimatedNowMs: engine.estimatedServerNowMs())?
            .fractionRemaining
    }

    private func timerOverride(_ state: LudoGameStateV2, _ seat: Int) -> Color? {
        guard !state.isFinished, let turn = state.turn, turn.seat == seat else { return nil }
        let colors = LudoColors.resolve(scheme)
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
                Canvas { ctx, size in
                    let colors = LudoColors.resolve(scheme)
                    drawBoard(&ctx, size: size, colors: colors, state: state)
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture().onEnded { handleBoardTap(in: side) }
                )
                .onAppear { if boardSide == 0 { boardSide = side } }
                .onChange(of: side) { _, new in boardSide = new }

                accessiblePawnActions(state: state, side: side)

                dieAnchorView(state: state)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func accessiblePawnActions(state: LudoGameStateV2, side: CGFloat) -> some View {
        if let turn = state.turn, turn.phase == "awaitingMove",
           state.viewerRole == "controller", state.viewerSeat == turn.seat {
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
    ) {
        // Display-pawn override from the coordinator: mid-hop or capture-return; authoritative
        // state already holds every destination and is never fed back by animation.
        var override: (seat: Int, pawn: Int, center: CGPoint)?
        if let h = coordinator.hopOverride {
            override = (h.seat == -1 ? (state.turn?.seat ?? 0) : h.seat, h.pawn, h.center)
        }
        if let c = coordinator.captureReturn {
            override = (c.seat, c.pawn, c.center)
        }

        LudoBoardCanvas.draw(
            &ctx,
            size: size,
            colors: colors,
            state: state,
            sweep: sweepVisual,
            displayOverride: override,
            highContrast: contrast == .increased)
    }

    private var sweepVisual: LudoBoardSweep? { coordinator.sweep }

    /// One global die resting at the ACTIVE player's anchor OUTSIDE the board (§11.3). It
    /// never flies across the board during a roll — it tumbles in place at its anchor. The §12.3
    /// sequence relocates it only after the border sweep completes (coordinator-ordered).
    @ViewBuilder
    private func dieAnchorView(state: LudoGameStateV2) -> some View {
        let canRoll = state.isActive &&
            state.turn?.phase == "awaitingRoll" &&
            state.viewerRole == "controller" && state.viewerSeat == state.turn?.seat

        GeometryReader { geo in
            // The die rests INSIDE the active seat's home quadrant, the way Ludo King does. The
            // anchors used to sit at a negative inset outside the board rect, which put the die
            // beyond the layout bounds and clipped it away entirely — the die was never visible.
            // The yard pocket is empty space by construction, so nothing is occluded.
            let side = min(geo.size.width, geo.size.height)
            let quadrant = side * 0.235          // centre of a 6x6 home yard on the 15x15 grid
            let originX = (geo.size.width - side) / 2
            let originY = (geo.size.height - side) / 2
            let point: CGPoint = {
                switch state.turn?.seat ?? 0 {
                case 1: return CGPoint(x: originX + quadrant,
                                       y: originY + quadrant)                 // green top-left
                case 2: return CGPoint(x: originX + side - quadrant,
                                       y: originY + quadrant)                 // yellow top-right
                case 3: return CGPoint(x: originX + side - quadrant,
                                       y: originY + side - quadrant)          // blue bottom-right
                default: return CGPoint(x: originX + quadrant,
                                        y: originY + side - quadrant)         // red bottom-left
                }
            }()

            dieView(state: state, canRoll: canRoll)
                .frame(width: LudoDimens.dieHitTarget, height: LudoDimens.dieHitTarget)
                .position(point)
        }
        .allowsHitTesting(true)
    }

    private func dieView(state: LudoGameStateV2, canRoll: Bool) -> some View {
        let value = rollDisplayValue(state)
        let pipsNeutral = state.isFinished || state.turn == nil
        let pose = coordinator.rollPose.map { rp in
            LudoDiePose(rotationXDeg: rp.rotationXDeg, rotationYDeg: rp.rotationYDeg,
                        liftPx: rp.liftPx, scaleX: rp.scaleX, scaleY: rp.scaleY)
        } ?? LudoDiePose.resting(value: value)

        return ZStack {
            Circle().fill(Color.clear).contentShape(Circle())
            LudoDieCanvas(value: value, pose: pose, pipsNeutral: pipsNeutral,
                          activeSeat: state.turn?.seat, side: dieSide)
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

    private func rollDisplayValue(_ state: LudoGameStateV2) -> Int {
        state.turn?.value ?? 1
    }

    // MARK: Taps on the board

    private func handleBoardTap(in side: CGFloat) {
        guard let state = engine.ludoV2?.state else { return }

        // A tap during a hop chain fast-forwards the moving pawn (§15); sends NO input.
        if coordinator.isAnimating {
            coordinator.cancelAll()
            return
        }

        // Resolve ONLY among server-legal tokens (§17).
        guard let turn = state.turn, turn.phase == "awaitingMove",
              state.viewerRole == "controller", state.viewerSeat == turn.seat,
              lastTapPoint != nil else { return }

        let layout = LudoBoardGeometry.Layout(sideLength: side)
        let dropped = Set<Int>()
        let placed = LudoPawnLayer.layout(state: state, layout: layout, droppedSeats: dropped)
        var legalBySeat: [Int: Set<Int>] = [turn.seat: Set(turn.legalTokenIds)]
        legalBySeat[turn.seat] = Set(turn.legalTokenIds)

        if let hit = LudoPawnLayer.hitTest(placed: placed, unit: layout.unit,
                                           point: lastTapPoint ?? .zero,
                                           legalTokensBySeat: legalBySeat) {
            engine.moveLudoV2(token: hit.pawn)
        }
        self.lastTapPoint = nil
    }

    @State private var lastTapPoint: CGPoint?

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
                coordinator.enqueueRoll(rollId: r.rollId, value: r.value, matchId: matchId)
            }
        case "move", "capture", "autoTurn":
            if let m = action.move {
                enqueueMoveBeat(m, actorSeat: action.actorSeat)
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
        if let start = center(of: m.from) { centers.append(start) }
        centers.append(contentsOf: m.path.compactMap { center(of: $0) })

        var yardSlot: CGPoint?
        if let cap = m.captured {
            yardSlot = layout.yardSlotCenter(seat: cap.seat, pawn: cap.tokenId)
            if let fromC = center(of: cap.from), let slot = yardSlot {
                coordinator.arcFrom = fromC
                coordinator.arcMidpoint = CGPoint(x: (fromC.x + slot.x) / 2,
                                                  y: min(fromC.y, slot.y) - layout.unit)
            }
        }
        coordinator.enqueueMove(tokenId: m.tokenId, actorSeat: actorSeat, centers: centers,
                                captured: m.captured, yardSlotCenter: yardSlot)
    }

    @State private var lastPresentedActionID: String?

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

#if DEBUG
/// Cold-start skeleton: neutral generated board until the snapshot arrives (§9).
struct NeutralBoardSkeleton: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors = LudoColors.resolve(scheme)
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size),
                           cornerRadius: LudoDimens.boardCornerRadius),
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
        .clipShape(RoundedRectangle(cornerRadius: LudoDimens.boardCornerRadius))
    }
}
#endif

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
