//
//  CarromGame.swift
//  Voiid Ui
//
//  Main observable game controller for Carrom.
//  Coordinates physics steps, turn lifecycle, gesture handling, rules evaluation,
//  haptic feedback, and bot execution.
//

import SwiftUI
import Combine

enum CarromPhase: Equatable {
    case placement
    case aiming
    case inMotion
    case evaluating
    case gameOver(winner: String)
}

enum CarromBannerType {
    case info, success, foul
}

struct CarromBanner: Equatable {
    let text: String
    let type: CarromBannerType
}

@MainActor
final class CarromGame: ObservableObject {

    // MARK: - Published State

    @Published var mode: CarromGameMode = .classic
    @Published var isBot: Bool = true
    @Published var turn: CarromTurn = .player1
    @Published var phase: CarromPhase = .placement

    @Published var player1Score: Int = 0
    @Published var player2Score: Int = 0
    @Published var player1Pieces: [CarromPieceType] = []
    @Published var player2Pieces: [CarromPieceType] = []

    @Published var baselineNormX: CGFloat = 0.5
    @Published var aimDirection: CGVector = CGVector(dx: 0, dy: -1) // Shooting UP by default
    @Published var shotPower: CGFloat = 0.0 // 0.0 ... 1.0
    @Published var isDraggingAim: Bool = false
    @Published var isPlacementValid: Bool = true

    @Published var aimResult: CarromAimResult? = nil
    @Published var banner: CarromBanner? = nil
    @Published private(set) var animationTick: UInt = 0

    var canControl: Bool {
        (phase == .placement || phase == .aiming) && (turn == .player1 || !isBot)
    }

    private var pendingAction: (delay: TimeInterval, action: () -> Void)?

