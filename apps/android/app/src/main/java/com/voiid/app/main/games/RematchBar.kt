package com.voiid.app.main.games

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.ApiClient
import com.voiid.app.net.GamesService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.VoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.launch

/**
 * What to do once an online match is over: play them again, or leave.
 *
 * THE HIGHEST-VALUE MISSING BUTTON IN THE PRODUCT (docs/games/CROSS_CUTTING.md §1). Two people
 * who just finished a match are the two most likely to play another in the next thirty seconds,
 * and until now that took going back to the Games tab, picking the game, picking the friend,
 * sending a fresh invite, and waiting for them to accept it.
 *
 * ONLINE ONLY. The bot screens already have "Play again", which is a local reset and needs no
 * server. This is for matches with a real opponent, where a rematch is a new row, a new invite
 * and a fresh permission check.
 *
 * Mirrors iOS `RematchBar.swift`.
 */
@Composable
fun RematchBar(
    /** The match that just finished. Its id is what the server clones. */
    matchId: String,
    /** Opens the new match once the server has minted it. */
    onRematch: (String) -> Unit,
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val haptics = remember(context) { VoiidHaptics(context) }
    val service = remember(context) { GamesService(ApiClient(TokenStore.get(context))) }
    val scope = rememberCoroutineScope()

    var requesting by remember { mutableStateOf(false) }
    // Shown inline rather than as a dialog: a dialog for "they left" is a modal to dismiss on
    // top of a match that is already over.
    var failure by remember { mutableStateOf<String?>(null) }

    Column(modifier.fillMaxWidth().padding(top = VoiidSpacing.lg)) {
        AnimatedVisibility(visible = failure != null, enter = fadeIn(), exit = fadeOut()) {
            Text(
                failure.orEmpty(),
                color = VoiidColor.textSecondary,
                fontSize = 13.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.sm),
            )
        }

        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
            Box(
                Modifier
                    .weight(1f)
                    .clip(CircleShape)
                    .background(VoiidColor.primary)
                    // Disabled WHILE IN FLIGHT, not after failing: a rematch refused because
                    // the opponent was momentarily unreachable should be retryable without
                    // leaving the screen.
                    .clickable(enabled = !requesting) {
                        haptics.tap()
                        requesting = true
                        failure = null
                        scope.launch {
                            runCatching { service.rematch(matchId) }
                                .onSuccess { requesting = false; onRematch(it) }
                                .onFailure {
                                    requesting = false
                                    // DELIBERATELY VAGUE, and deliberately not the server's
                                    // message. The route returns 403 without naming which
                                    // player failed, so it cannot be used to probe whether a
                                    // user id exists or is in your contacts; echoing a raw
                                    // error here would undo that.
                                    failure = "Couldn't start a rematch. They may have left."
                                }
                        }
                    }
                    .padding(vertical = VoiidSpacing.md),
                contentAlignment = Alignment.Center,
            ) {
                if (requesting) {
                    CircularProgressIndicator(
                        color = VoiidColor.textOnPrimary,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(18.dp),
                    )
                } else {
                    Text(
                        "Rematch",
                        color = VoiidColor.textOnPrimary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }

            Text(
                "Exit",
                color = VoiidColor.textPrimary,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .weight(1f)
                    .clip(CircleShape)
                    .background(VoiidColor.fieldFill)
                    .clickable { haptics.tap(); onExit() }
                    .padding(vertical = VoiidSpacing.md),
            )
        }
    }
}
