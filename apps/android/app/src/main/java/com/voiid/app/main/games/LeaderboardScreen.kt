package com.voiid.app.main.games

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
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
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * Who has beaten whom, among people you actually play (docs/GAMES.md §3).
 *
 * ONLY REFEREED MATCHES COUNT. Every row here comes from `game_match_results`, written by
 * the games service when a real match ended — practice wins against the local bot are
 * deliberately excluded, because a client-reported score is an unverifiable claim and this
 * board is the one place in the feature where the number has to mean something.
 *
 * Ranked by wins, then games played. Draws are shown separately rather than folded into
 * losses: Tic Tac Toe draws constantly, and calling a draw a loss would make almost
 * everyone look worse than they are.
 *
 * Mirrors iOS `LeaderboardView.swift`.
 */
@Composable
fun LeaderboardScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val service = remember { GamesService(ApiClient(TokenStore.get(context))) }

    var rows by remember { mutableStateOf<List<GamesService.LeaderboardRow>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var failed by remember { mutableStateOf(false) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(reload) {
        loading = true
        failed = false
        runCatching { service.leaderboard() }
            .onSuccess { rows = it }
            .onFailure {
                failed = true
                // LOG THE CAUSE. Discarding it is why a server-side SQL error looked
                // indistinguishable from being offline for this screen's entire life — the UI said
                // "couldn't load" and nothing, anywhere, said why.
                android.util.Log.w("Leaderboard", "load failed: ${it.message}", it)
            }
        loading = false
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .padding(horizontal = VoiidSpacing.md),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = VoiidSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = VoiidColor.textPrimary,
                modifier = Modifier.clickable { onClose() },
            )
            Text(
                "Leaderboard",
                color = VoiidColor.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.size(24.dp))
        }

        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            when {
                loading -> CircularProgressIndicator(color = VoiidColor.primary)

                failed -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        "Couldn't load the leaderboard",
                        color = VoiidColor.textPrimary,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        "Try again",
                        color = VoiidColor.primary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(top = VoiidSpacing.sm).clickable { reload++ },
                    )
                }

                rows.isEmpty() -> Text(
                    "Play a friend to start a record. Practice games don't count here.",
                    color = VoiidColor.textSecondary,
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = VoiidSpacing.lg),
                )

                else -> LazyColumn(
                    Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                ) {
                    itemsIndexed(rows, key = { _, r -> r.opponent_id }) { i, row ->
                        LeaderRow(rank = i + 1, row = row)
                    }
                }
            }
        }
    }
}

@Composable
private fun LeaderRow(rank: Int, row: GamesService.LeaderboardRow) {
    // The top row swells slightly — a cheap way to make first place read as first place
    // without a trophy icon competing with the numbers.
    val scale by animateFloatAsState(
        targetValue = if (rank == 1) 1.02f else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy),
        label = "rank",
    )
    val name = row.full_name ?: row.username ?: "Unknown"

    Row(
        Modifier
            .fillMaxWidth()
            .scale(scale)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .padding(VoiidSpacing.md),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Box(
            Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(
                    if (rank == 1) VoiidColor.primary else VoiidColor.primary.copy(alpha = 0.12f)
                ),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                "$rank",
                color = if (rank == 1) VoiidColor.textOnPrimary else VoiidColor.primary,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
            )
        }

        Column(Modifier.weight(1f)) {
            Text(name, color = VoiidColor.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(
                "${row.played} played",
                color = VoiidColor.textSecondary,
                fontSize = 12.sp,
            )
        }

        // W / D / L from the CALLER's point of view — "wins" is how many times you beat
        // this person, which is the number people actually argue about.
        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md)) {
            Tally("W", row.wins, VoiidColor.success)
            Tally("D", row.draws, VoiidColor.textSecondary)
            Tally("L", row.losses, VoiidColor.error)
        }
    }
}

@Composable
private fun Tally(label: String, value: Int, color: androidx.compose.ui.graphics.Color) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("$value", color = color, fontSize = 16.sp, fontWeight = FontWeight.Bold)
        Text(label, color = VoiidColor.textSecondary, fontSize = 10.sp)
    }
}
