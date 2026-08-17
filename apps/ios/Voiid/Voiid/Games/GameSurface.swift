//
//  GameSurface.swift
//  Voiid
//
//  The shared visual language for game boards: paper grain, felt, wood, inset cells, and the
//  specular highlight that makes a token read as an object rather than a filled circle.
//
//  WHY THIS IS SHARED RATHER THAN FOUR SEPARATE TREATMENTS. Four boards styled independently is
//  four different games stapled to a tab — the same failure SOUND_DESIGN.md §3 describes for
//  audio, where four unrelated "you lost that one" sounds teach the player nothing. A player
//  should be able to tell they are still inside Voiid when they move between games, and that is
//  carried by grain, depth and light behaving the same way everywhere.
//
//  IT IS ALL PROCEDURAL. No image assets, no atlases, nothing to ship or version — every effect
//  here is drawn from a seed, so it scales to any board size and costs nothing in binary weight.
//  The alternative, a texture PNG per surface, would be four more assets to keep in step across
//  two platforms for something a hash function does exactly as well.
//
//  DETERMINISTIC, DELIBERATELY. Grain is drawn from a positional hash rather than `random()`, so
//  a board looks identical on every redraw. A texture that shimmers as the view re-renders is
//  worse than no texture at all.
//
//  Mirrors Android `GameSurface.kt`. Keep the constants identical.
//

import SwiftUI

enum GameSurface {

    // MARK: - Deterministic noise

    /// A stable pseudo-random value in 0...1 for a grid position.
    ///
    /// The classic sine-hash: cheap, no state, and — the point — the SAME answer for the same
    /// (x, y, seed) every single call. SwiftUI redraws a Canvas whenever anything above it
    /// changes, so grain built on `Double.random` would crawl and sparkle on every frame.
    static func noise(_ x: Int, _ y: Int, seed: Int = 0) -> Double {
        let v = sin(Double(x) * 127.1 + Double(y) * 311.7 + Double(seed) * 74.7) * 43758.5453
        return v - v.rounded(.down)
    }

    // MARK: - Surfaces

    /// PAPER: a warm off-white with fine grain and a soft vignette.
    ///
    /// Sea Battle's chart (SEA_BATTLE.md §8.2) and anything that wants to read as printed. The
    /// grain is what stops a large flat fill looking like an empty view.
    static func paper(
        in ctx: GraphicsContext, rect: CGRect, base: Color, grain: Double = 0.022, seed: Int = 7
    ) {
        ctx.fill(Path(rect), with: .color(base))
        speckle(in: ctx, rect: rect, amount: grain, seed: seed, cell: 3)
        vignette(in: ctx, rect: rect, strength: 0.10)
    }

    /// FELT: a table surface — denser, softer grain and a stronger vignette.
    ///
    /// Ludo's board (LUDO.md §8.1 asks for warm and tactile — "a mat on the floor").
    static func felt(
        in ctx: GraphicsContext, rect: CGRect, base: Color, seed: Int = 11
    ) {
        ctx.fill(Path(rect), with: .color(base))
        speckle(in: ctx, rect: rect, amount: 0.028, seed: seed, cell: 4)
        vignette(in: ctx, rect: rect, strength: 0.14)
    }

    /// Fine grain, drawn as sparse translucent dots.
    ///
    /// `cell` is the spacing in points: smaller is denser and costs more. At cell 3 a 350pt board
    /// is ~13k candidate points of which a fraction are drawn, which is trivial for a surface
    /// that is redrawn only when the board changes.
    static func speckle(
        in ctx: GraphicsContext, rect: CGRect, amount: Double, seed: Int, cell: Int
    ) {
        let cols = Int(rect.width) / cell
        let rows = Int(rect.height) / cell
        guard cols > 0, rows > 0 else { return }
        for gy in 0..<rows {
            for gx in 0..<cols {
                let n = noise(gx, gy, seed: seed)
                // Only the top slice of the noise field becomes a speck, which is what makes it
                // read as grain rather than as a dither pattern.
                // A high threshold keeps grain sparse. Too low and it stops reading as texture
                // and starts reading as dirt on the screen.
                guard n > 0.93 else { continue }
                let x = rect.minX + Double(gx * cell)
                let y = rect.minY + Double(gy * cell)
                let dark = noise(gx, gy, seed: seed + 1) > 0.5
                let a = amount * (0.4 + n * 0.6)
                ctx.fill(
                    Path(CGRect(x: x, y: y, width: Double(cell) * 0.7, height: Double(cell) * 0.7)),
                    with: .color(dark ? .black.opacity(a) : .white.opacity(a * 0.8)))
            }
        }
    }

