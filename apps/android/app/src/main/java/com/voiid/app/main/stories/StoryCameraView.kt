@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.voiid.app.main.stories

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.ViewPort
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import android.view.OrientationEventListener
import androidx.camera.core.UseCase
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
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.ui.graphics.asImageBitmap
import com.voiid.app.main.clips.ClipFilter
import androidx.compose.material.icons.filled.GridOn
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.FlashOff
import androidx.compose.material.icons.filled.FlashOn
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.voiid.app.main.camera.FaceFilterOverlay
import com.voiid.app.main.camera.FaceLensRail
import com.voiid.app.main.camera.captureFilteredStill
import com.voiid.app.main.clips.ClipFaceAssets
import com.voiid.app.main.clips.ClipFaceDetector
import com.voiid.app.main.clips.ClipFaceEffect
import androidx.compose.material.icons.filled.Face
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.border
import androidx.compose.ui.draw.alpha
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.Executors
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

/**
 * In-app camera for Moments, built on CameraX. Port of iOS `StoryCameraView`:
 *
 *  - TAP captures a photo.
 *  - PRESS-AND-HOLD (≥300ms) records video — audio included when the mic grant exists — up to
 *    [maxSeconds], with an elapsed/cap timer so stopping never reads arbitrary; release stops early.
 *  - Recorded at H.264 720p via [QualitySelector], matching the iOS export target and keeping a
 *    full take well inside the upload caps without a re-encode pass.
 *  - Face filters (the clips set, same rail) on every presentation. A photo taken with a filter
 *    on comes from the preview frame with the sprites baked in (see captureFilteredStill), so
 *    what was on screen is what gets sent. Video records the clean stream — same as clips.
 *  - [photoOnly] (chat, profile photo) drops hold-to-record and the mic; [selfie] opens on the
 *    front lens and crops the still square around a framing guide.
 *  - Capture failures are USER-VISIBLE alerts, never only logcat.
 *  - A denied CAMERA permission shows recovery actions instead of an unexplained black preview.
 */
