//
//  SeaBattleBoard.swift
//  Voiid
//
//  Board geometry, fleet rules and the two grid renderers for Sea Battle
//  (docs/games/future/SEA_BATTLE.md §6, §8).
//
//  THE RULES IN HERE ARE A MIRROR, NOT AN AUTHORITY. The server validates every fleet and
//  resolves every shot; this file exists so the placement UI can show a ship red before the
//  player drops it, and so the Random button can produce something without a round trip.
//  Anything it decides that the server would decide differently is a bug in this file — the
//  server is the referee (GAMES.md §1) and the frame is always the truth.
//
//  Ported literally to Android `SeaBattleBoard.kt`. The constants below are the parity
//  surface: SNAKE.md §2.4 records two renderers that "were ported line-for-line including the
//  bug", and warns that divergent constants are how two builds of one game end up feeling
//  different.
//

import SwiftUI

// MARK: - Geometry

enum SeaBattle {
    /// 10x10, columns A–J, rows 1–10.
    static let size = 10
    static let cells = size * size

    /// Coordinates are ONE packed integer, never a string. "B10" and "B1" differ by a
    /// character and a client that misparses that fires at the wrong square silently.
    static func packed(_ x: Int, _ y: Int) -> Int { y * size + x }
    static func cx(_ c: Int) -> Int { c % size }
    static func cy(_ c: Int) -> Int { c / size }

    /// The classic Milton Bradley set — 17 squares of 100. Index is the type id on the wire.
    ///
    /// The SERVER sends `fleetSpec` in every frame and the renderer should prefer that; this is
    /// the fallback for the placement screen, which runs before any frame has arrived.
    static let fleetSpec = [5, 4, 3, 3, 2]
    static let shipNames = ["Carrier", "Battleship", "Cruiser", "Submarine", "Destroyer"]
    static let fleetCells = 17

    /// `A`…`J` — shown on both boards, because a player calling out "D7" in the chat has to be
    /// able to read D7 off the screen.
    static func columnLabel(_ x: Int) -> String {
        String(UnicodeScalar(UInt8(65 + x)))
    }

    static func coordLabel(_ cell: Int) -> String {
        "\(columnLabel(cx(cell)))\(cy(cell) + 1)"
    }
}

// MARK: - Fleet rules

/// A ship being placed, or one the server told us about.
struct SeaBattleShip: Equatable, Identifiable {
    var type: Int
    var cells: [Int]
    var hits: Int = 0

    var id: Int { type }
    var isSunk: Bool { hits >= cells.count }
    var name: String { SeaBattle.shipNames[min(type, SeaBattle.shipNames.count - 1)] }
}

enum SeaBattleRules {
    /// Contiguous and collinear along one row or one column.
    ///
    /// THIS ONE CHECK IS WHAT ENFORCES "NO DIAGONALS" — a diagonal ship is by definition in
    /// neither a single row nor a single column, so there is no separate diagonal rule.
    ///
    /// It also catches row wrap: packed cells 9 and 10 are consecutive integers but sit on
    /// different rows, so a Destroyer running off column J would pass a naive `next == prev + 1`
    /// check. Requiring an identical row for a horizontal ship rejects it.
    static func isContiguousLine(_ cells: [Int]) -> Bool {
        guard cells.count > 1 else { return true }
        let sameRow = cells.allSatisfy { SeaBattle.cy($0) == SeaBattle.cy(cells[0]) }
        let sameCol = cells.allSatisfy { SeaBattle.cx($0) == SeaBattle.cx(cells[0]) }
        guard sameRow || sameCol else { return false }
        let step = sameRow ? 1 : SeaBattle.size
        let sorted = cells.sorted()
        for i in 1..<sorted.count where sorted[i] - sorted[i - 1] != step { return false }
        return true
    }

    /// Why a fleet is illegal, or nil when it is fine. Distinct reasons because the placement
    /// UI renders a different message for each — "that ship is invalid" teaches the player
    /// nothing about what to do differently.
    enum Failure: Equatable {
        case wrongShipCount, duplicateType, unknownType, wrongLength, offBoard, notContiguous, overlap

        var message: String {
            switch self {
            case .wrongShipCount: return "Place all five ships"
            case .duplicateType:  return "Two ships of the same kind"
            case .unknownType:    return "Unknown ship"
            case .wrongLength:    return "That ship is the wrong length"
            case .offBoard:       return "That ship is off the board"
            case .notContiguous:  return "Ships must be straight, along a row or a column"
            case .overlap:        return "Ships cannot overlap"
            }
        }
    }

