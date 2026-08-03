package com.voiid.app.main

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Headset
import androidx.compose.material.icons.filled.PhoneInTalk
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
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
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.voiid.app.net.CallManager
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.delay
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer

/**
 * 1:1 voice/video call UI backed by the real WebRTC engine ([CallManager]).
 * The call-type picker starts a real outgoing call; on-screen state, the timer,
 * mute/speaker/camera controls and the video renderers are all wired to live call state.
 *
 * Group calls are OUT OF SCOPE for v1 (see CallManager) — this UI renders 1:1 only.
 */

enum class CallKind { VOICE, VIDEO }

/** What the call-type picker needs to dial a real 1:1 call. */
data class CallRequest(
    val title: String,
    val isGroup: Boolean,
    val members: List<com.voiid.app.model.VMember>,   // kept for source compat; unused in 1:1
    val photoName: String?,
    val kind: CallKind,
    val conversationId: String = "",
    val peerUserId: String? = null,
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

// MARK: - Full-screen call overlay (driven by CallManager state)

/**
 * The single call surface RootTabView shows whenever [CallManager.state] is non-null.
 * Branches between the incoming ring UI and the active/outgoing in-call UI.
 */
@Composable
fun CallOverlay(state: CallManager.CallState) {
    if (state.incoming && state.phase == CallManager.Phase.RINGING_IN) {
        IncomingCallUi(state)
    } else {
        InCallUi(state)
    }
}

@Composable
private fun IncomingCallUi(state: CallManager.CallState) {
    val haptics = LocalVoiidHaptics.current
    val isVideo = state.kind == CallKind.VIDEO
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(VoiidColor.primary, Color.Black)))) {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(64.dp))
            Text(
                if (isVideo) "Incoming video call" else "Incoming voice call",
                style = VoiidFont.rounded(15), color = Color.White.copy(alpha = 0.85f),
            )
            Spacer(Modifier.height(24.dp))
            Box(
                Modifier.size(140.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.15f))
                    .border(3.dp, Color.White.copy(alpha = 0.6f), CircleShape),
                contentAlignment = Alignment.Center,
            ) { VoiidAvatar(size = 140.dp, modifier = Modifier.clip(CircleShape)) }
            Spacer(Modifier.height(20.dp))
            Text(state.peerName, style = VoiidFont.rounded(26, FontWeight.Bold), color = Color.White)

            Spacer(Modifier.weight(1f))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(
                        Modifier.size(72.dp).clip(CircleShape).background(VoiidColor.error)
                            .softClickable { haptics.rigid(); CallManager.decline() },
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Default.CallEnd, "Decline", tint = Color.White, modifier = Modifier.size(30.dp)) }
                    Text("Decline", style = VoiidFont.rounded(13), color = Color.White)
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(
                        Modifier.size(72.dp).clip(CircleShape).background(VoiidColor.success)
                            .softClickable { haptics.tap(); CallManager.accept() },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            if (isVideo) Icons.Default.Videocam else Icons.Default.Call,
                            "Accept", tint = Color.White, modifier = Modifier.size(30.dp),
                        )
                    }
                    Text("Accept", style = VoiidFont.rounded(13), color = Color.White)
                }
            }
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun InCallUi(state: CallManager.CallState) {
    val haptics = LocalVoiidHaptics.current
    val isVideo = state.kind == CallKind.VIDEO

    // Live timer derived from the real connection time.
    var seconds by remember { mutableIntStateOf(0) }
    LaunchedEffect(state.connectedAtMs) {
        val start = state.connectedAtMs
        if (start == null) { seconds = 0; return@LaunchedEffect }
        while (true) {
            seconds = ((System.currentTimeMillis() - start) / 1000).toInt()
            delay(500)
        }
    }

    // Priority matters: a reconnecting call is the thing the user needs told about, and a held
    // call is silent on purpose — both must beat the running timer, which otherwise ticks along
    // implying everything is fine.
    val statusText = when {
        state.phase == CallManager.Phase.ENDED -> "Call ended"
        state.reconnecting -> "Reconnecting…"
        state.onHold -> "On hold"
        state.peerOnHold -> "${state.peerName} put you on hold"
        state.phase == CallManager.Phase.RINGING_OUT -> if (isVideo) "Ringing — Video" else "Ringing…"
        state.phase == CallManager.Phase.RINGING_IN -> "Incoming…"
        state.phase == CallManager.Phase.CONNECTING -> "Connecting…"
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

    // A PiP window is a few hundred pixels wide: every piece of chrome must go, leaving only
    // full-bleed remote video. Mute/hang-up remain reachable as PiP RemoteActions.
    val inPip by rememberIsInPipMode()

    Box(Modifier.fillMaxSize().then(if (inPip) Modifier.background(Color.Black) else bgModifier)) {

        // Remote video fills the screen once frames arrive. Deliberately kept in the
        // composition whenever we're in PiP even if `hasRemoteVideo` briefly flaps — tearing
        // the renderer out mid-PiP would leave an empty black window.
        if (isVideo && (state.hasRemoteVideo || inPip)) {
            RemoteVideoSurface(Modifier.fillMaxSize())
        }

        if (inPip) return@Box

        Column(Modifier.fillMaxSize().statusBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(48.dp))
            Text(state.peerName, style = VoiidFont.rounded(24, FontWeight.Bold), color = titleColor)
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (state.reconnecting) PulsingDot()
                Text(statusText, style = VoiidFont.rounded(14), color = statusColor)
            }

            val waiting by CallManager.waiting.collectAsState()
            waiting?.let { CallWaitingBanner(it, haptics) }

            Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                if (isVideo) VideoCenter(state) else VoiceCenter()
            }

            CallControls(
                isVideo = isVideo, muted = state.muted, speaker = state.speaker, videoOn = state.videoEnabled,
                onHold = state.onHold,
                canHold = state.phase == CallManager.Phase.CONNECTED || state.phase == CallManager.Phase.CONNECTING,
                onMute = { haptics.tap(); CallManager.toggleMute() },
                onSpeaker = { haptics.tap(); CallManager.toggleSpeaker() },
                onVideo = { haptics.tap(); CallManager.toggleVideo() },
                onFlip = { haptics.tap(); CallManager.switchCamera() },
                onToggleHold = { haptics.tap(); CallManager.toggleHold() },
                onEnd = { haptics.rigid(); CallManager.hangup() },
            )
            Spacer(Modifier.height(48.dp))
        }
    }
}

