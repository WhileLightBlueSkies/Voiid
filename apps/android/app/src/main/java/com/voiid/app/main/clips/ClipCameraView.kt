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
import androidx.camera.core.AspectRatio
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.ViewPort
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
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
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import kotlinx.coroutines.launch
import androidx.compose.material.icons.filled.GridOn
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Face
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
import androidx.compose.ui.graphics.drawscope.Stroke
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
import androidx.compose.ui.layout.onSizeChanged
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
import java.util.concurrent.Executors
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
    // Decode the filter art off the main thread, before the rail is tappable, so picking a
    // filter never blocks a frame on a PNG decode.
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { ClipFaceAssets.preload(context) }
    }
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
    var faceEffect by remember { mutableStateOf(ClipFaceEffect.NONE) }
    val faceDetector = remember { ClipFaceDetector() }
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    // Hardware control-plane state. `camera` is what carries zoom/torch/focus; it used to be
    // dropped on the floor at bind time, which is why none of them existed.
    var camera by remember { mutableStateOf<Camera?>(null) }
    var currentZoom by remember { mutableStateOf(1f) }
    var minZoom by remember { mutableStateOf(1f) }
    var maxZoom by remember { mutableStateOf(5f) }
    var torchOn by remember { mutableStateOf(false) }
    var focusPoint by remember { mutableStateOf<Offset?>(null) }

    LaunchedEffect(camera) {
        val cam = camera ?: return@LaunchedEffect
        cam.cameraInfo.zoomState.observe(lifecycleOwner) { state ->
            if (state != null) {
                currentZoom = state.zoomRatio
                minZoom = state.minZoomRatio
                maxZoom = state.maxZoomRatio
            }
        }
    }

    val zoomPresets = remember(minZoom, maxZoom, lensFront) {
        val list = mutableListOf<Float>()
        if (!lensFront && minZoom <= 0.7f) list.add(0.6f)
        list.add(1f)
        if (maxZoom >= 2f) list.add(2f)
        if (maxZoom >= 3f) list.add(3f)
        if (maxZoom >= 5f && list.size < 4) list.add(5f)
        list.filter { it in minZoom..maxZoom }
    }

    val previewView = remember {
        // COMPATIBLE, not the default PERFORMANCE: it backs the preview with a TextureView,
        // which is the only surface the live filter can be hung on (see the layer-paint note
        // below). A SurfaceView is composited by SurfaceFlinger, outside our draw pass, and
        // cannot be colour-filtered at all.
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
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
    // The clip's length, chosen under the shutter (15s / 30s / 60s / 2m). Defaults to the whole
    // allowance: the shorter lengths are a choice, not a limit to discover mid-take.
    var lengthSeconds by remember { mutableStateOf(maxSeconds) }
    val capMs = lengthSeconds * 1000L

    // Audio is recorded only if the permission was actually granted. Asking CameraX for audio
    // without it throws at start; a clip with no sound beats a camera that refuses to record.
    val hasAudio = remember {
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    // (Re)bind whenever the lens flips. unbindAll first so use-cases don't stack.
    DisposableEffect(lensFront) {
        currentZoom = 1f
        minZoom = 1f
        maxZoom = 1f
        faceDetector.isFrontCamera = lensFront
        previewView.post {
            faceDetector.viewWidth = previewView.width.toFloat()
            faceDetector.viewHeight = previewView.height.toFloat()
        }
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            val provider = providerFuture.get()
            // ImageAnalysis ONLY. Asking for a big analysis stream backfires twice over: the
            // detector pays for pixels ML Kit does not use, and because Preview + VideoCapture
            // + ImageAnalysis must resolve to a guaranteed stream combination, a greedy
            // analysis stream pushes the OTHER two down. Measured on an iQOO I2221: a shared
            // 1080x1920 CLOSEST_HIGHER selector produced analysis=3264x1836 and left the
            // preview at 720x1280, upscaled ~1.75x onto a 1260x2800 view.
            //
            // 1280x720 is landscape because ResolutionStrategy matches in sensor orientation.
            val analysisResSelector = ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                .setResolutionStrategy(
                    ResolutionStrategy(
                        android.util.Size(1280, 720),
                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER
                    )
                )
                .build()

            // 16:9 to MATCH the analysis stream, but no ResolutionStrategy — pinning an exact
            // size is what cost us the sharpness. The aspect ratios have to agree: the two
            // streams otherwise cover different fields of view, and the analysis -> preview
            // coordinate transform has no crop rect to reconcile them with, so every landmark
            // lands offset. (Measured: preview 3:4 + analysis 16:9 put the sprites up-left.)
            val previewResSelector = ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                .build()

            val preview = Preview.Builder()
                .setResolutionSelector(previewResSelector)
                .build()
                .also { it.setSurfaceProvider(previewView.surfaceProvider) }
            val selector = if (lensFront) CameraSelector.DEFAULT_FRONT_CAMERA
                           else CameraSelector.DEFAULT_BACK_CAMERA
            val imageAnalysis = ImageAnalysis.Builder()
                .setResolutionSelector(analysisResSelector)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                .build()
                .also { analysis ->
                    analysis.setAnalyzer(analysisExecutor) { imageProxy ->
                        if (faceDetector.activeEffect != ClipFaceEffect.NONE) {
                            faceDetector.analyze(imageProxy)
                        } else {
                            imageProxy.close()
                        }
                    }
                }
            runCatching {
                provider.unbindAll()

                // The ViewPort is what makes ImageAnalysis coordinates mean anything on the
                // preview. CoordinateTransform is only defined between use cases that share
                // one: without it each use case carries an unrelated crop rect and the matrix
                // it produces is garbage — which is exactly what we measured, a face box with
                // its width and height transposed by 720/1280.
                //
                // 9:16 explicitly rather than previewView.viewPort, which would take the
                // PreviewView's own 1260x2800 (0.45) aspect and crop the RECORDING to it.
                // Recording stays 16:9; the preview keeps cropping it for display, which the
                // PreviewView's own output transform already accounts for.
                val viewPort = ViewPort.Builder(
                    android.util.Rational(9, 16),
                    preview.targetRotation,
                ).setScaleType(ViewPort.FILL_CENTER).build()

                val useCaseGroup = UseCaseGroup.Builder()
                    .addUseCase(preview)
                    .addUseCase(videoCapture)
                    .addUseCase(imageAnalysis)
                    .setViewPort(viewPort)
                    .build()

                camera = provider.bindToLifecycle(lifecycleOwner, selector, useCaseGroup)
                previewView.post {
                    faceDetector.viewWidth = previewView.width.toFloat()
                    faceDetector.viewHeight = previewView.height.toFloat()
                }
            }.onFailure {
                errorText = "Couldn't start the camera."
            }
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
        onDispose {
            runCatching { recording?.stop() }
            runCatching { analysisExecutor.shutdown() }
            runCatching { faceDetector.close() }
        }
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
        val matrix = filter.colorMatrix()
        if (matrix != null) {
            texture.setLayerPaint(
                Paint().apply { colorFilter = ColorMatrixColorFilter(matrix) }
            )
        } else {
            texture.setLayerPaint(null)
        }
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

    // ── Recorder design (Voiid Ui, Chat/ClipRecorderScreen.swift; iOS ClipRecorderView) ──
    // The frame is the screen: tools in a column on the right, effects and upload bottom-left,
    // the shutter in the middle with the clip's progress on its ring, undo and next on the right.
    var lockedTake by remember { mutableStateOf(false) }
    var showSpeed by remember { mutableStateOf(false) }
    var showGrid by remember { mutableStateOf(false) }
    var timerSeconds by remember { mutableStateOf(0) }
    var countdown by remember { mutableStateOf<Int?>(null) }
    var showEffects by remember { mutableStateOf(false) }
    var effectsTab by remember { mutableStateOf(0) }   // 0 faces, 1 filters
    var filterThumbs by remember { mutableStateOf<Map<ClipFilter, Bitmap>>(emptyMap()) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var countdownJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    val lengths = remember(maxSeconds) { listOf(15, 30, 60, 120).filter { it <= maxSeconds } }

    LaunchedEffect(isRecording) { if (!isRecording) lockedTake = false }

    fun startCountdown() {
        countdownJob?.cancel()
        countdownJob = scope.launch {
            for (n in timerSeconds downTo 1) {
                countdown = n
                haptics.tap()
                delay(1000)
            }
            countdown = null
            timerSeconds = 0          // one take per countdown — the timer is for getting into shot
            lockedTake = true
            showSpeed = false
            startRecording()
        }
    }

    fun openEffects() {
        showEffects = true
        // The look thumbnails are YOUR shot in each look, taken from the live frame now.
        val frame = runCatching { previewView.bitmap }.getOrNull() ?: return
        scope.launch(Dispatchers.Default) {
            val scale = 160f / maxOf(frame.width, 1)
            val small = Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt().coerceAtLeast(1),
                (frame.height * scale).toInt().coerceAtLeast(1), true)
            val thumbs = ClipFilter.entries.associateWith { f ->
                val m = f.colorMatrix() ?: return@associateWith small
                val out = Bitmap.createBitmap(small.width, small.height, Bitmap.Config.ARGB_8888)
                android.graphics.Canvas(out).drawBitmap(small, 0f, 0f,
                    Paint().apply { colorFilter = ColorMatrixColorFilter(m) })
                out
            }
            withContext(Dispatchers.Main) { filterThumbs = thumbs }
        }
    }

    // The shutter's press handler outlives recompositions (it is suspended mid-press), so it
    // reads the live state and actions through these rather than capturing stale ones.
    val recordingNow by androidx.compose.runtime.rememberUpdatedState(isRecording)
    val startNow by androidx.compose.runtime.rememberUpdatedState { showSpeed = false; startRecording() }
    val stopNow by androidx.compose.runtime.rememberUpdatedState { stopRecording() }
    val timerNow by androidx.compose.runtime.rememberUpdatedState(timerSeconds)
    val fullNow by androidx.compose.runtime.rememberUpdatedState(totalMs >= capMs - 50)
    val countdownNow by androidx.compose.runtime.rememberUpdatedState(countdown)

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { previewView },
            modifier = Modifier
                .fillMaxSize()
                // The one authoritative source for the size landmarks are mapped into. It
                // fires on layout, before any face is published, so the detector is never
                // waiting on a Canvas that is itself waiting on a face.
                .onSizeChanged {
                    faceDetector.viewWidth = it.width.toFloat()
                    faceDetector.viewHeight = it.height.toFloat()
                }
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

        com.voiid.app.main.camera.FaceFilterOverlay(faceDetector, faceEffect)

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


        if (showGrid) {
            Canvas(Modifier.fillMaxSize()) {
                val c = Color.White.copy(alpha = 0.3f)
                for (i in 1..2) {
                    val x = size.width * i / 3f
                    val y = size.height * i / 3f
                    drawLine(c, Offset(x, 0f), Offset(x, size.height), strokeWidth = 1f)
                    drawLine(c, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
                }
            }
        }

        countdown?.let {
            Text("$it", style = VoiidFont.rounded(110, FontWeight.Bold), color = Color.White,
                modifier = Modifier.align(Alignment.Center))
        }

        // Filter name, flashed centre-screen on a swipe.
        if (filterLabelAlpha > 0.01f) {
            Text(filter.label, style = VoiidFont.rounded(28, FontWeight.Bold), color = Color.White,
                modifier = Modifier.align(Alignment.Center).alpha(filterLabelAlpha))
        }

        // ── Top: segment bar, close, timer ────────────────────────────────────────
        Column(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 14.dp, vertical = 8.dp)) {
            if (segments.isNotEmpty() || isRecording) {
                Row(Modifier.fillMaxWidth().height(3.dp)
                    .clip(RoundedCornerShape(VoiidRadius.pill)).background(Color.White.copy(alpha = 0.2f)),
                    horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                    segments.forEach { take -> SegmentTick(take.outputMs.toFloat() / capMs, Color.White) }
                    if (isRecording && liveOutputMs > 0) SegmentTick(liveOutputMs.toFloat() / capMs, VoiidColor.error)
                }
            } else {
                Spacer(Modifier.height(3.dp))
            }
            Spacer(Modifier.height(10.dp))
            Box(Modifier.fillMaxWidth()) {
                if (!isRecording) {
                    CircleButton(Icons.Default.Close, "Close") {
                        stopRecording()
                        segments.forEach { runCatching { it.file.delete() } }
                        onClose()
                    }
                }
                if (totalMs > 0 || isRecording) {
                    Row(Modifier.align(Alignment.Center).clip(RoundedCornerShape(VoiidRadius.pill))
                        .background(Color.Black.copy(alpha = 0.45f)).padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        if (isRecording) {
                            Box(Modifier.size(7.dp).clip(CircleShape).background(VoiidColor.error))
                            Spacer(Modifier.size(6.dp))
                        }
                        Text("%d:%02d / %d:%02d".format(totalMs / 60000, (totalMs / 1000) % 60,
                            lengthSeconds / 60, lengthSeconds % 60),
                            style = VoiidFont.rounded(14, FontWeight.SemiBold), color = Color.White)
                    }
                }
            }
        }

        errorText?.let {
            Text(it, style = VoiidFont.rounded(13), color = Color.White,
                modifier = Modifier.align(Alignment.Center).padding(top = 96.dp)
                    .clip(RoundedCornerShape(VoiidRadius.sm)).background(Color.Black.copy(alpha = 0.6f))
                    .padding(horizontal = 12.dp, vertical = 8.dp))
        }

        // ── Right: tool column. Fades out while recording so the shot is unobstructed. ──
        if (!isRecording && !showEffects) {
            Column(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(top = 70.dp, end = 12.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                ToolButton(Icons.Default.Cameraswitch, "Flip") { haptics.tap(); lensFront = !lensFront }
                if (camera?.cameraInfo?.hasFlashUnit() == true) {
                    ToolButton(if (torchOn) Icons.Default.FlashOn else Icons.Default.FlashOff, "Flash", active = torchOn) {
                        haptics.tap()
                        torchOn = !torchOn
                        runCatching { camera?.cameraControl?.enableTorch(torchOn) }
                    }
                }
                ToolText(if (speed == 1f) "1×" else speedLabel(speed), if (speed == 1f) "Speed" else speedLabel(speed),
                    active = speed != 1f || showSpeed) { haptics.tap(); showSpeed = !showSpeed }
                ToolButton(Icons.Default.Timer, if (timerSeconds == 0) "Timer" else "${timerSeconds}s", active = timerSeconds != 0) {
                    haptics.tap()
                    timerSeconds = when (timerSeconds) { 0 -> 3; 3 -> 10; else -> 0 }
                }
                ToolButton(Icons.Default.GridOn, "Grid", active = showGrid) { haptics.tap(); showGrid = !showGrid }
            }
        }

        // ── Bottom ────────────────────────────────────────────────────────────────
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                .background(androidx.compose.ui.graphics.Brush.verticalGradient(
                    listOf(Color.Transparent, Color.Black.copy(alpha = 0.55f))))
                .navigationBarsPadding().padding(top = 60.dp, bottom = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (showSpeed && !isRecording) {
                Row(Modifier.clip(RoundedCornerShape(VoiidRadius.pill)).background(Color.Black.copy(alpha = 0.5f)).padding(4.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    SPEEDS.forEach { s ->
                        val on = speed == s
                        Box(Modifier.size(width = 54.dp, height = 34.dp).clip(RoundedCornerShape(VoiidRadius.pill))
                            .background(if (on) Color.White else Color.Transparent)
                            .softClickable(scale = 0.94f) { haptics.selection(); speed = s },
                            contentAlignment = Alignment.Center) {
                            Text(speedLabel(s), style = VoiidFont.rounded(13, FontWeight.SemiBold),
                                color = if (on) Color.Black else Color.White)
                        }
                    }
                }
            }
            if (zoomPresets.size > 1 && !isRecording) {
                Row(Modifier.clip(RoundedCornerShape(VoiidRadius.pill)).background(Color.Black.copy(alpha = 0.25f))
                    .padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    val lit = zoomPresets.minByOrNull { abs(it - currentZoom) }
                    zoomPresets.forEach { preset ->
                        val on = preset == lit
                        Box(Modifier.size(42.dp).softClickable(scale = 0.92f) {
                            haptics.selection()
                            camera?.cameraControl?.setZoomRatio(preset.coerceIn(minZoom, maxZoom))
                        }, contentAlignment = Alignment.Center) {
                            Box(Modifier.size(if (on) 38.dp else 32.dp).clip(CircleShape)
                                .background(Color.Black.copy(alpha = if (on) 0.55f else 0.3f)), contentAlignment = Alignment.Center) {
                                val label = if (preset < 1f) ".${(preset * 10).roundToInt()}" else "${preset.toInt()}"
                                Text(if (on) "$label×" else label, style = VoiidFont.rounded(if (on) 12 else 11, FontWeight.Bold),
                                    color = if (on) VoiidColor.accent else Color.White)
                            }
                        }
                    }
                }
            }

            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterHorizontally)) {
                    if (!isRecording) {
                        val styled = faceEffect != ClipFaceEffect.NONE || filter != ClipFilter.NONE
                        SideButton(Icons.Default.Face, "Effects", highlight = styled) { haptics.tap(); openEffects() }
                        if (onPickGallery != null && segments.isEmpty()) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                GalleryButton(galleryThumb) { haptics.tap(); onPickGallery.invoke() }
                                Text("Upload", style = VoiidFont.rounded(10, FontWeight.SemiBold), color = Color.White,
                                    modifier = Modifier.padding(top = 4.dp))
                            }
                        }
                    }
                }

                // Shutter. Tap: a locked take that runs until the next tap. Hold: a take that
                // ends on release. Under a third of a second counts as a tap.
                val progress = (totalMs.toFloat() / capMs).coerceIn(0f, 1f)
                val ends = remember(segments.size) {
                    var sum = 0L; segments.map { sum += it.outputMs; sum.toFloat() / capMs }
                }
                Box(
                    Modifier.size(82.dp)
                        .alpha(if (totalMs >= capMs - 50 && !isRecording) 0.5f else 1f)
                        .pointerInput(Unit) {
                            detectTapGestures(onPress = {
                                if (countdownNow != null) {
                                    countdownJob?.cancel(); countdown = null
                                    tryAwaitRelease(); return@detectTapGestures
                                }
                                if (recordingNow) {
                                    haptics.tap(); stopNow()
                                    tryAwaitRelease(); return@detectTapGestures
                                }
                                if (fullNow) { tryAwaitRelease(); return@detectTapGestures }
                                if (timerNow > 0) {
                                    startCountdown()
                                    tryAwaitRelease(); return@detectTapGestures
                                }
                                val pressedAt = System.currentTimeMillis()
                                haptics.selection()
                                startNow()
                                tryAwaitRelease()
                                if (System.currentTimeMillis() - pressedAt < 350) lockedTake = true else stopNow()
                            })
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    val ringColor = if (isRecording) VoiidColor.error else VoiidColor.accent
                    Canvas(Modifier.fillMaxSize()) {
                        val stroke = 5.dp.toPx()
                        val inset = stroke / 2
                        val arcSize = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke)
                        drawArc(Color.White.copy(alpha = 0.35f), 0f, 360f, false,
                            topLeft = Offset(inset, inset), size = arcSize, style = Stroke(stroke))
                        drawArc(ringColor, -90f, 360f * progress, false,
                            topLeft = Offset(inset, inset), size = arcSize,
                            style = Stroke(stroke, cap = androidx.compose.ui.graphics.StrokeCap.Round))
                        // A notch at the end of each take.
                        ends.forEach { f ->
                            val angle = Math.toRadians((360.0 * f) - 90.0)
                            val r = size.width / 2 - inset
                            val c = Offset(size.width / 2, size.height / 2)
                            val p1 = Offset(c.x + (r - 5.dp.toPx()) * kotlin.math.cos(angle).toFloat(),
                                c.y + (r - 5.dp.toPx()) * kotlin.math.sin(angle).toFloat())
                            val p2 = Offset(c.x + (r + 5.dp.toPx()) * kotlin.math.cos(angle).toFloat(),
                                c.y + (r + 5.dp.toPx()) * kotlin.math.sin(angle).toFloat())
                            drawLine(Color.Black, p1, p2, strokeWidth = 3.dp.toPx())
                        }
                    }
                    Box(Modifier.size(if (isRecording) 32.dp else 62.dp)
                        .clip(if (isRecording) RoundedCornerShape(9.dp) else CircleShape)
                        .background(if (isRecording) VoiidColor.error else Color.White))
                }

                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically) {
                    if (segments.isNotEmpty() && !isRecording) {
                        SideButton(Icons.AutoMirrored.Filled.Undo, "Undo") {
                            haptics.tap()
                            val last = segments.removeAt(segments.lastIndex)
                            runCatching { last.file.delete() }
                            bankedMs = segments.sumOf { it.outputMs }
                        }
                        Box(Modifier.size(48.dp).clip(CircleShape).background(VoiidColor.accent)
                            .softClickable(scale = 0.9f) { haptics.success(); onDone(segments.toList(), filter) },
                            contentAlignment = Alignment.Center) {
                            Icon(Icons.Default.Check, "Next", tint = Color.White)
                        }
                    }
                }
            }

            if (segments.isEmpty() && !isRecording) {
                Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                    lengths.forEach { s ->
                        val on = lengthSeconds == s
                        Column(Modifier.softClickable(scale = 0.94f) { haptics.selection(); lengthSeconds = s }
                            .padding(horizontal = 4.dp, vertical = 2.dp),
                            horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(if (s >= 120) "2m" else "${s}s",
                                style = VoiidFont.rounded(13, if (on) FontWeight.Bold else FontWeight.Medium),
                                color = if (on) Color.White else Color.White.copy(alpha = 0.6f))
                            Spacer(Modifier.height(4.dp))
                            Box(Modifier.size(4.dp).clip(CircleShape).background(if (on) Color.White else Color.Transparent))
                        }
                    }
                }
            } else {
                Text(if (isRecording) (if (lockedTake) "Tap to stop" else "Release to stop") else "Hold or tap to add another take",
                    style = VoiidFont.rounded(12, FontWeight.Medium), color = Color.White.copy(alpha = 0.75f),
                    modifier = Modifier.height(30.dp))
            }
        }

        // ── Effects tray: faces and looks, chosen once per clip ────────────────────
        if (showEffects) {
            Box(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { showEffects = false } })
            Column(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .clip(RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp))
                    .background(Color(0xE6161A1C))
                    .navigationBarsPadding().padding(bottom = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Spacer(Modifier.height(8.dp))
                Box(Modifier.size(width = 36.dp, height = 4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.35f)))
                Row(Modifier.fillMaxWidth().padding(horizontal = 60.dp)) {
                    listOf("Faces", "Filters").forEachIndexed { i, title ->
                        Column(Modifier.weight(1f).softClickable(scale = 0.96f) { haptics.selection(); effectsTab = i },
                            horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(title, style = VoiidFont.rounded(14, FontWeight.SemiBold),
                                color = if (effectsTab == i) Color.White else Color.White.copy(alpha = 0.55f))
                            Spacer(Modifier.height(6.dp))
                            Box(Modifier.size(width = 24.dp, height = 2.5.dp).clip(CircleShape)
                                .background(if (effectsTab == i) Color.White else Color.Transparent))
                        }
                    }
                }
                LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp)) {
                    if (effectsTab == 0) {
                        items(ClipFaceEffect.entries.toList()) { f ->
                            EffectCell(f.label, selected = faceEffect == f, onClick = {
                                haptics.selection()
                                faceEffect = f
                                faceDetector.activeEffect = f
                                if (f == ClipFaceEffect.NONE) faceDetector.reset()
                            }) {
                                Text(if (f == ClipFaceEffect.NONE) "⊘" else f.icon, style = VoiidFont.rounded(28), color = Color.White)
                            }
                        }
                    } else {
                        items(ClipFilter.entries.toList()) { f ->
                            EffectCell(f.label, selected = filter == f, onClick = { haptics.selection(); filter = f }) {
                                val thumb = filterThumbs[f]
                                if (thumb != null) {
                                    androidx.compose.foundation.Image(thumb.asImageBitmap(), null,
                                        contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                                }
                            }
                        }
                    }
                }
                Box(Modifier.clip(RoundedCornerShape(VoiidRadius.pill)).background(Color.White)
                    .softClickable(scale = 0.95f) { haptics.tap(); showEffects = false }
                    .padding(horizontal = 28.dp, vertical = 11.dp)) {
                    Text("Done", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = Color.Black)
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

/** A tool in the right-hand column: a glass disc and its label. */
@Composable
private fun ToolButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    Column(Modifier.size(width = 56.dp, height = 62.dp).softClickable(scale = 0.9f, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(42.dp).clip(CircleShape).background(if (active) Color.White else Color.Black.copy(alpha = 0.35f)),
            contentAlignment = Alignment.Center) {
            Icon(icon, label, tint = if (active) Color.Black else Color.White, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.height(3.dp))
        Text(label, style = VoiidFont.rounded(10, FontWeight.SemiBold), color = Color.White)
    }
}

/** A tool whose glyph is text (the speed). */
@Composable
private fun ToolText(glyph: String, label: String, active: Boolean, onClick: () -> Unit) {
    Column(Modifier.size(width = 56.dp, height = 62.dp).softClickable(scale = 0.9f, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(42.dp).clip(CircleShape).background(if (active) Color.White else Color.Black.copy(alpha = 0.35f)),
            contentAlignment = Alignment.Center) {
            Text(glyph, style = VoiidFont.rounded(12, FontWeight.Bold), color = if (active) Color.Black else Color.White)
        }
        Spacer(Modifier.height(3.dp))
        Text(label, style = VoiidFont.rounded(10, FontWeight.SemiBold), color = Color.White)
    }
}

/** A control beside the shutter: glyph over label. */
@Composable
private fun SideButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    highlight: Boolean = false,
    onClick: () -> Unit,
) {
    Column(Modifier.softClickable(scale = 0.9f, onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(38.dp), contentAlignment = Alignment.Center) {
            Icon(icon, label, tint = if (highlight) VoiidColor.accent else Color.White, modifier = Modifier.size(22.dp))
        }
        Text(label, style = VoiidFont.rounded(10, FontWeight.SemiBold), color = Color.White)
    }
}

/** One round cell in the effects tray. */
@Composable
private fun EffectCell(label: String, selected: Boolean, onClick: () -> Unit, content: @Composable () -> Unit) {
    Column(Modifier.size(width = 68.dp, height = 86.dp).softClickable(scale = 0.94f, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(60.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f))
            .border(if (selected) 3.dp else 1.dp, if (selected) VoiidColor.accent else Color.White.copy(alpha = 0.25f), CircleShape),
            contentAlignment = Alignment.Center) { content() }
        Spacer(Modifier.height(6.dp))
        Text(label, style = VoiidFont.rounded(11, if (selected) FontWeight.Bold else FontWeight.Medium),
            color = Color.White.copy(alpha = if (selected) 1f else 0.8f), maxLines = 1)
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
