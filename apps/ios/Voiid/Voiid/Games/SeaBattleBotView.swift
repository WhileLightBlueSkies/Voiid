//
//  SeaBattleBotView.swift
//  Voiid
//
//  Practice against the local bot. No server, no match row, no connection needed.
//
//  Difficulty arrives already chosen from GameSetupSheet and is LOCKED for the match — a record
//  of "beat the hard bot" is worthless if it could be lowered mid-game. To change it you leave
//  and start again, which is exactly the honest cost.
//
//  IT DRAWS THROUGH THE SAME CODE AS THE ONLINE MATCH. `SeaBattleBotMatch` builds a
//  `SeaBattleState` shaped exactly like a server frame, and both boards come from
//  `SeaBattleCells` — so a player cannot tell a practice board from a real one, and a fix to one
//  is a fix to both. That is the same reason TicTacToeBoard is shared between its two screens.
//
//  Mirrors Android `SeaBattleBotScreen.kt`.
//

import SwiftUI

struct SeaBattleBotView: View {
    let level: BotDifficulty
    let skill: Double
    var onClose: (() -> Void)?

    @StateObject private var match = SeaBattleBotMatch()
    @StateObject private var motion = SeaBattleMotion()
    @EnvironmentObject var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Placement is local until committed, exactly as it is online.
    @State private var draft: [SeaBattleShip] = []
    @State private var draggingType: Int?
    @State private var horizontal: [Int: Bool] = [:]

    @State private var reticle: Int?
    @State private var showingOwnBoard = false

    private var s: SeaBattleState { match.state }

