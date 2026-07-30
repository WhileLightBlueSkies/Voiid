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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * Match length for hand cricket, 1–5 overs (docs/GAMES_HAND_CRICKET.md §2).
 *
 * A SEPARATE STEP RATHER THAN A ROW ON [GameSetupSheet]: that sheet asks one question — who are
 * you playing — and stacking an unrelated second question onto it would make it the place every
 * decision goes. This appears only for the one game that has a length to choose.
 *
 * CHOSEN BY THE CREATOR, FIXED FOR BOTH. Match length is a property of the match, not of a
 * player, so there is nothing to negotiate: the invitee joins a 3-over game the same way they
 * join a game already in progress.
 *
 * Mirrors iOS `OversSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OversSheet(
    onPick: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = VoiidColor.background,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = VoiidSpacing.md)
                .padding(bottom = VoiidSpacing.xl),
        ) {
            Text(
                "How many overs?",
                color = VoiidColor.textPrimary,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
            )
            Text(
                "6 balls each. 2 wickets. Locked once the match starts.",
                color = VoiidColor.textSecondary,
                fontSize = 14.sp,
                modifier = Modifier.padding(top = 4.dp, bottom = VoiidSpacing.lg),
            )
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                (1..5).forEach { n ->
                    Box(
                        Modifier
                            .weight(1f)
                            .size(56.dp)
                            .clip(CircleShape)
                            .background(VoiidColor.fieldFill)
                            .clickable { onPick(n) },
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            "$n",
                            color = VoiidColor.textPrimary,
                            fontSize = 20.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }
    }
}
