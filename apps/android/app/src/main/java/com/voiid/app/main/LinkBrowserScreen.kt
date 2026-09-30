package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.filled.Lock
import com.voiid.app.ui.components.softClickable
import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.voiid.app.net.DeviceDirectoryService
import com.voiid.app.net.LinkBrowserCode
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.pressableClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Settings → Linked Devices → Link a Browser. Twin of iOS `LinkBrowserView.swift`.
 *
 * Three stages, same as iOS: scan Voiid Web's QR → preview (device name + a verification code
 * the user checks against their screen) → confirm, gated on unlocking the phone.
 *
 * SCANNING GRANTS NOTHING. Only a well-formed `voiid://link?token=…` payload is accepted
 * ([LinkBrowserCode]); anything else is refused without a network call. Approval pins the
 * identity key the user was shown in the preview, and requires the device owner (biometric or
 * screen lock) — someone holding an unlocked-then-set-down phone cannot link their browser.
 */
@Composable
fun LinkBrowserScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val lifecycleOwner = LocalLifecycleOwner.current
    val service = remember { DeviceDirectoryService(context) }

    var cameraAllowed by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var resumed by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var scannedToken by remember { mutableStateOf<String?>(null) }
    var preview by remember { mutableStateOf<DeviceDirectoryService.LinkPreview?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var linked by remember { mutableStateOf(false) }
    var operation by remember { mutableStateOf<Job?>(null) }

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        cameraAllowed = it
        if (!it) error = "Allow camera access in Settings to scan your browser’s code."
    }
    // Pre-Android 10 fallback for the owner check: the system confirm-credential screen.
    var keyguardResult by remember { mutableStateOf<((Boolean) -> Unit)?>(null) }
    val keyguardLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        keyguardResult?.invoke(it.resultCode == Activity.RESULT_OK); keyguardResult = null
    }

    LaunchedEffect(Unit) { if (!cameraAllowed) permissionLauncher.launch(Manifest.permission.CAMERA) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, _ ->
            resumed = lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            if (resumed) cameraAllowed = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer); operation?.cancel() }
    }

    fun reset() { operation?.cancel(); scannedToken = null; preview = null; error = null; busy = false }

    fun scan(raw: String) {
        if (busy || preview != null || error != null) return
        val token = LinkBrowserCode.token(raw) ?: run {
            haptics.error()
            error = "This is not a Voiid Web linking code. Scan the code shown on your computer."
            return
        }
        busy = true
        operation = scope.launch {
            try {
                val result = service.preview(token)
                if (result.platform != "web") return@launch
                haptics.success()
                scannedToken = token; preview = result
            } catch (e: Exception) {
                error = "Couldn’t check this code. It may have expired. Scan a fresh code from your browser."
            } finally { busy = false }
        }
    }

    fun approve() {
        val token = scannedToken ?: return
        val shown = preview ?: return
        if (busy) return
        busy = true; error = null
        operation = scope.launch {
            try {
                val owner = confirmDeviceOwner(context, "Link this browser to send and receive Voiid messages.") { intent, done ->
                    keyguardResult = done; keyguardLauncher.launch(intent)
                }
                when (owner) {
                    OwnerCheck.CANCELLED -> return@launch
                    OwnerCheck.FAILED -> {
                        error = "Linking wasn’t completed. Unlock your phone and try again. If this code expired, scan a fresh one."
                        return@launch
                    }
                    OwnerCheck.CONFIRMED -> Unit
                }
                service.approve(token, shown.identity_public_key)
                haptics.success()
                linked = true
            } catch (e: Exception) {
                haptics.error()
                error = "Linking wasn’t completed. Unlock your phone and try again. If this code expired, scan a fresh one."
            } finally { busy = false }
        }
    }

    // Design reference: Voiid Ui/Chat/LinkedDevicesScreen.swift (LinkBrowserSheet).
    BackHandler { if (!(busy && preview != null)) onClose() }
    Column(
        Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding().navigationBarsPadding(),
    ) {
        Box(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 16.dp)) {
            Text(
                "Cancel", style = VoiidFont.rounded(17), color = VoiidColor.accentInk.copy(alpha = if (busy && preview != null) 0.4f else 1f),
                modifier = Modifier.align(Alignment.CenterStart)
                    .softClickable(enabled = !(busy && preview != null)) { operation?.cancel(); onClose() },
            )
        }
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            val current = preview
            when {
                linked -> {
                    Spacer(Modifier.height(24.dp))
                    Icon(Icons.Filled.VerifiedUser, null, tint = VoiidColor.accentInk, modifier = Modifier.size(56.dp))
                    Title("Browser Linked", "You can remove its access at any time in Linked Devices.")
                    PrimaryPill("Done", modifier = Modifier.fillMaxWidth(), onClick = onClose)
                }
                current != null -> {
                    Spacer(Modifier.height(12.dp))
                    Box(
                        Modifier.size(84.dp).clip(RoundedCornerShape(22.dp)).background(VoiidColor.accentTint),
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Filled.Laptop, null, tint = VoiidColor.accentInk, modifier = Modifier.size(40.dp)) }
                    Title("Link ${current.device_name}?", "Check this code matches the one on your computer.")
                    Text(
                        current.verification_code,
                        style = VoiidFont.rounded(40, FontWeight.SemiBold).copy(fontFamily = FontFamily.Monospace),
                        color = VoiidColor.textPrimary,
                        maxLines = 1,
                        modifier = Modifier.clip(RoundedCornerShape(18.dp)).background(VoiidColor.surfaceCard)
                            .padding(horizontal = 24.dp, vertical = 16.dp)
                            .semantics { contentDescription = "Verification code: ${current.verification_code.toList().joinToString(" ")}" },
                    )
                    Text(
                        "This browser will be able to send and receive messages as you. If the codes don't match, or someone sent you this code, cancel.",
                        style = VoiidFont.rounded(13), color = VoiidColor.textSecondary, textAlign = TextAlign.Center,
                    )
                    error?.let { Text(it, style = VoiidFont.rounded(15), color = VoiidColor.error, textAlign = TextAlign.Center) }
                    PrimaryPill(if (busy) "Confirming…" else "Codes Match — Link", modifier = Modifier.fillMaxWidth(), enabled = !busy, onClick = ::approve)
                    Text("Scan a Different Code", style = VoiidFont.rounded(15), color = VoiidColor.accentInk,
                        modifier = Modifier.softClickable(enabled = !busy, onClick = ::reset))
                }
                else -> {
                    Title("Link a Browser", "Open Voiid Web on your computer and scan the QR code it shows.")
                    Box(
                        Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(28.dp)).background(Color.Black)
                            .semantics { contentDescription = "Camera for scanning a Voiid Web QR code" },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (cameraAllowed) {
                            CameraFeed(
                                scanning = resumed && !busy && error == null,
                                onCamera = {},
                                onDecoded = ::scan,
                                onError = { error = "Camera unavailable. Check camera access in Settings and try again." },
                            )
                            ScanCorners(VoiidColor.primary, Modifier.fillMaxSize().padding(28.dp))
                            if (busy) Row(
                                Modifier.clip(RoundedCornerShape(14.dp)).background(Color.Black.copy(alpha = 0.55f)).padding(14.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                                Text("Checking browser…", style = VoiidFont.rounded(15), color = Color.White)
                            }
                        } else {
                            Icon(Icons.Filled.QrCodeScanner, null, tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(34.dp))
                        }
                    }
                    error?.let { message ->
                        Text(message, style = VoiidFont.rounded(15), color = VoiidColor.error, textAlign = TextAlign.Center)
                        Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                            Text("Try Again", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.accentInk,
                                modifier = Modifier.softClickable {
                                    reset()
                                    if (!cameraAllowed) permissionLauncher.launch(Manifest.permission.CAMERA)
                                })
                            Text("Open Settings", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.accentInk,
                                modifier = Modifier.softClickable {
                                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                                })
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.Lock, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(13.dp))
                        Text("Only link computers you own", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                    }
                    Text("Scanning does not grant access. You will confirm the browser on the next screen.",
                        style = VoiidFont.rounded(13), color = VoiidColor.textSecondary, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

@Composable
private fun Title(title: String, subtitle: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary, textAlign = TextAlign.Center)
        Text(subtitle, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary, textAlign = TextAlign.Center)
    }
}

