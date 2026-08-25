//
//  LudoModels.swift
//  Voiid
//
//  Wire/state model for Ludo schema v3 (LUDO_GAME_SPEC.md §5–§6).
//
//  Type names mirror backend/games/src/engine/ludo/types.ts normatively; only casing differs.
//  THE CLIENT IS A RENDERER: it never decides legality — the frame's `legalTokenIds` is the one
//  answer to "what can this seat do", computed server-side for validation, auto-play, timeout
//  and this highlight alike.
//
//  NOTE WHAT IS ABSENT AND WHY: no raw user ids anywhere. `seatID` is match-scoped and opaque;
//  `displayName` is a per-recipient projection decided server-side (§11.2) — a client must
//  never RECEIVE an unauthorized real username and then hide it locally.
//

import Foundation

enum LudoRules {
    static let schemaVersion = 3
    static let rulesVersion = "ludo-classic-2"

    static let trackCount = 52
    static let homeLaneCount = 5
    static let tokensPerSeat = 4

    static let yard = -1
    static let homeLaneBase = 100
    static let finished = 200

    /// §13: the per-decision server clock. The ring is display-only; a paused app extends nothing.
    static let turnWindowMs: Double = 30_000
    /// §12.3 serialized sequence: border sweep 0–360 ms, die relocation + pips 360–480 ms.
    static let transitionMs: Double = 480
    /// Die roll choreography total (§14.3).
    static let rollTotalMs: Double = 940

    static func hopMs(_ cells: Int) -> Double { cells == 0 ? 0 : 120 + 92 * Double(cells - 1) }
    static let captureExtraMs: Double = 480
    static let finishExtraMs: Double = 550

    static let safeIndices: Set<Int> = [0, 8, 13, 21, 26, 34, 39, 47]
    static let entryIndices: Set<Int> = [0, 13, 26, 39]
    static let starIndices: Set<Int> = [8, 21, 34, 47]
    static let approachIndices: [Int] = [50, 11, 24, 37]

    static let startIndices = [0, 13, 26, 39]
    static func startIndex(_ seat: Int) -> Int { startIndices[seat % 4] }

    static func progressOf(_ absolute: Int, seat: Int) -> Int {
        (absolute - startIndex(seat) + trackCount) % trackCount
    }
}

enum LudoSeatColor: Int, CaseIterable {
    case red = 0, green = 1, yellow = 2, blue = 3
    var name: String {
        switch self {
        case .red: return "red"
        case .green: return "green"
        case .yellow: return "yellow"
        case .blue: return "blue"
        }
    }
}

struct LudoTurnView {
    let seat: Int
    let serial: Int
    let phase: String            // "awaitingRoll" | "awaitingMove" | "none"
    let opensAt: Double          // epoch ms
    let deadlineAt: Double?      // epoch ms; nil for bots
    let botActionAt: Double?
    let sixStreak: Int
    let rollId: String?
    let value: Int?
    let legalMoves: [LudoLegalMove]
    let automated: Bool
    var legalTokenIds: [Int] { legalMoves.map(\.tokenId) }
}

struct LudoLegalMove {
    let tokenId: Int
    let to: Int
    let path: [Int]
    let capture: (seat: Int, tokenId: Int)?
    let isSafe: Bool
}

struct LudoActionMove {
    struct CapturedPawn { let seat: Int; let tokenId: Int; let from: Int; let to: Int }
    let tokenId: Int
    let from: Int
    let to: Int
    let path: [Int]
    let captured: CapturedPawn?
}

struct LudoAction {
    struct RollInfo { let rollId: String; let value: Int; let auto: Bool }
    let id: String
    let type: String             // turnChanged|roll|move|autoTurn|capture|drop|end
    let committedAt: Double
    let presentationEndsAt: Double
    let actorSeat: Int
    let fromSeat: Int?
    let roll: RollInfo?
    let move: LudoActionMove?
}

struct LudoSeatViewV2 {
    let seat: Int
    let seatId: String
    let color: LudoSeatColor
    let displayName: String
    let controller: String       // human|bot
    let botMarker: String?
    let botDifficulty: String?
    let participation: String    // waiting|active|winner
    let connection: String       // connected|disconnected
    let timeoutStreak: Int
    let finishedPawns: Int
    let captures: Int
    var isBot: Bool { controller == "bot" }
}

/// One authoritative frame, applied in ONE transaction so a refresh never flashes an empty
/// board (§9).
struct LudoGameStateV2 {
    let schemaVersion: Int
    let rulesVersion: String
    let mode: String             // "duel" | "four"
    let status: String           // waiting|active|finished|abandoned
    let serverNow: Double        // epoch ms of emission; drives the smoothed clock offset
    let viewerSeat: Int?
    let viewerRole: String
    let seats: [LudoSeatViewV2]
    let tokensPerSeat: Int
    let tokens: [[Int]]
    let turn: LudoTurnView?
    let lastAction: LudoAction?
    let winnerSeat: Int?
    let endReason: String?
    let seedCommitment: String?
    let seq: Int

    var isFinished: Bool { status == "finished" || status == "abandoned" }
    var isActive: Bool { status == "active" }
    func seat(bySeat seat: Int) -> LudoSeatViewV2? { seats.first { $0.seat == seat } }
    func token(seat: Int, pawn: Int) -> Int {
        guard seat < tokens.count else { return LudoRules.yard }
        guard pawn < tokens[seat].count else { return LudoRules.yard }
        return tokens[seat][pawn]
    }
}

