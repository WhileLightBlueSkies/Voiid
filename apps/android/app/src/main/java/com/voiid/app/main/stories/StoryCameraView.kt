package com.voiid.app.main.stories

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
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
 *  - Capture failures are USER-VISIBLE alerts, never only logcat.
 *  - A denied CAMERA permission shows recovery actions instead of an unexplained black preview.
 */
@Composable
fun StoryCameraView(
    maxSeconds: Int = 30,
    onCaptured: (photo: ByteArray?, videoUri: Uri?) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    var lensFront by remember { mutableStateOf(false) }
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
    val previewView = remember { PreviewView(context) }

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

    DisposableEffect(lensFront, cameraGranted) {
        if (cameraGranted) {
            val providerFuture = ProcessCameraProvider.getInstance(context)
            providerFuture.addListener({
                val provider = providerFuture.get()
                val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
                val selector = if (lensFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
                runCatching {
                    provider.unbindAll()
                    provider.bindToLifecycle(lifecycleOwner, selector, preview, imageCapture, videoCapture)
                }.onFailure { recordingError = "Couldn't start the camera." }
            }, ContextCompat.getMainExecutor(context))
        }
        onDispose {
            runCatching { ProcessCameraProvider.getInstance(context).get().unbindAll() }
            stopRecording()
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (cameraGranted) {
            AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())

            Box(
                Modifier.align(Alignment.TopStart).padding(16.dp).size(40.dp).clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.35f)).softClickable(scale = 0.9f) { onClose() },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Default.Close, "Close", tint = Color.White) }

            Box(
                Modifier.align(Alignment.TopEnd).padding(16.dp).size(40.dp).clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.35f)).softClickable(scale = 0.9f) { lensFront = !lensFront },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Default.Cameraswitch, "Flip", tint = Color.White) }

            if (isRecording) {
                Text(
                    "%02d:%02d / %02d:%02d".format(recordSeconds / 60, recordSeconds % 60, maxSeconds / 60, maxSeconds % 60),
                    style = VoiidFont.rounded(15, FontWeight.SemiBold),
                    color = Color.White,
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(bottom = 120.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.error)
                        .padding(horizontal = 14.dp, vertical = 6.dp),
                )
            }

            Box(
                Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 32.dp)
                    .size(76.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.25f)),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(if (isRecording) 34.dp else 60.dp).clip(CircleShape)
                        .background(if (isRecording) VoiidColor.error else Color.White)
                        .shutterGestures(
                            onTapPhoto = {
                                capturePhoto(context, imageCapture) { bytes ->
                                    if (bytes != null) onCaptured(bytes, null)
                                    else recordingError = "Couldn't take that photo."
                                }
                            },
                            onHoldStart = { startRecording() },
                            onHoldEnd = { stopRecording() },
                        ),
                )
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
    imageCapture.takePicture(
        ContextCompat.getMainExecutor(context),
        object : ImageCapture.OnImageCapturedCallback() {
            override fun onCaptureSuccess(image: ImageProxy) {
                val bytes = image.use {
                    val buffer = it.planes[0].buffer
                    ByteArray(buffer.remaining()).also { arr -> buffer.get(arr) }
                }
                onResult(bytes)
            }
            override fun onError(exception: ImageCaptureException) {
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
    onTapPhoto: () -> Unit,
    onHoldStart: () -> Unit,
    onHoldEnd: () -> Unit,
): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val beganAt = System.currentTimeMillis()
        var recording = false
        while (true) {
            val event = awaitPointerEvent()
            val change = event.changes.firstOrNull { it.id == down.id } ?: break
            if (!recording && change.pressed && System.currentTimeMillis() - beganAt >= HOLD_THRESHOLD_MS) {
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
