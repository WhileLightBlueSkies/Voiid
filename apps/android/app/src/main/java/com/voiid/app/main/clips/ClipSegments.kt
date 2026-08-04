package com.voiid.app.main.clips

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
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
 * Joins the takes recorded by [ClipCameraView] into the single file the rest of the composer
 * expects.
 *
 * Concatenation happens HERE, once, rather than after every stop in the camera: CameraX has no
 * append mode, so each take is its own file, and re-muxing the accumulated recording on every
 * stop would stall the shutter for seconds on a long take. The camera stays responsive and
 * pays the cost once, when the user commits.
 */
object ClipSegments {

    /**
     * Concatenate [segments] in order. Returns the single joined file, or null if the export
     * failed. A one-segment recording is returned as-is — running a whole transcode to copy
     * one file would be pure loss, and it is the overwhelmingly common case.
     */
    suspend fun concatenate(context: Context, segments: List<File>): File? {
        if (segments.isEmpty()) return null
        if (segments.size == 1) return segments.first()

        val out = File(context.cacheDir, "clip_joined_${System.currentTimeMillis()}.mp4")
        val sequence = EditedMediaItemSequence(
            segments.map { EditedMediaItem.Builder(MediaItem.fromUri(it.toURI().toString())).build() }
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
        segments.forEach { runCatching { it.delete() } }
        return out
    }
}
