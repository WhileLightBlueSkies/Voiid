package com.voiid.app.main.clips

import android.Manifest
import android.annotation.SuppressLint
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.media.MediaMetadataRetriever
import android.os.Build
import android.provider.MediaStore
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FlashOff
import androidx.compose.material.icons.filled.FlashOn
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.roundToInt

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
    onDone: (List<ClipTake>, ClipFilter) -> Unit,
    onClose: () -> Unit,
    onPickGallery: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val haptics = LocalVoiidHaptics.current
    val density = LocalDensity.current

    var lensFront by remember { mutableStateOf(false) }
    var recording by remember { mutableStateOf<Recording?>(null) }
    var isRecording by remember { mutableStateOf(false) }
    /** Output milliseconds already banked in finished segments, plus the live one. */
    var bankedMs by remember { mutableStateOf(0L) }
    var liveMs by remember { mutableStateOf(0L) }
    // ClipTake, not File: each take carries its own measured duration and its own playback
    // rate, which ClipSegments.concatenate bakes in at export. Speed is stored rather than
    // applied at capture — re-timing between takes would mean a transcode mid-shoot and would
    // discard the original footage.
    val segments = remember { mutableStateListOf<ClipTake>() }

    // Library import while takes exist → confirm the discard, naming the count.
    var showReplaceTakes by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    // The rate the NEXT take will be recorded at. Never changes a take already on disk.
    var speed by remember { mutableStateOf(1f) }
    var filter by remember { mutableStateOf(ClipFilter.NONE) }
    // Hardware control-plane state. `camera` is what carries zoom/torch/focus; it used to be
    // dropped on the floor at bind time, which is why none of them existed.
    var camera by remember { mutableStateOf<Camera?>(null) }
    var torchOn by remember { mutableStateOf(false) }
    var focusPoint by remember { mutableStateOf<Offset?>(null) }

    val previewView = remember {
        // COMPATIBLE, not the default PERFORMANCE: it backs the preview with a TextureView,
        // which is the only surface the live filter can be hung on (see the layer-paint note
        // below). A SurfaceView is composited by SurfaceFlinger, outside our draw pass, and
        // cannot be colour-filtered at all.
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }
    }
    val recorder = remember {
        Recorder.Builder()
            // FHD, not HD. The export ladder skips any rung whose long edge exceeds the
            // source's (ClipExporter.encode), so a 1280-tall recording can never satisfy the
            // 1920 FHD rung: recording at HD silently capped every in-app clip at 720p while
            // gallery imports of the same scene published 1080p. UHD is still refused — the
            // ladder tops out at 1080p, so 4K would only burn storage and transcode time to be
            // downscaled moments later. The fallback keeps devices with no 1080p profile
            // bindable rather than failing to start the camera at all.
            .setQualitySelector(
                QualitySelector.from(
                    Quality.FHD,
                    FallbackStrategy.higherQualityOrLowerThan(Quality.HD),
                )
            )
            .build()
    }
    val videoCapture = remember { VideoCapture.withOutput(recorder) }

    // The live take counts against the cap at its OUTPUT length, same as a banked one: a 0.3x
    // take stretches to more than three times the seconds the shutter was open, and counting
    // wall-clock would sail past the backend's 90s limit and be rejected only at post.
    val liveOutputMs = if (speed <= 0f) liveMs else (liveMs / speed).toLong()
    val totalMs = bankedMs + liveOutputMs
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
                camera = provider.bindToLifecycle(
                    lifecycleOwner, selector, preview, videoCapture,
                )
            }.onFailure { errorText = "Couldn't start the camera." }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            camera = null
            // A rebind starts with the torch off; the button must not keep claiming it is lit.
            torchOn = false
            runCatching { ProcessCameraProvider.getInstance(context).get().unbindAll() }
        }
    }

    // Stop a recording still running when this screen goes away, or the file is left open and
    // the segment is unusable.
    DisposableEffect(Unit) {
        onDispose { runCatching { recording?.stop() } }
    }

    // ── Live filter ───────────────────────────────────────────────────────────────
    // The look is a ColorMatrixColorFilter on the preview TextureView's LAYER PAINT — the one
    // hook TextureView offers for tinting the stream it composites. Three consequences, all of
    // them the ones we want:
    //   * it is DISPLAY ONLY. The frames CameraX hands VideoCapture never see it, so recording
    //     stays clean and the filter is baked exactly once, at export, from the edit — no
    //     double-applied colour matrix and no destructive capture.
    //   * it reuses ClipFilter.colorMatrix() verbatim, so the viewfinder, the strip thumbnails
    //     and the exported video are one definition and cannot drift.
    //   * it needs no new dependency. The alternative — media3's Media3Effect CameraEffect —
    //     needs CameraX 1.4.x, and CameraX here is shared with the stories camera, so that
    //     upgrade is its own change with its own regression surface.
    // PreviewView creates its TextureView lazily when the stream starts, hence the hierarchy
    // listener rather than a one-shot lookup.
    var previewTexture by remember { mutableStateOf<TextureView?>(null) }
    DisposableEffect(previewView) {
        previewTexture = findTextureView(previewView)
        previewView.setOnHierarchyChangeListener(object : ViewGroup.OnHierarchyChangeListener {
            override fun onChildViewAdded(parent: View?, child: View?) {
                previewTexture = findTextureView(previewView)
            }

            override fun onChildViewRemoved(parent: View?, child: View?) {
                if (child === previewTexture) previewTexture = null
            }
        })
        onDispose { previewView.setOnHierarchyChangeListener(null) }
    }
    LaunchedEffect(previewTexture, filter) {
        val texture = previewTexture ?: return@LaunchedEffect
        // A bare Paint is the identity: alpha 255, no colour filter. Passing one for NONE
        // rather than null keeps the reset path identical to the apply path.
        texture.setLayerPaint(
            Paint().apply {
                filter.colorMatrix()?.let { colorFilter = ColorMatrixColorFilter(it) }
            }
        )
    }

    // The tapped point is drawn for a beat and then dropped — a focus ring that stays on
    // screen reads as a control rather than as confirmation.
    LaunchedEffect(focusPoint) {
        if (focusPoint != null) {
            delay(800)
            focusPoint = null
        }
    }

    // Flashed on a filter change and then faded: the look is the feedback, the name is only
    // needed for the moment you change it.
    var filterLabelAt by remember { mutableStateOf(0L) }
    var showFilterLabel by remember { mutableStateOf(false) }
    LaunchedEffect(filterLabelAt) {
        if (filterLabelAt == 0L) return@LaunchedEffect
        showFilterLabel = true
        delay(900)
        showFilterLabel = false
    }
    val filterLabelAlpha by animateFloatAsState(
        targetValue = if (showFilterLabel) 1f else 0f,
        label = "clipFilterLabel",
    )

    val galleryThumb = rememberLatestGalleryThumb(context, enabled = onPickGallery != null)

    fun stopRecording() {
        recording?.stop()
        recording = null
    }

    fun startRecording() {
        if (totalMs >= capMs) return
        val target = File(context.cacheDir, "clip_seg_${System.currentTimeMillis()}.mp4")
        val opts = FileOutputOptions.Builder(target).build()
        // Read once at start: the rail is inert mid-take, but a take must be banked with the
        // rate it was shot for even if the rail moves before Finalize arrives.
        val takeSpeed = speed
        runCatching {
            recording = recorder.prepareRecording(context, opts)
                .apply { if (hasAudio) withAudioEnabled() }
                .start(ContextCompat.getMainExecutor(context)) { event ->
                    when (event) {
                        is VideoRecordEvent.Status -> {
                            liveMs = event.recordingStats.recordedDurationNanos / 1_000_000
                            // The cap is enforced HERE rather than by a timer: this is the
                            // only signal tied to what was actually written to the file. It is
                            // measured in OUTPUT seconds, which is what the backend limits.
                            val out = if (takeSpeed <= 0f) liveMs else (liveMs / takeSpeed).toLong()
                            if (bankedMs + out >= capMs) stopRecording()
                        }
                        is VideoRecordEvent.Finalize -> {
                            isRecording = false
                            val ok = !event.hasError() && target.length() > 0
                            if (ok) {
                                // liveMs is CameraX's own recordingStats figure for this take —
                                // authoritative and already measured, so the take is banked
                                // without a MediaMetadataRetriever round-trip on the main thread.
                                segments.add(
                                    ClipTake(target, speed = takeSpeed, recordedMs = liveMs)
                                )
                                bankedMs = segments.sumOf { it.outputMs }
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
        AndroidView(
            factory = { previewView },
            modifier = Modifier
                .fillMaxSize()
                // Taps first in the chain, drags second: pointer events reach the LAST
                // pointerInput first, so the drag/pinch detector gets to consume and cancel a
                // tap that turned into a swipe, rather than both firing.
                .pointerInput(camera, isRecording) {
                    detectTapGestures(
                        onDoubleTap = {
                            // Flipping mid-take would have to cut the segment; not offered
                            // while recording, which is also what the iOS camera does.
                            if (!isRecording) {
                                haptics.tap()
                                lensFront = !lensFront
                            }
                        },
                        onTap = { offset ->
                            val control = camera?.cameraControl ?: return@detectTapGestures
                            val point = previewView.meteringPointFactory
                                .createPoint(offset.x, offset.y)
                            // Auto-cancel returns the sensor to continuous AF instead of
                            // leaving the frame locked on whatever was tapped minutes ago.
                            runCatching {
                                control.startFocusAndMetering(
                                    FocusMeteringAction.Builder(point)
                                        .setAutoCancelDuration(3, TimeUnit.SECONDS)
                                        .build()
                                )
                            }
                            focusPoint = offset
                        },
                    )
                }
                .pointerInput(camera) {
                    // Pinch and horizontal swipe share one gesture loop on purpose. Two
                    // separate detectors would race for the same stream — the transform
                    // detector consumes pans as well as pinches, so a filter swipe would be
                    // eaten before the drag detector ever saw it.
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        var totalDx = 0f
                        var pinching = false
                        var dragging = false
                        do {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.count { it.pressed }
                            if (pressed > 1) {
                                pinching = true
                                val zoomChange = event.calculateZoom()
                                if (zoomChange != 1f) {
                                    val state = camera?.cameraInfo?.zoomState?.value
                                    if (state != null) {
                                        runCatching {
                                            camera?.cameraControl?.setZoomRatio(
                                                (state.zoomRatio * zoomChange).coerceIn(
                                                    state.minZoomRatio, state.maxZoomRatio,
                                                )
                                            )
                                        }
                                    }
                                    event.changes.forEach { it.consume() }
                                }
                            } else if (pressed == 1 && !pinching) {
                                // first { pressed }, not first(): a two-finger gesture ending
                                // reports the lifted pointer in changes too, and reading its
                                // (zero) movement would stall the swipe.
                                totalDx += event.changes.first { it.pressed }.positionChange().x
                                if (!dragging && abs(totalDx) > viewConfiguration.touchSlop) {
                                    dragging = true
                                }
                                if (dragging) event.changes.forEach { it.consume() }
                            }
                        } while (event.changes.any { it.pressed })

                        if (dragging && !pinching) {
                            // A fraction of the screen, not a fixed pixel count: the same
                            // flick has to page on a 5" phone and on a tablet.
                            val threshold = size.width * 0.15f
                            val filters = ClipFilter.entries
                            val index = filters.indexOf(filter)
                            val next = when {
                                totalDx <= -threshold -> index + 1
                                totalDx >= threshold -> index - 1
                                else -> index
                            }.coerceIn(0, filters.lastIndex)
                            if (next != index) {
                                filter = filters[next]
                                filterLabelAt = System.currentTimeMillis()
                                haptics.tap()
                            }
                        }
                    }
                },
        )

        focusPoint?.let { point ->
            val ringPx = with(density) { 72.dp.toPx() }
            Box(
                Modifier
                    .offset {
                        IntOffset(
                            (point.x - ringPx / 2f).roundToInt(),
                            (point.y - ringPx / 2f).roundToInt(),
                        )
                    }
                    .size(72.dp)
                    .clip(CircleShape)
                    .border(1.5.dp, Color.White.copy(alpha = 0.9f), CircleShape)
            )
        }

        // ── Top bar ───────────────────────────────────────────────────────────────
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircleButton(Icons.Default.Close, "Close") {
                stopRecording()
                // Discard half-finished takes; nothing here has been handed to the composer.
                segments.forEach { runCatching { it.file.delete() } }
                onClose()
            }
            Spacer(Modifier.weight(1f))
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
                        .clip(RoundedCornerShape(VoiidRadius.pill))
                        .background(if (isRecording) VoiidColor.error else Color.Black.copy(alpha = 0.4f))
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
            Spacer(Modifier.weight(1f))
            // Torch only where there is a lamp: front cameras mostly have none, and an
            // always-present button that silently does nothing is worse than no button.
            if (camera?.cameraInfo?.hasFlashUnit() == true) {
                CircleButton(
                    if (torchOn) Icons.Default.FlashOn else Icons.Default.FlashOff,
                    if (torchOn) "Turn off the light" else "Turn on the light",
                    tint = if (torchOn) VoiidColor.accent else Color.White,
                ) {
                    haptics.tap()
                    torchOn = !torchOn
                    runCatching { camera?.cameraControl?.enableTorch(torchOn) }
                }
            }
            CircleButton(Icons.Default.Cameraswitch, "Flip") {
                if (!isRecording) { haptics.tap(); lensFront = !lensFront }
            }
        }

        // Segment progress — one tick per take, so "how much have I got, and what does undo
        // throw away" is answerable at a glance instead of by arithmetic on a timer. Each tick
        // is sized by the take's OUTPUT length, matching what the cap counts.
        if (segments.isNotEmpty() || isRecording) {
            Row(
                Modifier.fillMaxWidth().statusBarsPadding()
                    .padding(top = 72.dp, start = 16.dp, end = 16.dp)
                    .height(3.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                // Durations come from each ClipTake, already measured at capture — the old
                // single bar hid a MediaMetadataRetriever read per recomposition here, which
                // is a main-thread file read on every frame of a recording.
                segments.forEach { take ->
                    SegmentTick(take.outputMs.toFloat() / capMs, Color.White)
                }
                if (isRecording && liveOutputMs > 0) {
                    SegmentTick(liveOutputMs.toFloat() / capMs, VoiidColor.error)
                }
            }
        }

        // Filter name, flashed centre-screen on a swipe. Not a permanent label: the point of
        // a live filter is that you judge it by looking at the picture.
        if (filterLabelAlpha > 0.01f) {
            Text(
                filter.label,
                style = VoiidFont.rounded(28, FontWeight.Bold),
                color = Color.White,
                modifier = Modifier.align(Alignment.Center).alpha(filterLabelAlpha),
            )
        }

        errorText?.let {
            Text(
                it,
                style = VoiidFont.rounded(13),
                color = Color.White,
                modifier = Modifier.align(Alignment.Center)
                    .padding(top = 96.dp)
                    .clip(RoundedCornerShape(VoiidRadius.sm))
                    .background(Color.Black.copy(alpha = 0.6f))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }

        // ── Bottom controls ───────────────────────────────────────────────────────
        Column(
            Modifier.align(Alignment.BottomCenter).navigationBarsPadding()
                .padding(bottom = 32.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Speed rail. Recording always happens at 1x — the rate rides along with the take
            // and is applied at export (see ClipTake) — so this is free to change between
            // takes and costs nothing until the user commits.
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SPEEDS.forEach { option ->
                    val selected = option == speed
                    Box(
                        Modifier
                            .size(width = 52.dp, height = 44.dp)
                            .clip(RoundedCornerShape(VoiidRadius.pill))
                            .background(
                                if (selected) Color.White else Color.Black.copy(alpha = 0.35f)
                            )
                            // Present but inert mid-take rather than hidden, so the rail does
                            // not reflow under the user's thumb while they are shooting.
                            .alpha(if (isRecording) 0.4f else 1f)
                            .softClickable(scale = 0.92f, enabled = !isRecording) {
                                haptics.tap()
                                speed = option
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            speedLabel(option),
                            style = VoiidFont.rounded(13, FontWeight.SemiBold),
                            color = if (selected) Color.Black else Color.White,
                        )
                    }
                }
            }

            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                // Left slot: undo the last take once there is one, otherwise the way into the
                // gallery. Undo wins because it is the destructive-but-wanted action during a
                // shoot; importing is a decision made before the first take, not after it.
                Box(Modifier.size(56.dp), contentAlignment = Alignment.Center) {
                    when {
                        segments.isNotEmpty() && !isRecording -> {
                            CircleButton(Icons.AutoMirrored.Filled.Undo, "Undo last take") {
                                haptics.tap()
                                val last = segments.removeAt(segments.lastIndex)
                                runCatching { last.file.delete() }
                                // Re-derived from what remains rather than by subtracting the
                                // discarded take, which would drift.
                                bankedMs = segments.sumOf { it.outputMs }
                            }
                        }
                        onPickGallery != null && !isRecording -> {
                            GalleryButton(galleryThumb) {
                                haptics.tap()
                                // Unmerged takes are one tap away from being THROWN AWAY by a
                                // library import, so they get a say: iOS asks before
                                // replacing. With nothing banked, import straight through.
                                if (segments.isEmpty()) onPickGallery?.invoke()
                                else showReplaceTakes = true
                            }
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
                            .clip(if (isRecording) RoundedCornerShape(VoiidRadius.sm) else CircleShape)
                            .background(if (isRecording) VoiidColor.error else Color.White)
                    )
                }

                // Accept what has been recorded and hand the segments to the composer, with
                // the filter the author was actually looking at while they shot.
                Box(Modifier.size(56.dp), contentAlignment = Alignment.Center) {
                    if (segments.isNotEmpty() && !isRecording) {
                        Box(
                            Modifier.size(48.dp).clip(CircleShape).background(VoiidColor.primary)
                                .softClickable(scale = 0.9f) {
                                    haptics.tap()
                                    onDone(segments.toList(), filter)
                                },
                            contentAlignment = Alignment.Center,
                        ) { Icon(Icons.Default.Check, "Use clip", tint = VoiidColor.textOnPrimary) }
                    }
                }
            }
        }
    }

    if (showReplaceTakes) {
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { showReplaceTakes = false },
            title = "Import from gallery?",
            body = "This discards your ${segments.size} unmerged ${if (segments.size == 1) "take" else "takes"}.",
            confirmLabel = "Discard & pick",
            onConfirm = {
                showReplaceTakes = false
                onPickGallery?.invoke()
            },
            confirmDestructive = true,
        )
    }
}

/** The rates the record rail offers, matching iOS and Instagram's own set. */
private val SPEEDS = listOf(0.3f, 0.5f, 1f, 2f, 3f)

private fun speedLabel(speed: Float): String =
    if (speed % 1f == 0f) "${speed.toInt()}×" else "$speed×"

/**
 * One tick in the segment bar.
 *
 * The fraction has a floor rather than a `widthIn(min=)`: inside a Row, `fillMaxWidth(f)` fixes
 * the width exactly, so a minimum-width modifier could never widen a sliver back to something
 * you can see — and an invisible tick is exactly the anchor undo needs.
 */
@Composable
private fun SegmentTick(fraction: Float, color: Color) {
    Box(
        Modifier
            .fillMaxWidth(fraction.coerceIn(0.008f, 1f))
            .height(3.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(color)
    )
}

@Composable
private fun CircleButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    tint: Color = Color.White,
    onClick: () -> Unit,
) {
    Box(
        Modifier.size(44.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.35f))
            .softClickable(scale = 0.9f, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, label, tint = tint) }
}

/** The corner tile that opens the picker — a real thumbnail when we can read one. */
@Composable
private fun GalleryButton(thumb: Bitmap?, onClick: () -> Unit) {
    Box(
        Modifier
            .size(48.dp)
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(Color.Black.copy(alpha = 0.35f))
            .border(1.dp, Color.White.copy(alpha = 0.6f), RoundedCornerShape(VoiidRadius.md))
            .softClickable(scale = 0.9f, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (thumb != null) {
            androidx.compose.foundation.Image(
                bitmap = thumb.asImageBitmap(),
                contentDescription = "Choose a video",
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Icon(Icons.Default.PhotoLibrary, "Choose a video", tint = Color.White)
        }
    }
}

/**
 * The newest video in the gallery, for the corner tile — or null, which is fine.
 *
 * Best-effort by design. Reading it needs the media-read permission, which the photo picker
 * itself deliberately does NOT require, so when that permission is absent the tile falls back
 * to an icon rather than the app prompting for something it does not otherwise need.
 */
@Composable
private fun rememberLatestGalleryThumb(context: Context, enabled: Boolean): Bitmap? {
    var thumb by remember { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(enabled) {
        if (!enabled) return@LaunchedEffect
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_VIDEO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
        if (ContextCompat.checkSelfPermission(context, permission) !=
            PackageManager.PERMISSION_GRANTED
        ) return@LaunchedEffect

        thumb = withContext(Dispatchers.IO) { runCatching { latestVideoFrame(context) }.getOrNull() }
    }
    return thumb
}

private fun latestVideoFrame(context: Context): Bitmap? {
    val uri = context.contentResolver.query(
        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
        arrayOf(MediaStore.Video.Media._ID),
        null,
        null,
        "${MediaStore.Video.Media.DATE_ADDED} DESC LIMIT 1",
    )?.use { cursor ->
        if (cursor.moveToFirst()) {
            ContentUris.withAppendedId(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI, cursor.getLong(0),
            )
        } else null
    } ?: return null

    // MediaMetadataRetriever rather than ContentResolver.loadThumbnail, which is API 29+: the
    // level check would have to sit outside the coroutine that calls it, and lint cannot follow
    // a guard across that boundary — a NewApi error would fail every release build. try/finally
    // rather than use{} for the same reason: MMR only became AutoCloseable in 29.
    val retriever = MediaMetadataRetriever()
    return try {
        retriever.setDataSource(context, uri)
        val frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            ?: return null
        val edge = maxOf(frame.width, frame.height)
        if (edge <= THUMB_PX) {
            frame
        } else {
            val scale = THUMB_PX.toFloat() / edge
            Bitmap.createScaledBitmap(
                frame,
                (frame.width * scale).toInt().coerceAtLeast(1),
                (frame.height * scale).toInt().coerceAtLeast(1),
                true,
            )
        }
    } finally {
        retriever.release()
    }
}

/** Long edge of the viewfinder's gallery tile bitmap, in px. */
private const val THUMB_PX = 192

/** PreviewView builds its surface view lazily, so the search has to be by type, not index. */
private fun findTextureView(root: View): TextureView? {
    if (root is TextureView) return root
    if (root is ViewGroup) {
        for (i in 0 until root.childCount) {
            findTextureView(root.getChildAt(i))?.let { return it }
        }
    }
    return null
}
