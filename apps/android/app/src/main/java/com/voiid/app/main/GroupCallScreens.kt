package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.voiid.app.net.GroupCallManager
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.delay
import livekit.org.webrtc.RendererCommon
import livekit.org.webrtc.SurfaceViewRenderer

/**
 * GROUP call UI, backed by [GroupCallManager] (LiveKit SFU + MLS-derived E2EE).
 *
 * Deliberately separate from [CallOverlay], which drives 1:1 calls on the Stream WebRTC
 * stack. The two use DIFFERENT, non-interchangeable renderer classes:
 * 1:1 uses `org.webrtc.SurfaceViewRenderer`, this uses `livekit.org.webrtc.SurfaceViewRenderer`.
 * Keeping the surfaces apart is what lets both WebRTC builds coexist safely.
 */

// MARK: - Overlay

@Composable
fun GroupCallOverlay(state: GroupCallManager.GroupCallState) {
    val haptics = LocalVoiidHaptics.current

    // A failed/blocked call shows its reason instead of an empty grid.
    if (state.error != null) {
        GroupCallMessage(title = state.title, message = state.error)
        return
    }

    var seconds by remember { mutableIntStateOf(0) }
    LaunchedEffect(state.connectedAtMs) {
        val start = state.connectedAtMs
        if (start == null) { seconds = 0; return@LaunchedEffect }
        while (true) {
            seconds = ((System.currentTimeMillis() - start) / 1000).toInt()
            delay(500)
        }
    }

    val statusText = when (state.phase) {
        GroupCallManager.Phase.CONNECTING -> "Connecting…"
        GroupCallManager.Phase.RECONNECTING -> "Reconnecting…"
        GroupCallManager.Phase.CONNECTED -> "%02d:%02d".format(seconds / 60, seconds % 60)
        GroupCallManager.Phase.ENDED -> "Call ended"
    }
    val isVideo = state.kind == CallKind.VIDEO

    Box(
        Modifier.fillMaxSize()
            .background(Brush.verticalGradient(listOf(VoiidColor.primary, Color.Black))),
    ) {
        Column(Modifier.fillMaxSize().statusBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(24.dp))
            Text(
                state.title,
                style = VoiidFont.rounded(22, FontWeight.Bold),
                color = Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(statusText, style = VoiidFont.rounded(14), color = Color.White.copy(alpha = 0.85f))
                Text("·", style = VoiidFont.rounded(14), color = Color.White.copy(alpha = 0.5f))
                Text(
                    "${state.participants.size}",
                    style = VoiidFont.rounded(14), color = Color.White.copy(alpha = 0.85f),
                )
                // E2EE is the product promise — state it plainly, and flag it if ever absent.
                Icon(
                    if (state.e2ee) Icons.Default.Lock else Icons.Default.LockOpen,
                    contentDescription = if (state.e2ee) "End-to-end encrypted" else "Not encrypted",
                    tint = if (state.e2ee) Color.White.copy(alpha = 0.75f) else VoiidColor.error,
                    modifier = Modifier.size(13.dp),
                )
            }

            Box(Modifier.fillMaxWidth().weight(1f).padding(horizontal = 12.dp, vertical = 12.dp)) {
                if (state.participants.isEmpty()) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            "Waiting for others to join…",
                            style = VoiidFont.rounded(15), color = Color.White.copy(alpha = 0.7f),
                        )
                    }
                } else {
                    ParticipantGrid(state.participants)
                }
            }

            GroupCallControls(
                isVideo = isVideo,
                muted = state.muted,
                videoOn = state.videoEnabled,
                onMute = { haptics.tap(); GroupCallManager.toggleMute() },
                onVideo = { haptics.tap(); GroupCallManager.toggleVideo() },
                onFlip = { haptics.tap(); GroupCallManager.switchCamera() },
                onLeave = { haptics.rigid(); GroupCallManager.leave() },
            )
            Spacer(Modifier.height(40.dp))
        }
    }
}

