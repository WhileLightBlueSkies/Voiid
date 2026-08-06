package com.voiid.app.net

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Call-state audio for 1:1 calls: the callee's incoming ringtone, the caller's ringback,
 * busy/declined, and a short end-of-call cue.
 *
 * ## Why STREAM_VOICE_CALL and not STREAM_RING
 * There are two *different* sounds in a call, with deliberately different silent-switch
 * behaviour (see `docs/CALL_RELIABILITY.md`, "P0.5"):
 *
 *  - The **callee's incoming ringtone** ([startIncomingRinger]) rides the ring stream via the
 *    default system ringtone, and therefore *correctly* respects ringer mode — silent means
 *    silent, exactly like a native call. It lives here rather than on the notification channel
 *    because a self-managed `ConnectionService` gets no platform ring, and a channel alert is
 *    a single ding across a 45-second ring window.
 *  - The **caller's ringback** ("brrring brrring" while waiting) must be audible even with the
 *    phone silenced: the user just deliberately placed a call and is holding the handset to
 *    their ear. Playing it on `STREAM_RING`/notification would be muted by ringer mode — the
 *    classic bug. Playing it on **`STREAM_VOICE_CALL`**, under the call's already-applied
 *    `MODE_IN_COMMUNICATION` audio mode, means it is governed by the *in-call* volume, is not
 *    affected by ringer mode at all, and follows the live call route (earpiece / speaker /
 *    wired / Bluetooth SCO) that [CallManager.applyAudioRoute] selected. The same stream the
 *    voice will arrive on is the stream the ringback plays on, so there is no route pop when
 *    media starts.
 *
 * ## Safety
 * A tone must never be able to crash or drop a call, so every [ToneGenerator] interaction is
 * wrapped — the constructor genuinely throws `RuntimeException` when the platform can't hand
 * out an AudioTrack. All work is serialized onto one private background thread: `ToneGenerator`
 * is not thread-safe, and constructing one does real audio-flinger work we don't want on the
 * main thread. Every generator is explicitly `release()`d (they leak an AudioTrack otherwise),
 * and one-shot tones are released on a delayed post rather than left for the GC.
 */
object CallTones {

    /** In-call stream: not silenced by ringer mode, follows the MODE_IN_COMMUNICATION route. */
    private const val STREAM = AudioManager.STREAM_VOICE_CALL

    /** Percent of max stream volume. Ringback should sit under the peer's voice, not over it. */
    private const val RINGBACK_VOLUME = 70
    private const val SIGNAL_VOLUME = 80

    /** Busy/declined feedback: long enough to register, short enough not to annoy. */
    private const val BUSY_MS = 3_000L
    private const val ENDED_MS = 250L

    private val thread = HandlerThread("VoiidCallTones").apply { start() }
    private val handler = Handler(thread.looper)

    /** The looping ringback generator; non-null exactly while ringback is audible. */
    private var ringback: ToneGenerator? = null

    /** One-shot generators still playing out, tracked so teardown can release them early. */
    private val oneShots = ArrayList<ToneGenerator>(2)

    // ---- incoming ringer (callee side) -----------------------------------------

    /** One second on, one second off, repeating from index 0 — the familiar ring cadence. */
    private val RING_VIBRATION = longArrayOf(0L, 1_000L, 1_000L)

    /** The looping ringtone player; non-null exactly while the ringtone is audible. */
    private var ringer: MediaPlayer? = null
    private var ringerVibrator: Vibrator? = null

    /**
     * True from the moment the ringer is armed, whether or not it ended up making sound —
     * in RINGER_MODE_VIBRATE there is no [ringer] to test but there is still a running
     * vibration, and both must be idempotent against a re-post of the ring notification.
     */
    @Volatile private var incomingRinging = false

