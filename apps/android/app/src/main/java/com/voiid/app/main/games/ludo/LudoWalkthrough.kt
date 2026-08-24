package com.voiid.app.main.games.ludo

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.LudoPalette
import com.voiid.app.ui.theme.VoiidColor

/**
 * First-run rules walkthrough (§10): version 1, seven steps, a bottom sheet no higher than 30%
 * of the screen so the highlighted REAL cells stay visible. It is a LOCAL DEMO built from the
 * same 15×15 renderer and geometry — never networked, never after a live match started.
 *
 * The capture demonstration MUST use track index 7 (index 8 is safe) — that invariant lives in
 * the tutorial snapshot test on the backend and the step table below.
 */
object LudoWalkthrough {
    const val VERSION = 1

    data class Step(val copy: String)

    val STEPS = listOf(
        Step("Tap the die to roll."),
        Step("A six brings a pawn out."),
        Step("Move by the number shown."),
        Step("Land on a rival to send it home."),   // demo target: track index 7 (NOT safe)
        Step("Stars and colored starts are safe."),
        Step("Finish through your colored lane."),
        Step("Bring all four pawns home to win."),
    )

    /** Demo state per step, rendered through LudoBoardDraw with a local TutorialState. */
    fun tutorialState(step: Int): LudoGameState {
        val Y = LudoRules.YARD
        val tokens: List<List<Int>> = when (step) {
            0 -> listOf(listOf(Y, Y, Y, Y), listOf(Y, Y, Y, Y))
            1 -> listOf(listOf(LudoRules.startIndex(0), Y, Y, Y), listOf(Y, Y, Y, Y))
            2 -> listOf(listOf(4, Y, Y, Y), listOf(Y, Y, Y, Y))
            // CAPTURE DEMO TARGETS TRACK INDEX 7 — non-safe by construction.
            3 -> listOf(listOf(7, Y, Y, Y), listOf(Y, Y, Y, Y))
            4 -> listOf(listOf(13, Y, Y, Y), listOf(13, Y, Y, Y))   // two colors coexist on safe 13
            5 -> listOf(listOf(LudoRules.HOME_LANE_BASE + 3, Y, Y, Y), listOf(Y, Y, Y, Y))
            else -> listOf(
                listOf(LudoRules.FINISHED, LudoRules.FINISHED, LudoRules.FINISHED, LudoRules.FINISHED),
                listOf(Y, Y, Y, Y),
            )
        }
        return LudoGameState(
            schemaVersion = LudoRules.SCHEMA_VERSION,
            rulesVersion = LudoRules.RULES_VERSION,
            mode = "duel",
            status = "active",
            serverNow = 0,
            viewerSeat = 0,
            seats = listOf(
                seatView(0, "@you"),
                seatView(2, "@rival"),
            ),
            tokensPerSeat = 4,
            tokens = tokens + emptyList(),
            turn = null,
            lastAction = null,
            winnerSeat = if (step == 6) 0 else null,
            endReason = if (step == 6) "win" else null,
            seedCommitment = null,
            seq = 0,
        )
    }

    private fun seatView(seat: Int, name: String) = LudoSeatView(
        seat = seat,
        seatId = "demo-$seat",
        color = LudoSeatColor.RED,
        displayName = name,
        participation = "active",
        connection = "connected",
        timeoutStreak = 0,
        finishedPawns = 0,
        captures = 0,
    )
}

enum class DemoMode { FirstRun, Sandbox }

/**
 * The sheet itself. Persistent Skip in the top-right dismisses ALL steps in one tap; both skip
 * and Done write local seen state immediately and fire the cross-device sync upstream.
 */