    /// The same checks, in the same order, as `backend/games/src/engine/seabattle/fleet.ts`.
    /// Order matters for the message the player sees: overlap is reported before contiguity
    /// on the server, so it must be here too or the two disagree about *why* a fleet failed.
    static func validate(_ ships: [SeaBattleShip]) -> Failure? {
        guard ships.count == SeaBattle.fleetSpec.count else { return .wrongShipCount }

        var seenTypes = Set<Int>()
        var occupied = Set<Int>()

        for ship in ships {
            guard ship.type >= 0, ship.type < SeaBattle.fleetSpec.count else { return .unknownType }
            guard !seenTypes.contains(ship.type) else { return .duplicateType }
            seenTypes.insert(ship.type)

            guard ship.cells.count == SeaBattle.fleetSpec[ship.type] else { return .wrongLength }

            for c in ship.cells {
                guard c >= 0, c < SeaBattle.cells else { return .offBoard }
                // Across the whole fleet, so this catches a ship doubling back on itself too.
                guard !occupied.contains(c) else { return .overlap }
                occupied.insert(c)
            }

            guard isContiguousLine(ship.cells) else { return .notContiguous }
        }

        return nil
    }

    /// Can this ship sit here, ignoring itself?
    ///
    /// Used for the live drag preview, which needs an answer per frame while the finger moves
    /// and cannot re-validate the whole fleet each time.
    static func canPlace(_ cells: [Int], avoiding others: [SeaBattleShip], length: Int) -> Bool {
        guard cells.count == length else { return false }
        guard cells.allSatisfy({ $0 >= 0 && $0 < SeaBattle.cells }) else { return false }
        guard isContiguousLine(cells) else { return false }
        let taken = Set(others.flatMap { $0.cells })
        return !cells.contains(where: { taken.contains($0) })
    }

    /// The cells a ship of `length` would occupy from an origin.
    static func run(from origin: Int, length: Int, horizontal: Bool) -> [Int] {
        let x = SeaBattle.cx(origin), y = SeaBattle.cy(origin)
        // Clamped so a ship dragged past the edge slides back on-board rather than vanishing —
        // a ship that disappears under the finger reads as a bug, not as a rejection.
        let ox = horizontal ? min(x, SeaBattle.size - length) : x
        let oy = horizontal ? y : min(y, SeaBattle.size - length)
        return (0..<length).map {
            horizontal ? SeaBattle.packed(ox + $0, oy) : SeaBattle.packed(ox, oy + $0)
        }
    }

    /// A legal fleet placed at random.
    ///
    /// MANDATORY AND THE DEFAULT PATH (§2.2): a player who must place five ships before their
    /// first shot may never reach the first shot. The board arrives already populated and
    /// READY is one tap.
    ///
    /// Unlike the server's version this uses the system RNG, deliberately — it produces only
    /// the caller's own fleet, which is about to be sent to the server anyway, so there is
    /// nothing here that has to be reproducible from a seed.
    static func randomFleet() -> [SeaBattleShip] {
        for _ in 0..<200 {
            var ships: [SeaBattleShip] = []
            var occupied = Set<Int>()
            var ok = true

            // Longest first: a Carrier placed last into a crowded board is what fails.
            for (type, length) in SeaBattle.fleetSpec.enumerated() {
                var placed = false
                for _ in 0..<100 where !placed {
                    let horizontal = Bool.random()
                    let x = Int.random(in: 0..<(horizontal ? SeaBattle.size - length + 1 : SeaBattle.size))
                    let y = Int.random(in: 0..<(horizontal ? SeaBattle.size : SeaBattle.size - length + 1))
                    let cells = (0..<length).map {
                        horizontal ? SeaBattle.packed(x + $0, y) : SeaBattle.packed(x, y + $0)
                    }
                    if cells.contains(where: { occupied.contains($0) }) { continue }
                    cells.forEach { occupied.insert($0) }
                    ships.append(SeaBattleShip(type: type, cells: cells))
                    placed = true
                }
                if !placed { ok = false; break }
            }

            if ok { return ships }
        }

        // Unreachable in practice. A dull legal fleet still beats throwing inside a match.
        return SeaBattle.fleetSpec.enumerated().map { type, length in
            SeaBattleShip(type: type, cells: (0..<length).map { SeaBattle.packed($0, type) })
        }
    }
}