@Composable
fun StoryCameraView(
    maxSeconds: Int = 30,
    photoOnly: Boolean = false,
    selfie: Boolean = false,
    onCaptured: (photo: ByteArray?, videoUri: Uri?) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    var lensFront by remember { mutableStateOf(selfie) }
    var faceEffect by remember { mutableStateOf(ClipFaceEffect.NONE) }
    var showFilters by remember { mutableStateOf(true) }
    val faceDetector = remember { ClipFaceDetector() }
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    val effectOn = faceEffect != ClipFaceEffect.NONE
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { ClipFaceAssets.preload(context) }
    }
    val imageCapture = remember {
        ImageCapture.Builder().setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY).build()
    }
    val recorder = remember {
        Recorder.Builder()
            .setQualitySelector(
                QualitySelector.from(Quality.HD, FallbackStrategy.lowerQualityOrHigherThan(Quality.SD))
            )
            .build()
    }
    val videoCapture = remember { VideoCapture.Builder(recorder).build() }
    // COMPATIBLE (TextureView) so the preview has a readable bitmap for filtered stills.
    val previewView = remember {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }

    // Track the physical camera orientation even when the activity stays portrait-locked.
    DisposableEffect(imageCapture, videoCapture) {
        val listener = object : OrientationEventListener(context) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN) return
                val rotation = UseCase.snapToSurfaceRotation(orientation)
                imageCapture.targetRotation = rotation
                videoCapture.targetRotation = rotation
            }
        }
        listener.enable()
        onDispose { listener.disable() }
    }

    // ── Tools (Voiid Ui MomentCameraScreen; iOS StoryCameraView) ──
    var camera by remember { mutableStateOf<androidx.camera.core.Camera?>(null) }
    var currentZoom by remember { mutableStateOf(1f) }
    var minZoom by remember { mutableStateOf(1f) }
    var maxZoom by remember { mutableStateOf(1f) }
    var flashOn by remember { mutableStateOf(false) }
    var timerSeconds by remember { mutableIntStateOf(0) }
    var countdown by remember { mutableStateOf<Int?>(null) }
    var showGrid by remember { mutableStateOf(false) }
    var showEffects by remember { mutableStateOf(false) }
    var effectsTab by remember { mutableIntStateOf(0) }       // 0 faces, 1 filters
    var look by remember { mutableStateOf(ClipFilter.NONE) }
    var lookThumbs by remember { mutableStateOf<Map<ClipFilter, android.graphics.Bitmap>>(emptyMap()) }
    var processing by remember { mutableStateOf(false) }
    var recordMs by remember { mutableStateOf(0L) }

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
        list.filter { it in minZoom..maxZoom }
    }

    // The look is shown on the viewfinder only (the TextureView's layer paint), then baked into
    // the photo or video once it is taken — the same colour matrix either way.
    var previewTexture by remember { mutableStateOf<android.view.TextureView?>(null) }
    DisposableEffect(previewView) {
        previewTexture = com.voiid.app.main.clips.findTextureView(previewView)
        previewView.setOnHierarchyChangeListener(object : android.view.ViewGroup.OnHierarchyChangeListener {
            override fun onChildViewAdded(parent: android.view.View?, child: android.view.View?) {
                previewTexture = com.voiid.app.main.clips.findTextureView(previewView)
            }
            override fun onChildViewRemoved(parent: android.view.View?, child: android.view.View?) {
                if (child === previewTexture) previewTexture = null
            }
        })
        onDispose { previewView.setOnHierarchyChangeListener(null) }
    }
    LaunchedEffect(previewTexture, look) {
        val texture = previewTexture ?: return@LaunchedEffect
        texture.setLayerPaint(look.colorMatrix()?.let {
            android.graphics.Paint().apply { colorFilter = android.graphics.ColorMatrixColorFilter(it) }
        })
    }

    var isRecording by remember { mutableStateOf(false) }
    var recordSeconds by remember { mutableIntStateOf(0) }
    var activeRecording by remember { mutableStateOf<Recording?>(null) }
    var recordingError by remember { mutableStateOf<String?>(null) }

    val cameraGranted = ContextCompat.checkSelfPermission(
        context, Manifest.permission.CAMERA,
    ) == PackageManager.PERMISSION_GRANTED
    val micGranted = ContextCompat.checkSelfPermission(
        context, Manifest.permission.RECORD_AUDIO,
    ) == PackageManager.PERMISSION_GRANTED

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { grants ->
        if (grants.values.none { it }) {
            recordingError = "Voiid needs the camera to record a Moment."
        }
    }

    fun startRecording() {
        if (isRecording) return
        val file = File(context.cacheDir, "moment_${System.currentTimeMillis()}.mp4")
        val pending = recorder.prepareRecording(context, FileOutputOptions.Builder(file).build())
            .apply { if (micGranted) withAudioEnabled() }
        var tickJob: Job? = null
        val rec = pending.start(ContextCompat.getMainExecutor(context)) { event ->
            when (event) {
                is VideoRecordEvent.Start -> {
                    isRecording = true
                    recordSeconds = 0
                    recordMs = 0
                    val began = System.currentTimeMillis()
                    tickJob = scope.launch {
                        while (isRecording) {
                            delay(50)
                            recordMs = System.currentTimeMillis() - began
                            recordSeconds = (recordMs / 1000).toInt()
                            if (recordMs >= maxSeconds * 1000L) { activeRecording?.stop(); break }
                        }
                    }
                }
                is VideoRecordEvent.Finalize -> {
                    isRecording = false
                    tickJob?.cancel()
                    activeRecording = null
                    if (!event.hasError()) {
                        val uri = event.outputResults.outputUri
                        if (look == ClipFilter.NONE) onCaptured(null, uri)
                        else scope.launch {
                            processing = true
                            val baked = bakeLookIntoVideo(context, uri, look)
                            processing = false
                            if (baked != null) onCaptured(null, baked)
                            else recordingError = "Couldn't apply the filter to that video."
                        }
                    } else {
                        recordingError = "Recording failed. Please try again."
                    }
                }
                else -> {}
            }
        }
        activeRecording = rec
    }

    fun stopRecording() {
        if (isRecording) activeRecording?.stop()
    }

    // Rebound when the lens flips AND when a filter is switched on or off: with a filter the
    // camera needs a face-analysis stream, without one it needs full-resolution ImageCapture,
    // and asking for both plus video is past the stream combinations many phones guarantee.
    DisposableEffect(lensFront, cameraGranted, effectOn) {
        faceDetector.isFrontCamera = lensFront
        if (cameraGranted) {
            val providerFuture = ProcessCameraProvider.getInstance(context)
            providerFuture.addListener({
                val provider = providerFuture.get()
                // 16:9 on both streams so the analysis and preview cover the same field of
                // view — otherwise every landmark lands offset (see ClipCameraView).
                val ratio = ResolutionSelector.Builder()
                    .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                    .build()
                val analysisRes = ResolutionSelector.Builder()
                    .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            android.util.Size(1280, 720),
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                        )
                    )
                    .build()
                val preview = Preview.Builder().setResolutionSelector(ratio).build()
                    .also { it.setSurfaceProvider(previewView.surfaceProvider) }
                val selector = if (lensFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
                val group = UseCaseGroup.Builder().addUseCase(preview)
                if (effectOn) {
                    val analysis = ImageAnalysis.Builder()
                        .setResolutionSelector(analysisRes)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                        .build()
                        .also { a ->
                            a.setAnalyzer(analysisExecutor) { proxy ->
                                if (faceDetector.activeEffect != ClipFaceEffect.NONE) faceDetector.analyze(proxy)
                                else proxy.close()
                            }
                        }
                    group.addUseCase(analysis)
                } else {
                    group.addUseCase(imageCapture)
                }
                if (!photoOnly) group.addUseCase(videoCapture)
                group.setViewPort(
                    ViewPort.Builder(android.util.Rational(9, 16), preview.targetRotation)
                        .setScaleType(ViewPort.FILL_CENTER).build()
                )
                runCatching {
                    provider.unbindAll()
                    camera = provider.bindToLifecycle(lifecycleOwner, selector, group.build())
                    flashOn = false
                    previewView.post {
                        faceDetector.viewWidth = previewView.width.toFloat()
                        faceDetector.viewHeight = previewView.height.toFloat()
                    }
                }.onFailure { recordingError = "Couldn't start the camera." }
            }, ContextCompat.getMainExecutor(context))
        }
        onDispose {
            runCatching { ProcessCameraProvider.getInstance(context).get().unbindAll() }
            stopRecording()
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            runCatching { analysisExecutor.shutdown() }
            runCatching { faceDetector.close() }
        }
    }

    fun deliverPhoto(bytes: ByteArray?) {
        if (bytes == null) { recordingError = "Couldn't take that photo."; return }
        if (look == ClipFilter.NONE) { onCaptured(bytes, null); return }
        scope.launch {
            val baked = withContext(Dispatchers.Default) { runCatching { applyLookToJpeg(bytes, look) }.getOrNull() }
            onCaptured(baked ?: bytes, null)
        }
    }

    fun takePhoto() {
        // Filtered stills and the square selfie come from the preview frame; a plain photo
        // keeps ImageCapture's full sensor resolution.
        if (effectOn || selfie) {
            deliverPhoto(runCatching {
                captureFilteredStill(previewView, faceDetector, faceEffect, squareCrop = selfie)
            }.getOrNull())
        } else {
            imageCapture.flashMode = if (flashOn && !lensFront) ImageCapture.FLASH_MODE_ON else ImageCapture.FLASH_MODE_OFF
            capturePhoto(context, imageCapture) { bytes -> deliverPhoto(bytes) }
        }
    }

    fun shutterTap() {
        if (isRecording || processing) return
        if (countdown != null) return
        if (timerSeconds == 0) { takePhoto(); return }
        scope.launch {
            for (n in timerSeconds downTo 1) { countdown = n; delay(1000) }
            countdown = null
            takePhoto()
        }
    }

    fun openEffects() {
        showEffects = true
        val frame = runCatching { previewView.bitmap }.getOrNull() ?: return
        scope.launch(Dispatchers.Default) {
            val w = 160
            val small = android.graphics.Bitmap.createScaledBitmap(frame, w, (w.toFloat() * frame.height / frame.width).toInt().coerceAtLeast(1), true)
            val thumbs = ClipFilter.entries.associateWith { f ->
                val m = f.colorMatrix() ?: return@associateWith small
                val out = android.graphics.Bitmap.createBitmap(small.width, small.height, android.graphics.Bitmap.Config.ARGB_8888)
                android.graphics.Canvas(out).drawBitmap(small, 0f, 0f,
                    android.graphics.Paint().apply { colorFilter = android.graphics.ColorMatrixColorFilter(m) })
                out
            }
            withContext(Dispatchers.Main) { lookThumbs = thumbs }
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (cameraGranted) {
            AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
            FaceFilterOverlay(faceDetector, faceEffect)

            if (showGrid) {
                androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                    val c = Color.White.copy(alpha = 0.3f)
                    for (i in 1..2) {
                        drawLine(c, androidx.compose.ui.geometry.Offset(size.width * i / 3f, 0f),
                            androidx.compose.ui.geometry.Offset(size.width * i / 3f, size.height), 1f)
                        drawLine(c, androidx.compose.ui.geometry.Offset(0f, size.height * i / 3f),
                            androidx.compose.ui.geometry.Offset(size.width, size.height * i / 3f), 1f)
                    }
                }
            }

            if (selfie) {
                Box(
                    Modifier.align(Alignment.TopCenter).padding(top = 150.dp)
                        .size(300.dp).clip(CircleShape)
                        .border(2.dp, Color.White.copy(alpha = 0.55f), CircleShape),
                )
            }

            countdown?.let {
                Text("$it", style = VoiidFont.rounded(110, FontWeight.Bold), color = Color.White,
                    modifier = Modifier.align(Alignment.Center))
            }

            // ── Top: close, and the time while recording ──
            Box(Modifier.align(Alignment.TopCenter).fillMaxWidth().statusBarsPadding()
                .padding(horizontal = 14.dp, vertical = 8.dp)) {
                if (!isRecording) TopCircle(onClick = onClose) { Icon(Icons.Default.Close, "Close", tint = Color.White) }
                if (isRecording) {
                    Row(Modifier.align(Alignment.Center).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f))
                        .padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(7.dp).clip(CircleShape).background(VoiidColor.error))
                        Spacer(Modifier.size(6.dp))
                        Text("%d:%02d / %d:%02d".format(recordSeconds / 60, recordSeconds % 60, maxSeconds / 60, maxSeconds % 60),
                            style = VoiidFont.rounded(14, FontWeight.SemiBold), color = Color.White)
                    }
                }
            }

            // ── Right: tools ──
            if (!isRecording && !showEffects) {
                Column(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(top = 64.dp, end = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    CameraTool(Icons.Default.Cameraswitch, "Flip") { lensFront = !lensFront }
                    if (camera?.cameraInfo?.hasFlashUnit() == true) {
                        CameraTool(if (flashOn) Icons.Default.FlashOn else Icons.Default.FlashOff, "Flash", active = flashOn) {
                            flashOn = !flashOn
                            // The torch lights video and preview-frame stills; ImageCapture fires its own flash.
                            runCatching { camera?.cameraControl?.enableTorch(flashOn && (effectOn || !photoOnly)) }
                        }
                    }
                    CameraTool(Icons.Default.Timer, if (timerSeconds == 0) "Timer" else "${timerSeconds}s", active = timerSeconds != 0) {
                        timerSeconds = when (timerSeconds) { 0 -> 3; 3 -> 10; else -> 0 }
                    }
                    CameraTool(Icons.Default.GridOn, "Grid", active = showGrid) { showGrid = !showGrid }
                }
            }

            // ── Bottom: zoom, then effects · shutter ──
            if (!showEffects) Column(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.5f))))
                    .navigationBarsPadding().padding(top = 50.dp, bottom = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                if (zoomPresets.size > 1 && !isRecording) {
                    Row(Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.25f)).padding(horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        val lit = zoomPresets.minByOrNull { kotlin.math.abs(it - currentZoom) }
                        zoomPresets.forEach { preset ->
                            val on = preset == lit
                            Box(Modifier.size(42.dp).softClickable(scale = 0.92f) {
                                camera?.cameraControl?.setZoomRatio(preset.coerceIn(minZoom, maxZoom))
                            }, contentAlignment = Alignment.Center) {
                                Box(Modifier.size(if (on) 38.dp else 32.dp).clip(CircleShape)
                                    .background(Color.Black.copy(alpha = if (on) 0.55f else 0.3f)), contentAlignment = Alignment.Center) {
                                    val label = if (preset < 1f) ".${(preset * 10).toInt()}" else "${preset.toInt()}"
                                    Text(if (on) "$label×" else label, style = VoiidFont.rounded(if (on) 12 else 11, FontWeight.Bold),
                                        color = if (on) VoiidColor.accent else Color.White)
                                }
                            }
                        }
                    }
                }
                Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        if (!isRecording) {
                            val styled = faceEffect != ClipFaceEffect.NONE || look != ClipFilter.NONE
                            Column(Modifier.softClickable(scale = 0.9f) { openEffects() },
                                horizontalAlignment = Alignment.CenterHorizontally) {
                                Box(Modifier.size(44.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.35f)),
                                    contentAlignment = Alignment.Center) {
                                    Icon(Icons.Default.Face, "Effects", tint = if (styled) VoiidColor.accent else Color.White)
                                }
                                Text("Effects", style = VoiidFont.rounded(10, FontWeight.SemiBold), color = Color.White,
                                    modifier = Modifier.padding(top = 3.dp))
                            }
                        }
                    }
                    // Shutter: TAP for a photo, HOLD for a video — the ring fills to the limit.
                    val progress = if (maxSeconds > 0) (recordMs.toFloat() / (maxSeconds * 1000f)).coerceIn(0f, 1f) else 0f
                    Box(
                        Modifier.size(84.dp).shutterGestures(
                            holdEnabled = !photoOnly,
                            onTapPhoto = { shutterTap() },
                            onHoldStart = { if (!processing && countdown == null) startRecording() },
                            onHoldEnd = { stopRecording() },
                        ),
                        contentAlignment = Alignment.Center,
                    ) {
                        val ring = VoiidColor.error
                        androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                            val stroke = 5.dp.toPx()
                            val inset = stroke / 2
                            val arc = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke)
                            drawArc(Color.White, 0f, 360f, false, androidx.compose.ui.geometry.Offset(inset, inset), arc,
                                style = androidx.compose.ui.graphics.drawscope.Stroke(stroke))
                            if (isRecording) drawArc(ring, -90f, 360f * progress, false, androidx.compose.ui.geometry.Offset(inset, inset), arc,
                                style = androidx.compose.ui.graphics.drawscope.Stroke(stroke, cap = androidx.compose.ui.graphics.StrokeCap.Round))
                        }
                        Box(Modifier.size(if (isRecording) 32.dp else 66.dp)
                            .clip(if (isRecording) androidx.compose.foundation.shape.RoundedCornerShape(9.dp) else CircleShape)
                            .background(if (isRecording) VoiidColor.error else Color.White))
                    }
                    Spacer(Modifier.weight(1f))
                }
                Text(
                    when {
                        isRecording -> "Release to stop"
                        photoOnly -> "Tap to take a photo"
                        else -> "Tap for photo, hold for video"
                    },
                    style = VoiidFont.rounded(12, FontWeight.Medium), color = Color.White.copy(alpha = 0.75f),
                )
            }

            // ── Effects tray: faces and looks ──
            if (showEffects) {
                Box(Modifier.fillMaxSize().pointerInput(Unit) {
                    detectTapGestures { showEffects = false }
                })
                Column(
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                        .clip(androidx.compose.foundation.shape.RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp))
                        .background(Color(0xE6161A1C)).navigationBarsPadding().padding(bottom = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Spacer(Modifier.height(8.dp))
                    Box(Modifier.size(width = 36.dp, height = 4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.35f)))
                    Row(Modifier.fillMaxWidth().padding(horizontal = 60.dp)) {
                        listOf("Faces", "Filters").forEachIndexed { i, t ->
                            Column(Modifier.weight(1f).softClickable(scale = 0.96f) { effectsTab = i },
                                horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(t, style = VoiidFont.rounded(14, FontWeight.SemiBold),
                                    color = if (effectsTab == i) Color.White else Color.White.copy(alpha = 0.55f))
                                Spacer(Modifier.height(6.dp))
                                Box(Modifier.size(width = 24.dp, height = 2.5.dp).clip(CircleShape)
                                    .background(if (effectsTab == i) Color.White else Color.Transparent))
                            }
                        }
                    }
                    if (effectsTab == 0) {
                        FaceLensRail(
                            selected = faceEffect,
                            onSelect = { effect ->
                                faceEffect = effect
                                faceDetector.activeEffect = effect
                                if (effect == ClipFaceEffect.NONE) faceDetector.reset()
                            },
                        )
                    } else {
                        androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp)) {
                            items(ClipFilter.entries.size) { idx ->
                                val f = ClipFilter.entries[idx]
                                val on = look == f
                                Column(Modifier.softClickable(scale = 0.94f) { look = f },
                                    horizontalAlignment = Alignment.CenterHorizontally) {
                                    Box(Modifier.size(60.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f))
                                        .border(if (on) 3.dp else 1.dp, if (on) VoiidColor.accent else Color.White.copy(alpha = 0.25f), CircleShape)) {
                                        lookThumbs[f]?.let {
                                            androidx.compose.foundation.Image(it.asImageBitmap(), null,
                                                contentScale = androidx.compose.ui.layout.ContentScale.Crop, modifier = Modifier.fillMaxSize())
                                        }
                                    }
                                    Text(f.label, style = VoiidFont.rounded(11, if (on) FontWeight.Bold else FontWeight.Medium),
                                        color = Color.White.copy(alpha = if (on) 1f else 0.8f), modifier = Modifier.padding(top = 6.dp))
                                }
                            }
                        }
                    }
                    Box(Modifier.clip(CircleShape).background(Color.White).softClickable(scale = 0.95f) { showEffects = false }
                        .padding(horizontal = 28.dp, vertical = 11.dp)) {
                        Text("Done", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = Color.Black)
                    }
                }
            }

            if (processing) {
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f)), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        androidx.compose.material3.CircularProgressIndicator(color = Color.White)
                        Text("Applying the filter…", style = VoiidFont.rounded(14, FontWeight.Medium), color = Color.White)
                    }
                }
            }
        } else {
            PermissionDeniedRecovery(
                onRequest = { permissionLauncher.launch(arrayOf(Manifest.permission.CAMERA)) },
                onClose = onClose,
            )
        }
    }

    recordingError?.let { msg ->
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { recordingError = null },
            title = "Camera problem",
            body = msg,
            confirmLabel = "OK",
            onConfirm = { recordingError = null },
            cancelLabel = null,
        )
    }
}

