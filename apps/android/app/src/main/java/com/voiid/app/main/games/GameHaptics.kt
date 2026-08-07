package com.voiid.app.main.games

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Haptics for in-match Snake events (GAMES_ANIMATION.md §8), as opposed to `VoiidHaptics`
 * (ui/components/Haptics.kt) which covers ordinary UI taps.
 *
 * WHY A SEPARATE CLASS RATHER THAN NEW METHODS ON [com.voiid.app.ui.components.VoiidHaptics].
 * That class deliberately stays at API 26's `createOneShot`/`createWaveform` ceiling and a
 * five-method UI vocabulary (tap/soft/rigid/selection/success). Game events want richer
 * envelopes than that vocabulary has room for — a kill wants a sharp transient plus a distinct
 * decaying rumble, which is two shaped segments, not one preset — and minSdk is 24 while the
 * primitive composition API this reaches for is 30+, so this needs its OWN three-tier fallback
 * rather than bolting a fourth tier onto a class other UI code depends on staying simple.
 *
 * THREE TIERS (matches the doc's table exactly):
 *   API 30+   VibrationEffect.Composition — PRIMITIVE_CLICK/TICK/QUICK_RISE/QUICK_FALL,
 *             composable with per-primitive scale. Closest analogue to iOS Core Haptics.
 *   API 26-29 VibrationEffect.createWaveform(timings, amplitudes, -1) — amplitude control,
 *             no primitives, same technique `VoiidHaptics.boundary()` already uses.
 *   API 24-25 Vibrator.vibrate(longArray, -1) — crude on/off pattern only.
 *
 * Mirrors iOS `GameHaptics.swift` — same event-to-feel mapping, necessarily different APIs
 * (Core Haptics has no Android equivalent).
 */
class GameHaptics(context: Context) {

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
    private val hasAmplitudeControl =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && vibrator?.hasAmplitudeControl() == true

    /** Wall-clock throttle for [eat] — see that function for why. Owned HERE rather than left
     * to the caller: every caller of a retriggering haptic would otherwise have to remember
     * its own cooldown, and getting that wrong is silent (a buzz instead of a crash), so the
     * one thing in this class that retriggers fast owns its own floor. */
    private var lastEatAtNanos = 0L
    private val eatMinGapNanos = 60_000_000L   // 60ms — matches iOS GameHaptics.swift's throttle

    /** Light tick on eating. Flat intensity — the server's `eat` event carries no food value
     * (position + eater id only, see snake/index.ts's `k: 'eat'` push), and this can fire
     * several times a second, so a per-pickup distinction would be imperceptible at that rate
     * anyway. RATE-LIMITED INTERNALLY: `eat` can fire several times a second in a food-dense
     * patch, and a motor retriggered that fast reads as a buzz rather than a series of
     * distinct ticks — 60ms keeps individual eats distinguishable without saturating the
     * hardware queue, matching iOS's identical floor. */
    fun eat() {
        if (!hasMotor) return
        val now = System.nanoTime()
        if (now - lastEatAtNanos < eatMinGapNanos) return
        lastEatAtNanos = now
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> primitiveClick(scale = 0.4f)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ->
                vibrator?.vibrate(VibrationEffect.createOneShot(10, clampAmplitude(90)))
            else -> @Suppress("DEPRECATION") vibrator?.vibrate(10)
        }
    }

    /** Sharp transient + a short decaying rumble — same envelope shape as the `kill` sound
     * recipe in docs/GAMES_AUDIO.md §8.6 (impact + descending tone + sub) and the 120ms
     * hitstop in ImpactTimeline. Three channels landing on one event is what makes a kill read
     * as one beat instead of three separate signals. */
    fun kill() {
        if (!hasMotor) return
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                val composition = VibrationEffect.startComposition()
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, 1.0f)
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, 0.5f, 20)
                vibrator?.vibrate(composition.compose())
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                val timings = longArrayOf(0, 30, 20, 100)
                val amplitudes = intArrayOf(0, 255, 0, 130)
                vibrator?.vibrate(
                    if (hasAmplitudeControl) VibrationEffect.createWaveform(timings, amplitudes, -1)
                    else VibrationEffect.createWaveform(timings, -1)
                )
            }
            else -> @Suppress("DEPRECATION") vibrator?.vibrate(longArrayOf(0, 30, 20, 100), -1)
        }
    }

    /** Heavy transient + a longer decaying rumble — the biggest haptic in the game, matching
     * death being the biggest audio/visual moment (docs/GAMES_AUDIO.md §8.7, ImpactTimeline's
     * 100ms freeze + 500ms slow-mo). */
    fun death() {
        if (!hasMotor) return
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                val composition = VibrationEffect.startComposition()
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_QUICK_RISE, 1.0f)
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, 0.7f, 30)
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, 0.5f, 60)
                vibrator?.vibrate(composition.compose())
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                val timings = longArrayOf(0, 40, 30, 200)
                val amplitudes = intArrayOf(0, 255, 0, 180)
                vibrator?.vibrate(
                    if (hasAmplitudeControl) VibrationEffect.createWaveform(timings, amplitudes, -1)
                    else VibrationEffect.createWaveform(timings, -1)
                )
            }
            else -> @Suppress("DEPRECATION") vibrator?.vibrate(longArrayOf(0, 40, 30, 200), -1)
        }
    }

    /** Soft pulse for the arena border danger vignette, `proximity` 0 (far) to 1 (about to
     * die). Deliberately gentle even at full intensity — this can retrigger every frame while
     * a player hugs the wall, and a strong haptic on a loop reads as the device malfunctioning
     * rather than as a warning. RATE-LIMITING IS THE CALLER'S JOB, same as [eat]. */
    fun borderPulse(proximity: Float) {
        if (!hasMotor || proximity <= 0.05f) return
        val amplitude = (proximity * 100).toInt().coerceIn(1, 100)
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> primitiveClick(scale = proximity.coerceAtMost(0.4f))
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ->
                vibrator?.vibrate(VibrationEffect.createOneShot(12, clampAmplitude(amplitude)))
            else -> @Suppress("DEPRECATION") vibrator?.vibrate(12)
        }
    }

    private fun primitiveClick(scale: Float) {
        val composition = VibrationEffect.startComposition()
            .addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, scale)
        vibrator?.vibrate(composition.compose())
    }

    private fun clampAmplitude(amplitude: Int): Int =
        if (hasAmplitudeControl) amplitude.coerceIn(1, 255) else VibrationEffect.DEFAULT_AMPLITUDE
}
