//
//  CarromTheme.swift
//  Voiid Ui
//
//  Visual identity and geometry constants for the Carrom board.
//  Curated according to the Voiid design system and traditional Indian carrom proportions.
//

import SwiftUI

enum CarromTheme {

    // MARK: - Geometry & Proportions (Normalized to Virtual Board 360x360)

    /// The canonical virtual coordinate space of the playing surface (excluding outer rosewood frame).
    static let surfaceSize: CGFloat = 360
    /// Outer frame border thickness.
    static let frameThickness: CGFloat = 24
    /// Total board dimension including outer wooden frame.
    static let totalBoardSize: CGFloat = surfaceSize + (frameThickness * 2) // 408

    /// Radius of the 4 corner pockets.
    static let pocketRadius: CGFloat = 17.5
    /// Center of pockets relative to surface origin (0,0).
    static let pocketInset: CGFloat = 20.0

    /// Dimensions of pieces
    static let pieceRadius: CGFloat = 11.5
    static let strikerRadius: CGFloat = 16.5
    static let pieceMass: CGFloat = 1.0
    static let strikerMass: CGFloat = 3.2

    /// Baselines: offset from edge to outer baseline, and baseline width
    static let baselineInset: CGFloat = 52.0
    static let baselineWidth: CGFloat = 26.0 // striker fits comfortably between the parallel lines
    static let baselineCircleRadius: CGFloat = 10.5

    /// Center circles
    static let centerOuterRadius: CGFloat = 36.0
    static let centerInnerRadius: CGFloat = 14.0

    // MARK: - Color Palette

    // Surface Wood (Warm Indian birch plywood)
    static let woodLight   = Color(ludoHex: 0xF4E7D3)
    static let woodMid     = Color(ludoHex: 0xEAD8BC)
    static let woodDark    = Color(ludoHex: 0xDFCAAB)
    static let woodGrain   = Color(ludoHex: 0xD3BC9A)

    // Lines & Markings
    static let boardLine   = Color(ludoHex: 0x563721).opacity(0.85)
    static let boardLineLo = Color(ludoHex: 0x563721).opacity(0.35)
    static let baseCircleRed = Color(ludoHex: 0xC62828)

    // Outer Frame (Indian Rosewood / Sheesham)
    static let frameWoodLight = Color(ludoHex: 0x361E13)
    static let frameWoodMid   = Color(ludoHex: 0x22120A)
    static let frameWoodDark  = Color(ludoHex: 0x140A06)
    static let cushionRubber  = Color(ludoHex: 0x2E180E)

    // Pocket Wells & Brass
    static let pocketWell     = Color(ludoHex: 0x09090B)
    static let pocketNet      = Color(ludoHex: 0x18181B)
    static let brassHighlight = Color(ludoHex: 0xF5D77F)
    static let brassBase      = Color(ludoHex: 0xC9A227)
    static let brassShadow    = Color(ludoHex: 0x785E0E)

    // Carrom Men
    static let whitePieceMain = Color(ludoHex: 0xFBF7EF)
    static let whitePieceRing = Color(ludoHex: 0xE2D3BA)
    static let whitePieceCore = Color(ludoHex: 0xC8B494)

    static let blackPieceMain = Color(ludoHex: 0x221F1C)
    static let blackPieceRing = Color(ludoHex: 0x3B3733)
    static let blackPieceCore = Color(ludoHex: 0x151312)

    static let queenMain      = Color(ludoHex: 0xC62828)
    static let queenRing      = Color(ludoHex: 0xE53935)
    static let queenStar      = Color(ludoHex: 0xFFD54F)

    // Striker (Contemporary acrylic glow)
    static let strikerBody    = Color(ludoHex: 0x0F172A)
    static let strikerGlow    = Color(ludoHex: 0x00E5FF)
    static let strikerRing    = Color(ludoHex: 0x38BDF8)
    static let strikerCore    = Color(ludoHex: 0xE0F2FE)

    // Trajectory Laser & Aim
    static let aimLaser       = Color(ludoHex: 0x00F0FF)
    static let aimBounceLaser = Color(ludoHex: 0x38BDF8).opacity(0.65)
    static let aimGhostDisc   = Color(ludoHex: 0x00F0FF).opacity(0.3)
}
