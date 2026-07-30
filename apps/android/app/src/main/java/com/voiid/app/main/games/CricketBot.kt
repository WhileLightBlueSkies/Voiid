package com.voiid.app.main.games

import kotlin.random.Random

/**
 * Local bot for Hand Cricket (docs/GAMES_HAND_CRICKET.md).
 *
 * THE STRATEGIC PROBLEM IS ASYMMETRIC, unlike RPS, and that is what makes this bot
 * interesting. The two roles want different things from the same pick:
 *
 *   * BOWLING, the bot wants to MATCH the batter's number (a match is a wicket).
 *   * BATTING, the bot wants to AVOID the bowler's number, and among the safe numbers prefer
 *     the big ones (6 scores six; a match on 6 costs the same wicket as a match on 1).
 *
 * So difficulty is again exploitation of human non-randomness, but applied to opposite goals
 * depending on who is batting. People are predictable in specific ways here: they favour 6
 * when batting (it scores most), they under-use 0, and they repeat recent numbers more than
 * chance would.
 *
 * The scale is honest about its ceiling:
 *   skill 0.0 → uniform random over 0..6. A wicket is then a 1-in-7 coincidence.
 *   skill 1.0 → bowls at your most likely number and bats away from it. Still cannot beat a
 *               truly random human, because nothing can — with both sides uniform, every
 *               ball is a 1/7 wicket chance regardless of strategy. Claiming otherwise would
 *               be the same lie the RPS bot's doc warns about.
 *
 * WHY IT BATS FOR BIG RUNS RATHER THAN PURE SAFETY: a bot that always picked the single safest
 * number would score 1s and lose every chase, which reads as broken rather than easy. Weighting
 * safe-and-large is what makes an innings feel like an innings.
 *
 * Mirrors iOS `CricketBot.swift`.
 */
object CricketBot {

    /** Legal picks, inclusive. 0 is a closed fist — a dot ball, and out if matched. */
    const val MIN_PICK = 0
    const val MAX_PICK = 6
    private val ALL = (MIN_PICK..MAX_PICK).toList()

    /**
     * Choose a pick.
     *
     * [humanHistory] is the HUMAN's past picks in this role, most recent last. Kept per role
     * by the caller: how someone bats says little about how they bowl, so mixing the two
     * would blur the model into noise.
     *
     * [botIsBatting] flips the objective — match to take a wicket, or dodge to score.
     */
    fun choosePick(humanHistory: List<Int>, skill: Float, botIsBatting: Boolean): Int {
        // Nothing to exploit yet, or the dice said play it straight. A bot that "reads" you
        // on ball one would be inventing a pattern that cannot exist.
        if (humanHistory.isEmpty() || Random.nextFloat() > skill) {
            return if (botIsBatting) randomBattingPick() else ALL.random()
        }

        val predicted = predict(humanHistory)
        return if (botIsBatting) {
            // Avoid the predicted bowl; among what's left, favour the big scores.
            val safe = ALL.filter { it != predicted }
            weightedByRuns(safe)
        } else {
            // Bowl AT the predicted bat. This is the only pick that can take a wicket.
            predicted
        }
    }

    /**
     * The human's most likely next pick, by frequency weighted toward recent balls: the last
     * 5 count double, because people drift within an innings and a pick from twenty balls ago
     * says little about the next one. (Same model as [RpsBot], same reason.)
     */
    private fun predict(history: List<Int>): Int {
        val weights = IntArray(MAX_PICK + 1)
        history.forEachIndexed { i, p ->
            if (p in MIN_PICK..MAX_PICK) {
                weights[p] += if (i >= history.size - 5) 2 else 1
            }
        }
        return weights.indices.maxByOrNull { weights[it] } ?: ALL.random()
    }

    /**
     * A batting pick with no read on the bowler: skewed toward big runs, but never ONLY 6 —
     * a bot that always picks 6 is trivially bowled out by a human who always bowls 6.
     */
    private fun randomBattingPick(): Int = weightedByRuns(ALL)

    /**
     * Pick from [candidates] with weight proportional to run value, so 6 is likeliest and 0
     * is a rare defensive choice. `+1` keeps 0 reachable rather than impossible.
     */
    private fun weightedByRuns(candidates: List<Int>): Int {
        if (candidates.isEmpty()) return ALL.random()
        val total = candidates.sumOf { it + 1 }
        var roll = Random.nextInt(total)
        for (c in candidates) {
            roll -= (c + 1)
            if (roll < 0) return c
        }
        return candidates.last()
    }

    /** True if these two picks are a wicket. The one place the rule lives. */
    fun isWicket(batterPick: Int, bowlerPick: Int): Boolean = batterPick == bowlerPick

    /**
     * Which wicket animation this ball earns (docs/GAMES_HAND_CRICKET.md §5). Chosen by the
     * MATCHED NUMBER, so it is deterministic from the ball itself and needs no extra state.
     */
    fun wicketIsCatch(matchedPick: Int): Boolean = matchedPick <= 2
}
