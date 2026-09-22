package com.voiid.app.main

import android.location.Geocoder
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.*
import com.voiid.app.BuildConfig
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import com.voiid.app.net.*
import com.voiid.app.ui.components.VoiidDetent
import com.voiid.app.ui.components.VoiidSheet
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.*

@Composable
fun LocationComposeSheet(conv: VConversation, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val permissions = rememberLocationPermissions()
    val provider = remember { LocationProvider(context) }
    val camera = rememberCameraPositionState()
    val target = ShareTarget(conv.id, conv.type == ConversationType.GROUP, conv.peerUserId)
    var live by remember { mutableStateOf(false) }
    var duration by remember { mutableStateOf(3600) }
    var label by remember { mutableStateOf("") }
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<android.location.Address>>(emptyList()) }
    var selected by remember { mutableStateOf<LatLng?>(null) }
    var searching by remember { mutableStateOf(false) }
    var locating by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var locateJob by remember { mutableStateOf<Job?>(null) }
    var selectionVersion by remember { mutableIntStateOf(0) }

    fun cancelLocate() { selectionVersion++; locateJob?.cancel(); locating = false }
    fun choose(point: LatLng) {
        selected = point
        camera.position = CameraPosition.fromLatLngZoom(point, 16f)
    }
    fun locate() {
        if (locating || sending) return
        status = null
        locating = true
        val version = ++selectionVersion
        permissions.request(needBackground = false) { permission ->
            if (version == selectionVersion) {
                if (permission == LocationPermissionResult.DENIED) {
                    locating = false
                    status = "Allow location access in Settings, or search for a place to send a pin."
                } else {
                    locateJob = scope.launch {
                        try {
                            val fix = provider.freshFix()
                            if (version == selectionVersion) {
                                if (fix == null) status = "Couldn’t locate you. Check that device location is on and try again."
                                else choose(LatLng(fix.latitude, fix.longitude))
                            }
                        } finally { if (version == selectionVersion) locating = false }
                    }
                }
            }
        }
    }
    LaunchedEffect(Unit) { if (LocationPermissions.hasForeground(context)) locate() }
    DisposableEffect(Unit) { onDispose { selectionVersion++; locateJob?.cancel() } }
    LaunchedEffect(camera.isMoving) {
        if (camera.cameraMoveStartedReason == CameraMoveStartedReason.GESTURE) {
            cancelLocate()
            if (!camera.isMoving) { selected = camera.position.target; label = "Dropped pin" }
        }
    }
    LaunchedEffect(query) {
        results = emptyList()
        if (query.trim().length < 2) { searching = false; return@LaunchedEffect }
        searching = true
        delay(350)
        try {
            // Only explicit search text goes to the geocoder; no automatic reverse geocoding.
            val matches = withTimeout(8_000) {
                check(Geocoder.isPresent()) { "Place search is unavailable on this device." }
                val geocoder = Geocoder(context)
                if (android.os.Build.VERSION.SDK_INT >= 33) {
                    suspendCancellableCoroutine<List<android.location.Address>> { continuation ->
                        geocoder.getFromLocationName(query.trim(), 6, object : Geocoder.GeocodeListener {
                            override fun onGeocode(addresses: MutableList<android.location.Address>) {
                                if (continuation.isActive) continuation.resumeWith(Result.success(addresses))
                            }
                            override fun onError(errorMessage: String?) {
                                if (continuation.isActive) continuation.resumeWith(Result.failure(IllegalStateException("Search unavailable")))
                            }
                        })
                    }
                } else runInterruptible(Dispatchers.IO) {
                    @Suppress("DEPRECATION")
                    geocoder.getFromLocationName(query.trim(), 6).orEmpty()
                }
            }
            results = matches.filter { it.hasLatitude() && it.hasLongitude() }
            status = if (results.isEmpty()) "No places found. Try a fuller address." else null
        } catch (e: TimeoutCancellationException) { status = "Search took too long. Please try again." }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { status = "Couldn’t search places. Check your connection and try again." }
        finally { searching = false }
    }
    fun send() {
        if (sending || locating || camera.isMoving) return
        status = null
        sending = true
        if (live) {
            permissions.request(needBackground = false) { permission ->
                if (permission == LocationPermissionResult.DENIED) {
                    sending = false
                    status = "Allow location access in Settings to share live location."
                } else scope.launch {
                    try {
                        status = LocationShareEngine.startLiveShare(context, target, duration)
                        if (status == null) onDismiss()
                    } finally { sending = false }
                }
            }
        } else scope.launch {
            try {
                val point = selected
                if (point == null) status = "Search, locate yourself, or move the map to choose a pin."
                else {
                    status = LocationShareEngine.sendPin(context, target, label, point.latitude, point.longitude)
                    if (status == null) onDismiss()
                }
            } finally { sending = false }
        }
    }

    VoiidSheet(visible = true, onDismiss = { if (!sending) onDismiss() }, detents = listOf(VoiidDetent.Large),
        dismissOnBack = !sending, tapOutsideToDismiss = !sending, dismissOnDrag = !sending) {
        Column(Modifier.fillMaxWidth().fillMaxHeight()) {
            Column(Modifier.fillMaxWidth().weight(1f)
                .verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Share location", style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
                        Text("With ${conv.title}", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                    }
                    Box(Modifier.size(48.dp).clickable(enabled = !sending) { onDismiss() }, contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.Close, "Close", tint = VoiidColor.textSecondary)
                    }
                }
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(VoiidColor.fieldFill).padding(4.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    LocationChoice("Send a pin", !live, Modifier.weight(1f), !sending) { live = false }
                    LocationChoice("Live location", live, Modifier.weight(1f), !sending) { live = true }
                }
                if (!live) {
                    LocationField(query, "Search places or addresses", !sending) { cancelLocate(); query = it }
                    if (searching) Text("Searching…", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                    results.forEach { address ->
                        Text(address.getAddressLine(0) ?: address.featureName ?: "Place",
                            style = VoiidFont.rounded(14), color = VoiidColor.textPrimary,
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(VoiidColor.fieldFill)
                                .clickable(enabled = !sending) {
                                    cancelLocate()
                                    choose(LatLng(address.latitude, address.longitude))
                                    label = address.featureName.orEmpty()
                                    query = ""; results = emptyList(); status = null
                                }.padding(14.dp))
                    }
                }
                if (!live) {
                    Box(Modifier.fillMaxWidth().height(260.dp).clip(RoundedCornerShape(20.dp))) {
                        if (BuildConfig.MAPS_CONFIGURED) {
                            GoogleMap(Modifier.fillMaxSize(), cameraPositionState = camera,
                                properties = MapProperties(isBuildingEnabled = false, mapStyleOptions = rememberLocationMapStyle()),
                                uiSettings = MapUiSettings(zoomControlsEnabled = false, mapToolbarEnabled = false,
                                    myLocationButtonEnabled = false, scrollGesturesEnabled = !sending && !live,
                                    zoomGesturesEnabled = !sending && !live))
                            if (selected != null || camera.isMoving) Icon(Icons.Default.LocationOn, "Selected location",
                                tint = VoiidColor.primary, modifier = Modifier.align(Alignment.Center).size(40.dp).offset(y = (-20).dp))
                        } else MapUnavailableCard(Modifier.fillMaxSize(), selected?.latitude, selected?.longitude)
                        Row(Modifier.align(Alignment.BottomEnd).padding(12.dp).clip(RoundedCornerShape(24.dp))
                            .background(VoiidColor.surfaceCard).clickable(enabled = !sending && !locating) { locate() }
                            .heightIn(min = 48.dp).padding(horizontal = 16.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (locating) CircularProgressIndicator(Modifier.size(18.dp), color = VoiidColor.primary, strokeWidth = 2.dp)
                            else Icon(Icons.Default.MyLocation, null, tint = VoiidColor.primary, modifier = Modifier.size(20.dp))
                            Text(if (locating) "Locating…" else "Locate me", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                        }
                    }
                }
                if (live) {
                    Text("Let them follow your journey", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    Text("${conv.title} can see your live location until the timer ends. You can stop at any time.",
                        style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                    Text("SHARE FOR", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(VoiidColor.surfaceCard)) {
                        listOf(900 to "15 min", 3600 to "1 hour", 28800 to "8 hours").forEach { (seconds, title) ->
                            Row(Modifier.fillMaxWidth().clickable(enabled = !sending) { duration = seconds }.padding(16.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                Text(title, style = VoiidFont.rounded(16, FontWeight.Medium), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                                androidx.compose.material3.RadioButton(selected = duration == seconds,
                                    onClick = null, enabled = !sending, modifier = Modifier.size(24.dp),
                                    colors = androidx.compose.material3.RadioButtonDefaults.colors(selectedColor = VoiidColor.primary))
                            }
                        }
                    }
                    Text("An ongoing notification lets you stop sharing while using other apps. Closing Voiid or device battery restrictions may interrupt updates.",
                        style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                } else {
                    Text(selected?.let { "%.5f, %.5f".format(it.latitude, it.longitude) } ?: "Choose a place with search, the map, or Locate me.",
                        style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                    LocationField(label, "Add a label (optional)", !sending) { label = it }
                }
                status?.let {
                    Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
                    if (!LocationPermissions.hasForeground(context)) Text("Open location settings",
                        style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.primary,
                        modifier = Modifier.clickable { LocationPermissions.openAppSettings(context) }.padding(vertical = 12.dp))
                }
            }
            Column(Modifier.fillMaxWidth().background(VoiidColor.surfaceCard).padding(horizontal = 20.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val enabled = !sending && !locating && !camera.isMoving && (live || selected != null)
                Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp))
                    .background(VoiidColor.primary.copy(alpha = if (enabled) 1f else 0.45f))
                    .clickable(enabled = enabled) { send() }.padding(18.dp), contentAlignment = Alignment.Center) {
                    Text(if (sending) "Sending…" else if (live) "Start live location" else "Send selected location",
                        style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textOnPrimary)
                }
                Text("Location messages are end-to-end encrypted.", style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
            }
        }
    }
}

@Composable
private fun LocationChoice(title: String, selected: Boolean, modifier: Modifier, enabled: Boolean, onClick: () -> Unit) {
    Box(modifier.clip(RoundedCornerShape(14.dp)).background(if (selected) VoiidColor.surfaceCard else VoiidColor.fieldFill)
        .clickable(enabled = enabled, onClick = onClick).heightIn(min = 48.dp).padding(horizontal = 8.dp), contentAlignment = Alignment.Center) {
        Text(title, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = if (selected) VoiidColor.textPrimary else VoiidColor.textSecondary)
    }
}

@Composable
private fun LocationField(value: String, placeholder: String, enabled: Boolean, onChange: (String) -> Unit) {
    BasicTextField(value, onChange, enabled = enabled, singleLine = true,
        textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
        cursorBrush = SolidColor(VoiidColor.primary),
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(VoiidColor.fieldFill).padding(16.dp),
        decorationBox = { inner -> Box { if (value.isEmpty()) Text(placeholder, style = VoiidFont.rounded(15), color = VoiidColor.placeholder); inner() } })
}
