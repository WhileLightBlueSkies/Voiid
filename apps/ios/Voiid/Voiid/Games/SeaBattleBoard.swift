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
    /// The aiming reticle, if any.
    var reticle: Int?
    /// Cell the shell is currently falling on, drawn mid-flight.
    var firing: Int?
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
                        draw(ctx: ctx, cellSize: cellSize)
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

    private func draw(ctx: GraphicsContext, cellSize: CGFloat) {
        for index in 0..<SeaBattle.cells {
            let x = CGFloat(SeaBattle.cx(index)) * cellSize
            let y = CGFloat(SeaBattle.cy(index)) * cellSize
            let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize).insetBy(dx: 0.6, dy: 0.6)
            let state = index < cells.count ? cells[index] : .water

            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(fill(state)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 1.5),
                       with: .color(ink.opacity(0.12)), lineWidth: 0.5)

            // HIT AND MISS DIFFER IN SHAPE AND FILL BEFORE THEY DIFFER IN COLOUR (§8.4).
            // Snake identifies players by colour alone and CROSS_CUTTING.md §13 flags that as a
            // problem for ~8% of men; hit/miss is the most important read in this game, so the
            // board must survive being rendered in greyscale.
            switch state {
            case .miss:
                // A small hollow ring. Recedes.
                let r = cellSize * 0.18
                let c = CGPoint(x: rect.midX, y: rect.midY)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(ink.opacity(0.5)), lineWidth: 1.2)
            case .hit, .shipHit:
                // A large filled mark. Advances.
                let r = cellSize * 0.30
                let c = CGPoint(x: rect.midX, y: rect.midY)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 0.72, green: 0.22, blue: 0.15)))
            case .sunk:
                ctx.fill(Path(roundedRect: rect.insetBy(dx: cellSize * 0.12, dy: cellSize * 0.12),
                              cornerRadius: 1.5),
                         with: .color(Color(red: 0.42, green: 0.13, blue: 0.10)))
            default:
                break
            }
        }

        if let reticle {
            let rect = cellRect(reticle, cellSize: cellSize)
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 2),
                       with: .color(Color(red: 0.72, green: 0.22, blue: 0.15)), lineWidth: 2)
        }

        if let firing {
            let rect = cellRect(firing, cellSize: cellSize)
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: cellSize * 0.34, dy: cellSize * 0.34)),
                     with: .color(ink.opacity(0.8)))
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
        case .ship:    return ink.opacity(0.62)
        case .shipHit: return ink.opacity(0.45)
        }
    }
}
