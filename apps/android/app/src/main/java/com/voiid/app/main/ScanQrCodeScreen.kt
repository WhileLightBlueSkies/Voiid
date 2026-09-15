package com.voiid.app.main

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FlashlightOff
import androidx.compose.material.icons.filled.FlashlightOn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.voiid.app.net.CommunityLink
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** A scan supplies identity only. Existing services own PIN/request and membership checks. */
@Composable
fun ScanQrCodeScreen(onBack: () -> Unit, onOpen: (String, Boolean) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val haptics = LocalVoiidHaptics.current
    var permission by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var active by remember { mutableStateOf(lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    var captured by remember { mutableStateOf<String?>(null) }
    var cameraError by remember { mutableStateOf<String?>(null) }
    var rejected by remember { mutableStateOf(false) }
    var camera by remember { mutableStateOf<Camera?>(null) }
    var torchOn by remember { mutableStateOf(false) }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { permission = it }
    LaunchedEffect(Unit) { if (!permission) permissionLauncher.launch(Manifest.permission.CAMERA) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, _ ->
            active = lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            if (active) permission = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            else torchOn = false
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(rejected) { if (rejected) { kotlinx.coroutines.delay(3000); rejected = false } }
    LaunchedEffect(camera, torchOn, active) {
        val current = camera ?: return@LaunchedEffect
        val future = current.cameraControl.enableTorch(torchOn && active)
        future.addListener({ runCatching { future.get() }.onFailure { torchOn = false } }, ContextCompat.getMainExecutor(context))
    }
    val reset: () -> Unit = { captured = null; torchOn = false; rejected = false; cameraError = null }
    captured?.let { raw ->
        val community = CommunityLink.parse(Uri.parse(raw))
        if (community != null) CommunityJoinSheet(link = community, onDismiss = onBack, onScanAgain = reset)
        else ProfileLink.handleFrom(raw)?.let { handle ->
            FindByUsernameScreen(onClose = onBack, prefilledHandle = handle, onScanAgain = reset, onOpen = onOpen)
        }
        return
    }
    QrPreviewPage("Scan QR", "Scan a Voiid profile or community code", onBack) {
        Box(Modifier.fillMaxWidth().heightIn(min = 280.dp, max = 440.dp).aspectRatio(0.78f)
            .clip(RoundedCornerShape(24.dp)).background(Color.Black).testTag("scan.viewfinder"), contentAlignment = Alignment.Center) {
            if (permission && cameraError == null) {
                CameraFeed(scanning = active && captured == null, onCamera = { camera = it },
                    onError = { cameraError = "Camera unavailable. Close the scanner and try again." },
                    onDecoded = { raw ->
                        if (captured == null && active) {
                            if (CommunityLink.parse(Uri.parse(raw)) != null || ProfileLink.handleFrom(raw) != null) {
                                torchOn = false; captured = raw; haptics.success()
                            } else if (!rejected) { rejected = true; haptics.error() }
                        }
                    })
                val accent = VoiidColor.primary
                Canvas(Modifier.fillMaxSize().padding(horizontal = 28.dp, vertical = 48.dp)) {
                    // Draw each corner without stretching the camera feed.
                    val arm = 30.dp.toPx()
                    val stroke = 4.dp.toPx()
                    val corners = listOf(Offset(0f,0f), Offset(size.width,0f), Offset(size.width,size.height), Offset(0f,size.height))
                    corners.forEachIndexed { i, p ->
                        val x = if (i == 0 || i == 3) arm else -arm
                        val y = if (i < 2) arm else -arm
                        drawLine(accent, p, p + Offset(x,0f), stroke, StrokeCap.Round)
                        drawLine(accent, p, p + Offset(0f,y), stroke, StrokeCap.Round)
                    }
                }
            } else Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(cameraError ?: "Camera access is off", color = Color.White, style = VoiidFont.rounded(18), textAlign = TextAlign.Center)
                if (!permission) QrAction("Open Settings") {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                }
            }
        }
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            IconButton(onClick = { torchOn = !torchOn }, enabled = permission && camera?.cameraInfo?.hasFlashUnit() == true,
                modifier = Modifier.size(56.dp).clip(CircleShape).background(VoiidColor.surfaceRaised).testTag("scan.flashlight")) {
                Icon(if (torchOn) Icons.Default.FlashlightOn else Icons.Default.FlashlightOff,
                    if (torchOn) "Turn flashlight off" else "Turn flashlight on", tint = VoiidColor.textPrimary)
            }
            Text(if (torchOn) "Flashlight on" else "Flashlight", color = VoiidColor.textSecondary, style = VoiidFont.rounded(13))
            if (rejected) Text("That isn’t a Voiid profile or community code. Try another.", color = VoiidColor.error,
                style = VoiidFont.rounded(13), textAlign = TextAlign.Center, modifier = Modifier.testTag("scan.invalidCode"))
        }
    }
}

@Composable
internal fun CameraFeed(scanning: Boolean, onCamera: (Camera?) -> Unit, onDecoded: (String) -> Unit, onError: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val view = remember(context) { PreviewView(context).apply { implementationMode = PreviewView.ImplementationMode.COMPATIBLE } }
    val live = remember { AtomicBoolean(scanning) }
    live.set(scanning)
    val decoded by rememberUpdatedState(onDecoded)
    val failed by rememberUpdatedState(onError)
    val ready by rememberUpdatedState(onCamera)
    DisposableEffect(view, owner) {
        val disposed = AtomicBoolean(false)
        val executor = Executors.newSingleThreadExecutor()
        val main = ContextCompat.getMainExecutor(context)
        val preview = androidx.camera.core.Preview.Builder().build().also { it.setSurfaceProvider(view.surfaceProvider) }
        val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
        var provider: ProcessCameraProvider? = null
        var boundCamera: Camera? = null
        analysis.setAnalyzer(executor) { proxy ->
            try {
                if (!disposed.get() && live.get()) decodeQr(proxy)?.let { raw ->
                    main.execute { if (!disposed.get() && live.get()) decoded(raw) }
                }
            } finally { proxy.close() }
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (!disposed.get()) runCatching {
                provider = future.get()
                boundCamera = provider!!.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                ready(boundCamera)
            }.onFailure { if (!disposed.get()) failed() }
        }, main)
        onDispose {
            disposed.set(true)
            live.set(false)
            analysis.clearAnalyzer()
            boundCamera?.cameraControl?.enableTorch(false)
            provider?.unbind(preview, analysis)
            ready(null)
            executor.shutdown()
        }
    }
    AndroidView(factory = { view }, modifier = Modifier.fillMaxSize())
}

private fun decodeQr(proxy: ImageProxy): String? = runCatching {
    val plane = proxy.planes[0]
    val bytes = packQrLuminance(plane.buffer, proxy.width, proxy.height, plane.rowStride, plane.pixelStride)
    val source = com.google.zxing.PlanarYUVLuminanceSource(bytes, proxy.width, proxy.height, 0, 0, proxy.width, proxy.height, false)
    com.google.zxing.qrcode.QRCodeReader().decode(com.google.zxing.BinaryBitmap(com.google.zxing.common.HybridBinarizer(source))).text
}.getOrNull()
