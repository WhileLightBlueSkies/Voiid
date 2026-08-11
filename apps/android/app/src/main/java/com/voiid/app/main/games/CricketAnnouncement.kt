package com.voiid.app.main.games

/**
 * The moments in a match that deserve to be SAID, not just reflected in a label.
 *
 * Hand Cricket's big transitions were all silent state flips: the innings changed and the
 * scoreboard simply started counting a different number, the roles swapped and a small caption
 * quietly went from "You're batting" to "You're bowling". If you were looking at the pick pad —
 * which is where your eyes are — you missed all of it, and then wondered why your taps were
 * scoring nothing.
 *
 * DELIVERED ON THE PITCH, not over the screen. These first shipped on iOS as a card on a dimmed
 * scrim and looked exactly like what they were: a system alert dropped on a game. The pitch is
 * already the window the player watches for "what just happened", so the message belongs in that
 * same space — the players fade, the grass stays, the message is delivered where the ball would
 * be, and play resumes. See CricketPitch's `announcement` parameter.
 *
 * Mirrors iOS `CricketAnnouncement.swift`. Keep the copy and the durations identical.
 */
data class CricketAnnouncement(
    /** Changes whenever a NEW announcement should play, so the same text can repeat in a match. */
    val id: Int,
    val kind: Kind,
    /** The headline. Short, past tense, specific — "You won the toss" beats "Toss result". */
    val title: String,
    /** One line of consequence: what it MEANS for the player, not a restatement of the title. */
    val detail: String,
) {
    enum class Kind { TOSS, INNINGS_BREAK, ROLE_CHANGE, TARGET }

    /**
     * Milliseconds the message stays on the pitch.
     *
     * These are timed against how long the text takes to be NOTICED, PARSED and turned into a
     * decision — not merely read. "You need 14 to win" is four words and several seconds of
     * thought, and the innings break is the one moment in the match where the player is
     * re-planning rather than reacting.
     *
     * A message that outstays its welcome costs a beat; one that leaves early costs the
     * information entirely, and there is no way to ask for it back.
     */
    val durationMs: Long
        get() = when (kind) {
            Kind.TOSS -> 5200
            Kind.INNINGS_BREAK -> 5600      // carries the target — the most thinking per word
            Kind.ROLE_CHANGE -> 4000
            Kind.TARGET -> 5200
        }
}

/**
 * Builds the announcement copy, so the online and bot screens cannot word the same event two
 * different ways. Pure functions of the facts — nothing here reads state.
 */
object CricketAnnouncements {
    /**
     * [choice] is what the TOSS WINNER elected — "bat" or "bowl" — whoever that was.
     *
     * The winner's election is about THEMSELVES, so turning it into "am I batting" depends on who
     * won: if I won and chose to bat, I bat; if THEY won and chose to bat, I bowl. Getting that
     * backwards is silent and produces an announcement that contradicts the scoreboard two
     * seconds later, which is worse than no announcement at all.
     */
    fun toss(id: Int, iWon: Boolean, choice: String, opponent: String): CricketAnnouncement {
        val winnerBats = choice == "bat"
        val iBat = if (iWon) winnerBats else !winnerBats
        val who = if (iBat) "you're batting first" else "$opponent bats first"
        return CricketAnnouncement(
            id = id,
            kind = CricketAnnouncement.Kind.TOSS,
            title = if (iWon) "You won the toss" else "$opponent won the toss",
            detail = if (iWon) "You chose to $choice — $who." else "$opponent chose to $choice — $who.",
        )
    }

    /** Fired at the innings change, before the chase begins. */
    fun inningsBreak(
        id: Int, firstInningsScore: Int, target: Int, iChase: Boolean, opponent: String,
    ): CricketAnnouncement = CricketAnnouncement(
        id = id,
        kind = CricketAnnouncement.Kind.INNINGS_BREAK,
        title = "End of the first innings",
        detail = if (iChase) "$opponent made $firstInningsScore. You need $target to win."
                 else "You made $firstInningsScore. $opponent needs $target to win.",
    )

    /** Fired whenever the local player's ROLE changes — the thing that was a small caption. */
    fun role(id: Int, batting: Boolean): CricketAnnouncement = CricketAnnouncement(
        id = id,
        kind = CricketAnnouncement.Kind.ROLE_CHANGE,
        title = if (batting) "You're batting" else "You're bowling",
        detail = if (batting) "Pick a number. If they match it, you're out."
                 else "Pick a number. Match theirs and you take the wicket.",
    )
}
