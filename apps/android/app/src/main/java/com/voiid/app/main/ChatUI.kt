package com.voiid.app.main

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.MessageKind
import com.voiid.app.model.MessageStatus
import com.voiid.app.model.VMessage
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** Shared chat UI atoms — bubbles, date separators, typing indicator (from `ChatDetailView.swift`). */

/** Bubble shape with the tail squared on the correct side. */
fun bubbleShape(isMine: Boolean): Shape = RoundedCornerShape(
    topStart = 16.dp,
    topEnd = 16.dp,
    bottomEnd = if (isMine) 0.dp else 16.dp,
    bottomStart = if (isMine) 16.dp else 0.dp,
)

/** Stable per-sender accent color for group sender names (WhatsApp-style). */
fun senderColor(senderId: String): androidx.compose.ui.graphics.Color {
    val palette = listOf(0xFFC0556B, 0xFF3E9E6E, 0xFF4D7EA8, 0xFFD8A24A, 0xFF8E5BA6, 0xFFBA6B3D, 0xFF2A9D8F)
    val idx = kotlin.math.abs(senderId.hashCode()) % palette.size
    return androidx.compose.ui.graphics.Color(palette[idx])
}

/**
 * Message bubble — mine = light pink (#FCF4F8), received = white (#FFFFFF).
 * System messages render as a centered pill. In groups, incoming bubbles show a colored
 * sender name. Refined receipts: tap to reveal time; "Read" only under the last sent message.
 */
@Composable
fun MessageBubble(message: VMessage, isLastMine: Boolean, isGroup: Boolean = false) {
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

    var showMeta by remember { mutableStateOf(false) }
    val mine = message.isMine

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = if (mine) Alignment.End else Alignment.Start,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Row(Modifier.fillMaxWidth()) {
            if (mine) Spacer(Modifier.width(48.dp))   // keep ≥48 gap on the far side
            Box(
                modifier = Modifier.weight(1f),
                contentAlignment = if (mine) Alignment.CenterEnd else Alignment.CenterStart,
            ) {
                Column(
                    modifier = Modifier
                        .clip(bubbleShape(mine))
                        .background(if (mine) VoiidColor.bubbleReceived else VoiidColor.surfaceCard)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) { showMeta = !showMeta }
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    if (isGroup && !mine && message.senderName.isNotEmpty()) {
                        Text(message.senderName, style = VoiidFont.rounded(12, FontWeight.SemiBold), color = senderColor(message.senderId))
                    }
                    BubbleContent(message)
                }
            }
            if (!mine) Spacer(Modifier.width(48.dp))
        }

        // Receipt line: time on tap; "Sent/Delivered/Read" only under the last sent message.
        AnimatedVisibility(visible = showMeta || (mine && isLastMine)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier.padding(start = if (mine) 0.dp else 6.dp, end = if (mine) 6.dp else 0.dp),
            ) {
                if (showMeta) {
                    Text(VoiidDate.bubbleTime(message.createdAt), style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
                }
                if (mine && isLastMine) {
                    Text(
                        receiptLabel(message.status),
                        style = VoiidFont.rounded(11, FontWeight.Medium),
                        color = if (message.status == MessageStatus.READ) VoiidColor.primary else VoiidColor.textSecondary,
                    )
                }
            }
        }
    }
}

private fun receiptLabel(status: MessageStatus): String = when (status) {
    MessageStatus.SENDING -> "Sending…"
    MessageStatus.SENT -> "Sent"
    MessageStatus.DELIVERED -> "Delivered"
    MessageStatus.READ -> "Read"
    MessageStatus.FAILED -> "Failed"
}

@Composable
private fun BubbleContent(message: VMessage) {
    when (message.kind) {
        MessageKind.IMAGE -> Box(
            modifier = Modifier
                .size(180.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(VoiidColor.accent.copy(alpha = 0.4f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.Image, null, tint = VoiidColor.primary, modifier = Modifier.size(40.dp))
        }
        MessageKind.VOICE -> VoiceNotePlayer(label = message.text)
        else -> Text(message.text, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
    }
}

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
