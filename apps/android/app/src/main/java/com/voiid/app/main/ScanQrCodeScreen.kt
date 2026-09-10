package com.voiid.app.main

import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.reduceMotionEnabled
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import java.util.concurrent.Executors
import kotlin.math.min

/**
 * Scan someone's Voiid QR code — port of iOS `ScanQRCodeView`, confirmation sequence included.
 *
 * IT HANDS OFF RATHER THAN ACTS. A scan supplies a handle and nothing else: the PIN step and
 * the accept-a-request step both still happen, on the same screen typing the handle would
 * have reached. That is the whole reason the code does not contain the PIN — scanning is a
 * shortcut past the typing, not past the gates.
 *
 * WHY THERE IS A BEAT BEFORE THE HANDOFF. A scan is the one moment in this flow where the
 * phone knows something the person holding it does not yet: it read a code, and it is about
 * to change screens because of it. Cutting straight to the next screen makes that read
 * invisible and the navigation feel like a glitch. So the viewfinder locks, the card settles
 * in, the check draws itself, and only then does the handoff run — the same ~1.1s iOS spends,
 * and for the same reason.
 */
@Composable
fun ScanQrCodeScreen(onBack: () -> Unit, onScanned: (String) -> Unit,
                     onCommunityScanned: ((com.voiid.app.net.CommunityLink) -> Unit)? = null) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val haptics = LocalVoiidHaptics.current
    val reduceMotion = reduceMotionEnabled()

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
    LaunchedEffect(Unit) { if (!permission) launcher.launch(android.Manifest.permission.CAMERA) }

    // captured = a valid code is in hand and the viewfinder has stopped reading.
    // confirmed = the card is in and the check is drawing. Two flags, because the frame
    // locks BEFORE the confirmation settles — that gap is what makes the read feel seen.
    var captured by remember { mutableStateOf<String?>(null) }
    var confirmed by remember { mutableStateOf(false) }

    LaunchedEffect(captured) {
        val handle = captured ?: return@LaunchedEffect
        haptics.success()
        kotlinx.coroutines.delay(if (reduceMotion) 40 else 120)
        confirmed = true
        kotlinx.coroutines.delay(950)
        val community = com.voiid.app.net.CommunityLink.parse(android.net.Uri.parse(handle))
        if (community != null) onCommunityScanned?.invoke(community) else onScanned(handle)
    }

    BackupScaffold(title = "Scan code", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        Box(
            Modifier.fillMaxWidth().height(420.dp)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(Color.Black),
            contentAlignment = Alignment.Center,
        ) {
            if (permission) {
                CameraFeed(
                    scanning = captured == null,
                    lifecycleOwner = lifecycleOwner,
                    onDecoded = { handle ->
                        val community = com.voiid.app.net.CommunityLink.parse(android.net.Uri.parse(handle))
                        if (captured == null && (community == null || onCommunityScanned != null)) captured = handle
                    },
                )
                Viewfinder(captured = captured != null, confirmed = confirmed, reduceMotion = reduceMotion)
            } else {
                Text(
                    "Voiid needs the camera to scan a code.",
                    style = VoiidFont.rounded(14),
                    color = Color.White,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(24.dp),
                )
            }

            captured?.let { handle ->
                ConfirmationCard(handle = com.voiid.app.net.CommunityLink.parse(android.net.Uri.parse(handle))?.handle ?: handle, confirmed = confirmed, reduceMotion = reduceMotion, community = com.voiid.app.net.CommunityLink.parse(android.net.Uri.parse(handle)) != null)
            }
        }

        Spacer(Modifier.height(16.dp))
        if (captured == null) {
            Text(
                "Scan. Connect.",
                style = VoiidFont.rounded(25, FontWeight.Bold),
                color = VoiidColor.textPrimary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(6.dp))
            Text(
                "Scan a Voiid profile or community code",
                style = VoiidFont.rounded(14, FontWeight.Medium),
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp),
            )
        }
    }
}

/** Corner brackets plus the travelling read-line, both of which stop the moment a code lands. */
@Composable
private fun Viewfinder(captured: Boolean, confirmed: Boolean, reduceMotion: Boolean) {
    val scale by animateFloatAsState(
        targetValue = if (captured && !reduceMotion) 0.94f else 1f,
        animationSpec = spring(dampingRatio = 1f, stiffness = Spring.StiffnessMediumLow),
        label = "viewfinderScale",
    )
    val alpha by animateFloatAsState(
        targetValue = if (confirmed) 0f else 1f,
        animationSpec = tween(220),
        label = "viewfinderAlpha",
    )
    // The laser is the only thing on screen saying "this is live and looking". It stops on
    // capture, which is half of what makes the freeze read as a RESULT rather than a stall.
    val sweep by rememberInfiniteTransition(label = "laser").animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1600, easing = LinearEasing), RepeatMode.Reverse),
        label = "laserSweep",
    )
    val accent = VoiidColor.accentInk

    androidx.compose.foundation.Canvas(
        Modifier.size(240.dp).scale(scale).alpha(alpha),
    ) {
        val side = min(size.width, size.height)
        val arm = side * 0.18f
        val stroke = 3.dp.toPx()
        val color = if (captured) accent else Color.White
        // Four corners, drawn by rotating one L four times.
        repeat(4) { i ->
            rotate(degrees = 90f * i, pivot = center) {
                drawLine(color, Offset(0f, 0f), Offset(arm, 0f), stroke, StrokeCap.Round)
                drawLine(color, Offset(0f, 0f), Offset(0f, arm), stroke, StrokeCap.Round)
            }
        }
        if (!captured && !reduceMotion) {
            val y = side * sweep
            drawLine(
                Brush.horizontalGradient(
                    listOf(Color.Transparent, accent.copy(alpha = 0.9f), Color.Transparent),
                ),
                Offset(0f, y), Offset(side, y), stroke,
            )
        }
    }
}

