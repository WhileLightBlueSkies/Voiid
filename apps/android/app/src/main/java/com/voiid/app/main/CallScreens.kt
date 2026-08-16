package com.voiid.app.main

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
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
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Headset
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.PhoneInTalk
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.voiid.app.net.CallManager
import com.voiid.app.net.ConferenceManager
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.VoiidMenu
import com.voiid.app.ui.components.VoiidMenuItem
import com.voiid.app.ui.components.reduceMotionEnabled
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
    val minimized by CallManager.minimized.collectAsState()
    when {
        state.incoming && state.phase == CallManager.Phase.RINGING_IN -> IncomingCallUi(state)
        // MINIMIZED: a compact pill instead of the full screen, so the rest of the app is
        // usable during a call. Never for a RINGING call — a call you have not answered must
        // not be dismissable into a pill.
        minimized -> MinimizedCallPill(state)
        else -> InCallUi(state)
    }
}

/**
 * The minimized call: a circular, draggable bubble.
 *
 * WHY A CIRCLE, NOT A PILL. The pill was a full-width bar under the status bar — it covered
 * whatever the app was showing there, and its shape said "banner", which is the language of
 * something you dismiss rather than something you tap to return to. A round bubble reads as a
 * live object, takes a fraction of the space, and is the shape every messenger uses for
 * exactly this state.
 *
 * WHY IT DRAGS. A fixed position always ends up over the one control you need. It snaps to
 * the nearest side after a drag so it can never be left half off-screen, and stays vertically
 * where you put it.
 *
 * WHY THIS EXISTS AT ALL. Android had no way to leave a call screen without ENDING the call,
 * so answering meant losing the whole app until it was over — you could not check the address
 * someone was reading to you. Video calls go to system PiP instead (see the minimize button);
 * this is the voice-call path, and the fallback when PiP is unavailable.
 */
