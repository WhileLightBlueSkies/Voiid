package com.voiid.app.main.games.ludobot

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import com.voiid.app.main.games.GameSettings

/**
 * In-match haptics for bot Ludo. Mirrors iOS `LudoHaptics` in `Games/Ludo/LudoGame.swift`:
 * a light tick leaving the yard, a heavy thud on a capture, a success pulse on reaching home.
 *
 * ONE GATE, in [play], rather than a check in each entry point — the fourth one added would
 * forget it. The setting is read per call, so turning haptics off in the settings sheet stops
 * them in the match already running rather than only in the next one.
 */
class LudoBotHaptics(context: Context) {

    private val appContext = context.applicationContext

    private val vibrator: Vibrator? = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = appContext.getSystemService(VibratorManager::class.java)
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            appContext.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }.getOrNull()

    private fun play(durationMs: Long, amplitude: Int) {
        if (!GameSettings.hapticsEnabled(appContext)) return
        val v = vibrator ?: return
        if (!v.hasVibrator()) return
        runCatching {
            // `VibrationEffect` is API 26 and minSdk is 24, so the two oldest supported
            // versions take the deprecated call. They lose amplitude control — a pre-26
            // vibrate is on or off — which is why the durations carry the weight difference
            // there: a 45ms capture still feels heavier than an 18ms tick.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createOneShot(durationMs, amplitude))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(durationMs)
            }
        }
    }

    /** Light tick as a token leaves the yard. */
    fun tick() = play(18, 90)

    /** Heavy thud on sending an opponent home. */
    fun thud() = play(45, 255)

    /** Crisp thud when the die lands on the tray. */
    fun impact() = play(24, 200)

    /** Success pulse as a token reaches home. */
    fun success() = play(30, 170)
}
