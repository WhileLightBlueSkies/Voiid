//
//  LudoTheme.swift
//  Voiid
//
//  Resolved per-theme palette handed to Canvas draw code (§2). Mirrors
//  packages/design-tokens/tokens.json → color.game.ludo value for value; Android's
//  LudoThemeColors is the parity twin. Draw functions receive this ONCE — they never read
//  trait collections mid-draw, so a theme flip re-renders instead of tearing.
//

import SwiftUI

struct LudoColors {
    let isDark: Bool

    let screenBackground: Color
    let boardSurface: Color
    let trackCellFill: Color
    let trackCellBorder: Color
    let trackCellPressed: Color
    let unusedCellFill: Color
    let safeCellFill: Color
    let safeCellStar: Color

    // Player hues — pawn, lane, border, pips. Fixed per seat, never derived at runtime.
    let playerHues: [Color]
    let yards: [Color]
    let homeLanes: [Color]

    let yardPocket: Color
    let yardPocketBorder: Color
    let inactiveYard: Color
    let boardOuterNeutral: Color

    // THE DIE HAS ONE NEUTRAL BODY in every state; only pips take the active hue (§1).
    let dieBody: Color
    let dieEdge: Color
    let dieNeutralPip: Color

    let textPrimary: Color
    let textSecondary: Color
    let podSurface: Color
    let podBorder: Color
    let timerTrack: Color
    let timerActive: Color
    let timerWarning: Color
    let timerCritical: Color
    let focusRing: Color
    let scrim: Color
    let shadow: Color

    func hue(_ seat: Int) -> Color { playerHues[seat % 4] }
    func yard(_ seat: Int) -> Color { yards[seat % 4] }
    func homeLane(_ seat: Int) -> Color { homeLanes[seat % 4] }
    func centerTriangle(_ seat: Int) -> Color { yard(seat) }

    static let light = LudoColors(
        isDark: false,
        screenBackground: Color(hex: 0xF2F2F3),
        boardSurface: .white,
        trackCellFill: .white,
        trackCellBorder: Color(hex: 0x202020),
        trackCellPressed: Color(hex: 0xE7EAEE),
        unusedCellFill: .white,
        safeCellFill: .white,
        safeCellStar: Color(hex: 0x383838),
        playerHues: [Color(hex: 0xCF514F), Color(hex: 0x5F9F5E), Color(hex: 0xE9BD2E), Color(hex: 0x4B78E5)],
        yards: [Color(hex: 0xF30104), Color(hex: 0x03A822), Color(hex: 0xFDD805), Color(hex: 0x0F7DEE)],
        homeLanes: [Color(hex: 0xF30104), Color(hex: 0x03A822), Color(hex: 0xFDD805), Color(hex: 0x0F7DEE)],
        yardPocket: .white,
        yardPocketBorder: Color(hex: 0x202020),
        inactiveYard: .white,
        boardOuterNeutral: Color(hex: 0x202020),
        dieBody: Color(hex: 0xFEFEFE),
        dieEdge: Color(hex: 0xC7C9CF),
        dieNeutralPip: Color(hex: 0x69717D),
        textPrimary: Color(hex: 0x111015),
        textSecondary: Color(hex: 0x5D696C),
        podSurface: .white,
        podBorder: Color(hex: 0xC7C9CF),
        timerTrack: Color(hex: 0xD9DDE3),
        timerActive: Color(hex: 0x69717D),
        timerWarning: Color(hex: 0xB07818),
        timerCritical: Color(hex: 0xC0392F),
        focusRing: Color(hex: 0x13828C),
        scrim: Color.black.opacity(0.32),
        shadow: Color.black.opacity(0.14))

