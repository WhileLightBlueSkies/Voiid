package com.voiid.app.main

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.VMember
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.delay

/**
 * Call type picker + simulated Voice/Video call screens (1:1 + group) —
 * port of iOS `CallScreens.swift`. Dummy: Ringing → Connected with a running timer.
 */

enum class CallKind { VOICE, VIDEO }

/** What a call needs to render (works for 1:1 and group). */
data class CallRequest(
    val title: String,
    val isGroup: Boolean,
    val members: List<VMember>,   // for group grids; empty for 1:1
    val photoName: String?,
    val kind: CallKind,
)

// MARK: - Voice/Video picker (small branded sheet)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CallTypeSheet(title: String, onPick: (CallKind) -> Unit, onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background) {
        Column(
            Modifier.fillMaxWidth().padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            Text("Call $title", style = VoiidFont.rounded(18, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                CallTypeCard("Voice", Icons.Default.Call, Modifier.weight(1f)) { haptics.tap(); onPick(CallKind.VOICE) }
                CallTypeCard("Video", Icons.Default.Videocam, Modifier.weight(1f)) { haptics.tap(); onPick(CallKind.VIDEO) }
            }
            Text(
                "Cancel", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
                modifier = Modifier.softClickable { onDismiss() },
            )
        }
    }
}

@Composable
private fun CallTypeCard(label: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .softClickable(onClick = onClick)
            .padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            Modifier.size(64.dp).clip(CircleShape).background(VoiidColor.primary),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(30.dp)) }
        Text(label, style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.textPrimary)
    }
}

// MARK: - Call screen (voice + video, 1:1 + group)

@Composable
fun CallScreen(request: CallRequest, onEnd: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    var connected by remember { mutableStateOf(false) }
    var seconds by remember { mutableIntStateOf(0) }
    var muted by remember { mutableStateOf(false) }
    var speaker by remember { mutableStateOf(false) }
    var videoOn by remember { mutableStateOf(true) }
    val isVideo = request.kind == CallKind.VIDEO

    LaunchedEffect(Unit) {
        delay(2000)
        connected = true
        while (true) { delay(1000); seconds += 1 }
    }

    val statusText = when {
        !connected -> if (isVideo) "Ringing — Video" else "Ringing…"
        else -> "%02d:%02d".format(seconds / 60, seconds % 60)
    }
    val onDark = isVideo
    val titleColor = if (onDark) Color.White else VoiidColor.textPrimary
    val statusColor = if (onDark) Color.White.copy(alpha = 0.85f) else VoiidColor.textSecondary

    val bgModifier = if (isVideo) {
        Modifier.background(Brush.verticalGradient(listOf(VoiidColor.primary, Color.Black)))
    } else {
        Modifier.background(VoiidColor.background)
    }

    Box(Modifier.fillMaxSize().then(bgModifier)) {
        Column(Modifier.fillMaxSize().statusBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(48.dp))

            // Group call banner card
            if (request.isGroup) {
                Row(
                    Modifier
                        .clip(CircleShape)
                        .background(if (isVideo) Color.White.copy(alpha = 0.15f) else VoiidColor.surfaceCard)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(
                        Modifier.size(30.dp).clip(CircleShape).background(VoiidColor.primary),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            if (isVideo) Icons.Default.Videocam else Icons.Default.Call,
                            null, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(14.dp),
                        )
                    }
                    Column {
                        Text(
                            if (isVideo) "Group video call" else "Group voice call",
                            style = VoiidFont.rounded(13, FontWeight.SemiBold),
                            color = if (isVideo) Color.White else VoiidColor.textPrimary,
                        )
                        Text(
                            "${request.members.size} participants",
                            style = VoiidFont.rounded(11),
                            color = if (isVideo) Color.White.copy(alpha = 0.8f) else VoiidColor.textSecondary,
                        )
                    }
                }
                Spacer(Modifier.height(16.dp))
            }

            // Title + status
            Text(request.title, style = VoiidFont.rounded(24, FontWeight.Bold), color = titleColor)
            Spacer(Modifier.height(6.dp))
            Text(statusText, style = VoiidFont.rounded(14), color = statusColor)

            // Center content: avatar (voice) or video grid/self
            Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                if (isVideo) VideoCenter(request, videoOn) else VoiceCenter(request)
            }

            // Controls
            CallControls(
                isVideo = isVideo, muted = muted, speaker = speaker, videoOn = videoOn,
                onMute = { haptics.tap(); muted = !muted },
                onSpeaker = { haptics.tap(); speaker = !speaker },
                onVideo = { haptics.tap(); videoOn = !videoOn },
                onFlip = { haptics.tap() },
                onEnd = { haptics.rigid(); onEnd() },
            )
            Spacer(Modifier.height(48.dp))
        }
    }
}

