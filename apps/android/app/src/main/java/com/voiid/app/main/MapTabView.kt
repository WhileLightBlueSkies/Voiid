package com.voiid.app.main

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.rememberCameraPositionState
import com.voiid.app.BuildConfig
import com.voiid.app.model.ChatStore
import com.voiid.app.model.MapContact
import com.voiid.app.model.MapStore
import com.voiid.app.model.MapSubject
import com.voiid.app.model.MapSubjectState
import com.voiid.app.model.MapVisibility
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.VoiidPrimaryButton
import com.voiid.app.ui.components.VoiidToggle
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.delay

/**
 * Feature (B) — The Map. A Snapchat-Map-style surface showing the contacts who have explicitly
 * chosen to be visible to YOU, plus the controls for who can see you (docs/LOCATION.md §7-§8).
 *
 * The safety posture is visible in the layout, not buried in a setting:
 *  - First ever open is a full-screen explainer: Browse only vs Choose who can see me. Default
 *    is to appear to no one; there is no "share with everyone".
 *  - A persistent, unmissable pill states your visibility at all times ("Visible to N" on accent,
 *    "Ghost Mode — hidden from everyone" on grey). Ghost is one tap and is a hard local gate.
 *  - A missing/misconfigured Google Maps key degrades to [MapUnavailableCard] + a coordinate
 *    list, never a silent grey grid or a crash.
 */
@Composable
fun MapTabView(map: MapStore, chat: ChatStore) {
    val context = LocalContext.current
    val visibility by map.visibility.collectAsState()
    val audience by map.audience.collectAsState()
    val subjectsMap by map.subjects.collectAsState()
    val onboarded by map.onboarded.collectAsState()

    val subjects = subjectsMap.values.toList()
    val onMap = subjects.filter { it.isOnMap }
    val offMap = subjects.filter { !it.isOnMap }

    // Coarse foreground presence only: start on enter, stop on leave, and re-derive subject
    // states every 30 s so "Live" decays to "Stale" without a network round-trip.
    LaunchedEffect(Unit) {
        map.onForeground()
        while (true) { delay(30_000); map.recomputeSubjects() }
    }
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose { map.onBackground() }
    }

    var showAudience by remember { mutableStateOf(false) }

    // FINE/COARSE foreground grant, requested IN CONTEXT at opt-in — never at onboarding, and
    // never bundled with ACCESS_BACKGROUND_LOCATION (the Map runs foreground-only, so it does
    // not need background at all).
    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { grants ->
        val granted = grants.values.any { it }
        if (granted) showAudience = true
    }
    val requestThenPick: () -> Unit = {
        permLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
    }

    if (!onboarded) {
        MapExplainer(
            onBrowseOnly = { map.markOnboarded() },
            onChoose = { map.markOnboarded(); requestThenPick() },
        )
        if (showAudience) {
            MapAudienceSheet(
                directConversations = chat.directConversations,
                current = audience,
                onConfirm = { picked -> map.setAudience(picked); if (picked.isNotEmpty()) map.goVisible(); showAudience = false },
                onDismiss = { showAudience = false },
            )
        }
        return
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {

        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Map", style = VoiidFont.rounded(24, FontWeight.Bold), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
            // Ghost toggle: ON = ghost (hidden). Turning OFF re-opens the picker if you have no
            // audience yet; otherwise it re-mints a fresh key and re-appears.
            Text(
                if (visibility == MapVisibility.GHOST) "Ghost" else "Visible",
                style = VoiidFont.rounded(13, FontWeight.Medium),
                color = VoiidColor.textSecondary,
            )
            Spacer(Modifier.size(10.dp))
            VoiidToggle(checked = visibility == MapVisibility.GHOST) { ghostOn ->
                if (ghostOn) map.goGhost()
                else if (audience.isEmpty()) requestThenPick() else map.goVisible()
            }
        }

        VisiblePill(
            visible = visibility == MapVisibility.VISIBLE,
            audienceCount = audience.size,
            onClick = { if (visibility == MapVisibility.VISIBLE) showAudience = true else requestThenPick() },
        )

        Box(Modifier.fillMaxWidth().weight(1f)) {
            if (BuildConfig.MAPS_CONFIGURED) {
                MapCanvas(onMap)
            } else {
                MapUnavailableCard(
                    headline = "Maps aren’t set up in this build",
                    subline = "Add MAPS_API_KEY to local.properties and rebuild — see docs/LOCATION.md. Location sharing still works: open a person below in your map app.",
                )
            }
        }

        // "Not sharing" / aged-out list beneath the map (§8). An age-out KEEPS the last position
        // in the list; an explicit stop erased it entirely and it isn't here at all.
        if (offMap.isNotEmpty()) {
            NotSharingList(offMap, context)
        }
    }

    if (showAudience) {
        MapAudienceSheet(
            directConversations = chat.directConversations,
            current = audience,
            onConfirm = { picked ->
                map.setAudience(picked)
                if (picked.isNotEmpty() && visibility == MapVisibility.GHOST) map.goVisible()
                showAudience = false
            },
            onDismiss = { showAudience = false },
        )
    }
}