    static let dark = LudoColors(
        isDark: true,
        screenBackground: Color(hex: 0x111015),
        boardSurface: Color(hex: 0x1F2326),
        trackCellFill: Color(hex: 0x1F2326),
        trackCellBorder: Color(hex: 0x101316),
        trackCellPressed: Color(hex: 0x2A2D35),
        unusedCellFill: Color(hex: 0x1F2326),
        safeCellFill: Color(hex: 0x1F2326),
        safeCellStar: Color(hex: 0xF4F6FA),
        playerHues: [Color(hex: 0xFD605B), Color(hex: 0x3AD784), Color(hex: 0xFED632), Color(hex: 0x337AE5)],
        yards: [Color(hex: 0xB70407), Color(hex: 0x028327), Color(hex: 0xD4A70E), Color(hex: 0x024F9F)],
        homeLanes: [Color(hex: 0xB70407), Color(hex: 0x028327), Color(hex: 0xD4A70E), Color(hex: 0x024F9F)],
        yardPocket: Color(hex: 0x1F2326),
        yardPocketBorder: Color(hex: 0x101316),
        inactiveYard: Color(hex: 0x1F2326),
        boardOuterNeutral: Color(hex: 0x101316),
        dieBody: Color(hex: 0x181920),
        dieEdge: Color(hex: 0x464952),
        dieNeutralPip: Color(hex: 0xB2B8C3),
        textPrimary: Color(hex: 0xF7F7F7),
        textSecondary: Color(hex: 0xA6B0B2),
        podSurface: Color(hex: 0x181920),
        podBorder: Color(hex: 0x464952),
        timerTrack: Color(hex: 0x3A3E47),
        timerActive: Color(hex: 0xB2B8C3),
        timerWarning: Color(hex: 0xE0A83C),
        timerCritical: Color(hex: 0xEF7A6B),
        focusRing: Color(hex: 0x68B8BD),
        scrim: Color.black.opacity(0.44),
        shadow: Color.black.opacity(0.40))

    static func resolve(_ scheme: ColorScheme) -> LudoColors {
        scheme == .dark ? .dark : .light
    }

    /// The board is flat in both themes.
    func boardShadow() -> (offset: CGSize, radius: CGFloat) {
        (.zero, 0)
    }
}

enum LudoDimens {
    static let boardCornerRadius: CGFloat = 0
    static func perimeterStroke(dark: Bool) -> CGFloat { dark ? 3.5 : 3 }
    static let boardContentInset: CGFloat = 0
    static func cellBorder(dark: Bool) -> CGFloat { 0.75 }
    static let cellCornerRadiusFactor: CGFloat = 0
    static let yardPocketInsetFactor: CGFloat = 0.80
    /// Resting-circle radius for a yard slot, as a fraction of one cell.
    static let yardSlotRadiusFactor: CGFloat = 0.46
    static let yardPocketRadiusFactor: CGFloat = 0.72
    static let safeStarOuterRadiusFactor: CGFloat = 0.34
    static let safeStarInnerRadiusFactor: CGFloat = 0.15

    // Pods carry only a chip and a username, so they stay small and let the board dominate —
    // the name is a label beside the board, never a headline.
    static let podSizeStandard = CGSize(width: 120, height: 36)
    static let podSizeCompact = CGSize(width: 108, height: 32)
    static let podCornerRadius: CGFloat = 10
    static let chipStandard: CGFloat = 16
    static let chipCompact: CGFloat = 14
    static let ringStandard: CGFloat = 24
    static let ringCompact: CGFloat = 21
    static let ringStroke: CGFloat = 2

    static let dieSizeStandard: CGFloat = 64
    static let dieSizeCompact: CGFloat = 44
    static let dieSizeTablet: CGFloat = 72
    static let dieHitTarget: CGFloat = 72
}

enum LudoMotion {
    static let borderSweepMs: Double = 360
    static let dieRelocateMs: Double = 120
    static let pipCrossFadeMs: Double = 120
    static let hopMs: Double = 120
    static let hopStaggerMs: Double = 92
    static let fastForwardMs: Double = 90
    static let haloBreatheMs: Double = 520
    static let captureScaleMs: Double = 150
    /// Whole capture retrace, split across however many cells the pawn has to walk back.
    static let captureReturnTotalMs: Double = 520
    static let captureLegMinMs: Double = 26
    static let captureReturnMs: Double = 260
    static let finishShrinkMs: Double = 240
    static let resultRippleMs: Double = 420
}