// MARK: - Cell rendering

/// What one square shows. Derived from the frame, never from a local guess about a shot.
enum SeaBattleCell: Equatable {
    case water
    case miss
    case hit
    case sunk
    /// One of my own ships, undamaged. Only ever drawn on my own board.
    case ship
    /// One of my own ships, hit.
    case shipHit
}

/// A grid of 100 squares.
///
/// PLAIN SWIFTUI, NOT METAL. SnakeMetalView exists because Snake draws six SDF-shaded
/// polylines at 60 fps; this draws 100 static rounded rects and at most one animating shell.
/// GAMES.md §4 specifies exactly this split.
struct SeaBattleGrid: View {
    let cells: [SeaBattleCell]
    /// Ships to draw as HULLS rather than as cell fills (§6.3).
    ///
    /// Passed in rather than derived from `cells`, because a cell state cannot tell you which
    /// ship it belongs to or which way that ship points — that is the whole reason ships have
    /// to be drawn per ship. Empty on the enemy board until the terminal frame reveals a fleet.
    var ships: [SeaBattleShip] = []
    /// Ship type ids that have been sunk, so a wreck can be drawn as a wreck.
    var sunkTypes: Set<Int> = []
    /// The aiming reticle, if any.
    var reticle: Int?
    /// Cell the shell is currently falling on, drawn mid-flight.
    var firing: Int?
    /// 0...1 through the shell's travel, so the reticle can contract to a point (§9).
    var shellProgress: Double = 0
    /// Cells of a ship that has just been sunk, revealed one at a time (§9).
    var sunkReveal: [Int] = []
    /// Dimmed when it is not the board the player should be looking at.
    var dimmed: Bool = false
    var showLabels: Bool = true
    var onTap: ((Int) -> Void)?
    var onDrag: ((Int) -> Void)?

    /// Ink on paper (§8.2). Not naval-realistic and not Snake's retro-neon: the fiction is a
    /// naval chart, which is what the player is actually working, and it makes "nothing moves"
    /// an aesthetic rather than a limitation.
    private let ink = Color(red: 0.16, green: 0.21, blue: 0.28)
    private let paper = Color(red: 0.93, green: 0.91, blue: 0.86)
    private let sea = Color(red: 0.80, green: 0.85, blue: 0.87)