    // Delays advance only while the screen is active. Resetting drops old bot/turn work.
    private func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        pendingAction = (delay, action)
    }

    func pauseClock() { lastFrameTime = 0 }

    // Queen Tracking
    @Published var queenState: QueenState = .onBoard
    enum QueenState: Equatable {
        case onBoard
        case pendingCover(by: CarromTurn)
        case covered(by: CarromTurn)
    }

    // Win condition
    let targetScore: Int = 9

    // MARK: - Internal Physics Engine

    let world = CarromPhysicsWorld()
    private var pocketedThisTurn: [CarromPiece] = []
    private var lastFrameTime: TimeInterval = 0

    init(mode: CarromGameMode = .classic, isBot: Bool = true) {
        self.mode = mode
        self.isBot = isBot
        setupWorldCallbacks()
        resetBoard()
    }

    // MARK: - World Setup & Callbacks

    private func setupWorldCallbacks() {
        world.onPieceCollision = { impulse in
            if impulse > 18 {
                Haptics.rigid()
            } else {
                Haptics.soft()
            }
        }

        world.onCushionBounce = {
            Haptics.soft()
        }

        world.onPiecePocketed = { [weak self] piece, _ in
            guard let self else { return }
            self.pocketedThisTurn.append(piece)

            if piece.type == .striker {
                Haptics.error()
            } else if piece.type == .queen {
                Haptics.boundary()
            } else {
                Haptics.success()
            }
        }
    }

    // MARK: - Board Setup

    func resetBoard() {
        pendingAction = nil
        lastFrameTime = 0
        shotPower = 0.70
        isDraggingAim = false
        aimResult = nil
        world.pieces = CarromEngine.generateStartingPieces()
        player1Score = 0
        player2Score = 0
        player1Pieces.removeAll()
        player2Pieces.removeAll()
        turn = .player1
        queenState = .onBoard
        baselineNormX = 0.5
        phase = .placement
        pocketedThisTurn.removeAll()
        banner = nil

        updateStrikerPlacement()
    }

    // MARK: - Baseline Positioning

    func updateBaselineSlider(_ value: CGFloat) {
        guard canControl else { return }
        guard phase == .placement || phase == .aiming else { return }
        baselineNormX = min(max(value, 0.0), 1.0)
        updateStrikerPlacement()
    }

    private func updateStrikerPlacement() {
        let pos = CarromEngine.baselinePosition(for: turn, normalizedX: baselineNormX)
        if let strikerIndex = world.pieces.firstIndex(where: { $0.type == .striker }) {
            world.pieces[strikerIndex].position = pos
            world.pieces[strikerIndex].velocity = .zero
            world.pieces[strikerIndex].isPocketed = false
            world.pieces[strikerIndex].sinkProgress = 0
            world.pieces[strikerIndex].pocketIndex = nil
        }
        isPlacementValid = CarromEngine.isStrikerPlacementValid(at: pos, pieces: world.pieces)

        // Default aim direction
        let defaultAimY: CGFloat = (turn == .player1) ? -1.0 : 1.0
        aimDirection = CGVector(dx: 0, dy: defaultAimY)
        updateAimGuide()
    }

    // MARK: - Aim & Strike

    func setAimPoint(_ targetPt: CGPoint) {
        guard canControl else { return }
        guard (phase == .placement || phase == .aiming), isPlacementValid else { return }
        guard let striker = world.pieces.first(where: { $0.type == .striker }) else { return }

        let toTarget = (targetPt - striker.position).vector
        if toTarget.length > 12 {
            // Check that it's aiming forward (away from baseline)
            let isForward = (turn == .player1) ? (toTarget.dy < 10) : (toTarget.dy > -10)
            if isForward {
                aimDirection = toTarget.normalized()
                if shotPower <= 0.05 {
                    shotPower = 0.70 // Default confident strike power
                }
                phase = .aiming
                updateAimGuide()
            }
        }
    }

    func setShotPower(_ power: CGFloat) {
        guard canControl else { return }
        shotPower = min(max(power, 0.1), 1.0)
        if phase == .placement && isPlacementValid {
            phase = .aiming
            updateAimGuide()
        }
    }

    func nudgeBaseline(_ delta: CGFloat) {
        guard canControl else { return }
        guard phase == .placement || phase == .aiming else { return }
        baselineNormX = min(max(baselineNormX + delta, 0.0), 1.0)
        updateStrikerPlacement()
        Haptics.soft()
    }

    func updateAimGesture(dragOffset: CGSize) {
        guard canControl else { return }
        guard phase == .placement || phase == .aiming, isPlacementValid else { return }
        phase = .aiming
        isDraggingAim = true

        // Slingshot control: dragging OPPOSITE to shoot direction
        let pullVector = CGVector(dx: -dragOffset.width, dy: -dragOffset.height)
        let pullLength = pullVector.length

        if pullLength > 10 {
            aimDirection = pullVector.normalized()
            shotPower = min(max(pullLength / 110.0, 0.20), 1.0)
        }

        updateAimGuide()
    }

    func fireStrike(power: CGFloat? = nil) {
        guard canControl else { return }
        guard (phase == .aiming || phase == .placement), isPlacementValid else { return }
        let p = power ?? (shotPower > 0.08 ? shotPower : 0.70)
        guard let strikerIndex = world.pieces.firstIndex(where: { $0.type == .striker }) else { return }

        // Calibrated carrom impulse velocities (420 to 1050 pt/s)
        let minSpeed: CGFloat = 420.0
        let maxSpeed: CGFloat = 1050.0
        let speed = minSpeed + (p * (maxSpeed - minSpeed))
        world.pieces[strikerIndex].velocity = aimDirection.normalized() * speed

        lastFrameTime = 0 // Reset time anchor so first simulation tick has clean dt
        Haptics.boundary()
        phase = .inMotion
        pocketedThisTurn.removeAll()
        aimResult = nil
        shotPower = 0
        isDraggingAim = false
    }

    func releaseStrike() {
        guard phase == .aiming || phase == .placement else { return }
        isDraggingAim = false

        guard isPlacementValid, shotPower > 0.12 else {
            phase = .placement
            shotPower = 0
            aimResult = nil
            return
        }

        guard let strikerIndex = world.pieces.firstIndex(where: { $0.type == .striker }) else { return }

        let minSpeed: CGFloat = 420.0
        let maxSpeed: CGFloat = 1050.0
        let speed = minSpeed + (shotPower * (maxSpeed - minSpeed))
        world.pieces[strikerIndex].velocity = aimDirection.normalized() * speed

        lastFrameTime = 0 // Reset time anchor
        Haptics.boundary()
        phase = .inMotion
        pocketedThisTurn.removeAll()
        aimResult = nil
        shotPower = 0
    }

    func updateAimGuide() {
        guard let striker = world.pieces.first(where: { $0.type == .striker }) else { return }
        aimResult = world.predictAim(from: striker.position, direction: aimDirection)
    }

    // MARK: - Simulation Loop Step

    func stepSimulationFrame(currentTime: TimeInterval) {
        let dt: CGFloat
        if lastFrameTime == 0 {
            dt = 1.0 / 60.0
        } else {
            let elapsed = currentTime - lastFrameTime
            dt = CGFloat(min(max(elapsed, 0.001), 0.033))
        }
        lastFrameTime = currentTime

        if let pending = pendingAction {
            if pending.delay <= Double(dt) {
                pendingAction = nil
                pending.action()
            } else {
                pendingAction = (pending.delay - Double(dt), pending.action)
            }
        }
        guard phase == .inMotion else { return }
        world.step(dt: dt)
        animationTick &+= 1

        if world.isSettled {
            lastFrameTime = 0
            evaluateTurn()
        }
    }

    // MARK: - Turn Evaluation & Rules

    private func evaluateTurn() {
        phase = .evaluating
        let ownColour: CarromPieceType = turn == .player1 ? .white : .black
        let strikerPocketed = pocketedThisTurn.contains { $0.type == .striker }
        let ownMen = pocketedThisTurn.filter { $0.type == ownColour }
        let hasQueen = pocketedThisTurn.contains { $0.type == .queen }
        var extraTurn = !ownMen.isEmpty && !strikerPocketed

        if hasQueen && !strikerPocketed {
            if !ownMen.isEmpty {
                queenState = .covered(by: turn)
                banner = CarromBanner(text: "Queen covered!", type: .success)
            } else {
                queenState = .pendingCover(by: turn)
                banner = CarromBanner(text: "Pocket your colour next to cover the queen", type: .info)
            }
            extraTurn = true
        } else if case .pendingCover(let claimant) = queenState, claimant == turn {
            if !strikerPocketed && !ownMen.isEmpty {
                queenState = .covered(by: turn)
                banner = CarromBanner(text: "Queen covered!", type: .success)
            } else {
                returnQueenToCenter()
                queenState = .onBoard
                banner = CarromBanner(text: "Cover missed — queen returned", type: .foul)
            }
        }

        if strikerPocketed {
            if hasQueen {
                returnQueenToCenter()
                queenState = .onBoard
            }
            if let penalty = world.pieces.firstIndex(where: { $0.type == ownColour && $0.isPocketed }) {
                returnPieceToCenter(at: penalty)
            }
            extraTurn = false
            banner = CarromBanner(text: "Striker foul — turn lost", type: .foul)
        }

        // The queen must be covered before either colour can clear the board.
        if case .covered = queenState {
            // A covered queen stays off the board for either player's finish.
        } else {
            for colour in [CarromPieceType.white, .black] {
                if !world.pieces.contains(where: { $0.type == colour && !$0.isPocketed }),
                   let last = world.pieces.firstIndex(where: { $0.type == colour && $0.isPocketed }) {
                    returnPieceToCenter(at: last)
                    if colour == ownColour { extraTurn = false }
                    banner = CarromBanner(text: "Cover the queen before your last piece", type: .info)
                }
            }
        }

        // Colours belong to players, including pieces accidentally pocketed by their opponent.
        player1Pieces = world.pieces.filter { $0.type == .white && $0.isPocketed }.map(\.type)
        player2Pieces = world.pieces.filter { $0.type == .black && $0.isPocketed }.map(\.type)
        player1Score = player1Pieces.count
        player2Score = player2Pieces.count
        let opponentCleared = turn == .player1 ? player2Score == targetScore : player1Score == targetScore
        let ownCleared = turn == .player1 ? player1Score == targetScore : player2Score == targetScore
        if opponentCleared || ownCleared {
            let winner = opponentCleared ? turn.opposite : turn
            phase = .gameOver(winner: winner == .player1 ? (isBot ? "You" : "Player 1") : (isBot ? "Carrom Bot" : "Player 2"))
            return
        }

        schedule(after: 1.2) { [weak self] in
            guard let self else { return }
            if !extraTurn { self.turn = self.turn.opposite }
            self.phase = .placement
            self.banner = nil
            self.shotPower = 0.70
            self.updateStrikerPlacement()
            if self.turn == .player2 && self.isBot { self.scheduleBotShot() }
        }
    }

    private func returnQueenToCenter() {
        if let idx = world.pieces.firstIndex(where: { $0.type == .queen }) {
            returnPieceToCenter(at: idx)
        }
    }

    private func returnPieceToCenter(at idx: Int) {
        let center = CGPoint(x: CarromTheme.surfaceSize / 2, y: CarromTheme.surfaceSize / 2)
        // Return near the centre without overlapping another disc.
        let otherPieces = world.pieces.filter { !$0.isPocketed && $0.id != world.pieces[idx].id }
        var returnPosition = center
        search: for ring in 0...12 {
            for slot in 0..<36 {
                let angle = CGFloat(slot) * .pi / 18
                let candidate = center + CGPoint(x: cos(angle), y: sin(angle)) * CGFloat(ring * 12)
                if otherPieces.allSatisfy({ candidate.distance(to: $0.position) >= $0.radius + CarromTheme.pieceRadius + 1 }) {
                    returnPosition = candidate
                    break search
                }
            }
        }
        world.pieces[idx].position = returnPosition
        world.pieces[idx].velocity = .zero
        world.pieces[idx].isPocketed = false
        world.pieces[idx].sinkProgress = 0
        world.pieces[idx].pocketIndex = nil
    }

    // MARK: - Bot Turn Routine

    private func scheduleBotShot() {
        guard phase == .placement, turn == .player2, isBot else { return }

        // Natural pause for realism
        schedule(after: 0.8) { [weak self] in
            guard let self, self.turn == .player2, self.phase == .placement else { return }

            let botShot = CarromEngine.calculateBotShot(pieces: self.world.pieces)

            // 1. Move slider to bot position
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                self.baselineNormX = botShot.baselineX
                self.updateStrikerPlacement()
            }

            // If no free baseline exists, end this turn instead of leaving the bot stuck.
            guard self.isPlacementValid else {
                self.banner = CarromBanner(text: "Baseline blocked — turn passed", type: .info)
                self.turn = .player1
                self.updateStrikerPlacement()
                return
            }

            // 2. Aim and draw trajectory
            self.schedule(after: 0.6) { [weak self] in
                guard let self, self.turn == .player2 else { return }
                self.aimDirection = botShot.aimDirection
                self.shotPower = min(max((botShot.power - 420.0) / 630.0, 0.20), 1.0)
                self.phase = .aiming
                self.updateAimGuide()

                // 3. Release Strike
                self.schedule(after: 0.5) { [weak self] in
                    guard let self, self.turn == .player2 else { return }
                    self.releaseStrike()
                }
            }
        }
    }
}
