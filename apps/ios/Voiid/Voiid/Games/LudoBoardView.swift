//
//  LudoBoardView.swift
//  Voiid
//
//  The board and its tokens (docs/games/future/LUDO.md §6.2, §8, §9).
//
//  ONE CANVAS FOR THE STATIC BOARD, OVERLAID VIEWS FOR THE TOKENS. The board is ~70 cells that
//  never change, so it is drawn once; the tokens are ≤16 views so each can animate individually
//  with SwiftUI's own animation system. Not Metal — GAMES.md §4 specifies plain views for board
//  games, and SnakeMetalView exists only because Snake shades six polylines at 60fps.
//
//  Mirrors Android `LudoBoardView.kt`. Every geometry constant comes from `Ludo` (LudoBoard.swift)
//  so the two platforms cannot disagree about where a square is.
//

import SwiftUI

/// A token, positioned and animated. Identity is (seat, index) so SwiftUI animates the SAME view
/// from square to square rather than cross-fading two different ones.
private struct LudoToken: Identifiable {
    let seat: Int
    let index: Int
    let position: Int
    /// How many of this seat's tokens share the square, and which one this is — used to fan a
    /// stack out rather than drawing four discs on top of each other.
    let stackCount: Int
    let stackIndex: Int
    var id: String { "\(seat)-\(index)" }
}

struct LudoBoardView: View {
    let state: LudoState
    /// The local player's seat, so the board can be rotated to put them at the bottom.
    let mySeat: Int?
    /// Tokens the local player may move right now. Empty unless it is their turn to move.
    let legal: [Int]
    var onTapToken: ((Int) -> Void)?
    /// Positions to draw INSTEAD of the state's, while a hop chain is in flight (§9).
    ///
    /// Passed in rather than owned here because the driver has to outlive a single body
    /// evaluation, and because the screen decides when a move begins — the board only draws.
    var hopOverrides: [String: Int] = [:]
    /// Set when the player has asked the system to reduce motion. Collapses every spring.
    var reduceMotion: Bool = false

    /// Warm and tactile (§8.1) — Ludo is the one game in the folder where nostalgia is an asset,
    /// because it has a referent people actually played on a mat on the floor.
    private let boardPaper = Color(red: 0.97, green: 0.95, blue: 0.90)
    private let boardInk = Color(red: 0.22, green: 0.20, blue: 0.18)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Canvas { ctx, size in
                    drawBoard(ctx: ctx, side: size.width)
                }
                .frame(width: side, height: side)

