package com.voiid.app.ui.components

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/**
 * Native haptics — the Android counterpart to iOS `Haptics`.
 *
 * Drives the vibration motor directly via [Vibrator] / [VibratorManager] + [VibrationEffect] so a
 * buzz always fires (the iOS `UIImpactFeedbackGenerator` contract), instead of going through
 * `View.performHapticFeedback`, whose light constants are gated behind the OEM "touch feedback"
 * system setting and are silently dropped on many phones.
 *
 * Mapping to iOS impact styles:
 *   tap/selection → EFFECT_TICK (light)   soft → EFFECT_CLICK (medium)
 *   rigid → EFFECT_HEAVY_CLICK             success → EFFECT_DOUBLE_CLICK (notification)
 *
 * Requires `android.permission.VIBRATE`. Honours the device having a motor + the global vibration
 * toggle; full fallbacks down to API 24.
 */
class VoiidHaptics(context: Context) {

    private val vibrator: Vibrator? = run {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val mgr = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            mgr?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    private val hasMotor = vibrator?.hasVibrator() == true

    /** Predefined effect on API 29+, one-shot fallback on 26-28, legacy vibrate below that. */
    private fun predefined(effectId: Int, fallbackMs: Long, fallbackAmplitude: Int) {
        val v = vibrator ?: return
        if (!hasMotor) return
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
                v.vibrate(VibrationEffect.createPredefined(effectId))
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ->
                v.vibrate(VibrationEffect.createOneShot(fallbackMs, clampAmplitude(fallbackAmplitude)))
            else ->
                @Suppress("DEPRECATION") v.vibrate(fallbackMs)
        }
    }

    private fun clampAmplitude(amplitude: Int): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && vibrator?.hasAmplitudeControl() == true) {
            amplitude.coerceIn(1, 255)
        } else {
            VibrationEffect.DEFAULT_AMPLITUDE
        }

    /** A short double-buzz "success" — waveform on API 26+, pattern fallback below. */
    private fun successPulse() {
        val v = vibrator ?: return
        if (!hasMotor) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            v.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK))
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            v.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 18, 80, 28), -1))
        } else {
            @Suppress("DEPRECATION") v.vibrate(longArrayOf(0, 18, 80, 28), -1)
        }
    }

    /** Light impact — taps on buttons / nav. */
    fun tap() = predefined(VibrationEffect.EFFECT_TICK, fallbackMs = 12, fallbackAmplitude = 90)

    /** Soft/medium impact — press-in feedback. */
    fun soft() = predefined(VibrationEffect.EFFECT_CLICK, fallbackMs = 16, fallbackAmplitude = 140)

    /** Rigid/heavy impact — start of a press-and-hold (e.g. voice record). */
    fun rigid() = predefined(VibrationEffect.EFFECT_HEAVY_CLICK, fallbackMs = 24, fallbackAmplitude = 255)

    /** Selection change — picker / segmented ticks. */
    fun selection() = predefined(VibrationEffect.EFFECT_TICK, fallbackMs = 10, fallbackAmplitude = 80)

    /** Success notification — completed actions. */
    fun success() = successPulse()
}

val LocalVoiidHaptics = compositionLocalOf<VoiidHaptics> {
    error("VoiidHaptics not provided — wrap content in VoiidApp / provide LocalVoiidHaptics")
}

@Composable
fun rememberVoiidHaptics(): VoiidHaptics {
    val context = LocalContext.current
    return remember(context) { VoiidHaptics(context.applicationContext) }
}
