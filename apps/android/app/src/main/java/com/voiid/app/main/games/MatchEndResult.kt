package com.voiid.app.main.games

import androidx.compose.ui.graphics.Color

/**
 * What a finished match says about itself (docs/games/VISUALS_AUDIO_AND_PARITY.md §9.3).
 *
 * ONE DESCRIPTOR, SIX GAMES. Every game builds one of these and hands it to [MatchEndOverlay];
 * no game writes its own end screen. Six separate end screens is how six games that share a tab
 * end up feeling like six apps — the same argument `CATCH` makes for sound.
 *
 * WHAT A GAME OWNS: the words and the numbers. WHAT THE OVERLAY OWNS: the scrim, the motion, the
 * particles, the sound, the haptics, the buttons and the share sheet. A game that starts reaching
 * into presentation is the beginning of the drift this file exists to prevent.
 *
 * Ported from iOS `MatchEndResult.swift`. Every string and every stat row must match.
 */
data class MatchEndResult(
    val outcome: Outcome,
    /** One short line, past tense. Null falls back to the outcome's own word. */
    val headline: String? = null,
    /** Why, when the why is not obvious: "They resigned", "You ran out of time". */
    val detail: String? = null,
    /** 2-4 rows. Everything here is already in the frame or already tracked locally. */
    val stats: List<Stat> = emptyList(),
    /**
     * The game's own colour, so the overlay belongs to the board behind it.
     *
     * NULLABLE, not defaulted to `VoiidColor.primary`: that is a `@Composable @ReadOnlyComposable`
     * getter (it picks light/dark at call time) and cannot be evaluated in a plain data-class
     * default. [MatchEndOverlay] resolves null to the primary inside a composable scope, which
     * is the only place the theme can legally be read.
     */
    val accent: Color? = null,
    /**
     * Text to drop into a chat. Null hides the share button.
     *
     * ON A LOSS THE BUTTON BECOMES REMATCH, never Share — nobody shares a loss, and offering it
     * reads as a joke at the player's expense. The overlay enforces that; a game may set this
     * unconditionally.
     */
    val shareText: String? = null,
    /**
     * WINNING BECAUSE SOMEONE LEFT IS NOT A VICTORY (§9.7).
     *
     * Set for a win by resignation or timeout: verdict and reason, no confetti, no fanfare,
     * half-gain stinger, buttons immediately. The existing sound code already refuses to play a
     * stinger for an abandoned match — `winnerUserId ?: return` in LudoSound and SeaBattleSound —
     * and this is the same principle applied to the visuals.
     */
    val hollow: Boolean = false,
) {
    val title: String get() = headline ?: outcome.verdict

    /**
     * The three outcomes differ in DIRECTION, not merely in colour (§9.5) — a win rises, a
     * defeat settles, a tie converges. That is what makes the result readable across a room.
     */
    enum class Outcome(
        /** The word. Carries the outcome on its own, so the screen survives greyscale. */
        val verdict: String,
        val sound: String,
        /**
         * A DEFEAT IS SHORTER THAN A WIN, deliberately. A defeat screen as loud as a win screen
         * makes winning feel like nothing; the shortest honest path back into a game is the
         * respect. This scales the whole sequence in [MatchEndOverlay].
         */
        val sequenceScale: Float,
    ) {
        WIN("You win", GameAudio.RESULT_WIN, 1.0f),
        LOSE("You lose", GameAudio.RESULT_LOSE, 0.75f),
        TIE("Draw", GameAudio.RESULT_TIE, 0.82f),
    }

    data class Stat(
        val label: String,
        val value: String,
        /**
         * At most ONE row is highlighted — a personal best, the winning margin. Two highlights
         * is no highlight.
         */
        val highlight: Boolean = false,
    )

    companion object {
        // ---- per-game builders ------------------------------------------------------------
        //
        // Kept together rather than each living in its own screen: six builders side by side is
        // how "Sea Battle says shots, Ludo says nothing" gets noticed.

        /** Rock Paper Scissors. [mine]/[theirs] are round wins. */
        fun rps(mine: Int, theirs: Int, mostThrown: String?, record: String?): MatchEndResult {
            val stats = buildList {
                add(Stat("Rounds", "$mine – $theirs", mine > theirs))
                mostThrown?.let { add(Stat("You threw most", it)) }
                record?.let { add(Stat("Record", it)) }
            }
            return MatchEndResult(
                outcome = if (mine == theirs) Outcome.TIE
                          else if (mine > theirs) Outcome.WIN else Outcome.LOSE,
                stats = stats,
                shareText = "Beat me at Rock Paper Scissors $theirs–$mine. Rematch?",
            )
        }

        fun ticTacToe(won: Boolean?, moves: Int, record: String?): MatchEndResult {
            val stats = buildList {
                add(Stat("Moves played", "$moves"))
                record?.let { add(Stat("Record", it)) }
            }
            return MatchEndResult(
                outcome = when (won) {
                    null -> Outcome.TIE
                    true -> Outcome.WIN
                    false -> Outcome.LOSE
                },
                headline = if (won == null) "Dead heat" else null,
                detail = if (won == null) "Nobody could force it" else null,
                stats = stats,
                shareText = if (won == null) "Forced a draw again. Nobody wins this one."
                            else "Tic Tac Toe, settled. Rematch?",
            )
        }

        /** Hand Cricket. [margin] is already phrased — "by 12 runs", "by 4 wickets". */
        fun cricket(myScore: Int, theirScore: Int, margin: String?, wickets: Int): MatchEndResult {
            val stats = buildList {
                add(Stat("You", "$myScore", myScore > theirScore))
                add(Stat("Them", "$theirScore"))
                margin?.let { add(Stat("Won", it)) }
                add(Stat("Wickets taken", "$wickets"))
            }
            return MatchEndResult(
                outcome = if (myScore == theirScore) Outcome.TIE
                          else if (myScore > theirScore) Outcome.WIN else Outcome.LOSE,
                detail = margin,
                stats = stats,
                shareText = if (myScore > theirScore)
                    "Chased $theirScore in Hand Cricket. Your turn."
                else "Hand Cricket, $myScore plays $theirScore. Rematch?",
            )
        }

        fun ludo(
            placement: Int,
            seats: Int,
            home: Int,
            tokens: Int,
            captures: Int,
            lost: Int,
            won: Boolean,
        ): MatchEndResult = MatchEndResult(
            outcome = if (won) Outcome.WIN else Outcome.LOSE,
            headline = if (won) "You win" else "${ordinal(placement)} of $seats",
            stats = listOf(
                Stat("Tokens home", "$home/$tokens", home == tokens),
                Stat("Captures made", "$captures"),
                Stat("Tokens lost", "$lost"),
            ),
            accent = Ludo.SEAT_COLORS[0],
            shareText = if (won) "Won Ludo from last place. Ask me how." else null,
        )

        /**
         * Sea Battle. [hiddenShips] is how many of the winner's ships were never found — the
         * line that turns a number into a story.
         */
        fun seaBattle(
            won: Boolean,
            shots: Int,
            hits: Int,
            sunk: Int,
            hiddenShips: Int,
            endedBy: String?,
        ): MatchEndResult {
            val accuracy = if (shots > 0) (hits.toFloat() / shots * 100).toInt() else 0
            val hollow = won && (endedBy == "resign" || endedBy == "timeout")
            val stats = buildList {
                add(Stat("Shots fired", "$shots"))
                add(Stat("Accuracy", "$accuracy%", accuracy >= 40))
                add(Stat("Ships sunk", "$sunk/5"))
                if (won && hiddenShips > 0) add(Stat("Still hidden", "$hiddenShips of yours"))
            }
            return MatchEndResult(
                outcome = if (won) Outcome.WIN else Outcome.LOSE,
                detail = when (endedBy) {
                    "resign" -> if (won) "They resigned" else "You resigned"
                    "timeout" -> if (won) "They ran out of time" else "You ran out of time"
                    else -> null
                },
                stats = stats,
                shareText = when {
                    won && hiddenShips > 0 ->
                        "Sank your fleet with $hiddenShips ships still hidden."
                    won -> "Sank your whole fleet. Rematch?"
                    else -> null
                },
                hollow = hollow,
            )
        }

        fun snake(
            length: Int,
            kills: Int,
            rank: Int,
            players: Int,
            best: Int,
            isBest: Boolean,
        ): MatchEndResult {
            val stats = buildList {
                add(Stat("Length", "$length", isBest))
                add(Stat("Kills", "$kills"))
                if (players > 1) add(Stat("Rank", "${ordinal(rank)} of $players"))
                if (!isBest && best > length) add(Stat("Your best", "$best"))
            }
            return MatchEndResult(
                // Snake is a free-for-all, so "win" means finishing first and everything else is
                // a loss — there is no tie to draw.
                outcome = if (rank == 1) Outcome.WIN else Outcome.LOSE,
                headline = if (rank == 1) "You win" else null,
                detail = if (isBest) "New personal best" else null,
                stats = stats,
                shareText = if (isBest) "New best in Snake: $length. Beat that."
                            else "I got $length in Snake. Beat that.",
            )
        }

        /** A match nobody finished. NOT an outcome — see §9.7 and the overlay's hollow path. */
        fun abandoned(): MatchEndResult = MatchEndResult(
            outcome = Outcome.TIE,
            headline = "Match abandoned",
            detail = "Nobody finished this one",
            hollow = true,
        )

        private fun ordinal(n: Int): String = when (n) {
            1 -> "1st"
            2 -> "2nd"
            3 -> "3rd"
            else -> "${n}th"
        }
    }
}

