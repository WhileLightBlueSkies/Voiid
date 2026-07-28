package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Directions
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.CameraMoveStartedReason
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.rememberCameraPositionState
import com.voiid.app.BuildConfig
import com.voiid.app.model.LocationEnvelope
import com.voiid.app.model.LiveShareView
import com.voiid.app.model.ShareState
import com.voiid.app.net.ChatEngine
import com.voiid.app.net.LocationShareEngine
import com.voiid.app.store.UserDirectory
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Full-screen location detail (docs/LOCATION.md §4): the map, Open in Maps and Directions
 * handoffs. No in-app routing — we hand off to the system map app (§10.10).
 *
 * LIVE, not a snapshot. This view used to render `ref.lat/ref.lon` once, so a friend walking
 * across town stayed pinned wherever they were when you opened the sheet — the pipeline was
 * delivering fixes the whole time and only the bubble showed them. It now observes
 * [LocationShareEngine.inboundViews] (a snapshot state map, so new fixes recompose us), moves
 * the marker with a short animation rather than teleporting it, and follows with the camera
 * until you pan.
 *
 * Every sharer in the conversation is drawn on THIS one map (a group where three people are
 * sharing is one map with three faces, not three separate frozen bubbles).
 *
 * Nothing here changes cadence, encryption or the foreground service — this is presentation
 * over the existing decrypted stream.
 */
@Composable
fun LocationDetailView(ref: ChatEngine.LocationRef, conversationId: String? = null, onClose: () -> Unit) {
    val context = LocalContext.current
    BackHandler { onClose() }

    val isLive = ref.kind == LocationEnvelope.K_LIVE_START

    // 1s ticker: drives the countdown, the "updated Xs ago" line and the LIVE→STALE→ENDED
    // transition WITHOUT any network — the timer guarantee (§3) holds offline.
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(isLive) {
        if (!isLive) return@LaunchedEffect
        while (true) { kotlinx.coroutines.delay(1_000); now = System.currentTimeMillis() }
    }

    // Every live sharer in this conversation (G5). Falls back to just this share when we were
    // opened without a conversation id, and to an empty list for a static pin.
    val shares: List<LiveShareView> = when {
        !isLive -> emptyList()
        conversationId != null -> LocationShareEngine.inboundForConversation(conversationId, now)
        else -> listOfNotNull(LocationShareEngine.inbound(ref.shareId))
    }
    // The share this bubble opened, kept first so the header describes the right person.
    val primary = shares.firstOrNull { it.shareId == ref.shareId } ?: shares.firstOrNull()

    // Most current coordinate: the live fix if the stream has produced one, else the
    // coordinate the message itself carried.
    val lat = primary?.lastFix?.lat ?: ref.lat
    val lon = primary?.lastFix?.lon ?: ref.lon
    if (lat == null || lon == null) { onClose(); return }

    val state = primary?.state(now) ?: if (isLive) ShareState.ENDED else null

    Column(Modifier.fillMaxSize().background(VoiidColor.background)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Default.Close, "Close", tint = VoiidColor.textPrimary, modifier = Modifier.size(26.dp).clickable { onClose() })
            Column(Modifier.weight(1f)) {
                Text(
                    ref.label?.ifBlank { null } ?: if (isLive) "Live location" else "Location",
                    style = VoiidFont.rounded(18, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                )
                // WhatsApp's "Live until …": expiry countdown + freshness of the last fix.
                if (isLive) {
                    Text(
                        liveSubtitle(state, primary, ref.expiresAt, now),
                        style = VoiidFont.rounded(12), color = subtitleColor(state), maxLines = 1,
                    )
                }
            }
            if (isLive && state != null) LiveDot(state)
        }

        Box(Modifier.fillMaxWidth().weight(1f)) {
            if (!BuildConfig.MAPS_CONFIGURED) {
                MapUnavailableCard(Modifier.fillMaxSize(), lat, lon)
            } else {
                LiveDetailMap(shares = shares, fallback = LatLng(lat, lon), state = state, now = now)
            }
        }

        Column(
            Modifier.fillMaxWidth().background(VoiidColor.surfaceCard).navigationBarsPadding().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("%.5f, %.5f".format(lat, lon), style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.textSecondary)
            // Honesty line (docs/LOCATION.md §10): a phone GPS fix is not a pinpoint, and a
            // reader who treats it as one can walk to the wrong door. Prefer the accuracy the
            // DEVICE actually reported for this fix; fall back to a conservative typical value
            // when a sender's payload carried none.
            Text(
                accuracyNote(primary?.lastFix?.acc ?: ref.acc),
                style = VoiidFont.rounded(11), color = VoiidColor.textSecondary,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                DetailAction(Icons.Default.Map, "Open in Maps", Modifier.weight(1f)) { openInMaps(context, lat, lon, ref.label) }
                DetailAction(Icons.Default.Directions, "Directions", Modifier.weight(1f)) { openDirections(context, lat, lon, ref.label) }
            }
        }
    }
}

