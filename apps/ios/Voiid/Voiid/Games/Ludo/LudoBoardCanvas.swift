//
//  LudoBoardCanvas.swift
//  Voiid
//
//  Board composition as a pure Canvas draw function (§3.3), so the live board, the
//  walkthrough demo and cold-start skeletons share ONE renderer.
//
//  Draw order is fixed:
//    backing → yard fields → yard pockets → cells → center triangles → safe marks/chevrons →
//    highlights → pawns → perimeter stroke.
//
//  Every node draws from ITS OWN rect — never a flattened bitmap — so cells stay addressable
//  for highlight, pulse, hit-test and semantics.
//

import SwiftUI

/// One frame of border-sweep visual state, produced by the coordinator.
struct LudoBoardSweep {
    let fromSeat: Int
    let toSeat: Int
    let progress: CGFloat   // 0...1, already eased by the coordinator
}

enum LudoBoardCanvas {

    static func droppedSeats(_ state: LudoGameStateV2) -> Set<Int> {
        []
    }

    /// "seat:pawn" keys for every token the CURRENT roll can legally move. Empty between turns,
    /// so nothing glows while there is no decision to make.
    static func activePawnKeys(_ state: LudoGameStateV2) -> Set<String> {
        guard !state.isFinished, let turn = state.turn, turn.phase == "awaitingMove" else {
            return []
        }
        return Set(turn.legalTokenIds.map { "\(turn.seat):\($0)" })
    }

    /// Cell keys under server-legal tokens — the halo/highlight set.
    static func legalCellHighlights(_ state: LudoGameStateV2) -> Set<String> {
        guard !state.isFinished, let turn = state.turn else { return [] }
        var keys = Set<String>()
        for token in turn.legalTokenIds {
            guard let pos = state.tokens[ludoSafe: turn.seat]?[ludoSafe: token] else { continue }
            if pos >= 0 && pos < LudoRules.trackCount {
                let c = LudoBoardGeometry.trackCoords[pos]
                keys.insert("cell-\(c.0)-\(c.1)")
            } else if pos >= LudoRules.homeLaneBase,
                      pos < LudoRules.homeLaneBase + LudoRules.homeLaneCount {
                let c = LudoBoardGeometry.homeLaneCoords[turn.seat][pos - LudoRules.homeLaneBase]
                keys.insert("cell-\(c.0)-\(c.1)")
            }
        }
        return keys
    }