    var body: some View {
        VStack(spacing: VoiidSpacing.sm) {
            if s.phase == "placing" { placement } else { battle }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .overlay {
            if s.finished {
                MatchEndOverlay(
                    result: botResult(),
                    onPlayAgain: {
                        match.restart()
                        draft = SeaBattleRules.randomFleet()
                        reticle = nil
                    },
                    onExit: { onClose?() })
                .transition(.opacity)
            }
        }
        .navigationTitle("Sea Battle")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { onClose?() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(VoiidColor.textPrimary)
                }
                .accessibilityLabel("Back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Text(level.label)
                    .font(VoiidFont.rounded(13, .medium))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
        }
        .onAppear {
            session.hideTabBar = true
            match.configure(level: level, skill: skill)
            GameAudio.shared.preload(for: "seabattle")
            // The board arrives already populated — never an empty board with a demand to fill it.
            if draft.isEmpty { draft = SeaBattleRules.randomFleet() }
        }
        .onDisappear {
            session.hideTabBar = false
            GameAudio.shared.release(for: "seabattle")
            motion.cancel()
        }
        // Same two beats as online, driven by the same fields.
        .onChange(of: match.state.lastShot) { _, shot in
            guard shot != nil else { return }
            reticle = nil
            SeaBattleSound.shotResolved(match.state, me: "you")
            if (match.state.lastResult ?? 0) > 0 { motion.hitShake(reduceMotion: reduceMotion) }
            if match.state.lastResult == 2 {
                let owner = match.state.turn == SeaBattleBotMatch.humanSeat
                    ? SeaBattleBotMatch.botSeat : SeaBattleBotMatch.humanSeat
                motion.revealSunk(Array(match.state.sunkCells[owner].suffix(5)),
                                  reduceMotion: reduceMotion)
            }
        }
        .onChange(of: match.state.finished) { _, finished in
            guard finished else { return }
            SeaBattleSound.matchEnded(match.state, me: "you")
        }
    }

    /// THEIR ships, and ONLY the ones I am allowed to see — the identical rule the online screen
    /// follows. The bot's fleet is not in the state until the terminal frame reveals it.
    private var enemyShips: [SeaBattleShip] {
        let enemy = SeaBattleBotMatch.botSeat
        if s.finished, let revealed = s.revealedFleets, revealed.indices.contains(enemy) {
            return revealed[enemy].map {
                SeaBattleShip(type: $0.type, cells: $0.cells, hits: $0.hits)
            }
        }
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

    // MARK: - The result

    /// Built from the same state the online screen reads — the bot match produces a frame of
    /// the same shape, so the two end screens cannot drift.
    private func botResult() -> MatchEndResult {
        guard s.winnerUserId != nil else { return .abandoned() }
        let seat = SeaBattleBotMatch.humanSeat
        let shots = s.shots[seat]
        let hits = s.results[seat].filter { $0 > 0 }.count
        let sunk = s.sunk[SeaBattleBotMatch.botSeat].count
        let hitCells = Set(
            s.shots[SeaBattleBotMatch.botSeat].enumerated()
                .filter { i, _ in s.results[SeaBattleBotMatch.botSeat][safe: i].map { $0 > 0 } ?? false }
                .map { $0.element })
        let untouched = s.myFleet.filter { ship in ship.cells.allSatisfy { !hitCells.contains($0) } }
        return .seaBattle(
            won: s.winnerUserId == "you",
            shots: shots.count,
            hits: hits,
            sunk: sunk,
            hiddenShips: untouched.count,
            endedBy: s.endedBy)
    }

    // MARK: - Placement

    @ViewBuilder
    private var placement: some View {
        VStack(spacing: VoiidSpacing.md) {
            Text("Your ships are placed. Drag to move them, or tap Ready.")
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)

            SeaBattleGrid(
                cells: draftCells,
                ships: draft,
                onTap: { cell in if let type = shipAt(cell) { rotate(type) } },
                onDrag: { cell in dragShip(to: cell) })
                .padding(.horizontal, VoiidSpacing.sm)

            HStack(spacing: VoiidSpacing.md) {
                Button("Random") {
                    draft = SeaBattleRules.randomFleet()
                    GameAudio.shared.play("place_thud", gain: 0.5)
                }
                .font(VoiidFont.rounded(15, .medium))
                .foregroundStyle(VoiidColor.textSecondary)

                Spacer()

                Button("Ready") { match.place(draft) }
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundStyle(SeaBattleRules.validate(draft) == nil
                                     ? VoiidColor.primary : VoiidColor.textSecondary)
                    .disabled(SeaBattleRules.validate(draft) != nil)
            }
            .padding(.horizontal, VoiidSpacing.sm)
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
        guard SeaBattleRules.canPlace(cells, avoiding: others, length: draft[idx].cells.count) else {
            GameAudio.shared.play("error", gain: 0.4)
            return
        }
        horizontal[type] = !isH
        draft[idx].cells = cells
        GameAudio.shared.play("place_thud", gain: 0.45)
    }

    private func dragShip(to cell: Int) {
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

    private var draftCells: [SeaBattleCell] {
        var cells = [SeaBattleCell](repeating: .water, count: SeaBattle.cells)
        for ship in draft {
            for c in ship.cells where c >= 0 && c < cells.count { cells[c] = .ship }
        }
        return cells
    }

    // MARK: - Battle

    @ViewBuilder
    private var battle: some View {
        VStack(spacing: VoiidSpacing.sm) {
            status

            if showingOwnBoard {
                ownBoard
                enemyBoard.frame(maxHeight: 96)
                    .onTapGesture { withAnimation { showingOwnBoard = false } }
            } else {
                enemyBoard
                ownBoard.frame(maxHeight: 96)
                    .onTapGesture { withAnimation { showingOwnBoard = true } }
            }

            fleetStrip

            // The end screen is an OVERLAY over the boards (§9.2).
            if !s.finished {
                fireButton
            }
        }
    }

    private var enemyBoard: some View {
        SeaBattleGrid(
            cells: SeaBattleCells.enemy(s, mySeat: SeaBattleBotMatch.humanSeat),
            ships: enemyShips,
            sunkTypes: Set(s.sunk[SeaBattleBotMatch.botSeat]),
            reticle: reticle,
            shellProgress: motion.shellProgress,
            sunkReveal: motion.sunkReveal,
            dimmed: !match.canFire,
            onTap: { cell in
                guard match.canFire else { return }
                guard !s.shots[SeaBattleBotMatch.humanSeat].contains(cell) else { return }
                reticle = cell
            })
    }

    private var ownBoard: some View {
        SeaBattleGrid(
            cells: SeaBattleCells.own(s, mySeat: SeaBattleBotMatch.humanSeat, draft: draft),
            ships: s.myFleet.isEmpty
                ? draft
                : s.myFleet.map { SeaBattleShip(type: $0.type, cells: $0.cells, hits: $0.hits) },
            sunkTypes: Set(s.sunk[SeaBattleBotMatch.humanSeat]),
            dimmed: match.canFire,
            showLabels: false)
    }

    @ViewBuilder
    private var status: some View {
        let text: String = {
            if s.finished {
                guard let winner = s.winnerUserId else { return "Match abandoned" }
                if s.endedBy == "resign" { return "You gave up" }
                return winner == "you" ? "You win" : "The bot wins"
            }
            if match.botThinking { return "The bot is thinking…" }
            return match.canFire ? "Your turn" : "Their turn"
        }()

        VStack(spacing: 2) {
            Text(text)
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundStyle(s.finished ? VoiidColor.primary : VoiidColor.textSecondary)
                .accessibilityAddTraits(.updatesFrequently)
            Text("\(s.shots[SeaBattleBotMatch.humanSeat].count) shots")
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary.opacity(0.8))
        }
    }

    private var fleetStrip: some View {
        HStack(spacing: VoiidSpacing.lg) {
            ForEach([("Theirs", SeaBattleBotMatch.botSeat),
                     ("Yours", SeaBattleBotMatch.humanSeat)], id: \.0) { label, seat in
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
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fireButton: some View {
        let canFire = match.canFire && reticle != nil
        Button {
            guard let cell = reticle else { return }
            GameAudio.shared.play("fire_launch", gain: 0.7)
            // The shell falls, THEN the shot resolves — so a local bot game has the same beat as
            // a round-tripped online one rather than answering instantly.
            motion.fire(reduceMotion: reduceMotion) { match.fire(at: cell) }
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
                        .stroke(canFire ? VoiidColor.primary
                                        : VoiidColor.textSecondary.opacity(0.3), lineWidth: 1))
                .foregroundStyle(canFire ? VoiidColor.primary : VoiidColor.textSecondary)
        }
        .disabled(!canFire)
        .padding(.horizontal, VoiidSpacing.sm)
    }
}

/// Bounds-safe subscript. The frame's arrays are built by the match, but indexing them blind
/// would still crash on a malformed one rather than degrade.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
