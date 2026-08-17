package com.voiid.app.main.games

import kotlin.math.abs
import kotlin.random.Random

/**
 * The practice opponent (docs/games/future/SEA_BATTLE.md §11).
 *
 * SEA BATTLE IS THE HAPPY CASE FOR A DIFFICULTY SLIDER, and that is worth stating because the
 * other bots in this app are careful about the opposite. RpsBot refuses to fake a scale at all
 * ("against a truly random opponent, RPS has no skill... a difficulty slider over it would be a
 * lie"), and Snake's difficulty maps to BOT COUNT only, so "hard" means more opponents of
 * identical ability. Here there is a genuine, well-understood skill gradient, and EVERY LEVEL OF
 * IT IS A DIFFERENT ALGORITHM rather than the same algorithm with a knob.
 *
 * IT CANNOT SEE YOUR SHIPS. Every level computes from public information only — the same shots,
 * results and sunk lists a human player has. The fleet is never consulted. That is not a
 * courtesy, it is the one property that makes the board worth reasoning about: the belief that
 * the board is fixed and you are finding it.
 *
 * IT NEVER RE-ROLLS ITS FLEET. The temptation with a hidden-state bot is to leave the fleet
 * undetermined and materialise ships away from incoming fire. That is cheating, it is
 * undetectable, and it would poison the only thing this game has.
 *
 * Ported literally from iOS `SeaBattleBot.swift`. Every threshold and weight below is a parity
 * surface — a bot that hunts differently on two platforms is two different games.
 */