@Composable
private fun MinimizedCallPill(state: CallManager.CallState) {
    val haptics = LocalVoiidHaptics.current
    val density = LocalDensity.current
    var offset by remember { mutableStateOf(Offset.Zero) }
    var container by remember { mutableStateOf(IntSize.Zero) }
    var onRight by remember { mutableStateOf(true) }
    var dragging by remember { mutableStateOf(false) }

    val bubble = 64.dp
    val margin = 12.dp
    val dx by animateFloatAsState(offset.x, spring(dampingRatio = 0.8f), label = "bubbleX")
    val dy by animateFloatAsState(offset.y, spring(dampingRatio = 0.8f), label = "bubbleY")
    val scale by animateFloatAsState(if (dragging) 1.06f else 1f, spring(), label = "bubbleScale")

    Box(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .onSizeChanged { container = it },
    ) {
        Box(
            Modifier
                .align(if (onRight) Alignment.TopEnd else Alignment.TopStart)
                .padding(margin)
                .graphicsLayer {
                    translationX = dx
                    translationY = dy
                    scaleX = scale
                    scaleY = scale
                }
                .size(bubble)
                .clip(CircleShape)
                .background(VoiidColor.success)
                .pointerInput(container) {
                    detectDragGestures(
                        onDragStart = { dragging = true; haptics.tap() },
                        onDragEnd = {
                            // Snap to the nearer SIDE, keeping the vertical position — the
                            // user chose that height, and resetting it would undo the drag
                            // they just made.
                            val half = with(density) { (bubble / 2 + margin).toPx() }
                            val originX = if (onRight) container.width - half else half
                            val landedRight = (originX + offset.x) > container.width / 2f
                            if (landedRight != onRight) haptics.selection()
                            onRight = landedRight
                            offset = Offset(0f, offset.y)
                            dragging = false
                        },
                    ) { change, amount ->
                        change.consume()
                        offset += amount
                    }
                }
                .softClickable { haptics.tap(); CallManager.expand() },
            contentAlignment = Alignment.Center,
        ) {
            // A VIDEO call keeps its video IN the bubble. Minimizing a video call to an icon
            // throws away the thing you minimized it to keep watching — and since system PiP
            // is not an option here (it leaves the app entirely), the bubble has to carry it.
            if (state.kind == CallKind.VIDEO && state.hasRemoteVideo) {
                RemoteVideoSurface(Modifier.fillMaxSize().clip(CircleShape))
                // The timer sits ON the video, on a scrim, so it stays legible over any frame.
                Box(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .background(Color.Black.copy(alpha = 0.45f))
                        .padding(vertical = 2.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        callTimer(state),
                        style = VoiidFont.rounded(10, FontWeight.SemiBold),
                        color = Color.White,
                        maxLines = 1,
                    )
                }
            } else {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        if (state.kind == CallKind.VIDEO) Icons.Default.Videocam else Icons.Default.Call,
                        "Return to call", tint = Color.White, modifier = Modifier.size(20.dp),
                    )
                    // The timer, not the name: at 64dp a name truncates to nothing useful,
                    // and "how long have I been on this call" is the fact worth surfacing.
                    Text(
                        callTimer(state),
                        style = VoiidFont.rounded(11, FontWeight.SemiBold),
                        color = Color.White,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

/** mm:ss since connect, or the phase while it is not yet up. */
@Composable
private fun callTimer(state: CallManager.CallState): String {
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(state.connectedAtMs) {
        while (state.connectedAtMs != null) {
            now = System.currentTimeMillis()
            kotlinx.coroutines.delay(1000)
        }
    }
    val started = state.connectedAtMs ?: return "Connecting…"
    val s = ((now - started) / 1000).coerceAtLeast(0)
    return "%d:%02d".format(s / 60, s % 60)
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
            // THE CALLER'S REAL FACE, not the wordmark. `VoiidAvatar` is the bundled
            // placeholder — so the one screen where knowing WHO is calling matters most
            // showed a logo. `ProfileAvatar` resolves the peer's photo through the shared
            // cache and falls back to their initials, which is at least a person.
            //
            // A slow pulse on the ring: a ringing call is a live event, and a completely
            // static screen reads as a screenshot. Deliberately gentle — this is on screen
            // while a phone is buzzing, and anything faster competes for attention.
            val ringPulse = rememberInfiniteTransition(label = "ring")
            val ringScale by ringPulse.animateFloat(
                1f, 1.06f,
                infiniteRepeatable(tween(1200, easing = FastOutSlowInEasing), RepeatMode.Reverse),
                label = "ringScale",
            )
            Box(contentAlignment = Alignment.Center) {
                Box(
                    Modifier
                        .size(160.dp)
                        .graphicsLayer { scaleX = ringScale; scaleY = ringScale }
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.10f)),
                )
                ProfileAvatar(
                    photoUrl = UserDirectory.photoUrl(state.peerUserId),
                    name = state.peerName,
                    size = 140.dp,
                    modifier = Modifier
                        .clip(CircleShape)
                        .border(3.dp, Color.White.copy(alpha = 0.6f), CircleShape),
                )
            }
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
                        // textOnPrimary, which FLIPS with the theme, not a fixed white. The
                        // status fills invert — dark in light mode, LIGHT in dark mode — so
                        // white measured 2.74:1 on the dark error fill, under the 3:1 a glyph
                        // needs. Flipped it is 4.60 and 6.82. Same fix as the swipe actions.
                    ) { Icon(Icons.Default.CallEnd, "Decline", tint = VoiidColor.textOnPrimary, modifier = Modifier.size(30.dp)) }
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
                            // Flips with the theme — white was 2.08:1 on the dark success
                            // fill, the worst pairing on the screen, on the button people are
                            // trying to hit in a hurry.
                            "Accept", tint = VoiidColor.textOnPrimary, modifier = Modifier.size(30.dp),
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
    val context = androidx.compose.ui.platform.LocalContext.current
    var showAddPerson by remember { mutableStateOf(false) }
    // The conference roster is drawn over the call surface when there is more than one other
    // participant — see ConferenceViews.kt for why it is deliberately spare.
    val conference by ConferenceManager.state.collectAsState()

    val reduceMotion = reduceMotionEnabled()
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
        // "CALLING…" UNTIL THEIR PHONE ACTUALLY RINGS. This said "Ringing…" from the instant
        // you tapped call, which claims something we do not know: the callee may be offline,
        // out of coverage, or their push may not have landed. `peerRinging` flips only when
        // their device sends `call_ringing` — the same moment our ringback tone starts — so
        // the word and the sound arrive together and both are true.
        state.phase == CallManager.Phase.RINGING_OUT ->
            if (!state.peerRinging) "Calling…"
            else if (isVideo) "Ringing — Video" else "Ringing…"
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

        // MINIMIZE — voice AND video. The call keeps running; only the full screen goes away.
        //
        // Android had no way off a call screen except ending the call, so answering meant
        // losing the whole app until it was over. Offered once the call is real (not while
        // ringing — a call you have not answered must not be dismissable) and never in PiP,
        // which is already a minimized state.
        if (state.phase == CallManager.Phase.CONNECTED || state.phase == CallManager.Phase.CONNECTING) {
            Box(
                Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(12.dp)
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(
                        if (isVideo) Color.White.copy(alpha = 0.20f) else VoiidColor.surfaceCard,
                    )
                    // ALWAYS the in-app bubble, never system PiP.
                    //
                    // I routed video minimize to PiP last commit and that was wrong: Android
                    // PiP shrinks the WHOLE ACTIVITY into a corner and shows the launcher
                    // behind it. So "minimize" left the app entirely — the exact opposite of
                    // what the button is for, which is to keep using Voiid during a call.
                    //
                    // PiP still exists and is still correct for its own case: pressing
                    // Home/Recents during a video call (onUserLeaveHint), where the user has
                    // genuinely chosen to leave. The video bubble below keeps the remote
                    // frame visible WITHIN the app.
                    .softClickable { haptics.tap(); CallManager.minimize() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.KeyboardArrowDown, "Minimize call",
                    tint = if (isVideo) Color.White else VoiidColor.textPrimary,
                    modifier = Modifier.size(22.dp),
                )
            }
        }

        Column(Modifier.fillMaxSize().statusBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(48.dp))
            Text(state.peerName, style = VoiidFont.rounded(24, FontWeight.Bold), color = titleColor)
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (state.reconnecting) PulsingDot()
                // TABULAR DIGITS ON THE ONE THING THAT TICKS. The duration re-renders every
                // second, and in a proportional face a 1 is narrower than a 0 — so "01:11"
                // and "01:00" are different widths and the whole centred line shifts sideways
                // once a second, for the entire call. It is the most-looked-at element on the
                // screen and it was the only one that jittered. Mirrors iOS.
                Text(
                    statusText,
                    style = VoiidFont.rounded(14).copy(
                        fontFeatureSettings = "tnum",
                    ),
                    color = statusColor,
                )
            }

            val waiting by CallManager.waiting.collectAsState()
            waiting?.let { CallWaitingBanner(it, haptics) }

            Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                if (isVideo) VideoCenter(state) else VoiceCenter(state, reduceMotion)
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
                // Offered only on a CONNECTED 1:1 that is not already a conference. Escalating
                // a call that has not connected has nothing to escalate.
                onAddPerson = if (state.phase == CallManager.Phase.CONNECTED && !ConferenceManager.isActive) {
                    { haptics.tap(); showAddPerson = true }
                } else null,
            )
            Spacer(Modifier.height(48.dp))
        }

        // Who is on the call, once it is more than two people.
        if ((conference?.roster?.size ?: 0) > 1) {
            ConferenceRoster(
                Modifier.align(Alignment.TopStart).statusBarsPadding().padding(16.dp),
            )
        }

        if (showAddPerson) {
            androidx.compose.ui.window.Dialog(onDismissRequest = { showAddPerson = false }) {
                ConferenceInviteSheet(
                    chat = androidx.lifecycle.viewmodel.compose.viewModel(),
                    excludeUserId = state.peerUserId,
                    onPick = { invitee ->
                        showAddPerson = false
                        ConferenceManager.addPerson(
                            context = context,
                            callId = state.callId,
                            kind = state.kind,
                            peerUserId = state.peerUserId,
                            inviteeUserId = invitee,
                        )
                    },
                    onDismiss = { showAddPerson = false },
                )
            }
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

    // Re-assert when the remote track actually arrives. `hasRemoteVideo` flips at exactly
    // that moment, and the renderer usually registered BEFORE it — so without this the
    // attach ran against a null track and the frame never appeared. Same race as the local
    // surface; addSink on an attached sink is a no-op.
    val remoteState by CallManager.state.collectAsState()
    LaunchedEffect(remoteState?.hasRemoteVideo, remoteState?.phase) {
        CallManager.setRemoteRenderer(renderer)
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

/**
 * The voice-call centre: the person you are talking to.
 *
 * THE PEER'S REAL FACE, not the wordmark. This took no parameters and rendered
 * [VoiidAvatar] — a bundled placeholder that draws the literal word "voiid" — so the one
 * screen where knowing who you are talking to matters most showed a logo for every real
 * contact. The INCOMING screen was fixed to use [ProfileAvatar]; this one, which is on screen
 * for the entire duration of every outgoing and connected voice call, was missed.
 *
 * The pulse runs only while the call is NOT yet connected: ringing is a live event and a
 * static screen reads as a screenshot, but once someone answers the movement has nothing left
 * to say and becomes decoration on a screen people leave open for minutes. Mirrors iOS.
 */
@Composable
private fun VoiceCenter(state: CallManager.CallState, reduceMotion: Boolean) {
    val ringing = state.phase != CallManager.Phase.CONNECTED
    val pulse = rememberInfiniteTransition(label = "voiceRing")
    val scale by pulse.animateFloat(
        0.94f, 1.06f,
        infiniteRepeatable(tween(1200, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "voiceRingScale",
    )
    Box(contentAlignment = Alignment.Center) {
        if (ringing && !reduceMotion) {
            Box(
                Modifier
                    .size(190.dp)
                    .graphicsLayer { scaleX = scale; scaleY = scale }
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.10f)),
            )
        }
        Box(
            Modifier.size(160.dp).clip(CircleShape).background(VoiidColor.fieldFill)
                .border(3.dp, VoiidColor.accent, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            ProfileAvatar(
                photoUrl = UserDirectory.photoUrl(state.peerUserId),
                name = state.peerName,
                size = 160.dp,
                modifier = Modifier.clip(CircleShape),
            )
        }
    }
}

@Composable
private fun VideoCenter(state: CallManager.CallState) {
    Box(Modifier.fillMaxSize()) {
        // A DRAGGABLE self-preview that snaps to whichever corner you release it near, with
        // the camera flip on the tile itself. Mirrors iOS `SelfPreview`.
        //
        // WHY IT DRAGS. A fixed corner always covers something eventually — the other
        // person's face drifts, or a caption sits under it. Snapping to corners rather than
        // free-floating keeps the layout predictable: it cannot be left half off-screen or
        // dead-centre over the remote video.
        //
        // WHY THE FLIP IS HERE. It acts on the self-view, which was at the opposite end of
        // the display from the button that controlled it — and it was a sixth control in a
        // row that already overflowed. On the tile, the control and its result are the same
        // object.
        SelfPreview(state = state)
    }
}

/** Self-preview surface; detached + released when the call UI leaves the composition. */
@Composable
private fun LocalVideoSurface(modifier: Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val renderer = remember { makeRenderer(context, mirror = true) }
    val state by CallManager.state.collectAsState()

    DisposableEffect(renderer) {
        CallManager.setLocalRenderer(renderer)
        onDispose { CallManager.detachRenderer(renderer, remote = false) }
    }

    // RE-ASSERT WHEN THE CALL PHASE CHANGES.
    //
    // The local track is created inside doAnswer() on the ANSWERING side — after this
    // composable has already registered its renderer, so the attach in setLocalRenderer saw
    // no track and did nothing. CallService now attaches idempotently from both sides, and
    // this covers the remaining window: keying on `phase` re-runs the attach the moment the
    // call moves to CONNECTING/CONNECTED, which is exactly when the track appears.
    //
    // Cheap: addSink on an already-attached sink is a no-op.
    LaunchedEffect(state?.phase, state?.videoEnabled) {
        CallManager.setLocalRenderer(renderer)
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
    /**
     * Non-null only when this call can become a conference. HIDDEN rather than disabled when
     * it cannot: the row is width-constrained (see the overflow note below), so a permanently
     * dead control would cost space the other buttons need.
     */
    onAddPerson: (() -> Unit)? = null,
) {
    // EVENLY DISTRIBUTED, not fixed-spacing.
    //
    // THE OVERFLOW. A video call showed mic, hold, camera, flip, route and end — six 64dp
    // controls with 24dp gaps, needing ~500dp of width that a normal phone does not have, so
    // the end button ran off the right edge. `weight(1f)` lets them share whatever width
    // exists, at any control count, on any device.
    //
    // The camera FLIP is gone from this row: it now lives ON the self-preview, where the
    // thing it affects is the thing you are looking at. Mirrors iOS.
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceEvenly,
    ) {
        Ctrl(if (muted) Icons.Default.MicOff else Icons.Default.Mic, muted, isVideo, onMute)
        if (canHold) {
            Ctrl(if (onHold) Icons.Default.PlayArrow else Icons.Default.Pause, onHold, isVideo, onToggleHold)
        }
        if (isVideo) {
            Ctrl(if (videoOn) Icons.Default.Videocam else Icons.Default.VideocamOff, !videoOn, isVideo, onVideo)
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
        // ADD SOMEONE — turns this 1:1 into a conference. Present only when the engine says
        // escalation is possible; see the parameter's note for why it is hidden, not disabled.
        onAddPerson?.let { Ctrl(Icons.Default.PersonAdd, false, isVideo, it) }
        Box(
            Modifier.size(64.dp).clip(CircleShape).background(VoiidColor.error).softClickable(onClick = onEnd),
            contentAlignment = Alignment.Center,
            // Flips with the theme: white measured 2.74:1 on the dark error fill, under the
            // 3:1 a glyph needs. Same fix as decline above, and as the group call screen.
        ) { Icon(Icons.Default.CallEnd, "End call", tint = VoiidColor.textOnPrimary, modifier = Modifier.size(26.dp)) }
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

    // POLLED, not read once at composition.
    //
    // THIS IS WHY THE PICKER NEVER APPEARED. `remember { availableAudioRoutes() }` evaluates
    // exactly once — when the call screen first composes. At that moment the audio session is
    // often not yet in MODE_IN_COMMUNICATION, so `availableCommunicationDevices` returns only
    // the built-ins, the list has 2 entries, and the control collapses to a plain speaker
    // toggle for the whole call. Connecting a headset afterwards changed nothing, because
    // nothing re-read.
    //
    // A 2-second poll is the honest fix here: AudioManager has no Compose-friendly device
    // callback, `registerAudioDeviceCallback` needs a Handler and its own lifecycle, and a
    // headset appearing 2s late is imperceptible next to one that never appears at all.
    var routes by remember { mutableStateOf(CallManager.availableAudioRoutes()) }
    var current by remember { mutableStateOf(CallManager.currentAudioRoute()) }
    LaunchedEffect(Unit) {
        while (true) {
            routes = CallManager.availableAudioRoutes()
            current = CallManager.currentAudioRoute()
            kotlinx.coroutines.delay(2_000)
        }
    }
    // Also re-read the moment the speaker flag changes, so the checkmark moves with the tap
    // rather than up to 2s later.
    LaunchedEffect(speaker) { current = CallManager.currentAudioRoute() }

    if (routes.size > 2) {
        Box {
            Ctrl(routeIcon(current), current !is com.voiid.app.net.CallManager.AudioRoute.Earpiece, isVideo) {
                // Refresh on open too — the poll may be up to 2s stale.
                routes = CallManager.availableAudioRoutes()
                current = CallManager.currentAudioRoute()
                haptics.tap()
                menuOpen = true
            }
            VoiidMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                routes.forEach { route ->
                    // A one-of-many choice, so `selected` drives the tick and the weight —
                    // see VoiidMenuItem's note on why that is distinct from a list of actions.
                    VoiidMenuItem(
                        route.label,
                        routeIcon(route),
                        selected = route.id == current.id,
                    ) {
                        menuOpen = false
                        haptics.tap()
                        CallManager.selectAudioRoute(route)
                    }
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

/** Which corner the self-view is parked in. */
private enum class PreviewCorner { TOP_START, TOP_END, BOTTOM_START, BOTTOM_END }

@Composable
private fun BoxScope.SelfPreview(state: CallManager.CallState) {
    val haptics = LocalVoiidHaptics.current
    val density = LocalDensity.current
    var corner by remember { mutableStateOf(PreviewCorner.TOP_END) }
    var drag by remember { mutableStateOf(Offset.Zero) }
    var dragging by remember { mutableStateOf(false) }
    var container by remember { mutableStateOf(IntSize.Zero) }

    val tileW = 104.dp
    val tileH = 140.dp
    val margin = 12.dp

    val alignment = when (corner) {
        PreviewCorner.TOP_START -> Alignment.TopStart
        PreviewCorner.TOP_END -> Alignment.TopEnd
        PreviewCorner.BOTTOM_START -> Alignment.BottomStart
        PreviewCorner.BOTTOM_END -> Alignment.BottomEnd
    }
    // Animated so a corner change glides rather than teleports.
    val dx by animateFloatAsState(drag.x, spring(dampingRatio = 0.8f), label = "selfX")
    val dy by animateFloatAsState(drag.y, spring(dampingRatio = 0.8f), label = "selfY")
    val scale by animateFloatAsState(if (dragging) 1.04f else 1f, spring(), label = "selfScale")

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { container = it },
    ) {
        Box(
            Modifier
                .align(alignment)
                .padding(margin)
                .graphicsLayer {
                    translationX = dx
                    translationY = dy
                    scaleX = scale
                    scaleY = scale
                }
                .size(width = tileW, height = tileH)
                .clip(RoundedCornerShape(18.dp))
                .background(VoiidColor.primary.copy(alpha = 0.5f))
                // A hairline so a dark preview against a dark remote frame still has an edge.
                .border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(18.dp))
                .pointerInput(container) {
                    detectDragGestures(
                        onDragStart = { dragging = true; haptics.tap() },
                        onDragEnd = {
                            // Snap from where the tile ACTUALLY is — its corner plus the
                            // drag — not from the finger, so a small nudge does not fling it
                            // across the screen.
                            val halfW = with(density) { (tileW / 2 + margin).toPx() }
                            val halfH = with(density) { (tileH / 2 + margin).toPx() }
                            val originX = if (corner == PreviewCorner.TOP_START || corner == PreviewCorner.BOTTOM_START) {
                                halfW
                            } else {
                                container.width - halfW
                            }
                            val originY = if (corner == PreviewCorner.TOP_START || corner == PreviewCorner.TOP_END) {
                                halfH
                            } else {
                                container.height - halfH
                            }
                            val landedX = originX + drag.x
                            val landedY = originY + drag.y
                            val left = landedX < container.width / 2f
                            val top = landedY < container.height / 2f
                            val target = when {
                                top && left -> PreviewCorner.TOP_START
                                top -> PreviewCorner.TOP_END
                                left -> PreviewCorner.BOTTOM_START
                                else -> PreviewCorner.BOTTOM_END
                            }
                            if (target != corner) haptics.selection()
                            corner = target
                            drag = Offset.Zero
                            dragging = false
                        },
                    ) { change, amount ->
                        change.consume()
                        drag += amount
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            if (state.videoEnabled) {
                LocalVideoSurface(Modifier.fillMaxSize().clip(RoundedCornerShape(18.dp)))
            } else {
                Icon(Icons.Default.VideocamOff, null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(26.dp))
            }

            // Camera flip, ON the preview.
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(6.dp)
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.45f))
                    .softClickable { haptics.tap(); CallManager.switchCamera() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.Cameraswitch, "Flip camera",
                    tint = Color.White, modifier = Modifier.size(15.dp),
                )
            }
        }
    }
}