/** Shown when a call can't start (SFU unconfigured, keys not synced, connect failure). */
@Composable
private fun GroupCallMessage(title: String, message: String) {
    Box(
        Modifier.fillMaxSize().background(VoiidColor.background),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(title, style = VoiidFont.rounded(20, FontWeight.Bold), color = VoiidColor.textPrimary)
            Text(
                message,
                style = VoiidFont.rounded(15),
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

// MARK: - Adaptive grid

/**
 * Tile layout by participant count:
 *  - 1  → one full-bleed tile
 *  - 2  → two stacked halves
 *  - 3–4 → 2×2
 *  - 5+ → scrolling 2-column grid (3 columns once it gets genuinely crowded)
 */
@Composable
private fun ParticipantGrid(participants: List<GroupCallManager.Participant>) {
    val n = participants.size
    when {
        n == 1 -> ParticipantTile(participants[0], Modifier.fillMaxSize())

        n == 2 -> Column(
            Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(TILE_GAP),
        ) {
            participants.forEach { p ->
                ParticipantTile(p, Modifier.fillMaxWidth().weight(1f))
            }
        }

        n <= 4 -> Column(
            Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(TILE_GAP),
        ) {
            participants.chunked(2).forEach { rowItems ->
                Row(
                    Modifier.fillMaxWidth().weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(TILE_GAP),
                ) {
                    rowItems.forEach { p -> ParticipantTile(p, Modifier.weight(1f).fillMaxSize()) }
                    // Keep a lone tile in a row at half width rather than stretching it.
                    if (rowItems.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }

        else -> LazyVerticalGrid(
            columns = GridCells.Fixed(if (n > 9) 3 else 2),
            modifier = Modifier.fillMaxSize(),
            horizontalArrangement = Arrangement.spacedBy(TILE_GAP),
            verticalArrangement = Arrangement.spacedBy(TILE_GAP),
        ) {
            items(participants, key = { it.identity }) { p ->
                ParticipantTile(p, Modifier.fillMaxWidth().aspectRatio(0.85f))
            }
        }
    }
}

private val TILE_GAP = 8.dp

@Composable
private fun ParticipantTile(p: GroupCallManager.Participant, modifier: Modifier) {
    val shape = RoundedCornerShape(VoiidRadius.lg)
    Box(
        modifier
            .clip(shape)
            .background(Color.White.copy(alpha = 0.08f))
            // Speaking indicator: a live accent ring around the active speaker's tile.
            .then(
                if (p.speaking) Modifier.border(2.5.dp, VoiidColor.accent, shape)
                else Modifier.border(1.dp, Color.White.copy(alpha = 0.12f), shape),
            ),
    ) {
        val track = p.videoTrack
        if (p.cameraOn && track != null) {
            GroupVideoSurface(track, mirror = p.isLocal, modifier = Modifier.fillMaxSize())
        } else {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                VoiidAvatar(size = 64.dp, modifier = Modifier.clip(CircleShape))
            }
        }

        // Name + per-tile mute/video state.
        Row(
            Modifier
                .align(Alignment.BottomStart)
                .padding(8.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(Color.Black.copy(alpha = 0.45f))
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (p.micMuted) {
                Icon(
                    Icons.Default.MicOff, "Muted",
                    tint = VoiidColor.error, modifier = Modifier.size(12.dp),
                )
            }
            if (!p.cameraOn) {
                Icon(
                    Icons.Default.VideocamOff, "Camera off",
                    tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(12.dp),
                )
            }
            Text(
                if (p.isLocal) "You" else p.name,
                style = VoiidFont.rounded(12, FontWeight.Medium),
                color = Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * A LiveKit video surface. Attaches on entry and DETACHES on dispose — a renderer left
 * attached to a track that outlives it leaks the surface and can crash on release.
 */
@Composable
private fun GroupVideoSurface(
    track: io.livekit.android.room.track.VideoTrack,
    mirror: Boolean,
    modifier: Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val renderer = remember {
        SurfaceViewRenderer(context).apply {
            // init() goes through the Room so the renderer binds to LiveKit's EGL context,
            // NOT CallManager's — they are different WebRTC builds.
            GroupCallManager.initRenderer(this)
            setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
            setEnableHardwareScaler(true)
            setMirror(mirror)
        }
    }
    DisposableEffect(renderer, track) {
        runCatching { track.addRenderer(renderer) }
        onDispose {
            runCatching { track.removeRenderer(renderer) }
            runCatching { renderer.release() }
        }
    }
    AndroidView(factory = { renderer }, modifier = modifier)
}

// MARK: - Controls

@Composable
private fun GroupCallControls(
    isVideo: Boolean,
    muted: Boolean,
    videoOn: Boolean,
    onMute: () -> Unit,
    onVideo: () -> Unit,
    onFlip: () -> Unit,
    onLeave: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(24.dp)) {
        GroupCtrl(if (muted) Icons.Default.MicOff else Icons.Default.Mic, muted, onMute)
        GroupCtrl(if (videoOn) Icons.Default.Videocam else Icons.Default.VideocamOff, !videoOn, onVideo)
        if (isVideo) GroupCtrl(Icons.Default.Cameraswitch, false, onFlip)
        Box(
            Modifier.size(64.dp).clip(CircleShape).background(VoiidColor.error).softClickable(onClick = onLeave),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Default.CallEnd, "Leave call", tint = Color.White, modifier = Modifier.size(26.dp)) }
    }
}

@Composable
private fun GroupCtrl(icon: ImageVector, active: Boolean, onClick: () -> Unit) {
    val fg = if (active) VoiidColor.primary else Color.White
    val bg = if (active) VoiidColor.textOnPrimary else Color.White.copy(alpha = 0.2f)
    Box(
        Modifier.size(56.dp).clip(CircleShape).background(bg).softClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = fg, modifier = Modifier.size(22.dp)) }
}