class SeaBattleBot(
    /** 0..1, matching the continuous-slider convention the other bots use. */
    val skill: Double,
) {

    // ---- targeting -----------------------------------------------------------------------

    /**
     * The next square to fire at, given only what a player could see.
     *
     * [shots]/[results] are the bot's own history against the human; [sunkCells] are outlines
     * the human's fleet has already revealed. Nothing here reads the human's ships.
     */
    fun chooseShot(
        shots: List<Int>,
        results: List<Int>,
        sunkCells: List<Int>,
        fleetSpec: List<Int>,
    ): Int {
        val fired = shots.toHashSet()
        val available = (0 until SeaBattle.CELLS).filter { it !in fired }
        if (available.isEmpty()) return 0

        // Between bands the higher algorithm plays with probability `skill` and the lower
        // otherwise — the same construction RpsBot.chooseThrow uses. It makes the scale
        // continuous instead of four steps, and makes a mid-skill bot feel INCONSISTENT rather
        // than uniformly mediocre, which is much closer to how a human plays.
        val roll = Random.nextDouble()

        // Live hits: hit cells that are not part of an already-sunk ship. These are the trail
        // that hunting follows, and excluding sunk outlines is what stops the bot re-probing
        // around a ship it has already finished.
        val sunk = sunkCells.toHashSet()
        val liveHits = ArrayList<Int>()
        for ((i, cell) in shots.withIndex()) {
            if (i >= results.size) break
            if (results[i] > 0 && cell !in sunk) liveHits.add(cell)
        }

        return when {
            skill < 0.25 ->
                // Uniform random over unfired cells. No hunt at all — a hit is not followed up.
                // ~95 shots to win, which is what random shooting costs.
                available.random()

            skill < 0.5 -> {
                // Random search, then HUNT: on a hit, queue the four orthogonal neighbours. ~65.
                if (roll < skill) hunt(liveHits, fired)?.let { return it }
                available.random()
            }

            skill < 0.75 -> {
                // PARITY search + hunt + LINE-LOCK. ~52.
                if (roll < skill) {
                    lineLock(liveHits, fired)?.let { return it }
                    hunt(liveHits, fired)?.let { return it }
                    parity(available)?.let { return it }
                }
                hunt(liveHits, fired) ?: available.random()
            }

            else -> {
                // PROBABILITY DENSITY. For every remaining ship, count every legal placement
                // consistent with all known hits, misses and sinks; fire at the cell appearing
                // in the most placements. ~42, close to the practical optimum for a solver that
                // sees only hits and misses.
                if (roll < skill) {
                    lineLock(liveHits, fired)?.let { return it }
                    density(fired, shots, results, sunk, fleetSpec, liveHits)?.let { return it }
                }
                hunt(liveHits, fired) ?: available.random()
            }
        }
    }

    /** The four orthogonal neighbours of any live hit. */
    private fun hunt(liveHits: List<Int>, fired: Set<Int>): Int? {
        val candidates = ArrayList<Int>()
        for (hit in liveHits) {
            for (n in neighbours(hit)) if (n !in fired) candidates.add(n)
        }
        return candidates.randomOrNull()
    }

    /**
     * After two collinear hits, extend along that line and stop probing perpendicular.
     *
     * This is the single biggest jump in a Battleship solver's efficiency: without it, a bot
     * that has found a 4-long ship still wastes shots checking above and below every hit.
     */
    private fun lineLock(liveHits: List<Int>, fired: Set<Int>): Int? {
        if (liveHits.size < 2) return null
        val hits = liveHits.toHashSet()

        for (hit in liveHits) {
            // Horizontal pair?
            if ((hit + 1) in hits && SeaBattle.cy(hit) == SeaBattle.cy(hit + 1)) {
                extend(hits, fired, hit, 1)?.let { return it }
            }
            // Vertical pair?
            if ((hit + SeaBattle.SIZE) in hits) {
                extend(hits, fired, hit, SeaBattle.SIZE)?.let { return it }
            }
        }
        return null
    }

    /** Walk both ends of a contiguous run of hits and return the first unfired cell. */
    private fun extend(hits: Set<Int>, fired: Set<Int>, from: Int, step: Int): Int? {
        val horizontal = step == 1

        var low = from
        while ((low - step) in hits && sameLine(low, low - step, horizontal)) low -= step
        var high = from
        while ((high + step) in hits && sameLine(high, high + step, horizontal)) high += step

        for (candidate in listOf(low - step, high + step)) {
            if (candidate < 0 || candidate >= SeaBattle.CELLS) continue
            val anchor = if (candidate == low - step) low else high
            if (!sameLine(anchor, candidate, horizontal)) continue
            if (candidate !in fired) return candidate
        }
        return null
    }

    /** Row wrap check: cells 9 and 10 are consecutive integers on DIFFERENT rows. */
    private fun sameLine(a: Int, b: Int, horizontal: Boolean): Boolean =
        if (horizontal) SeaBattle.cy(a) == SeaBattle.cy(b) else SeaBattle.cx(a) == SeaBattle.cx(b)

    /**
     * Only cells where `(x + y) % 2 == 0`.
     *
     * The smallest ship is 2 long, so it cannot hide entirely inside one parity class — which
     * means half the board can be skipped during the search phase for free.
     */
    private fun parity(available: List<Int>): Int? {
        val even = available.filter { (SeaBattle.cx(it) + SeaBattle.cy(it)) % 2 == 0 }
        return even.randomOrNull() ?: available.randomOrNull()
    }

    /** Count every legal placement of every remaining ship, consistent with what is known. */
    private fun density(
        fired: Set<Int>,
        shots: List<Int>,
        results: List<Int>,
        sunkCells: Set<Int>,
        fleetSpec: List<Int>,
        liveHits: List<Int>,
    ): Int? {
        // Which cells are known EMPTY: fired and missed.
        val misses = HashSet<Int>()
        for ((i, cell) in shots.withIndex()) {
            if (i >= results.size) break
            if (results[i] == 0) misses.add(cell)
        }

        // Which ships are still afloat. Derived from what has been sunk, which is public.
        // Each sunk ship accounts for `length` cells of sunkCells; approximate by removing the
        // longest ships that fit the revealed outlines. Exact bookkeeping is not needed here —
        // an over-estimate of remaining fleet only makes the heatmap slightly less sharp.
        var sunkBudget = sunkCells.size
        val afloat = ArrayList<Int>()
        for (length in fleetSpec.sortedDescending()) {
            if (sunkBudget >= length) sunkBudget -= length else afloat.add(length)
        }
        if (afloat.isEmpty()) afloat.add(2)

        val heat = IntArray(SeaBattle.CELLS)
        val hits = liveHits.toHashSet()

        for (length in afloat) {
            for (y in 0 until SeaBattle.SIZE) {
                for (x in 0 until SeaBattle.SIZE) {
                    for (horizontal in listOf(true, false)) {
                        if (horizontal && x + length > SeaBattle.SIZE) continue
                        if (!horizontal && y + length > SeaBattle.SIZE) continue
                        val cells = (0 until length).map {
                            if (horizontal) SeaBattle.packed(x + it, y)
                            else SeaBattle.packed(x, y + it)
                        }
                        // A placement is impossible if it covers a known miss or a sunk cell.
                        if (cells.any { it in misses || it in sunkCells }) continue
                        // A placement that covers a live hit is much more likely — weight it, so
                        // the solver finishes wounded ships rather than opening new fronts.
                        val weight = if (cells.any { it in hits }) 12 else 1
                        for (c in cells) if (c !in fired) heat[c] += weight
                    }
                }
            }
        }

        return heat.indices
            .filter { it !in fired && heat[it] > 0 }
            .maxByOrNull { heat[it] }
    }

    private fun neighbours(cell: Int): List<Int> {
        val x = SeaBattle.cx(cell)
        val y = SeaBattle.cy(cell)
        val out = ArrayList<Int>(4)
        if (x > 0) out.add(SeaBattle.packed(x - 1, y))
        if (x < SeaBattle.SIZE - 1) out.add(SeaBattle.packed(x + 1, y))
        if (y > 0) out.add(SeaBattle.packed(x, y - 1))
        if (y < SeaBattle.SIZE - 1) out.add(SeaBattle.packed(x, y + 1))
        return out
    }

    // ---- its own placement ---------------------------------------------------------------

    /**
     * AXIS 2 OF DIFFICULTY (§11.1), and it matters more than it sounds: half of losing to a good
     * Battleship player is that their fleet was hard to find.
     *
     * Weak bots place uniformly at random, which clusters and hugs edges. Strong bots reject
     * placements that are statistically easy to find — nothing wholly on an edge row, and a bias
     * away from the centre 4x4, which is where the density solver and most humans look first.
     */
    fun placeFleet(): List<SeaBattleShip> {
        if (skill < 0.5) return SeaBattleRules.randomFleet()

        // Sample several fleets and keep the one that looks hardest to find. Cheap — this runs
        // once per match, not per turn.
        var best = SeaBattleRules.randomFleet()
        var bestScore = -Double.MAX_VALUE
        repeat(24) {
            val candidate = SeaBattleRules.randomFleet()
            val score = awkwardness(candidate)
            if (score > bestScore) {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    /** Higher is harder to find. */
    private fun awkwardness(fleet: List<SeaBattleShip>): Double {
        var score = 0.0
        var edgeShips = 0
        for (ship in fleet) {
            val allEdge = ship.cells.all { c ->
                val x = SeaBattle.cx(c)
                val y = SeaBattle.cy(c)
                x == 0 || y == 0 || x == SeaBattle.SIZE - 1 || y == SeaBattle.SIZE - 1
            }
            if (allEdge) edgeShips++
            // Distance from the centre 4x4, where everyone looks first.
            for (c in ship.cells) {
                val dx = abs(SeaBattle.cx(c) - 4.5)
                val dy = abs(SeaBattle.cy(c) - 4.5)
                score += minOf(dx, dy) * 0.15
            }
        }
        // A ship entirely on an edge is the single most-guessed layout, so it is penalised
        // rather than rewarded despite being "away from centre".
        score -= edgeShips * 2.0
        return score
    }

    companion object {
        /**
         * 600–1400 ms, randomised.
         *
         * PRESENTATION, NOT FAIRNESS, and it is stated here so nobody later "optimises" it away:
         * an instant answer reads as a lookup table and destroys the fiction that someone is
         * thinking.
         */
        fun thinkingDelayMs(): Long = Random.nextLong(600, 1400)
    }
}
