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
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.vector.ImageVector
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
    onCall: (() -> Unit)? = null,
    onDelete: (() -> Unit)? = null,
    onTap: () -> Unit,
) {
    // SWIPE ACTIONS, and on Android they were not optional-but-missing — they were the ONLY
    // way to delete a chat from this layout, and there wasn't one. `onDelete` was wired
    // solely to the grid's drag-to-zone, so a user who preferred the list could not remove a
    // conversation at all. iOS has had swipe here from the start; this closes that.
    //
    // Swipe RIGHT-to-left for the destructive action, matching iOS's trailing edge, so the
    // gesture means the same thing on both platforms.
    if (onDelete == null && onCall == null) {
        ChatListRowContent(conversation, onTap)
        return
    }

    val canCall = onCall != null && conversation.type == ConversationType.DIRECT
    val state = rememberSwipeToDismissBoxState(
        // A full swipe must NOT delete outright. Deleting a conversation is irreversible and
        // there is no undo here, so the gesture reveals the action and the user still has to
        // choose it — the same reason iOS sets allowsFullSwipe: false.
        confirmValueChange = { false },
    )

    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = false,
        enableDismissFromEndToStart = true,
        backgroundContent = {
            SwipeActions(
                revealed = state.targetValue == SwipeToDismissBoxValue.EndToStart,
                canCall = canCall,
                onCall = { onCall?.invoke() },
                onDelete = { onDelete?.invoke() },
            )
        },
    ) {
        ChatListRowContent(conversation, onTap)
    }
}

/**
 * The revealed actions behind a swiped row. Mirrors the iOS swipe actions exactly: Delete in
 * [VoiidColor.error], Call in [VoiidColor.success], destructive one outermost.
 *
 * State is carried by ICON AND COLOUR together, never colour alone — a red and a green block
 * with no glyphs is the pairing that fails for the ~1 in 12 men with a colour-vision
 * deficiency, which is the same rule the palette states for status colours.
 */
@Composable
private fun SwipeActions(
    revealed: Boolean,
    canCall: Boolean,
    onCall: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().height(72.dp),
        horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (canCall) {
            SwipeAction(Icons.Default.Call, "Call", VoiidColor.success, onCall)
        }
        SwipeAction(Icons.Default.Delete, "Delete", VoiidColor.error, onDelete)
    }
}

@Composable
private fun SwipeAction(icon: ImageVector, label: String, tint: Color, onClick: () -> Unit) {
    Box(
        Modifier
            .width(72.dp)
            .height(72.dp)
            .background(tint)
            .softClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        // textOnPrimary, which FLIPS with the theme — and it has to. The status fills are
        // dark in light mode and LIGHT in dark mode, so a fixed near-white glyph measured
        // 2.54:1 on dark error and 1.93:1 on dark success. Flipping gives 5.03/4.91 in light
        // and 6.82/8.97 in dark.
        Icon(icon, contentDescription = label, tint = VoiidColor.textOnPrimary)
    }
}

@Composable
private fun ChatListRowContent(
    conversation: VConversation,
    onTap: () -> Unit,
) {
    val isUnread = conversation.unreadCount > 0

    Row(
        Modifier
            .fillMaxWidth()
            // Opaque: the swipe actions sit BEHIND this row, and a transparent foreground
            // would let them bleed through the content at rest.
            .background(VoiidColor.background)
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
                // Appearing is the moment that matters — it is the whole point of the badge.
                // AnimatedVisibility (not a bare `if`) is what gives the REMOVAL an exit at
                // all: a plain conditional drops the composable instantly, so marking a chat
                // read made the badge vanish with no acknowledgement.
                //
                // It scales from the trailing edge it is anchored to, so it reads as arriving
                // from its own position rather than being pasted in. Matches iOS exactly.
                androidx.compose.animation.AnimatedVisibility(
                    visible = isUnread,
                    enter = androidx.compose.animation.scaleIn(
                        animationSpec = spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessMedium),
                        initialScale = 0.5f,
                        transformOrigin = TransformOrigin(1f, 0.5f),
                    ) + androidx.compose.animation.fadeIn(),
                    exit = androidx.compose.animation.scaleOut(
                        targetScale = 0.5f,
                        transformOrigin = TransformOrigin(1f, 0.5f),
                    ) + androidx.compose.animation.fadeOut(),
                ) {
                    Box(
                        Modifier
                            .defaultMinSize(minWidth = 22.dp, minHeight = 22.dp)
                            .clip(RoundedCornerShape(999.dp))
                            // AMBER, matching the grid card. The same signal was drawn in two
                            // different colours depending on which layout you had chosen —
                            // aubergine here, amber there — and the palette reserves amber for
                            // exactly this: "the one thing that must be seen". Aubergine is
                            // also the app's most-used colour, so an unread badge in it
                            // competed with every other primary surface instead of standing
                            // out from them.
                            .background(VoiidColor.accent)
                            .padding(horizontal = 7.dp, vertical = 3.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        // The NUMBER rolls when the count changes rather than being swapped
                        // out. A badge going 2 -> 3 with a hard substitution is easy to miss
                        // entirely; the digit moving is what says "this just changed" with no
                        // extra chrome. `AnimatedContent` is Compose's equivalent of iOS's
                        // .contentTransition(.numericText()).
                        androidx.compose.animation.AnimatedContent(
                            targetState = conversation.unreadCount,
                            transitionSpec = {
                                // A rising count enters from BELOW and the old digit leaves
                                // upward, so the direction of travel encodes the direction of
                                // the change (skill §8: hint where things are going).
                                (androidx.compose.animation.slideInVertically { h -> h } +
                                    androidx.compose.animation.fadeIn()) togetherWith
                                    (androidx.compose.animation.slideOutVertically { h -> -h } +
                                        androidx.compose.animation.fadeOut())
                            },
                            label = "unreadCount",
                        ) { count ->
                            Text(
                                if (count > 99) "99+" else "$count",
                                style = VoiidFont.rounded(12, FontWeight.SemiBold),
                                color = VoiidColor.textOnAccent,
                            )
                        }
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
