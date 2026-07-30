package com.voiid.app.main

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.scaleIn
import androidx.compose.animation.fadeIn
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.automirrored.filled.Forward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import com.voiid.app.model.MessageKind
import com.voiid.app.model.MessageStatus
import com.voiid.app.model.VCallLog
import com.voiid.app.model.VMessage
import com.voiid.app.model.VPoll
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.bouncyClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlin.math.abs
import kotlin.math.roundToInt

/** Shared chat UI atoms — bubbles, reactions, polls, date separators, typing indicator. */

private val reactionSet = listOf("👍", "❤️", "😂", "😮", "😢", "🙏")

/** Bubble shape with the tail squared on the correct side. */
fun bubbleShape(isMine: Boolean): Shape = RoundedCornerShape(
    topStart = 16.dp,
    topEnd = 16.dp,
    bottomEnd = if (isMine) 0.dp else 16.dp,
    bottomStart = if (isMine) 16.dp else 0.dp,
)

/** Stable per-sender accent color for group sender names (WhatsApp-style). */
fun senderColor(senderId: String): Color {
    val palette = listOf(0xFFC0556B, 0xFF3E9E6E, 0xFF4D7EA8, 0xFFD8A24A, 0xFF8E5BA6, 0xFFBA6B3D, 0xFF2A9D8F)
    val idx = abs(senderId.hashCode()) % palette.size
    return Color(palette[idx])
}

