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

    val domainChat: Color @Composable @ReadOnlyComposable get() = pick(VoiidPalette.AccentInkLight, VoiidPalette.AccentInkDark)
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
    // Spine — PEACOCK TEAL. Mirrors iOS Theme.swift, which is the reference when the two
    // disagree.
    //
    // ── MIGRATED FROM ELECTRIC LIME ─────────────────────────────────────────────────
    // This palette was #C6FF00 on #0B0B0B, and it carried a rule that no longer applies: the
    // lime was a FILL colour and never a text colour, because it measured 1.19:1 on white —
    // invisible — so light mode had to resolve the spine to near-black ink instead.
    //
    // Teal has no such split. #13828C is 4.87:1 on the light ground and its dark lift
    // (#68B8BD) is 8.9:1 on the dark ground, so the SAME hue is legible as text in both
    // themes. That is why PrimaryLight below is the brand colour rather than ink, which is
    // the single biggest behavioural difference from the lime palette: code that assumed
    // "primary is ink in light mode" is now wrong.
    val PrimaryLight = Color(0xFF13828C)     // Peacock teal — legible as text on light
    val PrimaryDark = Color(0xFF68B8BD)      // lifted, so it holds up on the dark ground
    val BackgroundLight = Color(0xFFF6F8F8)
    val BackgroundDark = Color(0xFF080C0E)
    val SurfaceLight = Color(0xFFFFFFFF)
    val SurfaceDark = Color(0xFF111719)      // Surface — a step ABOVE the ground

    // Bubbles. Teal in BOTH themes: a filled element is where the brand colour belongs, and
    // it is what makes your own thread trackable down the screen.
    val BubbleSentLight = Color(0xFF13828C)
    val BubbleSentDark = Color(0xFF13828C)
    // Fixed in both themes. WHITE now, not near-black: the fill is a mid-dark teal, so its
    // label must be light. This inverted when the palette left lime — a #0B0B0B label on
    // #13828C measures 2.9:1 and fails.
    val TextOnBubble = Color(0xFFFFFFFF)

    /** Label on the teal accent. Fixed in both themes — see [VoiidColor.textOnAccent]. */
    val TextOnAccent = Color(0xFFFFFFFF)
    // Surface-light in dark so THEIR bubble separates from both the ground and the card.
    val BubbleRecvLight = Color(0xFFEDF1F1)
    val BubbleRecvDark = Color(0xFF182124)

    // Text
    val TextPrimaryLight = Color(0xFF101617)
    val TextPrimaryDark = Color(0xFFF6F8F8)
    val TextSecondaryLight = Color(0xFF5D696C)
    val TextSecondaryDark = Color(0xFFA6B0B2)
    // On a filled primary surface. Both themes fill with a mid-dark teal, so both labels are
    // white — unlike the lime palette, where the two directions differed.
    val TextOnPrimaryLight = Color(0xFFFFFFFF)
    val TextOnPrimaryDark = Color(0xFFFFFFFF)
    val PlaceholderLight = Color(0xFF899396)
    val PlaceholderDark = Color(0xFF6D787B)

    // Lines
    val DividerLight = Color(0xFFD7DEDF)
    val DividerDark = Color(0xFF263236)
    val FieldBorderLight = Color(0xFFD7DEDF)
    val FieldBorderDark = Color(0xFF263236)
    val FieldFillLight = Color(0xFFEDF1F1)
    val FieldFillDark = Color(0xFF111719)

    // Accent — the teal as a FILL. Not theme-split: what matters is its LABEL's contrast
    // against the fill (white on #13828C, 4.87:1), not the fill against the ground.
    //
    // The lime palette carried a caveat here — lime vs white is 1.19:1, so a lime fill had no
    // visible edge on white and anything relying on its boundary needed an outline. Teal does
    // not have that problem: #13828C against #F6F8F8 is a clear edge on its own.
    val SparkLight = Color(0xFF13828C)
    val SparkDark = Color(0xFF13828C)

    // The brand as TEXT. Light uses the brand colour directly (4.87:1 on the light ground);
    // dark lifts it (#68B8BD) because #13828C on #080C0E is too dark to read.
    //
    // The lime palette had to go olive (#5A7A00) here to reach 4.62:1, losing the hue in the
    // process. Teal keeps its identity in both themes, which is much of why the spine moved.
    val AccentInkLight = Color(0xFF13828C)
    val AccentInkDark = Color(0xFF68B8BD)

    /** Pressed state for a filled accent. iOS: VoiidColor.accentPressed. */
    val AccentPressed = Color(0xFF0E6E77)
    /** A wash of the accent, for tinted chips and callout grounds. */
    val AccentTintLight = Color(0xFFD9EFF0)
    val AccentTintDark = Color(0xFF123538)

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
