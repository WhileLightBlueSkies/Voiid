package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * The classic LIST layout for the chat list — the alternative to the icon grid
 * (see ChatLayoutPreference for why both exist). Port of iOS `ChatListRows.swift`.
 *
 * A list row's whole job is to answer "does this need me?" without being opened. That means
 * four facts in one glance — who, what they said, when, and whether it is unread — and a
 * visual hierarchy that lets the eye skip the rows that do not matter.
 */
@Composable
fun ChatListRow(
    conversation: VConversation,
    onTap: () -> Unit,
) {
    val isUnread = conversation.unreadCount > 0

    Row(
        Modifier
            .fillMaxWidth()
            .softClickable(onClick = onTap)
            .padding(horizontal = 16.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Avatar(conversation)

        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    conversation.title,
                    // WEIGHT carries unread, not colour alone. Roughly 1 in 12 men has a
                    // colour-vision deficiency, and a tinted name against a tinted badge is
                    // exactly the pairing that fails for them.
                    style = VoiidFont.rounded(16, if (isUnread) FontWeight.SemiBold else FontWeight.Medium),
                    color = VoiidColor.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.weight(1f))
                conversation.lastMessageAt?.let { at ->
                    Text(
                        VoiidDate.listPreview(at),
                        style = VoiidFont.rounded(12),
                        // The timestamp lifts to the brand colour when unread — the one place
                        // colour does work the badge does not already do, and never alone.
                        color = if (isUnread) VoiidColor.primary else VoiidColor.textSecondary,
                    )
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    conversation.lastMessagePreview ?: "Tap to start the conversation",
                    style = VoiidFont.rounded(14, if (isUnread) FontWeight.Medium else FontWeight.Normal),
                    // A preview that is ABSENT reads differently from one that is empty — the
                    // placeholder is dimmer so it never looks like a message someone sent.
                    color = if (isUnread) VoiidColor.textPrimary
                            else VoiidColor.textSecondary.copy(
                                alpha = if (conversation.lastMessagePreview == null) 0.7f else 1f,
                            ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.weight(1f))
                if (isUnread) {
                    Box(
                        Modifier
                            .defaultMinSize(minWidth = 22.dp, minHeight = 22.dp)
                            .clip(RoundedCornerShape(999.dp))
                            .background(VoiidColor.primary)
                            .padding(horizontal = 7.dp, vertical = 3.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            if (conversation.unreadCount > 99) "99+" else "${conversation.unreadCount}",
                            style = VoiidFont.rounded(12, FontWeight.SemiBold),
                            color = VoiidColor.textOnPrimary,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun Avatar(conversation: VConversation) {
    Box(Modifier.size(54.dp)) {
        if (conversation.type == ConversationType.SELF) {
            // Note to Self gets its mark, not a face — same reasoning as the grid card. The
            // two layouts must teach the same vocabulary.
            Box(
                Modifier.size(54.dp).clip(CircleShape).background(VoiidColor.primary.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.Bookmark, null, tint = VoiidColor.primary, modifier = Modifier.size(20.dp))
            }
        } else {
            ProfileAvatar(
                photoUrl = conversation.photoURL,
                name = conversation.title,
                size = 54.dp,
                modifier = Modifier.clip(CircleShape),
            )
        }

        if (conversation.isOnline) {
            // Ringed in the list's own background so the dot reads as ON the avatar rather
            // than floating beside it — without the ring it disappears against a light photo.
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .size(13.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.background)
                    .padding(2.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.success),
            )
        }
    }
}