    static func draw(
        _ ctx: inout GraphicsContext,
        size: CGSize,
        colors: LudoColors,
        state: LudoGameStateV2,
        sweep: LudoBoardSweep?,
        displayOverrides: [(seat: Int, pawn: Int, center: CGPoint)] = [],
        highContrast: Bool = false,
        /// 0...1 of the active seat's decision window still remaining; nil hides the clock.
        /// Advances the marching dashes on playable tokens.
        dashPhase: CGFloat = 0,
        timerFraction: CGFloat? = nil,
        /// Warning / critical tint for the last seconds; nil keeps the seat hue.
        timerTint: Color? = nil,
    ) {
        let side = size.width
        let layout = LudoBoardGeometry.Layout(sideLength: side)
        let unit = layout.unit
        let dropped = droppedSeats(state)

        // 1) Flat board backing; the contract requires zero board elevation.
        let boardRect = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        let boardShape = RoundedRectangle(cornerRadius: LudoDimens.boardCornerRadius)
        ctx.fill(boardShape.path(in: boardRect), with: .color(colors.boardSurface))

        // 2+3) Yard fields then pockets.
        for node in LudoBoardGeometry.cells {
            let r = layout.rect(of: node)
            switch node.role {
            case .yard:
                ctx.fill(Rectangle().path(in: r),
                         with: .color(LudoCellView.yardFill(node, dropped: dropped, colors)))
            default:
                continue
            }
        }
        for seat in 0..<4 {
            let origin: (Int, Int) = seat == 0 ? (0, 9) : seat == 1 ? (0, 0) : seat == 2 ? (9, 0) : (9, 9)
            let inset = unit * LudoDimens.yardPocketInsetFactor
            let r = CGRect(x: CGFloat(origin.0) * unit + inset, y: CGFloat(origin.1) * unit + inset,
                           width: unit * 4.4, height: unit * 4.4)
            let pocket = RoundedRectangle(cornerRadius: unit * LudoDimens.yardPocketRadiusFactor).path(in: r)
            ctx.fill(pocket, with: .color(colors.yardPocket))
            ctx.stroke(pocket, with: .color(colors.yardPocketBorder), lineWidth: max(0.75, unit * 0.04))

            // Four resting circles, one per pawn, ringed on the pocket centre. They give a pawn
            // in the yard somewhere to SIT rather than float, and stay legible when the slot is
            // empty — the same read as the seat rings in Ludo King.
            let slotRadius = unit * LudoDimens.yardSlotRadiusFactor
            for pawn in 0..<4 {
                let c = layout.yardSlotCenter(seat: seat, pawn: pawn)
                let ring = Path(ellipseIn: CGRect(x: c.x - slotRadius, y: c.y - slotRadius,
                                                  width: slotRadius * 2, height: slotRadius * 2))
                ctx.fill(ring, with: .color(colors.yard(seat).opacity(0.16)))
                ctx.stroke(ring, with: .color(colors.yard(seat)),
                           lineWidth: max(0.75, unit * 0.045))
            }
        }

        // 4) Cells — track + lanes; each from its OWN rect.
        for node in LudoBoardGeometry.cells where node.role != .yard && node.role != .yardPocket {
            LudoCellView.draw(&ctx, node: node, rect: layout.rect(of: node), colors: colors,
                              pressed: false, highlight: nil, highContrast: highContrast,
                              darkTheme: colors.isDark)
        }

        // 5) Center triangles over the 3×3 region.
        let centerRect = LudoCellView.centerRect(for: layout)
        for seat in 0..<4 {
            ctx.fill(LudoCellView.centerTrianglePath(seat: seat, centerRect: centerRect),
                     with: .color(colors.centerTriangle(seat)))
        }

        // 6) Safe marks — stars + owner-hue entry chevrons; Paths, never glyphs.
        for node in LudoBoardGeometry.cells {
            switch node.decoration {
            case .star:
                ctx.stroke(LudoCellView.safeStarPath(in: layout.rect(of: node)),
                           with: .color(colors.safeCellStar), lineWidth: max(1, unit * 0.055))
            case .approachChevron:
                let seat = node.seat ?? 0
                ctx.stroke(LudoCellView.entryChevronPath(in: layout.rect(of: node), seat: seat),
                           with: .color(colors.yard(seat)),
                           style: StrokeStyle(lineWidth: unit * 0.10, lineCap: .round, lineJoin: .round))
            case .none:
                continue
            }
        }

        // 7) Highlights under legal pawns.
        let highlights = legalCellHighlights(state)
        if !highlights.isEmpty {
            for node in LudoBoardGeometry.cells where highlights.contains(node.id) {
                var r = layout.rect(of: node)
                r = r.insetBy(dx: -1.5, dy: -1.5)
                ctx.stroke(RoundedRectangle(cornerRadius: 3).path(in: r),
                           with: .color(colors.hue(state.turn?.seat ?? 0).opacity(0.45)),
                           lineWidth: 2.5)
            }
        }

        // 8) Pawns — pin silhouettes tinted per seat; finished sit at 52% in their slots.
        // `displayOverrides` carries every pawn in transit — a mover mid-hop AND the pawn it
        // authoritative state already holds every destination.
        //
        // A token is ACTIVE when the current roll could actually be played with it. That is the
        // server's legal set, never a guess: the glow is a promise that tapping does something.
        let placed = LudoPawnLayer.layout(state: state, layout: layout,
                                          droppedSeats: dropped, displayOverrides: displayOverrides)
        let activeTokens = activePawnKeys(state)
        // Playable tokens paint LAST so they sit over anything sharing their cell — a token you
        // can act on must never be buried under one you cannot.
        let ordered = placed.sorted { a, b in
            let aActive = activeTokens.contains("\(a.seat):\(a.pawnIndex)")
            let bActive = activeTokens.contains("\(b.seat):\(b.pawnIndex)")
            return !aActive && bActive
        }
        for pawn in ordered {
            let isActive = activeTokens.contains("\(pawn.seat):\(pawn.pawnIndex)")
            let scale = pawn.scale * (isActive ? LudoPawnShape.activeScale : 1)
            let boxW = LudoPawnShape.widthFactor * unit * scale
            let boxH = LudoPawnShape.heightFactor * unit * scale
            var pawnCtx = ctx
            pawnCtx.translateBy(x: pawn.center.x - boxW / 2, y: pawn.center.y - boxH / 2)
            LudoPawnShape.draw(&pawnCtx, width: boxW, height: boxH,
                               hue: colors.hue(pawn.seat),
                               active: isActive,
                               dashPhase: dashPhase,
                               colors: colors)
        }

        // 9) Perimeter LAST — the turn border sweeps OVER everything (§12).
        let stroke = LudoDimens.perimeterStroke(dark: colors.isDark)
        let perimeter = LudoTurnBorder.perimeterPath(
            side: side, cornerRadius: LudoDimens.boardCornerRadius, stroke: stroke)

        if state.isFinished || state.turn == nil {
            // Game end changes INSTANTLY to podBorder; winner presentation belongs to the
            // result sheet, not a false "active" border (§12.1).
            ctx.stroke(perimeter, with: .color(colors.boardOuterNeutral), lineWidth: stroke)
        } else if let s = sweep, s.fromSeat != s.toSeat {
            LudoTurnBorder.draw(
                &ctx, path: perimeter, stroke: stroke,
                baseColor: colors.hue(s.fromSeat),
                overlayColor: colors.hue(s.toSeat),
                phaseStart: LudoBoardGeometry.borderAnchors[s.fromSeat % 4],
                progress: s.progress)
        } else {
            // The perimeter IS the clock. It carries the active seat's hue and shortens from
            // that seat's own anchor as their window runs down, so who is on the clock and how
            // long they have left are one signal instead of two (§12.1). Reduced motion lands
            // here too: the border simply stops shortening smoothly, it never disappears.
            let seat = state.turn?.seat ?? 0
            let hue = timerTint ?? colors.hue(seat)
            let anchor = LudoBoardGeometry.borderAnchors[seat % 4]

            guard let fraction = timerFraction else {
                ctx.stroke(perimeter, with: .color(hue), lineWidth: stroke)
                return
            }

            // The spent part stays as a dim track so the board never loses its outline. It uses
            // the pod ring's track token, not the game-end outline, which is near-black and read
            // as a hard shadow down one edge of the board.
            ctx.stroke(perimeter, with: .color(colors.timerTrack), lineWidth: stroke)
            let remaining = max(0, min(1, fraction))
            guard remaining > 0.001 else { return }
            LudoTurnBorder.drawArc(
                &ctx, path: perimeter, stroke: stroke, color: hue,
                phaseStart: anchor, length: remaining)
        }
    }
}

/// Thin SwiftUI wrapper used by screens and the walkthrough demo.
struct LudoV2BoardView: View {
    let state: LudoGameStateV2
    var sweep: LudoBoardSweep?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { ctx, size in
            LudoBoardCanvas.draw(&ctx, size: size, colors: LudoColors.resolve(scheme),
                                 state: state, sweep: sweep, highContrast: contrast == .increased)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LudoAccessibility.boardSummary(state))
    }
}
