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
        displayOverride: (seat: Int, pawn: Int, center: CGPoint)? = nil,
        highContrast: Bool = false,
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

        // 8) Pawns — blank silhouettes tinted per seat; finished sit at 52% in their slots.
        // `displayOverride` carries the ONE display pawn mid-hop / mid-capture-return while
        // authoritative state already holds every destination.
        let placed = LudoPawnLayer.layout(state: state, layout: layout,
                                          droppedSeats: dropped, displayOverride: displayOverride)
        for pawn in placed {
            let boxW = LudoPawnShape.widthFactor * unit * pawn.scale
            let boxH = LudoPawnShape.heightFactor * unit * pawn.scale
            var pawnCtx = ctx
            pawnCtx.translateBy(x: pawn.center.x - boxW / 2, y: pawn.center.y - boxH / 2)

            // Contact shadow: y=2 blur=3 rest / y=6 blur=8 hopping (§2.2).
            let shadowRect = CGRect(x: boxW * 0.16, y: boxH * 0.93,
                                    width: boxW * 0.68, height: boxW * 0.12)
            pawnCtx.fill(Path(ellipseIn: shadowRect), with: .color(.black.opacity(0.14)))

            let hue = colors.hue(pawn.seat)
            let body = LudoPawnShape.path(width: boxW, height: boxH)
            pawnCtx.fill(body, with: .color(hue))
            pawnCtx.stroke(LudoPawnShape.rimPath(width: boxW, height: boxH),
                           with: .color(LudoPawnShape.rimColor(hue, darkTheme: colors.isDark)),
                           lineWidth: 1)
            pawnCtx.stroke(LudoPawnShape.highlightArc(width: boxW, height: boxH),
                           with: .color(LudoPawnShape.rimColor(hue, darkTheme: colors.isDark).opacity(0.45)),
                           lineWidth: 1)
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
            // Steady full border in the active hue (§12.1); reduced motion lands here too.
            ctx.stroke(perimeter, with: .color(colors.hue(state.turn?.seat ?? 0)), lineWidth: stroke)
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
