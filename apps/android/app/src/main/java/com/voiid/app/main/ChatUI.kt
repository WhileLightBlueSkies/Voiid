package com.voiid.app.main

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.voiid.app.model.MessageKind
import com.voiid.app.model.MessageStatus
import com.voiid.app.model.VMessage
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** Shared chat UI atoms — bubbles, ticks, date separators, typing indicator (from `ChatDetailView.swift`). */

/** Bubble shape with the tail squared on the correct side. */
fun bubbleShape(isMine: Boolean): Shape = RoundedCornerShape(
    topStart = 16.dp,
    topEnd = 16.dp,
    bottomEnd = if (isMine) 0.dp else 16.dp,
    bottomStart = if (isMine) 16.dp else 0.dp,
)

@Composable
fun MessageBubble(message: VMessage) {
    Row(Modifier.fillMaxWidth()) {
        if (message.isMine) Spacer(Modifier.weight(1f))
        Box(
            modifier = Modifier
                .widthIn(max = 300.dp)
                .clip(bubbleShape(message.isMine))
                .background(if (message.isMine) VoiidColor.bubbleSent else VoiidColor.bubbleReceived)
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            androidx.compose.foundation.layout.Column(
                horizontalAlignment = if (message.isMine) Alignment.End else Alignment.Start,
            ) {
                BubbleContent(message)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(VoiidDate.bubbleTime(message.createdAt), style = VoiidFont.rounded(10), color = VoiidColor.textSecondary)
                    if (message.isMine) StatusTicks(message.status)
                }
            }
        }
        if (!message.isMine) Spacer(Modifier.weight(1f))
    }
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
            Icon(Icons.Default.Schedule, null, tint = VoiidColor.primary, modifier = Modifier.size(40.dp))
        }
        MessageKind.VOICE -> VoiceNotePlayer(label = message.text)
        else -> Text(message.text, style = VoiidFont.body, color = VoiidColor.textPrimary)
    }
}

@Composable
fun StatusTicks(status: MessageStatus) {
    when (status) {
        MessageStatus.SENDING -> Icon(Icons.Default.Schedule, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(12.dp))
        MessageStatus.SENT -> Icon(Icons.Default.Check, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(12.dp))
        MessageStatus.DELIVERED -> Icon(Icons.Default.DoneAll, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(14.dp))
        MessageStatus.READ -> Icon(Icons.Default.DoneAll, null, tint = VoiidColor.success, modifier = Modifier.size(14.dp))
        MessageStatus.FAILED -> Icon(Icons.Default.ErrorOutline, null, tint = VoiidColor.error, modifier = Modifier.size(12.dp))
    }
}

@Composable
fun DateSeparator(text: String) {
    Box(Modifier.fillMaxWidth().padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
        Text(
            text,
            style = VoiidFont.rounded(11, androidx.compose.ui.text.font.FontWeight.Medium),
            color = VoiidColor.textSecondary,
            modifier = Modifier
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(999.dp))
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
