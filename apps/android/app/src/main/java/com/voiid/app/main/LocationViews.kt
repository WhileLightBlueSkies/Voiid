package com.voiid.app.main

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.material.icons.filled.LocationOff
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Map
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.GoogleMapOptions
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.rememberCameraPositionState
import com.voiid.app.BuildConfig
import com.voiid.app.net.ChatEngine
import com.voiid.app.ui.theme.LocalVoiidDark
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Local map rendering for location messages (docs/LOCATION.md §4, §7). We render the map ON
 * DEVICE — we never upload a rendered thumbnail (that would be a second R2 blob + key, and would
 * leak the sender's device to Google on behalf of every viewer). Each viewer renders locally.
 *
 * A MISSING Google Maps API key must degrade VISIBLY, never crash and never grey out silently:
 * with `BuildConfig.MAPS_CONFIGURED == false` we NEVER instantiate GoogleMap — we render
 * [MapUnavailableCard] / a coordinate card, and location sharing itself keeps working (coordinates
 * + Open in Maps). The key must come from the developer (local.properties / -PMAPS_API_KEY / env);
 * we never invent or hardcode one.
 */

/** Hand off to whatever map app is installed (docs/LOCATION.md §4 — no in-app routing). */
fun openInMaps(context: Context, lat: Double, lon: Double, label: String?) {
    val q = if (label.isNullOrBlank()) "$lat,$lon" else Uri.encode(label)
    val uri = Uri.parse("geo:$lat,$lon?q=$lat,$lon($q)")
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        .onFailure {
            // No map app: fall back to a plain geo: without a query, then give up silently.
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("geo:$lat,$lon")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
}

/**
 * A static, lite-mode map centred on [lat],[lon] with a pin. Lite mode renders a static bitmap —
 * correct and cheap inside a scrolling list. Falls back to [MapUnavailableCard] when the key is
 * absent, and to a coordinate card if the map never reports loaded (a wrong/restricted key).
 */
@Composable
fun LocationMap(
    lat: Double,
    lon: Double,
    lite: Boolean,
    modifier: Modifier = Modifier,
    desaturated: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    if (!BuildConfig.MAPS_CONFIGURED) {
        MapUnavailableCard(modifier, lat, lon)
        return
    }
    var failed by remember(lat, lon) { mutableStateOf(false) }
    var loaded by remember(lat, lon) { mutableStateOf(false) }
    // Runtime gate for the more common real failure: a key that EXISTS but is restricted to the
    // wrong package/SHA-1 renders grey tiles. Watchdog swaps in the coordinate card.
    LaunchedEffect(lat, lon) {
        kotlinx.coroutines.delay(6_000)
        if (!loaded) failed = true
    }
    if (failed) { MapUnavailableCard(modifier, lat, lon, wrongKey = true); return }

    Box(modifier) {
        val camera = rememberCameraPositionState { position = CameraPosition.fromLatLngZoom(LatLng(lat, lon), 15f) }
        GoogleMap(
            modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(VoiidRadius.md)),
            cameraPositionState = camera,
            googleMapOptionsFactory = { GoogleMapOptions().liteMode(lite) },
            uiSettings = MapUiSettings(
                zoomControlsEnabled = false, scrollGesturesEnabled = !lite,
                zoomGesturesEnabled = !lite, compassEnabled = false, mapToolbarEnabled = false,
            ),
            properties = com.google.maps.android.compose.MapProperties(
                mapType = MapType.NORMAL,
                isBuildingEnabled = false,
                // The in-chat bubble used NO style at all — a stock Google basemap sitting
                // inside a Peacock transcript, and a glaring white rectangle in dark mode.
                // Same two styles the Map tab uses, so a pin looks identical in both places.
                mapStyleOptions = com.google.android.gms.maps.model.MapStyleOptions(
                    if (LocalVoiidDark.current) VOIID_MAP_STYLE_DARK else VOIID_MAP_STYLE_LIGHT,
                ),
            ),
            onMapLoaded = { loaded = true },
        ) {
            Marker(state = MarkerState(position = LatLng(lat, lon)))
        }
        if (desaturated) {
            // Stale marker: dim the last-known map so "lost signal" reads differently from live.
            Box(Modifier.fillMaxSize().clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.background.copy(alpha = 0.35f)))
        }
        if (lite && onClick != null) {
            // Lite mode's DOCUMENTED default tap action is to launch the external Google Maps
            // app, and the GoogleMap child consumes the touch before any parent `clickable`
            // ever sees it — which is why tapping a bubble used to leave Voiid instead of
            // opening our own LocationDetailView. Swallow input in an overlay ABOVE the map
            // (and above the desaturation scrim) and invoke the caller's handler ourselves.
            // The external app must only ever be reachable from the explicit "Open in Maps" /
            // "Directions" buttons in the detail view.
            Box(
                Modifier
                    .fillMaxSize()
                    .pointerInput(onClick) { detectTapGestures { onClick() } },
            )
        }
    }
}

/**
 * Shown wherever a map cannot render — either the build has no Maps key ([BuildConfig]
 * .MAPS_CONFIGURED == false) or a key that exists is restricted wrong. A coordinate card, never a
 * silent grey grid. Location sharing itself is unaffected.
 */