/** Four corner brackets — the iOS scanner's `ScanBrackets`, drawn once. */
@Composable
private fun ScanCorners(color: Color, modifier: Modifier) {
    androidx.compose.foundation.Canvas(modifier) {
        val arm = 34.dp.toPx(); val w = 4.dp.toPx()
        val stroke = androidx.compose.ui.graphics.drawscope.Stroke(width = w, cap = androidx.compose.ui.graphics.StrokeCap.Round)
        fun corner(x: Float, y: Float, dx: Float, dy: Float) {
            val path = androidx.compose.ui.graphics.Path().apply {
                moveTo(x, y + dy * arm); lineTo(x, y); lineTo(x + dx * arm, y)
            }
            drawPath(path, color, style = stroke)
        }
        corner(0f, 0f, 1f, 1f); corner(size.width, 0f, -1f, 1f)
        corner(0f, size.height, 1f, -1f); corner(size.width, size.height, -1f, -1f)
    }
}

@Composable
private fun PrimaryAction(title: String, busy: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp))
            .background(VoiidColor.primary.copy(alpha = if (busy) 0.6f else 1f))
            .pressableClickable(enabled = !busy, onClick = onClick),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (busy) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
        Text(title, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = Color.White)
    }
}

// ── Device-owner check ────────────────────────────────────────────────────────────────

