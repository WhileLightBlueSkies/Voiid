package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
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
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.launch

/**
 * One seeded Snake arena a day, the same for everyone (docs/games/CROSS_CUTTING.md §5,
 * SNAKE_COMPETITIVE_PARITY.md §4 P3.8).
 *
 * THE COMPETITOR'S VERSION IS A LUCKY WHEEL AND A COIN BALANCE. Ours is neither. Their
 * `LuckyWheel`/`ChallengeMetric` cluster exists to make a player open an ad-funded app once a
 * day; the reward is currency, and the currency exists to be bought. Voiid is a messenger, and a
 * free-to-play economy bolted onto a chat app would change what the product is.
 *
 * What survives that cut is the part that was never about money: everyone plays the SAME arena
 * today, so a score is finally comparable. That is one seed and one query.
 *
 * THE BOARD IS GLOBAL, unlike [LeaderboardScreen], and that is not an inconsistency. The
 * ordinary board is scoped to people you have actually played, because a global ranking of a
 * two-player game is a list of strangers you cannot challenge. The daily is the opposite: the
 * comparison is meaningful precisely BECAUSE everyone faced the same food layout and bots.
 *
 * ONE ATTEMPT A DAY, enforced by a unique index rather than by this screen.
 *
 * Mirrors iOS `DailyChallengeView.swift`.
 */
@Composable
fun DailyChallengeScreen(
    /** Opens the arena once today's run has been minted. */
    onPlay: (String) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = remember(context) { VoiidHaptics(context) }
    val service = remember(context) { GamesService(ApiClient(TokenStore.get(context))) }
    val scope = rememberCoroutineScope()

    var data by remember { mutableStateOf<GamesService.DailyResponse?>(null) }
    var loading by remember { mutableStateOf(true) }
    var failed by remember { mutableStateOf(false) }
    var starting by remember { mutableStateOf(false) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(reload) {
        loading = true
        failed = false
        runCatching { service.daily() }
            .onSuccess { data = it }
            .onFailure { failed = true }
        loading = false
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .padding(horizontal = VoiidSpacing.md),
    ) {
        Row(Modifier.fillMaxWidth().padding(vertical = VoiidSpacing.md),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = VoiidColor.textPrimary,
                modifier = Modifier.clickable { onClose() },
            )
            Text(
                "Daily challenge",
                color = VoiidColor.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f),
            )
            Box(Modifier.size(24.dp))
        }

        when {
            loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VoiidColor.primary)
            }

            failed -> Column(
                Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text("Couldn't load today's challenge",
                    color = VoiidColor.textPrimary, fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold)
                Text("Try again",
                    color = VoiidColor.primary, fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = VoiidSpacing.sm).clickable { reload++ })
            }

            else -> {
                val d = data
                LazyColumn(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                    item {
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(VoiidRadius.lg))
                                .background(VoiidColor.surfaceCard)
                                .padding(VoiidSpacing.md),
                            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                        ) {
                            Text(
                                "Everyone plays the same arena today — same food, same bots. " +
                                    "One run each.",
                                color = VoiidColor.textSecondary,
                                fontSize = 14.sp,
                            )

                            val mine = d?.mine
                            if (mine != null) {
                                // Their own result, stated plainly. A player who already played
                                // needs their number more than they need a disabled button
                                // explaining itself.
                                Text(
                                    mine.score?.let { "You scored $it. Back tomorrow." }
                                        ?: "Your run is still going.",
                                    color = VoiidColor.textPrimary,
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.SemiBold,
                                )
                            } else {
                                Box(
                                    Modifier
                                        .fillMaxWidth()
                                        .clip(CircleShape)
                                        .background(VoiidColor.primary)
                                        .clickable(enabled = !starting) {
                                            haptics.tap()
                                            starting = true
                                            scope.launch {
                                                val choice = SnakeChoiceStore(context)
                                                runCatching { service.startDaily(choice.skinId) }
                                                    .onSuccess { starting = false; onPlay(it) }
                                                    .onFailure {
                                                        starting = false
                                                        // A 409 means they already played —
                                                        // the rule, not a failure. Reloading
                                                        // turns the button into their result
                                                        // rather than showing an error for
                                                        // working correctly.
                                                        reload++
                                                    }
                                            }
                                        }
                                        .padding(vertical = VoiidSpacing.md),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (starting) {
                                        CircularProgressIndicator(
                                            color = VoiidColor.textOnPrimary,
                                            strokeWidth = 2.dp,
                                            modifier = Modifier.size(18.dp),
                                        )
                                    } else {
                                        Text("Play today's arena",
                                            color = VoiidColor.textOnPrimary,
                                            fontSize = 16.sp, fontWeight = FontWeight.Bold)
                                    }
                                }
                            }
                        }
                    }

                    val rows = d?.leaderboard.orEmpty()
                    if (rows.isEmpty()) {
                        item {
                            // Says the board is empty AND why that is an opportunity. "No scores
                            // yet" alone reads as a broken screen.
                            Text(
                                "Nobody has finished today's arena yet. First score sets the mark.",
                                color = VoiidColor.textSecondary,
                                fontSize = 14.sp,
                                textAlign = TextAlign.Center,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = VoiidSpacing.md,
                                             start = VoiidSpacing.lg, end = VoiidSpacing.lg),
                            )
                        }
                    } else {
                        itemsIndexed(rows) { index, row -> DailyRowView(index + 1, row) }
                    }

                    item { Spacer(Modifier.size(VoiidSpacing.xl)) }
                }
            }
        }
    }
}

@Composable
private fun DailyRowView(rank: Int, row: GamesService.DailyRow) {
    Row(
        Modifier
            .fillMaxWidth()
            .scale(if (rank == 1) 1.02f else 1f)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .padding(VoiidSpacing.md),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Box(
            Modifier
                .size(36.dp)
                .background(
                    if (rank == 1) VoiidColor.primary else VoiidColor.primary.copy(alpha = 0.12f),
                    CircleShape,
                ),
            contentAlignment = Alignment.Center,
        ) {
            Text("$rank",
                color = if (rank == 1) VoiidColor.textOnPrimary else VoiidColor.primary,
                fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }

        // USERNAME FIRST on this board, where the ordinary leaderboard prefers a full name. That
        // board only ever lists people you have played; this one is global, so it puts strangers'
        // names in front of each other and a handle is the identity a player chose to be public.
        Text(
            row.username ?: row.full_name ?: "Someone",
            color = VoiidColor.textPrimary,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f),
        )

        Text("${row.score}",
            color = VoiidColor.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.Bold)
    }
}