/**
 * The remote-video surface. Beyond rendering it feeds PiP two things:
 * - its window bounds, used as `setSourceRectHint` so the enter-PiP animation is seamless;
 * - the decoded frame size, so the PiP window tracks the real video aspect ratio live.
 */
@Composable
private fun RemoteVideoSurface(modifier: Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val renderer = remember {
        makeRenderer(context, mirror = false, events = RemoteFrameEvents)
    }
    DisposableEffect(renderer) {
        CallManager.setRemoteRenderer(renderer)
        onDispose {
            CallPipState.setRemoteVideoBounds(null)
            CallManager.detachRenderer(renderer, remote = true)
        }
    }
    AndroidView(
        factory = { renderer },
        modifier = modifier.onGloballyPositioned { coords ->
            val b = coords.boundsInWindow()
            if (b.width > 0f && b.height > 0f) {
                CallPipState.setRemoteVideoBounds(
                    android.graphics.Rect(
                        b.left.toInt(), b.top.toInt(), b.right.toInt(), b.bottom.toInt(),
                    ),
                )
            }
        },
    )
}

/** Publishes remote frame geometry so PiP can match the real video aspect. */
private object RemoteFrameEvents : RendererCommon.RendererEvents {
    override fun onFirstFrameRendered() {}
    override fun onFrameResolutionChanged(videoWidth: Int, videoHeight: Int, rotation: Int) {
        CallPipState.setRemoteVideoSize(videoWidth, videoHeight, rotation)
    }
}

