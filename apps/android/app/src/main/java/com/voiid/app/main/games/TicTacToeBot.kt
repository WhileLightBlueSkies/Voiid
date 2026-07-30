package com.voiid.app.main.games

import kotlin.random.Random

/**
 * Local, offline bot for Tic Tac Toe (docs/GAMES.md §1 calls this out as a deliberate,
 * separate addition to the online-only design).
 *
 * WHY THIS IS ENTIRELY CLIENT-SIDE. The online game is server-authoritative because two
 * humans can cheat each other. A bot match has one human and no opponent to protect —
 * cheating yourself is not a threat model. So a bot game creates no match row, no Redis
 * state, no WS traffic and no server load, and works with no connection at all.
 *
 * DIFFICULTY IS ONE NUMBER, NOT FOUR MODES. [skill] (0..1) is the single source of truth:
 * the probability the bot plays the BEST move rather than a random legal one. The named
 * presets are positions on that scale, so the slider and the chips can never disagree.
 *
 * At skill = 1 the bot is a full minimax player and is UNBEATABLE — perfect Tic Tac Toe
 * draws at best. That is deliberate for the top of the slider, and why "Hard" sits below
 * 1.0: a game you can never win stops being fun.
 *
 * Mirrors iOS `TicTacToeBot.swift`.
 */
enum class BotDifficulty(val label: String, val skill: Float) {
    // Easy is 0.15 rather than 0: a fully random bot misses wins already on the board and
    // reads as broken rather than easy.
    EASY("Easy", 0.15f),
    MODERATE("Moderate", 0.55f),
    HARD("Hard", 0.92f);

    companion object {
        /** The preset a raw skill value matches, or null if the slider sits between them. */
        fun matching(skill: Float): BotDifficulty? =
            entries.firstOrNull { kotlin.math.abs(it.skill - skill) < 0.001f }
    }
}

object TicTacToeBot {

    val lines = listOf(
        listOf(0, 1, 2), listOf(3, 4, 5), listOf(6, 7, 8),
        listOf(0, 3, 6), listOf(1, 4, 7), listOf(2, 5, 8),
        listOf(0, 4, 8), listOf(2, 4, 6),
    )

    /**
     * Choose a cell for [botSeat]. [skill] is the probability of playing optimally;
     * otherwise a random legal move. That mix is what makes difficulty feel continuous —
     * a "70% good" bot blunders roughly three moves in ten, a far more natural opponent
     * than a fixed shallower search (which is either perfect or obviously stupid).
     */
    fun chooseMove(board: List<Int?>, botSeat: Int, skill: Float): Int? {
        val empty = board.indices.filter { board[it] == null }
        if (empty.isEmpty()) return null
        if (Random.nextFloat() > skill) return empty.random()
        return bestMove(board, botSeat) ?: empty.random()
    }

    /**
     * Full minimax. The search space is tiny (at most 9! leaf orderings, far fewer in
     * practice), so no alpha-beta or depth cap is needed.
     *
     * Depth is folded into the score so the bot prefers a FASTER win and a SLOWER loss.
     * Without it all wins look equal and the bot idly postpones a mate it could take now,
     * which looks like it isn't trying.
     */
    private fun bestMove(board: List<Int?>, seat: Int): Int? {
        var bestScore = Int.MIN_VALUE
        var bestCell: Int? = null
        for (cell in board.indices) {
            if (board[cell] != null) continue
            val next = board.toMutableList().also { it[cell] = seat }
            val score = minimax(next, seat, 1 - seat, 1)
            if (bestCell == null || score > bestScore) {
                bestScore = score
                bestCell = cell
            }
        }
        return bestCell
    }

    private fun minimax(board: List<Int?>, seat: Int, turn: Int, depth: Int): Int {
        winner(board)?.let { return if (it == seat) 10 - depth else depth - 10 }
        if (board.none { it == null }) return 0   // draw

        var best = if (turn == seat) Int.MIN_VALUE else Int.MAX_VALUE
        for (cell in board.indices) {
            if (board[cell] != null) continue
            val next = board.toMutableList().also { it[cell] = turn }
            val score = minimax(next, seat, 1 - turn, depth + 1)
            best = if (turn == seat) maxOf(best, score) else minOf(best, score)
        }
        return best
    }

    /**
     * The seat owning a completed line, or null. Duplicates the server's line table by
     * necessity — a bot match never reaches the server. The ONLINE game still asks the
     * server for everything; this is not a second referee for real matches.
     */
    fun winner(board: List<Int?>): Int? {
        for (l in lines) {
            val a = board[l[0]]
            if (a != null && a == board[l[1]] && a == board[l[2]]) return a
        }
        return null
    }
}
