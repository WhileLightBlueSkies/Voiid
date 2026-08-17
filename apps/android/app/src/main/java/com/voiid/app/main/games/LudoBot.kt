package com.voiid.app.main.games

import kotlin.math.abs
import kotlin.random.Random

/**
 * The practice opponent (docs/games/future/LUDO.md §11).
 *
 * DIFFICULTY NEVER TOUCHES THE DICE, AT ANY LEVEL, EVER. A bot that rolls better is not a harder
 * bot, it is a cheat — and in a game where players already suspect the dice it is the single most
 * damaging thing that could be built. Every band below varies MOVE SELECTION only; the die comes
 * from the same uniform draw the human gets.
 *
 * THE HONEST PART, which matters more here than for any other bot in this app: Ludo is roughly
 * 80% dice and 20% decisions. In a 4-player game the baseline win rate is 25% and a perfect
 * player against three random ones wins about 33-36%. That is the entire value of playing well —
 * eight to eleven percentage points.
 *
 *     The hardest Ludo bot will lose to a beginner about six times in ten. That is not a
 *     weakness in the bot. It is the game.
 *
 * So difficulty is presented as PLAYSTYLE, NOT STRENGTH (§11.2) — "Careless / Steady / Cautious /
 * Sharp" rather than Easy/Hard. Naming it by strength promises something the game cannot deliver,
 * and a player who loses to "Easy" will correctly conclude the labels are meaningless.
 *
 * Ported literally from iOS `LudoBot.swift`. Every weight below is a parity surface.
 */