/** The persistent, unmissable visibility indicator (§8). Never absent, never ambiguous. */
@Composable
private fun VisiblePill(visible: Boolean, audienceCount: Int, onClick: () -> Unit) {
    val bg = if (visible) VoiidColor.accent else Color(0xFFB8B0B4)
    val label = if (visible) {
        if (audienceCount == 1) "Visible to 1 person" else "Visible to $audienceCount people"
    } else "Ghost Mode — hidden from everyone"
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 6.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(bg)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(9.dp).clip(CircleShape).background(if (visible) VoiidColor.primary else Color(0xFF6E6670)))
        Spacer(Modifier.size(10.dp))
        Text(label, style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
        Text(if (visible) "Edit" else "Choose", style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.textPrimary)
    }
}

/**
 * The live map. Google Maps Compose. Guarded by [BuildConfig.MAPS_CONFIGURED] at the call site,
 * plus a runtime watchdog: a key restricted to the wrong package/SHA-1 renders grey tiles and
 * never fires onMapLoaded, so after 6 s of silence we swap in the unavailable card.
 */
@Composable
private fun MapCanvas(onMap: List<MapSubject>) {
    val context = LocalContext.current
    var loaded by remember { mutableStateOf(false) }
    var watchdogFired by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(6_000); if (!loaded) watchdogFired = true }

    // The "my location" layer + recenter button need a granted location permission — Google
    // Maps throws a SecurityException if enabled without it. Ghost Mode does NOT gate this:
    // seeing your OWN dot is client-side and unrelated to what you broadcast.
    val hasLocationPermission = androidx.core.content.ContextCompat.checkSelfPermission(
        context, Manifest.permission.ACCESS_FINE_LOCATION,
    ) == android.content.pm.PackageManager.PERMISSION_GRANTED ||
        androidx.core.content.ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

    val first = onMap.firstOrNull()?.fix
    val camera = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(
            first?.let { LatLng(it.lat, it.lon) } ?: LatLng(20.0, 0.0),
            if (first != null) 13f else 2f,
        )
    }

    Box(Modifier.fillMaxSize()) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = camera,
            // Snapchat-style skin: a muted, de-saturated map so the friend markers are the
            // focus, not the streets — the Google Maps parallel of iOS's `.emphasis(.muted)`.
            properties = MapProperties(
                mapType = MapType.NORMAL,
                mapStyleOptions = com.google.android.gms.maps.model.MapStyleOptions(VOIID_MAP_STYLE),
                // Your own blue dot — shown whenever we hold the permission, Ghost Mode or not.
                isMyLocationEnabled = hasLocationPermission,
            ),
            uiSettings = MapUiSettings(
                zoomControlsEnabled = false,
                mapToolbarEnabled = false,
                // Native "recenter on me" button (top-right), enabled with the location layer.
                myLocationButtonEnabled = hasLocationPermission,
            ),
            onMapLoaded = { loaded = true },
        ) {
            for (s in onMap) {
                val fix = s.fix ?: continue
                Marker(
                    state = MarkerState(position = LatLng(fix.lat, fix.lon)),
                    title = UserDirectory.displayName(s.userId),
                    snippet = if (s.state == MapSubjectState.STALE) "Last seen a while ago · may have lost signal" else "Updated recently",
                    alpha = if (s.state == MapSubjectState.STALE) 0.5f else 1f,
                )
            }
        }
        if (watchdogFired && !loaded) {
            MapUnavailableCard(
                headline = "Map failed to load",
                subline = "Check the Google Maps API key’s restrictions (package + signing SHA-1). Location sharing itself still works.",
            )
        }
    }
}

