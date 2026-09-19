//
//  LudoTheme.swift
//  Voiid
//
//  Design tokens for the luxury wood and brass Ludo board.
//

import SwiftUI

typealias LudoTheme = Theme

enum Theme {

    // MARK: Surfaces
    static let ink      = Color(ludoHex: 0x0E1620)
    static let ink2     = Color(ludoHex: 0x16212E)
    static let ink3     = Color(ludoHex: 0x1E2C3C)
    static let hairline = Color(ludoHex: 0x263547)

    static let board   = Color(ludoHex: 0xF3E9D6)
    static let board2  = Color(ludoHex: 0xE8DAC0)
    static let line    = Color(ludoHex: 0xB9A484)
    static let brass   = Color(ludoHex: 0xC9A227)
    static let brassLo = Color(ludoHex: 0x8A6E15)
    static let cream   = Color(ludoHex: 0xFFF8EA)
    static let muted   = Color(ludoHex: 0x9DAFC2)
    static let faint   = Color(ludoHex: 0x5C6E80)

    // MARK: Seats
    static let seatColours: [Color] = [
        Color(ludoHex: 0xE0503F),   // Red
        Color(ludoHex: 0x2FA36B),   // Green
        Color(ludoHex: 0xE8A72E),   // Amber
        Color(ludoHex: 0x3B7DD8)    // Blue
    ]

    static func seat(_ i: Int) -> Color { seatColours[i % 4] }

    // MARK: Background
    static var backdrop: some View {
        RadialGradient(
            colors: [Color(ludoHex: 0x1B2836), ink, Color(ludoHex: 0x080D13)],
            center: .top, startRadius: 0, endRadius: 900
        )
        .ignoresSafeArea()
    }

    // MARK: Type
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func label(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    // MARK: Motion
    enum Timing {
        /// One square of travel. Deliberately slow enough to read as a hop.
        static let hop: Duration = .milliseconds(150)
        /// How long the die tumbles before it settles.
        static let diceTumble: Double = 0.52
        static let capturePause: Duration = .milliseconds(520)
        static let botThink: Duration = .milliseconds(700)
    }

    /// The overshoot that makes a token land rather than slide.
    static let land = Animation.spring(response: 0.26, dampingFraction: 0.55)
}

// MARK: - Hex helper

extension Color {
    init(ludoHex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((ludoHex >> 16) & 0xFF) / 255,
            green: Double((ludoHex >> 8)  & 0xFF) / 255,
            blue:  Double( ludoHex        & 0xFF) / 255,
            opacity: 1
        )
    }
}
