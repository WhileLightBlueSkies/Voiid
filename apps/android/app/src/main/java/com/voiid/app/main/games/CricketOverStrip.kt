package com.voiid.app.main.games

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.GamesEngine
import com.voiid.app.ui.theme.VoiidColor

/**
 * The current over, ball by ball — the strip every cricket broadcast puts on screen.
 *
 * WHY IT MATTERS HERE. Hand Cricket's scoreboard says 34-1 in 1.3 overs, which is the state but
 * not the STORY. "· 4 W 2 – –" says the over started quietly, went for four, took a wicket, and
 * has two balls left. That is what a player actually reasons about when deciding whether to push
 * for runs or block, and until now none of it was on screen: the pitch showed the last ball and
 * then forgot it.
 *
 * DERIVED, NOT STORED. Every ball is already in `history` with its innings, so the strip is a
 * filter and a slice — no new state, nothing to keep in sync, and it is automatically right after
 * a reconnect or a rejoin.
 *
 * Mirrors iOS `CricketOverStrip.swift`.
 */
@Composable
fun CricketOverStrip(
    /** Every ball bowled in the match so far, oldest first. */
    history: List<GamesEngine.CricketState.Ball>,
    /** The innings being played right now — first-innings balls must not leak into the second. */
    innings: Int,
    /** Balls bowled in THIS innings, which is where the over boundary comes from. */
    ballsBowled: Int,
    modifier: Modifier = Modifier,
) {
    val ballsPerOver = 6

    // Balls bowled in the CURRENT over only. Taken from the tail of this innings' history rather
    // than counted forward, so a match joined mid-over still shows the right beads.
    val mine = history.filter { it.innings == innings }
    val done = ballsBowled % ballsPerOver
    // A completed over reads as full until the next ball lands, rather than snapping to empty
    // the instant the sixth is bowled — the player is still looking at it.
    val count = if (done == 0 && mine.isNotEmpty()) ballsPerOver else done
    val thisOver = mine.takeLast(count)

    Row(
        modifier.semantics { contentDescription = spoken(thisOver, ballsBowled, ballsPerOver) },
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            // 1-based, because nobody says "over 1" meaning the second one.
            "Over ${ballsBowled / ballsPerOver + 1}",
            color = VoiidColor.textSecondary,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(end = 2.dp),
        )

        repeat(ballsPerOver) { i ->
            val ball = thisOver.getOrNull(i)
            // A ball that has just landed pops, so the eye is drawn to the newest bead rather
            // than having to find it.
            val pop by animateFloatAsState(
                targetValue = if (i == thisOver.size - 1) 1f else 0.92f,
                animationSpec = spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMedium),
                label = "bead$i",
            )
            Box(
                Modifier
                    .size(24.dp)
                    .scale(pop)
                    .clip(CircleShape)
                    .background(beadBackground(ball)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    beadText(ball),
                    color = beadForeground(ball),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

/**
 * Broadcast shorthand: W for a wicket, · for a dot, the number otherwise. Future balls are an em
 * dash, which is what makes "how much is left" readable at a glance.
 */
private fun beadText(ball: GamesEngine.CricketState.Ball?): String = when {
    ball == null -> "–"
    ball.wicket -> "W"
    ball.runs == 0 -> "·"
    else -> "${ball.runs}"
}

@Composable
private fun beadForeground(ball: GamesEngine.CricketState.Ball?): Color = when {
    ball == null -> VoiidColor.textSecondary.copy(alpha = 0.5f)
    ball.wicket -> Color.White
    ball.runs >= 4 -> Color.White
    else -> VoiidColor.textPrimary
}

@Composable
private fun beadBackground(ball: GamesEngine.CricketState.Ball?): Color = when {
    ball == null -> VoiidColor.fieldFill.copy(alpha = 0.4f)
    ball.wicket -> Color(0xFFB32929)
    // Boundaries get the accent, so a good over is legible as a shape before it is read.
    ball.runs >= 4 -> VoiidColor.primary
    ball.runs == 0 -> VoiidColor.fieldFill
    else -> VoiidColor.fieldFill.copy(alpha = 0.85f)
}

private fun spoken(
    over: List<GamesEngine.CricketState.Ball>, ballsBowled: Int, ballsPerOver: Int,
): String {
    val label = "Over ${ballsBowled / ballsPerOver + 1}"
    if (over.isEmpty()) return "$label, no balls bowled yet"
    return "$label: " + over.joinToString(", ") {
        when {
            it.wicket -> "wicket"
            it.runs == 0 -> "dot"
            else -> "${it.runs}"
        }
    }
}
