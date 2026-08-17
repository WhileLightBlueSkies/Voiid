package com.voiid.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color

/**
 * PEACOCK — the Voiid colour system. Mirrors iOS `VoiidColor` value for value.
 *
 * Every token is THEME-RESOLVING: each is a `@Composable get` that reads [LocalVoiidDark] and
 * returns the light or dark value. That is what let the whole app gain dark mode from this one
 * file — roughly 807 references to `VoiidColor.*` all follow automatically, with no call site
 * knowing which theme is active.
 *
 * The system has a spine and a set of domain hues:
 *  - PEACOCK teal carries every primary action. It LIFTS in dark (#0E6F68 → #3FBFB2) because a
 *    single fixed accent always fails one of the two grounds.
 *  - SPARK is the one warm counterweight — unread badges, live indicators, missed calls. It
 *    appears rarely by design; that scarcity is what makes it read as urgent.
 *  - Domain hues (stories/map/calls/payments) are rotations of ONE lightness and chroma, so
 *    five colours still read as one family. Section identity only — icons, empty states,
 *    headers — never bubbles or body text.
 *
 * Replaces the previous fixed-light palette, whose sent bubble (#C8C8C8 on #DFDFDF) sat at
 * 1.26:1 and was effectively invisible on a mid-tier LCD in daylight.
 *
 * NOTE: these are `@Composable` properties, so they can only be read inside composition. A few
 * non-composable call sites (canvas painters, notification builders) need the raw values —
 * those live in [VoiidPalette] below.
 */
object VoiidColor {

    // ---- Spine -------------------------------------------------------------------------