@Composable
private fun VoiceCenter() {
    Box(
        Modifier.size(160.dp).clip(CircleShape).background(VoiidColor.fieldFill)
            .border(3.dp, VoiidColor.accent, CircleShape),
        contentAlignment = Alignment.Center,
    ) { VoiidAvatar(size = 160.dp, modifier = Modifier.clip(CircleShape)) }
}

@Composable
private fun VideoCenter(state: CallManager.CallState) {
    Box(Modifier.fillMaxSize()) {
        // Local self-preview (bottom-right).
        Box(
            Modifier
                .align(Alignment.BottomEnd)
                .padding(24.dp)
                .size(width = 110.dp, height = 150.dp)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.primary.copy(alpha = 0.5f)),
            contentAlignment = Alignment.Center,
        ) {
            if (state.videoEnabled) {
                LocalVideoSurface(Modifier.fillMaxSize().clip(RoundedCornerShape(VoiidRadius.lg)))
            } else {
                Icon(Icons.Default.VideocamOff, null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(30.dp))
            }
        }
    }
}

/** Self-preview surface; detached + released when the call UI leaves the composition. */
@Composable
private fun LocalVideoSurface(modifier: Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val renderer = remember { makeRenderer(context, mirror = true) }
    DisposableEffect(renderer) {
        CallManager.setLocalRenderer(renderer)
        onDispose { CallManager.detachRenderer(renderer, remote = false) }
    }
    AndroidView(factory = { renderer }, modifier = modifier)
}

/** Build + init a SurfaceViewRenderer bound to the shared EGL context. */
private fun makeRenderer(
    context: android.content.Context,
    mirror: Boolean,
    events: RendererCommon.RendererEvents? = null,
): SurfaceViewRenderer =
    SurfaceViewRenderer(context).apply {
        init(CallManager.eglBaseContext, events)
        setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
        setEnableHardwareScaler(true)
        setMirror(mirror)
    }

/**
 * A slow amber pulse next to "Reconnecting…". Deliberately subtle: the call may well recover
 * within a second, and a loud alarm for something that usually self-heals trains users to
 * distrust it. It is there so a frozen call reads as *recovering*, not dead.
 */
@Composable
private fun PulsingDot() {
    val transition = rememberInfiniteTransition(label = "reconnecting")
    val alpha by transition.animateFloat(
        initialValue = 0.25f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(750), RepeatMode.Reverse),
        label = "reconnectingAlpha",
    )
    Box(Modifier.size(8.dp).clip(CircleShape).background(VoiidColor.warning.copy(alpha = alpha)))
}

/**
 * A second call is ringing while this one is up. Shown in-call as well as in the notification,
 * because the user is most likely staring at this screen when it happens.
 */
@Composable
private fun CallWaitingBanner(
    call: CallManager.WaitingCall,
    haptics: com.voiid.app.ui.components.VoiidHaptics,
) {
    Column(
        Modifier
            .padding(horizontal = 20.dp, vertical = 12.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "${call.peerName} is calling",
            style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary,
        )
        Text(
            "Answering will end your current call.",
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                "Decline",
                style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.error,
                modifier = Modifier.softClickable { haptics.rigid(); CallManager.declineWaiting() },
            )
            Text(
                "End & answer",
                style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.primary,
                modifier = Modifier.softClickable { haptics.tap(); CallManager.acceptWaiting() },
            )
        }
    }
}

