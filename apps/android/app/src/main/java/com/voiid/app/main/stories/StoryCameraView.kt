package com.voiid.app.main.stories

import android.content.Context
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.voiid.app.ui.components.softClickable

/**
 * In-app camera (photo) for stories, built on CameraX — the app had NO camera stack before this
 * (no CameraX, no UIImagePickerController equivalent). Video capture stays on the gallery path for
 * v1; a still photo is the common case and keeps this to one screen with no recording state.
 *
 * The CAMERA permission is already requested at onboarding, so there is no permission plumbing
 * here — if it was denied the preview stays black and the user can fall back to the gallery.
 * Returns JPEG bytes via [onCaptured]; the composer then re-encodes/caps them.
 */
@Composable
fun StoryCameraView(
    onCaptured: (ByteArray) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var lensFront by remember { mutableStateOf(false) }
    val imageCapture = remember { ImageCapture.Builder().build() }
    val previewView = remember { PreviewView(context) }

    // (Re)bind whenever the lens flips. unbindAll first so the two use-cases don't stack.
    DisposableEffect(lensFront) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            val provider = providerFuture.get()
            val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
            val selector = if (lensFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(lifecycleOwner, selector, preview, imageCapture)
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            runCatching { ProcessCameraProvider.getInstance(context).get().unbindAll() }
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())

        // Close
        Box(
            Modifier.align(Alignment.TopStart).padding(16.dp).size(40.dp).clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.35f)).softClickable(scale = 0.9f) { onClose() },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Default.Close, "Close", tint = Color.White) }

        // Flip camera
        Box(
            Modifier.align(Alignment.TopEnd).padding(16.dp).size(40.dp).clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.35f)).softClickable(scale = 0.9f) { lensFront = !lensFront },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Default.Cameraswitch, "Flip", tint = Color.White) }

        // Shutter
        Box(
            Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 32.dp)
                .size(76.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.25f)),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier.size(60.dp).clip(CircleShape).background(Color.White)
                    .softClickable(scale = 0.88f) { capture(context, imageCapture, onCaptured) },
            )
        }
    }
}

/** Take a single frame and hand back JPEG bytes. */
private fun capture(context: Context, imageCapture: ImageCapture, onCaptured: (ByteArray) -> Unit) {
    imageCapture.takePicture(
        ContextCompat.getMainExecutor(context),
        object : ImageCapture.OnImageCapturedCallback() {
            override fun onCaptureSuccess(image: ImageProxy) {
                val bytes = image.use {
                    val buffer = it.planes[0].buffer
                    ByteArray(buffer.remaining()).also { arr -> buffer.get(arr) }
                }
                // CameraX JPEG capture already yields JPEG bytes in plane 0.
                onCaptured(bytes)
            }
            override fun onError(exception: ImageCaptureException) {
                android.util.Log.e("VOIID", "camera capture failed", exception)
            }
        },
    )
}
