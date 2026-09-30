package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DevicesOther
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.net.DeviceDirectoryService
import com.voiid.app.net.E2EManager
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidCircleBack
import com.voiid.app.ui.components.VoiidMenu
import com.voiid.app.ui.components.VoiidMenuItem
import com.voiid.app.ui.components.rememberVoiidPullRefresh
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.components.voiidPullRefresh
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Settings -> Linked Devices. Port of iOS `LinkedDevicesView.swift`; design reference
 * `Voiid Ui/Chat/LinkedDevicesScreen.swift`.
 *
 * Three decisions carried over verbatim:
 *  1. The current device is unrevocable STRUCTURALLY, not conditionally — its section renders
 *     [DeviceRow] bare. Swipe, long-press and the detail push are attached only in the
 *     other-devices loop, never inside the row.
 *  2. No device id ever reaches the screen as visible/selectable text — see
 *     [DeviceDirectoryService]'s security note. The id is used only as list key and as the
 *     revoke call's argument.
 *  3. "Link a Browser" pairs Voiid Web via QR (routes/linking.ts) — [LinkBrowserScreen].
 *     Disabled until this phone has an E2E device id: there is nothing to link a browser TO
 *     before this device is registered.
 *
 * What the screen does NOT claim: whether another device is online, where it is, or its IP —
 * the server exposes none of that. "Last active" is `last_seen_at`, labelled as exactly that.
 */
