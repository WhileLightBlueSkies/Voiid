package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.DeviceDirectoryService
import com.voiid.app.net.E2EManager
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Settings -> Linked Devices. Port of iOS `LinkedDevicesView.swift`.
 *
 * Three decisions carried over verbatim:
 *  1. The current device is unrevocable STRUCTURALLY, not conditionally — it renders in
 *     its own section built by its own row, with no remove affordance attached anywhere
 *     in that code path (contrast [OtherDeviceRow] below, the only row with a delete icon).
 *  2. No device id ever reaches the screen as visible/selectable text — see
 *     [DeviceDirectoryService]'s security note. The id is used only as list key and as the
 *     revoke call's argument.
 *  3. No "Link a Device" button: that would pair a web companion via QR (routes/linking.ts),
 *     which needs camera capture + a scanner screen that does not exist yet. A button here
 *     with no scanner behind it would open nothing.
 */
@Composable
fun LinkedDevicesScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val service = remember { DeviceDirectoryService(context) }
    val currentDeviceId = remember { E2EManager.get(context).deviceId }

    var loading by remember { mutableStateOf(true) }
    var devices by remember { mutableStateOf<List<DeviceDirectoryService.LinkedDevice>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var deviceToRemove by remember { mutableStateOf<DeviceDirectoryService.LinkedDevice?>(null) }
    var removalError by remember { mutableStateOf<String?>(null) }

    suspend fun load(showSpinner: Boolean) {
        if (showSpinner) loading = true
        try {
            devices = service.devices()
            error = null
        } catch (e: Exception) {
            if (showSpinner || devices.isEmpty()) error = e.message ?: "Couldn't load devices."
            else removalError = e.message ?: "Couldn't load devices."
        }
        loading = false
    }

    LaunchedEffect(Unit) { load(showSpinner = true) }

    val thisDevice = devices.firstOrNull { it.id == currentDeviceId }
    val otherDevices = devices.filter { it.id != currentDeviceId }

    BackupScaffold(title = "Linked Devices", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        when {
            loading -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                CircularProgressIndicator(color = VoiidColor.primary)
            }
            error != null -> Column {
                Text(error!!, style = VoiidFont.rounded(14), color = VoiidColor.error)
                Spacer(Modifier.height(8.dp))
                TextButton(onClick = { scope.launch { load(showSpinner = true) } }) {
                    Text("Try Again", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.primary)
                }
            }
            else -> {
                if (thisDevice != null) {
                    Text("This device", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                    Spacer(Modifier.height(8.dp))
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard),
                    ) {
                        DeviceRow(name = thisDevice.name, detail = "Signed in", isPhone = thisDevice.isPhone)
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Signing in to Voiid on another phone signs this one out — Voiid keeps one phone per account.",
                        style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                    )
                    Spacer(Modifier.height(20.dp))
                }

                if (currentDeviceId == null) {
                    Text("Devices", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                    Spacer(Modifier.height(8.dp))
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard),
                    ) {
                        if (devices.isEmpty()) {
                            Text(
                                "No devices are signed in.", style = VoiidFont.rounded(14),
                                color = VoiidColor.textSecondary, modifier = Modifier.padding(16.dp),
                            )
                        } else {
                            devices.forEach { d ->
                                DeviceRow(name = d.name, detail = lastActive(d), isPhone = d.isPhone)
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Voiid can't tell which of these is the phone you're using right now, so devices " +
                            "can't be removed here — removing the wrong one would sign you out. Pull down to refresh.",
                        style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                    )
                } else {
                    Text("Other devices", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                    Spacer(Modifier.height(8.dp))
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard),
                    ) {
                        if (otherDevices.isEmpty()) {
                            Text(
                                "No other devices are signed in.", style = VoiidFont.rounded(14),
                                color = VoiidColor.textSecondary, modifier = Modifier.padding(16.dp),
                            )
                        } else {
                            otherDevices.forEach { d ->
                                OtherDeviceRow(
                                    name = d.name, detail = lastActive(d), isPhone = d.isPhone,
                                    onRemove = { removalError = null; deviceToRemove = d },
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Removing a device stops it receiving new messages straight away. Anything already " +
                            "downloaded to that device stays on it. Devices are added when you sign in to " +
                            "Voiid on a new device.",
                        style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                    )
                }

                removalError?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error)
                }
            }
        }
    }

    deviceToRemove?.let { device ->
        AlertDialog(
            onDismissRequest = { deviceToRemove = null },
            containerColor = VoiidColor.surfaceCard,
            title = { Text("Remove this device?", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary) },
            text = { Text("It will stop receiving new messages.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary) },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        try {
                            service.revoke(device.id)
                            deviceToRemove = null
                            load(showSpinner = false)
                        } catch (e: Exception) {
                            removalError = e.message ?: "Couldn't remove device."
                            deviceToRemove = null
                        }
                    }
                }) { Text("Remove", color = VoiidColor.error) }
            },
            dismissButton = { TextButton(onClick = { deviceToRemove = null }) { Text("Cancel", color = VoiidColor.primary) } },
        )
    }
}

private fun lastActive(device: DeviceDirectoryService.LinkedDevice): String? =
    device.lastSeenMillis?.let { "Last active ${VoiidDate.relative(it)}" }

@Composable
private fun DeviceRow(name: String, detail: String?, isPhone: Boolean) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            if (isPhone) Icons.Default.PhoneAndroid else Icons.Default.Laptop, null,
            tint = VoiidColor.primary, modifier = Modifier.size(20.dp),
        )
        Column {
            Text(name, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
            detail?.let { Text(it, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary) }
        }
    }
}

@Composable
private fun OtherDeviceRow(name: String, detail: String?, isPhone: Boolean, onRemove: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            if (isPhone) Icons.Default.PhoneAndroid else Icons.Default.Laptop, null,
            tint = VoiidColor.primary, modifier = Modifier.size(20.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(name, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
            detail?.let { Text(it, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary) }
        }
        Icon(
            Icons.Default.Delete, "Remove device",
            tint = VoiidColor.error, modifier = Modifier.size(20.dp).softClickable { onRemove() },
        )
    }
}