/** Full-featured message bubble — port of iOS `MessageBubble`. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun MessageBubble(
    message: VMessage,
    isLastMine: Boolean,
    isGroup: Boolean = false,
    selectionMode: Boolean = false,
    selected: Boolean = false,
    onSelectTap: () -> Unit = {},
    onReply: () -> Unit = {},
    onForward: () -> Unit = {},
    onReact: (String) -> Unit = {},
    onCopy: () -> Unit = {},
    onInfo: () -> Unit = {},
    onDelete: () -> Unit = {},
    onVote: (String) -> Unit = {},
    /** Tap a call bubble to call back, with that call's kind (true = video). */
    onCallBack: (Boolean) -> Unit = {},
) {
    // A finished call (WhatsApp-style): its own sided, tappable bubble — NOT a centered
    // system pill, because it is an action you can repeat, not an announcement.
    message.call?.let { log ->
        CallLogBubble(log, onCallBack = { onCallBack(log.isVideo) })
        return
    }

    // System message — centered pill (e.g. "You added Priyanshu").
    if (message.kind == MessageKind.SYSTEM) {
        Box(Modifier.fillMaxWidth().padding(vertical = 2.dp), contentAlignment = Alignment.Center) {
            Text(
                message.text,
                style = VoiidFont.rounded(11, FontWeight.Medium),
                color = VoiidColor.textSecondary,
                modifier = Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .background(VoiidColor.surfaceCard.copy(alpha = 0.7f))
                    .padding(horizontal = 16.dp, vertical = 5.dp),
            )
        }
        return
    }

    val haptics = LocalVoiidHaptics.current
    val density = LocalDensity.current
    val mine = message.isMine
    var showMenu by remember { mutableStateOf(false) }
    var showEmojiPicker by remember { mutableStateOf(false) }
    var swipeX by remember { mutableFloatStateOf(0f) }
    val animSwipe by animateFloatAsState(swipeX, label = "swipe")
    val maxSwipe = with(density) { 80.dp.toPx() }
    val replyTrigger = with(density) { 50.dp.toPx() }

    Box(Modifier.fillMaxWidth()) {
        // Swipe-to-reply hint icon
        Icon(
            Icons.AutoMirrored.Filled.Reply, null, tint = VoiidColor.primary,
            modifier = Modifier
                .align(if (mine) Alignment.CenterEnd else Alignment.CenterStart)
                .padding(horizontal = 24.dp)
                .size(20.dp)
                .alpha((abs(swipeX) / 60f).coerceIn(0f, 1f)),
        )

        Row(
            Modifier
                .fillMaxWidth()
                .offset { IntOffset(animSwipe.roundToInt(), 0) }
                .then(
                    if (selectionMode) Modifier
                    else Modifier.pointerInput(message.id) {
                        detectHorizontalDragGestures(
                            onDragEnd = {
                                if (abs(swipeX) > replyTrigger) { haptics.tap(); onReply() }
                                swipeX = 0f
                            },
                        ) { change, amount ->
                            change.consume()
                            swipeX = if (mine) (swipeX + amount).coerceIn(-maxSwipe, 0f)
                            else (swipeX + amount).coerceIn(0f, maxSwipe)
                        }
                    },
                ),
        ) {
            if (selectionMode) {
                Icon(
                    if (selected) Icons.Default.CheckCircle else Icons.Outlined.Circle, null,
                    tint = if (selected) VoiidColor.primary else VoiidColor.textSecondary.copy(alpha = 0.5f),
                    modifier = Modifier.align(Alignment.CenterVertically).padding(end = 8.dp).size(22.dp),
                )
            }
            if (mine) Spacer(Modifier.width(56.dp))
            // Group, incoming: the sender's real profile photo beside the bubble, so you can
            // see at a glance who's texting (WhatsApp-style).
            if (isGroup && !mine) {
                ProfileAvatar(
                    photoUrl = com.voiid.app.store.UserDirectory.photoUrl(message.senderId),
                    name = message.senderName,
                    size = 28.dp,
                    modifier = Modifier.align(Alignment.Bottom).padding(end = 6.dp),
                )
            }
            Box(
                modifier = Modifier.weight(1f),
                contentAlignment = if (mine) Alignment.CenterEnd else Alignment.CenterStart,
            ) {
                Column(horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
                    Box {
                        Column(
                            modifier = Modifier
                                .clip(bubbleShape(mine))
                                .background(if (mine) VoiidColor.bubbleReceived else VoiidColor.surfaceCard)
                                // iOS opens the action menu on LONG-PRESS (0.3s) + rigid haptic;
                                // a plain tap only toggles selection while in selection mode.
                                .combinedClickable(
                                    interactionSource = remember { MutableInteractionSource() },
                                    indication = null,
                                    onLongClick = if (selectionMode) null else {
                                        { haptics.rigid(); showMenu = true }
                                    },
                                    onClick = { if (selectionMode) onSelectTap() },
                                )
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                            verticalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            BubbleInner(message, isGroup, isLastMine, onVote)
                        }

                        // Long-press reaction + actions popover
                        if (showMenu) {
                            Popup(
                                alignment = Alignment.TopCenter,
                                offset = IntOffset(0, with(density) { (-8).dp.roundToPx() }),
                                onDismissRequest = { showMenu = false },
                                properties = PopupProperties(focusable = true),
                            ) {
                                ReactionActionMenu(
                                    isMine = mine,
                                    onReact = { showMenu = false; onReact(it) },
                                    onMore = { showMenu = false; showEmojiPicker = true },
                                    onReply = { showMenu = false; onReply() },
                                    onForward = { showMenu = false; onForward() },
                                    onCopy = { showMenu = false; onCopy() },
                                    onInfo = { showMenu = false; onInfo() },
                                    onDelete = { showMenu = false; onDelete() },
                                )
                            }
                        }
                    }
                    // Reaction pill (overlapping bottom corner)
                    message.reaction?.let { r ->
                        Text(
                            r, fontSize = 13.sp,
                            modifier = Modifier
                                .offset(y = (-8).dp)
                                .padding(start = if (mine) 0.dp else 8.dp, end = if (mine) 8.dp else 0.dp)
                                .clip(CircleShape)
                                .background(VoiidColor.background)
                                .border(0.5.dp, VoiidColor.divider.copy(alpha = 0.5f), CircleShape)
                                .padding(3.dp),
                        )
                    }
                }
            }
            if (!mine) Spacer(Modifier.width(56.dp))
        }
    }

    if (showEmojiPicker) {
        EmojiPickerSheet(onPick = { onReact(it) }, onDismiss = { showEmojiPicker = false })
    }
}

