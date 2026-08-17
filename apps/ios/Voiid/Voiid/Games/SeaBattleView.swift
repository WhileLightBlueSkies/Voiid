//
//  SeaBattleView.swift
//  Voiid
//
//  The Sea Battle match screen (docs/games/future/SEA_BATTLE.md §6–§9).
//
//  A dumb view over GamesEngine, like every other renderer here: it holds no rules, decides
//  no outcomes, and never computes whether a shot hit. It draws the frame the server built
//  FOR THIS PLAYER — which for this game is not the same frame the opponent got, because the
//  engine projects state per recipient (§4.3). That is the one architectural difference from
//  Tic Tac Toe and it is invisible from in here: the fleet simply arrives, or does not.
//
//  Mirrors Android `SeaBattleScreen.kt`.
//

import SwiftUI

struct SeaBattleView: View {
    let matchId: String
    var onClose: (() -> Void)?
    var onRematch: ((String) -> Void)?

    @StateObject private var engine = GamesEngine.shared
    @StateObject private var motion = SeaBattleMotion()
    @EnvironmentObject var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var me: String? { TokenStore.shared.userId }

    // MARK: - Placement state
    //
    // Local until committed. The server has no notion of a half-placed fleet (§4.7) so there
    // is nothing to sync here — this is a form, and READY is its submit button.
    @State private var draft: [SeaBattleShip] = []
    @State private var draggingType: Int?
    @State private var horizontal: [Int: Bool] = [:]
    @State private var placementError: String?

    // MARK: - Firing state
    @State private var reticle: Int?
    /// The cell a shell is currently falling on. Local, and deliberately not a prediction of
    /// the OUTCOME — only of the fact that a shot was taken (§3.3).
    @State private var firingCell: Int?
    @State private var showingOwnBoard = false
    @State private var confirmResign = false

