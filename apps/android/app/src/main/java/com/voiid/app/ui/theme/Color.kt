package com.voiid.app.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * VOIID design tokens (Master Spec Section 6.1) — mirrors the iOS `VoiidColor`.
 * Fixed light design: the same values are used in light & dark (background stays #DFDFDF always).
 */
object VoiidColor {
    // Locked tokens — fixed in BOTH light & dark.
    val primary      = Color(0xFF4D3E47)   // brand plum
    val background   = Color(0xFFDFDFDF)   // app base surface — same light/dark
    val fieldBorder  = Color(0xFFE3BED8)
    val fieldFill    = Color(0xFFFCF4F8)   // light pink — same light/dark
    val bubbleSent   = Color(0xFFC8C8C8)

    // Derived tokens
    val bubbleReceived = Color(0xFFFCF4F8)
    val surfaceCard    = Color(0xFFFFFFFF)

    // Fixed text colors (background is fixed light, so text stays dark).
    val textPrimary    = Color(0xFF4D3E47)   // brand plum
    val textSecondary  = Color(0xFF7A6E74)   // muted plum
    val textOnPrimary  = Color(0xFFFCF4F8)
    val placeholder    = Color(0xFF9B8F95)   // clearly muted on the light pink field
    val divider        = Color(0xFFE3BED8)
    val accent         = Color(0xFFE3BED8)

    /// Theme-aware text on iOS — here the design is fixed light, so it equals the plum primary.
    val adaptiveText   = Color(0xFF4D3E47)

    // Status
    val success = Color(0xFF3E9E6E)
    val error   = Color(0xFFC0556B)
    val warning = Color(0xFFD8A24A)
    val info    = Color(0xFF4D3E47)
}