@Composable
private fun BubbleInner(message: VMessage, isGroup: Boolean, isLastMine: Boolean, onVote: (String) -> Unit) {
    val mine = message.isMine
    // "Forwarded" tag
    if (message.forwarded) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Icon(Icons.AutoMirrored.Filled.Forward, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(12.dp))
            Text("Forwarded", style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
        }
    }
    // Quoted reply
    if (message.replyToText != null) {
        Row(
            Modifier
                .clip(RoundedCornerShape(8.dp))
                .background(VoiidColor.fieldFill.copy(alpha = 0.7f))
                .padding(6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(Modifier.width(3.dp).height(32.dp).clip(RoundedCornerShape(2.dp)).background(VoiidColor.primary))
            Column {
                if (!message.replyToSender.isNullOrEmpty()) {
                    Text(message.replyToSender, style = VoiidFont.rounded(11, FontWeight.SemiBold), color = VoiidColor.primary)
                }
                Text(message.replyToText, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary, maxLines = 2)
            }
        }
    }
    // Sender identity (group, incoming only): saved name (or phone) coloured per sender, with
    // the @username in a lighter tone so you know exactly who's texting who.
    if (isGroup && !mine && message.senderName.isNotEmpty()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(message.senderName, style = VoiidFont.rounded(12, FontWeight.SemiBold), color = senderColor(message.senderId))
            com.voiid.app.store.UserDirectory.user(message.senderId)?.username?.takeIf { it.isNotBlank() }?.let {
                Text("@$it", style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
            }
        }
    }

    if (message.deletedForEveryone) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Icon(Icons.Default.Block, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(13.dp))
            Text("This message was deleted", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
        }
        return
    }

    // A game invite is a TEXT message whose body carries a token (see net/GameInvite.kt).
    // Intercepted before the kind switch so both sides render the Join card rather than a
    // raw `voiid:game/...` line.
    val invite = remember(message.text) { com.voiid.app.net.GameInvite.parse(message.text) }
    if (invite != null) {
        GameInviteBubble(message, invite)
        MetaRow(message, isLastMine, Modifier.padding(top = 2.dp))
        return
    }

    when (message.kind) {
        // Text: time + ticks flow INLINE at the end (bubble hugs content, WhatsApp-style) — iOS `textWithMeta`.
        MessageKind.TEXT -> Row(
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                styledText(message.text), style = VoiidFont.rounded(15), color = VoiidColor.textPrimary,
                modifier = Modifier.weight(1f, fill = false),
            )
            MetaRow(message, isLastMine)
        }
        // Non-text: content, then the meta row beneath it (iOS `content; metaRow.padding(.top, 2)`).
        MessageKind.IMAGE -> {
            val ref = message.mediaRef
            if (ref != null) {
                AsyncMediaImage(ref)
            } else {
                Box(
                    modifier = Modifier.size(200.dp).clip(RoundedCornerShape(12.dp)).background(VoiidColor.accent.copy(alpha = 0.4f)),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator(color = VoiidColor.primary) }   // local echo before upload
            }
            MetaRow(message, isLastMine, Modifier.padding(top = 2.dp))
        }
        MessageKind.VOICE -> {
            AsyncVoiceNote(message.mediaRef, message.text)
            MetaRow(message, isLastMine, Modifier.padding(top = 2.dp))
        }
        MessageKind.POLL -> {
            message.poll?.let { PollBubble(it, onVote) }
            MetaRow(message, isLastMine, Modifier.padding(top = 2.dp))
        }
        MessageKind.LOCATION -> {
            LocationPinBubble(message)
            MetaRow(message, isLastMine, Modifier.padding(top = 2.dp))
        }
        else -> Row(
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                styledText(message.text), style = VoiidFont.rounded(15), color = VoiidColor.textPrimary,
                modifier = Modifier.weight(1f, fill = false),
            )
            MetaRow(message, isLastMine)
        }
    }
}

/**
 * A finished call, in the transcript (WhatsApp/Signal style).
 *
 * Sided like a real bubble — outgoing right, incoming left — because a call IS attributable
 * to one party, unlike a system announcement. Tapping calls back with the same kind.
 *
 * A MISSED incoming call is the one state that gets colour: it is the only one the user may
 * still need to act on. Everything else stays quiet so a long call history does not shout.
 */
@Composable
private fun CallLogBubble(log: VCallLog, onCallBack: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val missed = log.incoming && !log.answered
    val tint = if (missed) VoiidColor.error else VoiidColor.textSecondary
    val icon = when {
        log.isVideo -> Icons.Default.Videocam
        else -> Icons.Default.Call
    }
    val title = when {
        log.answered -> if (log.isVideo) "Video call" else "Voice call"
        log.outcome == "declined" -> if (log.incoming) "Declined call" else "Call declined"
        log.outcome == "failed" -> "Call failed"
        log.incoming -> if (log.isVideo) "Missed video call" else "Missed voice call"
        else -> "No answer"
    }
    // Duration only when there IS one — an unanswered call has no elapsed time to report.
    val subtitle = log.durationSeconds?.let { s ->
        val m = s / 60
        if (m >= 60) "%d:%02d:%02d".format(m / 60, m % 60, s % 60) else "%d:%02d".format(m, s % 60)
    }

    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = if (log.incoming) Arrangement.Start else Arrangement.End,
    ) {
        Row(
            Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(if (log.incoming) VoiidColor.bubbleReceived else VoiidColor.bubbleSent)
                .clickable { haptics.tap(); onCallBack() }
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(10.dp))
            Column {
                Text(title, style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        VoiidDate.bubbleTime(log.startedAt),
                        style = VoiidFont.rounded(11),
                        color = VoiidColor.textSecondary,
                    )
                    subtitle?.let {
                        Text("· $it", style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
                    }
                }
            }
        }
    }
}

