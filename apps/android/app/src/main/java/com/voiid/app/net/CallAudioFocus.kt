package com.voiid.app.net

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Audio focus for calls — requesting it, holding it, and reacting when it is taken away.
 *
 * ## Why this exists
 *
 * Voiid requested audio focus **nowhere**. Two consequences, both bad and both constant:
 *
 *  * **Other apps were never ducked or paused.** You answered a call and heard Spotify
 *    playing over the caller. Android has no other mechanism for this — focus IS the
 *    mechanism, and every calling app is expected to take it.
 *  * **Nothing told Voiid when it lost focus.** A cellular call, an alarm, or a voice
 *    assistant would take the audio device out from under a live Voiid call and the call
 *    would keep running with no microphone and no speaker, with no recovery path. iOS has
 *    handled this since the file was written (`CallService.handleAudioInterruption`); this
 *    is the Android half that was missing.
 *
 * ## The focus type
 *
 * `AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE` with `USAGE_VOICE_COMMUNICATION`. Exclusive rather
 * than plain transient because a call should **pause** a podcast rather than duck it —
 * ducking leaves speech under speech, which is worse than silence. Transient rather than
 * permanent because the call ends and the other app should resume.
 *
 * ## Loss handling
 *
 * `AUDIOFOCUS_LOSS_TRANSIENT` (a phone call, an alarm) mutes capture and playback and
 * expects to get focus back. `AUDIOFOCUS_LOSS` is permanent — the user moved to another
 * audio app deliberately — so the call is left muted rather than silently un-muting later
 * over whatever they are now listening to. `GAIN` restores.
 *
 * `setWillPauseWhenDucked(true)` says: do not duck us, pause the other side. A voice call
 * is not background music.
 */
object CallAudioFocus {

    private var request: Any? = null            // AudioFocusRequest on O+, listener below it
    private var listener: AudioManager.OnAudioFocusChangeListener? = null
    private var onInterruption: ((Boolean) -> Unit)? = null

    /**
     * Take focus for a call.
     *
     * [onInterrupted] is invoked with `true` when the call must go quiet (focus lost) and
     * `false` when it may resume. Engines wire this to their own mute/track handling —
     * this object deliberately knows nothing about WebRTC.
     */
    @Synchronized
    fun request(context: Context, onInterrupted: (Boolean) -> Unit) {
        if (request != null) return              // already held; requesting twice is a no-op
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        onInterruption = onInterrupted

        val l = AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> onInterruption?.invoke(true)
                AudioManager.AUDIOFOCUS_GAIN,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE -> onInterruption?.invoke(false)
                AudioManager.AUDIOFOCUS_LOSS -> {
                    // Permanent: the user chose another audio app. Stay quiet rather than
                    // coming back later over whatever they are now playing.
                    onInterruption?.invoke(true)
                }
            }
        }
        listener = l

        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener(l)
                // Pause the other app, do not duck it: speech under speech is worse than
                // silence.
                .setWillPauseWhenDucked(true)
                // Do not fail the call just because focus is momentarily unavailable.
                .setAcceptsDelayedFocusGain(false)
                .build()
            request = req
            runCatching { am.requestAudioFocus(req) }.getOrDefault(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        } else {
            @Suppress("DEPRECATION")
            runCatching {
                am.requestAudioFocus(l, AudioManager.STREAM_VOICE_CALL,
                                     AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            }.getOrDefault(AudioManager.AUDIOFOCUS_REQUEST_FAILED).also { request = l }
        }

        if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            // Logged, not fatal: the call is still worth having without ducking, and
            // refusing to connect over a focus denial would be a worse failure.
            Log.w("VOIID", "audio focus not granted ($granted) — call continues unducked")
        }
    }

    /** Give focus back so the paused app can resume. Safe to call when nothing is held. */
    @Synchronized
    fun abandon(context: Context) {
        val held = request ?: return
        request = null
        val cb = listener
        listener = null
        onInterruption = null
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && held is AudioFocusRequest) {
                am.abandonAudioFocusRequest(held)
            } else if (cb != null) {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(cb)
            }
        }
    }
}