// ---- frame -> result, per game ------------------------------------------------------------
//
// These live next to the descriptor rather than in each screen, so the six sit side by side and
// a game that stops reporting something is visible. Everything below is already in the frame —
// no new wire field, no new endpoint (§9.8). iOS keeps the equivalents as private methods on
// each view; Kotlin has no partial-class equivalent, so they are top-level here.

/** Sea Battle. */
fun seaBattleResult(
    s: com.voiid.app.net.GamesEngine.SeaBattleState,
    mySeat: Int?,
    me: String?,
): MatchEndResult {
    // An abandoned match has no winner, and nothing should be celebrated (§9.7).
    val winner = s.winnerUserId ?: return MatchEndResult.abandoned()
    val seat = mySeat ?: 0
    val enemy = 1 - seat
    val shots = s.shots.getOrElse(seat) { emptyList() }
    val hits = s.results.getOrElse(seat) { emptyList() }.count { it > 0 }
    val sunk = s.sunk.getOrElse(enemy) { emptyList() }.size

    // How many of MY ships were never found. The line that turns a number into a story.
    val hitCells = s.shots.getOrElse(enemy) { emptyList() }
        .filterIndexed { i, _ ->
            (s.results.getOrElse(enemy) { emptyList() }.getOrElse(i) { 0 }) > 0
        }
        .toHashSet()
    val untouched = s.myFleet.count { ship -> ship.cells.none { it in hitCells } }

    return MatchEndResult.seaBattle(
        won = winner == me,
        shots = shots.size,
        hits = hits,
        sunk = sunk,
        hiddenShips = untouched,
        endedBy = s.endedBy,
    )
}