/** Time + delivery-tick row that flows inline after text (or beneath media) — iOS `metaRow`. */
@Composable
private fun MetaRow(message: VMessage, isLastMine: Boolean, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(VoiidDate.bubbleTime(message.createdAt), style = VoiidFont.rounded(10), color = VoiidColor.textSecondary.copy(alpha = 0.8f))
        // Clean text status (Sent / Delivered / Seen) under the LAST outgoing message
        // only, so older messages never change.
        if (message.isMine && isLastMine) {
            val label = when (message.status) {
                MessageStatus.SENDING -> "Sending…"
                MessageStatus.SENT -> "Sent"
                MessageStatus.DELIVERED -> "Delivered"
                MessageStatus.READ -> "Seen"
                MessageStatus.FAILED -> "Failed"
            }
            Text(
                "· $label", style = VoiidFont.rounded(10),
                color = if (message.status == MessageStatus.READ) VoiidColor.primary else VoiidColor.textSecondary.copy(alpha = 0.8f),
            )
        }
    }
}

/** Renders text with @mentions highlighted in the brand primary color. */
@Composable
private fun styledText(text: String) = buildAnnotatedString {
    text.split(" ").forEachIndexed { i, word ->
        if (i > 0) append(" ")
        val isMention = word.startsWith("@") && word.length > 1
        if (isMention) {
            withStyle(SpanStyle(color = VoiidColor.primary, fontWeight = FontWeight.SemiBold)) { append(word) }
        } else {
            append(word)
        }
    }
}

// MARK: - Reaction + action popover

@Composable
private fun ReactionActionMenu(
    isMine: Boolean,
    onReact: (String) -> Unit,
    onMore: () -> Unit,
    onReply: () -> Unit,
    onForward: () -> Unit,
    onCopy: () -> Unit,
    onInfo: () -> Unit,
    onDelete: () -> Unit,
) {
    val scale by animateFloatAsState(1f, spring(dampingRatio = Spring.DampingRatioMediumBouncy), label = "menuPop")
    Column(
        Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(VoiidColor.surfaceCard)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // reactions row + "+"
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            reactionSet.forEach { e ->
                Box(Modifier.size(34.dp).bouncyClickable { onReact(e) }, contentAlignment = Alignment.Center) {
                    Text(e, fontSize = 28.sp)
                }
            }
            Box(
                Modifier.size(34.dp).clip(CircleShape).background(VoiidColor.fieldFill).clickable { onMore() },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Default.Add, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(18.dp)) }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.4f)))
        // actions row
        Row(horizontalArrangement = Arrangement.spacedBy(0.dp)) {
            ActionBtn("Reply", Icons.AutoMirrored.Filled.Reply, VoiidColor.primary, onReply)
            ActionBtn("Forward", Icons.AutoMirrored.Filled.Forward, VoiidColor.primary, onForward)
            ActionBtn("Copy", Icons.Default.ContentCopy, VoiidColor.primary, onCopy)
            if (isMine) ActionBtn("Info", Icons.Default.Info, VoiidColor.primary, onInfo)
            ActionBtn("Delete", Icons.Default.Delete, VoiidColor.error, onDelete)
        }
    }
}

@Composable
private fun ActionBtn(label: String, icon: ImageVector, tint: Color, onClick: () -> Unit) {
    Column(
        Modifier.width(60.dp).clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null,
        ) { onClick() },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
        Text(label, style = VoiidFont.rounded(11), color = VoiidColor.textPrimary)
    }
}

// MARK: - Poll bubble (vote + live results)

