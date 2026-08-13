package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * Choose several opponents, for games with more than two seats
 * (docs/games/future/README.md §2.4, LUDO.md §14 phase 0).
 *
 * WHY THIS IS SEPARATE FROM [OpponentPickerSheet]. That one hands back a single conversation and
 * its callers are wired for exactly one — Tic Tac Toe, RPS, cricket and a Snake duel are all
 * strictly 1:1, and widening its callback would touch four working screens to serve none of them.
 * This is additive: a game whose catalog row allows more than two seats gets this sheet.
 *
 * THE SERVER SIDE ALREADY WORKS. `POST /games/matches` takes `opponent_ids` as an array and
 * validates it against the catalog's min/max_players; `handleJoin` gates the start on
 * `joined.length >= players.length` for any seat count. The gap this closes was entirely that no
 * client could express more than one opponent.
 *
 * Mirrors iOS `SeatPickerSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SeatPickerSheet(
    conversations: List<VConversation>,
    /** Seats the match needs BESIDES the creator. A 4-player Ludo game passes 3. */
    maxOpponents: Int,
    /** Fewest opponents that make a playable match, besides the creator. */
    minOpponents: Int,
    onDismiss: () -> Unit,
    /** The chosen conversations, in pick order — which becomes seat order. */
    onConfirm: (List<VConversation>) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    /**
     * Only direct chats whose peer user id we actually know.
     *
     * GROUPS ARE STILL EXCLUDED, and that is a deliberate half-step. LUDO.md §12.3 calls "play
     * Ludo with this group" the highest-value entry point in that doc, and it is — but it needs a
     * group-membership read and a fan-out invite this sheet has no business inventing, so seats
     * are filled from direct chats first and the group entry point is the next piece of work
     * rather than half-built here.
     */
    val candidates = remember(conversations) {
        conversations.filter { it.type == ConversationType.DIRECT && !it.peerUserId.isNullOrEmpty() }
    }
    // Pick ORDER is preserved, not list order: seat order is the order the creator chose, and in
    // Ludo the seat decides colour, entry square and turn order.
    val picked = remember { mutableStateListOf<String>() }

    val canConfirm = picked.size in minOpponents..maxOpponents

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.lg)) {
            Text(
                "Pick players",
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = VoiidColor.textPrimary,
                modifier = Modifier.fillMaxWidth().padding(VoiidSpacing.md),
                textAlign = TextAlign.Center,
            )

            if (candidates.isEmpty()) {
                Text(
                    "Start a chat with someone first — games are played with people you already talk to.",
                    fontSize = 14.sp,
                    color = VoiidColor.textSecondary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(VoiidSpacing.lg),
                )
            } else {
                LazyColumn(Modifier.fillMaxWidth().height(340.dp)) {
                    items(candidates, key = { it.id }) { convo ->
                        val index = picked.indexOf(convo.id).takeIf { it >= 0 }
                        val isPicked = index != null
                        // A full roster greys out the rest rather than silently ignoring taps —
                        // a tap that does nothing reads as a broken list.
                        val atCapacity = !isPicked && picked.size >= maxOpponents

                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable(enabled = !atCapacity) {
                                    if (isPicked) picked.remove(convo.id)
                                    else if (picked.size < maxOpponents) picked.add(convo.id)
                                }
                                .alpha(if (atCapacity) 0.45f else 1f)
                                .padding(horizontal = VoiidSpacing.md, vertical = VoiidSpacing.sm),
                        ) {
                            Box(
                                Modifier
                                    .size(40.dp)
                                    .background(
                                        if (isPicked) VoiidColor.primary
                                        else VoiidColor.primary.copy(alpha = 0.12f),
                                        CircleShape,
                                    ),
                                contentAlignment = Alignment.Center,
                            ) {
                                // The SEAT NUMBER, not a tick: in a 4-player game the order is
                                // the turn order, and showing it here makes that legible before
                                // the match rather than after the first roll.
                                Text(
                                    if (isPicked) "${(index ?: 0) + 2}"
                                    else convo.title.take(1).uppercase(),
                                    fontSize = if (isPicked) 15.sp else 16.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = if (isPicked) Color.White else VoiidColor.primary,
                                )
                            }
                            Text(
                                convo.title,
                                fontSize = 16.sp,
                                color = if (atCapacity) VoiidColor.textSecondary
                                        else VoiidColor.textPrimary,
                                modifier = Modifier.padding(start = VoiidSpacing.md).weight(1f),
                            )
                            if (isPicked) {
                                Icon(
                                    Icons.Filled.CheckCircle,
                                    contentDescription = null,
                                    tint = VoiidColor.primary,
                                )
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(VoiidSpacing.sm))

            // Say what is needed rather than only disabling the button. A dead button with no
            // explanation is the flow mistake CROSS_CUTTING.md §9 names across this whole surface.
            Text(
                when {
                    picked.size < minOpponents -> {
                        val need = minOpponents - picked.size
                        "Pick $need more player${if (need == 1) "" else "s"}"
                    }
                    picked.size >= maxOpponents -> "That's everyone — ${picked.size + 1} players"
                    else -> "${picked.size + 1} playing. Add up to ${maxOpponents - picked.size} more."
                },
                fontSize = 12.sp,
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )

            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = VoiidSpacing.md, vertical = VoiidSpacing.sm)
                    .background(
                        if (canConfirm) VoiidColor.primary
                        else VoiidColor.textSecondary.copy(alpha = 0.18f),
                        RoundedCornerShape(12.dp),
                    )
                    .clickable(enabled = canConfirm) {
                        onConfirm(picked.mapNotNull { id -> candidates.firstOrNull { it.id == id } })
                    }
                    .padding(vertical = VoiidSpacing.sm),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (picked.isEmpty()) "Start" else "Start with ${picked.size + 1}",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (canConfirm) Color.White else VoiidColor.textSecondary,
                )
            }
        }
    }
}