/** Ludo. Placement matters more than a win flag: "2nd of 4" is the honest result. */
fun ludoResult(
    s: com.voiid.app.net.GamesEngine.LudoState,
    mySeat: Int?,
    me: String?,
): MatchEndResult {
    val winner = s.winnerUserId ?: return MatchEndResult.abandoned()
    val seat = mySeat ?: 0
    val home = s.tokens.getOrElse(seat) { emptyList() }.count { it == Ludo.HOME }
    val placement = s.finishedOrder.indexOf(seat).takeIf { it >= 0 }?.plus(1)
        ?: (s.finishedOrder.size + 1)
    // Captures are only ever reported one move at a time, so a running tally would need history
    // the client does not keep. `lastMove` is the honest answer.
    val cap = s.lastMove?.captured
    return MatchEndResult.ludo(
        placement = placement,
        seats = s.players.size,
        home = home,
        tokens = s.tokensPerPlayer,
        captures = if (cap?.size == 2 && s.lastMove?.seat == seat) 1 else 0,
        lost = if (cap?.size == 2 && cap[0] == seat) 1 else 0,
        won = winner == me,
    )
}

/**
 * Hand Cricket.
 *
 * A CRICKET MATCH CAN GENUINELY TIE, unlike Sea Battle or Ludo, and the engine reports that as
 * `finished` with no winner. That is a real result and gets the tie treatment — it is NOT the
 * abandoned path, which is for a match nobody finished.
 */