@Composable
private fun CallControls(
    isVideo: Boolean,
    muted: Boolean,
    speaker: Boolean,
    videoOn: Boolean,
    onHold: Boolean,
    canHold: Boolean,
    onMute: () -> Unit,
    onSpeaker: () -> Unit,
    onVideo: () -> Unit,
    onFlip: () -> Unit,
    onToggleHold: () -> Unit,
    onEnd: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(24.dp)) {
        Ctrl(if (muted) Icons.Default.MicOff else Icons.Default.Mic, muted, isVideo, onMute)
        if (canHold) {
            Ctrl(if (onHold) Icons.Default.PlayArrow else Icons.Default.Pause, onHold, isVideo, onToggleHold)
        }
        if (isVideo) {
            Ctrl(if (videoOn) Icons.Default.Videocam else Icons.Default.VideocamOff, !videoOn, isVideo, onVideo)
            Ctrl(Icons.Default.Cameraswitch, false, isVideo, onFlip)
        }
        // Audio-output control on EVERY call, voice AND video — a video call needs to reach a
        // Bluetooth headset just as much as a voice call.
        //
        // A PICKER when there is something to pick, a toggle when there is not. The routing
        // has always CHOSEN a device (Bluetooth > wired > speaker > earpiece), but it never
        // told the user what was available — so connecting a headset silently moved the call
        // and there was no way to pull it back to the phone, or to pick between two headsets.
        // Above two routes this becomes a menu with the live one checked; with only
        // earpiece + speaker it stays the plain speaker toggle it always was. Mirrors iOS
        // `audioRouteControl`.
        AudioRouteControl(speaker = speaker, isVideo = isVideo, onToggleSpeaker = onSpeaker)
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

/**
 * Audio-output control: a route menu when more than earpiece + speaker exist, otherwise the
 * plain speaker toggle. Port of iOS `CallScreen.audioRouteControl`.
 */
@Composable
private fun AudioRouteControl(speaker: Boolean, isVideo: Boolean, onToggleSpeaker: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    var menuOpen by remember { mutableStateOf(false) }

    // Re-read on every open rather than holding a snapshot: a headset connected mid-call must
    // appear, and one that walked out of range must not linger in the list.
    var routes by remember { mutableStateOf(CallManager.availableAudioRoutes()) }
    val current = remember(menuOpen, speaker) { CallManager.currentAudioRoute() }

    if (routes.size > 2) {
        Box {
            Ctrl(routeIcon(current), current !is com.voiid.app.net.CallManager.AudioRoute.Earpiece, isVideo) {
                routes = CallManager.availableAudioRoutes()
                haptics.tap()
                menuOpen = true
            }
            DropdownMenu(
                expanded = menuOpen,
                onDismissRequest = { menuOpen = false },
                containerColor = VoiidColor.surfaceCard,
            ) {
                routes.forEach { route ->
                    val selected = route.id == current.id
                    DropdownMenuItem(
                        text = {
                            Text(
                                route.label,
                                style = VoiidFont.rounded(15, if (selected) FontWeight.SemiBold else FontWeight.Normal),
                                color = VoiidColor.textPrimary,
                            )
                        },
                        onClick = {
                            menuOpen = false
                            haptics.tap()
                            CallManager.selectAudioRoute(route)
                        },
                        leadingIcon = {
                            Icon(
                                if (selected) Icons.Default.Check else routeIcon(route),
                                null,
                                tint = if (selected) VoiidColor.primary else VoiidColor.textSecondary,
                            )
                        },
                    )
                }
            }
        }
    } else {
        Ctrl(Icons.AutoMirrored.Filled.VolumeUp, speaker, isVideo, onToggleSpeaker)
    }
}

private fun routeIcon(route: com.voiid.app.net.CallManager.AudioRoute): ImageVector = when (route) {
    is com.voiid.app.net.CallManager.AudioRoute.Bluetooth -> Icons.Default.Bluetooth
    is com.voiid.app.net.CallManager.AudioRoute.Wired -> Icons.Default.Headset
    com.voiid.app.net.CallManager.AudioRoute.Speaker -> Icons.AutoMirrored.Filled.VolumeUp
    com.voiid.app.net.CallManager.AudioRoute.Earpiece -> Icons.Default.PhoneInTalk
}
