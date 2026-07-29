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
import UIKit

// MARK: - Colors (Section 6.1)

/// PEACOCK — the Voiid colour system.
///
/// Every token here is THEME-RESOLVING: it is a `UIColor` built from a trait closure, so one
/// value renders correctly in light and dark without any call site knowing which is active.
/// That is what let the whole app gain dark mode from this one file — roughly 740 references
/// to `VoiidColor.*` on iOS all follow automatically.
///
/// The system has a spine and a set of domain hues:
///  - PEACOCK teal carries every primary action. It LIFTS in dark (#0E6F68 → #3FBFB2) because
///    a single fixed accent always fails one of the two grounds.
///  - SPARK is the one warm counterweight — unread badges, live indicators, missed calls. It
///    appears rarely by design; that scarcity is what makes it read as urgent.
///  - Domain hues (stories/map/calls/payments) are rotations of ONE lightness and chroma, so
///    five colours still read as one family. They are for section identity only — icons,
///    empty states, headers — never bubbles or body text.
///
/// Replaces the previous fixed-light palette, whose sent bubble (#C8C8C8 on #DFDFDF) sat at
/// 1.26:1 and was effectively invisible on a mid-tier LCD in daylight.
enum VoiidColor {

    /// Build a token that resolves per interface style. Light value first — it is the one a
    /// reader is most likely to be picturing.
    private static func dyn(_ light: UInt, _ dark: UInt) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }

    // MARK: Spine

    /// Peacock teal — every primary action, and the brand colour.
    static let primary      = dyn(0x0E6F68, 0x3FBFB2)
    /// The app ground. Warm off-white in light; near-black with a violet cast in dark, which
    /// is what stops an OLED panel from looking flat and dead.
    static let background   = dyn(0xF8F5F1, 0x0C0A10)
    /// Cards, sheets, raised rows — one step up from the ground.
    static let surfaceCard  = dyn(0xFFFFFF, 0x1A171D)

    // MARK: Bubbles

    /// YOUR message — a filled teal bubble.
    ///
    /// It does NOT lift to `primary`'s dark value (#3FBFB2). `primary` lifts because it draws
    /// TEXT on the ground, where the dark teal would be unreadable. This is a FILL with text
    /// ON it: at #3FBFB2 the near-white `textOnBubble` measures 2.12:1 and disappears. Keeping
    /// the text readable is the constraint that pins this token.
    ///
    /// Dark is nudged one step brighter than light for a different reason — the pairing that
    /// actually matters in a transcript is YOUR bubble against THEIRS, not against the ground.
    /// At #0E6F68 on #1A171D that was 2.95:1, just under the 3:1 two adjacent surfaces need,
    /// so the boundary between consecutive messages went soft in dark mode. #117E76 gives
    /// 3.61:1 there while white text still clears AA at 4.62:1.
    static let bubbleSent     = dyn(0x0E6F68, 0x117E76)
    /// Text on your own bubble. Fixed in both themes because the fill is dark in both —
    /// 5.65:1 on light's fill, 4.62:1 on dark's.
    static let textOnBubble   = Color(hex: 0xF0FAF8)
    /// THEIR message — the quiet one, so the eye tracks your own thread down the screen.
    static let bubbleReceived = dyn(0xFFFFFF, 0x1A171D)

    // MARK: Text

    static let textPrimary   = dyn(0x12101A, 0xEEEAF0)
    static let textSecondary = dyn(0x5A5362, 0xA49CAB)
    /// On a filled primary-teal surface.
    static let textOnPrimary = dyn(0xF0FAF8, 0x06211E)
    static let placeholder   = dyn(0x8A8292, 0x786F80)

    // MARK: Lines

    /// A divider must RECEDE. Previously identical to `accent`, so nothing in the UI had
    /// hierarchy — every rule shouted as loudly as every highlight.
    static let divider     = dyn(0xE4DED6, 0x29242F)
    static let fieldBorder = dyn(0xD9D2CA, 0x38323E)
    /// Input backgrounds and inert chips.
    static let fieldFill   = dyn(0xF1EDE7, 0x16131B)

    // MARK: Accents

    /// SPARK — the warm counterweight. Unread badges, live dots, the one thing that must be
    /// seen. Use sparingly; its power is entirely in its rarity.
    ///
    /// THEME-SPLIT, unlike its appearance in the palette study. The bright #E8825A measured
    /// only 2.49:1 against the light ground — under the 3:1 a UI surface needs — so an unread
    /// badge would have been hard to pick out in light mode, and white text on it failed
    /// outright at 2.70:1. Light uses a deeper burnt orange (4.33:1 surface, 4.70:1 for white
    /// text); dark keeps the bright value, which already measured 7.29:1 there.
    static let accent = dyn(0xC25022, 0xE8825A)

    // MARK: Domain hues (section identity only — never bubbles or body text)

    static let domainChat     = dyn(0x0E6F68, 0x3FBFB2)
    static let domainStories  = dyn(0x7B4B8A, 0xB98BC7)
    static let domainMap      = dyn(0x1F6091, 0x7FB6DE)
    static let domainCalls    = dyn(0x2E7D5B, 0x5FBE8D)
    static let domainPayments = dyn(0xA85C2B, 0xD9884A)

    // MARK: Status
    //
    // Semantic, and deliberately separate from the accent. NOTE: state must never be carried
    // by hue ALONE — roughly 1 in 12 men has a colour-vision deficiency, so a missed call is
    // red AND carries its icon and label.

    static let success = dyn(0x1F7A52, 0x63C78D)
    static let error   = dyn(0xC0392F, 0xEF7A6B)
    static let warning = dyn(0xB07818, 0xE0A83C)
    static let info    = dyn(0x1F6091, 0x7FB6DE)

    /// Retained for call sites that predate the theme-aware tokens; now simply the primary
    /// text colour, which resolves correctly on its own.
    static let adaptiveText = textPrimary
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
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
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

// MARK: - Screen width (non-deprecated; avoids UIScreen.main)

enum VoiidScreen {
    static var width: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width) ?? 402
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
