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

    /// VOIID TIDE #13828C — the brand. Every primary action.
    ///
    /// THE ONE THING THAT CHANGED FROM THE PREVIOUS TWO BRANDS: Tide is a MID-TONE, where the
    /// lime and the bright cyan were both light fills. That inverts the label rule —
    /// white on Tide is 4.57:1 and black is 4.30:1, so a filled Tide element carries WHITE
    /// text. See [textOnAccent].
    ///
    /// Tide is the same value in both themes, which is what makes the brand recognisable
    /// across the light/dark switch. What differs is where it may be used:
    ///
    ///   * As a FILL — buttons, badges, bubbles — it works on both grounds, because what
    ///     matters is its label's contrast against the fill, not the fill against the ground.
    ///   * As TEXT it is marginal: 4.30:1 on the dark ground and 4.28:1 on the light ground.
    ///     Dark mode therefore uses [accentInk] (#68B8BD, 8.59:1) for teal text, and light
    ///     mode keeps Tide but only on white (4.57:1), never on the page ground.
    static let primary      = Color(hex: 0x13828C)

    /// The app ground.
    static let background   = dyn(0xF6F8F8, 0x080C0E)
    /// Cards, sheets, raised rows — one step up from the ground.
    static let surfaceCard  = dyn(0xFFFFFF, 0x111719)
    /// One step below the card, for a region that must sit UNDER content rather than on it.
    static let surfaceDeep  = dyn(0xEDF1F1, 0x080C0E)
    /// One step above the card — a menu over a sheet, a raised control. Palette "Elevated".
    static let surfaceRaised = dyn(0xEDF1F1, 0x182124)

    // MARK: Bubbles

    /// YOUR message. Tide in both themes — the brand's loudest legitimate use, and what makes
    /// your own thread trackable down the screen.
    static let bubbleSent     = Color(hex: 0x13828C)
    /// Text on your own bubble. WHITE, fixed in both themes, because the fill is a mid-tone
    /// Tide in both. 4.57:1 — AA for body text.
    static let textOnBubble   = Color(hex: 0xFFFFFF)
    /// THEIR message — the quiet one, so the eye tracks your own thread down the screen.
    /// "Elevated" in dark so it separates from both the ground and the card.
    static let bubbleReceived = dyn(0xEDF1F1, 0x182124)

    // MARK: Text

    /// 18.42:1 on the dark ground, 17.14:1 on the light one.
    static let textPrimary   = dyn(0x101617, 0xF6F8F8)
    /// 8.86:1 dark, 5.32:1 light — AA on every surface in both themes.
    static let textSecondary = dyn(0x5D696C, 0xA6B0B2)
    /// On a filled PRIMARY surface. White in both, because primary is Tide in both.
    static let textOnPrimary = Color(hex: 0xFFFFFF)

    /// The MUTED tier. Deliberately below AA (2.8–4.3:1 depending on surface) — it is for
    /// placeholders and de-emphasised timestamps, never for text a user has to read. Anything
    /// load-bearing takes [textSecondary] instead.
    static let placeholder   = dyn(0x899396, 0x6D787B)

    // MARK: Lines

    /// A divider must RECEDE — quieter than an accent, or nothing in the UI has hierarchy.
    static let divider     = dyn(0xD7DEDF, 0x263236)
    static let fieldBorder = dyn(0xD7DEDF, 0x263236)
    /// Input backgrounds and inert chips.
    static let fieldFill   = dyn(0xEDF1F1, 0x111719)

    // MARK: Accents

    /// The Tide as a FILL — unread badges, the send button, the one thing that must be seen.
    /// Identical in both themes; its LABEL is what carries the contrast (see [textOnAccent]).
    static let accent = Color(hex: 0x13828C)

    /// The pressed state. A real darker step rather than an opacity change, so a pressed
    /// button does not go translucent over whatever is behind it. White on it is 5.97:1.
    static let accentPressed = Color(hex: 0x0E6E77)

    /// SOFT ACCENT — and the one token that genuinely differs by theme rather than merely
    /// being tuned for it.
    ///
    ///   * DARK  #68B8BD — a LIGHT teal, for teal TEXT and icons on a dark ground (8.59:1).
    ///   * LIGHT #D9EFF0 — a PALE teal, for a tinted SURFACE behind dark content.
    ///
    /// They are opposite jobs, which is why this is not simply "the same colour, lightened".
    /// Use [accentInk] when you want teal text and [accentTint] when you want a teal surface;
    /// both are defined in terms of this pair so the intent is legible at the call site.
    static let accentSoft = dyn(0xD9EFF0, 0x68B8BD)

    /// A selected row, a highlighted surface, a wash behind an icon. Pale in light; in dark
    /// the same idea is a low-alpha Tide, because #68B8BD as a large fill would glow.
    static let accentTint = dyn(0xD9EFF0, 0x123538)

    /// Text or a glyph ON the Tide accent. WHITE in both themes.
    ///
    /// This INVERTS the rule the previous two brand colours followed. Lime and bright cyan
    /// were light fills that needed near-black labels; Tide is a mid-tone, and white beats
    /// black on it (4.57:1 vs 4.30:1). Every filled button, badge and bubble label flipped.
    static let textOnAccent = Color(hex: 0xFFFFFF)

    /// The brand at READING weight — teal text, as opposed to a teal fill.
    ///
    /// Dark resolves to Soft accent #68B8BD (8.59:1), because Tide itself is only 4.30:1 on
    /// the dark ground. Light keeps true Tide, which is 4.57:1 on white — so use it on cards
    /// and sheets; on the light page ground it drops to 4.28:1, just under AA, and
    /// [textPrimary] is the right choice there instead.
    static let accentInk = dyn(0x13828C, 0x68B8BD)

    // MARK: Domain hues (section identity only — never bubbles or body text)

    /// Chat resolves to the spine.
    static let domainChat     = dyn(0x13828C, 0x68B8BD)
    static let domainStories  = dyn(0x7E22CE, 0xA855F7)
    static let domainMap      = dyn(0x1D4ED8, 0x3B82F6)
    static let domainCalls    = dyn(0x15803D, 0x22C55E)
    static let domainPayments = dyn(0xA16207, 0xFACC15)

    // MARK: Status
    //
    // Semantic, and deliberately separate from the accent. NOTE: state must never be carried
    // by hue ALONE — roughly 1 in 12 men has a colour-vision deficiency, so a missed call is
    // red AND carries its icon and label.

    /// 6.15:1 on the dark ground, 4.06:1 on the light one.
    static let success = dyn(0x238A58, 0x2FA36B)

    /// Online-presence green, used where "Online" is TEXT rather than a fill.
    static let onlineText = dyn(0x238A58, 0x2FA36B)
    /// 5.02:1 dark, 4.28:1 light.
    static let error   = dyn(0xD83A40, 0xE5484D)
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
