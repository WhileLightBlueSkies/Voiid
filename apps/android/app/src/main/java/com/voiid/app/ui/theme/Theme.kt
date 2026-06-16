package com.voiid.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

/**
 * Fixed light brand theme (the VOIID design is identical in light & dark — see ContentView /
 * `.preferredColorScheme(.light)` on iOS). Provides a Material3 colour scheme built from the
 * brand tokens so any stock Material component (bottom sheets, dialogs, ripples) is on-brand.
 */
private val VoiidColorScheme = lightColorScheme(
    primary = VoiidColor.primary,
    onPrimary = VoiidColor.textOnPrimary,
    secondary = VoiidColor.accent,
    onSecondary = VoiidColor.primary,
    background = VoiidColor.background,
    onBackground = VoiidColor.textPrimary,
    surface = VoiidColor.background,
    onSurface = VoiidColor.textPrimary,
    surfaceVariant = VoiidColor.fieldFill,
    onSurfaceVariant = VoiidColor.textSecondary,
    error = VoiidColor.error,
    outline = VoiidColor.fieldBorder,
)

@Composable
fun VoiidTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = VoiidColorScheme,
        typography = VoiidTypography,
        content = content,
    )
}