@Composable
private fun VoiceCenter(request: CallRequest) {
    if (request.isGroup) {
        ParticipantGrid(request.members, video = false)
    } else {
        Box(
            Modifier.size(160.dp).clip(CircleShape).background(VoiidColor.fieldFill)
                .border(3.dp, VoiidColor.accent, CircleShape),
            contentAlignment = Alignment.Center,
        ) { VoiidAvatar(size = 160.dp, modifier = Modifier.clip(CircleShape)) }
    }
}

@Composable
private fun VideoCenter(request: CallRequest, videoOn: Boolean) {
    if (request.isGroup) {
        ParticipantGrid(request.members, video = true)
    } else {
        Box(Modifier.fillMaxSize()) {
            // self preview (bottom-right)
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(24.dp)
                    .size(width = 110.dp, height = 150.dp)
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.primary.copy(alpha = 0.5f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (videoOn) Icons.Default.Person else Icons.Default.VideocamOff,
                    null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(30.dp),
                )
            }
        }
    }
}

@Composable
private fun ParticipantGrid(members: List<VMember>, video: Boolean) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(2),
        contentPadding = PaddingValues(horizontal = 24.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(members, key = { it.id }) { m ->
            if (video) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .aspectRatio(0.8f)
                        .clip(RoundedCornerShape(VoiidRadius.lg))
                        .background(VoiidColor.primary.copy(alpha = 0.5f)),
                    contentAlignment = Alignment.Center,
                ) {
                    VoiidAvatar(size = 56.dp, modifier = Modifier.clip(CircleShape))
                    Text(
                        if (m.isYou) "You" else m.name,
                        style = VoiidFont.rounded(10, FontWeight.Medium), color = Color.White,
                        modifier = Modifier
                            .align(Alignment.BottomStart)
                            .padding(6.dp)
                            .clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.4f))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            } else {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    VoiidAvatar(size = 72.dp, modifier = Modifier.clip(CircleShape))
                    Text(if (m.isYou) "You" else m.name, style = VoiidFont.rounded(12), color = VoiidColor.textPrimary)
                }
            }
        }
    }
}

@Composable
private fun CallControls(
    isVideo: Boolean,
    muted: Boolean,
    speaker: Boolean,
    videoOn: Boolean,
    onMute: () -> Unit,
    onSpeaker: () -> Unit,
    onVideo: () -> Unit,
    onFlip: () -> Unit,
    onEnd: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(32.dp)) {
        Ctrl(if (muted) Icons.Default.MicOff else Icons.Default.Mic, muted, isVideo, onMute)
        if (isVideo) {
            Ctrl(if (videoOn) Icons.Default.Videocam else Icons.Default.VideocamOff, !videoOn, isVideo, onVideo)
            Ctrl(Icons.Default.Cameraswitch, false, isVideo, onFlip)
        } else {
            Ctrl(Icons.AutoMirrored.Filled.VolumeUp, speaker, isVideo, onSpeaker)
        }
        // End
        Box(
            Modifier.size(64.dp).clip(CircleShape).background(VoiidColor.error).softClickable(onClick = onEnd),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Default.CallEnd, "End call", tint = Color.White, modifier = Modifier.size(26.dp)) }
    }
}

@Composable
private fun Ctrl(icon: ImageVector, active: Boolean, isVideo: Boolean, onClick: () -> Unit) {
    val fg = when {
        active -> VoiidColor.primary
        isVideo -> Color.White
        else -> VoiidColor.textPrimary
    }
    val bg = when {
        active -> VoiidColor.textOnPrimary
        isVideo -> Color.White.copy(alpha = 0.2f)
        else -> VoiidColor.surfaceCard
    }
    Box(
        Modifier.size(58.dp).clip(CircleShape).background(bg).softClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = fg, modifier = Modifier.size(22.dp)) }
}
