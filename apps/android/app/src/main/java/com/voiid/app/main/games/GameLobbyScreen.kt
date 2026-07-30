package com.voiid.app.main.games

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.ApiClient
import com.voiid.app.net.GameInvite
import com.voiid.app.net.GamesEngine
import com.voiid.app.net.GamesService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay

/**
 * The waiting room between sending an invite and the board opening.
 *
 * WHY THIS EXISTS. Creating a match used to drop the creator straight onto a board that could not
 * be played — the opponent hadn't joined, so no `game_state` frame ever arrived and the screen sat
 * on "Setting up the match…" forever. Worse, from the home screen it looked like nothing had
 * happened at all. A lobby makes the actual state legible: the invite is sent, we are waiting, and
 * here is how long they have.
 *
 * IT WATCHES FOR THE SAME FRAME THE BOARD DOES. The opponent joining is what makes the server build
 * and broadcast the opening state, so a non-null game state IS the signal that the match is live —
 * no extra "they joined" message is needed, and none exists. [onStart] fires on that frame.
 *
 * THE COUNTDOWN IS REAL. At expiry the invite is dead server-side (a 'waiting' match nobody joined),
 * so the lobby abandons it rather than leaving a phantom row that would show up in the opponent's
 * banners forever.
 *
 * Mirrors iOS `GameLobbyView.swift`.
 */
/**
 * Everything the lobby needs to describe itself, captured when the invite was sent.
 *
 * Passed in rather than re-fetched: the creator already knows the game, the opponent and the
 * settings — a round-trip to learn what they just chose would be a spinner for no reason.
 */
data class LobbyArgs(
    val matchId: String,
    val slug: String,
    val gameName: String,
    val opponentName: String,
    val detailLine: String,
)

@Composable
fun GameLobbyScreen(
    matchId: String,
    slug: String,
    gameName: String,
    opponentName: String,
    detailLine: String,
    onStart: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val engine = GamesEngine.get(context)
    // Any of the three game states arriving means the server built the board — which only happens
    // once the opponent joins.
    val tttState by engine.state.collectAsState()
    val rpsState by engine.rps.collectAsState()
    val cricketState by engine.cricket.collectAsState()

    val service = remember { GamesService(ApiClient(TokenStore.get(context))) }
    var expiresIn by remember { mutableLongStateOf(GameInvite.EXPIRY_MS) }
    var expired by remember { mutableStateOf(false) }

    val artId = remember(slug) {
        context.resources.getIdentifier("game_$slug", "drawable", context.packageName)
    }

    // The opponent joined — hand off to the board.
    LaunchedEffect(tttState, rpsState, cricketState) {
        if (tttState != null || rpsState != null || cricketState != null) onStart()
    }

    // Countdown. One tick a second is enough for a minutes-scale timer and costs nothing.
    LaunchedEffect(matchId) {
        val deadline = System.currentTimeMillis() + GameInvite.EXPIRY_MS
        while (true) {
            val left = deadline - System.currentTimeMillis()
            expiresIn = left.coerceAtLeast(0)
            if (left <= 0) break
            delay(1000)
        }
        // Nobody came. Abandon it so the row can't linger as a live invite on their side.
        expired = true
        runCatching { service.decline(matchId) }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .padding(horizontal = VoiidSpacing.lg),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(Modifier.fillMaxWidth().padding(top = VoiidSpacing.md)) {
            Text(
                "Cancel",
                color = VoiidColor.primary,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable {
                        // Leaving the lobby abandons the match: a 'waiting' row nobody will ever
                        // join is exactly what decline is for.
                        engine.leave()
                        onClose()
                    }
                    .padding(vertical = 4.dp, horizontal = 4.dp),
            )
        }

        Spacer(Modifier.weight(1f))

        // The game, as a poster — the same artwork the invite carries, so the two read as one thing.
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(4f / 3f)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.primary.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            if (artId != 0) {
                Image(
                    painter = painterResource(artId),
                    contentDescription = gameName,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
                Box(
                    Modifier
                        .fillMaxSize()
                        .background(
                            Brush.verticalGradient(
                                0.5f to Color.Transparent,
                                1f to Color.Black.copy(alpha = 0.5f),
                            )
                        )
                )
            } else {
                Icon(
                    Icons.Outlined.SportsEsports, null,
                    tint = VoiidColor.primary, modifier = Modifier.size(48.dp),
                )
            }
        }

        Text(
            gameName,
            color = VoiidColor.textPrimary,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(top = VoiidSpacing.md),
        )
        if (detailLine.isNotBlank()) {
            Text(detailLine, color = VoiidColor.textSecondary, fontSize = 14.sp)
        }

        if (expired) {
            Text(
                "$opponentName didn't join",
                color = VoiidColor.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = VoiidSpacing.lg),
                textAlign = TextAlign.Center,
            )
            Text(
                "The invite expired. Send another whenever you like.",
                color = VoiidColor.textSecondary,
                fontSize = 13.sp,
                modifier = Modifier.padding(top = 4.dp),
                textAlign = TextAlign.Center,
            )
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(top = VoiidSpacing.lg)
                    .clip(CircleShape)
                    .background(VoiidColor.primary)
                    .clickable { engine.leave(); onClose() }
                    .padding(vertical = VoiidSpacing.md),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "Back to games",
                    color = VoiidColor.textOnPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        } else {
            // Breathing dots: a waiting state needs to look alive, or it reads as frozen.
            val pulse = rememberInfiniteTransition(label = "wait")
            val a by pulse.animateFloat(
                initialValue = 0.35f, targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    tween(900, easing = LinearEasing), RepeatMode.Reverse,
                ),
                label = "dots",
            )
            Row(
                Modifier.padding(top = VoiidSpacing.lg),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                repeat(3) { i ->
                    Box(
                        Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .alpha(if (i == 0) a else if (i == 1) (a * 0.8f) else (a * 0.6f))
                            .background(VoiidColor.primary)
                    )
                }
            }
            Text(
                "Waiting for $opponentName…",
                color = VoiidColor.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = VoiidSpacing.sm),
                textAlign = TextAlign.Center,
            )
            Text(
                "Invite sent in chat · expires in ${formatCountdown(expiresIn)}",
                color = VoiidColor.textSecondary,
                fontSize = 13.sp,
                modifier = Modifier.padding(top = 4.dp),
                textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.weight(1f))
    }
}

/** "9:04" — a countdown, not a duration. Seconds are zero-padded so it doesn't jitter in width. */
internal fun formatCountdown(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0)
    return "${total / 60}:${(total % 60).toString().padStart(2, '0')}"
}
