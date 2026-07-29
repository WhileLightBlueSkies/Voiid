package com.voiid.app.ui.theme

import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Whether the current composition is rendering DARK.
 *
 * Every [VoiidColor] token reads this, which is what makes ~807 call sites theme-aware from a
 * single provider at the root. `staticCompositionLocalOf` rather than `compositionLocalOf`:
 * the value changes only on a whole-app theme switch, so invalidating the entire tree is
 * exactly what we want and is cheaper than tracking fine-grained reads.
 */
val LocalVoiidDark = staticCompositionLocalOf { false }

/**
 * Light / Dark / System, persisted per device.
 *
 * The app used to be pinned light (`lightColorScheme` with no dark counterpart) because the
 * palette had no dark values to resolve to. Peacock is fully theme-aware, so the choice now
 * belongs to the user — matching WhatsApp and Signal, which both offer these three options.
 *
 * SYSTEM is the default: an OS-level preference the user already expressed is the right
 * starting point, and it means a scheduled night mode works for free.
 */
enum class VoiidThemeMode { SYSTEM, LIGHT, DARK }

object VoiidThemeStore {
    private const val PREFS = "voiid_appearance"
    private const val KEY = "theme_mode"

    /** Observable so the Settings picker retints the whole app on tap. */
    var mode by mutableStateOf(VoiidThemeMode.SYSTEM)
        private set

    /** Call once at app start, BEFORE the first composition, so there is no light flash. */
    fun load(context: Context) {
        val raw = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, VoiidThemeMode.SYSTEM.name) ?: VoiidThemeMode.SYSTEM.name
        mode = runCatching { VoiidThemeMode.valueOf(raw) }.getOrDefault(VoiidThemeMode.SYSTEM)
    }

    fun set(context: Context, next: VoiidThemeMode) {
        mode = next
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, next.name).apply()
        applyToSystem(context)
    }

    /**
     * Push the choice down to the platform so the LAUNCH WINDOW matches.
     *
     * Compose only starts drawing after `setContent`; before that the window is painted from
     * `Theme.Voiid`, which resolves values/ vs values-night/ by the SYSTEM setting. Without
     * this, a user who picks Dark while their phone is in light mode gets a bright flash on
     * every cold start. `setApplicationNightMode` (API 31+) makes the resource qualifier
     * follow the in-app choice instead. Below 31 the launch window tracks the system and the
     * flash remains — acceptable, and not worth pulling in AppCompat for.
     */
    fun applyToSystem(context: Context) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S) return
        val ui = context.getSystemService(android.app.UiModeManager::class.java) ?: return
        runCatching {
            ui.setApplicationNightMode(
                when (mode) {
                    VoiidThemeMode.SYSTEM -> android.app.UiModeManager.MODE_NIGHT_AUTO
                    VoiidThemeMode.LIGHT -> android.app.UiModeManager.MODE_NIGHT_NO
                    VoiidThemeMode.DARK -> android.app.UiModeManager.MODE_NIGHT_YES
                },
            )
        }
    }
}

private val LightScheme = lightColorScheme(
    primary = VoiidPalette.PrimaryLight,
    onPrimary = VoiidPalette.TextOnPrimaryLight,
    secondary = VoiidPalette.SparkLight,
    onSecondary = VoiidPalette.TextPrimaryLight,
    background = VoiidPalette.BackgroundLight,
    onBackground = VoiidPalette.TextPrimaryLight,
    surface = VoiidPalette.SurfaceLight,
    onSurface = VoiidPalette.TextPrimaryLight,
    surfaceVariant = VoiidPalette.FieldFillLight,
    onSurfaceVariant = VoiidPalette.TextSecondaryLight,
    error = VoiidPalette.ErrorLight,
    outline = VoiidPalette.FieldBorderLight,
)

private val DarkScheme = darkColorScheme(
    primary = VoiidPalette.PrimaryDark,
    onPrimary = VoiidPalette.TextOnPrimaryDark,
    secondary = VoiidPalette.SparkDark,
    onSecondary = VoiidPalette.TextPrimaryDark,
    background = VoiidPalette.BackgroundDark,
    onBackground = VoiidPalette.TextPrimaryDark,
    surface = VoiidPalette.SurfaceDark,
    onSurface = VoiidPalette.TextPrimaryDark,
    surfaceVariant = VoiidPalette.FieldFillDark,
    onSurfaceVariant = VoiidPalette.TextSecondaryDark,
    error = VoiidPalette.ErrorDark,
    outline = VoiidPalette.FieldBorderDark,
)

/**
 * Root theme. Resolves the user's choice against the system setting, publishes it via
 * [LocalVoiidDark] for the Voiid tokens, and hands the matching Material3 scheme to any stock
 * component (bottom sheets, dialogs, ripples) so those are on-brand in both themes too.
 */
@Composable
fun VoiidTheme(content: @Composable () -> Unit) {
    val systemDark = isSystemInDarkTheme()
    val dark = when (VoiidThemeStore.mode) {
        VoiidThemeMode.SYSTEM -> systemDark
        VoiidThemeMode.LIGHT -> false
        VoiidThemeMode.DARK -> true
    }
    CompositionLocalProvider(LocalVoiidDark provides dark) {
        MaterialTheme(
            colorScheme = if (dark) DarkScheme else LightScheme,
            typography = VoiidTypography,
            content = content,
        )
    }
}
