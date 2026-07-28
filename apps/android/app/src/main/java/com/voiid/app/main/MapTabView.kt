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
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Search
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
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.rememberCameraPositionState
import com.voiid.app.BuildConfig
import com.voiid.app.model.ChatStore
import com.voiid.app.model.LiveShareView
import com.voiid.app.model.MapContact
import com.voiid.app.model.MapFix
import com.voiid.app.model.MapStore
import com.voiid.app.model.MapSubject
import com.voiid.app.model.MapSubjectState
import com.voiid.app.model.MapVisibility
import com.voiid.app.model.ShareState
import com.voiid.app.net.LocationShareEngine
import com.voiid.app.net.MapPlaceSearch
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
fun MapTabView(map: MapStore, chat: ChatStore, onOpenChatWithUser: ((String) -> Unit)? = null) {
    val context = LocalContext.current
    val visibility by map.visibility.collectAsState()
    val audience by map.audience.collectAsState()
    val subjectsMap by map.subjects.collectAsState()
    val onboarded by map.onboarded.collectAsState()
    val shareError by map.lastError.collectAsState()
    val waiting by map.waitingSenders.collectAsState()

    // 1 s tick so a conversation share's freshness (and its LIVE→STALE decay) is re-derived
    // without waiting for the 30 s presence recompute below. No network, no new wakeups.
    var now by remember { androidx.compose.runtime.mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) { delay(1_000); now = System.currentTimeMillis() }
    }

    // Two sources, one map (docs/LOCATION.md §5 + §7):
    //   (B) presence — ambient, coarse, 5 min / 250 m. Everyone who chose to be visible to us.
    //   (A) conversation live shares — someone actively sharing WITH ME from a chat, at
    //       10–15 s cadence. Their fixes are already decrypted and in memory for the bubble;
    //       drawing them here publishes nothing new and changes no cadence for anyone.
    // Dedupe by userId with the CONVERSATION share winning: it is strictly fresher than the
    // ambient one, so a friend who is live-sharing with you moves in near-real-time instead of
    // being pinned to their last 5-minute presence fix.
    val liveSubjects = LocationShareEngine.inboundViews.values
        .mapNotNull { it.asMapSubject(now) }
    val subjects = (subjectsMap.values.associateBy { it.userId } + liveSubjects.associateBy { it.userId })
        .values.toList()
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
    /** Which face the audience sheet opens on. Reset to CHOOSE by every entry point that is
     *  picking an audience, so a previous MANAGE opening can never leak into it. */
    var audienceMode by remember { mutableStateOf(MapAudienceMode.CHOOSE) }

    // ---- place search (Feature 4) -------------------------------------------------------
    var searchQuery by remember { mutableStateOf("") }
    var suggestions by remember { mutableStateOf<List<MapPlaceSearch.Suggestion>>(emptyList()) }
    var pickedSuggestion by remember { mutableStateOf<MapPlaceSearch.Suggestion?>(null) }
    var selectedPlace by remember { mutableStateOf<MapPlaceSearch.Resolved?>(null) }
    // ONE token per "type, refine, pick" interaction keeps autocomplete in the per-session
    // billing tier; a new one is minted after each resolve (see MapPlaceSearch).
    var sessionToken by remember { mutableStateOf(MapPlaceSearch.newSession()) }

    // Debounced so a fast typist produces one request per pause, not one per keystroke. An
    // empty query issues nothing at all — an idle Map tab makes no Places calls.
    LaunchedEffect(searchQuery) {
        val q = searchQuery.trim()
        if (q.isEmpty()) { suggestions = emptyList(); return@LaunchedEffect }
        if (pickedSuggestion?.title == q) return@LaunchedEffect   // don't re-search what we just picked
        delay(250)
        suggestions = MapPlaceSearch.predictions(context, q, sessionToken)
    }

    LaunchedEffect(pickedSuggestion) {
        val picked = pickedSuggestion ?: return@LaunchedEffect
        suggestions = emptyList()
        selectedPlace = MapPlaceSearch.fetchPlace(context, picked.placeId, sessionToken)
        sessionToken = MapPlaceSearch.newSession()   // the fetch closed the billed session
        pickedSuggestion = null
    }

    // FINE/COARSE foreground grant, requested IN CONTEXT at opt-in — never at onboarding, and
    // never bundled with ACCESS_BACKGROUND_LOCATION (the Map runs foreground-only, so it does
    // not need background at all).
    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { grants ->
        val granted = grants.values.any { it }
        // This path is always "I want to pick who sees me" — force the chooser.
        if (granted) { audienceMode = MapAudienceMode.CHOOSE; showAudience = true }
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

        // Going visible can fail (offline / server down). The pill below reflects the CONFIRMED
        // state, so without this the toggle would just spring back to Ghost with no explanation.
        shareError?.let { msg ->
            Text(
                msg,
                style = VoiidFont.rounded(13, FontWeight.Medium),
                color = VoiidColor.error,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp)
                    .padding(bottom = 8.dp)
                    .clickable { map.clearError() },
            )
        }

        VisiblePill(
            visible = visibility == MapVisibility.VISIBLE,
            audienceCount = audience.size,
            // Already visible → MANAGE (who can see me now, remove, stop all). Not yet visible
            // → the permission prompt, then the scope CHOOSER.
            onClick = {
                if (visibility == MapVisibility.VISIBLE) {
                    audienceMode = MapAudienceMode.MANAGE
                    showAudience = true
                } else {
                    requestThenPick()
                }
            },
        )

        // Place search (Feature 4). Gated with everything else behind MAPS_CONFIGURED: a build
        // with no Maps key shows no search field at all, and the unavailable card below is
        // unchanged.
        if (BuildConfig.MAPS_CONFIGURED) {
            MapSearchBar(
                query = searchQuery,
                onQueryChange = { searchQuery = it },
                suggestions = suggestions,
                onPick = { s -> pickedSuggestion = s; searchQuery = s.title },
                onClear = { searchQuery = ""; suggestions = emptyList(); selectedPlace = null },
            )
        }

        Box(Modifier.fillMaxWidth().weight(1f)) {
            if (BuildConfig.MAPS_CONFIGURED) {
                MapCanvas(onMap, now, onOpenChatWithUser, selectedPlace) { selectedPlace = null }
            } else {
                MapUnavailableCard(
                    headline = "Maps aren’t set up in this build",
                    subline = "Add MAPS_API_KEY to local.properties and rebuild — see docs/LOCATION.md. Location sharing still works: open a person below in your map app.",
                )
            }
        }

        // "Not sharing" / aged-out list beneath the map (§8). An age-out KEEPS the last position
        // in the list; an explicit stop erased it entirely and it isn't here at all.
        //
        // `waitingFor` are contacts who handed us a map_key but whose first fix hasn't landed
        // yet. Without them the map read as completely empty while friends were in fact
        // sharing — the position only exists after a live fix decrypts in this process.
        val onMapIds = onMap.map { it.userId }.toSet()
        val offMapIds = offMap.map { it.userId }.toSet()
        val waitingFor = waiting.filter { it !in onMapIds && it !in offMapIds }.sorted()
        if (offMap.isNotEmpty() || waitingFor.isNotEmpty()) {
            NotSharingList(offMap, waitingFor, context)
        }
    }

    if (showAudience) {
        MapAudienceSheet(
            directConversations = chat.directConversations,
            current = audience,
            mode = audienceMode,
            isVisible = visibility == MapVisibility.VISIBLE,
            onConfirm = { picked ->
                map.setAudience(picked)
                if (picked.isNotEmpty() && visibility == MapVisibility.GHOST) map.goVisible()
                showAudience = false
            },
            // setAudience() (which removeFromAudience routes through) revokes and rekeys, so the
            // sheet stays open and simply re-renders the shorter list from the audience flow.
            onRemove = { userId -> map.removeFromAudience(userId) },
            onStopAll = { map.killSwitch(); showAudience = false },
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
private fun MapCanvas(
    onMap: List<MapSubject>,
    now: Long,
    onOpenChat: ((String) -> Unit)? = null,
    place: MapPlaceSearch.Resolved? = null,
    onDismissPlace: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    var loaded by remember { mutableStateOf(false) }
    var watchdogFired by remember { mutableStateOf(false) }
    /** userId whose card is open — a tap on a face, dismissed by tapping the map. */
    var selected by remember { mutableStateOf<String?>(null) }
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

    // Fly to a place the moment it resolves.
    LaunchedEffect(place) {
        place?.let {
            camera.animate(
                com.google.android.gms.maps.CameraUpdateFactory.newLatLngZoom(LatLng(it.lat, it.lon), 16f),
                800,
            )
        }
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
            onMapClick = { selected = null },   // tap the map to dismiss an open contact card
        ) {
            for (s in onMap) {
                val fix = s.fix ?: continue
                // A FACE, not the stock red pin: the same marker language as iOS's
                // `contactMarker` and the live-location detail. The ring colour carries the
                // LIVE/STALE state; a photo-less friend falls back to initials on a stable
                // colour, never a generic pin that makes two people indistinguishable.
                MarkerComposable(
                    keys = arrayOf(s.userId, s.state),
                    state = MarkerState(position = LatLng(fix.lat, fix.lon)),
                    title = UserDirectory.displayName(s.userId),
                    onClick = { selected = s.userId; false },
                ) {
                    AvatarPin(userId = s.userId, stale = s.state == MapSubjectState.STALE)
                }
            }
            // A searched place — the stock pin here is correct: it must NOT look like a person.
            place?.let {
                Marker(
                    state = MarkerState(position = LatLng(it.lat, it.lon)),
                    title = it.name,
                    snippet = it.address,
                )
            }
        }
        // A resolved place takes precedence over a contact card — it is the thing the user
        // just explicitly asked for.
        if (place != null) {
            MapPlaceCard(
                place = place,
                modifier = Modifier.align(Alignment.BottomCenter),
                onDismiss = { onDismissPlace?.invoke() },
            )
        }
        // Tapping a face opens a small card instead of the SDK's default info window (which is
        // a bare title/snippet bubble with no avatar and no way to act on it).
        else selected?.let { uid ->
            val subject = onMap.firstOrNull { it.userId == uid }
            if (subject != null) {
                MapContactCard(
                    subject = subject,
                    now = now,
                    modifier = Modifier.align(Alignment.BottomCenter),
                    onOpenChat = onOpenChat?.let { open -> { open(uid) } },
                    onDismiss = { selected = null },
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
private fun NotSharingList(
    offMap: List<MapSubject>,
    waitingFor: List<String>,
    context: android.content.Context,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp)) {
        Text("Not on the map", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
        Spacer(Modifier.size(8.dp))
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 160.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            // Sharing with us, but no fix has arrived yet. Listed FIRST — this is the state a
            // friend is in for the first few minutes after they go visible.
            items(waitingFor, key = { "waiting_$it" }) { uid ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            UserDirectory.displayName(uid),
                            style = VoiidFont.rounded(15, FontWeight.Medium),
                            color = VoiidColor.textPrimary,
                        )
                        Text("Locating…", style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                    }
                }
            }
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
            "You appear to no one until you choose a scope — everyone you’ve chatted with, just your contacts, or only people you pick. Voiid’s servers know that a share exists and when it ends — they never know where you are. Your location is end-to-end encrypted.",
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

/**
 * Project a conversation live share (A) onto the Map's subject shape (B), so both sources can
 * be drawn by one renderer (docs/LOCATION.md §5, §7).
 *
 * This publishes NOTHING and changes no cadence: the fixes are already decrypted in memory for
 * the in-chat bubble, and this only makes them visible on the Map tab too — a friend who is
 * actively live-sharing with you moves at the share's 10–15 s cadence, while everyone else
 * keeps moving at the ambient 5-minute presence cadence.
 *
 * Null once the share has ENDED (it must leave the map, same as the bubble's terminal state)
 * or before its first fix has landed (nothing to draw yet — the presence entry, if any, still
 * shows and the "waiting" list already covers this case).
 */
private fun LiveShareView.asMapSubject(now: Long): MapSubject? {
    val fix = lastFix ?: return null
    val mapped = when (state(now)) {
        ShareState.LIVE -> MapSubjectState.LIVE
        ShareState.STALE -> MapSubjectState.STALE
        ShareState.ENDED -> return null
    }
    return MapSubject(
        userId = ownerUserId,
        fix = MapFix(
            subjectUserId = ownerUserId, shareId = shareId,
            lat = fix.lat, lon = fix.lon, acc = fix.acc, seq = fix.seq, fixedAt = fix.fixedAt,
        ),
        state = mapped,
    )
}

/**
 * The card shown when you tap a friend's face on the Map. Replaces the SDK's default info
 * window, which is a bare title/snippet bubble with no avatar and nothing to act on.
 *
 * Deliberately minimal: who, how fresh their position is, and one way to reach them. No
 * address (we never reverse-geocode — docs/LOCATION.md §10) and no coordinates readout.
 */
@Composable
private fun MapContactCard(
    subject: MapSubject,
    now: Long,
    modifier: Modifier = Modifier,
    onOpenChat: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    Row(
        modifier
            .fillMaxWidth()
            .padding(16.dp)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .clickable { onDismiss() }
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        AvatarPin(userId = subject.userId, stale = subject.state == MapSubjectState.STALE, size = 46.dp)
        Column(Modifier.weight(1f)) {
            Text(
                UserDirectory.displayName(subject.userId),
                style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary, maxLines = 1,
            )
            val age = subject.fix?.let { now - it.fixedAt }
            Text(
                when {
                    subject.state == MapSubjectState.STALE -> "May have lost signal"
                    age == null -> "Location unknown"
                    age < 60_000 -> "Updated just now"
                    age < 3_600_000 -> "Updated ${age / 60_000} min ago"
                    else -> "Updated ${age / 3_600_000} h ago"
                },
                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary, maxLines = 1,
            )
            // Same honesty line as the chat bubble/detail: a Map pin is an area, not a doorstep.
            Text(
                accuracyNote(subject.fix?.acc),
                style = VoiidFont.rounded(10), color = VoiidColor.textSecondary, maxLines = 1,
            )
        }
        if (onOpenChat != null) {
            Text(
                "Open chat",
                style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.primary,
                modifier = Modifier
                    .clip(RoundedCornerShape(VoiidRadius.pill))
                    .background(VoiidColor.fieldFill)
                    .clickable { onOpenChat() }
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }
    }
}

/**
 * Map-tab place search field + autocomplete list (Feature 4). Matches the visibility pill's
 * shape so the top chrome reads as one family.
 *
 * The whole thing is only ever composed when `BuildConfig.MAPS_CONFIGURED` is true, and
 * [MapPlaceSearch] degrades to an empty suggestion list when the key lacks "Places API (New)"
 * — so the worst case is a search box that finds nothing, never an error over the map.
 */
@Composable
private fun MapSearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    suggestions: List<MapPlaceSearch.Suggestion>,
    onPick: (MapPlaceSearch.Suggestion) -> Unit,
    onClear: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
        val shape = RoundedCornerShape(VoiidRadius.pill)
        Row(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.fieldBorder, shape)
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                androidx.compose.material.icons.Icons.Default.Search, null,
                tint = VoiidColor.textSecondary, modifier = Modifier.size(18.dp),
            )
            androidx.compose.foundation.text.BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                singleLine = true,
                textStyle = VoiidFont.rounded(15).merge(
                    androidx.compose.ui.text.TextStyle(color = VoiidColor.textPrimary),
                ),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(VoiidColor.primary),
                modifier = Modifier.weight(1f),
                decorationBox = { inner ->
                    if (query.isEmpty()) {
                        Text("Search places", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                    }
                    inner()
                },
            )
            if (query.isNotEmpty()) {
                Icon(
                    androidx.compose.material.icons.Icons.Default.Close, "Clear search",
                    tint = VoiidColor.textSecondary,
                    modifier = Modifier.size(18.dp).clickable { onClear() },
                )
            }
        }

        if (suggestions.isNotEmpty()) {
            Spacer(Modifier.size(6.dp))
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.surfaceCard),
            ) {
                for (s in suggestions) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { onPick(s) }
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.Default.LocationOn, null,
                            tint = VoiidColor.primary, modifier = Modifier.size(18.dp),
                        )
                        Column(Modifier.weight(1f)) {
                            Text(
                                s.title, style = VoiidFont.rounded(14, FontWeight.Medium),
                                color = VoiidColor.textPrimary, maxLines = 1,
                            )
                            if (s.subtitle.isNotBlank()) {
                                Text(
                                    s.subtitle, style = VoiidFont.rounded(11),
                                    color = VoiidColor.textSecondary, maxLines = 1,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Bottom card for a resolved place: name, address, and the two system handoffs.
 *
 * Directions is a HANDOFF to the system maps app, never in-app routing (docs/LOCATION.md
 * §10.10) — it reuses the same [openDirections] helper the location detail uses, so there is
 * one nav intent in the codebase rather than a copy per screen.
 */
@Composable
private fun MapPlaceCard(
    place: MapPlaceSearch.Resolved,
    modifier: Modifier = Modifier,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    Column(
        modifier
            .fillMaxWidth()
            .padding(16.dp)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f)) {
                Text(
                    place.name, style = VoiidFont.rounded(16, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary, maxLines = 2,
                )
                place.address?.let {
                    Text(it, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary, maxLines = 2)
                }
            }
            Icon(
                androidx.compose.material.icons.Icons.Default.Close, "Close",
                tint = VoiidColor.textSecondary,
                modifier = Modifier.size(20.dp).clickable { onDismiss() },
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PlaceAction("Directions", Modifier.weight(1f), filled = true) {
                openDirections(context, place.lat, place.lon, place.name)
            }
            PlaceAction("Open in Maps", Modifier.weight(1f), filled = false) {
                openInMaps(context, place.lat, place.lon, place.name)
            }
        }
    }
}

@Composable
private fun PlaceAction(label: String, modifier: Modifier, filled: Boolean, onClick: () -> Unit) {
    Box(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(if (filled) VoiidColor.primary else VoiidColor.fieldFill)
            .clickable { onClick() }
            .padding(vertical = 11.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label, style = VoiidFont.rounded(14, FontWeight.SemiBold),
            color = if (filled) VoiidColor.textOnPrimary else VoiidColor.textPrimary,
        )
    }
}
