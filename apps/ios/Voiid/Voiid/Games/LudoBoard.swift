//
//  LudoBoard.swift
//  Voiid
//
//  Ludo board geometry and the board renderer (docs/games/future/LUDO.md §6, §8).
//
//  THE GEOMETRY IS A LOOKUP TABLE, NOT DRAWING CODE. `squareCentre(position:seat:)` maps a
//  server position encoding to a point in normalised board space, and every token animation,
//  tap target and highlight reads from it. LUDO.md §6.2 is explicit about why: two hand-drawn
//  board layouts that disagree by a few points is exactly the parity drift ANDROID_IOS_PARITY.md
//  exists to prevent, and a table is checkable where drawing code is not.
//
//  The POSITION ENCODING is the server's, unchanged (backend/games/src/engine/ludo/board.ts):
//    -1        yard
//    0..51     main track, ABSOLUTE index
//    100..104  home column, 100 + step
//    200       home
//
//  Mirrors Android `LudoBoard.kt`. Port the constants literally.
//

import SwiftUI

enum Ludo {
    static let track = 52
    static let column = 5
    static let maxSeats = 4

    static let yard = -1
    static let columnBase = 100
    static let home = 200

    static func inYard(_ p: Int) -> Bool { p == yard }
    static func onTrack(_ p: Int) -> Bool { p >= 0 && p < track }
    static func inColumn(_ p: Int) -> Bool { p >= columnBase && p < columnBase + column }
    static func isHome(_ p: Int) -> Bool { p == home }

    static func entrySquare(_ seat: Int) -> Int { (seat * 13) % track }

    /// The eight starred squares. The board must TEACH this rule, so they are drawn (§8.1).
    static let safeSquares: Set<Int> = [0, 8, 13, 21, 26, 34, 39, 47]
    static func isSafe(_ p: Int) -> Bool { onTrack(p) && safeSquares.contains(p) }

    /// Four colours that are ALSO distinguishable by shape (§8.1).
    ///
    /// Ludo is traditionally colour-only and that is precisely the trap: CROSS_CUTTING.md §13
    /// flags Snake identifying players by colour alone as a problem for ~8% of men, and with four
    /// players it is four times worse. Each seat carries a distinct marker — dot, ring, cross,
    /// bar — on the token face, in the strip and in the yard.
    static let seatColors: [Color] = [
        Color(red: 0.85, green: 0.27, blue: 0.24),   // red
        Color(red: 0.20, green: 0.51, blue: 0.78),   // blue
        Color(red: 0.25, green: 0.62, blue: 0.35),   // green
        Color(red: 0.94, green: 0.71, blue: 0.20),   // yellow
    ]
    static let seatMarkers = ["circle.fill", "circle", "xmark", "minus"]
    static let seatNames = ["Red", "Blue", "Green", "Yellow"]

    // MARK: - The lookup table

    /// The 52 main-track squares, in order, on a 15x15 grid. Index 0 is seat 0's entry.
    ///
    /// DERIVED, THEN PINNED. This was not typed by hand — it is the traced perimeter of the
    /// standard cross (the union of rows and columns 6-8, minus the centre plus and the four
    /// 5-cell home columns), with the four cells diagonally adjacent to the centre removed. It
    /// is written out as a literal rather than generated at runtime because the array is the
    /// thing both platforms must agree on, and a literal can be diffed where a generator cannot.
    ///
    /// The count and the entry squares are the properties that matter and they are asserted in
    /// `LudoBoardTests`: 52 cells, no duplicates, and entries at indices 0/13/26/39 landing on
    /// the four arm mouths — which is what makes this table agree with the server's
    /// `entrySquare(seat) = seat * 13`.
    ///
    /// FOUR OF THE 52 STEPS ARE DIAGONAL, at the arm corners, and that is inherent rather than a
    /// defect: a 52-cell ring on a 15x15 cross cannot be orthogonal the whole way round — the
    /// orthogonal perimeter is 56. The four corner cells are the ones a physical board draws as
    /// the turn into the next arm, and a token cutting that corner reads correctly in motion.
    /// Stated here because "why are there diagonal steps" is otherwise a bug report.
    static let trackCells: [(Int, Int)] = [
        (6, 13), (6, 12), (6, 11), (6, 10), (6, 9), (5, 8),
        (4, 8), (3, 8), (2, 8), (1, 8), (0, 8), (0, 7),
        (0, 6), (1, 6), (2, 6), (3, 6), (4, 6), (5, 6),
        (6, 5), (6, 4), (6, 3), (6, 2), (6, 1), (6, 0),
        (7, 0), (8, 0), (8, 1), (8, 2), (8, 3), (8, 4),
        (8, 5), (9, 6), (10, 6), (11, 6), (12, 6), (13, 6),
        (14, 6), (14, 7), (14, 8), (13, 8), (12, 8), (11, 8),
        (10, 8), (9, 8), (8, 9), (8, 10), (8, 11), (8, 12),
        (8, 13), (8, 14), (7, 14), (6, 14),
    ]

    /// The 5 home-column squares per seat, running inward toward the centre.
    ///
    /// Five, matching the server's `COLUMN = 5`. The sixth cell of each middle lane is the arm
    /// mouth and belongs to the track, which is exactly what makes the ring 52 rather than 56.
    static let columnCells: [[(Int, Int)]] = [
        [(7, 13), (7, 12), (7, 11), (7, 10), (7, 9)],   // seat 0, up from the bottom
        [(1, 7), (2, 7), (3, 7), (4, 7), (5, 7)],       // seat 1, in from the left
        [(7, 1), (7, 2), (7, 3), (7, 4), (7, 5)],       // seat 2, down from the top
        [(13, 7), (12, 7), (11, 7), (10, 7), (9, 7)],   // seat 3, in from the right
    ]

    /// The four yard pockets, four slots each.
    static let yardCells: [[(Int, Int)]] = [
        [(2, 11), (4, 11), (2, 13), (4, 13)],   // seat 0, bottom-left
        [(2, 2), (4, 2), (2, 4), (4, 4)],       // seat 1, top-left
        [(10, 2), (12, 2), (10, 4), (12, 4)],   // seat 2, top-right
        [(10, 10), (12, 10), (10, 12), (12, 12)], // seat 3, bottom-right
    ]

    static let gridSize = 15

    /// Where a token sits, in normalised board space (0...1 on both axes).
    ///
    /// `tokenIndex` only matters in the yard, where four tokens occupy four distinct slots;
    /// everywhere else a seat's tokens can legitimately share a square (a block or a safe stack)
    /// and the renderer fans them out rather than the table doing it.
    static func squareCentre(position: Int, seat: Int, tokenIndex: Int = 0) -> CGPoint {
        let cell: (Int, Int)
        if isHome(position) {
            cell = (7, 7)                                   // the centre triangle
        } else if inColumn(position) {
            let step = min(position - columnBase, column - 1)
            cell = columnCells[seat % maxSeats][step]
        } else if onTrack(position) {
            cell = trackCells[position % track]
        } else {
            cell = yardCells[seat % maxSeats][tokenIndex % 4]
        }
        let unit = 1.0 / CGFloat(gridSize)
        return CGPoint(x: (CGFloat(cell.0) + 0.5) * unit, y: (CGFloat(cell.1) + 0.5) * unit)
    }
}
