//
//  CarromBoardView.swift
//  Voiid Ui
//
//  Retina-crisp, high performance Carrom Board Canvas renderer.
//  Renders authentic rosewood bumpers, brass corner brackets, birch ply grain,
//  concentric center rosette, 3D turned wooden pieces, dynamic drop shadows,
//  and interactive aim trajectory guides.
//

import SwiftUI

struct CarromBoardView: View {

    @ObservedObject var game: CarromGame
    var size: CGFloat = 360 // Target display size

    @State private var dragStartPoint: CGPoint? = nil
    @State private var isSlingshotDrag: Bool = false

    private var scaleFactor: CGFloat {
        size / CarromTheme.totalBoardSize
    }

    var body: some View {
        TimelineView(.animation(paused: game.phase != .inMotion)) { timeline in
            let date = timeline.date

            Canvas { ctx, canvasSize in
                // Explicit dependency on timeline.date ensures Canvas renders every frame at 60/120fps
                let _ = date.timeIntervalSinceReferenceDate

                let scale = scaleFactor
                ctx.scaleBy(x: scale, y: scale)

                // 1. Draw Board Frame, Wood Surface, Pockets, and Markings
                drawOuterFrame(ctx: &ctx)
                drawPlayingSurface(ctx: &ctx)
                drawBoardMarkings(ctx: &ctx)
                drawPockets(ctx: &ctx)

                // 2. Draw Aiming Laser & Trajectory Guide
                if (game.phase == .aiming || game.phase == .placement), let aim = game.aimResult {
                    drawAimGuide(ctx: &ctx, aim: aim)
                }

                // 3. Draw All Carrom Pieces & Striker
                drawPieces(ctx: &ctx)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 22 * scaleFactor, style: .continuous))
            .shadow(color: Color.black.opacity(0.45), radius: 20, y: 12)
            .gesture(boardGesture)
        }
    }

    // MARK: - Interactive Gestures

    private var boardGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard game.phase == .placement || game.phase == .aiming else { return }
                guard game.turn == .player1 || !game.isBot else { return }

                let local = value.location
                let boardScale = scaleFactor
                let frameOffset = CarromTheme.frameThickness
                // Convert screen point to virtual surface coordinates (0...360)
                let surfaceX = (local.x / boardScale) - frameOffset
                let surfaceY = (local.y / boardScale) - frameOffset
                let touchPt = CGPoint(x: surfaceX, y: surfaceY)

                guard let striker = game.world.pieces.first(where: { $0.type == .striker }) else { return }
                let strikerPos = striker.position
                let distToStriker = touchPt.distance(to: strikerPos)

                if dragStartPoint == nil {
                    dragStartPoint = touchPt
                    let baselineY = CarromEngine.baselineY(for: game.turn)
                    let isNearBaseline = abs(touchPt.y - baselineY) < 28.0

                    if distToStriker < (CarromTheme.strikerRadius * 2.2) || isNearBaseline {
                        isSlingshotDrag = false
                    } else if touchPt.y > strikerPos.y && game.turn == .player1 {
                        isSlingshotDrag = true
                    } else {
                        isSlingshotDrag = false
                        game.setAimPoint(touchPt)
                    }
                }

                let baselineY = CarromEngine.baselineY(for: game.turn)
                let isDraggingBaseline = abs(touchPt.y - baselineY) < 30.0 && !isSlingshotDrag

                if isDraggingBaseline {
                    // Direct baseline positioning
                    let normX = (surfaceX - CarromEngine.baselineMinX) / (CarromEngine.baselineMaxX - CarromEngine.baselineMinX)
                    game.updateBaselineSlider(normX)
                } else if touchPt.y > (strikerPos.y + 12.0) && game.turn == .player1 {
                    // Pulling BACKWARDS behind striker: Slingshot charging
                    isSlingshotDrag = true
                    let pullOffset = CGSize(
                        width: (touchPt.x - strikerPos.x),
                        height: (touchPt.y - strikerPos.y)
                    )
                    game.updateAimGesture(dragOffset: pullOffset)
                } else {
                    // Direct aim target tracking: aim straight toward finger/pawn
                    isSlingshotDrag = false
                    game.setAimPoint(touchPt)
                }
            }
            .onEnded { _ in
                let wasSlingshot = isSlingshotDrag
                dragStartPoint = nil
                isSlingshotDrag = false

                if wasSlingshot && game.phase == .aiming && game.shotPower > 0.15 {
                    game.releaseStrike()
                }
            }
    }

    // MARK: - Drawing Components

    private func drawOuterFrame(ctx: inout GraphicsContext) {
        let total = CarromTheme.totalBoardSize
        let outerRect = CGRect(x: 0, y: 0, width: total, height: total)
        let outerPath = Path(roundedRect: outerRect, cornerRadius: 22)

        // Rosewood rich gradient
        ctx.fill(
            outerPath,
            with: .linearGradient(
                Gradient(colors: [CarromTheme.frameWoodLight, CarromTheme.frameWoodDark]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: total, y: total)
            )
        )

        // Frame inner bevel shadow
        ctx.stroke(outerPath, with: .color(CarromTheme.frameWoodLight.opacity(0.6)), lineWidth: 1.5)

        // Brass Corner Brackets
        drawBrassCorner(ctx: &ctx, at: CGPoint(x: 16, y: 16), rotation: 0)
        drawBrassCorner(ctx: &ctx, at: CGPoint(x: total - 16, y: 16), rotation: .pi / 2)
        drawBrassCorner(ctx: &ctx, at: CGPoint(x: total - 16, y: total - 16), rotation: .pi)
        drawBrassCorner(ctx: &ctx, at: CGPoint(x: 16, y: total - 16), rotation: -.pi / 2)
    }

    private func drawBrassCorner(ctx: inout GraphicsContext, at center: CGPoint, rotation: Double) {
        var copy = ctx
        copy.translateBy(x: center.x, y: center.y)
        copy.rotate(by: Angle(radians: rotation))

        var bracket = Path()
        bracket.move(to: CGPoint(x: -8, y: -8))
        bracket.addLine(to: CGPoint(x: 14, y: -8))
        bracket.addLine(to: CGPoint(x: 14, y: -4))
        bracket.addLine(to: CGPoint(x: -4, y: -4))
        bracket.addLine(to: CGPoint(x: -4, y: 14))
        bracket.addLine(to: CGPoint(x: -8, y: 14))
        bracket.closeSubpath()

        copy.fill(bracket, with: .linearGradient(
            Gradient(colors: [CarromTheme.brassHighlight, CarromTheme.brassBase, CarromTheme.brassShadow]),
            startPoint: CGPoint(x: -8, y: -8),
            endPoint: CGPoint(x: 14, y: 14)
        ))
    }

    private func drawPlayingSurface(ctx: inout GraphicsContext) {
        let ft = CarromTheme.frameThickness
        let surf = CarromTheme.surfaceSize
        let surfRect = CGRect(x: ft, y: ft, width: surf, height: surf)
        let surfPath = Path(roundedRect: surfRect, cornerRadius: 4)

        // Birch plywood warm radial gradient
        ctx.fill(
            surfPath,
            with: .radialGradient(
                Gradient(colors: [CarromTheme.woodLight, CarromTheme.woodMid, CarromTheme.woodDark]),
                center: CGPoint(x: ft + surf / 2, y: ft + surf / 2),
                startRadius: 20,
                endRadius: surf * 0.72
            )
        )

        // Inner cushion border frame
        ctx.stroke(surfPath, with: .color(CarromTheme.cushionRubber), lineWidth: 2.0)
    }

    private func drawBoardMarkings(ctx: inout GraphicsContext) {
        let ft = CarromTheme.frameThickness
        let c = CGPoint(x: ft + CarromTheme.surfaceSize / 2, y: ft + CarromTheme.surfaceSize / 2)

        // 1. Center Queen Circle & Outer Rosette
        let outerCircle = Path(ellipseIn: CGRect(
            x: c.x - CarromTheme.centerOuterRadius,
            y: c.y - CarromTheme.centerOuterRadius,
            width: CarromTheme.centerOuterRadius * 2,
            height: CarromTheme.centerOuterRadius * 2
        ))
        ctx.stroke(outerCircle, with: .color(CarromTheme.boardLine), lineWidth: 1.2)

        let innerCircle = Path(ellipseIn: CGRect(
            x: c.x - CarromTheme.centerInnerRadius,
            y: c.y - CarromTheme.centerInnerRadius,
            width: CarromTheme.centerInnerRadius * 2,
            height: CarromTheme.centerInnerRadius * 2
        ))
        ctx.stroke(innerCircle, with: .color(CarromTheme.baseCircleRed), lineWidth: 1.5)
        ctx.fill(innerCircle, with: .color(CarromTheme.baseCircleRed.opacity(0.2)))

        // Decorative 8-petal mandala spokes
        for i in 0..<8 {
            let angle = CGFloat(i) * (.pi / 4.0)
            let p1 = CGPoint(x: c.x + cos(angle) * CarromTheme.centerInnerRadius,
                             y: c.y + sin(angle) * CarromTheme.centerInnerRadius)
            let p2 = CGPoint(x: c.x + cos(angle) * CarromTheme.centerOuterRadius,
                             y: c.y + sin(angle) * CarromTheme.centerOuterRadius)
            var spoke = Path()
            spoke.move(to: p1); spoke.addLine(to: p2)
            ctx.stroke(spoke, with: .color(CarromTheme.boardLineLo), lineWidth: 1.0)
        }

        // 2. Baselines (4 sides)
        drawBaselinePair(ctx: &ctx, turn: .player1, rotation: 0)           // Bottom
        drawBaselinePair(ctx: &ctx, turn: .player2, rotation: .pi)         // Top
        drawBaselinePair(ctx: &ctx, turn: .player1, rotation: .pi / 2)     // Right
        drawBaselinePair(ctx: &ctx, turn: .player1, rotation: -.pi / 2)    // Left

        // 3. Diagonal Foul Arrows
        drawFoulArrow(ctx: &ctx, fromAngle: -.pi * 0.75) // Top-Left
        drawFoulArrow(ctx: &ctx, fromAngle: -.pi * 0.25) // Top-Right
        drawFoulArrow(ctx: &ctx, fromAngle: .pi * 0.25)  // Bottom-Right
        drawFoulArrow(ctx: &ctx, fromAngle: .pi * 0.75)  // Bottom-Left
    }

    private func drawBaselinePair(ctx: inout GraphicsContext, turn: CarromTurn, rotation: Double) {
        let ft = CarromTheme.frameThickness
        let total = CarromTheme.totalBoardSize
        var copy = ctx
        copy.translateBy(x: total / 2, y: total / 2)
        copy.rotate(by: Angle(radians: rotation))
        copy.translateBy(x: -total / 2, y: -total / 2)

        let minX = ft + CarromEngine.baselineMinX
        let maxX = ft + CarromEngine.baselineMaxX
        let yCenter = ft + CarromEngine.baselineY(for: .player1)
        let halfWidth = CarromTheme.baselineWidth / 2

        let line1Y = yCenter - halfWidth
        let line2Y = yCenter + halfWidth

        // Baseline parallel lines
        var lines = Path()
        lines.move(to: CGPoint(x: minX, y: line1Y))
        lines.addLine(to: CGPoint(x: maxX, y: line1Y))
        lines.move(to: CGPoint(x: minX, y: line2Y))
        lines.addLine(to: CGPoint(x: maxX, y: line2Y))
        copy.stroke(lines, with: .color(CarromTheme.boardLine), lineWidth: 1.2)

        // Baseline Red Circles at ends
        let cr = CarromTheme.baselineCircleRadius
        let circle1 = CGRect(x: minX - cr, y: yCenter - cr, width: cr * 2, height: cr * 2)
        let circle2 = CGRect(x: maxX - cr, y: yCenter - cr, width: cr * 2, height: cr * 2)

        copy.fill(Path(ellipseIn: circle1), with: .color(CarromTheme.baseCircleRed))
        copy.fill(Path(ellipseIn: circle2), with: .color(CarromTheme.baseCircleRed))
        copy.stroke(Path(ellipseIn: circle1), with: .color(CarromTheme.boardLine), lineWidth: 1.0)
        copy.stroke(Path(ellipseIn: circle2), with: .color(CarromTheme.boardLine), lineWidth: 1.0)
    }

    private func drawFoulArrow(ctx: inout GraphicsContext, fromAngle: CGFloat) {
        let ft = CarromTheme.frameThickness
        let c = CGPoint(x: ft + CarromTheme.surfaceSize / 2, y: ft + CarromTheme.surfaceSize / 2)
        let startR = CarromTheme.centerOuterRadius + 14.0
        let endR = CarromTheme.surfaceSize * 0.52

        let p1 = CGPoint(x: c.x + cos(fromAngle) * startR, y: c.y + sin(fromAngle) * startR)
        let p2 = CGPoint(x: c.x + cos(fromAngle) * endR, y: c.y + sin(fromAngle) * endR)

        var line = Path()
        line.move(to: p1); line.addLine(to: p2)
        ctx.stroke(line, with: .color(CarromTheme.boardLineLo), lineWidth: 1.0)

        // End circle
        let endCircle = CGRect(x: p2.x - 4, y: p2.y - 4, width: 8, height: 8)
        ctx.stroke(Path(ellipseIn: endCircle), with: .color(CarromTheme.boardLine), lineWidth: 1.0)
    }

    private func drawPockets(ctx: inout GraphicsContext) {
        let ft = CarromTheme.frameThickness
        let r = CarromTheme.pocketRadius

        for pocket in game.world.pocketCenters {
            let cx = ft + pocket.x
            let cy = ft + pocket.y
            let pocketRect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)

            // Deep pocket well
            ctx.fill(Path(ellipseIn: pocketRect), with: .color(CarromTheme.pocketWell))
            // Inner pocket shadow
            ctx.stroke(Path(ellipseIn: pocketRect), with: .color(Color.black.opacity(0.9)), lineWidth: 2.0)
        }
    }

    // MARK: - Draw Pieces & Striker

    private func drawPieces(ctx: inout GraphicsContext) {
        let ft = CarromTheme.frameThickness

        for piece in game.world.pieces {
            guard !piece.isPocketed else { continue }

            let cx = ft + piece.position.x
            let cy = ft + piece.position.y
            let scale: CGFloat = 1.0 - (piece.sinkProgress * 0.6)
            let opacity: Double = Double(1.0 - piece.sinkProgress)
            let r = piece.radius * scale

            var pCtx = ctx
            pCtx.opacity = opacity

            // Drop shadow
            if piece.sinkProgress == 0 {
                let shadowRect = CGRect(x: cx - r, y: cy - r + 3, width: r * 2, height: r * 2)
                pCtx.fill(Path(ellipseIn: shadowRect), with: .color(Color.black.opacity(0.28)))
            }

            let pieceRect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            let piecePath = Path(ellipseIn: pieceRect)

            switch piece.type {
            case .white:
                pCtx.fill(piecePath, with: .radialGradient(
                    Gradient(colors: [CarromTheme.whitePieceMain, CarromTheme.whitePieceRing, CarromTheme.whitePieceCore]),
                    center: CGPoint(x: cx - r * 0.25, y: cy - r * 0.25),
                    startRadius: 1, endRadius: r
                ))
                // Concentric turned groove
                let groove = CGRect(x: cx - r * 0.55, y: cy - r * 0.55, width: r * 1.1, height: r * 1.1)
                pCtx.stroke(Path(ellipseIn: groove), with: .color(CarromTheme.whitePieceCore.opacity(0.8)), lineWidth: 1.0)

            case .black:
                pCtx.fill(piecePath, with: .radialGradient(
                    Gradient(colors: [CarromTheme.blackPieceRing, CarromTheme.blackPieceMain, CarromTheme.blackPieceCore]),
                    center: CGPoint(x: cx - r * 0.25, y: cy - r * 0.25),
                    startRadius: 1, endRadius: r
                ))
                let groove = CGRect(x: cx - r * 0.55, y: cy - r * 0.55, width: r * 1.1, height: r * 1.1)
                pCtx.stroke(Path(ellipseIn: groove), with: .color(Color.white.opacity(0.18)), lineWidth: 1.0)

            case .queen:
                pCtx.fill(piecePath, with: .radialGradient(
                    Gradient(colors: [CarromTheme.queenRing, CarromTheme.queenMain]),
                    center: CGPoint(x: cx - r * 0.25, y: cy - r * 0.25),
                    startRadius: 1, endRadius: r
                ))
                let starRect = CGRect(x: cx - r * 0.42, y: cy - r * 0.42, width: r * 0.84, height: r * 0.84)
                pCtx.fill(Path(ellipseIn: starRect), with: .color(CarromTheme.queenStar))
                pCtx.stroke(Path(ellipseIn: starRect), with: .color(Color.white.opacity(0.6)), lineWidth: 0.8)

            case .striker:
                let isValid = game.isPlacementValid
                let glowColor = isValid ? CarromTheme.strikerGlow : CarromTheme.baseCircleRed

                // Outer acrylic glow rim
                pCtx.fill(piecePath, with: .radialGradient(
                    Gradient(colors: [CarromTheme.strikerCore, CarromTheme.strikerRing, CarromTheme.strikerBody]),
                    center: CGPoint(x: cx - r * 0.25, y: cy - r * 0.25),
                    startRadius: 2, endRadius: r
                ))
                pCtx.stroke(piecePath, with: .color(glowColor), lineWidth: 1.6)

                // Power ring when aiming
                if game.phase == .aiming && game.shotPower > 0 {
                    let powerRing = CGRect(x: cx - r - 4, y: cy - r - 4, width: (r + 4) * 2, height: (r + 4) * 2)
                    pCtx.stroke(Path(ellipseIn: powerRing), with: .color(glowColor.opacity(Double(game.shotPower))), lineWidth: 2.0)
                }
            }
        }
    }

    // MARK: - Draw Aim Guide & Raycast Trajectory

    private func drawAimGuide(ctx: inout GraphicsContext, aim: CarromAimResult) {
        let ft = CarromTheme.frameThickness
        let start = CGPoint(x: ft + aim.rayStart.x, y: ft + aim.rayStart.y)
        let end = CGPoint(x: ft + aim.rayEnd.x, y: ft + aim.rayEnd.y)

        // Primary aim laser (dashed line)
        var primaryPath = Path()
        primaryPath.move(to: start)
        primaryPath.addLine(to: end)
        ctx.stroke(
            primaryPath,
            with: .color(CarromTheme.aimLaser),
            style: StrokeStyle(lineWidth: 2.0, lineCap: .round, dash: [6, 4])
        )

        // If hits wall: draw reflected bounce ray
        if aim.hasWallHit, let bounceEnd = aim.wallBounceEnd {
            let bEnd = CGPoint(x: ft + bounceEnd.x, y: ft + bounceEnd.y)
            var bouncePath = Path()
            bouncePath.move(to: end)
            bouncePath.addLine(to: bEnd)
            ctx.stroke(
                bouncePath,
                with: .color(CarromTheme.aimBounceLaser),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4])
            )
        }

        // If hits piece: draw ghost striker circle and target deflection indicator
        if let ghostPos = aim.ghostStrikerPos {
            let gCenter = CGPoint(x: ft + ghostPos.x, y: ft + ghostPos.y)
            let r = CarromTheme.strikerRadius
            let ghostRect = CGRect(x: gCenter.x - r, y: gCenter.y - r, width: r * 2, height: r * 2)

            ctx.stroke(Path(ellipseIn: ghostRect), with: .color(CarromTheme.aimLaser), lineWidth: 1.2)
            ctx.fill(Path(ellipseIn: ghostRect), with: .color(CarromTheme.aimGhostDisc))

            if let deflEnd = aim.targetDeflectionEnd {
                let dEnd = CGPoint(x: ft + deflEnd.x, y: ft + deflEnd.y)
                var deflPath = Path()
                if let targetPiece = game.world.pieces.first(where: { $0.id == aim.targetPieceID }) {
                    let tPos = CGPoint(x: ft + targetPiece.position.x, y: ft + targetPiece.position.y)
                    deflPath.move(to: tPos)
                    deflPath.addLine(to: dEnd)
                    ctx.stroke(
                        deflPath,
                        with: .color(CarromTheme.aimLaser),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [3, 3])
                    )
                }
            }
        }
    }
}