@Composable
private fun NotSharingList(offMap: List<MapSubject>, context: android.content.Context) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp)) {
        Text("Not on the map", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
        Spacer(Modifier.size(8.dp))
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 160.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            items(offMap, key = { it.userId }) { s ->
                val name = UserDirectory.displayName(s.userId)
                val sub = if (s.state == MapSubjectState.AGED_OUT) "Last seen over 8 hours ago" else "Not sharing"
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(name, style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.textPrimary)
                        Text(sub, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                    }
                    // An aged-out subject keeps a last position — offer the Open-in-Maps handoff.
                    val fix = s.fix
                    if (fix != null) {
                        Text(
                            "Open in Maps",
                            style = VoiidFont.rounded(13, FontWeight.SemiBold),
                            color = VoiidColor.primary,
                            modifier = Modifier.clickable { openInMaps(context, fix.lat, fix.lon, name) },
                        )
                    }
                }
            }
        }
    }
}

/** The first-open explainer (§8): exactly two choices, default is to appear to no one. */
@Composable
private fun MapExplainer(onBrowseOnly: () -> Unit, onChoose: () -> Unit) {
    Column(
        Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding().padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Default.LocationOn, null, tint = VoiidColor.primary, modifier = Modifier.size(48.dp))
        Spacer(Modifier.size(20.dp))
        Text("The Map", style = VoiidFont.rounded(26, FontWeight.Bold), color = VoiidColor.textPrimary)
        Spacer(Modifier.size(12.dp))
        Text(
            "You appear to no one until you choose individual people. Voiid’s servers know that a share exists and when it ends — they never know where you are. Your location is end-to-end encrypted.",
            style = VoiidFont.rounded(14),
            color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 8.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        Spacer(Modifier.size(28.dp))
        VoiidPrimaryButton(title = "Choose who can see me", modifier = Modifier.fillMaxWidth(), onClick = onChoose)
        Spacer(Modifier.size(12.dp))
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.lg))
                .clickable(onClick = onBrowseOnly)
                .padding(vertical = 18.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("Browse only", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        }
    }
}

private fun openInMaps(context: android.content.Context, lat: Double, lon: Double, label: String) {
    val uri = android.net.Uri.parse("geo:$lat,$lon?q=$lat,$lon(${android.net.Uri.encode(label)})")
    runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, uri)) }
}

/**
 * Snapchat-style muted map skin (Google Maps style JSON). De-saturates roads, labels and
 * landscape and softens water, so the friend avatars/markers are the visual focus rather
 * than a busy street map. The parallel of iOS MapKit's `.emphasis(.muted)`.
 */
private const val VOIID_MAP_STYLE: String = """
[
  {"elementType":"geometry","stylers":[{"saturation":-70},{"lightness":10}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#8a8a8f"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#f5f5f7"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#e9e9ec"}]},
  {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#e2e2e6"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#dcdce0"}]},
  {"featureType":"road","elementType":"labels","stylers":[{"visibility":"simplified"}]},
  {"featureType":"landscape","elementType":"geometry","stylers":[{"color":"#f2f2f4"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#cfe3ec"},{"saturation":-40}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"visibility":"off"}]}
]
"""