@Composable
fun PollBubble(poll: VPoll, onVote: (String) -> Unit) {
    val haptics = LocalVoiidHaptics.current
    var voted by remember { mutableStateOf<String?>(null) }
    Column(Modifier.width(240.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Default.BarChart, null, tint = VoiidColor.primary, modifier = Modifier.size(12.dp))
            Text("Poll", style = VoiidFont.rounded(11, FontWeight.SemiBold), color = VoiidColor.textSecondary)
        }
        Text(poll.question, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        poll.options.forEach { opt ->
            val total = poll.totalVotes.coerceAtLeast(1)
            val pct = opt.votes.toFloat() / total
            val shape = RoundedCornerShape(10.dp)
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(38.dp)
                    .clip(shape)
                    .border(1.dp, VoiidColor.fieldBorder, shape)
                    .clickable(enabled = voted == null) {
                        haptics.tap(); voted = opt.id; onVote(opt.id)
                    },
            ) {
                // result fill
                Box(
                    Modifier
                        .fillMaxWidth(if (voted != null) pct else 1f)
                        .height(38.dp)
                        .clip(shape)
                        .background(if (voted == opt.id) VoiidColor.accent else VoiidColor.fieldFill),
                )
                Row(
                    Modifier.fillMaxWidth().height(38.dp).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(opt.text, style = VoiidFont.rounded(14), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                    if (voted != null) {
                        Text("${(pct * 100).toInt()}%", style = VoiidFont.rounded(12, FontWeight.Medium), color = VoiidColor.textSecondary)
                    }
                }
            }
        }
        Text("${poll.totalVotes} votes", style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
    }
}

// MARK: - Game invite bubble (tap to join)

/**
 * An invite to a match, in the transcript.
 *
 * BOTH SIDES GET A BUTTON, and that is deliberate: the creator's board is already open, but
 * they may have closed it, and "Open" on their own invite is the only way back into a match
 * that hasn't finished. Labelling it differently per side ("Join" vs "Open") keeps that
 * honest without needing two code paths.
 *
 * Tapping publishes to [com.voiid.app.net.DeepLinkRouter] rather than calling a callback —
 * the board is a full-screen sibling of the whole tab tree, so the root composable owns it
 * (see the router's comment).
 */
@Composable
private fun GameInviteBubble(
    message: VMessage,
    invite: com.voiid.app.net.GameInvite.Parsed,
) {
    val haptics = LocalVoiidHaptics.current
    val shape = RoundedCornerShape(12.dp)
    Column(Modifier.width(230.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.Outlined.SportsEsports, null,
                tint = VoiidColor.primary, modifier = Modifier.size(13.dp),
            )
            Text(
                "Game invite",
                style = VoiidFont.rounded(11, FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
            )
        }
        // The human half of the token — never the marker line.
        Text(
            com.voiid.app.net.GameInvite.preview(message.text),
            style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = VoiidColor.textPrimary,
        )
        Box(
            Modifier
                .fillMaxWidth()
                .height(38.dp)
                .clip(shape)
                .background(VoiidColor.primary)
                .clickable {
                    haptics.tap()
                    com.voiid.app.net.DeepLinkRouter.openGameMatch(invite.matchId, invite.slug)
                },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (message.isMine) "Open board" else "Join game",
                style = VoiidFont.rounded(14, FontWeight.Bold),
                color = VoiidColor.textOnPrimary,
            )
        }
    }
}

// MARK: - Date separator + typing indicator

@Composable
fun DateSeparator(text: String) {
    Box(Modifier.fillMaxWidth().padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
        Text(
            text,
            style = VoiidFont.rounded(11, FontWeight.Medium),
            color = VoiidColor.textSecondary,
            modifier = Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(VoiidColor.surfaceCard.copy(alpha = 0.7f))
                .padding(horizontal = 16.dp, vertical = 4.dp),
        )
    }
}

@Composable
fun TypingBubble() {
    val transition = rememberInfiniteTransition(label = "typing")
    Row(Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .clip(bubbleShape(false))
                .background(VoiidColor.bubbleReceived)
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            repeat(3) { i ->
                val a by transition.animateFloat(
                    initialValue = 0.3f,
                    targetValue = 1f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(500, easing = LinearEasing),
                        repeatMode = RepeatMode.Reverse,
                        initialStartOffset = StartOffset(i * 166),
                    ),
                    label = "dot$i",
                )
                Box(Modifier.size(7.dp).alpha(a).clip(CircleShape).background(VoiidColor.textSecondary))
            }
        }
        Spacer(Modifier.weight(1f))
    }
}