    var body: some View {
        VStack(spacing: VoiidSpacing.md) {
            if let s = engine.seaBattle {
                switch s.phase {
                case "placing": placement(s)
                default:        battle(s)
                }
            } else if let err = engine.joinError {
                Text(err)
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundStyle(VoiidColor.error)
                    .padding(.top, VoiidSpacing.xl)
            } else {
                ProgressView().padding(.top, VoiidSpacing.xl)
                Text("Setting up the board…")
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        // THE END SCREEN SITS OVER THE BOARD, and the board stays visible behind it (§9.2). A
        // player has to be able to see the final fleet while reading the verdict — that is the
        // difference between a result and a receipt.
        .overlay {
            if let s = engine.seaBattle, s.finished {
                MatchEndOverlay(
                    result: seaBattleResult(s),
                    matchId: matchId,
                    onRematch: { newId in engine.leave(); onRematch?(newId) },
                    onExit: { engine.leave(); onClose?() })
                .transition(.opacity)
            }
        }
        .navigationTitle("Sea Battle")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { engine.leave(); onClose?() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(VoiidColor.textPrimary)
                }
                .accessibilityLabel("Back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let s = engine.seaBattle, !s.finished, s.phase == "firing" {
                    Button("Resign") { confirmResign = true }
                        .font(VoiidFont.rounded(14, .medium))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
            }
        }
        // Confirmation, because the button lives next to the board and a resignation is
        // irreversible and counts as a loss (§2.6).
        .alert("Resign this match?", isPresented: $confirmResign) {
            Button("Resign", role: .destructive) { engine.resignSeaBattle() }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("It counts as a loss.")
        }
        .task { await engine.open(matchId: matchId) }
        .onAppear {
            session.hideTabBar = true
            GameAudio.shared.preload(for: "seabattle")
            // A fleet is already on the board before the player is asked anything. Never show
            // an empty board and ask them to fill it — that is a decision demanded before the
            // player has committed, which CROSS_CUTTING.md §9 names as the flow mistake the
            // whole games surface makes.
            if draft.isEmpty { draft = SeaBattleRules.randomFleet() }
        }
        .onDisappear {
            session.hideTabBar = false
            engine.leave()
            GameAudio.shared.release(for: "seabattle")
            motion.cancel()
        }
        // THE RESULT IS REVEALED WHEN THE SHELL LANDS, NOT WHEN THE FRAME ARRIVES (§9).
        //
        // The frame usually beats the animation — on the dev box by 300 ms — and showing the
        // answer the instant it lands would make a fast connection feel different from a slow
        // one. Holding the reveal until the end of the fixed 380 ms travel is what makes every
        // shot feel the same, and it is the whole reason the travel exists.
        .onChange(of: engine.seaBattle?.lastShot) { _, shot in
            guard shot != nil else { return }
            let land = {
                firingCell = nil
                reticle = nil
                SeaBattleSound.shotResolved(engine.seaBattle, me: me)
                if engine.seaBattle?.lastResult ?? 0 > 0 {
                    motion.hitShake(reduceMotion: reduceMotion)
                }
                if engine.seaBattle?.lastResult == 2, let s = engine.seaBattle, let seat = mySeat {
                    // Whichever fleet just lost a ship owns the outline being drawn in.
                    let owner = s.turn.map { 1 - $0 } == seat ? 1 - seat : seat
                    motion.revealSunk(Array(s.sunkCells[owner].suffix(5)),
                                      reduceMotion: reduceMotion)
                }
            }
            // Only wait when WE fired — an incoming shot has no shell of ours in the air.
            if firingCell != nil {
                motion.fire(reduceMotion: reduceMotion, onLand: land)
            } else {
                land()
            }
        }
        .onChange(of: engine.seaBattle?.finished) { _, finished in
            guard finished == true else { return }
            SeaBattleSound.matchEnded(engine.seaBattle, me: me)
        }
    }

    // MARK: - Seats

    private var mySeat: Int? {
        // Prefer the seat the SERVER stamped on my own frame. Falling back to an index lookup
        // covers a spectator frame, where there is no seat and there should not be one.
        if let seat = engine.seaBattle?.seat { return seat }
        guard let me, let players = engine.seaBattle?.players else { return nil }
        return players.firstIndex(of: me)
    }

    private var isMyTurn: Bool {
        guard let s = engine.seaBattle, let me else { return false }
        return !s.finished && s.turnUserId == me
    }

    // MARK: - Placement

    @ViewBuilder
    private func placement(_ s: SeaBattleState) -> some View {
        let committed = mySeat.map { s.placed.indices.contains($0) && s.placed[$0] } ?? false

        VStack(spacing: VoiidSpacing.md) {
            if committed {
                // Waiting for the opponent. Nothing to do, and saying so beats a spinner.
                VStack(spacing: VoiidSpacing.sm) {
                    ProgressView()
                    Text("Fleet ready. Waiting for your opponent…")
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .padding(.top, VoiidSpacing.lg)
                SeaBattleGrid(cells: ownCells(s), ships: myShips(s),
                              sunkTypes: sunkTypes(s, seat: mySeat ?? 0), dimmed: true)
                    .padding(.horizontal, VoiidSpacing.sm)
            } else {
                Text("Your ships are placed. Drag to move them, or tap Ready.")
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)

                SeaBattleGrid(
                    cells: draftCells(),
                    ships: draft,
                    onTap: { cell in
                        // Tap while dragging rotates. A separate rotate button is a two-handed
                        // operation and a long-press conflicts with the drag itself (§7.4).
                        if let type = shipAt(cell) { rotate(type) }
                    },
                    onDrag: { cell in dragShip(to: cell) }
                )
                .padding(.horizontal, VoiidSpacing.sm)

                if let placementError {
                    Text(placementError)
                        .font(VoiidFont.rounded(13, .regular))
                        .foregroundStyle(VoiidColor.error)
                }

                HStack(spacing: VoiidSpacing.md) {
                    Button("Random") {
                        draft = SeaBattleRules.randomFleet()
                        placementError = nil
                        GameAudio.shared.play("place_thud", gain: 0.5)
                    }
                    .font(VoiidFont.rounded(15, .medium))
                    .foregroundStyle(VoiidColor.textSecondary)

                    Spacer()

                    Button("Ready") {
                        if let failure = SeaBattleRules.validate(draft) {
                            placementError = failure.message
                            GameAudio.shared.play("error", gain: 0.5)
                            return
                        }
                        placementError = nil
                        engine.placeFleet(draft.map {
                            SeaBattleState.Ship(type: $0.type, cells: $0.cells, hits: 0)
                        })
                    }
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundStyle(SeaBattleRules.validate(draft) == nil
                                     ? VoiidColor.primary : VoiidColor.textSecondary)
                    .disabled(SeaBattleRules.validate(draft) != nil)
                }
                .padding(.horizontal, VoiidSpacing.sm)
            }
        }
    }

    private func shipAt(_ cell: Int) -> Int? {
        draft.first(where: { $0.cells.contains(cell) })?.type
    }

    private func rotate(_ type: Int) {
        guard let idx = draft.firstIndex(where: { $0.type == type }) else { return }
        let isH = horizontal[type] ?? true
        let others = draft.filter { $0.type != type }
        let cells = SeaBattleRules.run(
            from: draft[idx].cells[0], length: draft[idx].cells.count, horizontal: !isH)
        // Refuse the rotation rather than silently correcting it — silent correction is worse,
        // because the player learns nothing about why (§7.4).
        guard SeaBattleRules.canPlace(cells, avoiding: others, length: draft[idx].cells.count) else {
            GameAudio.shared.play("error", gain: 0.4)
            return
        }
        horizontal[type] = !isH
        draft[idx].cells = cells
        GameAudio.shared.play("place_thud", gain: 0.45)
    }

    private func dragShip(to cell: Int) {
        // The ship being dragged is whichever one the finger started on, held for the gesture.
        if draggingType == nil { draggingType = shipAt(cell) }
        guard let type = draggingType,
              let idx = draft.firstIndex(where: { $0.type == type }) else { return }
        let length = draft[idx].cells.count
        let isH = horizontal[type] ?? true
        let cells = SeaBattleRules.run(from: cell, length: length, horizontal: isH)
        let others = draft.filter { $0.type != type }
        guard SeaBattleRules.canPlace(cells, avoiding: others, length: length) else { return }
        draft[idx].cells = cells
    }

    private func draftCells() -> [SeaBattleCell] {
        var cells = [SeaBattleCell](repeating: .water, count: SeaBattle.cells)
        for ship in draft {
            for c in ship.cells where c >= 0 && c < cells.count { cells[c] = .ship }
        }
        return cells
    }

    // MARK: - Battle

    @ViewBuilder
    private func battle(_ s: SeaBattleState) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            status(s)

            // THE LAYOUT IS THE DESIGN (§8.1). The opponent's board is primary — it is where
            // you act and where the deduction happens, so it gets the space. Your own board is
            // a strip: a status readout answering "how much trouble am I in" without a tap.
            //
            // The emphasis follows the action rather than making the player follow it: on their
            // turn the only thing that will happen is a shot landing on YOUR board, so that is
            // what lifts.
            if showingOwnBoard {
                boardPair(primary: ownBoard(s), secondary: enemyBoard(s), s: s)
            } else {
                boardPair(primary: enemyBoard(s), secondary: ownBoard(s), s: s)
            }

            fleetStrip(s)

            // The end screen is an OVERLAY over the board, not a bar under it — see the
            // `overlay` modifier on the body. Nothing takes the fire button's place here.
            if !s.finished {
                fireButton(s)
            }
        }
    }

    @ViewBuilder
    private func boardPair(primary: some View, secondary: some View, s: SeaBattleState) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            primary
            secondary
                .frame(maxHeight: 96)
                .onTapGesture {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        showingOwnBoard.toggle()
                    }
                }
        }
    }

    private func enemyBoard(_ s: SeaBattleState) -> some View {
        SeaBattleGrid(
            cells: enemyCells(s),
            ships: enemyShips(s),
            sunkTypes: sunkTypes(s, seat: mySeat.map { 1 - $0 } ?? 1),
            reticle: reticle,
            firing: firingCell,
            shellProgress: motion.shellProgress,
            sunkReveal: motion.sunkReveal,
            dimmed: !isMyTurn,
            onTap: { cell in
                guard isMyTurn, !s.finished else { return }
                // Already-fired squares are inert. The server rejects them anyway; not sending
                // is just not wasting a frame we know is pointless.
                guard let seat = mySeat, !s.shots[seat].contains(cell) else { return }
                reticle = cell
            })
    }

    private func ownBoard(_ s: SeaBattleState) -> some View {
        SeaBattleGrid(cells: ownCells(s), ships: myShips(s),
                      sunkTypes: sunkTypes(s, seat: mySeat ?? 0),
                      dimmed: isMyTurn, showLabels: false)
    }

    private func enemyCells(_ s: SeaBattleState) -> [SeaBattleCell] {
        SeaBattleCells.enemy(s, mySeat: mySeat)
    }

    private func ownCells(_ s: SeaBattleState) -> [SeaBattleCell] {
        SeaBattleCells.own(s, mySeat: mySeat, draft: draft)
    }

    // MARK: - Fleets to draw

    /// MY ships, as hulls. During placement this is the local draft; afterwards it is the
    /// server's own `myFleet`, which is the only fleet the frame ever carries for me.
    private func myShips(_ s: SeaBattleState) -> [SeaBattleShip] {
        let fleet = s.myFleet.isEmpty
            ? draft
            : s.myFleet.map { SeaBattleShip(type: $0.type, cells: $0.cells, hits: $0.hits) }
        return fleet
    }

    /// THEIR ships, and ONLY the ones I am allowed to see.
    ///
    /// A sunk ship's cells are public at the moment of sinking, and the terminal frame reveals
    /// both fleets — those are the only two paths. Drawing prettier ships must never become a
    /// way to draw a ship the server deliberately withheld (§6.1).
    private func enemyShips(_ s: SeaBattleState) -> [SeaBattleShip] {
        guard let seat = mySeat else { return [] }
        let enemy = 1 - seat
        if s.finished, let revealed = s.revealedFleets, revealed.indices.contains(enemy) {
            return revealed[enemy].map {
                SeaBattleShip(type: $0.type, cells: $0.cells, hits: $0.hits)
            }
        }
        // Not finished: only wrecks, reconstructed from the public sunk-cell list.
        guard s.sunkCells.indices.contains(enemy), s.sunk.indices.contains(enemy) else { return [] }
        let cells = s.sunkCells[enemy]
        var out: [SeaBattleShip] = []
        var cursor = 0
        for type in s.sunk[enemy] {
            let length = SeaBattle.fleetSpec.indices.contains(type)
                ? SeaBattle.fleetSpec[type] : 2
            guard cursor + length <= cells.count else { break }
            out.append(SeaBattleShip(type: type, cells: Array(cells[cursor..<(cursor + length)])))
            cursor += length
        }
        return out
    }

    private func sunkTypes(_ s: SeaBattleState, seat: Int) -> Set<Int> {
        s.sunk.indices.contains(seat) ? Set(s.sunk[seat]) : []
    }

    // MARK: - The result

    /// Everything here is already in the frame — no new wire field, no new endpoint (§9.8).
    private func seaBattleResult(_ s: SeaBattleState) -> MatchEndResult {
        // An abandoned match has no winner, and nothing should be celebrated (§9.7).
        guard let winner = s.winnerUserId else { return .abandoned() }
        let seat = mySeat ?? 0
        let shots = s.shots.indices.contains(seat) ? s.shots[seat] : []
        let results = s.results.indices.contains(seat) ? s.results[seat] : []
        let hits = results.filter { $0 > 0 }.count
        let sunk = s.sunk.indices.contains(1 - seat) ? s.sunk[1 - seat].count : 0

        // How many of MY ships were never found. The line that turns a number into a story.
        let myHitCells = Set(
            (s.shots.indices.contains(1 - seat) ? s.shots[1 - seat] : [])
                .enumerated()
                .filter { i, _ in
                    (s.results.indices.contains(1 - seat)
                        && s.results[1 - seat].indices.contains(i)
                        && s.results[1 - seat][i] > 0)
                }
                .map { $0.element })
        let untouched = s.myFleet.filter { ship in ship.cells.allSatisfy { !myHitCells.contains($0) } }

        return .seaBattle(
            won: winner == me,
            shots: shots.count,
            hits: hits,
            sunk: sunk,
            hiddenShips: untouched.count,
            endedBy: s.endedBy)
    }

    // MARK: - HUD

    @ViewBuilder
    private func status(_ s: SeaBattleState) -> some View {
        let text: String = {
            if s.finished {
                guard let winner = s.winnerUserId else { return "Match abandoned" }
                let won = winner == me
                switch s.endedBy {
                case "resign":  return won ? "They resigned — you win" : "You resigned"
                case "timeout": return won ? "They ran out of time — you win" : "You ran out of time"
                default:        return won ? "You win" : "You lose"
                }
            }
            return isMyTurn ? "Your turn" : "Their turn"
        }()

        VStack(spacing: 2) {
            Text(text)
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundStyle(s.finished ? VoiidColor.primary : VoiidColor.textSecondary)
                .accessibilityAddTraits(.updatesFrequently)

            // Shots fired is the score (§2.5) — a player who cannot see it cannot chase a
            // personal best.
            if let seat = mySeat, s.shots.indices.contains(seat) {
                Text("\(s.shots[seat].count) shots")
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundStyle(VoiidColor.textSecondary.opacity(0.8))
            }

            deadlineLabel(s)
        }
    }

    /// The turn deadline, and ONLY inside 6 hours. A countdown from 24 hours is noise (§8.3).
    @ViewBuilder
    private func deadlineLabel(_ s: SeaBattleState) -> some View {
        if !s.finished, isMyTurn, let at = s.deadlineAt {
            let remaining = at / 1000 - Date().timeIntervalSince1970
            if remaining > 0 && remaining < 6 * 3600 {
                Text("\(Int(remaining / 60)) min left")
                    .font(VoiidFont.rounded(11, .medium))
                    .foregroundStyle(VoiidColor.error.opacity(0.9))
            }
        }
    }

    /// Remaining fleet, both sides. The deduction aid, and the difference between the endgame
    /// being reasoning and being a grind (§8.3).
    private func fleetStrip(_ s: SeaBattleState) -> some View {
        HStack(spacing: VoiidSpacing.lg) {
            ForEach([("Theirs", 1 - (mySeat ?? 0)), ("Yours", mySeat ?? 0)], id: \.0) { label, seat in
                HStack(spacing: 4) {
                    Text(label)
                        .font(VoiidFont.rounded(10, .medium))
                        .foregroundStyle(VoiidColor.textSecondary.opacity(0.7))
                    ForEach(Array(s.fleetSpec.enumerated()), id: \.offset) { type, length in
                        let down = s.sunk.indices.contains(seat) && s.sunk[seat].contains(type)
                        Text("\(length)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(down ? VoiidColor.textSecondary.opacity(0.35)
                                                  : VoiidColor.textPrimary)
                            .strikethrough(down)
                            .accessibilityLabel(
                                "\(SeaBattle.shipNames[type]) \(down ? "sunk" : "afloat")")
                    }
                }
            }
        }
    }

    /// FIRE is the confirmation step the irreversibility demands (§7.2).
    ///
    /// A 10x10 grid gives ~33 pt cells, below both Apple's 44 pt and Material's 48 dp minimum.
    /// One-tap firing on a sub-minimum target, where a mis-tap is irreversible and costs the
    /// match, is not acceptable — so you aim, then commit. The hesitation between the two is
    /// also the most Battleship thing about Battleship, and a one-tap scheme deletes it.
    @ViewBuilder
    private func fireButton(_ s: SeaBattleState) -> some View {
        Button {
            guard let cell = reticle, isMyTurn else { return }
            firingCell = cell
            engine.fire(cell: cell)
            GameAudio.shared.play("fire_launch", gain: 0.7)
        } label: {
            Text(reticle.map { "FIRE — \(SeaBattle.coordLabel($0))" } ?? "Select a square")
                .font(VoiidFont.rounded(16, .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, VoiidSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(canFire ? VoiidColor.primary.opacity(0.16) : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(canFire ? VoiidColor.primary : VoiidColor.textSecondary.opacity(0.3),
                                lineWidth: 1))
                .foregroundStyle(canFire ? VoiidColor.primary : VoiidColor.textSecondary)
        }
        .disabled(!canFire)
        .padding(.horizontal, VoiidSpacing.sm)
    }

    private var canFire: Bool {
        isMyTurn && reticle != nil && firingCell == nil
    }
}
