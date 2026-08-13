//
//  SeaBattleBotMatch.swift
//  Voiid
//
//  The local match state machine for a Sea Battle practice game — the offline counterpart to
//  GamesEngine's server-fed state.
//
//  IT PRODUCES THE SAME SHAPE THE RENDERER CONSUMES. `SeaBattleView` draws from a
//  `SeaBattleState`, so this builds one rather than exposing a different model: one board
//  component draws both a bot game and an online game, and if this had its own shape every view
//  would grow a branch and the two would drift. That is the same reason TicTacToeBotMatch exists
//  in the shape it does.
//
//  THE RULES ARE THE CLIENT MIRROR (SeaBattleBoard.swift), not a third copy. Hit resolution here
//  is trivial — is this cell in a ship — and everything a player could argue about (placement
//  legality) goes through the same `SeaBattleRules.validate` the online game uses.
//
//  Mirrors Android `SeaBattleBotMatch.kt`.
//

import Foundation
import Combine

@MainActor
final class SeaBattleBotMatch: ObservableObject {
    static let humanSeat = 0
    static let botSeat = 1

    /// The state the renderer draws, built to look exactly like a server frame.
    @Published private(set) var state: SeaBattleState
    /// True while the bot is "thinking" — the board is locked so a fast tapper cannot fire twice.
    @Published private(set) var botThinking = false
    @Published var paused = false

    private(set) var level: BotDifficulty
    private(set) var skill: Double

    private var humanFleet: [SeaBattleShip] = []
    private var botFleet: [SeaBattleShip] = []
    private var bot: SeaBattleBot
    /// Guards against double-counting a result if the view re-renders after the game ends.
    private var recorded = false

    init(level: BotDifficulty = .moderate, skill: Double? = nil) {
        self.level = level
        self.skill = skill ?? level.skill
        self.bot = SeaBattleBot(skill: skill ?? level.skill)
        self.state = Self.emptyState()
    }

    func configure(level: BotDifficulty, skill: Double) {
        self.level = level
        self.skill = skill
        self.bot = SeaBattleBot(skill: skill)
    }

    private static func emptyState() -> SeaBattleState {
        SeaBattleState(
            players: ["you", "bot"],
            phase: "placing",
            turn: nil,
            turnUserId: nil,
            shots: [[], []],
            results: [[], []],
            sunk: [[], []],
            sunkCells: [[], []],
            placed: [false, false],
            fleetSpec: SeaBattle.fleetSpec,
            deadlineAt: nil,
            finished: false,
            winnerUserId: nil,
            endedBy: nil,
            lastShot: nil,
            lastResult: nil,
            seat: humanSeat,
            myFleet: [],
            revealedFleets: nil)
    }

    var canFire: Bool {
        !state.finished && !botThinking && !paused
            && state.phase == "firing" && state.turn == Self.humanSeat
    }

    // MARK: - Lifecycle

    func restart() {
        humanFleet = []
        botFleet = []
        botThinking = false
        paused = false
        recorded = false
        state = Self.emptyState()
    }

    /// Commit the human's fleet and open firing.
    ///
    /// THE BOT PLACES HERE AND NEVER AGAIN (§11.2). It commits a fleet at match start and lives
    /// with it — materialising ships away from incoming fire would be undetectable cheating.
    func place(_ fleet: [SeaBattleShip]) {
        guard SeaBattleRules.validate(fleet) == nil else { return }
        humanFleet = fleet
        botFleet = bot.placeFleet()

        // The human always fires first in practice. Fixed rather than drawn, because a practice
        // match is restartable at zero cost and losing the first shot to a coin flip is friction
        // with nothing behind it.
        state = SeaBattleState(
            players: state.players,
            phase: "firing",
            turn: Self.humanSeat,
            turnUserId: "you",
            shots: [[], []],
            results: [[], []],
            sunk: [[], []],
            sunkCells: [[], []],
            placed: [true, true],
            fleetSpec: SeaBattle.fleetSpec,
            deadlineAt: nil,
            finished: false,
            winnerUserId: nil,
            endedBy: nil,
            lastShot: nil,
            lastResult: nil,
            seat: Self.humanSeat,
            myFleet: fleet.map { SeaBattleState.Ship(type: $0.type, cells: $0.cells, hits: 0) },
            revealedFleets: nil)
    }

    // MARK: - Firing

