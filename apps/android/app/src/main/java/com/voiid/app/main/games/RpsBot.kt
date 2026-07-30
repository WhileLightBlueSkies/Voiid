package com.voiid.app.main.games

import kotlin.random.Random

/**
 * Local bot for Rock Paper Scissors.
 *
 * THE HONEST PROBLEM: against a truly random opponent, RPS has no skill — every strategy
 * wins exactly a third of the time. A "hard" bot that just plays randomly would be
 * indistinguishable from an easy one, and a difficulty slider over it would be a lie.
 *
 * So difficulty here is EXPLOITATION OF HUMAN NON-RANDOMNESS, which is how the game is
 * actually played well. People repeat throws, avoid repeating three times, and switch
 * after losses. This bot tracks the player's throw frequencies and, at [skill] probability,
 * plays the counter to their MOST LIKELY next throw; otherwise it throws at random.
 *
 * That makes the scale meaningful and honest:
 *   skill 0.0 → pure random, genuinely a coin flip
 *   skill 1.0 → punishes any pattern in your play, but still cannot beat a truly random
 *               human — which is correct, because nothing can. It is not "unbeatable" the
 *               way the Tic Tac Toe bot is, and it would be dishonest to pretend otherwise.
 *
 * Mirrors iOS `RpsBot.swift`.
 */
object RpsBot {

    /** Index convention shared with the server: 0 rock, 1 paper, 2 scissors. */
    const val ROCK = 0
    const val PAPER = 1
    const val SCISSORS = 2

    val names = listOf("rock", "paper", "scissors")

    /** What beats [throwIdx]. Rock<Paper<Scissors<Rock. */
    fun counter(throwIdx: Int): Int = (throwIdx + 1) % 3

    /**
     * 1 if [a] beats [b], -1 if it loses, 0 for a tie. The single place the rules live, so
     * the screen never re-derives them.
     */
    fun compare(a: Int, b: Int): Int = when {
        a == b -> 0
        counter(b) == a -> 1
        else -> -1
    }

    /**
     * Choose a throw. [history] is the HUMAN's past throws, most recent last.
     *
     * With no history there is nothing to exploit, so it falls through to random — a bot
     * that "reads" you on move one would be fabricating a pattern that cannot exist yet.
     */
    fun chooseThrow(history: List<Int>, skill: Float): Int {
        if (history.isEmpty() || Random.nextFloat() > skill) return Random.nextInt(3)

        // Frequency model, weighted toward recent throws: the last 5 count double, because
        // people drift and a throw from twenty rounds ago says little about the next one.
        val weights = IntArray(3)
        history.forEachIndexed { i, t ->
            weights[t] += if (i >= history.size - 5) 2 else 1
        }
        val predicted = weights.indices.maxByOrNull { weights[it] } ?: Random.nextInt(3)
        return counter(predicted)
    }
}
