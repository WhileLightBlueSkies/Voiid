package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * Choose who to play against (docs/GAMES.md §3).
 *
 * Sourced from EXISTING DIRECT CONVERSATIONS, deliberately — the whole invite model is
 * "play someone you already talk to". Groups are excluded because Tic Tac Toe is a
 * two-player game and the match roster is fixed at creation; a group picker would imply a
 * lobby this system does not have.
 *
 * Mirrors iOS `OpponentPickerSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OpponentPickerSheet(
    conversations: List<VConversation>,
    // The CONVERSATION, not just the peer id: the invite is sent into this chat, so the
    // caller needs both halves. Handing back only a user id is what made the invite
    // unsendable — there was no thread to put it in.
    onPick: (VConversation) -> Unit,
    onDismiss: () -> Unit,
) {
    // Only direct chats where we actually know the peer's user id — without it there is
    // nobody to name as the opponent.
    val candidates = conversations.filter {
        it.type == ConversationType.DIRECT && !it.peerUserId.isNullOrBlank()
    }

    com.voiid.app.ui.components.VoiidSheet(
        visible = true,
        onDismiss = onDismiss,
        detents = listOf(com.voiid.app.ui.components.VoiidDetent.Medium, com.voiid.app.ui.components.VoiidDetent.Large),
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = VoiidSpacing.md)) {
            Text(
                "Play against",
                color = VoiidColor.textPrimary,
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(bottom = VoiidSpacing.sm),
            )

            if (candidates.isEmpty()) {
                Text(
                    "Start a chat with someone first — games are played with people you already talk to.",
                    color = VoiidColor.textSecondary,
                    fontSize = 14.sp,
                    modifier = Modifier.padding(vertical = VoiidSpacing.lg),
                )
            } else {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        bottom = VoiidSpacing.xl,
                    ),
                ) {
                    items(candidates, key = { it.id }) { convo ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clickable { onPick(convo) }
                                .padding(vertical = VoiidSpacing.sm),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                        ) {
                            Box(
                                Modifier
                                    .size(40.dp)
                                    .clip(CircleShape)
                                    .background(VoiidColor.primary.copy(alpha = 0.12f)),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    convo.title.take(1).uppercase(),
                                    color = VoiidColor.primary,
                                    fontSize = 16.sp,
                                    fontWeight = FontWeight.SemiBold,
                                )
                            }
                            Text(
                                convo.title,
                                color = VoiidColor.textPrimary,
                                fontSize = 16.sp,
                            )
                        }
                    }
                }
            }
        }
    }
}