fun cricketResult(
    s: com.voiid.app.net.GamesEngine.CricketState,
    mySeat: Int,
): MatchEndResult {
    val their = if (mySeat == 0) 1 else 0
    val mine = s.scores.getOrElse(mySeat) { 0 }
    val theirs = s.scores.getOrElse(their) { 0 }
    // Wickets I took are the ones the OTHER side lost.
    val taken = s.wickets.getOrElse(their) { 0 }

    val margin: String? = if (mine > theirs) {
        val left = s.wicketsPerInnings - s.wickets.getOrElse(mySeat) { 0 }
        if (s.battingSeat == mySeat && s.innings == 2) {
            "by ${maxOf(left, 1)} wicket${if (left == 1) "" else "s"}"
        } else {
            "by ${mine - theirs} run${if (mine - theirs == 1) "" else "s"}"
        }
    } else null

    return MatchEndResult.cricket(mine, theirs, margin, taken)
}

/**
 * Rock Paper Scissors.
 *
 * RPS PLAYS TO A TARGET, so a finished match with equal scores is a genuine tie rather than an
 * abandonment: `winnerUserId` is null in both cases, so the score decides which.
 */
fun rpsResult(
    s: com.voiid.app.net.GamesEngine.RpsState,
    me: String?,
): MatchEndResult {
    val mySeat = s.players.indexOf(me).coerceAtLeast(0)
    val theirSeat = if (mySeat == 0) 1 else 0
    val mine = s.wins.getOrElse(mySeat) { 0 }
    val theirs = s.wins.getOrElse(theirSeat) { 0 }

    // What I threw most across the match — the one read-your-opponent stat the frame already
    // carries, since resolved rounds hold both throws.
    val counts = HashMap<String, Int>()
    for (round in s.history) {
        val name = round.throws.getOrNull(mySeat) ?: continue
        counts[name] = (counts[name] ?: 0) + 1
    }
    val mostThrown = counts.maxByOrNull { it.value }
        ?.let { "${it.key.replaceFirstChar { c -> c.uppercase() }} (${it.value})" }

    return MatchEndResult.rps(mine, theirs, mostThrown, null)
}

/** Tic Tac Toe. */
fun ticTacToeResult(
    s: com.voiid.app.net.GamesEngine.TicTacToeState,
    me: String?,
): MatchEndResult {
    val moves = s.board.count { it != null }
    // A draw is `finished` with no winner and a FULL board; an abandoned match is `finished`
    // with no winner and an unfinished one. Only the first is a real result.
    if (s.winnerUserId == null && moves < s.board.size) return MatchEndResult.abandoned()
    return MatchEndResult.ticTacToe(
        won = s.winnerUserId?.let { it == me },
        moves = moves,
        record = null,
    )
}
