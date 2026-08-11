package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.VoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay

/**
 * The toss, before ball one — shared by the online match and the bot match.
 *
 * TWO STEPS, because that is the real game (backend/games/src/engine/cricket):
 *
 *   1. one side CALLS heads or tails
 *   2. whoever wins the call ELECTS to bat or bowl
 *
 * The election is the part worth having. Choosing to bowl first means batting second knowing the
 * target, which in a two-wicket format is a genuine tactic rather than ceremony — a toss that
 * only decided who bats would be a coin flip with extra taps.
 *
 * PURE PRESENTATION. This composable never decides anything: it reports what the player tapped
 * and renders the state the server (or, offline, the bot match) reports back. The coin itself is
 * decided before anyone can call — see the engine's note on why.
 *
 * Mirrors iOS `CricketToss.swift`. Keep the landing duration identical.
 */
@Composable
fun CricketToss(
    /** "toss-call" | "toss-decide". */
    phase: String,
    /** True when the local player holds the call. */
    iCall: Boolean,
    /** True when the local player won the call and now elects. */
    iElect: Boolean,
    /** Which face landed, once called. Null hides the result. */
    coin: String?,
    /** What the caller said, for the "you called heads" line. */
    called: String?,
    /** Opponent's display name, for the waiting copy. */
    opponentName: String,
    onCall: (String) -> Unit,
    onElect: (String) -> Unit,
) {
    val context = LocalContext.current
    val haptics = remember(context) { VoiidHaptics(context) }

    // True once the coin has stopped, which gates the result copy and the bat/bowl buttons. The
    // SPIN belongs to CoinView; this is only "has it stopped yet", tracked here because the
    // words underneath have to wait for it.
    var settled by remember { mutableStateOf(false) }

    LaunchedEffect(coin) {
        if (coin == null) {
            settled = false
            return@LaunchedEffect
        }
        // MUST MATCH CoinView's landing duration. Revealing the result before the coin stops
        // spoils it; revealing long after reads as a hang.
        delay(LANDING_MS)
        settled = true
        haptics.success()
    }

    Column(
        Modifier.fillMaxSize().padding(horizontal = VoiidSpacing.lg),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CoinView(
            result = coin,
            modifier = Modifier.size(200.dp),
        )

        Spacer(Modifier.size(VoiidSpacing.lg))

        Text(
            headline(phase, iCall, iElect, settled, opponentName),
            style = VoiidFont.rounded(22, FontWeight.Bold),
            color = VoiidColor.textPrimary,
            textAlign = TextAlign.Center,
        )

        val sub = subline(phase, iCall, iElect, settled, called, coin, opponentName)
        if (sub.isNotEmpty()) {
            Spacer(Modifier.size(VoiidSpacing.sm))
            Text(
                sub,
                style = VoiidFont.rounded(14, FontWeight.Normal),
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.size(VoiidSpacing.xl))

        // The buttons appear only once the coin has settled, so a player cannot elect while it
        // is still spinning and miss the result that explains their own choice.
        when {
            phase == "toss-call" && iCall ->
                ChoiceRow(listOf("heads", "tails")) { haptics.tap(); onCall(it) }
            phase == "toss-decide" && iElect && settled ->
                ChoiceRow(listOf("bat", "bowl")) { haptics.tap(); onElect(it) }
        }
    }
}

/** Matches iOS `CoinSceneView`'s landing animation. */
private const val LANDING_MS = 1150L

@Composable
private fun ChoiceRow(options: List<String>, onPick: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        options.forEach { option ->
            Text(
                option.replaceFirstChar { it.uppercase() },
                style = VoiidFont.rounded(17, FontWeight.SemiBold),
                color = VoiidColor.textOnPrimary,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .weight(1f)
                    .clip(CircleShape)
                    .background(VoiidColor.primary)
                    .clickable { onPick(option) }
                    .padding(vertical = VoiidSpacing.md),
            )
        }
    }
}

private fun headline(
    phase: String, iCall: Boolean, iElect: Boolean, settled: Boolean, opponent: String,
): String = when {
    phase == "toss-call" -> if (iCall) "Call the toss" else "$opponent is calling"
    !settled -> "…"
    iElect -> "You won the toss"
    else -> "$opponent won the toss"
}

private fun subline(
    phase: String, iCall: Boolean, iElect: Boolean, settled: Boolean,
    called: String?, coin: String?, opponent: String,
): String {
    if (phase == "toss-call") return if (iCall) "Heads or tails?" else "Waiting for their call…"
    if (!settled) return ""
    val tail = if (iElect) " Bat or bowl?" else " They're deciding…"
    if (called != null && coin != null) {
        val outcome = if (called == coin) "correct" else "wrong"
        return "Called $called — $outcome, it's $coin.$tail"
    }
    return tail.trim()
}
