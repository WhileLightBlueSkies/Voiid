//
//  Theme.swift
//  Voiid
//
//  VOIID design system (Master Spec Section 6).
//  Tokens mirror packages/design-tokens/tokens.json — single source of truth.
//
//  Typography rule (per design owner):
//   - Splash + Terms screens: "voiid" wordmark uses Urbanist Bold (keep exactly as designed).
//   - Everything else: SF Pro Rounded.
//

import SwiftUI

// MARK: - Colors (Section 6.1)

enum VoiidColor {
    // Locked tokens
    static let primary      = Color(hex: 0x4D3E47)   // brand plum
    // Background: #DFDFDF (light) / deep plum-charcoal (dark)
    static let background   = adaptive(light: 0xDFDFDF, dark: 0x1C1820)
    static let fieldBorder  = Color(hex: 0xE3BED8)
    // Field fill: light pink (light) / muted dark plum (dark) so placeholder/text stay readable
    static let fieldFill    = adaptive(light: 0xFCF4F8, dark: 0x2A2430)
    static let bubbleSent   = Color(hex: 0xC8C8C8)

    // Derived tokens (Section 6.1 "derived — confirm")
    static let bubbleReceived = Color(hex: 0xFCF4F8)
    static let surfaceCard    = Color(hex: 0xFFFFFF)

    // Adaptive text colors: plum (#4D3E47) in light mode, #FCF4F8 in dark mode.
    static let textPrimary    = adaptive(light: 0x4D3E47, dark: 0xFCF4F8)
    // Muted text: lightened plum in light mode, dimmed light in dark mode.
    static let textSecondary  = adaptive(light: 0x7A6E74, dark: 0xCBBFC7)
    static let textOnPrimary  = Color(hex: 0xFCF4F8)
    // Placeholder: clearly muted on the light pink field (NOT white).
    static let placeholder    = adaptive(light: 0x9B8F95, dark: 0xCBBFC7)
    static let divider        = Color(hex: 0xE3BED8)
    static let accent         = Color(hex: 0xE3BED8)

    /// Builds a color that switches between two hex values by light/dark appearance.
    static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark))
                : UIColor(Color(hex: light))
        })
    }

    // Status
    static let success = Color(hex: 0x3E9E6E)
    static let error   = Color(hex: 0xC0556B)
    static let warning = Color(hex: 0xD8A24A)
    static let info    = Color(hex: 0x4D3E47)
}

// MARK: - Spacing (Section 6.3)

enum VoiidSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

// MARK: - Radii (Section 6.4)

enum VoiidRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let pill: CGFloat = 999
}

// MARK: - Typography (Section 6.2)
//
// Primary face = SF Pro Rounded (via .rounded design). Urbanist is only the logo wordmark
// on Splash/Terms; register the Urbanist font file in the app bundle (see BUILD_NATIVE.md).

enum VoiidFont {
    /// SF Pro Rounded at the spec's type scale.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let display  = rounded(34, .bold)
    static let title    = rounded(22, .semibold)
    static let headline = rounded(17, .semibold)
    static let body     = rounded(17, .regular)
    static let callout  = rounded(16, .regular)
    static let subhead  = rounded(15, .regular)
    static let footnote = rounded(13, .regular)
    static let caption  = rounded(12, .regular)

    /// Urbanist Bold — ONLY for the "voiid" logo wordmark on Splash + Terms.
    /// Falls back to rounded bold if the font isn't registered yet.
    static func logo(_ size: CGFloat) -> Font {
        .custom("Urbanist-Bold", size: size)
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}