/** Take a single frame and hand back JPEG bytes; failures surface as null, not silence. */
private fun capturePhoto(context: Context, imageCapture: ImageCapture, onResult: (ByteArray?) -> Unit) {
    // CameraX writes the crop and rotation into a JPEG file. Raw ImageProxy planes alone
    // omit imageInfo.rotationDegrees on some cameras, losing the capture orientation.
    val file = runCatching { File.createTempFile("moment_capture_", ".jpg", context.cacheDir) }.getOrNull()
        ?: return onResult(null)
    imageCapture.takePicture(
        ImageCapture.OutputFileOptions.Builder(file).build(),
        ContextCompat.getMainExecutor(context),
        object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                val bytes = try { runCatching { file.readBytes() }.getOrNull() } finally { file.delete() }
                onResult(bytes)
            }
            override fun onError(exception: ImageCaptureException) {
                file.delete()
                onResult(null)
            }
        },
    )
}

/**
 * Shutter gestures: release BEFORE the hold threshold is a photo TAP; holding past it starts
 * video and releasing stops it. Mirrors iOS `onTapGesture` + `onLongPressGesture(pressing:)`.
 */
private const val HOLD_THRESHOLD_MS = 300L

private fun Modifier.shutterGestures(
    holdEnabled: Boolean = true,
    onTapPhoto: () -> Unit,
    onHoldStart: () -> Unit,
    onHoldEnd: () -> Unit,
): Modifier = pointerInput(holdEnabled) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val beganAt = System.currentTimeMillis()
        var recording = false
        while (true) {
            val event = awaitPointerEvent()
            val change = event.changes.firstOrNull { it.id == down.id } ?: break
            if (holdEnabled && !recording && change.pressed && System.currentTimeMillis() - beganAt >= HOLD_THRESHOLD_MS) {
                recording = true
                onHoldStart()
            }
            if (!change.pressed) {
                if (recording) onHoldEnd() else onTapPhoto()
                break
            }
            change.consume()
        }
    }
}