    /** Peacock teal — every primary action, and the brand colour. */
    val primary: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.PrimaryLight, VoiidPalette.PrimaryDark)

    /**
     * The app ground. Warm off-white in light; near-black with a violet cast in dark, which is
     * what stops an OLED panel from looking flat and dead.
     */
    val background: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.BackgroundLight, VoiidPalette.BackgroundDark)

    /** Cards, sheets, raised rows — one step up from the ground. */
    val surfaceCard: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.SurfaceLight, VoiidPalette.SurfaceDark)

    // ---- Bubbles -----------------------------------------------------------------------

    /**
     * YOUR message — a filled teal bubble.
     *
     * It does NOT lift to [primary]'s dark value. `primary` lifts because it draws TEXT on the
     * ground; this is a FILL with text ON it, and at #3FBFB2 the near-white [textOnBubble]
     * measures 2.12:1 and disappears.
     *
     * Dark is one step brighter than light because the pairing that matters in a transcript is
     * YOUR bubble against THEIRS, not against the ground: #0E6F68 on #1A171D was 2.95:1, under
     * the 3:1 two adjacent surfaces need, so consecutive messages blurred together in dark.
     */
    val bubbleSent: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.BubbleSentLight, VoiidPalette.BubbleSentDark)

    /** Text on your own bubble. Fixed in both themes because the bubble itself is fixed. */
    val textOnBubble: Color @Composable @ReadOnlyComposable get() = VoiidPalette.TextOnBubble

    /** THEIR message — the quiet one, so the eye tracks your own thread down the screen. */
    val bubbleReceived: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.BubbleRecvLight, VoiidPalette.BubbleRecvDark)

    // ---- Text --------------------------------------------------------------------------

    val textPrimary: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.TextPrimaryLight, VoiidPalette.TextPrimaryDark)
    val textSecondary: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.TextSecondaryLight, VoiidPalette.TextSecondaryDark)

    /** On a filled primary-teal surface. */
    val textOnPrimary: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.TextOnPrimaryLight, VoiidPalette.TextOnPrimaryDark)
    val placeholder: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.PlaceholderLight, VoiidPalette.PlaceholderDark)

    // ---- Lines -------------------------------------------------------------------------

    /**
     * A divider must RECEDE. Previously identical to [accent], so nothing in the UI had
     * hierarchy — every rule shouted as loudly as every highlight.
     */
    val divider: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.DividerLight, VoiidPalette.DividerDark)
    val fieldBorder: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.FieldBorderLight, VoiidPalette.FieldBorderDark)

    /** Input backgrounds and inert chips. */
    val fieldFill: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.FieldFillLight, VoiidPalette.FieldFillDark)

    // ---- Accent ------------------------------------------------------------------------

    /**
     * SPARK — the warm counterweight. Unread badges, live dots, the one thing that must be
     * seen. Use sparingly; its power is entirely in its rarity.
     */
    val accent: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.SparkLight, VoiidPalette.SparkDark)

    /**
     * Text or a glyph ON the amber accent — an unread badge label, most often.
     *
     * FIXED IN BOTH THEMES, for the same reason [textOnBubble] is: amber is a LIGHT fill in
     * light AND dark, so its label has to be dark in both. The theme-resolving
     * [textOnPrimary] is wrong here by construction — it flips to near-white in light mode,
     * where it measured **3.31:1** on the light amber, under the 4.5:1 a label needs. The
     * unread count on the grid card was drawn in exactly that pairing and was the least
     * legible text on the busiest screen in the app.
     *
     * #14101F measures 4.79:1 on light amber and 8.67:1 on dark amber.
     */
    val textOnAccent: Color @Composable @ReadOnlyComposable get() = VoiidPalette.TextOnAccent

    // ---- Domain hues (section identity only — never bubbles or body text) ---------------

    val domainChat: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.PrimaryLight, VoiidPalette.PrimaryDark)
    val domainStories: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.StoriesLight, VoiidPalette.StoriesDark)
    val domainMap: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.MapLight, VoiidPalette.MapDark)
    val domainCalls: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.CallsLight, VoiidPalette.CallsDark)
    val domainPayments: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.PaymentsLight, VoiidPalette.PaymentsDark)

    // ---- Status ------------------------------------------------------------------------
    //
    // Semantic, and deliberately separate from the accent. NOTE: state must never be carried
    // by hue ALONE — roughly 1 in 12 men has a colour-vision deficiency, so a missed call is
    // red AND carries its icon and label.

    val success: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.SuccessLight, VoiidPalette.SuccessDark)
    val error: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.ErrorLight, VoiidPalette.ErrorDark)
    val warning: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.WarningLight, VoiidPalette.WarningDark)
    val info: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.MapLight, VoiidPalette.MapDark)

    /** Retained for call sites predating theme-aware tokens; now simply the primary text. */
    val adaptiveText: Color @Composable @ReadOnlyComposable get() = textPrimary

    @Composable
    @ReadOnlyComposable
    private fun pick(light: Color, dark: Color): Color = if (LocalVoiidDark.current) dark else light
}

/**
 * The raw Peacock values, theme-suffixed.
 *
 * Exists because [VoiidColor]'s tokens are `@Composable` and therefore unreadable outside
 * composition — notification builders, canvas painters and map style JSON all need constants.
 * Prefer [VoiidColor] anywhere you are inside a composable.
 */
object VoiidPalette {
    // Spine — ELECTRIC LIME on Voiid Black. Dark-first: light is the variant.
    //
    // THE ONE RULE: the lime is a FILL colour, not a text colour. #C6FF00 measures 16.59:1 on
    // the near-black ground and 1.19:1 on white — not weak, invisible. So dark mode uses it
    // freely (text, icons, lines) while LIGHT resolves the spine to near-black ink and keeps
    // the lime only for filled elements with dark labels on them. Mirrors iOS Theme.swift,
    // which is the reference when the two disagree.
    val PrimaryLight = Color(0xFF0B0B0B)     // ink — NOT lime; see the rule above
    val PrimaryDark = Color(0xFFC6FF00)      // Electric Lime
    val BackgroundLight = Color(0xFFFFFFFF)
    val BackgroundDark = Color(0xFF0B0B0B)   // Voiid Black — the DESIGNED state
    val SurfaceLight = Color(0xFFFFFFFF)
    val SurfaceDark = Color(0xFF1A1A1A)      // Surface — a step ABOVE the ground