    func fire(at cell: Int) {
        guard canFire else { return }
        guard cell >= 0, cell < SeaBattle.cells else { return }
        guard !state.shots[Self.humanSeat].contains(cell) else { return }

        apply(shot: cell, by: Self.humanSeat)
        guard !state.finished else { return }

        // The bot's turn. Delayed on purpose — see SeaBattleBot.thinkingDelay.
        botThinking = true
        let delay = SeaBattleBot.thinkingDelay()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !self.paused, !self.state.finished else { self.botThinking = false; return }
            self.botTurn()
            self.botThinking = false
        }
    }

    private func botTurn() {
        let mine = Self.botSeat
        let target = bot.chooseShot(
            shots: state.shots[mine],
            results: state.results[mine],
            // The outlines of the HUMAN's sunk ships — public information, the same the human
            // sees on their own board.
            sunkCells: state.sunkCells[Self.humanSeat],
            fleetSpec: state.fleetSpec)
        apply(shot: target, by: mine)
    }

    /// Resolve one shot against the target's fleet and rebuild the state.
    private func apply(shot cell: Int, by seat: Int) {
        let targetSeat = 1 - seat
        var fleet = targetSeat == Self.humanSeat ? humanFleet : botFleet

        var shots = state.shots
        var results = state.results
        var sunk = state.sunk
        var sunkCells = state.sunkCells

        var result = 0
        if let idx = fleet.firstIndex(where: { $0.cells.contains(cell) }) {
            fleet[idx].hits += 1
            if fleet[idx].isSunk {
                result = 2
                sunk[targetSeat].append(fleet[idx].type)
                // Once a ship is sunk its squares are public, exactly as the server promotes them
                // out of the secret at the moment of sinking.
                sunkCells[targetSeat].append(contentsOf: fleet[idx].cells)
            } else {
                result = 1
            }
        }

        if targetSeat == Self.humanSeat { humanFleet = fleet } else { botFleet = fleet }

        shots[seat].append(cell)
        results[seat].append(result)

        let hitTotal = fleet.reduce(0) { $0 + $1.hits }
        let won = hitTotal >= SeaBattle.fleetCells
        // ONE SHOT PER TURN — a hit does not grant another, matching the engine (§2.3).
        let nextTurn = won ? nil : targetSeat

        if won && !recorded {
            BotScoreStore.add(level, outcome: seat == Self.humanSeat ? 1 : -1)
            recorded = true
        }

        state = SeaBattleState(
            players: state.players,
            phase: won ? "done" : "firing",
            turn: nextTurn,
            turnUserId: nextTurn.map { state.players[$0] },
            shots: shots,
            results: results,
            sunk: sunk,
            sunkCells: sunkCells,
            placed: [true, true],
            fleetSpec: state.fleetSpec,
            deadlineAt: nil,
            finished: won,
            winnerUserId: won ? state.players[seat] : nil,
            endedBy: won ? "win" : nil,
            lastShot: cell,
            lastResult: result,
            seat: Self.humanSeat,
            myFleet: humanFleet.map {
                SeaBattleState.Ship(type: $0.type, cells: $0.cells, hits: $0.hits)
            },
            // Both fleets go out only once the match is over, exactly as the terminal server
            // frame does — the bot's ships are never in a frame before that.
            revealedFleets: won
                ? [humanFleet.map { SeaBattleState.Ship(type: $0.type, cells: $0.cells, hits: $0.hits) },
                   botFleet.map { SeaBattleState.Ship(type: $0.type, cells: $0.cells, hits: $0.hits) }]
                : nil)
    }

    /// Forfeit. A give-up that costs nothing is just a reset button with extra steps.
    func giveUp() {
        guard !state.finished else { return }
        if !recorded { BotScoreStore.add(level, outcome: -1); recorded = true }
        state = SeaBattleState(
            players: state.players, phase: "done", turn: nil, turnUserId: nil,
            shots: state.shots, results: state.results, sunk: state.sunk,
            sunkCells: state.sunkCells, placed: state.placed, fleetSpec: state.fleetSpec,
            deadlineAt: nil, finished: true, winnerUserId: state.players[Self.botSeat],
            endedBy: "resign", lastShot: state.lastShot, lastResult: state.lastResult,
            seat: Self.humanSeat, myFleet: state.myFleet,
            revealedFleets: [
                humanFleet.map { SeaBattleState.Ship(type: $0.type, cells: $0.cells, hits: $0.hits) },
                botFleet.map { SeaBattleState.Ship(type: $0.type, cells: $0.cells, hits: $0.hits) },
            ])
    }
}
