package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * How crowded the arena is, for a Snake match against a friend
 * (docs/games/SNAKE_COMPETITIVE_PARITY.md §4 P3.7).
 *
 * THE COMPETITOR'S `DuelGameMode` IS A MODE. Ours is not, and does not need to be: the engine
 * already takes a bot count and a player list, so a duel is a match with two seats and zero
 * bots. Building a mode around that would be a second code path to keep in step with the first,
 * for a difference that is one integer.
 *
 * So this asks the one question a mode would have answered implicitly, and it is worth asking
 * because the two answers play completely differently. An empty arena is a duel — every body on
 * screen is theirs, every kill is against them, and there is nowhere to hide. A populated one is
 * the .io game, where the friend is one snake among several and the win can go to whoever
 * farmed bots best.
 *
 * A FRIEND MATCH SILENTLY MEANT ZERO BOTS BEFORE THIS. That is the better default and it is
 * kept, but it was never a choice and never labelled.
 *
 * Mirrors iOS `DuelSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DuelSheet(
    /** Bot count for the match. 0 is a true duel. */
    onPick: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState()

    // Deliberately three, not a slider. The interesting choice is duel-or-not; the middle option
    // exists so "some bots" is reachable without pretending the exact number matters.
    val options = listOf(
        Triple(0, "Duel", "Just the two of you. Every snake on screen is theirs."),
        Triple(3, "Duel + bots", "A few bots to farm. More room to grow before you meet."),
        Triple(6, "Open arena", "A full lobby. Your friend is one snake among many."),
    )

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = VoiidColor.background,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(
                    start = VoiidSpacing.lg,
                    end = VoiidSpacing.lg,
                    top = VoiidSpacing.sm,
                    bottom = VoiidSpacing.xl,
                ),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            Text(
                "How busy is the arena?",
                color = VoiidColor.textPrimary,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
            )
            // Says it is fixed for both, for the same reason the overs sheet does: it is a
            // property of the match, not of a player, so there is nothing to negotiate after.
            Text(
                "Chosen by you, fixed for both. Locked once the match starts.",
                color = VoiidColor.textSecondary,
                fontSize = 14.sp,
                modifier = Modifier.padding(bottom = VoiidSpacing.sm),
            )

            options.forEach { (bots, title, subtitle) ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(VoiidRadius.lg))
                        .background(VoiidColor.surfaceCard)
                        .clickable { onPick(bots) }
                        .padding(VoiidSpacing.md),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            title,
                            color = VoiidColor.textPrimary,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(subtitle, color = VoiidColor.textSecondary, fontSize = 12.sp)
                    }
                    Text("›", color = VoiidColor.textSecondary, fontSize = 18.sp)
                }
            }
        }
    }
}
