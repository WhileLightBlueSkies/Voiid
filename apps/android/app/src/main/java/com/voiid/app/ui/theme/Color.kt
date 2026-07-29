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
    // Spine
    val PrimaryLight = Color(0xFF0E6F68)      // peacock teal
    val PrimaryDark = Color(0xFF3FBFB2)       // lifted so it stays vivid on black
    val BackgroundLight = Color(0xFFF8F5F1)   // warm off-white, not grey
    val BackgroundDark = Color(0xFF0C0A10)    // near-black with a violet cast
    val SurfaceLight = Color(0xFFFFFFFF)
    val SurfaceDark = Color(0xFF1A171D)

    // Bubbles. Dark is nudged brighter so YOUR bubble separates from THEIRS (3.61:1 vs
    // #1A171D) while white text on it still clears AA at 4.62:1.
    val BubbleSentLight = Color(0xFF0E6F68)
    val BubbleSentDark = Color(0xFF117E76)
    val TextOnBubble = Color(0xFFF0FAF8)
    val BubbleRecvLight = Color(0xFFFFFFFF)
    val BubbleRecvDark = Color(0xFF1A171D)

    // Text
    val TextPrimaryLight = Color(0xFF12101A)
    val TextPrimaryDark = Color(0xFFEEEAF0)
    val TextSecondaryLight = Color(0xFF5A5362)
    val TextSecondaryDark = Color(0xFFA49CAB)
    val TextOnPrimaryLight = Color(0xFFF0FAF8)
    val TextOnPrimaryDark = Color(0xFF06211E)
    val PlaceholderLight = Color(0xFF8A8292)
    val PlaceholderDark = Color(0xFF786F80)

    // Lines
    val DividerLight = Color(0xFFE4DED6)
    val DividerDark = Color(0xFF29242F)
    val FieldBorderLight = Color(0xFFD9D2CA)
    val FieldBorderDark = Color(0xFF38323E)
    val FieldFillLight = Color(0xFFF1EDE7)
    val FieldFillDark = Color(0xFF16131B)

    // Accent. THEME-SPLIT: the bright value measured only 2.49:1 on the light ground (under
    // the 3:1 a UI surface needs) and white text on it failed at 2.70:1, so light uses a
    // deeper burnt orange. Dark keeps the bright value, already 7.29:1 there.
    val SparkLight = Color(0xFFC25022)
    val SparkDark = Color(0xFFE8825A)

    // Domain hues
    val StoriesLight = Color(0xFF7B4B8A)
    val StoriesDark = Color(0xFFB98BC7)
    val MapLight = Color(0xFF1F6091)
    val MapDark = Color(0xFF7FB6DE)
    val CallsLight = Color(0xFF2E7D5B)
    val CallsDark = Color(0xFF5FBE8D)
    val PaymentsLight = Color(0xFFA85C2B)
    val PaymentsDark = Color(0xFFD9884A)

    // Status
    val SuccessLight = Color(0xFF1F7A52)
    val SuccessDark = Color(0xFF63C78D)
    val ErrorLight = Color(0xFFC0392F)
    val ErrorDark = Color(0xFFEF7A6B)
    val WarningLight = Color(0xFFB07818)
    val WarningDark = Color(0xFFE0A83C)
}