    /// Darken the edges. A board with even light across it reads as a screenshot of a board;
    /// a slight falloff reads as a physical object under a lamp.
    static func vignette(in ctx: GraphicsContext, rect: CGRect, strength: Double) {
        ctx.fill(
            Path(rect),
            with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(strength)]),
                center: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: min(rect.width, rect.height) * 0.30,
                endRadius: max(rect.width, rect.height) * 0.72))
    }

    // MARK: - Depth

    /// An INSET cell — light on the bottom-right, shadow on the top-left.
    ///
    /// Reads as a hole pressed into the surface, which is what a board square is. The direction
    /// is the inverse of `raised` below, and keeping the two consistent is what makes a board
    /// read as one lit object rather than a collection of independently shaded rectangles.
    ///
    /// LIGHT COMES FROM THE TOP-LEFT everywhere in this app. One light direction, every game.
    static func inset(
        in ctx: GraphicsContext, rect: CGRect, radius: CGFloat, depth: CGFloat = 1.2
    ) {
        let path = Path(roundedRect: rect, cornerRadius: radius)
        // Shadow along the top and left inner edges.
        ctx.stroke(
            Path(roundedRect: rect.offsetBy(dx: depth, dy: depth), cornerRadius: radius),
            with: .color(.black.opacity(0.10)), lineWidth: depth * 1.4)
        // Catch-light along the bottom and right.
        ctx.stroke(
            Path(roundedRect: rect.offsetBy(dx: -depth * 0.5, dy: -depth * 0.5), cornerRadius: radius),
            with: .color(.white.opacity(0.35)), lineWidth: depth)
        ctx.stroke(path, with: .color(.black.opacity(0.06)), lineWidth: 0.5)
    }

    /// A RAISED disc with a soft contact shadow, a body gradient and a specular highlight.
    ///
    /// THIS IS WHAT MAKES A TOKEN READ AS AN OBJECT rather than a filled circle, and it is the
    /// single highest-value effect in this file — LUDO.md §8.1 asks for "rounded 3/4-view pieces
    /// that look like objects that can be picked up", and three cheap layers get most of the way
    /// there without any model or sprite.
    ///
    ///   1. a contact shadow, offset DOWN — the piece sits on the board
    ///   2. a vertical gradient — lit from above, darker underneath
    ///   3. a small off-centre highlight — a hard light source, up and to the left
    /// A LUDO PAWN — a moulded plastic piece, not a lit disc (§5.1).
    ///
    /// `token` above draws a disc, which was right when the board was flat but is the reason the
    /// pieces never read as objects you could pick up. A pawn is four stacked shapes: base,
    /// waist, collar, head. Glossy rather than matte, because Ludo King's pieces read as
    /// polished plastic and that is most of the appeal.
    ///
    /// THE PIECE STILL SITS ON `centre`. The shadow moves for the hop, never the body — the
    /// piece and the square the rules say it occupies must agree.
    static func pawn(
        in ctx: GraphicsContext, centre: CGPoint, radius: CGFloat, color: Color,
        lifted: Bool = false
    ) {
        let shadowDrop = radius * (lifted ? 0.72 : 0.52)
        let shadowScale = lifted ? 0.72 : 0.92

        // 1. Contact shadow, UNDER the piece. Shrinks, drops away and softens as it lifts, which
        //    is most of what sells a hop as leaving the board.
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - radius * shadowScale,
                y: centre.y + shadowDrop - radius * 0.18,
                width: radius * 2 * shadowScale,
                height: radius * 0.46)),
            with: .color(.black.opacity(lifted ? 0.13 : 0.26)))

        // 2. Base: a squashed ellipse the piece stands on.
        let baseRY = radius * 0.22
        let baseY = centre.y + radius * 0.52
        ctx.fill(
            Path(ellipseIn: CGRect(x: centre.x - radius * 0.50, y: baseY - baseRY,
                                   width: radius, height: baseRY * 2)),
            with: .linearGradient(
                Gradient(colors: [color, darken(color, 0.34)]),
                startPoint: CGPoint(x: centre.x, y: baseY - baseRY),
                endPoint: CGPoint(x: centre.x, y: baseY + baseRY)))

        // 3. Waist: two mirrored curves from the base up to the neck. This is the silhouette
        //    that says "pawn" — a cylinder would read as a checker.
        var waist = Path()
        waist.move(to: CGPoint(x: centre.x - radius * 0.50, y: baseY))
        waist.addQuadCurve(
            to: CGPoint(x: centre.x - radius * 0.22, y: centre.y - radius * 0.10),
            control: CGPoint(x: centre.x - radius * 0.46, y: centre.y + radius * 0.10))
        waist.addLine(to: CGPoint(x: centre.x + radius * 0.22, y: centre.y - radius * 0.10))
        waist.addQuadCurve(
            to: CGPoint(x: centre.x + radius * 0.50, y: baseY),
            control: CGPoint(x: centre.x + radius * 0.46, y: centre.y + radius * 0.10))
        waist.closeSubpath()
        ctx.fill(waist, with: .linearGradient(
            Gradient(colors: [lighten(color, 0.20), color, darken(color, 0.28)]),
            startPoint: CGPoint(x: centre.x - radius * 0.5, y: centre.y),
            endPoint: CGPoint(x: centre.x + radius * 0.5, y: centre.y)))

        // 4. Collar: the thin band between waist and head. The detail that makes it read as
        //    MOULDED rather than carved.
        ctx.fill(
            Path(ellipseIn: CGRect(x: centre.x - radius * 0.30,
                                   y: centre.y - radius * 0.20,
                                   width: radius * 0.60, height: radius * 0.16)),
            with: .color(lighten(color, 0.12)))

        // 5. Head.
        let head = CGRect(x: centre.x - radius * 0.34, y: centre.y - radius * 0.78,
                          width: radius * 0.68, height: radius * 0.68)
        ctx.fill(Path(ellipseIn: head), with: .linearGradient(
            Gradient(colors: [lighten(color, 0.30), color, darken(color, 0.24)]),
            startPoint: CGPoint(x: head.minX, y: head.minY),
            endPoint: CGPoint(x: head.maxX, y: head.maxY)))

        // 6. Specular on the head's upper-left, and a rim light on the lower-right. Two lights
        //    is what separates gloss from a flat fill.
        ctx.fill(
            Path(ellipseIn: CGRect(x: head.minX + head.width * 0.16,
                                   y: head.minY + head.height * 0.12,
                                   width: head.width * 0.30, height: head.height * 0.26)),
            with: .color(.white.opacity(0.72)))
        ctx.stroke(
            Path(ellipseIn: head.insetBy(dx: radius * 0.03, dy: radius * 0.03)),
            with: .color(.white.opacity(0.25)),
            lineWidth: max(0.6, radius * 0.05))
    }

    static func token(
        in ctx: GraphicsContext, centre: CGPoint, radius: CGFloat, color: Color,
        lifted: Bool = false
    ) {
        // THE BODY STAYS ON `centre`. An earlier version shifted it up to make room for the
        // shadow, which drifted every token visibly off the square the rules say it occupies —
        // the piece and its position must agree, so the shadow moves instead.
        let shadowDrop = radius * (lifted ? 0.62 : 0.40)
        let shadowScale = lifted ? 0.80 : 0.94

        // 1. Contact shadow, UNDER the piece. It shrinks, drops away and softens as the piece
        //    lifts, which is most of what sells a hop as leaving the surface (LUDO.md §9).
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - radius * shadowScale,
                y: centre.y + shadowDrop - radius * 0.22,
                width: radius * 2 * shadowScale,
                height: radius * 0.52)),
            with: .color(.black.opacity(lifted ? 0.14 : 0.24)))

        let body = CGRect(x: centre.x - radius, y: centre.y - radius,
                          width: radius * 2, height: radius * 2)

        // 2. Body: lit from above.
        ctx.fill(
            Path(ellipseIn: body),
            with: .linearGradient(
                Gradient(colors: [
                    lighten(color, 0.28),
                    color,
                    darken(color, 0.30),
                ]),
                startPoint: CGPoint(x: body.midX, y: body.minY),
                endPoint: CGPoint(x: body.midX, y: body.maxY)))

        // A darker rim, so the piece has an edge rather than fading into the board.
        ctx.stroke(Path(ellipseIn: body), with: .color(darken(color, 0.45).opacity(0.55)),
                   lineWidth: max(0.8, radius * 0.07))

        // 3. Specular: small, off-centre, up-left. Placement matters more than size — centred,
        //    it reads as a hole; offset, it reads as a curved surface catching a light.
        let hi = CGRect(
            x: body.midX - radius * 0.52, y: body.midY - radius * 0.62,
            width: radius * 0.62, height: radius * 0.44)
        ctx.fill(Path(ellipseIn: hi), with: .color(.white.opacity(0.42)))
    }

    // MARK: - Colour helpers

    static func lighten(_ c: Color, _ amount: Double) -> Color {
        Color(UIColor(c).blended(with: .white, amount: amount))
    }

    static func darken(_ c: Color, _ amount: Double) -> Color {
        Color(UIColor(c).blended(with: .black, amount: amount))
    }
}

private extension UIColor {
    /// Mix toward another colour in sRGB. Good enough for shading a game piece, and it avoids
    /// pulling in a colour-space dependency for what is a lerp.
    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = max(0, min(1, amount))
        return UIColor(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            alpha: a1)
    }
}