/** Denied-camera state: explain, offer the system prompt again, or fall back to the gallery. */
@Composable
private fun PermissionDeniedRecovery(onRequest: () -> Unit, onClose: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
    ) {
        Text("Camera is off", style = VoiidFont.rounded(18, FontWeight.SemiBold), color = Color.White,
             textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(
            "Allow camera access to record a Moment, or pick one from your gallery instead.",
            style = VoiidFont.rounded(14),
            color = Color.White.copy(alpha = 0.75f),
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))
        Box(
            Modifier.clip(CircleShape).background(Color.White)
                .softClickable(scale = 0.94f) { onRequest() }
                .padding(horizontal = 24.dp, vertical = 10.dp),
        ) {
            Text("Allow camera access", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = Color.Black)
        }
        Spacer(Modifier.height(10.dp))
        Text(
            "Use gallery instead",
            style = VoiidFont.rounded(15, FontWeight.Medium),
            color = Color.White.copy(alpha = 0.85f),
            modifier = Modifier
                .softClickable(scale = 0.94f) { onClose() }
                .padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun TopCircle(active: Boolean = false, onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        Modifier.size(44.dp).clip(CircleShape)
            .background(if (active) Color.White else Color.Black.copy(alpha = 0.35f))
            .softClickable(scale = 0.9f) { onClick() },
        contentAlignment = Alignment.Center,
    ) { content() }
}

/** A tool in the right-hand column: a glass disc and its label. */
@Composable
private fun CameraTool(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    Column(Modifier.softClickable(scale = 0.9f, onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(42.dp).clip(CircleShape).background(if (active) Color.White else Color.Black.copy(alpha = 0.35f)),
            contentAlignment = Alignment.Center) {
            Icon(icon, label, tint = if (active) Color.Black else Color.White, modifier = Modifier.size(20.dp))
        }
        Text(label, style = VoiidFont.rounded(10, FontWeight.SemiBold), color = Color.White, modifier = Modifier.padding(top = 3.dp))
    }
}

/** The look drawn into a photo: upright (EXIF applied, since the re-encode drops it), then colour-matrixed. */
private fun applyLookToJpeg(bytes: ByteArray, look: ClipFilter): ByteArray {
    val matrix = look.colorMatrix() ?: return bytes
    val src = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return bytes
    val degrees = runCatching {
        when (android.media.ExifInterface(bytes.inputStream()).getAttributeInt(
            android.media.ExifInterface.TAG_ORIENTATION, android.media.ExifInterface.ORIENTATION_NORMAL)) {
            android.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            android.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            android.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
    }.getOrDefault(0f)
    val upright = if (degrees == 0f) src else android.graphics.Bitmap.createBitmap(
        src, 0, 0, src.width, src.height, android.graphics.Matrix().apply { postRotate(degrees) }, true)
    val out = android.graphics.Bitmap.createBitmap(upright.width, upright.height, android.graphics.Bitmap.Config.ARGB_8888)
    android.graphics.Canvas(out).drawBitmap(upright, 0f, 0f,
        android.graphics.Paint().apply { colorFilter = android.graphics.ColorMatrixColorFilter(matrix) })
    return java.io.ByteArrayOutputStream().use {
        out.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, it)
        it.toByteArray()
    }
}

/** Re-encode a recorded moment with the look burned in (the same Media3 effect the clip export uses). */
private suspend fun bakeLookIntoVideo(context: Context, source: Uri, look: ClipFilter): Uri? {
    val out = File(context.cacheDir, "moment_look_${System.currentTimeMillis()}.mp4")
    val edited = androidx.media3.transformer.EditedMediaItem.Builder(androidx.media3.common.MediaItem.fromUri(source))
        .setEffects(androidx.media3.transformer.Effects(com.google.common.collect.ImmutableList.of(),
            com.google.common.collect.ImmutableList.copyOf(look.effects())))
        .build()
    val ok = withContext(Dispatchers.Main) {
        kotlinx.coroutines.suspendCancellableCoroutine { cont ->
            val transformer = androidx.media3.transformer.Transformer.Builder(context)
                .setVideoMimeType(androidx.media3.common.MimeTypes.VIDEO_H264)
                .addListener(object : androidx.media3.transformer.Transformer.Listener {
                    override fun onCompleted(composition: androidx.media3.transformer.Composition,
                                             result: androidx.media3.transformer.ExportResult) {
                        if (cont.isActive) cont.resume(true) {}
                    }
                    override fun onError(composition: androidx.media3.transformer.Composition,
                                         result: androidx.media3.transformer.ExportResult,
                                         exception: androidx.media3.transformer.ExportException) {
                        android.util.Log.w("VOIID", "moment look bake failed: ${exception.message}")
                        if (cont.isActive) cont.resume(false) {}
                    }
                })
                .build()
            transformer.start(edited, out.absolutePath)
            cont.invokeOnCancellation {
                kotlinx.coroutines.CoroutineScope(Dispatchers.Main.immediate).launch { transformer.cancel() }
            }
        }
    }
    // The clean take is ours to drop once the baked copy exists.
    if (ok) runCatching { source.path?.let { File(it).delete() } }
    return if (ok && out.exists()) Uri.fromFile(out) else null
}