/**
 * The interactive map: one animated avatar marker per sharer, camera following until the user
 * takes over.
 *
 * FOLLOW RULE: we recentre on every new fix only while [userPanned] is false. The first
 * gesture-driven camera move sets it (so the map stops fighting the user's finger) and the
 * recenter FAB clears it — the WhatsApp behaviour.
 */
@Composable
private fun LiveDetailMap(
    shares: List<LiveShareView>,
    fallback: LatLng,
    state: ShareState?,
    now: Long,
) {
    val camera = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(fallback, 16f)
    }
    var userPanned by remember { mutableStateOf(false) }
    // Only a GESTURE counts as taking over; our own animateCamera calls must not disable follow.
    LaunchedEffect(camera.cameraMoveStartedReason) {
        if (camera.cameraMoveStartedReason == CameraMoveStartedReason.GESTURE) userPanned = true
    }

    // Positions we actually draw, one per sharer (falls back to the message coordinate when the
    // stream hasn't produced a fix yet).
    val points: List<Pair<LiveShareView, LatLng>> = shares.mapNotNull { s ->
        s.lastFix?.let { s to LatLng(it.lat, it.lon) }
    }
    val targets = points.map { it.second }.ifEmpty { listOf(fallback) }

    // Follow: a single sharer centres; several fit all of them in view.
    LaunchedEffect(targets, userPanned) {
        if (userPanned) return@LaunchedEffect
        if (targets.size == 1) {
            camera.animate(CameraUpdateFactory.newLatLng(targets.first()), 800)
        } else {
            val bounds = LatLngBounds.builder().apply { targets.forEach { include(it) } }.build()
            runCatching { camera.animate(CameraUpdateFactory.newLatLngBounds(bounds, 160), 800) }
        }
    }

    Box(Modifier.fillMaxSize()) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = camera,
            uiSettings = MapUiSettings(zoomControlsEnabled = false, compassEnabled = false, mapToolbarEnabled = false),
            properties = com.google.maps.android.compose.MapProperties(mapType = MapType.NORMAL),
        ) {
            if (points.isEmpty()) {
                MarkerComposable(state = MarkerState(position = fallback)) {
                    AvatarPin(userId = null, stale = state == ShareState.STALE, ended = state == ShareState.ENDED)
                }
            } else {
                for ((share, target) in points) {
                    val s = share.state(now)
                    AnimatedAvatarMarker(
                        target = target,
                        userId = share.ownerUserId,
                        stale = s == ShareState.STALE,
                        ended = s == ShareState.ENDED,
                    )
                }
            }
        }

        // Recenter: only offered once the user has taken the camera over.
        if (userPanned) {
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(16.dp)
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.surfaceCard)
                    .clickable { userPanned = false },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.MyLocation, "Recenter", tint = VoiidColor.primary, modifier = Modifier.size(22.dp))
            }
        }
    }
}

/**
 * A marker that GLIDES to each new fix instead of teleporting.
 *
 * Fixes arrive every 10–15 s, so an un-animated marker reads as a series of jumps. We
 * interpolate lat/lon over ~1 s — comfortably shorter than the cadence, so a marker always
 * settles before the next fix and never lags behind reality.
 */
@Composable
private fun AnimatedAvatarMarker(target: LatLng, userId: String?, stale: Boolean, ended: Boolean) {
    val latAnim = remember { Animatable(target.latitude.toFloat()) }
    val lonAnim = remember { Animatable(target.longitude.toFloat()) }
    LaunchedEffect(target) {
        val spec = tween<Float>(durationMillis = 1_000, easing = LinearEasing)
        coroutineScope {
            launch { latAnim.animateTo(target.latitude.toFloat(), spec) }
            launch { lonAnim.animateTo(target.longitude.toFloat(), spec) }
        }
    }
    val pos = LatLng(latAnim.value.toDouble(), lonAnim.value.toDouble())
    MarkerComposable(
        keys = arrayOf(userId ?: "", stale, ended),
        state = MarkerState(position = pos),
        title = userId?.let { UserDirectory.displayName(it) },
    ) {
        AvatarPin(userId = userId, stale = stale, ended = ended)
    }
}

