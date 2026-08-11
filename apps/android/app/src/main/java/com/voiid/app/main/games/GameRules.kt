package com.voiid.app.main.games

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.TrendingUp
import androidx.compose.material.icons.outlined.AutoAwesomeMotion
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.OpenInFull
import androidx.compose.material.icons.outlined.EmojiEvents
import androidx.compose.material.icons.outlined.Grid3x3
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.RemoveRedEye
import androidx.compose.material.icons.outlined.SportsCricket
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material.icons.outlined.Timeline
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * How each game is played, in the one place a player is guaranteed to look: the sheet that opens
 * when they tap a game and before they have committed to a match.
 *
 * NOTHING EXPLAINED ITSELF (docs/games/CROSS_CUTTING.md §11). Hand Cricket in particular is
 * unplayable without being told — "matching numbers is out" is a house rule nobody guesses, and a
 * player who does not know it spends their first match wondering why picking the same number as
 * the bot keeps ending their innings. Tic Tac Toe needs no explanation and gets a short one
 * anyway, because a game that says nothing while its neighbours do reads as unfinished.
 *
 * WRITTEN AS RULES, NOT MARKETING. "Both players pick a number from 0 to 6" is useful; "Test your
 * reflexes in this thrilling arcade challenge" is not, and it costs the reader the two seconds
 * they were willing to give. Every line answers one of: what do I do, what wins, what ends it.
 *
 * KEYED BY SLUG, the same key the server's rules modules and the renderers use — so a game whose
 * rules have not been written falls back to nothing rather than to another game's.
 *
 * Mirrors iOS `GameRules.swift`. Keep the copy identical.
 */
object GameRules {
    /**
     * One rule line: an icon and the rule itself.
     *
     * Split rather than one paragraph because a player scanning for "how do I win" should find it
     * without reading the rest — a wall of prose in a sheet is a wall nobody reads.
     */
    data class Line(val icon: ImageVector, val text: String)

    /** The rules for a game, or empty if it has none written. */
    fun lines(slug: String): List<Line> = when (slug) {
        "cricket" -> cricket
        "tictactoe" -> tictactoe
        "rps" -> rps
        "snake" -> snake
        else -> emptyList()
    }

    /** A one-line hook shown under the game's name. Sets expectations before the rules do. */
    fun tagline(slug: String): String? = when (slug) {
        "cricket" -> "Two innings. Guess your opponent, and don't get matched."
        "tictactoe" -> "Three in a row. Simple, solved, and still worth a rematch."
        "rps" -> "First to 3. The trick is reading them, not the throw."
        "snake" -> "Eat, grow, survive. Six snakes, one arena, no brakes."
        else -> null
    }

    // THE HOUSE RULES ARE THE POINT. Hand Cricket's scoring is obvious; what is not obvious is
    // that a matched number is a wicket, that this INCLUDES 0 vs 0, and that two wickets ends
    // your innings. All three are stated before anyone plays a ball.
    private val cricket = listOf(
        Line(Icons.Outlined.PanTool,
            "Both players secretly pick a number from 0 to 6, then reveal together."),
        Line(Icons.Outlined.SportsCricket,
            "Batting: your number is added to your score."),
        Line(Icons.Outlined.Cancel,
            "Match your opponent's number and you're OUT — including 0 against 0."),
        Line(Icons.Outlined.SwapHoriz,
            "Two wickets or all your overs ends the innings, then you swap."),
        Line(Icons.Outlined.EmojiEvents,
            "Batting second, you win by passing their score. Level totals are a tie."),
    )

    private val tictactoe = listOf(
        Line(Icons.Outlined.Grid3x3, "Take turns claiming a square on the 3×3 board."),
        Line(Icons.Outlined.Timeline,
            "Three of yours in a row — across, down or diagonally — wins."),
        Line(Icons.Outlined.SwapHoriz,
            "Fill the board with no line and it's a draw, which is the usual result between " +
                "two people paying attention."),
    )

    private val rps = listOf(
        Line(Icons.Outlined.PanTool,
            "Rock beats scissors, scissors beats paper, paper beats rock."),
        Line(Icons.Outlined.RemoveRedEye,
            "Both throws are locked in before either is shown, so there is nothing to react to."),
        Line(Icons.Outlined.EmojiEvents, "First to 3 rounds takes the match. Ties replay the round."),
    )

    // CHECKED LINE BY LINE AGAINST backend/games/src/engine/snake. Two of these were wrong on
    // the first pass — boost's cost and what happens when you hit a body — which is exactly the
    // kind of error that teaches a player the opposite of the game they are playing.
    private val snake = listOf(
        Line(Icons.AutoMirrored.Outlined.TrendingUp,
            "Steer with the stick and eat pellets to grow."),
        Line(Icons.Outlined.Bolt,
            "Hold BOOST to sprint. It burns your own mass and drops it behind you as food, " +
                "and it cuts out if you get too small to afford it."),
        Line(Icons.Outlined.Warning,
            "Run into another snake's body and YOU die — the one you hit is unharmed. So " +
                "cutting in front of a big snake beats trying to outgrow it."),
        Line(Icons.Outlined.OpenInFull,
            "Head to head, the longer snake survives. If you are near enough the same size, " +
                "you both go. The arena wall kills outright."),
        Line(Icons.Outlined.AutoAwesomeMotion,
            "Anything that dies bursts into food worth taking. Longest snake when the clock " +
                "runs out wins."),
    )
}