    /**
     * Start the callee-side incoming ringtone loop.
     *
     * With a self-managed [android.telecom.ConnectionService] the platform does NOT ring on the
     * app's behalf, and the incoming-call notification channel is deliberately silent (see
     * [CallForegroundService]) so the two can never double up — which leaves this as the only
     * thing a user in the next room hears. Ringer mode is honoured exactly as a native call
     * would: SILENT rings nothing at all, VIBRATE buzzes without sound.
     *
     * Idempotent: the ring notification is re-posted whenever the caller's name finishes
     * resolving, and restarting the ringtone from the top on every re-post would be audible.
     */
    fun startIncomingRinger(context: Context) {
        val app = context.applicationContext
        handler.post {
            if (incomingRinging) return@post
            val am = app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return@post
            val mode = runCatching { am.ringerMode }.getOrDefault(AudioManager.RINGER_MODE_NORMAL)
            if (mode == AudioManager.RINGER_MODE_SILENT) return@post
            incomingRinging = true
            startRingVibration(app)
            if (mode != AudioManager.RINGER_MODE_NORMAL) return@post
            val uri = runCatching { RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE) }
                .getOrNull() ?: return@post
            runCatching {
                MediaPlayer().also { mp ->
                    mp.setAudioAttributes(ringAttributes())
                    mp.setDataSource(app, uri)
                    mp.isLooping = true
                    mp.prepare()
                    mp.start()
                    ringer = mp
                }
            }.onFailure {
                runCatching { ringer?.release() }
                ringer = null
                android.util.Log.w("VOIID", "incoming ringtone unavailable: ${it.message}")
            }
        }
    }

    /**
     * Stop the incoming ringer. Called on accept, decline, remote hang-up and ring timeout — a
     * ringtone that outlives its ring is worse than no ringtone. Safe when nothing is playing.
     */
    fun stopIncomingRinger() {
        handler.post {
            incomingRinging = false
            ringer?.let { mp ->
                ringer = null
                runCatching { mp.stop() }
                runCatching { mp.release() }
            }
            ringerVibrator?.let { v ->
                ringerVibrator = null
                runCatching { v.cancel() }
            }
        }
    }

    private fun ringAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

    // The pre-API-26 Vibrator entry points are the only ones that exist on our minSdk 24 floor.
    @Suppress("DEPRECATION")
    private fun startRingVibration(app: Context) {
        val v = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (app.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
            } else {
                app.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
        }.getOrNull() ?: return
        if (!runCatching { v.hasVibrator() }.getOrDefault(false)) return
        ringerVibrator = v
        // The audio attributes are what make the OS treat this as a RING vibration, so it
        // still fires under a Do Not Disturb rule that allows calls through.
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createWaveform(RING_VIBRATION, 0), ringAttributes())
            } else {
                v.vibrate(RING_VIBRATION, 0, ringAttributes())
            }
        }
    }

    // ---- ringback --------------------------------------------------------------

    /**
     * Start the caller-side ringback loop. Idempotent — a duplicate `call_ringing` frame (the
     * callee re-raising its notification, or a signaling replay from the outbox) must not stack
     * a second tone on top of the first.
     *
     * `TONE_SUP_RINGTONE` is defined with an infinite repeat count, so a single [startTone]
     * loops until [stopRingback]; there is no timer to keep alive and nothing to re-arm.
     */
    fun startRingback() {
        handler.post {
            if (ringback != null) return@post
            runCatching {
                ToneGenerator(STREAM, RINGBACK_VOLUME).also { gen ->
                    ringback = gen
                    if (!gen.startTone(ToneGenerator.TONE_SUP_RINGTONE)) {
                        // Couldn't actually start — don't hold a live generator for nothing.
                        runCatching { gen.release() }
                        ringback = null
                    }
                }
            }.onFailure {
                ringback = null
                android.util.Log.w("VOIID", "ringback unavailable: ${it.message}")
            }
        }
    }

    /**
     * Stop ringback immediately. Called the instant the call is answered, declined, busy,
     * failed or timed out — ringback bleeding into connected audio is worse than no ringback.
     * Safe to call when nothing is playing.
     */
    fun stopRingback() {
        handler.post {
            val gen = ringback ?: return@post
            ringback = null
            runCatching { gen.stopTone() }
            runCatching { gen.release() }
        }
    }

    // ---- one-shot cues ---------------------------------------------------------

    /** Standard busy/engaged tone — the peer declined, or is already on another call. */
    fun playBusy() = playOneShot(ToneGenerator.TONE_SUP_BUSY, BUSY_MS)

    /** Short "call failed" cue, distinct from busy so the two aren't confused. */
    fun playFailed() = playOneShot(ToneGenerator.TONE_SUP_ERROR, BUSY_MS)

    /** Brief click when a connected call ends normally. */
    fun playEnded() = playOneShot(ToneGenerator.TONE_PROP_PROMPT, ENDED_MS)

    private fun playOneShot(tone: Int, durationMs: Long) {
        handler.post {
            // Never let a cue and the ringback overlap: they are mutually exclusive states.
            ringback?.let { gen ->
                ringback = null
                runCatching { gen.stopTone() }
                runCatching { gen.release() }
            }
            runCatching {
                val gen = ToneGenerator(STREAM, SIGNAL_VOLUME)
                oneShots.add(gen)
                gen.startTone(tone, durationMs.toInt())
                // ToneGenerator does not free itself when the tone ends.
                handler.postDelayed({
                    oneShots.remove(gen)
                    runCatching { gen.stopTone() }
                    runCatching { gen.release() }
                }, durationMs + 250L)
            }.onFailure { android.util.Log.w("VOIID", "tone unavailable: ${it.message}") }
        }
    }

    // ---- teardown --------------------------------------------------------------

    /**
     * Release everything. Called on call teardown so no generator survives the call that
     * created it — a leaked one holds an AudioTrack open on the voice-call stream, which on
     * some devices keeps the whole in-call route alive after the call is gone.
     *
     * [keepOneShots] lets the end-of-call cue finish playing while the call's own ringback is
     * killed instantly.
     */
    fun release(keepOneShots: Boolean = false) {
        stopIncomingRinger()
        handler.post {
            ringback?.let { gen ->
                ringback = null
                runCatching { gen.stopTone() }
                runCatching { gen.release() }
            }
            if (keepOneShots) return@post
            for (gen in oneShots) {
                runCatching { gen.stopTone() }
                runCatching { gen.release() }
            }
            oneShots.clear()
        }
    }
}
