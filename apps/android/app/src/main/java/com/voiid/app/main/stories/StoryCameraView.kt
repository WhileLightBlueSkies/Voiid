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
                    tickJob = scope.launch {
                        while (isRecording && recordSeconds < maxSeconds) {
                            delay(1000)
                            recordSeconds += 1
                            if (recordSeconds >= maxSeconds) activeRecording?.stop()
                        }
                    }
                }
                is VideoRecordEvent.Finalize -> {
                    isRecording = false
                    tickJob?.cancel()
                    activeRecording = null
                    if (!event.hasError()) {
                        onCaptured(null, event.outputResults.outputUri)
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
                    provider.bindToLifecycle(lifecycleOwner, selector, group.build())
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

    fun takePhoto() {
        // Filtered stills and the square selfie come from the preview frame; a plain photo
        // keeps ImageCapture's full sensor resolution.
        if (effectOn || selfie) {
            val bytes = runCatching {
                captureFilteredStill(previewView, faceDetector, faceEffect, squareCrop = selfie)
            }.getOrNull()
            if (bytes != null) onCaptured(bytes, null) else recordingError = "Couldn't take that photo."
        } else {
            capturePhoto(context, imageCapture) { bytes ->
                if (bytes != null) onCaptured(bytes, null)
                else recordingError = "Couldn't take that photo."
            }
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (cameraGranted) {
            AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
            FaceFilterOverlay(faceDetector, faceEffect)

            if (selfie) {
                Box(
                    Modifier.align(Alignment.TopCenter).padding(top = 150.dp)
                        .size(300.dp).clip(CircleShape)
                        .border(2.dp, Color.White.copy(alpha = 0.55f), CircleShape),
                )
            }

            Row(
                Modifier.align(Alignment.TopCenter).fillMaxWidth().statusBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TopCircle(onClick = onClose) { Icon(Icons.Default.Close, "Close", tint = Color.White) }
                Spacer(Modifier.weight(1f))
                TopCircle(active = showFilters, onClick = { showFilters = !showFilters }) {
                    Icon(
                        Icons.Default.Face,
                        if (showFilters) "Hide filters" else "Show filters",
                        tint = if (showFilters) Color.Black else Color.White,
                    )
                }
                TopCircle(onClick = { if (!isRecording) lensFront = !lensFront }) {
                    Icon(Icons.Default.Cameraswitch, "Flip", tint = Color.White)
                }
            }

            Column(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding()
                    .padding(bottom = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (isRecording) {
                    Text(
                        "%02d:%02d / %02d:%02d".format(recordSeconds / 60, recordSeconds % 60, maxSeconds / 60, maxSeconds % 60),
                        style = VoiidFont.rounded(15, FontWeight.SemiBold),
                        color = Color.White,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(VoiidColor.error)
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                    )
                } else if (showFilters) {
                    FaceLensRail(
                        selected = faceEffect,
                        onSelect = { effect ->
                            faceEffect = effect
                            faceDetector.activeEffect = effect
                            if (effect == ClipFaceEffect.NONE) faceDetector.reset()
                        },
                    )
                }
                Box(
                    Modifier.size(78.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.25f))
                        .border(4.dp, Color.White, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        Modifier.size(if (isRecording) 34.dp else 62.dp).clip(CircleShape)
                            .background(if (isRecording) VoiidColor.error else Color.White)
                            .shutterGestures(
                                holdEnabled = !photoOnly,
                                onTapPhoto = { if (!isRecording) takePhoto() },
                                onHoldStart = { startRecording() },
                                onHoldEnd = { stopRecording() },
                            ),
                    )
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
