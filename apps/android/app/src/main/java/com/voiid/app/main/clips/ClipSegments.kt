package com.voiid.app.main.clips

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.effect.SpeedChangeEffect
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File

/**
 * One recorded take: the file, the playback speed the author chose for it, and how long the
 * shutter was actually open.
 *
 * SPEED IS STORED, NOT APPLIED. The camera always records at 1x and the speed rides along as
 * metadata until [ClipSegments.concatenate] bakes it in. Re-timing at capture would mean
 * running a transcode between takes — seconds of dead shutter — and it would throw away the
 * original footage, so changing your mind about 3x would cost you the take.
 */
data class ClipTake(
    val file: File,
    val speed: Float = 1f,
    /** Wall-clock length of the recording, from CameraX's own recording stats. */
    val recordedMs: Long = 0L,
) {
    /**
     * How much of the finished clip this take will occupy.
     *
     * The 90s cap is a property of the EXPORTED video (backend MAX_DURATION_MS), not of how
     * long the shutter was open: a 0.3x take stretches to more than three times its recorded
     * length. Counting wall-clock seconds against the cap would let a slow-motion recording
     * sail past it and be rejected only at post, after the whole ladder had been encoded.
     */
    val outputMs: Long get() = if (speed <= 0f) recordedMs else (recordedMs / speed).toLong()
}

/**
 * Joins the takes recorded by [ClipCameraView] into the single file the rest of the composer
 * expects, applying each take's chosen speed on the way through.
 *
 * Concatenation happens HERE, once, rather than after every stop in the camera: CameraX has no
 * append mode, so each take is its own file, and re-muxing the accumulated recording on every
 * stop would stall the shutter for seconds on a long take. The camera stays responsive and
 * pays the cost once, when the user commits.
 */
object ClipSegments {

    /**
     * Concatenate [takes] in order. Returns the single joined file, or null if the export
     * failed. A one-take recording AT 1x is returned as-is — running a whole transcode to copy
     * one file would be pure loss, and it is the overwhelmingly common case. Any other speed
     * is a real re-time, so the shortcut cannot apply.
     */
    suspend fun concatenate(context: Context, takes: List<ClipTake>): File? {
        if (takes.isEmpty()) return null
        if (takes.size == 1 && takes.first().speed == 1f) return takes.first().file

        val out = File(context.cacheDir, "clip_joined_${System.currentTimeMillis()}.mp4")
        val sequence = EditedMediaItemSequence(
            takes.map { take ->
                EditedMediaItem.Builder(MediaItem.fromUri(take.file.toURI().toString()))
                    .setEffects(effectsFor(take.speed))
                    .build()
            }
        )
        val composition = Composition.Builder(sequence).build()

        // Transformer MUST be built, started and cancelled on ONE thread — the one whose
        // Looper it captured at build time — and it enforces that with
        // verifyApplicationThread(). See the long note in ClipEditor: calling start() off the
        // main thread throws and kills the process. The transcode itself still runs on
        // Transformer's own workers, so this does not block the UI.
        val ok = withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, result: ExportResult) {
                            if (cont.isActive) cont.resume(true) {}
                        }

                        override fun onError(
                            composition: Composition,
                            result: ExportResult,
                            exception: ExportException,
                        ) {
                            android.util.Log.w(
                                "VOIID", "clip segment join failed: ${exception.message}")
                            if (cont.isActive) cont.resume(false) {}
                        }
                    })
                    .build()
                transformer.start(composition, out.absolutePath)
                cont.invokeOnCancellation {
                    CoroutineScope(Dispatchers.Main.immediate).launch { transformer.cancel() }
                }
            }
        }

        if (!ok || !out.exists() || out.length() == 0L) {
            runCatching { out.delete() }
            return null
        }
        // The takes are consumed by the join; leaving them behind would double the cache cost
        // of every multi-segment recording.
        takes.forEach { runCatching { it.file.delete() } }
        return out
    }

    /**
     * Video AND audio have to be re-timed together, by the same factor, or a 2x take plays at
     * double speed over audio that still runs at 1x and drifts further out of sync every
     * second. [SpeedChangeEffect] handles the frames; [SonicAudioProcessor] resamples the
     * audio. Sonic scales pitch along with tempo, which is the sound everyone already
     * associates with sped-up video.
     */
    private fun effectsFor(speed: Float): Effects {
        if (speed == 1f) return Effects.EMPTY
        return Effects(
            listOf(SonicAudioProcessor().apply { setSpeed(speed) }),
            listOf(SpeedChangeEffect(speed)),
        )
    }
}
