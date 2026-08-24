package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.rememberCameraPositionState
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.offset
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import com.voiid.app.net.LocationPermissionResult
import com.voiid.app.net.LocationPermissions
import com.voiid.app.net.LocationShareEngine
import com.voiid.app.net.ShareTarget
import com.voiid.app.net.rememberLocationPermissions
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * The "share location" compose sheet (docs/LOCATION.md §8.A). Names the audience explicitly, then
 * offers a one-off pin OR a time-bounded live share (15 min / 1 h / 8 h — no indefinite option).
 * The runtime location permission is requested IN-CONTEXT here (foreground always; background only
 * when duration > 15 min), never at onboarding. A denial is never fatal — a foreground-only share
 * still runs; only a hard foreground denial blocks it, and then we route to Settings.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LocationComposeSheet(conv: VConversation, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val permissions = rememberLocationPermissions()

    val isGroup = conv.type == ConversationType.GROUP
    val target = ShareTarget(conversationId = conv.id, isGroup = isGroup, peerUserId = conv.peerUserId)
    val audience = if (isGroup) "Everyone in ${conv.title} (${conv.memberCount} people)" else conv.title

    var label by remember { mutableStateOf("") }
    val haptics = LocalVoiidHaptics.current

    // Picker camera. Starts on the user so the common case — "here" — needs no panning.
    val pickerCamera = rememberCameraPositionState()
    var myLocation by remember { mutableStateOf<LatLng?>(null) }
    LaunchedEffect(Unit) {
        // One coarse fix to centre on. Without it the map opens on the whole globe and every
        // pin starts with a hunt.
        LocationShareEngine.currentFixForPicker(context) { lat, lon ->
            val here = LatLng(lat, lon)
            myLocation = here
            pickerCamera.position = CameraPosition.fromLatLngZoom(here, PICKER_ZOOM)
        }
    }
    var status by remember { mutableStateOf<String?>(null) }
    var permanentlyDenied by remember { mutableStateOf(false) }

    fun startLive(durationSeconds: Int) {
        val needBackground = durationSeconds > 900
        permissions.request(needBackground) { result ->
            when (result) {
                LocationPermissionResult.DENIED -> {
                    status = "Location permission is needed to share."
                    permanentlyDenied = (context as? android.app.Activity)?.let { LocationPermissions.foregroundPermanentlyDenied(it) } ?: false
                }
                LocationPermissionResult.FOREGROUND_ONLY, LocationPermissionResult.FULL -> {
                    if (result == LocationPermissionResult.FOREGROUND_ONLY && needBackground)
                        status = "Live location pauses when Voiid is in the background."
                    scope.launch {
                        val err = LocationShareEngine.startLiveShare(context, target, durationSeconds)
                        if (err != null) status = err else onDismiss()
                    }
                }
            }
        }
    }

    fun sendPin() {
        permissions.request(needBackground = false) { result ->
            if (result == LocationPermissionResult.DENIED) {
                status = "Location permission is needed to share."
                permanentlyDenied = (context as? android.app.Activity)?.let { LocationPermissions.foregroundPermanentlyDenied(it) } ?: false
            } else {
                // The coordinate under the crosshair — where the user actually placed the pin.
                val c = pickerCamera.position.target
                LocationShareEngine.sendPin(context, target, label.ifBlank { null }, c.latitude, c.longitude)
                onDismiss()
            }
        }
    }

    com.voiid.app.ui.components.VoiidSheet(visible = true, onDismiss = onDismiss, detents = listOf(com.voiid.app.ui.components.VoiidDetent.Medium, com.voiid.app.ui.components.VoiidDetent.Large),) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Default.LocationOn, null, tint = VoiidColor.primary, modifier = Modifier.size(22.dp))
                Text("Share location", style = VoiidFont.rounded(20, FontWeight.Bold), color = VoiidColor.textPrimary)
            }
            Text(
                "Your location is end-to-end encrypted — Voiid’s servers never see it.",
                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
            )

            // THE PICKER MAP, which was missing entirely.
            //
            // The sheet only offered "send my current location" — so you could not send where
            // you are MEETING someone, only where you happened to be standing, which is most
            // of what a location pin is for.
            //
            // The pin is FIXED AT THE CENTRE and the map moves under it, rather than a marker
            // you drag. That is what WhatsApp, Uber and Google Maps all do, for a good reason:
            // a dragged marker sits under your thumb at the moment you place it, so you cannot
            // see what you are choosing. Mirrors iOS.
            Box(
                Modifier.fillMaxWidth().height(240.dp).clip(RoundedCornerShape(VoiidRadius.lg)),
            ) {
                GoogleMap(
                    modifier = Modifier.fillMaxSize(),
                    cameraPositionState = pickerCamera,
                    uiSettings = MapUiSettings(
                        zoomControlsEnabled = false,
                        mapToolbarEnabled = false,
                        myLocationButtonEnabled = false,
                    ),
                )
                // The crosshair, offset up so the pin's POINT is at the centre — centring the
                // whole glyph would put the tip below the position it marks.
                Icon(
                    Icons.Default.LocationOn, null,
                    tint = VoiidColor.error,
                    modifier = Modifier.align(Alignment.Center).size(40.dp).offset(y = (-20).dp),
                )
                // Recentre. Panning away and losing yourself is the one thing a picker must
                // let you undo.
                Box(
                    Modifier
                        .align(Alignment.BottomEnd)
                        .padding(8.dp)
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.surfaceCard)
                        .softClickable {
                            haptics.tap()
                            myLocation?.let {
                                pickerCamera.position = CameraPosition.fromLatLngZoom(it, PICKER_ZOOM)
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Default.MyLocation, "My location", tint = VoiidColor.primary, modifier = Modifier.size(18.dp))
                }
            }

            // Optional user-typed label (NEVER reverse-geocoded — docs/LOCATION.md §10).
            val shape = RoundedCornerShape(VoiidRadius.md)
            Box(
                Modifier.fillMaxWidth().height(48.dp).clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.fieldFill).border(1.dp, VoiidColor.fieldBorder, shape)
                    .padding(horizontal = 14.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                BasicTextField(
                    value = label, onValueChange = { label = it }, singleLine = true,
                    textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
                    cursorBrush = SolidColor(VoiidColor.primary), modifier = Modifier.fillMaxWidth(),
                    decorationBox = { inner ->
                        if (label.isEmpty()) Text("Add a label (optional)", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                        inner()
                    },
                )
            }

            PrimaryRow(Icons.Default.LocationOn, "Send current location", "A one-off pin in this chat") { sendPin() }

            Text("Share live location", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary, modifier = Modifier.padding(top = 4.dp))
            Text(
                "$audience will see your live location.",
                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                DurationChip("15 min", Modifier.weight(1f)) { startLive(900) }
                DurationChip("1 hour", Modifier.weight(1f)) { startLive(3600) }
                DurationChip("8 hours", Modifier.weight(1f)) { startLive(28800) }
            }

            status?.let { s ->
                Text(s, style = VoiidFont.rounded(12, FontWeight.Medium), color = VoiidColor.error)
                if (permanentlyDenied) {
                    Text(
                        "Open Settings to allow location",
                        style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.primary,
                        modifier = Modifier.clickable { LocationPermissions.openAppSettings(context) },
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun PrimaryRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.primary).clickable { onClick() }.padding(14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, null, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textOnPrimary)
            Text(subtitle, style = VoiidFont.rounded(11), color = VoiidColor.textOnPrimary.copy(alpha = 0.8f))
        }
    }
}

@Composable
private fun DurationChip(label: String, modifier: Modifier, onClick: () -> Unit) {
    val shape = RoundedCornerShape(VoiidRadius.pill)
    Row(
        modifier.clip(shape).background(VoiidColor.fieldFill).border(1.dp, VoiidColor.fieldBorder, shape).clickable { onClick() }.padding(vertical = 12.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Schedule, null, tint = VoiidColor.primary, modifier = Modifier.size(14.dp))
        Spacer(Modifier.size(6.dp))
        Text(label, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textPrimary)
    }
}

/** ~600 m across: close enough to place a pin on a building, wide enough to orient. */
private const val PICKER_ZOOM = 16f
