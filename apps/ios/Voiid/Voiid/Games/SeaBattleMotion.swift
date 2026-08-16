//
//  SeaBattleMotion.swift
//  Voiid
//
//  Shell travel, sunk reveal and hit shake (docs/games/future/SEA_BATTLE.md §9).
//
//  THE 380 ms SHELL TRAVEL IS LOAD-BEARING, NOT DECORATION.
//
//  It is the window the server's answer arrives in, which is what lets the game feel instant
//  while being fully round-tripped. It is also the suspense: the beat between committing and
//  knowing is the emotional content of a turn.
//
//  AND IT RUNS ITS FULL LENGTH EVEN WHEN THE FRAME ARRIVES IN 40 ms. The result is revealed at
//  the END of the travel either way, so the game feels identical on a fast and a slow
//  connection. That is a deliberate trade of 340 ms of latency for consistency — and it is the
//  opposite of the choice Snake makes, correctly, for a game where reaction time is the skill.
//
//  Mirrors Android `SeaBattleMotion.kt`.
//

import Foundation
import Combine

@MainActor
final class SeaBattleMotion: ObservableObject {
    /// 0...1 through the shell's fall. The grid eases this itself.
    @Published private(set) var shellProgress: Double = 0
    /// Cells of the ship currently being revealed, added one at a time.
    @Published private(set) var sunkReveal: [Int] = []
    /// A 2 px nudge on a hit. Two pixels, hit only, and off under reduce-motion (§9) —
    /// CROSS_CUTTING.md §13 records that Snake shipped hitstop and shake with no opt-out, and
    /// this is the game deliberately not repeating it.
    @Published private(set) var shake: CGFloat = 0

    static let travel: TimeInterval = 0.38
    /// A sink is a hit PLUS a consequence, and the consequence has to land second or the two
    /// read as one event — the same 120 ms trick as the crowd behind a cricket wicket.
    static let sinkHold: TimeInterval = 0.12
    static let perCell: TimeInterval = 0.06

    private var shellTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?

    /// Run the shell. `onLand` fires at the end, which is when the result is revealed.
    func fire(reduceMotion: Bool, onLand: @escaping () -> Void) {
        shellTask?.cancel()
        guard !reduceMotion else {
            shellProgress = 0
            onLand()
            return
        }
        shellTask = Task { @MainActor in
            let steps = 24
            for i in 0...steps {
                self.shellProgress = Double(i) / Double(steps)
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.travel / Double(steps) * 1_000_000_000))
                if Task.isCancelled { return }
            }
            self.shellProgress = 0
            onLand()
        }
    }

    /// Draw a sunk ship's outline in along its hull, after a hold.
    func revealSunk(_ cells: [Int], reduceMotion: Bool) {
        revealTask?.cancel()
        guard !reduceMotion, !cells.isEmpty else { return }
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.sinkHold * 1_000_000_000))
            for cell in cells {
                if Task.isCancelled { return }
                self.sunkReveal.append(cell)
                try? await Task.sleep(nanoseconds: UInt64(Self.perCell * 1_000_000_000))
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.sunkReveal.removeAll()
        }
    }

    /// 2 px, hit only.
    func hitShake(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        Task { @MainActor in
            for offset in [CGFloat(2), -2, 1.2, -0.8, 0] {
                self.shake = offset
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            self.shake = 0
        }
    }

    func cancel() {
        shellTask?.cancel()
        revealTask?.cancel()
        shellProgress = 0
        sunkReveal.removeAll()
        shake = 0
    }
}
