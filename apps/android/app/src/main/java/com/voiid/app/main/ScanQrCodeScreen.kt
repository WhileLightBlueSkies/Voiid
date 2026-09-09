package com.voiid.app.main

import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import java.util.concurrent.Executors

/**
 * Scan someone's Voiid QR code — port of iOS `ScanQRCodeView`.
 *
 * IT HANDS OFF RATHER THAN ACTS. A scan supplies a handle and nothing else: the PIN step and
 * the accept-a-request step both still happen, on the same screen typing the handle would
 * have reached. That is the whole reason the code does not contain the PIN — scanning is a
 * shortcut past the typing, not past the gates.
 *
 * Only `https://voiid.app/u/<handle>` is accepted, parsed by the same [ProfileLink] rules the
 * QR screen builds with. A QR encoding any other URL is ignored rather than followed, because
 * following an arbitrary scanned link is how a scanner becomes an attack surface.
 */
@Composable
fun ScanQrCodeScreen(onBack: () -> Unit, onScanned: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val haptics = com.voiid.app.ui.components.LocalVoiidHaptics.current

    var permission by remember {
        mutableStateOf(
            androidx.core.content.ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.CAMERA,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        )
    }
    val launcher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission(),
    ) { permission = it }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (!permission) launcher.launch(android.Manifest.permission.CAMERA)
    }

    // Latched so a code held in frame fires ONCE. Without it the analyzer reports the same
    // handle every frame and the handoff runs dozens of times.
    var handled by remember { mutableStateOf(false) }

    BackupScaffold(title = "Scan code", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        Box(
            Modifier.fillMaxWidth().height(420.dp)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(Color.Black),
            contentAlignment = Alignment.Center,
        ) {
            if (permission) {
                val executor = remember { Executors.newSingleThreadExecutor() }
                DisposableEffect(Unit) { onDispose { executor.shutdown() } }

                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx ->
                        val view = PreviewView(ctx)
                        val providerFuture = ProcessCameraProvider.getInstance(ctx)
                        providerFuture.addListener({
                            val provider = providerFuture.get()
                            val preview = androidx.camera.core.Preview.Builder().build()
                                .also { it.setSurfaceProvider(view.surfaceProvider) }
                            val analysis = ImageAnalysis.Builder()
                                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                .build()
                            analysis.setAnalyzer(executor) { proxy ->
                                if (!handled) {
                                    decodeQr(proxy)?.let { text ->
                                        ProfileLink.handleFrom(text)?.let { handle ->
                                            handled = true
                                            android.os.Handler(android.os.Looper.getMainLooper()).post {
                                                haptics.tap()
                                                onScanned(handle)
                                            }
                                        }
                                    }
                                }
                                proxy.close()
                            }
                            runCatching {
                                provider.unbindAll()
                                provider.bindToLifecycle(
                                    lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA,
                                    preview, analysis,
                                )
                            }
                        }, androidx.core.content.ContextCompat.getMainExecutor(ctx))
                        view
                    },
                )
            } else {
                Text(
                    "Voiid needs the camera to scan a code.",
                    style = VoiidFont.rounded(14),
                    color = Color.White,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(24.dp),
                )
            }
        }

        Spacer(Modifier.height(16.dp))
        Text(
            "Point at someone's Voiid QR code. You'll still need their contact PIN, and they " +
                "choose whether to accept.",
            style = VoiidFont.rounded(13),
            color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp),
        )
    }
}

/** One frame → QR text, or null. Luminance plane only; ZXing needs nothing else. */
private fun decodeQr(proxy: ImageProxy): String? {
    val buffer = proxy.planes[0].buffer
    val bytes = ByteArray(buffer.remaining()).also { buffer.get(it) }
    val source = com.google.zxing.PlanarYUVLuminanceSource(
        bytes, proxy.width, proxy.height, 0, 0, proxy.width, proxy.height, false,
    )
    val bitmap = com.google.zxing.BinaryBitmap(com.google.zxing.common.HybridBinarizer(source))
    return runCatching { com.google.zxing.qrcode.QRCodeReader().decode(bitmap).text }.getOrNull()
}