/**
 * What the scan produced, as a card that settles in over the frozen frame.
 *
 * The ring expands and fades once as the check draws — one gesture, not a loop. A repeating
 * pulse here would say "working"; this moment is finished, and it should say so.
 */
@Composable
private fun ConfirmationCard(handle: String, confirmed: Boolean, reduceMotion: Boolean, community: Boolean = false) {
    val scale by animateFloatAsState(
        targetValue = if (confirmed || reduceMotion) 1f else 0.95f,
        animationSpec = spring(dampingRatio = 1f, stiffness = Spring.StiffnessMediumLow),
        label = "cardScale",
    )
    val alpha by animateFloatAsState(
        targetValue = if (confirmed) 1f else 0f,
        animationSpec = tween(220),
        label = "cardAlpha",
    )
    val ring by animateFloatAsState(
        targetValue = if (confirmed && !reduceMotion) 1.18f else 1f,
        animationSpec = tween(500),
        label = "ringScale",
    )
    val ringAlpha by animateFloatAsState(
        targetValue = if (confirmed) 0f else 1f,
        animationSpec = tween(500),
        label = "ringAlpha",
    )
    val check by animateFloatAsState(
        targetValue = if (confirmed) 1f else 0f,
        animationSpec = tween(durationMillis = if (reduceMotion) 0 else 250, delayMillis = if (reduceMotion) 0 else 80),
        label = "checkDraw",
    )

    val accent = VoiidColor.accent
    val accentInk = VoiidColor.accentInk

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp)
            .scale(scale).alpha(alpha)
            .clip(RoundedCornerShape(28.dp))
            .background(VoiidColor.surfaceCard)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.size(112.dp), contentAlignment = Alignment.Center) {
            androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                drawCircle(accentInk.copy(alpha = 0.2f * ringAlpha), radius = size.minDimension / 2f * ring,
                    style = Stroke(width = 1.dp.toPx()))
                drawCircle(accent.copy(alpha = 0.12f), radius = 56.dp.toPx())
                drawCircle(accent.copy(alpha = 0.16f), radius = 46.dp.toPx())
                drawCircle(accent, radius = 36.dp.toPx())
                // The checkmark DRAWS rather than appears — the stroke arriving is what reads
                // as "it worked", and a mark that simply pops in reads as a static icon.
                val w = 30.dp.toPx()
                val h = 23.dp.toPx()
                val p0 = Offset(center.x - w / 2f, center.y)
                val p1 = Offset(center.x - w * 0.12f, center.y + h / 2.6f)
                val p2 = Offset(center.x + w / 2f, center.y - h / 2.6f)
                val path = androidx.compose.ui.graphics.Path().apply {
                    moveTo(p0.x, p0.y); lineTo(p1.x, p1.y); lineTo(p2.x, p2.y)
                }
                val measure = androidx.compose.ui.graphics.PathMeasure().apply { setPath(path, false) }
                val drawn = androidx.compose.ui.graphics.Path()
                measure.getSegment(0f, measure.length * check, drawn, true)
                drawPath(drawn, Color.White,
                    style = Stroke(width = 4.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
        }

        Spacer(Modifier.height(14.dp))
        Text("Code scanned", style = VoiidFont.rounded(26, FontWeight.Bold), color = VoiidColor.textPrimary)
        Spacer(Modifier.height(6.dp))
        Text("You're one step closer.", style = VoiidFont.rounded(15, FontWeight.Medium),
            color = VoiidColor.textSecondary)

        Spacer(Modifier.height(24.dp))
        Row(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(VoiidColor.surfaceRaised)
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(46.dp).clip(RoundedCornerShape(15.dp))
                    .background(accent.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(handle.take(1).uppercase(), style = VoiidFont.rounded(19, FontWeight.Bold), color = accentInk)
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("@$handle", style = VoiidFont.rounded(17, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary, maxLines = 1)
                Text("Voiid profile code", style = VoiidFont.rounded(12, FontWeight.Medium),
                    color = VoiidColor.textSecondary)
            }
            Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = accentInk, modifier = Modifier.size(15.dp))
        }

        Spacer(Modifier.height(20.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Lock, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(12.dp))
            Spacer(Modifier.width(6.dp))
            Text(if (community) "Review the community before joining" else "Next, enter their Contact PIN", style = VoiidFont.rounded(12, FontWeight.Medium),
                color = VoiidColor.textSecondary)
        }
    }
}

@Composable
private fun CameraFeed(
    scanning: Boolean,
    lifecycleOwner: androidx.lifecycle.LifecycleOwner,
    onDecoded: (String) -> Unit,
) {
    val executor = remember { Executors.newSingleThreadExecutor() }
    DisposableEffect(Unit) { onDispose { executor.shutdown() } }
    // Read through a holder so the analyzer — bound once — always sees the CURRENT value
    // rather than the one captured when the camera was wired up.
    val live = remember { mutableStateOf(scanning) }
    live.value = scanning

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
                    if (live.value) {
                        decodeQr(proxy)?.let { text ->
                            (if (com.voiid.app.net.CommunityLink.parse(android.net.Uri.parse(text)) != null) text else ProfileLink.handleFrom(text))?.let { handle ->
                                android.os.Handler(android.os.Looper.getMainLooper()).post {
                                    onDecoded(handle)
                                }
                            }
                        }
                    }
                    proxy.close()
                }
                runCatching {
                    provider.unbindAll()
                    provider.bindToLifecycle(
                        lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis,
                    )
                }
            }, androidx.core.content.ContextCompat.getMainExecutor(ctx))
            view
        },
    )
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