@Composable
fun LudoWalkthroughSheet(
    demoMode: DemoMode,
    clockNote: Boolean,
    onDismiss: () -> Unit,
) {
    var step by remember { mutableIntStateOf(0) }
    val context = LocalContext.current
    fun markSeen() {
        com.voiid.app.net.GamesEngine.get(context).markLudoWalkthroughSeen(context)
    }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(com.voiid.app.ui.theme.VoiidColor.surfaceCard)
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "How to play · ${step + 1} of ${LudoWalkthrough.STEPS.size}",
                fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                color = LudoPalette.textPrimary(),
                modifier = Modifier.weight(1f),
            )
            Text(
                "Skip",
                fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                color = VoiidColor.primary,
                modifier = Modifier
                    .clickable {
                        markSeen()
                        onDismiss()   // one tap dismisses all steps (§10)
                    }
                    .padding(8.dp),
            )
        }
        if (clockNote && demoMode == DemoMode.Sandbox) {
            Text(
                "The clock keeps running",
                fontSize = 12.sp,
                color = LudoPalette.textSecondary(),
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        Spacer(Modifier.height(10.dp))

        // Real board demo, dimmed to 35% except the highlighted cells for this step.
        WalkthroughBoard(step)

        Spacer(Modifier.height(10.dp))
        Text(
            LudoWalkthrough.STEPS[step].copy,
            fontSize = 15.sp,
            color = LudoPalette.textPrimary(),
        )
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
            if (step > 0) {
                androidx.compose.material3.TextButton(onClick = { step-- }) { Text("Back") }
            }
            Spacer(Modifier.weight(1f))
            androidx.compose.material3.Button(onClick = {
                if (step < LudoWalkthrough.STEPS.lastIndex) {
                    step++
                } else {
                    markSeen()
                    onDismiss()
                }
            }) {
                Text(if (step < LudoWalkthrough.STEPS.lastIndex) "Next" else "Done")
            }
        }
    }
}

@Composable
private fun WalkthroughBoard(step: Int) {
    val darkNow = !com.voiid.app.ui.theme.LocalVoiidDark.current
    val wColors = com.voiid.app.ui.theme.ludoPaletteFor(darkNow)
    androidx.compose.foundation.Canvas(
        Modifier
            .fillMaxWidth()
            .height(220.dp),
    ) {
        val state = LudoWalkthrough.tutorialState(step)
        LudoBoardDraw.drawAll(
            scope = this,
            colors = wColors,
            state = state,
            placedPawns = pawnCenters(state, size.width),
            highlightCells = highlightForStep(step),
            sweep = null,
            darkTheme = darkNow,
            reduceMotion = true,
        )
    }
}

private fun pawnCenters(state: LudoGameState, sidePx: Float): List<LudoPawnLayer.PlacedPawn> {
    val layout = LudoBoardGeometry.Layout(sidePx)
    return LudoPawnLayer.layout(state, layout, emptySet())
}

private fun highlightForStep(step: Int): Set<String> = when (step) {
    1 -> setOf(cellKey(2, 11), cellKeyFromTrack(0))
    2 -> (1..4).map { i ->
        val c = LudoBoardGeometry.TRACK_COORDS[i]
        "cell-${c.first}-${c.second}"
    }.toSet()
    3 -> setOf(cellKeyFromTrack(7))
    4 -> setOf(cellKeyFromTrack(13), cellKeyFromTrack(21), cellKeyFromTrack(26), cellKeyFromTrack(34),
               cellKeyFromTrack(39), cellKeyFromTrack(47), cellKeyFromTrack(0), cellKeyFromTrack(8))
    5 -> (LudoRules.HOME_LANE_BASE until LudoRules.HOME_LANE_BASE + 5).mapNotNull { pos ->
        LudoBoardGeometry.HOME_LANE_COORDS[0][pos - LudoRules.HOME_LANE_BASE]
            .let { "cell-${it.first}-${it.second}" }
    }.toSet()
    else -> emptySet()
}

private fun cellKey(x: Int, y: Int) = "cell-$x-$y"
private fun cellKeyFromTrack(i: Int) =
    LudoBoardGeometry.TRACK_COORDS[i].let { "cell-${it.first}-${it.second}" }