    var body: some View {
        // A LIVE CLOCK, at a deliberately low rate.
        //
        // §8.2 asks for "a barely-perceptible caustic shimmer, ~0.04 amplitude, 8-second period"
        // whose whole job is to prove the screen is alive during the long pauses of an async
        // match. 20 fps is plenty for something that slow, and a board game has no reason to
        // hold the display at 120 Hz — the shimmer must not cost more than the game does.
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { timeline in
            content(now: timeline.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(now: TimeInterval) -> some View {
        GeometryReader { geo in
            let labelSpace: CGFloat = showLabels ? 14 : 0
            let side = min(geo.size.width - labelSpace, geo.size.height - labelSpace)
            let cellSize = side / CGFloat(SeaBattle.size)

            ZStack(alignment: .topLeading) {
                if showLabels {
                    labels(cellSize: cellSize, origin: labelSpace)
                }

                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        draw(ctx: ctx, cellSize: cellSize, now: now)
                    }
                    .frame(width: side, height: side)
                }
                .offset(x: labelSpace, y: labelSpace)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard let cell = hit(g.location, cellSize: cellSize, origin: labelSpace) else { return }
                            onDrag?(cell)
                        }
                        .onEnded { g in
                            guard let cell = hit(g.location, cellSize: cellSize, origin: labelSpace) else { return }
                            onTap?(cell)
                        }
                )
            }
            .opacity(dimmed ? 0.6 : 1)
            .animation(.easeInOut(duration: 0.32), value: dimmed)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func hit(_ p: CGPoint, cellSize: CGFloat, origin: CGFloat) -> Int? {
        let x = Int((p.x - origin) / cellSize)
        let y = Int((p.y - origin) / cellSize)
        guard x >= 0, x < SeaBattle.size, y >= 0, y < SeaBattle.size else { return nil }
        return SeaBattle.packed(x, y)
    }

    private func labels(cellSize: CGFloat, origin: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<SeaBattle.size, id: \.self) { i in
                Text(SeaBattle.columnLabel(i))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.55))
                    .frame(width: cellSize, height: origin)
                    .offset(x: origin + CGFloat(i) * cellSize, y: 0)
                Text("\(i + 1)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.55))
                    .frame(width: origin, height: cellSize)
                    .offset(x: 0, y: origin + CGFloat(i) * cellSize)
            }
        }
    }

    private func draw(ctx: GraphicsContext, cellSize: CGFloat, now: TimeInterval) {
        // THE CHART UNDER THE WATER (§8.2). Paper and ink, not naval realism — the fiction is
        // that you are working a problem on a naval chart, which is what the player is actually
        // doing, and it makes "nothing moves" a deliberate aesthetic rather than a limitation.
        let board = CGRect(x: 0, y: 0,
                           width: cellSize * CGFloat(SeaBattle.size),
                           height: cellSize * CGFloat(SeaBattle.size))
        GameSurface.paper(in: ctx, rect: board, base: paper, grain: 0.020, seed: 3)

        for index in 0..<SeaBattle.cells {
            let x = CGFloat(SeaBattle.cx(index)) * cellSize
            let y = CGFloat(SeaBattle.cy(index)) * cellSize
            let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize).insetBy(dx: 0.6, dy: 0.6)
            let state = index < cells.count ? cells[index] : .water

            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(fill(state)))

            // WATER SHIMMER on anything still unknown. Each cell gets its own phase from a
            // positional hash, so the surface moves as a field rather than pulsing in unison —
            // one board-wide sine would read as the whole screen breathing.
            if state == .water {
                let phase = GameSurface.noise(SeaBattle.cx(index), SeaBattle.cy(index), seed: 5)
                let wave = sin(now * 0.79 + phase * 6.28)
                // ~0.04 amplitude, per §8.2. Just enough to prove the screen is alive.
                let caustic = 0.04 * (0.5 + 0.5 * wave)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                         with: .color(.white.opacity(caustic)))
                // A slow diagonal glint across a small fraction of cells.
                if phase > 0.86 {
                    let g = 0.05 * (0.5 + 0.5 * sin(now * 0.51 + phase * 9.4))
                    ctx.fill(Path(roundedRect: rect.insetBy(dx: cellSize * 0.3, dy: cellSize * 0.34),
                                  cornerRadius: 1),
                             with: .color(.white.opacity(g)))
                }
            }

            // Every square is pressed into the chart, one light direction shared app-wide.
            GameSurface.inset(in: ctx, rect: rect, radius: 1.5, depth: 0.6)

            // HIT AND MISS DIFFER IN SHAPE AND FILL BEFORE THEY DIFFER IN COLOUR (§8.4).
            // Snake identifies players by colour alone and CROSS_CUTTING.md §13 flags that as a
            // problem for ~8% of men; hit/miss is the most important read in this game, so the
            // board must survive being rendered in greyscale.
            switch state {
            case .miss:
                // A SPLASH: a hollow ring with two fainter rings still spreading. Recedes.
                let c = CGPoint(x: rect.midX, y: rect.midY)
                let r = cellSize * 0.18
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(ink.opacity(0.5)), lineWidth: 1.2)
                for (i, scale) in [1.55, 2.05].enumerated() {
                    let rr = r * scale
                    ctx.stroke(
                        Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                        with: .color(ink.opacity(0.16 - Double(i) * 0.06)), lineWidth: 0.7)
                }
            case .hit, .shipHit:
                // A SCORCH: a dark burn with a ragged rim and a hot centre. Advances.
                let c = CGPoint(x: rect.midX, y: rect.midY)
                let r = cellSize * 0.32
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 0.95, green: 0.55, blue: 0.15),
                            Color(red: 0.72, green: 0.22, blue: 0.15),
                            Color(red: 0.30, green: 0.10, blue: 0.08),
                        ]),
                        center: c, startRadius: 0, endRadius: r))
                // Debris: a few specks thrown clear, seeded per cell so they never move.
                for k in 0..<4 {
                    let a = GameSurface.noise(index, k, seed: 21) * 6.28
                    let d = r * (1.15 + GameSurface.noise(index, k, seed: 22) * 0.5)
                    let p = CGPoint(x: c.x + CoreGraphics.cos(a) * d, y: c.y + CoreGraphics.sin(a) * d)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 0.8, y: p.y - 0.8, width: 1.6, height: 1.6)),
                             with: .color(ink.opacity(0.35)))
                }
            case .sunk:
                // A SUNK HULL, still burning. The flame flickers on its own phase so a
                // multi-cell wreck does not pulse as one block.
                ctx.fill(Path(roundedRect: rect.insetBy(dx: cellSize * 0.10, dy: cellSize * 0.10),
                              cornerRadius: 1.5),
                         with: .color(Color(red: 0.24, green: 0.09, blue: 0.07)))
                let phase = GameSurface.noise(SeaBattle.cx(index), SeaBattle.cy(index), seed: 9)
                let flicker = 0.5 + 0.5 * sin(now * 6.1 + phase * 6.28)
                let fh = cellSize * (0.26 + 0.16 * flicker)
                let c = CGPoint(x: rect.midX, y: rect.midY)
                var flame = Path()
                flame.move(to: CGPoint(x: c.x - cellSize * 0.14, y: c.y + cellSize * 0.10))
                flame.addQuadCurve(
                    to: CGPoint(x: c.x, y: c.y + cellSize * 0.10 - fh),
                    control: CGPoint(x: c.x - cellSize * 0.18, y: c.y - fh * 0.3))
                flame.addQuadCurve(
                    to: CGPoint(x: c.x + cellSize * 0.14, y: c.y + cellSize * 0.10),
                    control: CGPoint(x: c.x + cellSize * 0.18, y: c.y - fh * 0.3))
                flame.closeSubpath()
                ctx.fill(flame, with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 1.0, green: 0.85, blue: 0.35).opacity(0.95),
                        Color(red: 0.92, green: 0.36, blue: 0.10).opacity(0.75),
                        Color(red: 0.55, green: 0.12, blue: 0.05).opacity(0.0),
                    ]),
                    startPoint: CGPoint(x: c.x, y: c.y + cellSize * 0.10),
                    endPoint: CGPoint(x: c.x, y: c.y + cellSize * 0.10 - fh)))
            default:
                break
            }
        }

        // SHIPS, AS SHIPS. After the cells so a hull sits on the water, before the markers so
        // a scorch lands ON the hull rather than under it.
        for ship in ships {
            drawShip(ship, in: ctx, cellSize: cellSize)
        }

        if let reticle {
            let rect = cellRect(reticle, cellSize: cellSize)
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 2),
                       with: .color(Color(red: 0.72, green: 0.22, blue: 0.15)), lineWidth: 2)
        }

        // THE BOMB (§6.4). A real projectile lobbed from a cannon at the near edge, replacing
        // the contracting reticle that used to stand in for one.
        //
        // THE 380 ms FLIGHT IS THE SAME BUDGET AS BEFORE — it is the window the server's answer
        // arrives in, and stretching it would add latency for decoration. Only the drawing
        // changed.
        //
        // THREE DETAILS SELL THE ARC, and none of them is optional:
        //   * the bomb SCALES along the flight (1.0 -> 1.55 -> 0.85), which is perspective in a
        //     top-down view and the difference between "thrown" and "slid";
        //   * a SHADOW tracks the straight muzzle->target line at ground level while the bomb
        //     arcs above it — without it the arc reads as the bomb moving sideways;
        //   * it TUMBLES, 2.5 turns over the flight.
        if let firing {
            let rect = cellRect(firing, cellSize: cellSize)
            let t = max(0, min(1, shellProgress))
            let board = cellSize * CGFloat(SeaBattle.size)

            // The muzzle sits at the near edge, centred — the cannon in the reference art.
            let muzzle = CGPoint(x: board / 2, y: board + cellSize * 0.35)
            let target = CGPoint(x: rect.midX, y: rect.midY)

            // Ground track: the straight line the shadow walks.
            let ground = CGPoint(x: muzzle.x + (target.x - muzzle.x) * t,
                                 y: muzzle.y + (target.y - muzzle.y) * t)

            // Arc height scales with distance, clamped so a near shot still lobs and a far one
            // does not leave the board.
            let distanceCells = hypot(target.x - muzzle.x, target.y - muzzle.y) / cellSize
            let arc = min(max(distanceCells * 0.28, 0.9), 3.2) * cellSize
            let lift = arc * 4 * t * (1 - t)          // parabola, zero at both ends

            let bomb = CGPoint(x: ground.x, y: ground.y - lift)
            let scale = 1.0 + 0.55 * sin(t * .pi) - 0.15 * t
            let radius = cellSize * 0.20 * scale

            // Shadow first, on the water, shrinking as the bomb climbs away from it.
            let shadowR = cellSize * 0.15 * (1 - 0.35 * sin(t * .pi))
            ctx.fill(
                Path(ellipseIn: CGRect(x: ground.x - shadowR, y: ground.y - shadowR * 0.5,
                                       width: shadowR * 2, height: shadowR)),
                with: .color(ink.opacity(0.28)))

            // The bomb: a dark round body with a lit shoulder and a fuse spark, tumbling.
            var body = ctx
            body.translateBy(x: bomb.x, y: bomb.y)
            body.rotate(by: .radians(t * 2.5 * 2 * .pi))
            body.fill(
                Path(ellipseIn: CGRect(x: -radius, y: -radius,
                                       width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color(red: 0.42, green: 0.44, blue: 0.48),
                                      Color(red: 0.12, green: 0.13, blue: 0.16)]),
                    center: CGPoint(x: -radius * 0.3, y: -radius * 0.3),
                    startRadius: 0, endRadius: radius * 1.6))
            body.fill(
                Path(ellipseIn: CGRect(x: radius * 0.35, y: -radius * 0.95,
                                       width: radius * 0.5, height: radius * 0.5)),
                with: .color(Color(red: 1.0, green: 0.74, blue: 0.28).opacity(0.9)))

            // The reticle stays on the target the whole way, so the player never loses track of
            // where the bomb is going to land.
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 2),
                       with: .color(Color(red: 0.72, green: 0.22, blue: 0.15).opacity(0.5)),
                       lineWidth: 1.5)
        }

        // THE SUNK OUTLINE, DRAWN IN CELL BY CELL (§9). A ship that simply turns dark reads as a
        // state change; drawing it along its own hull reads as the ship going down, and it is
        // what makes the announcement land as a consequence rather than a label.
        for cell in sunkReveal where cell < SeaBattle.cells {
            let rect = cellRect(cell, cellSize: cellSize)
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 2),
                       with: .color(Color(red: 0.42, green: 0.13, blue: 0.10)), lineWidth: 2)
        }
    }

    /// One ship, drawn across its whole bounding box.
    ///
    /// A VERTICAL SHIP IS THE HORIZONTAL PATH ROTATED, not a second set of paths: two hand-drawn
    /// orientations is two things to keep in sync, and a hull is symmetric about its keel.
    private func drawShip(_ ship: SeaBattleShip, in ctx: GraphicsContext, cellSize: CGFloat) {
        guard let (rect, horizontal) = SeaBattleShipArt.frame(
            cells: ship.cells, cellSize: cellSize) else { return }

        let sunk = sunkTypes.contains(ship.type)
        // Unit space runs along the ship's LENGTH, so a vertical ship is drawn into a rotated
        // box of the same proportions.
        let length = horizontal ? rect.width : rect.height
        let beam = horizontal ? rect.height : rect.width

        var layer = ctx
        layer.translateBy(x: rect.midX, y: rect.midY)
        if !horizontal { layer.rotate(by: .degrees(90)) }
        // A sunk hull rolls and settles rather than simply turning dark — a state change reads
        // as a state change, a list reads as a ship going down.
        if sunk {
            layer.rotate(by: .degrees(8))
            layer.opacity = 0.85
        }
        layer.scaleBy(x: length, y: beam)
        layer.translateBy(x: -0.5, y: -0.5)

        let hull = SeaBattleShipArt.hull(type: ship.type)
        layer.fill(hull, with: .linearGradient(
            Gradient(colors: sunk
                     ? [SeaBattleShipArt.hullSunk, SeaBattleShipArt.hullSunk.opacity(0.8)]
                     : [SeaBattleShipArt.hullLit, SeaBattleShipArt.hullBody]),
            startPoint: CGPoint(x: 0.5, y: 0),
            endPoint: CGPoint(x: 0.5, y: 1)))
        // The outline is what makes it read at a 33 pt cell. Scaled inversely so it stays one
        // hairline wide however long the ship is.
        layer.stroke(hull, with: .color(SeaBattleShipArt.hullInk),
                     lineWidth: 1.6 / max(length, 1))

        for detail in SeaBattleShipArt.details(type: ship.type) {
            layer.fill(detail, with: .color(
                sunk ? SeaBattleShipArt.hullSunk : SeaBattleShipArt.hullDeck))
        }
    }

    private func cellRect(_ index: Int, cellSize: CGFloat) -> CGRect {
        CGRect(x: CGFloat(SeaBattle.cx(index)) * cellSize,
               y: CGFloat(SeaBattle.cy(index)) * cellSize,
               width: cellSize, height: cellSize).insetBy(dx: 0.6, dy: 0.6)
    }

    private func fill(_ state: SeaBattleCell) -> Color {
        switch state {
        case .water:   return sea.opacity(0.55)
        case .miss:    return sea.opacity(0.35)
        case .hit:     return paper
        case .sunk:    return paper
        // WATER, NOT INK. The hull is drawn over these cells by `drawShip`, so a filled square
        // underneath would show around the bow and stern where the silhouette narrows. A ship
        // sits ON the sea; the cell's job is now only to be sea.
        case .ship:    return sea.opacity(0.55)
        case .shipHit: return sea.opacity(0.55)
        }
    }
}

