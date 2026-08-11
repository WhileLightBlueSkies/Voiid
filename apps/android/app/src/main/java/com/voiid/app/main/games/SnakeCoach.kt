package com.voiid.app.main.games

import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlin.math.hypot

/**
 * Teaching Snake by playing it, once (docs/games/SNAKE_COMPETITIVE_PARITY.md §4 P2.6).
 *
 * The competitor ships a `TutorialGameMode` with a `TutorialSnakeBot` and a `TutorialTouchZone`
 * — a whole parallel mode. We deliberately do not, for two reasons.
 *
 * A separate mode is a second arena to keep in step with the real one: every change to
 * steering, boost or death has to be made twice, and the day they drift the tutorial teaches
 * something false. And a scripted opponent is a lie a player can feel — they beat it, then meet
 * a real bot and discover the game they were taught is not the game they are playing.
 *
 * So this is a coach, not a mode. It rides on top of an ordinary match: real bots, real stakes,
 * real death. It only ever ADDS one line of text at a time and never blocks input, because a
 * tutorial that takes the controls away is a slideshow with extra steps.
 *
 * IT RUNS ONCE. The flag is set the moment the last step is reached, not when the match ends,
 * so a player who learns the game and then dies does not get taught it again.
 *
 * Mirrors iOS `SnakeCoach.swift`.
 */
enum class SnakeCoachStep(val text: String, val icon: ImageVector) {
    /**
     * Steering. Cleared by moving at all — the check is on distance travelled, not on the
     * control being touched, so it works identically for both schemes (P1.5) rather than
     * hard-coding the joystick the way a `TutorialTouchZone` would.
     */
    STEER("Steer with your thumb — your snake never stops moving.", Icons.Filled.TouchApp),

    /** Eating. Cleared by mass going up, which is the only definition of "ate" the player has. */
    EAT("Eat the dots. Every one makes you longer.", Icons.Outlined.Circle),

    /**
     * Boosting. Cleared by the boost actually engaging — not the button being held, since below
     * the fuel floor holding it does nothing and teaching otherwise would be teaching a bug.
     */
    BOOST("Hold boost to sprint. It burns the length you just ate.", Icons.Filled.Bolt),

    /**
     * The rule that kills people. Cleared on a timer: there is no safe way to make a player
     * demonstrate dying, so this one is told rather than tested.
     */
    RULE(
        "You die by touching another snake's body. Their head hitting yours is their problem.",
        Icons.Filled.Warning,
    ),
}

/** Drives the steps and remembers that it has run. */
class SnakeCoach(context: Context, enabled: Boolean) {
    private val prefs = context.getSharedPreferences("voiid.games", Context.MODE_PRIVATE)

    /** Null once there is nothing left to teach. */
    val step = mutableStateOf<SnakeCoachStep?>(null)

    /**
     * Where the snake was when the current step began, so STEER can measure movement rather
     * than trust a control callback.
     */
    private var origin: Offset? = null
    private var massAtStart: Int? = null

    /**
     * Guards against a step being cleared by state that was already true when it opened — a
     * player who happens to be boosting when BOOST appears has not been taught anything.
     */
    private var openedAt = 0L

    init {
        // Nothing to do for a player who has already been through it. Constructing the coach
        // and immediately finishing keeps the arena's wiring identical either way.
        step.value = if (enabled && !prefs.getBoolean(KEY, false)) SnakeCoachStep.STEER else null
    }

    /** Called on every HUD publish with the live match state. */
    fun update(head: Offset, mass: Int, boostActive: Boolean) {
        val current = step.value ?: return
        if (origin == null) {
            origin = head
            massAtStart = mass
            openedAt = System.currentTimeMillis()
        }

        // Every step holds for a beat before it can clear. A line that vanishes the instant it
        // appears was never read, and the player is left knowing something changed but not what.
        val shown = (System.currentTimeMillis() - openedAt) / 1000.0
        if (shown <= 1.4) return

        val done = when (current) {
            SnakeCoachStep.STEER -> {
                val o = origin ?: head
                hypot((head.x - o.x).toDouble(), (head.y - o.y).toDouble()) > 240
            }
            SnakeCoachStep.EAT -> mass > (massAtStart ?: mass)
            SnakeCoachStep.BOOST -> boostActive
            // Told, not tested — so it clears on reading time. Longer than the others because
            // it is the longest line and the only one that is not confirmed by doing.
            SnakeCoachStep.RULE -> shown > 6
        }

        if (done) advance()
    }

    private fun advance() {
        val next = SnakeCoachStep.entries.getOrNull((step.value?.ordinal ?: 0) + 1)
        step.value = next
        origin = null
        massAtStart = null
        openedAt = System.currentTimeMillis()
        // Set on reaching the END, not on the match ending. A player who has been shown all four
        // lines has been taught; whether they then survive is not the coach's business, and
        // re-teaching someone who died once is how a tutorial becomes a nag.
        if (next == null) prefs.edit().putBoolean(KEY, true).apply()
    }

    private companion object {
        const val KEY = "voiid.snake.coached"
    }
}

/**
 * The one line, at the top of the arena.
 *
 * Positioned under the HUD rather than over the middle of the board: the middle is where the
 * snake is, and covering the thing you are teaching someone to look at defeats the purpose.
 */
@Composable
fun SnakeCoachBanner(step: SnakeCoachStep?, modifier: Modifier = Modifier) {
    AnimatedVisibility(
        visible = step != null,
        // Down from above and out upward: the banner belongs to the HUD it sits under, so it
        // enters and leaves from the same edge rather than appearing from nothing.
        enter = slideInVertically { -it } + fadeIn(),
        exit = slideOutVertically { -it } + fadeOut(),
        modifier = modifier,
    ) {
        // Held so the text does not blank out mid-exit, once `step` has already gone null.
        val shown = step ?: SnakeCoachStep.RULE
        Row(
            Modifier
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(Color.Black.copy(alpha = 0.55f))
                .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(VoiidRadius.lg))
                .padding(horizontal = VoiidSpacing.md, vertical = VoiidSpacing.sm),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            Icon(
                shown.icon,
                contentDescription = null,
                tint = VoiidColor.primary,
                modifier = Modifier.size(16.dp),
            )
            Text(
                shown.text,
                style = VoiidFont.rounded(13, FontWeight.SemiBold),
                color = Color.White,
            )
        }
    }
}