@Composable
fun MapUnavailableCard(modifier: Modifier = Modifier, lat: Double? = null, lon: Double? = null, wrongKey: Boolean = false) {
    val shape = RoundedCornerShape(VoiidRadius.md)
    Column(
        modifier
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, shape)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Default.Map, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(28.dp))
        Text(
            if (wrongKey) "Map failed to load" else "Maps aren’t set up in this build",
            style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textPrimary,
        )
        Text(
            if (wrongKey) "Check the API key’s restrictions."
            else "Add MAPS_API_KEY to local.properties and rebuild — see docs/LOCATION.md.",
            style = VoiidFont.rounded(11), color = VoiidColor.textSecondary,
        )
        if (lat != null && lon != null) {
            Text(
                "%.5f, %.5f".format(lat, lon),
                style = VoiidFont.rounded(11, FontWeight.Medium), color = VoiidColor.textSecondary,
            )
        }
    }
}

/**
 * The in-conversation location bubble (docs/LOCATION.md §4). Renders a pin or a live marker. All
 * live/ended state is derivable from expiresAt alone (the timer guarantee, §3), refined by the
 * live fix stream when we have it.
 */
@Composable
fun LocationPinBubble(message: com.voiid.app.model.VMessage) {
    val ref = message.location ?: return
    val engine = com.voiid.app.net.LocationShareEngine
    val now = System.currentTimeMillis()
    var showDetail by remember { mutableStateOf(false) }

    if (showDetail) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showDetail = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
            // Pass the conversation so the detail can draw EVERY sharer in this chat on one
            // map, not just the person whose bubble was tapped.
        ) { LocationDetailView(ref, message.conversationId) { showDetail = false } }
    }

    val isLive = ref.kind == com.voiid.app.model.LocationEnvelope.K_LIVE_START
    // Recipient live view (fix stream); for my own bubble this is null and we drive off expiresAt.
    val inbound = if (isLive && !message.isMine) engine.inbound(ref.shareId) else null
    val state = when {
        !isLive -> null
        inbound != null -> inbound.state(now)
        message.isMine && engine.isMineActive(ref.shareId) && (ref.expiresAt ?: 0) > now -> com.voiid.app.model.ShareState.LIVE
        (ref.expiresAt ?: 0) > now -> com.voiid.app.model.ShareState.STALE
        else -> com.voiid.app.model.ShareState.ENDED
    }
    // The most current coordinate we can show (last live fix if any, else the message's own).
    // Both may be null for an iOS live_start that hasn't sent its first fix yet.
    val fix = inbound?.lastFix
    val lat = fix?.lat ?: ref.lat
    val lon = fix?.lon ?: ref.lon
    val ended = state == com.voiid.app.model.ShareState.ENDED
    val hasCoord = lat != null && lon != null

    Column(Modifier.width(220.dp).clip(RoundedCornerShape(VoiidRadius.md)).clickable { if (hasCoord) showDetail = true }) {
        if (hasCoord) {
            LocationMap(
                lat = lat, lon = lon, lite = true,
                modifier = Modifier.fillMaxWidth().height(140.dp),
                desaturated = state == com.voiid.app.model.ShareState.STALE || ended,
                // The map surface swallows taps, so it opens the detail itself; the Column's
                // clickable below stays as the handler for the non-map ("Locating…") states.
                onClick = { showDetail = true },
            )
        } else {
            // Live share received but no fix yet — a calm "locating" panel until it lands.
            Box(
                Modifier.fillMaxWidth().height(140.dp).background(VoiidColor.fieldFill),
                contentAlignment = Alignment.Center,
            ) { Text("Locating…", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary) }
        }
        Row(
            Modifier.fillMaxWidth().background(VoiidColor.surfaceCard).padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                if (ended) Icons.Default.LocationOff else Icons.Default.LocationOn,
                null, tint = if (ended) VoiidColor.textSecondary else VoiidColor.primary, modifier = Modifier.size(16.dp),
            )
            Column(Modifier.weight(1f)) {
                Text(
                    ref.label?.ifBlank { null } ?: if (isLive) "Live location" else "Location",
                    style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textPrimary, maxLines = 1,
                )
                val sub = when {
                    isLive && ended -> "ended ${VoiidDate.bubbleTime(ref.expiresAt ?: message.createdAt)}"
                    isLive && state == com.voiid.app.model.ShareState.STALE -> "may have lost signal"
                    isLive -> "Live · ${minutesLeft(ref.expiresAt, now)} left"
                    else -> "Tap to open"
                }
                Text(sub, style = VoiidFont.rounded(11), color = VoiidColor.textSecondary, maxLines = 1)
                // The pin is an estimate, not a doorstep — say so on the bubble itself rather
                // than only once the detail is opened. Uses the accuracy the sender's device
                // reported for this fix (see accuracyNote).
                if (hasCoord && !ended) {
                    Text(
                        accuracyNote(fix?.acc ?: ref.acc.takeIf { it > 0 }),
                        style = VoiidFont.rounded(10), color = VoiidColor.textSecondary, maxLines = 1,
                    )
                }
            }
            // Inline Stop on MY own live bubble while it is still running.
            if (isLive && message.isMine && engine.isMineActive(ref.shareId) && !ended) {
                Text(
                    "Stop", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.error,
                    modifier = Modifier.clickable { ref.shareId?.let { engine.stopShareUi(it) } },
                )
            }
        }
    }
}

private fun minutesLeft(expiresAt: Long?, now: Long): String {
    val ms = (expiresAt ?: now) - now
    val mins = (ms / 60000L).coerceAtLeast(0)
    return if (mins >= 60) "${mins / 60}h ${mins % 60}m" else "${mins}m"
}