// MARK: - Deriving the two boards from a frame

/// What each square shows, derived from a frame.
///
/// SHARED BY THE ONLINE MATCH AND PRACTICE MODE, and that is the whole reason it is not a method
/// on either screen. The bot game builds a `SeaBattleState` that looks exactly like a server
/// frame, so both screens can read the board through the same two functions — which means a
/// player cannot tell a practice board from a real one, and a fix to one is a fix to both.
///
/// Every rule that decides what is visible lives here: their un-hit ships are never in a frame,
/// sunk outlines become public at the moment of sinking, and both fleets appear only once the
/// match is over.
enum SeaBattleCells {
    /// The OPPONENT's board as this player may see it: my shots, and any ship I have sunk.
    ///
    /// Their un-hit ships are not in the frame at all, so there is nothing here to accidentally
    /// draw — the projection is the server's, not this function's.
    static func enemy(_ s: SeaBattleState, mySeat: Int?) -> [SeaBattleCell] {
        var cells = [SeaBattleCell](repeating: .water, count: SeaBattle.cells)
        guard let seat = mySeat, s.shots.indices.contains(seat) else { return cells }
        let enemy = 1 - seat
        for (i, cell) in s.shots[seat].enumerated() where cell < cells.count {
            let result = s.results[seat].indices.contains(i) ? s.results[seat][i] : 0
            cells[cell] = result == 0 ? .miss : .hit
        }
        // Sunk outlines are public once the ship is down, and they are what makes the endgame
        // deduction rather than a grind (§2.4).
        if s.sunkCells.indices.contains(enemy) {
            for c in s.sunkCells[enemy] where c < cells.count { cells[c] = .sunk }
        }
        // Once the match is over the terminal frame carries both fleets, so the loser's unhit
        // ships finally appear. This is the ONLY path that draws an enemy ship that is not sunk.
        if s.finished, let revealed = s.revealedFleets, revealed.indices.contains(enemy) {
            for ship in revealed[enemy] {
                for c in ship.cells where c < cells.count && cells[c] == .water { cells[c] = .ship }
            }
        }
        return cells
    }

