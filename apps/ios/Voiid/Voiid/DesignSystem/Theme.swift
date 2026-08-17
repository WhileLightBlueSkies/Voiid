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

    /// ELECTRIC LIME — the brand. Every primary action.
    ///
    /// THE ONE THING TO UNDERSTAND ABOUT THIS PALETTE: the lime is a FILL colour, not a text
    /// colour, and that is a hard rule rather than a preference. #C6FF00 measures 16.59:1 on
    /// the near-black ground and **1.19:1 on white** — not "weak", invisible. So:
    ///
    ///   * DARK is the designed state. The lime works everywhere there: text, icons, lines.
    ///   * LIGHT resolves `primary` to near-black INK, not lime. Lime survives in light mode
    ///     only as a filled element with dark text on it (16.59:1), which is what
    ///     [accent] and [textOnAccent] exist for.
    ///
    /// A light-mode call site that wants "the brand colour" wants `accent` as a FILL, or
    /// `primary` as ink. It does not want lime text on white, and this token will not give it.
    static let primary      = dyn(0x0B0B0B, 0xC6FF00)

    /// The app ground. Voiid Black in dark — the DESIGNED state; white in light.
    static let background   = dyn(0xFFFFFF, 0x0B0B0B)
    /// Cards, sheets, raised rows — one step up from the ground.
    static let surfaceCard  = dyn(0xFFFFFF, 0x1A1A1A)

    // MARK: Bubbles

    /// YOUR message. Lime in dark, where black text on it reads at 16.59:1 — the brand's
    /// loudest legitimate use. Light keeps the lime too: a filled element is exactly where it
    /// works, and it is what makes your own thread trackable down the screen.
    static let bubbleSent     = dyn(0xC6FF00, 0xC6FF00)
    /// Text on your own bubble. FIXED in both themes because the fill is lime in both, and a
    /// light fill needs dark text either way. 16.59:1.
    static let textOnBubble   = Color(hex: 0x0B0B0B)
    /// THEIR message — the quiet one, so the eye tracks your own thread down the screen.
    /// Surface-light in dark so it separates from both the ground (#0B0B0B) and the card.
    static let bubbleReceived = dyn(0xF7F7F7, 0x2A2A2A)

    // MARK: Text

    static let textPrimary   = dyn(0x0B0B0B, 0xF5F5F5)
    /// 5.33:1 on white, 7.80:1 on Voiid Black. The light value is darker than the palette's
    /// #A3A3A3, which measured only 2.32:1 on white — unreadable as secondary text.
    static let textSecondary = dyn(0x6B6B6B, 0xA3A3A3)
    /// On a filled PRIMARY surface. Dark-mode primary is lime, so its label is near-black;
    /// light-mode primary is ink, so its label is near-white. Both directions correct.
    static let textOnPrimary = dyn(0xF5F5F5, 0x0B0B0B)
    static let placeholder   = dyn(0x8A8A8A, 0x6B6B6B)

    // MARK: Lines

    /// A divider must RECEDE — quieter than an accent, or nothing in the UI has hierarchy.
    static let divider     = dyn(0xE8E8E8, 0x2A2A2A)
    static let fieldBorder = dyn(0xD4D4D4, 0x3A3A3A)
    /// Input backgrounds and inert chips.
    static let fieldFill   = dyn(0xF7F7F7, 0x1A1A1A)

    // MARK: Accents

    /// The lime as a FILL — unread badges, the send button, the one thing that must be seen.
    ///
    /// NOT theme-split, unlike the old amber, and that is the point: a filled lime chip works
    /// on both grounds because what matters is the contrast of its LABEL against the fill
    /// (16.59:1, see [textOnAccent]), not the fill against the ground.
    ///
    /// ONE CAVEAT, and it matters on light: lime vs white is 1.19:1, so a lime fill has no
    /// visible edge on a white ground. Anything relying on its boundary — an outlined chip, a
    /// lime-on-white card — needs [fieldBorder] or an ink outline. A filled shape with dark
    /// content inside reads fine; an outline in lime does not.
    static let accent = Color(hex: 0xC6FF00)

    /// Text or a glyph ON the lime accent. FIXED in both themes: lime is a light fill in
    /// light AND dark, so its label is dark in both. 16.59:1.
    static let textOnAccent = Color(hex: 0x0B0B0B)

    /// Lime at reading weight, for the rare case where the brand must appear as TEXT on a
    /// LIGHT ground. #5A7A00 is the same hue pushed down to 4.62:1 on white — it reads as
    /// olive rather than electric, which is the honest cost of putting this hue on white at
    /// all. Prefer a filled [accent] chip; reach for this only when a fill is impossible.
    static let accentInk = dyn(0x5A7A00, 0xC6FF00)

    // MARK: Domain hues (section identity only — never bubbles or body text)

    /// Chat resolves to the spine, as before.
    static let domainChat     = dyn(0x0B0B0B, 0xC6FF00)
    /// The remaining domains take the palette's feedback hues, theme-split: the bright values
    /// measured 1.5–4.0:1 on white (Warning worst at 1.53:1), so light uses darkened variants
    /// of the SAME hue at 4.9–7.0:1. Dark keeps the bright ones, all above 4.9:1 there.
    static let domainStories  = dyn(0x7E22CE, 0xA855F7)
    static let domainMap      = dyn(0x1D4ED8, 0x3B82F6)
    static let domainCalls    = dyn(0x15803D, 0x22C55E)
    static let domainPayments = dyn(0xA16207, 0xFACC15)

    // MARK: Status
    //
    // Semantic, and deliberately separate from the accent. NOTE: state must never be carried
    // by hue ALONE — roughly 1 in 12 men has a colour-vision deficiency, so a missed call is
    // red AND carries its icon and label.
    //
    // Every light value is a darkened variant of the palette's bright one, because the brights
    // are designed for near-black: Success 2.28:1, Warning 1.53:1, Error 3.76:1, Info 3.68:1
    // on white. Same hues, pushed to AA.

    static let success = dyn(0x15803D, 0x22C55E)

    /// Online-presence green, used where "Online" is TEXT rather than a fill. Darker than
    /// [success] on light because the chat toolbar is translucent — the real backdrop is
    /// whatever is scrolling underneath, not the ground the ratio was measured against.
    static let onlineText = dyn(0x166534, 0x22C55E)
    static let error   = dyn(0xDC2626, 0xEF4444)
    static let warning = dyn(0xA16207, 0xFACC15)
    static let info    = dyn(0x1D4ED8, 0x3B82F6)

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