                ForEach(tokens) { token in
                    tokenView(token, side: side)
                }
            }
            .frame(width: side, height: side)
            // YOU ARE ALWAYS AT THE BOTTOM (§6.3). The board is rotated so the local player's
            // yard is bottom-left, exactly as Air Hockey always puts your goal at the bottom.
            // This is a CLIENT-SIDE rotation the server knows nothing about — it means every
            // player has the same spatial relationship to their own tokens, whichever seat they
            // actually drew.
            .rotationEffect(.degrees(Double(-90 * (mySeat ?? 0))))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Tokens

    private var tokens: [LudoToken] {
        var out: [LudoToken] = []
        for (seat, row) in state.tokens.enumerated() {
            // Count how many of this seat's tokens share each square, so a stack fans out.
            var seen: [Int: Int] = [:]
            let counts = row.reduce(into: [Int: Int]()) { acc, p in acc[p, default: 0] += 1 }
            for (index, position) in row.enumerated() {
                let stackIndex = seen[position, default: 0]
                seen[position] = stackIndex + 1
                out.append(LudoToken(
                    seat: seat, index: index, position: position,
                    stackCount: counts[position] ?? 1, stackIndex: stackIndex))
            }
        }
        return out
    }

    @ViewBuilder
    private func tokenView(_ token: LudoToken, side: CGFloat) -> some View {
        let unit = side / CGFloat(Ludo.gridSize)
        // A token mid-hop draws at its intermediate square; everything else draws the truth.
        let drawn = hopOverrides[LudoHop.key(seat: token.seat, token: token.index)]
            ?? token.position
        let hopping = hopOverrides[LudoHop.key(seat: token.seat, token: token.index)] != nil
        let centre = Ludo.squareCentre(
            position: drawn, seat: token.seat, tokenIndex: token.index)
        // Fan a stack so two tokens on one square are both visible — rare, and it beats an
        // ambiguous target (§7.2).
        //
        // NOT IN THE YARD. Every token in a yard shares position -1, so the stack logic saw four
        // tokens on one square and fanned them — on top of `squareCentre` already giving each one
        // its own pocket slot by `tokenIndex`. The two offsets compounded and every yard token
        // sat visibly up and left of the circle drawn for it. A yard is not a stack; it is four
        // separate places that happen to share an encoding.
        let stacked = token.stackCount > 1 && !Ludo.inYard(drawn)
        let spread: CGFloat = stacked ? unit * 0.18 : 0
        let offset = stacked
            ? CGFloat(token.stackIndex) - CGFloat(token.stackCount - 1) / 2
            : 0
        let isMine = token.seat == mySeat
        let isLegal = isMine && legal.contains(token.index)

        ZStack {
            // A REAL PIECE, NOT A FILLED CIRCLE (§8.1 asks for "rounded pieces that look like
            // objects that can be picked up"). Contact shadow, lit body, off-centre specular —
            // three cheap layers in GameSurface that do most of what a sprite would.
            Canvas { ctx, size in
                GameSurface.token(
                    in: ctx,
                    centre: CGPoint(x: size.width / 2, y: size.height / 2),
                    radius: min(size.width, size.height) / 2 - 1,
                    color: Ludo.seatColors[token.seat % Ludo.maxSeats],
                    // The shadow shrinks and softens while the token is airborne, which is most
                    // of what sells a hop as leaving the board.
                    lifted: hopping)
            }
            // COLOUR IS NEVER THE ONLY CHANNEL (§8.1). Ludo is traditionally colour-only and
            // that is the trap: with four players it is four times worse than Snake's version of
            // the same problem, which CROSS_CUTTING.md §13 flags for ~8% of men.
            Image(systemName: Ludo.seatMarkers[token.seat % Ludo.maxSeats])
                .font(.system(size: unit * 0.30, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
        }
        // A 48pt HIT TARGET REGARDLESS OF VISUAL SIZE (§7.2). A 52-square track on a 390pt board
        // gives ~40pt cells and ~28pt tokens, well under the platform minimum, so the tappable
        // area is deliberately larger than the disc.
        .frame(width: unit * 0.72, height: unit * 0.72)
        // Legal tokens lift so the player can see what the die bought them without working it
        // out (§7.1, §9).
        // The arc: each hop lifts and squashes on landing, which is what makes a token read as
        // an object being picked up rather than a dot sliding (§9).
        .scaleEffect(hopping ? 1.16 : (isLegal ? 1.18 : 1.0))
        .offset(y: hopping ? -unit * 0.22 : 0)
        .opacity(isMine && !legal.isEmpty && !isLegal ? 0.45 : 1.0)
        // Counter-rotate the token by the board's rotation, so a marker is never upside down
        // for the player looking at it.
        .rotationEffect(.degrees(Double(90 * (mySeat ?? 0))))
        // CENTRE THE VISUAL INSIDE THE LARGER HIT FRAME.
        //
        // The hit frame below is 44pt (the platform minimum) while the disc is ~17pt on a phone,
        // so there is ~27pt of slack. Without an explicit alignment SwiftUI is free to seat the
        // smaller child anywhere in it, and the tokens visibly drifted up and left of the yard
        // circles they are supposed to sit in — the piece disagreeing with its own square.
        .frame(width: max(unit * 0.72, 44), height: max(unit * 0.72, 44), alignment: .center)
        // THE HIT AREA AND THE TAP MUST BE ATTACHED BEFORE `.position`, NOT AFTER.
        //
        // `.position` expands the view to fill its parent and places the content inside it, so a
        // `.contentShape` applied afterwards describes a shape inscribed in the WHOLE BOARD
        // rather than in the token. Every token then claimed the same board-sized hit area,
        // taps landed on whichever view was last in z-order, and moving a token by tapping it
        // simply did not work — while looking completely correct on screen.
        .contentShape(Circle())
        .onTapGesture { if isLegal { onTapToken?(token.index) } }
        .accessibilityLabel("\(Ludo.seatNames[token.seat % Ludo.maxSeats]) token \(token.index + 1)")
        .accessibilityHint(isLegal ? "Tap to move" : "")
        .accessibilityAddTraits(isLegal ? .isButton : [])
        .position(
            x: centre.x * side + offset * spread,
            y: centre.y * side + offset * spread)
        // THE HOP CHAIN (§9). `drawn` steps square by square while a move is in flight, and each
        // step animates on its own short spring — so the token visibly counts out the distance
        // instead of sliding to the answer. Under reduce-motion the driver never runs and this
        // collapses to an instant cut, per §9's fallback.
        .animation(
            reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.62),
            value: drawn)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hopping)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: isLegal)
    }

    // MARK: - The static board

    private func drawBoard(ctx: GraphicsContext, side: CGFloat) {
        let unit = side / CGFloat(Ludo.gridSize)

        // FELT, NOT A FLAT FILL. §8.1 asks for warm and tactile — a mat on the floor — and a
        // large even rectangle reads as an empty view no matter what colour it is.
        GameSurface.felt(
            in: ctx, rect: CGRect(x: 0, y: 0, width: side, height: side), base: boardPaper)

        func cellRect(_ x: Int, _ y: Int) -> CGRect {
            CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit, width: unit, height: unit)
        }

        // Yards: four corner pockets, tinted by seat.
        for seat in 0..<Ludo.maxSeats {
            let cells = Ludo.yardCells[seat]
            guard let minX = cells.map(\.0).min(), let minY = cells.map(\.1).min(),
                  let maxX = cells.map(\.0).max(), let maxY = cells.map(\.1).max() else { continue }
            let rect = CGRect(x: CGFloat(minX - 1) * unit, y: CGFloat(minY - 1) * unit,
                              width: CGFloat(maxX - minX + 3) * unit,
                              height: CGFloat(maxY - minY + 3) * unit)
            ctx.fill(Path(roundedRect: rect, cornerRadius: unit * 0.4),
                     with: .color(Ludo.seatColors[seat].opacity(0.22)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: unit * 0.4),
                       with: .color(Ludo.seatColors[seat].opacity(0.55)), lineWidth: 1)
            for slot in cells {
                ctx.stroke(Path(ellipseIn: cellRect(slot.0, slot.1).insetBy(dx: unit * 0.16, dy: unit * 0.16)),
                           with: .color(Ludo.seatColors[seat].opacity(0.5)), lineWidth: 1)
            }
        }

        // Main track.
        for (index, cell) in Ludo.trackCells.enumerated() {
            let rect = cellRect(cell.0, cell.1).insetBy(dx: 0.5, dy: 0.5)
            // An entry square is tinted with its owner's colour so a player can find where their
            // tokens come out without being told.
            var fill = Color.white
            for seat in 0..<Ludo.maxSeats where Ludo.entrySquare(seat) == index {
                fill = Ludo.seatColors[seat].opacity(0.30)
            }
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill))
            // Pressed into the board rather than sitting on it — one light direction, top-left,
            // shared with every other surface in the app.
            GameSurface.inset(in: ctx, rect: rect, radius: 2, depth: 0.9)

            // SAFE SQUARES ARE PRINTED STARS. This is a rule the board must teach (§8.1) — a
            // player who does not know a square is safe cannot reason about capture at all.
            if Ludo.isSafe(index) {
                let c = CGPoint(x: rect.midX, y: rect.midY)
                let r = unit * 0.26
                var star = Path()
                for i in 0..<10 {
                    let angle: CGFloat = CGFloat(i) * .pi / 5 - .pi / 2
                    let radius: CGFloat = i % 2 == 0 ? r : r * 0.45
                    let p = CGPoint(x: c.x + CGFloat(cos(Double(angle))) * radius,
                                    y: c.y + CGFloat(sin(Double(angle))) * radius)
                    if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
                }
                star.closeSubpath()
                ctx.fill(star, with: .color(boardInk.opacity(0.30)))
            }
        }

        // Home columns, in each seat's colour, running to the centre.
        for seat in 0..<Ludo.maxSeats {
            for cell in Ludo.columnCells[seat] {
                let rect = cellRect(cell.0, cell.1).insetBy(dx: 0.5, dy: 0.5)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                         with: .color(Ludo.seatColors[seat].opacity(0.55)))
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 2),
                           with: .color(boardInk.opacity(0.20)), lineWidth: 0.6)
            }
        }

        // The centre: four triangles meeting, one per seat.
        let mid = CGPoint(x: side / 2, y: side / 2)
        let block = CGRect(x: 6 * unit, y: 6 * unit, width: 3 * unit, height: 3 * unit)
        let corners = [
            (CGPoint(x: block.minX, y: block.maxY), CGPoint(x: block.maxX, y: block.maxY)), // seat 0, bottom
            (CGPoint(x: block.minX, y: block.minY), CGPoint(x: block.minX, y: block.maxY)), // seat 1, left
            (CGPoint(x: block.minX, y: block.minY), CGPoint(x: block.maxX, y: block.minY)), // seat 2, top
            (CGPoint(x: block.maxX, y: block.minY), CGPoint(x: block.maxX, y: block.maxY)), // seat 3, right
        ]
        for (seat, pair) in corners.enumerated() {
            var tri = Path()
            tri.move(to: mid)
            tri.addLine(to: pair.0)
            tri.addLine(to: pair.1)
            tri.closeSubpath()
            ctx.fill(tri, with: .color(Ludo.seatColors[seat].opacity(0.75)))
        }
        ctx.stroke(Path(block), with: .color(boardInk.opacity(0.3)), lineWidth: 1)
    }
}
