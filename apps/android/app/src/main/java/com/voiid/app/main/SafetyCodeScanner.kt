package com.voiid.app.main

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.voiid.app.ui.theme.VoiidColor

internal object SafetyQRComparison {
    enum class Result { MATCH, MISMATCH, INVALID }
    fun compare(payload: String, expected: String): Result {
        val digits = expected.filter { it in '0'..'9' }
        if (payload.length != 60 || payload.any { it !in '0'..'9' } || digits.length != 60) return Result.INVALID
        return if (payload == digits) Result.MATCH else Result.MISMATCH
    }
}

@Composable
internal fun SafetyCodeScanner(expected: String, peerName: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var permission by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var active by remember { mutableStateOf(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    var unavailable by remember { mutableStateOf(false) }
    var result by remember(expected) { mutableStateOf<SafetyQRComparison.Result?>(null) }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { permission = it }
    LaunchedEffect(Unit) { if (!permission) request.launch(Manifest.permission.CAMERA) }
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, _ ->
            active = owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            if (active) permission = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(VoiidColor.background).systemBarsPadding()
            .verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            Text("Scan security QR", color = VoiidColor.textPrimary)
            Text("Scan $peerName’s code from this device pair’s Verify encryption screen.", color = VoiidColor.textSecondary)
            val outcome = result
            if (outcome != null) {
                Text(when (outcome) {
                    SafetyQRComparison.Result.MATCH -> "Codes match"
                    SafetyQRComparison.Result.MISMATCH -> "Codes don’t match"
                    SafetyQRComparison.Result.INVALID -> "Not a security QR code"
                }, color = VoiidColor.textPrimary)
                Text(when (outcome) {
                    SafetyQRComparison.Result.MATCH -> "The displayed security codes match for this device pair. Verify other linked devices separately."
                    SafetyQRComparison.Result.MISMATCH -> "Check the conversation and selected device. Compare the codes again before sharing sensitive information."
                    SafetyQRComparison.Result.INVALID -> "Scan the QR shown in Verify encryption, not a profile or community QR."
                }, color = VoiidColor.textSecondary)
                Button(onClick = { result = null }) { Text("Scan again") }
            } else if (permission && !unavailable) {
                Box(Modifier.fillMaxWidth().height(320.dp)) {
                    CameraFeed(scanning = active, onCamera = {}, onError = { unavailable = true },
                        onDecoded = { if (result == null) result = SafetyQRComparison.compare(it, expected) })
                }
            } else {
                Text(if (unavailable) "Camera unavailable. You can still compare the digits." else "Allow camera access to scan, or compare the digits manually.", color = VoiidColor.textSecondary)
                if (!permission) Button(onClick = { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))) }) { Text("Open Settings") }
            }
            Button(onClick = onClose) { Text("Done") }
        }
    }
}
