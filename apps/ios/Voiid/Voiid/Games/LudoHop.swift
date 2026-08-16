//
//  LudoHop.swift
//  Voiid
//
//  The hop chain (docs/games/future/LUDO.md §9).
//
//  THE HOP IS THE MOST IMPORTANT ANIMATION IN THE GAME AND IT MUST NOT BE OPTIMISED AWAY.
//
//  A token that slides or teleports to its destination discards the one piece of information the
//  movement carries: HOW FAR. Hopping square by square shows the count, which is what makes a 6
//  feel different from a 2 — and in a 4-player game, where you spend three quarters of your time
//  watching, it is what makes other people's turns worth watching at all.
//
//  WHY THIS IS A SEPARATE DRIVER RATHER THAN AN ANIMATION MODIFIER. SwiftUI animates a value
//  from A to B; it has no notion of "visit these seven squares in order". So this walks the
//  server's own path and republishes an intermediate position per step, and the view animates
//  between consecutive steps as it already does. The path comes from the same movement maths the
//  engine uses, so the token traces exactly the squares the rules say it crossed.
//
//  Mirrors Android `LudoHop.kt`.
//

import Foundation
import Combine

@MainActor
final class LudoHop: ObservableObject {
    /// Position overrides while a hop is in flight, keyed "seat-token".
    ///
    /// The board reads through this, so a token mid-hop draws at its intermediate square while
    /// every other token draws from the authoritative state. An empty dictionary means nothing
    /// is animating and the board is showing the truth.
    @Published private(set) var overrides: [String: Int] = [:]

    /// ~110 ms per square (§9). Fast enough not to be a wait, slow enough to be countable.
    static let perSquare: TimeInterval = 0.11

    /// TOTAL TRAVEL IS CAPPED AT 900 ms (§9). Six squares is ~660 ms, so this only bites on a
    /// long home-column run. Watching is good; waiting is not.
    static let maxTotal: TimeInterval = 0.9

    private var task: Task<Void, Never>?

    static func key(seat: Int, token: Int) -> String { "\(seat)-\(token)" }

    /// Animate one move across every square it crosses.
    ///
    /// `reduceMotion` collapses the chain to nothing — but note what §9 asks for there: the
    /// reduced version must STILL COMMUNICATE DISTANCE, because a token that teleports loses the
    /// count. That is why the caller shows a distance readout instead; this simply does not run.
    func play(
        seat: Int,
        token: Int,
        from: Int,
        to: Int,
        die: Int,
        reduceMotion: Bool,
        onStep: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        task?.cancel()

        let squares = Self.path(from: from, die: die, seat: seat, to: to)
        // A yard entry crosses nothing — the token is placed on the entry square — and a
        // single-square move is already its own destination. Neither is worth a chain.
        guard !reduceMotion, squares.count > 1 else {
            onFinish()
            return
        }

        let k = Self.key(seat: seat, token: token)
        // Squeeze the per-step interval if the run is long enough to exceed the cap.
        let step = min(Self.perSquare, Self.maxTotal / Double(squares.count))

        task = Task { @MainActor in
            for square in squares.dropLast() {
                self.overrides[k] = square
                onStep()
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                if Task.isCancelled { break }
            }
            // Clear the override rather than setting the final square: the authoritative state
            // already holds it, and leaving an override behind would freeze the token there if
            // the next frame moved it.
            self.overrides.removeValue(forKey: k)
            onFinish()
        }
    }

    /// Interrupt everything — a tap-to-skip, or leaving the screen.
    ///
    /// §9 asks that a tap skip to the end. A player who has seen the count does not need to
    /// watch the rest of it.
    func skip() {
        task?.cancel()
        overrides.removeAll()
    }

    /// The squares a move crosses, excluding the origin and including the destination.
    ///
    /// The same movement rule as `backend/games/src/engine/ludo/board.ts`. A mirror, used only to
    /// decide what to DRAW — the destination itself always comes from the server.
    static func path(from: Int, die: Int, seat: Int, to: Int) -> [Int] {
        if Ludo.inYard(from) { return [to] }
        var squares: [Int] = []
        for step in 1...max(die, 1) {
            guard let at = destination(from, step, seat) else { break }
            squares.append(at)
        }
        // Trust the server's destination over the mirror's: if the two ever disagree, the token
        // must still finish where the rules say it did.
        if squares.last != to { squares.append(to) }
        return squares
    }

    private static func destination(_ pos: Int, _ die: Int, _ seat: Int) -> Int? {
        if Ludo.isHome(pos) { return nil }
        if Ludo.inYard(pos) { return die == 6 ? Ludo.entrySquare(seat) : nil }
        if Ludo.inColumn(pos) {
            let step = pos - Ludo.columnBase + die
            if step == Ludo.column { return Ludo.home }
            if step > Ludo.column { return nil }
            return Ludo.columnBase + step
        }
        let travelled = (pos - Ludo.entrySquare(seat) + Ludo.track) % Ludo.track
        let next = travelled + die
        if next == Ludo.track + Ludo.column { return Ludo.home }
        if next > Ludo.track + Ludo.column { return nil }
        if next >= Ludo.track { return Ludo.columnBase + (next - Ludo.track) }
        return (Ludo.entrySquare(seat) + next) % Ludo.track
    }
}
