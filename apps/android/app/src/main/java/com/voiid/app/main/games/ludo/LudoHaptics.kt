package com.voiid.app.main.games.ludo

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Ludo haptics (§13–§15): the ACTIVE player's own device only.
 *   light at 5/4/3 s remaining, medium at 2/1 s — each fired ONCE per turn serial;
 *   medium impact at the die's 760 ms beat, once per rollId;
 *   rigid impact for the capturer, warning pattern for the captured.
 *
 * Never replayed after foreground/reconnect: callers pass the current serial/rollId and this
 * object remembers what it already fired. Respects its own system settings gate.
 */
object LudoHaptics {

    private var lastTimerKey: String? = null
    private var lastRollId: String? = null

    fun reset() {
        lastTimerKey = null
        lastRollId = null
    }

    private val vibrator: Vibrator? = null

    private fun vibrate(context: Context, amplitude: Int, ms: Long) {
        val v = vibratorOf(context) ?: return
        val effect = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            VibrationEffect.createOneShot(ms, amplitude)
        } else {
            @Suppress("DEPRECATION") VibrationEffect.createWaveform(longArrayOf(0, ms), -1)
        }
        v.vibrate(effect)
    }

    private fun vibratorOf(context: Context): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION") context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }

    /** Called from the ring ticker with secondsRemaining; fires once per threshold per turn. */
    fun timerTick(context: Context, key: String, secondsRemaining: Int) {
        if (!enabled(context)) return
        val fire = when (secondsRemaining) {
            5, 4, 3 -> "light:$secondsRemaining"
            2, 1 -> "med:$secondsRemaining"
            else -> null
        } ?: return
        val full = "$key:$fire"
        if (lastTimerKey == full) return   // never replay after reconnect/foreground (§13)
        lastTimerKey = full
        vibrate(context, if (secondsRemaining >= 3) 60 else 120, 24)
    }

    fun rollImpact(context: Context, rollId: String) {
        if (!enabled(context) || lastRollId == rollId) return
        lastRollId = rollId
        vibrate(context, 160, 34)
    }

    fun captureByMe(context: Context) = vibrate(context, 180, 40)
    fun captureOnMe(context: Context) = vibrate(context, 140, 70)

    private fun enabled(context: Context): Boolean =
        com.voiid.app.main.games.GameSettings.hapticsEnabled(context.applicationContext)
}