class LudoBot(
    /** 0..1, matching the continuous-slider convention every other bot here uses. */
    val skill: Double,
) {

    /**
     * Pick one of the server-legal token indices to move.
     *
     * [legal] is authoritative and comes from the engine — the bot chooses AMONG it and never
     * re-derives it. That is the same rule the renderer follows, and it is what keeps one
     * definition of "what can this player do" (§4.2).
     */
    fun chooseMove(legal: List<Int>, tokens: List<List<Int>>, seat: Int, die: Int): Int {
        val first = legal.firstOrNull() ?: return 0
        if (legal.size == 1) return first

        // Between bands, the higher policy plays with probability `skill` and the lower
        // otherwise — RpsBot's construction, which makes the scale continuous rather than four
        // steps and makes a mid bot INCONSISTENT rather than uniformly mediocre.
        val roll = Random.nextDouble()

        return when {
            // Random legal move. No preference at all.
            skill < 0.25 -> legal.random()

            // Greedy priority: capture > enter home > leave the yard > advance the furthest.
            skill < 0.5 ->
                if (roll < skill) greedy(legal, tokens, seat, die) else legal.random()

            // Risk-aware: greedy, plus a threat model that penalises landing in front of an
            // opponent and rewards safe squares and blocks.
            //
            // The doc's top band is a depth-2 expectimax. It is deliberately not built: the
            // measured gap between risk-aware and perfect play in Ludo is a couple of percentage
            // points of win rate (§11.2), which is inside the noise of a single match, and a
            // search that cannot be felt is cost without a benefit.
            else ->
                if (roll < skill) riskAware(legal, tokens, seat, die)
                else greedy(legal, tokens, seat, die)
        }
    }

    // ---- policies ------------------------------------------------------------------------

    private fun greedy(legal: List<Int>, tokens: List<List<Int>>, seat: Int, die: Int): Int =
        best(legal, tokens, seat, die) { to, from, _ ->
            var score = 0.0
            if (to == Ludo.HOME) score += 100
            if (capturesAt(to, tokens, seat)) score += 80
            // Getting a token out is nearly always right.
            if (from == Ludo.YARD) score += 40
            if (Ludo.inColumn(to)) score += 10
            if (Ludo.onTrack(to)) score += relative(to, seat) * 0.1
            score
        }

    private fun riskAware(legal: List<Int>, tokens: List<List<Int>>, seat: Int, die: Int): Int =
        best(legal, tokens, seat, die) { to, from, token ->
            var score = 0.0
            if (to == Ludo.HOME) score += 100
            if (capturesAt(to, tokens, seat)) score += 80
            if (from == Ludo.YARD) score += 40
            // A column is permanently safe.
            if (Ludo.inColumn(to)) score += 25
            if (Ludo.isSafe(to)) score += 18
            if (Ludo.onTrack(to)) score += relative(to, seat) * 0.1

            // THE THREAT MODEL. For each opponent token 1-6 squares behind this destination,
            // there is a 1/6 chance per token of being captured before our next turn. Safe
            // squares and the home column are immune.
            if (Ludo.onTrack(to) && !Ludo.isSafe(to)) {
                var exposure = 0.0
                for ((other, row) in tokens.withIndex()) {
                    if (other == seat) continue
                    for (p in row) {
                        if (!Ludo.onTrack(p)) continue
                        val gap = (to - p + Ludo.TRACK) % Ludo.TRACK
                        if (gap in 1..6) exposure += 1.0 / 6.0
                    }
                }
                score -= exposure * 45
            }

            // Forming a block: two of ours on one square, which nobody can land on or pass. The
            // only defensive action in the game, so it is worth real weight.
            val ownThere = tokens[seat].withIndex().count { it.index != token && it.value == to }
            if (ownThere >= 1 && Ludo.onTrack(to) && !Ludo.isSafe(to)) score += 22

            // Leaving a block that is currently holding an opponent back has a cost — but a
            // blocking player must still move if it is their only legal move, which the engine
            // enforces, so this is a preference rather than a veto.
            val ownAtSource = tokens[seat].withIndex().count { it.index != token && it.value == from }
            if (ownAtSource >= 1 && Ludo.onTrack(from) && !Ludo.isSafe(from)) score -= 12

            score
        }

    /** Score every legal move and take the best, with a small deliberate wobble at high skill. */
    private fun best(
        legal: List<Int>,
        tokens: List<List<Int>>,
        seat: Int,
        die: Int,
        score: (to: Int, from: Int, token: Int) -> Double,
    ): Int {
        val ranked = ArrayList<Pair<Int, Double>>()
        for (token in legal) {
            val row = tokens.getOrNull(seat) ?: continue
            val from = row.getOrNull(token) ?: continue
            val to = destination(from, die, seat) ?: continue
            ranked.add(token to score(to, from, token))
        }
        if (ranked.isEmpty()) return legal.firstOrNull() ?: 0
        ranked.sortByDescending { it.second }

        // THE BOT OCCASIONALLY TAKES THE SECOND-BEST MOVE at high skill — 8% of the time, when
        // the gap is small (§11.3). Perfect consistency is the tell that you are playing a
        // machine, and Ludo's decisions are close enough that a small deviation costs nearly
        // nothing.
        if (skill >= 0.75 && ranked.size > 1 && Random.nextDouble() < 0.08 &&
            abs(ranked[0].second - ranked[1].second) < 20
        ) {
            return ranked[1].first
        }
        return ranked[0].first
    }

    // ---- board maths, mirroring the server -------------------------------------------------

    private fun capturesAt(to: Int, tokens: List<List<Int>>, seat: Int): Boolean {
        if (!Ludo.onTrack(to) || Ludo.isSafe(to)) return false
        for ((other, row) in tokens.withIndex()) {
            if (other == seat) continue
            // Exactly one opponent token is a capture; two or more is a block and is not legal
            // to land on, so it is not a capture either.
            if (row.count { it == to } == 1) return true
        }
        return false
    }

    private fun relative(absolute: Int, seat: Int): Int =
        (absolute - Ludo.entrySquare(seat) + Ludo.TRACK) % Ludo.TRACK

    /**
     * The same movement rule as `backend/games/src/engine/ludo/board.ts`.
     *
     * A MIRROR, NOT AN AUTHORITY: the bot only ever chooses among the server's own `legal` set,
     * so this is used to compare destinations, never to decide legality.
     */
    private fun destination(pos: Int, die: Int, seat: Int): Int? {
        if (Ludo.isHome(pos)) return null
        if (Ludo.inYard(pos)) return if (die == 6) Ludo.entrySquare(seat) else null
        if (Ludo.inColumn(pos)) {
            val step = pos - Ludo.COLUMN_BASE + die
            if (step == Ludo.COLUMN) return Ludo.HOME
            if (step > Ludo.COLUMN) return null
            return Ludo.COLUMN_BASE + step
        }
        val travelled = relative(pos, seat)
        val next = travelled + die
        if (next == Ludo.TRACK + Ludo.COLUMN) return Ludo.HOME
        if (next > Ludo.TRACK + Ludo.COLUMN) return null
        if (next >= Ludo.TRACK) return Ludo.COLUMN_BASE + (next - Ludo.TRACK)
        return (Ludo.entrySquare(seat) + next) % Ludo.TRACK
    }

    companion object {
        /**
         * Playstyle names for the four bands (§11.2).
         *
         * Deliberately NOT the shared [BotDifficulty] labels, which read Easy/Moderate/Hard.
         * Those are honest for Tic Tac Toe, where skill decides the game; they would be a
         * promise Ludo cannot keep.
         */
        fun styleLabel(skill: Double): String = when {
            skill < 0.25 -> "Careless"
            skill < 0.5 -> "Steady"
            skill < 0.75 -> "Cautious"
            else -> "Sharp"
        }

        /**
         * 700–1600 ms, randomised, plus the roll animation.
         *
         * PRESENTATION, NOT FAIRNESS. An instant move reads as a lookup table.
         */
        fun thinkingDelayMs(): Long = Random.nextLong(700, 1600)
    }
}
