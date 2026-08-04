package com.voiid.app.main.clips

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import java.io.File

/**
 * In-app clip camera — record, review, keep. Mirrors what iOS gets from `StoryCameraView`
 * in `.clip` mode (90s cap, video-only, tap-to-toggle, flip, live timer).
 *
 * WHY THIS EXISTS. The Android CameraX stack was IMAGE-ONLY: [com.voiid.app.main.stories
 * .StoryCameraView] binds `ImageCapture` and the `camera-video` artifact was not even a
 * dependency, so the clip composer handed off to the system camera intent. That works, but it
 * is somebody else's UI — no in-app timer, no cap indication, no flip we control, and no way
 * to ever put the filter strip in the live preview. It also meant a process death mid-capture
 * silently dropped the recording (see the rememberSaveable note in ClipComposerFlow).
 *
 * SEGMENTS. Recording is multi-take: each start/stop appends a segment, and the last one can
 * be undone. They are concatenated at export rather than here — CameraX has no append mode,
 * and re-muxing on every stop would stall the shutter for seconds on a long take.
 */
@SuppressLint("MissingPermission") // CAMERA/RECORD_AUDIO are requested at onboarding; see below.
@Composable
fun ClipCameraView(
    maxSeconds: Int = 90,
    onDone: (List<File>) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val haptics = LocalVoiidHaptics.current

    var lensFront by remember { mutableStateOf(false) }
    var recording by remember { mutableStateOf<Recording?>(null) }
    var isRecording by remember { mutableStateOf(false) }
    /** Whole seconds already banked in finished segments, plus the live one. */
    var bankedMs by remember { mutableStateOf(0L) }
    var liveMs by remember { mutableStateOf(0L) }
    val segments = remember { mutableStateListOf<File>() }
    var errorText by remember { mutableStateOf<String?>(null) }

    val previewView = remember { PreviewView(context) }
    val recorder = remember {
        Recorder.Builder()
            // HD, not UHD: the export ladder tops out at 1080p, so recording 4K only burns
            // storage and transcode time to be downscaled moments later.
            .setQualitySelector(QualitySelector.from(Quality.HD))
            .build()
    }
    val videoCapture = remember { VideoCapture.withOutput(recorder) }

    val totalMs = bankedMs + liveMs
    val capMs = maxSeconds * 1000L

    // Audio is recorded only if the permission was actually granted. Asking CameraX for audio
    // without it throws at start; a clip with no sound beats a camera that refuses to record.
    val hasAudio = remember {
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    // (Re)bind whenever the lens flips. unbindAll first so use-cases don't stack.
    DisposableEffect(lensFront) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            val provider = providerFuture.get()
            val preview = Preview.Builder().build()
                .also { it.setSurfaceProvider(previewView.surfaceProvider) }
            val selector = if (lensFront) CameraSelector.DEFAULT_FRONT_CAMERA
                           else CameraSelector.DEFAULT_BACK_CAMERA
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(lifecycleOwner, selector, preview, videoCapture)
            }.onFailure { errorText = "Couldn't start the camera." }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            runCatching { ProcessCameraProvider.getInstance(context).get().unbindAll() }
        }
    }

    // Stop a recording still running when this screen goes away, or the file is left open and
    // the segment is unusable.
    DisposableEffect(Unit) {
        onDispose { runCatching { recording?.stop() } }
    }

    fun stopRecording() {
        recording?.stop()
        recording = null
    }

    fun startRecording() {
        if (totalMs >= capMs) return
        val target = File(context.cacheDir, "clip_seg_${System.currentTimeMillis()}.mp4")
        val opts = FileOutputOptions.Builder(target).build()
        runCatching {
            recording = recorder.prepareRecording(context, opts)
                .apply { if (hasAudio) withAudioEnabled() }
                .start(ContextCompat.getMainExecutor(context)) { event ->
                    when (event) {
                        is VideoRecordEvent.Status -> {
                            liveMs = event.recordingStats.recordedDurationNanos / 1_000_000
                            // The cap is enforced HERE rather than by a timer: this is the
                            // only signal tied to what was actually written to the file.
                            if (bankedMs + liveMs >= capMs) stopRecording()
                        }
                        is VideoRecordEvent.Finalize -> {
                            isRecording = false
                            val ok = !event.hasError() && target.length() > 0
                            if (ok) {
                                segments.add(target)
                                bankedMs += liveMs
                            } else {
                                runCatching { target.delete() }
                                errorText = "That take didn't record."
                            }
                            liveMs = 0
                        }
                        else -> Unit
                    }
                }
            isRecording = true
            errorText = null
        }.onFailure {
            isRecording = false
            errorText = "Couldn't start recording."
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())

        // ── Top bar ───────────────────────────────────────────────────────────────
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircleButton(Icons.Default.Close, "Close") {
                stopRecording()
                // Discard half-finished takes; nothing here has been handed to the composer.
                segments.forEach { runCatching { it.delete() } }
                onClose()
            }
            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
            if (totalMs > 0 || isRecording) {
                // Elapsed AND the cap, so a 90s clip does not stop at what looks like an
                // arbitrary moment with no warning it was coming.
                Text(
                    "%02d:%02d / %02d:%02d".format(
                        totalMs / 60000, (totalMs / 1000) % 60,
                        maxSeconds / 60, maxSeconds % 60,
                    ),
                    style = VoiidFont.rounded(15, FontWeight.SemiBold),
                    color = Color.White,
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(if (isRecording) VoiidColor.error else Color.Black.copy(alpha = 0.4f))
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
            CircleButton(Icons.Default.Cameraswitch, "Flip") {
                // Flipping mid-take would have to cut the segment; simply not offered while
                // recording, which is also what the iOS camera does.
                if (!isRecording) { haptics.tap(); lensFront = !lensFront }
            }
        }

        // Segment progress — one bar per take, so "how much have I got" is answerable at a
        // glance without doing arithmetic on a timer.
        if (segments.isNotEmpty() || isRecording) {
            Row(
                Modifier.fillMaxWidth().statusBarsPadding().padding(top = 72.dp, start = 16.dp, end = 16.dp)
                    .height(3.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Box(
                    Modifier
                        .fillMaxWidth((totalMs.toFloat() / capMs).coerceIn(0f, 1f))
                        .height(3.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(if (isRecording) VoiidColor.error else Color.White)
                )
            }
        }

        errorText?.let {
            Text(
                it,
                style = VoiidFont.rounded(13),
                color = Color.White,
                modifier = Modifier.align(Alignment.Center)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.Black.copy(alpha = 0.6f))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }

        // ── Bottom controls ───────────────────────────────────────────────────────
        Row(
            Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 32.dp)
                .fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            // Undo the last take. Present but inert while recording rather than vanishing,
            // so the row does not reflow under the user's thumb mid-take.
            Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                if (segments.isNotEmpty() && !isRecording) {
                    CircleButton(Icons.AutoMirrored.Filled.Undo, "Undo last take") {
                        haptics.tap()
                        val last = segments.removeAt(segments.lastIndex)
                        // Re-derive the banked total from what remains; subtracting the last
                        // measured duration would drift after a discarded take.
                        runCatching { last.delete() }
                        bankedMs = segments.sumOf { durationMsOf(context, it) }
                    }
                }
            }

            // Shutter: tap toggles. Nobody holds a finger down for 90 seconds.
            Box(
                Modifier.size(76.dp).clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.25f))
                    .softClickable(scale = 0.9f) {
                        haptics.tap()
                        if (isRecording) stopRecording() else startRecording()
                    },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier
                        .size(if (isRecording) 34.dp else 62.dp)
                        .clip(if (isRecording) RoundedCornerShape(8.dp) else CircleShape)
                        .background(if (isRecording) VoiidColor.error else Color.White)
                )
            }

            // Accept what has been recorded and hand the segments to the composer.
            Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                if (segments.isNotEmpty() && !isRecording) {
                    Box(
                        Modifier.size(48.dp).clip(CircleShape).background(VoiidColor.primary)
                            .softClickable(scale = 0.9f) {
                                haptics.tap()
                                onDone(segments.toList())
                            },
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Default.Check, "Use clip", tint = VoiidColor.textOnPrimary) }
                }
            }
        }
    }
}

@Composable
private fun CircleButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    Box(
        Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.35f))
            .softClickable(scale = 0.9f, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, label, tint = Color.White) }
}

/** Duration of a recorded segment, read back from the file itself. */
private fun durationMsOf(context: Context, file: File): Long =
    runCatching {
        android.media.MediaMetadataRetriever().use { mmr ->
            mmr.setDataSource(file.absolutePath)
            mmr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
        }
    }.getOrDefault(0L)