@Composable
fun LinkedDevicesScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalVoiidHaptics.current
    val service = remember { DeviceDirectoryService(context) }
    val currentDeviceId = remember { E2EManager.get(context).deviceId }

    var loading by remember { mutableStateOf(true) }
    var devices by remember { mutableStateOf<List<DeviceDirectoryService.LinkedDevice>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var deviceToRemove by remember { mutableStateOf<DeviceDirectoryService.LinkedDevice?>(null) }
    var confirmRemoveAll by remember { mutableStateOf(false) }
    var removalError by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<DeviceDirectoryService.LinkedDevice?>(null) }
    var showingHelp by remember { mutableStateOf(false) }
    var showingLinkBrowser by remember { mutableStateOf(false) }

    suspend fun load(showSpinner: Boolean) {
        if (showSpinner) loading = true
        try {
            devices = service.devices()
            error = null
            removalError = null
        } catch (e: Exception) {
            // A cold load has nothing to keep, so the failure takes the screen. A refresh over
            // a good list keeps the list and reports the failure inline.
            if (showSpinner || devices.isEmpty()) error = e.message ?: "Couldn't load devices."
            else removalError = e.message ?: "Couldn't load devices."
        }
        loading = false
    }

    /** Revokes each in turn, then reloads. Never receives the current device. */
    fun remove(targets: List<DeviceDirectoryService.LinkedDevice>) {
        scope.launch {
            working = true
            var failure: Exception? = null
            targets.filter { it.id != currentDeviceId }.forEach { d ->
                try { service.revoke(d.id) } catch (e: Exception) { failure = e }
            }
            if (failure != null) { haptics.error(); removalError = failure?.message ?: "Couldn't remove device." }
            else haptics.success()
            working = false
            load(showSpinner = false)
        }
    }

    val pull = rememberVoiidPullRefresh { scope.launch { load(showSpinner = false) } }
    LaunchedEffect(Unit) { load(showSpinner = true) }

    if (showingLinkBrowser) {
        LinkBrowserScreen(onClose = {
            showingLinkBrowser = false
            scope.launch { load(showSpinner = false) }
        })
        return
    }

    BackHandler { onBack() }

    val thisDevice = devices.firstOrNull { it.id == currentDeviceId }
    val otherDevices = devices.filter { it.id != currentDeviceId }
    // "Linked browsers" when that is all they are — the normal case, with one phone per account.
    val othersTitle = if (otherDevices.all { it.platform.equals("web", true) }) "Linked browsers" else "Other devices"

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .voiidPullRefresh(pull, VoiidColor.primary),
    ) {
        Row(Modifier.fillMaxWidth().padding(end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            VoiidCircleBack(onBack = onBack)
            Spacer(Modifier.weight(1f))
            Box(
                Modifier.size(40.dp).clip(CircleShape).background(VoiidColor.surfaceCard)
                    .softClickable { haptics.tap(); showingHelp = true },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.HelpOutline, "How linking works", tint = VoiidColor.accentInk, modifier = Modifier.size(22.dp))
            }
        }

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 24.dp)) {
            Text(
                "Linked Devices",
                style = VoiidFont.rounded(34, FontWeight.Bold),
                color = VoiidColor.textPrimary,
                modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 4.dp),
            )

            // The one thing people come here to DO, so it leads — above the list, not after it.
            GroupedSection(null) {
                Column(
                    Modifier.fillMaxWidth().padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Icon(Icons.Default.DevicesOther, null, tint = VoiidColor.accentInk, modifier = Modifier.size(40.dp))
                    Text(
                        "Use Voiid on your computer. Messages stay end-to-end encrypted on every device you link.",
                        style = VoiidFont.rounded(15), color = VoiidColor.textSecondary, textAlign = TextAlign.Center,
                    )
                    PrimaryPill(
                        "Link a Browser",
                        modifier = Modifier.fillMaxWidth(),
                        enabled = currentDeviceId != null,
                        icon = Icons.Default.QrCodeScanner,
                    ) { haptics.tap(); showingLinkBrowser = true }
                }
            }

            when {
                loading -> Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = VoiidColor.primary)
                }
                error != null -> GroupedSection(null) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(error!!, style = VoiidFont.rounded(15), color = VoiidColor.error)
                        Text("Try Again", style = VoiidFont.rounded(17), color = VoiidColor.accentInk,
                            modifier = Modifier.softClickable { scope.launch { load(showSpinner = true) } })
                    }
                }
                else -> {
                    // Rendered only when the server's ACTIVE list contains it — otherwise this
                    // device has been revoked, and "This device" would assert what it denied.
                    if (thisDevice != null) {
                        GroupedSection(
                            "This device",
                            footer = "Signing in to Voiid on another phone signs this one out. Voiid keeps one phone per account.",
                        ) {
                            DeviceRow(thisDevice, isCurrent = true)
                        }
                    }

                    if (currentDeviceId == null) {
                        // We cannot tell which row is the phone in the user's hand, so nothing is
                        // removable: a wrong guess signs the user out of their own account.
                        GroupedSection(
                            "Devices",
                            footer = "Voiid can't tell which of these is the phone you're using right now, so devices " +
                                "can't be removed here — removing the wrong one would sign you out. Pull down to refresh.",
                        ) {
                            if (devices.isEmpty()) EmptyRow("No devices are signed in.")
                            devices.forEachIndexed { i, d ->
                                DeviceRow(d, isCurrent = false)
                                if (i < devices.lastIndex) RowDivider()
                            }
                            removalError?.let { InlineError(it) }
                        }
                    } else {
                        GroupedSection(
                            othersTitle,
                            footer = "Removing a device stops it receiving new messages straight away. Anything it already downloaded stays on it.",
                        ) {
                            if (otherDevices.isEmpty()) EmptyRow("No browsers are linked.")
                            otherDevices.forEachIndexed { i, d ->
                                // Removal is attached HERE, never inside DeviceRow — see decision 1.
                                RemovableDevice(
                                    device = d,
                                    onOpen = { haptics.tap(); detail = d },
                                    onRemove = { haptics.rigid(); removalError = null; deviceToRemove = d },
                                )
                                if (i < otherDevices.lastIndex) RowDivider()
                            }
                            removalError?.let { InlineError(it) }
                        }

                        if (otherDevices.size > 1) {
                            GroupedSection(null) {
                                Box(
                                    Modifier.fillMaxWidth().softClickable(enabled = !working, scale = 1f) {
                                        haptics.rigid(); removalError = null; confirmRemoveAll = true
                                    }.padding(vertical = 13.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (working) CircularProgressIndicator(color = VoiidColor.error, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                                    else Text("Log Out All Other Devices", style = VoiidFont.rounded(17), color = VoiidColor.error)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    deviceToRemove?.let { device ->
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { deviceToRemove = null },
            title = "Remove this device?",
            // What actually happens, not "are you sure".
            body = "${device.name} will be signed out and stop receiving new messages. Linking it again takes a new QR scan from this phone.",
            confirmLabel = "Remove",
            onConfirm = { deviceToRemove = null; remove(listOf(device)) },
            confirmDestructive = true,
        )
    }

    if (confirmRemoveAll) {
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { confirmRemoveAll = false },
            title = "Log out all other devices?",
            body = "This phone stays signed in. Every other device is signed out immediately.",
            confirmLabel = "Log Out ${otherDevices.size} Devices",
            onConfirm = { confirmRemoveAll = false; remove(otherDevices) },
            confirmDestructive = true,
        )
    }

    detail?.let { d ->
        DeviceDetail(d, onBack = { detail = null }, onRemove = { detail = null; deviceToRemove = d })
    }

    if (showingHelp) LinkingHelp(onClose = { showingHelp = false })
}

private fun lastActive(device: DeviceDirectoryService.LinkedDevice): String? =
    device.lastSeenMillis?.let { "Last active ${VoiidDate.relative(it)}" }

/** One device. Deliberately carries NO removal affordance — see decision 1. */
@Composable
private fun DeviceRow(device: DeviceDirectoryService.LinkedDevice, isCurrent: Boolean, trailing: (@Composable () -> Unit)? = null) {
    val detail = if (isCurrent) "Active now" else lastActive(device)
    Row(
        Modifier.fillMaxWidth().background(VoiidColor.surfaceCard).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            Modifier.size(38.dp).clip(RoundedCornerShape(10.dp))
                .background(if (isCurrent) VoiidColor.primary else VoiidColor.accentTint),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (device.isPhone) Icons.Default.PhoneAndroid else Icons.Default.Laptop, null,
                tint = if (isCurrent) Color.White else VoiidColor.accentInk, modifier = Modifier.size(20.dp),
            )
        }
        Column(Modifier.weight(1f)) {
            Text(device.name, style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            detail?.let {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (isCurrent) Box(Modifier.size(7.dp).clip(CircleShape).background(VoiidColor.success))
                    Text(it, style = VoiidFont.rounded(15), color = if (isCurrent) VoiidColor.success else VoiidColor.textSecondary)
                }
            }
        }
        trailing?.invoke()
    }
}

/** Swipe left or long-press to remove; tap for details. Wraps [DeviceRow] from outside. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun RemovableDevice(device: DeviceDirectoryService.LinkedDevice, onOpen: () -> Unit, onRemove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    // A full swipe only REVEALS Remove; revoking always goes through the confirm dialog.
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { false })
    Box {
        SwipeToDismissBox(
            state = state,
            enableDismissFromStartToEnd = false,
            backgroundContent = {
                Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.End) {
                    Box(
                        Modifier.width(88.dp).fillMaxHeight().background(VoiidColor.error).softClickable(onClick = onRemove),
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(Icons.Default.Delete, null, tint = Color.White)
                            Text("Remove", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = Color.White)
                        }
                    }
                }
            },
        ) {
            Box(Modifier.combinedClickable(onClick = onOpen, onLongClick = { menu = true })) {
                DeviceRow(device, isCurrent = false) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = VoiidColor.textSecondary)
                }
            }
        }
        VoiidMenu(expanded = menu, onDismissRequest = { menu = false }) {
            VoiidMenuItem("Remove", Icons.Default.Delete, destructive = true) { menu = false; onRemove() }
        }
    }
}

@Composable
private fun EmptyRow(text: String) {
    Text(text, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary, modifier = Modifier.padding(16.dp))
}

@Composable
private fun InlineError(text: String) {
    Text(text, style = VoiidFont.rounded(13), color = VoiidColor.error, modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp))
}

@Composable
private fun RowDivider() = HorizontalDivider(color = VoiidColor.divider, modifier = Modifier.padding(start = 68.dp))

// MARK: - Detail

@Composable
private fun DeviceDetail(device: DeviceDirectoryService.LinkedDevice, onBack: () -> Unit, onRemove: () -> Unit) {
    val platform = when (device.platform.lowercase()) {
        "web" -> "Voiid Web"
        "ios" -> "iPhone"
        "android" -> "Android"
        else -> device.platform.ifBlank { "Unknown" }
    }
    Dialog(onDismissRequest = onBack, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        BackHandler { onBack() }
        Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding().navigationBarsPadding()) {
            VoiidCircleBack(onBack = onBack)
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    Modifier.size(72.dp).clip(RoundedCornerShape(18.dp)).background(VoiidColor.accentTint),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(if (device.isPhone) Icons.Default.PhoneAndroid else Icons.Default.Laptop, null,
                        tint = VoiidColor.accentInk, modifier = Modifier.size(34.dp))
                }
                Spacer(Modifier.height(10.dp))
                Text(device.name, style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary,
                    textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 16.dp))
            }
            Spacer(Modifier.height(12.dp))
            GroupedSection(
                null,
                footer = "Don't recognise this device? Remove it. Whoever is using it loses access to new messages immediately.",
            ) {
                LabeledRow("App", platform)
                RowDivider()
                LabeledRow("Last active", device.lastSeenMillis?.let {
                    SimpleDateFormat("d MMM yyyy, h:mm a", Locale.getDefault()).format(Date(it))
                } ?: "Not yet")
            }
            GroupedSection(null) {
                Box(
                    Modifier.fillMaxWidth().softClickable(scale = 1f, onClick = onRemove).padding(vertical = 13.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("Remove Device", style = VoiidFont.rounded(17), color = VoiidColor.error)
                }
            }
        }
    }
}

@Composable
private fun LabeledRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
        Text(label, style = VoiidFont.rounded(17), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
        Text(value, style = VoiidFont.rounded(17), color = VoiidColor.textSecondary)
    }
}

// MARK: - Help

@Composable
private fun LinkingHelp(onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        BackHandler { onClose() }
        Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding().navigationBarsPadding()) {
            Box(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 16.dp)) {
                Text("How Linking Works", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                    modifier = Modifier.align(Alignment.Center))
                Text("Done", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.accentInk,
                    modifier = Modifier.align(Alignment.CenterEnd).softClickable(onClick = onClose))
            }
            GroupedSection(null) {
                HelpItem(Icons.Default.QrCodeScanner, "Linking",
                    "Open Voiid Web on a computer and scan its QR code with this phone. Nothing is linked until you check the code matches and confirm with your screen lock.")
                RowDivider()
                HelpItem(Icons.Default.Lock, "Encryption",
                    "Each browser has its own keys. Messages are end-to-end encrypted to every linked device.")
                RowDivider()
                HelpItem(Icons.Default.PhoneAndroid, "One phone per account", "Signing in on another phone signs this one out.")
                RowDivider()
                HelpItem(Icons.Default.PanTool, "Something you don't recognise", "Remove it. It stops receiving new messages at once.")
            }
        }
    }
}

@Composable
private fun HelpItem(icon: ImageVector, title: String, body: String) {
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Icon(icon, null, tint = VoiidColor.accentInk, modifier = Modifier.size(22.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text(body, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
        }
    }
}