    // Bubbles. Lime in BOTH themes: a filled element is exactly where the lime works, and it
    // is what makes your own thread trackable down the screen.
    val BubbleSentLight = Color(0xFFC6FF00)
    val BubbleSentDark = Color(0xFFC6FF00)
    // Fixed in both themes: the fill is lime in both, and a light fill needs dark text.
    // 16.59:1.
    val TextOnBubble = Color(0xFF0B0B0B)

    /** Label on the lime accent. Fixed in both themes — see [VoiidColor.textOnAccent]. */
    val TextOnAccent = Color(0xFF0B0B0B)
    // Surface-light in dark so THEIR bubble separates from both the ground and the card.
    val BubbleRecvLight = Color(0xFFF7F7F7)
    val BubbleRecvDark = Color(0xFF2A2A2A)

    // Text
    val TextPrimaryLight = Color(0xFF0B0B0B)
    val TextPrimaryDark = Color(0xFFF5F5F5)
    // Light is darker than the palette's #A3A3A3, which measured 2.32:1 on white —
    // unreadable as secondary text. 5.33:1 / 7.80:1.
    val TextSecondaryLight = Color(0xFF6B6B6B)
    val TextSecondaryDark = Color(0xFFA3A3A3)
    // On a filled primary surface. Dark primary is lime so its label is near-black; light
    // primary is ink so its label is near-white. Both directions correct.
    val TextOnPrimaryLight = Color(0xFFF5F5F5)
    val TextOnPrimaryDark = Color(0xFF0B0B0B)
    val PlaceholderLight = Color(0xFF8A8A8A)
    val PlaceholderDark = Color(0xFF6B6B6B)

    // Lines
    val DividerLight = Color(0xFFE8E8E8)
    val DividerDark = Color(0xFF2A2A2A)
    val FieldBorderLight = Color(0xFFD4D4D4)
    val FieldBorderDark = Color(0xFF3A3A3A)
    val FieldFillLight = Color(0xFFF7F7F7)
    val FieldFillDark = Color(0xFF121212)

    // Accent — the lime as a FILL. NOT theme-split, unlike the old amber: a filled lime chip
    // works on both grounds because what matters is its LABEL's contrast against the fill
    // (16.59:1), not the fill against the ground.
    //
    // CAVEAT on light: lime vs white is 1.19:1, so a lime fill has no visible edge on white.
    // Anything relying on its boundary needs FieldBorder or an ink outline.
    val SparkLight = Color(0xFFC6FF00)
    val SparkDark = Color(0xFFC6FF00)

    // Lime at reading weight, for the rare case where the brand must be TEXT on a LIGHT
    // ground. The same hue pushed to 4.62:1 on white — olive rather than electric, which is
    // the honest cost. Prefer a filled accent chip.
    val AccentInkLight = Color(0xFF5A7A00)
    val AccentInkDark = Color(0xFFC6FF00)

    // Domain hues — the palette's feedback colours, theme-split. The brights measured
    // 1.5-4.0:1 on white (Warning worst at 1.53:1), so light takes darkened variants of the
    // SAME hue at 4.9-7.0:1.
    val StoriesLight = Color(0xFF7E22CE)
    val StoriesDark = Color(0xFFA855F7)
    val MapLight = Color(0xFF1D4ED8)
    val MapDark = Color(0xFF3B82F6)
    val CallsLight = Color(0xFF15803D)
    val CallsDark = Color(0xFF22C55E)
    val PaymentsLight = Color(0xFFA16207)
    val PaymentsDark = Color(0xFFFACC15)

    // Status. Same rule as the domains: light values are darkened variants, because the
    // palette's brights are designed for near-black.
    val SuccessLight = Color(0xFF15803D)
    val SuccessDark = Color(0xFF22C55E)
    val ErrorLight = Color(0xFFDC2626)
    val ErrorDark = Color(0xFFEF4444)
    val WarningLight = Color(0xFFA16207)
    val WarningDark = Color(0xFFFACC15)
    val InfoLight = Color(0xFF1D4ED8)
    val InfoDark = Color(0xFF3B82F6)
}