@Composable
private fun LiveDot(state: ShareState) {
    Box(
        Modifier.size(10.dp).clip(CircleShape).background(
            when (state) {
                ShareState.LIVE -> VoiidColor.primary
                ShareState.STALE -> VoiidColor.textSecondary
                ShareState.ENDED -> VoiidColor.textSecondary.copy(alpha = 0.5f)
            },
        ),
    )
}

/** "Live · ends in 43 min · updated 4s ago" — the freshness WhatsApp shows on its detail map. */
private fun liveSubtitle(state: ShareState?, share: LiveShareView?, expiresAt: Long?, now: Long): String {
    if (state == ShareState.ENDED) return "Live location ended"
    val parts = mutableListOf<String>()
    val ends = share?.expiresAt ?: expiresAt
    if (ends != null && ends > now) parts.add("ends in ${humanDuration(ends - now)}")
    val fixedAt = share?.lastFix?.fixedAt
    parts.add(
        when {
            state == ShareState.STALE -> "may have lost signal"
            fixedAt != null -> "updated ${humanAge(now - fixedAt)}"
            else -> "waiting for first fix"
        },
    )
    return parts.joinToString(" · ")
}

private fun subtitleColor(state: ShareState?) =
    if (state == ShareState.STALE || state == ShareState.ENDED) VoiidColor.textSecondary else VoiidColor.primary

private fun humanDuration(ms: Long): String {
    val mins = (ms / 60_000L).coerceAtLeast(0)
    return if (mins >= 60) "${mins / 60}h ${mins % 60}m" else "${mins}m"
}

private fun humanAge(ms: Long): String {
    val secs = (ms / 1000L).coerceAtLeast(0)
    return when {
        secs < 10 -> "just now"
        secs < 60 -> "${secs}s ago"
        secs < 3600 -> "${secs / 60}m ago"
        else -> "${secs / 3600}h ago"
    }
}

/**
 * "Accurate to about N m" — the one place this sentence is produced, so the bubble, the
 * full-screen detail and the map card cannot drift apart.
 *
 * WHY IT EXISTS: a marker drawn as a single point reads as an exact doorstep, and it is not.
 * A phone fix is typically 10–30 m in the open and much worse indoors or between tall
 * buildings, so a viewer navigating to a friend needs to know the pin has a radius. We show
 * the accuracy the SENDER'S DEVICE reported for that fix rather than a fixed number, because
 * inventing a figure would be its own dishonesty; [FALLBACK_ACCURACY_M] covers only the case
 * where a payload carried no accuracy at all.
 *
 * Note this is separate from the coordinate rounding we apply (5 dp ≈ 1 m) — that is a privacy
 * measure and is far finer than the fix's own error, so it never dominates this number.
 */
private const val FALLBACK_ACCURACY_M = 30

fun accuracyNote(acc: Double?): String {
    val metres = acc?.takeIf { it.isFinite() && it > 0 }?.toInt() ?: FALLBACK_ACCURACY_M
    // Round to something a human reads as an estimate, never a false precision like "37 m".
    val rounded = when {
        metres <= 10 -> 10
        metres <= 30 -> ((metres + 4) / 5) * 5
        metres <= 100 -> ((metres + 9) / 10) * 10
        else -> ((metres + 49) / 50) * 50
    }
    return "Accurate to about $rounded m — GPS is approximate"
}

/** Directions handoff — shared with the map tab's place card, so the intent lives in one place. */
fun openDirections(context: android.content.Context, lat: Double, lon: Double, label: String?) {
    runCatching {
        context.startActivity(
            android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("google.navigation:q=$lat,$lon"))
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }.onFailure { openInMaps(context, lat, lon, label) }
}

@Composable
private fun DetailAction(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, modifier: Modifier, onClick: () -> Unit) {
    Row(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.fieldFill)
            .clickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(18.dp))
        Text(label, style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Spacer(Modifier.height(0.dp))
    }
}