enum LudoWireParser {
    /// Parse the per-recipient `ludoV3` payload (§7.2). Never sees a raw user id.
    static func parse(seq: Int, payload: [String: Any]) -> LudoGameStateV2? {
        guard let v2 = payload["ludoV3"] as? [String: Any] else { return nil }
        guard (v2["schemaVersion"] as? Int) == LudoRules.schemaVersion else { return nil }
        guard let rawSeats = v2["seats"] as? [[String: Any]] else { return nil }
        guard let rawTokens = v2["tokens"] as? [[Int]] else { return nil }

        let seats: [LudoSeatViewV2] = rawSeats.compactMap { s in
            guard let seat = s["seat"] as? Int else { return nil }
            let colorName = s["color"] as? String ?? "red"
            let color = LudoSeatColor(rawValue: seat) ?? .red
            _ = colorName
            return LudoSeatViewV2(
                seat: seat,
                seatId: s["seatId"] as? String ?? "",
                color: LudoSeatColor(rawValue: seat) ?? .red,
                displayName: s["displayName"] as? String ?? "",
                controller: s["controller"] as? String ?? "human",
                botMarker: s["botMarker"] as? String,
                botDifficulty: s["botDifficulty"] as? String,
                participation: s["participation"] as? String ?? "waiting",
                connection: s["connection"] as? String ?? "disconnected",
                timeoutStreak: s["timeoutStreak"] as? Int ?? 0,
                finishedPawns: s["finishedPawns"] as? Int ?? 0,
                captures: s["captures"] as? Int ?? 0)
        }

        let turn: LudoTurnView? = (v2["turn"] as? [String: Any]).flatMap { t in
            guard let seat = t["seat"] as? Int else { return nil }
            let legalMoves: [LudoLegalMove] = (t["legalMoves"] as? [[String: Any]] ?? []).compactMap { move in
                guard let tokenId = move["tokenId"] as? Int, let to = move["to"] as? Int else { return nil }
                let capture = (move["capture"] as? [String: Any]).flatMap { c -> (Int, Int)? in
                    guard let seat = c["seat"] as? Int, let pawn = c["tokenId"] as? Int else { return nil }
                    return (seat, pawn)
                }
                return LudoLegalMove(tokenId: tokenId, to: to, path: move["path"] as? [Int] ?? [],
                                     capture: capture, isSafe: move["isSafe"] as? Bool ?? false)
            }
            return LudoTurnView(
                seat: seat,
                serial: t["serial"] as? Int ?? 0,
                phase: t["phase"] as? String ?? "awaitingRoll",
                opensAt: t["opensAt"] as? Double ?? 0,
                deadlineAt: t["deadlineAt"] as? Double,
                botActionAt: t["botActionAt"] as? Double,
                sixStreak: t["sixStreak"] as? Int ?? 0,
                rollId: t["rollId"] as? String,
                value: t["value"] as? Int,
                legalMoves: legalMoves,
                automated: t["automated"] as? Bool ?? false)
        }

        let lastAction: LudoAction? = (v2["lastAction"] as? [String: Any]).flatMap { a in
            guard let id = a["id"] as? String else { return nil }
            let move: LudoActionMove? = (a["move"] as? [String: Any]).flatMap { m in
                guard let tokenId = m["tokenId"] as? Int else { return nil }
                let captured: LudoActionMove.CapturedPawn? = (m["captured"] as? [String: Any]).flatMap { c in
                    guard let cs = c["seat"] as? Int else { return nil }
                    return LudoActionMove.CapturedPawn(
                        seat: cs,
                        tokenId: c["tokenId"] as? Int ?? 0,
                        from: c["from"] as? Int ?? 0,
                        to: c["to"] as? Int ?? LudoRules.yard)
                }
                return LudoActionMove(
                    tokenId: tokenId,
                    from: m["from"] as? Int ?? 0,
                    to: m["to"] as? Int ?? 0,
                    path: m["path"] as? [Int] ?? [],
                    captured: captured)
            }
            let roll: LudoAction.RollInfo? = (a["roll"] as? [String: Any]).flatMap { r in
                guard let rid = r["rollId"] as? String else { return nil }
                return LudoAction.RollInfo(rollId: rid, value: r["value"] as? Int ?? 0,
                                           auto: r["auto"] as? Bool ?? false)
            }
            return LudoAction(
                id: id,
                type: a["type"] as? String ?? "move",
                committedAt: a["committedAt"] as? Double ?? 0,
                presentationEndsAt: a["presentationEndsAt"] as? Double ?? 0,
                actorSeat: a["actorSeat"] as? Int ?? -1,
                fromSeat: a["fromSeat"] as? Int,
                roll: roll,
                move: move)
        }

        return LudoGameStateV2(
            schemaVersion: v2["schemaVersion"] as? Int ?? LudoRules.schemaVersion,
            rulesVersion: v2["rulesVersion"] as? String ?? LudoRules.rulesVersion,
            mode: v2["mode"] as? String ?? "four",
            status: v2["status"] as? String ?? "active",
            serverNow: v2["serverNow"] as? Double ?? Date().timeIntervalSince1970 * 1000,
            viewerSeat: v2["viewerSeat"] as? Int,
            viewerRole: v2["viewerRole"] as? String ?? "none",
            seats: seats,
            tokensPerSeat: v2["tokensPerSeat"] as? Int ?? 4,
            tokens: rawTokens,
            turn: turn,
            lastAction: lastAction,
            winnerSeat: v2["winnerSeat"] as? Int,
            endReason: v2["endReason"] as? String,
            seedCommitment: v2["seedCommitment"] as? String,
            seq: seq)
    }
}
