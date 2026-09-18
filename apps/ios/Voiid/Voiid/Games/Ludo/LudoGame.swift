//
//  LudoGame.swift
//  Voiid
//
//  Turn flow and animation timing for Ludo.
//

import SwiftUI
import Combine

@MainActor
final class LudoGame: ObservableObject {

    // MARK: Published state
    @Published private(set) var state = LudoState()
    @Published private(set) var pendingMoves: [Move] = []
    @Published private(set) var die: Int = 0
    @Published private(set) var message = "Red to roll."
    @Published private(set) var canRoll = false
    @Published private(set) var winner: Int?
    @Published private(set) var banner: String?

    @Published private(set) var hopping: TokenRef?
    @Published private(set) var popping: TokenRef?

    struct TokenRef: Equatable {
        let seat: Int
        let token: Int
    }

    let dice = DiceRoller()

    var humanSeats = 1
    var difficulty: String = "easy"
    var reduceMotion = false

    private var busy = false
    private var turnTask: Task<Void, Never>?

    func start(humans: Int = 1, difficulty: String = "easy") {
        humanSeats = humans
        self.difficulty = difficulty
        state = LudoState()
        pendingMoves = []
        winner = nil
        die = 0
        busy = false
        canRoll = true
        message = "\(LudoEngine.seats[0].name) to roll."
    }

    func restart() {
        stop()
        start(humans: humanSeats, difficulty: difficulty)
    }

    func isBot(_ seat: Int) -> Bool { seat >= humanSeats }

    func isLive(seat: Int, token: Int) -> Bool {
        seat == state.turn && pendingMoves.contains { $0.token == token }
    }

    // MARK: Rolling

    func roll() {
        guard !busy, winner == nil else { return }
        Task { await performRoll() }
    }

    private func performRoll() async {
        busy = true
        canRoll = false
        pendingMoves = []

        let seat = state.turn
        let rolled = await dice.roll(reduceMotion: reduceMotion)
        die = rolled

        state.consecutiveSixes = rolled == 6 ? state.consecutiveSixes + 1 : 0
        if state.consecutiveSixes == 3 {
            show("Three sixes")
            message = "\(name(seat)) rolled a third six — turn forfeited."
            state.consecutiveSixes = 0
            try? await Task.sleep(for: .milliseconds(900))
            return endTurn(again: false)
        }

        let moves = LudoEngine.legalMoves(state, seat: seat, die: rolled)

        guard !moves.isEmpty else {
            message = "\(name(seat)) rolled \(rolled) — no legal move."
            try? await Task.sleep(for: .milliseconds(850))
            return endTurn(again: rolled == 6)
        }

        if moves.count == 1 {
            message = "\(name(seat)) rolled \(rolled)."
            return await play(moves[0], seat: seat, die: rolled)
        }

        if isBot(seat) {
            message = "\(name(seat)) rolled \(rolled)…"
            try? await Task.sleep(for: .milliseconds(520))
            return await play(LudoEngine.botChoice(state, seat: seat, moves: moves, difficulty: difficulty),
                              seat: seat, die: rolled)
        }

        pendingMoves = moves
        message = "You rolled \(rolled). Tap a glowing token."
        busy = false
    }

    // MARK: Player input

    func tap(seat: Int, token: Int) {
        guard !busy, seat == state.turn, winner == nil else { return }

        if let move = pendingMoves.first(where: { $0.token == token }) {
            let rolled = die
            pendingMoves = []
            busy = true
            Task { await play(move, seat: seat, die: rolled) }
            return
        }

        // Forgiving input: tapping any token in your yard takes a pawn out if a yard exit is available
        if let yardMove = pendingMoves.first(where: { $0.leavesYard }),
           state.positions[seat][token] == LudoPos.yard {
            let rolled = die
            pendingMoves = []
            busy = true
            Task { await play(yardMove, seat: seat, die: rolled) }
            return
        }
    }

    // MARK: Executing a move

    private func play(_ move: Move, seat: Int, die rolled: Int) async {
        busy = true
        canRoll = false

        let step = reduceMotion ? Duration.milliseconds(10) : Theme.Timing.hop

        if move.leavesYard {
            withAnimation(Theme.land) { state.positions[seat][move.token] = 0 }
            LudoHaptics.tick()
            try? await Task.sleep(for: step * 2)
        } else {
            for square in (move.from + 1)...move.to {
                hopping = TokenRef(seat: seat, token: move.token)
                withAnimation(Theme.land) { state.positions[seat][move.token] = square }
                try? await Task.sleep(for: step / 2)
                hopping = nil
                try? await Task.sleep(for: step / 2)
            }
        }

        var captured = false
        let hits = LudoEngine.captures(state, seat: seat, dest: move.to)
        if !hits.isEmpty {
            captured = true
            show("Captured")
            LudoHaptics.thud()
            popping = TokenRef(seat: seat, token: move.token)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
                for hit in hits { state.positions[hit.seat][hit.token] = LudoPos.yard }
            }
            try? await Task.sleep(for: Theme.Timing.capturePause)
            popping = nil
        }

        var home = false
        if state.positions[seat][move.token] == LudoPos.goal {
            home = true
            show("Home")
            LudoHaptics.success()
            popping = TokenRef(seat: seat, token: move.token)
            try? await Task.sleep(for: .milliseconds(420))
            popping = nil
        }

        if state.hasWon(seat) { return declareWin(seat) }

        endTurn(again: LudoEngine.earnsAnotherRoll(die: rolled,
                                                   captured: captured,
                                                   reachedHome: home))
    }

    // MARK: Turn handover

    private func endTurn(again: Bool) {
        busy = false
        pendingMoves = []

        if !again {
            state.turn = (state.turn + 1) % 4
            state.consecutiveSixes = 0
        }

        let seat = state.turn
        if isBot(seat) {
            message = "\(name(seat)) is thinking…"
            canRoll = false
            turnTask?.cancel()
            turnTask = Task {
                try? await Task.sleep(for: reduceMotion ? .milliseconds(120) : Theme.Timing.botThink)
                guard !Task.isCancelled else { return }
                await performRoll()
            }
        } else {
            canRoll = true
            message = again ? "\(name(seat)) again — roll." : "\(name(seat)) to roll."
        }
    }

    func stop() {
        turnTask?.cancel()
        turnTask = nil
        busy = true
        canRoll = false
    }

    private func declareWin(_ seat: Int) {
        busy = true
        canRoll = false
        winner = seat
        show("\(LudoEngine.seats[seat].name) wins")
        message = "\(name(seat)) brought all four tokens home."
    }

    // MARK: Helpers

    private func name(_ seat: Int) -> String { LudoEngine.seats[seat].name }

    private func show(_ text: String) {
        banner = text
        Task {
            try? await Task.sleep(for: .milliseconds(1150))
            if banner == text { banner = nil }
        }
    }
}

// MARK: - Haptics

enum LudoHaptics {
    static func tick() {
        guard !GameHaptics.isDisabled else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    static func thud() {
        guard !GameHaptics.isDisabled else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        #endif
    }
    static func success() {
        guard !GameHaptics.isDisabled else { return }
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
