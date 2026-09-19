import SwiftUI

@main struct CarromCheck {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        var clock: TimeInterval = 1
        func advance(_ game: CarromGame, frames: Int = 100) {
            for _ in 0..<frames {
                clock += 1.0 / 60.0
                game.stepSimulationFrame(currentTime: clock)
            }
        }
        func pocket(_ game: CarromGame, _ types: [CarromPieceType]) {
            game.phase = .inMotion
            for type in types {
                let index = game.world.pieces.firstIndex { $0.type == type && !$0.isPocketed }!
                game.world.pieces[index].isPocketed = true
                game.world.pieces[index].sinkProgress = 1
                game.world.onPiecePocketed?(game.world.pieces[index], 0)
            }
            advance(game, frames: 1)
        }
        let game = CarromGame(isBot: false)
        check(game.world.pieces.count == 20, "Complete starting board")
        check(game.world.pieces.filter { $0.type == .white }.count == 9, "Nine white discs")
        check(game.world.pieces.filter { $0.type == .black }.count == 9, "Nine black discs")
        check(game.isPlacementValid, "Initial striker has free baseline")
        game.fireStrike()
        advance(game, frames: 600)
        check(game.phase != .inMotion, "Break shot settles")
        check(game.world.pieces.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite }, "Finite physics positions")

        game.resetBoard()
        pocket(game, [.striker, .white, .queen])
        check(game.player1Score == 0, "Striker foul returns own piece")
        check(game.queenState == .onBoard, "Queen with striker returns")
        check(!game.world.pieces.first { $0.type == .queen }!.isPocketed, "Queen physically returned")
        advance(game)
        check(game.turn == .player2, "Foul cannot grant extra turn")

        game.resetBoard()
        pocket(game, [.queen])
        check(game.queenState == .pendingCover(by: .player1), "Queen needs cover")
        advance(game)
        check(game.turn == .player1, "Queen grants cover shot")
        pocket(game, [.white])
        check(game.player1Score == 1 && game.queenState == .covered(by: .player1), "Own colour covers queen")

        game.resetBoard()
        pocket(game, [.queen])
        advance(game)
        pocket(game, [.black])
        check(game.queenState == .onBoard && game.player1Score == 0 && game.player2Score == 1, "Opponent colour cannot cover queen; credits opponent")
        let queen = game.world.pieces.first { $0.type == .queen }!
        check(game.world.pieces.filter { $0.type != .queen && !$0.isPocketed }.allSatisfy {
            queen.position.distance(to: $0.position) >= queen.radius + $0.radius
        }, "Returned queen does not overlap rack")

        game.resetBoard()
        pocket(game, [.queen, .white])
        check(game.queenState == .covered(by: .player1), "Same-shot cover")
        game.resetBoard()
        advance(game, frames: 200)
        check(game.turn == .player1 && game.player1Score == 0 && game.phase == .placement, "Reset cancels queued turn work")

        let bot = CarromGame()
        bot.turn = .player2
        let x = bot.baselineNormX
        bot.nudgeBaseline(0.2)
        bot.setShotPower(1)
        bot.fireStrike()
        check(bot.baselineNormX == x && bot.phase == .placement, "Human controls cannot alter bot turn")
        bot.resetBoard()
        pocket(bot, [])
        advance(bot, frames: 95)
        check(bot.turn == .player2, "Bot gets turn after human miss")
        bot.resetBoard()
        advance(bot, frames: 240)
        check(bot.turn == .player1 && bot.phase == .placement, "Restart cancels pending bot strike")
        pocket(bot, [])
        advance(bot, frames: 220)
        check(bot.phase == .inMotion, "Bot completes placement and fires")

        game.resetBoard()
        pocket(game, Array(repeating: .white, count: 9))
        check(game.player1Score == 8 && game.phase != .gameOver(winner: "Player 1"), "Last piece returns while queen uncovered")
        game.resetBoard()
        pocket(game, [.queen] + Array(repeating: .white, count: 9))
        check(game.phase == .gameOver(winner: "Player 1"), "Own colour cleared and queen covered wins")
        game.resetBoard()
        game.queenState = .covered(by: .player2)
        pocket(game, Array(repeating: .black, count: 9))
        check(game.phase == .gameOver(winner: "Player 2"), "Pocketing opponent's last disc awards their win")

        let world = CarromPhysicsWorld()
        world.pieces = [CarromPiece(id: 1, type: .white, position: CGPoint(x: 39, y: 20), velocity: CGVector(dx: 1050, dy: 0), radius: 11.5, mass: 1)]
        for _ in 0..<300 { world.step(dt: 1 / 60) }
        check(world.isSettled && world.pieces[0].isPocketed, "Fast disc captured by pocket cannot become permanently stuck")
        print("Passed \(checks) Carrom physics, rules, bot and restart checks.")
    }
}