    /// This player's own board: their fleet, and the opponent's shots on it.
    ///
    /// `draft` covers the placement phase, where the frame has no fleet yet — the only point at
    /// which a local draft and a server fleet are interchangeable, and only because nothing has
    /// been committed.
    static func own(
        _ s: SeaBattleState, mySeat: Int?, draft: [SeaBattleShip] = []
    ) -> [SeaBattleCell] {
        var cells = [SeaBattleCell](repeating: .water, count: SeaBattle.cells)
        let fleet = s.myFleet.isEmpty
            ? draft.map { SeaBattleState.Ship(type: $0.type, cells: $0.cells, hits: $0.hits) }
            : s.myFleet
        for ship in fleet {
            for c in ship.cells where c < cells.count { cells[c] = .ship }
        }
        guard let seat = mySeat else { return cells }
        let enemy = 1 - seat
        if s.shots.indices.contains(enemy) {
            for (i, cell) in s.shots[enemy].enumerated() where cell < cells.count {
                let result = s.results[enemy].indices.contains(i) ? s.results[enemy][i] : 0
                cells[cell] = result == 0 ? .miss : .shipHit
            }
        }
        if s.sunkCells.indices.contains(seat) {
            for c in s.sunkCells[seat] where c < cells.count { cells[c] = .sunk }
        }
        return cells
    }
}
