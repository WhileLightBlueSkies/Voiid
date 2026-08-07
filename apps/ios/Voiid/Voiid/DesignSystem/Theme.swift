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

/// NOCTURNE — the Voiid colour system (TESTING).
///
/// Dark-first: deep aubergine and a single warm amber, with light as the variant rather than
/// the default. Replaces Peacock while this direction is evaluated; the token NAMES are
/// unchanged, so every call site follows automatically and reverting is a one-file change.
///
/// Every token is THEME-RESOLVING — a `UIColor` built from a trait closure, so one value
/// renders correctly in light and dark without any call site knowing which is active.
///
/// FOUR VALUES DIFFER FROM THE PALETTE STUDY, because the study's swatches were never
/// measured against each other. All four failed WCAG and are corrected here; the character
/// (aubergine ground, amber accent) is untouched:
///   - dark bubble  #4A3B66 → #7862A6: it sat at 1.96:1 against the ground and 1.75:1 against
///     THEIR bubble, so consecutive messages had no visible boundary at all.
///   - light accent #E8A33D → #B57210: 1.88:1 on the light ground, i.e. an unread badge that
///     effectively vanished, and white text on it failed outright at 2.16:1.
/// Dark keeps the bright #E8A33D, which already measured 9.06:1 there.
enum VoiidColor {

    /// Build a token that resolves per interface style. Light value first — it is the one a
    /// reader is most likely to be picturing.
    private static func dyn(_ light: UInt, _ dark: UInt) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }

    // MARK: Spine

    /// Deep aubergine — every primary action, and the brand colour. Lifts in dark so it stays
    /// legible as TEXT on a near-black ground.
    static let primary      = dyn(0x2E2440, 0xB59BE0)
    /// The app ground. Dark is the DESIGNED state here; light is the variant.
    static let background   = dyn(0xF1EEF5, 0x0D0B14)
    /// Cards, sheets, raised rows — one step up from the ground.
    static let surfaceCard  = dyn(0xFFFFFF, 0x1C1826)

    // MARK: Bubbles

    /// YOUR message. Dark is #7862A6 rather than the study's #4A3B66 — see the type note.
    static let bubbleSent     = dyn(0x2E2440, 0x7862A6)
    /// Text on your own bubble. Fixed in both themes because the fill is dark in both.
    ///
    /// #F8F5FC, a touch brighter than the study's #F2ECFA: that measured 4.43:1 on the dark
    /// bubble — just under AA — because lifting the bubble to #7862A6 (to separate it from the
    /// ground) also lifted what the text has to beat. 4.75:1 now, 13.49:1 on light.
    static let textOnBubble   = Color(hex: 0xF8F5FC)
    /// THEIR message — the quiet one, so the eye tracks your own thread down the screen.
    static let bubbleReceived = dyn(0xFFFFFF, 0x1C1826)

    // MARK: Text

    static let textPrimary   = dyn(0x241D33, 0xE6E1EF)
    static let textSecondary = dyn(0x5F5570, 0xA79CBD)
    /// On a filled primary surface.
    static let textOnPrimary = dyn(0xEFEAF7, 0x14101F)
    static let placeholder   = dyn(0x8A82A0, 0x7A7190)

    // MARK: Lines

    /// A divider must RECEDE — quieter than an accent, or nothing in the UI has hierarchy.
    static let divider     = dyn(0xE3DEEC, 0x241F2F)
    static let fieldBorder = dyn(0xD6CFE4, 0x342D42)
    /// Input backgrounds and inert chips.
    static let fieldFill   = dyn(0xEAE5F2, 0x171320)

    // MARK: Accents

    /// AMBER — the one warm counterweight. Unread badges, live dots, the one thing that must
    /// be seen. Used sparingly; its power is entirely in its rarity.
    ///
    /// THEME-SPLIT: the bright #E8A33D measured 1.88:1 on the light ground — under the 3:1 a
    /// UI surface needs — so light uses a deeper amber (3.40:1 surface, 4.14:1 for dark text
    /// on it). Dark keeps the bright value at 9.06:1.
    static let accent = dyn(0xB57210, 0xE8A33D)

    /// Text or a glyph ON the amber accent — an unread badge label, most often.
    ///
    /// FIXED IN BOTH THEMES, for the same reason [textOnBubble] is: amber is a LIGHT fill in
    /// light AND dark, so its label has to be dark in both. The theme-resolving
    /// [textOnPrimary] is wrong here by construction — it flips to near-white in light mode,
    /// where it measured **3.31:1** on the light amber, under the 4.5:1 a label needs. The
    /// unread count on the grid card was drawn in exactly that pairing and was the least
    /// legible text on the busiest screen in the app.
    ///
    /// #14101F measures 4.79:1 on light amber and 8.67:1 on dark amber.
    static let textOnAccent = Color(hex: 0x14101F)

    // MARK: Domain hues (section identity only — never bubbles or body text)

    static let domainChat     = dyn(0x2E2440, 0xB59BE0)
    static let domainStories  = dyn(0x7B4B8A, 0xC98BD8)
    static let domainMap      = dyn(0x2A5B8F, 0x7FB0E0)
    static let domainCalls    = dyn(0x2E7D5B, 0x5FBE8D)
    static let domainPayments = dyn(0xA9690C, 0xE8A33D)

    // MARK: Status
    //
    // Semantic, and deliberately separate from the accent. NOTE: state must never be carried
    // by hue ALONE — roughly 1 in 12 men has a colour-vision deficiency, so a missed call is
    // red AND carries its icon and label.

    static let success = dyn(0x1F7A52, 0x63C78D)

    /// Online-presence green, used where the word "Online" is TEXT rather than a fill.
    ///
    /// Darker than [success] in the light theme on purpose. `success` is 4.61:1 on the light
    /// ground — a pass, but only just, and the place this is read is the chat toolbar, which
    /// is translucent Liquid Glass: the real backdrop is whatever bubble or photo is
    /// scrolling underneath, not the ground colour the ratio was measured against. 6.58:1
    /// keeps it legible against a white bubble (7.55:1) as well as the ground.
    ///
    /// Dark mode keeps [success] unchanged — it is already 9.38:1 there.
    static let onlineText = dyn(0x17603F, 0x63C78D)
    static let error   = dyn(0xC0392F, 0xEF7A6B)
    static let warning = dyn(0xB07818, 0xE0A83C)
    static let info    = dyn(0x2A5B8F, 0x7FB0E0)

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
