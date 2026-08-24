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

    // THE DIE HAS ONE NEUTRAL BODY in every state; only pips take the active hue (§1).
    let dieBody: Color
    let dieEdge: Color
    let dieNeutralPip: Color

    let textPrimary: Color
    let textSecondary: Color
    let podSurface: Color
    let podBorder: Color
    let timerTrack: Color
    let timerWarning: Color
    let timerCritical: Color
    let focusRing: Color
    let scrim: Color
    let shadow: Color

    func hue(_ seat: Int) -> Color { playerHues[seat % 4] }
    func yard(_ seat: Int) -> Color { yards[seat % 4] }
    func homeLane(_ seat: Int) -> Color { homeLanes[seat % 4] }
    func centerTriangle(_ seat: Int) -> Color { hue(seat) }

    static let light = LudoColors(
        isDark: false,
        screenBackground: Color(hex: 0xF6F8F8),
        boardSurface: Color(hex: 0xF3F4F6),
        trackCellFill: .white,
        trackCellBorder: Color(hex: 0xC9CDD5),
        trackCellPressed: Color(hex: 0xE7EAEE),
        unusedCellFill: Color(hex: 0xF3F4F6),
        safeCellFill: Color(hex: 0xE8EBF0),
        safeCellStar: Color(hex: 0x626A76),
        playerHues: [Color(hex: 0xD94B47), Color(hex: 0x248A4B), Color(hex: 0xC99A00), Color(hex: 0x2F6FD6)],
        yards: [Color(hex: 0xF8E4E3), Color(hex: 0xE2F0E7), Color(hex: 0xF7EFCF), Color(hex: 0xE3EBFA)],
        homeLanes: [Color(hex: 0xE88C89), Color(hex: 0x72B58B), Color(hex: 0xE3C558), Color(hex: 0x7FA4E6)],
        yardPocket: .white,
        yardPocketBorder: Color(hex: 0xD4D8DF),
        inactiveYard: Color(hex: 0xE7E9ED),
        dieBody: Color(hex: 0xF8F8F9),
        dieEdge: Color(hex: 0xC6CAD2),
        dieNeutralPip: Color(hex: 0x69717D),
        textPrimary: Color(hex: 0x101617),
        textSecondary: Color(hex: 0x5D696C),
        podSurface: .white,
        podBorder: Color(hex: 0xD7DEDF),
        timerTrack: Color(hex: 0xD9DDE3),
        timerWarning: Color(hex: 0xB07818),
        timerCritical: Color(hex: 0xC0392F),
        focusRing: Color(hex: 0x13828C),
        scrim: Color.black.opacity(0.32),
        shadow: Color.black.opacity(0.14))

    static let dark = LudoColors(
        isDark: true,
        screenBackground: Color(hex: 0x080C0E),
        boardSurface: Color(hex: 0x15171C),
        trackCellFill: Color(hex: 0x202229),
        trackCellBorder: Color(hex: 0x444852),
        trackCellPressed: Color(hex: 0x2A2D35),
        unusedCellFill: Color(hex: 0x15171C),
        safeCellFill: Color(hex: 0x2A2D35),
        safeCellStar: Color(hex: 0xC2C7D0),
        playerHues: [Color(hex: 0xF06460), Color(hex: 0x56B870), Color(hex: 0xF1C84B), Color(hex: 0x5B8DEF)],
        yards: [Color(hex: 0x2D2022), Color(hex: 0x1B2A22), Color(hex: 0x2C2819), Color(hex: 0x1C2431)],
        homeLanes: [Color(hex: 0xB84D4C), Color(hex: 0x3C7F50), Color(hex: 0xA98F3A), Color(hex: 0x446CB4)],
        yardPocket: Color(hex: 0x202229),
        yardPocketBorder: Color(hex: 0x3D414B),
        inactiveYard: Color(hex: 0x202229),
        dieBody: Color(hex: 0x1B1D24),
        dieEdge: Color(hex: 0x4A4E58),
        dieNeutralPip: Color(hex: 0xB2B8C3),
        textPrimary: Color(hex: 0xF6F8F8),
        textSecondary: Color(hex: 0xA6B0B2),
        podSurface: Color(hex: 0x171C1F),
        podBorder: Color(hex: 0x2D383C),
        timerTrack: Color(hex: 0x3A3E47),
        timerWarning: Color(hex: 0xE0A83C),
        timerCritical: Color(hex: 0xEF7A6B),
        focusRing: Color(hex: 0x68B8BD),
        scrim: Color.black.opacity(0.44),
        shadow: Color.black.opacity(0.40))

    static func resolve(_ scheme: ColorScheme) -> LudoColors {
        scheme == .dark ? .dark : .light
    }

    /// §2.2 elevation: board y=4/blur=14 light, y=6/blur=18 dark; drawn as a soft under-rect.
    func boardShadow() -> (offset: CGSize, radius: CGFloat) {
        isDark ? (CGSize(width: 0, height: 6), 18) : (CGSize(width: 0, height: 4), 14)
    }
}

enum LudoDimens {
    static let boardCornerRadius: CGFloat = 18
    static func perimeterStroke(dark: Bool) -> CGFloat { dark ? 3.5 : 3 }
    static let boardContentInset: CGFloat = 4
    static func cellBorder(dark: Bool) -> CGFloat { dark ? 1 : 0.75 }
    static let cellCornerRadiusFactor: CGFloat = 0.08
    static let yardPocketRadiusFactor: CGFloat = 0.48
    static let safeStarRadiusFactor: CGFloat = 0.28

    static let podSizeStandard = CGSize(width: 156, height: 52)
    static let podSizeCompact = CGSize(width: 144, height: 44)
    static let podCornerRadius: CGFloat = 14
    static let chipStandard: CGFloat = 24
    static let chipCompact: CGFloat = 20
    static let ringStandard: CGFloat = 32
    static let ringCompact: CGFloat = 28
    static let ringStroke: CGFloat = 2.5

    static let dieSizeStandard: CGFloat = 64
    static let dieSizeCompact: CGFloat = 56
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
    static let captureReturnMs: Double = 260
    static let finishShrinkMs: Double = 240
    static let resultRippleMs: Double = 420
}