private enum class OwnerCheck { CONFIRMED, CANCELLED, FAILED }

/**
 * iOS `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`: biometric OR the screen lock.
 * Android 10+ uses the platform BiometricPrompt with device-credential fallback; older
 * versions use the system confirm-credential screen via [launchKeyguard]. A phone with no
 * screen lock at all cannot confirm an owner, so it FAILS rather than silently passing.
 */
private suspend fun confirmDeviceOwner(
    context: Context,
    reason: String,
    launchKeyguard: (Intent, (Boolean) -> Unit) -> Unit,
): OwnerCheck {
    val keyguard = context.getSystemService(KeyguardManager::class.java)
    if (keyguard == null || !keyguard.isDeviceSecure) return OwnerCheck.FAILED

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val activity = context.findActivity() ?: return OwnerCheck.FAILED
        return suspendCancellableCoroutine { cont ->
            val builder = BiometricPrompt.Builder(activity)
                .setTitle("Link a Browser")
                .setDescription(reason)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setAllowedAuthenticators(
                    BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
            } else {
                @Suppress("DEPRECATION") builder.setDeviceCredentialAllowed(true)
            }
            val cancel = CancellationSignal()
            cont.invokeOnCancellation { cancel.cancel() }
            builder.build().authenticate(cancel, ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (cont.isActive) cont.resume(OwnerCheck.CONFIRMED)
                    }
                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        val cancelled = code == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED ||
                            code == BiometricPrompt.BIOMETRIC_ERROR_CANCELED
                        if (cont.isActive) cont.resume(if (cancelled) OwnerCheck.CANCELLED else OwnerCheck.FAILED)
                    }
                })
        }
    }

    @Suppress("DEPRECATION")
    val intent = keyguard.createConfirmDeviceCredentialIntent("Link a Browser", reason) ?: return OwnerCheck.FAILED
    return suspendCancellableCoroutine { cont ->
        launchKeyguard(intent) { ok -> if (cont.isActive) cont.resume(if (ok) OwnerCheck.CONFIRMED else OwnerCheck.CANCELLED) }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
