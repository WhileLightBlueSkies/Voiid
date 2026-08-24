//
//  LudoAccessibility.swift
//  Voiid
//
//  Accessibility labels (§17). VoiceOver order is close → help → top pods → die → legal pawns
//  → board summary → bottom pods → chat; the screen composes in exactly that order. Color is
//  NEVER the only carrier: the border hue alone cannot be spoken, so the board container states
//  the active seat and a pawn summary.
//

import Foundation

enum LudoAccessibility {

    static func boardSummary(_ state: LudoGameStateV2) -> String {
        let players = state.seats.count
        let activeColor = state.turn.map { colorName($0.seat) } ?? "no active"
        var summary = "Ludo board, \(players) players, \(activeColor) action"
        if let viewer = state.viewerSeat {
            let home = state.tokens[ludoSafe: viewer]?.filter { $0 == LudoRules.finished }.count ?? 0
            summary += ", you have \(home) of 4 pawns home"
        }
        return summary
    }

    /// "Safe track cell 8, row 9 column 3, occupied by one red pawn" (§17).
    static func cellLabel(_ node: LudoBoardGeometry.CellNode, state: LudoGameStateV2) -> String {
        let rowCol = ", row \(node.y + 1) column \(node.x + 1)"
        switch node.role {
        case .sharedTrack:
            var s = node.isSafe ? "Safe track cell \(node.trackIndex ?? -1)"
                                : "Track cell \(node.trackIndex ?? -1)"
            s += rowCol
            if let occupants = occupants(state, trackIndex: node.trackIndex ?? -1) {
                s += ", \(occupants)"
            }
            return s
        case .homeLane:
            return "\(colorName(node.seat ?? 0)) home lane, step \((node.homeStep ?? 0) + 1) of 5\(rowCol)"
        case .yardPocket:
            if let seat = node.seat {
                let slots = LudoBoardGeometry.yardSlots[seat % 4]
                if let pawn = slots.firstIndex(where: { $0.0 == node.x && $0.1 == node.y }) {
                    return "Yard slot \(pawn + 1)\(rowCol)"
                }
            }
            return "Yard\(rowCol)"
        case .yard:
            let owner = node.seat.map { "\(colorName($0)) yard" } ?? "Yard"
            return owner + rowCol
        case .center:
            return "Center finish\(rowCol)"
        case .unused:
            return ""
        }
    }

    private static func occupants(_ state: LudoGameStateV2, trackIndex: Int) -> String? {
        var count = 0
        var color = ""
        for (seat, row) in state.tokens.enumerated() where row.contains(trackIndex) {
            count += 1
            color = colorName(seat)
        }
        switch count {
        case 0: return nil
        case 1: return "occupied by one \(color) pawn"
        default: return "occupied by \(count) pawns"
        }
    }

    /// Pawn label per §17. Legal pawns add the button trait plus the movement hint upstream.
    static func pawnLabel(state: LudoGameStateV2, seat: Int, pawn: Int, displayName: String) -> String {
        let pos = state.tokens[ludoSafe: seat]?[ludoSafe: pawn] ?? LudoRules.yard
        let where_: String
        switch pos {
        case LudoRules.yard: where_ = "yard"
        case LudoRules.finished: where_ = "finished"
        case LudoRules.homeLaneBase..<(LudoRules.homeLaneBase + LudoRules.homeLaneCount):
            where_ = "home lane step \(pos - LudoRules.homeLaneBase + 1)"
        default: where_ = "track cell \(pos)"
        }
        return "\(displayName), \(colorName(seat)) pawn \(pawn + 1), \(where_)"
    }

    /// Legal pawns add the hint "Moves {value} spaces to {destination description}" (§17).
    static func legalHint(state: LudoGameStateV2, token: Int) -> String? {
        guard let turn = state.turn, let value = turn.value else { return nil }
        guard let from = state.tokens[ludoSafe: turn.seat]?[ludoSafe: token] else { return nil }

        let dest: Int?
        if from == LudoRules.yard {
            dest = value == 6 ? LudoRules.startIndex(turn.seat) : nil
        } else if from >= LudoRules.homeLaneBase,
                  from < LudoRules.homeLaneBase + LudoRules.homeLaneCount {
            let sum = (from - LudoRules.homeLaneBase) + value
            if sum == LudoRules.homeLaneCount { dest = LudoRules.finished }
            else if sum > LudoRules.homeLaneCount { dest = nil }
            else { dest = LudoRules.homeLaneBase + sum }
        } else {
            let travelled = LudoRules.progressOf(from, seat: turn.seat)
            let total = travelled + value
            if total == LudoRules.trackCount + LudoRules.homeLaneCount { dest = LudoRules.finished }
            else if total > LudoRules.trackCount + LudoRules.homeLaneCount { dest = nil }
            else if total >= LudoRules.trackCount { dest = LudoRules.homeLaneBase + (total - LudoRules.trackCount) }
            else { dest = (LudoRules.startIndex(turn.seat) + total) % LudoRules.trackCount }
        }

        guard let d = dest else { return nil }
        let description: String
        if d == LudoRules.finished { description = "home" }
        else if d >= LudoRules.homeLaneBase { description = "home lane step \(d - LudoRules.homeLaneBase + 1)" }
        else { description = "track cell \(d)" }
        return "Moves \(value) spaces to \(description)"
    }

    /// Die at rest vs during animation announce ONLY settled results (§17). Intermediate faces
    /// are never announced.
    static func dieLabel(state: LudoGameStateV2, displayedValue: Int) -> String {
        guard !state.isFinished, let turn = state.turn else { return "Die" }
        let name = state.seats.first { $0.seat == turn.seat }?.displayName ?? ""
        if turn.value == nil && turn.phase == "awaitingRoll" && state.viewerSeat == turn.seat {
            return "Die, double tap to roll"
        }
        return "Die, \(name) showing \(displayedValue)"
    }

    /// During animation announce only the settled result — never intermediate faces (§17).
    static func rollAnnouncement(name: String, value: Int) -> String {
        "\(name) rolled \(value)"
    }

    static func colorName(_ seat: Int) -> String {
        ["red", "green", "yellow", "blue"][seat % 4]
    }
}


