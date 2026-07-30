package com.voiid.app.net

/**
 * The wire form of a game invite (docs/GAMES.md §3).
 *
 * WHY A TEXT TOKEN AND NOT A NEW MESSAGE TYPE: the invite must arrive with a push, survive
 * the recipient being offline, and be end-to-end encrypted. The ordinary text pipe already
 * does all three, correctly, including the retry-on-reconnect queue. A bespoke content_type
 * would mean a second server contract, a second push path, and a second thing to get wrong
 * — for a payload that is two ids.
 *
 * So an invite IS a text message whose body happens to be recognisable. Clients that
 * understand the token draw a Join button; an older build shows a readable line of text
 * rather than a blank bubble, which is the whole reason the human-readable prefix is part
 * of the format instead of a bare URI.
 *
 * FORMAT: `<human text>\nvoiid:game/<slug>/<matchId>`
 * The marker goes LAST so `text.lines().last()` finds it regardless of what precedes it.
 *
 * Mirrors iOS `GameInvite.swift`.
 */
object GameInvite {

    private const val SCHEME = "voiid:game/"

    /** A parsed invite. [matchId] is what `POST /games/matches/:id/join` needs. */
    data class Parsed(val slug: String, val matchId: String)

    /**
     * Build the message body for an invite to [matchId].
     *
     * [gameName] is the display name from the catalog ("Tic Tac Toe"), so the readable half
     * names the actual game rather than a slug.
     */
    fun encode(slug: String, matchId: String, gameName: String): String =
        "🎮 Let's play $gameName!\n$SCHEME$slug/$matchId"

    /**
     * Recover the invite from a message body, or null if this isn't one.
     *
     * Tolerant of trailing whitespace and of text before the marker, because the body is a
     * user-visible string that other code (previews, forwarding) may have touched.
     */
    fun parse(text: String): Parsed? {
        val line = text.lines().map { it.trim() }.lastOrNull { it.startsWith(SCHEME) }
            ?: return null
        val parts = line.removePrefix(SCHEME).split("/")
        if (parts.size != 2) return null
        val (slug, matchId) = parts
        if (slug.isBlank() || matchId.isBlank()) return null
        return Parsed(slug, matchId)
    }

    /** True if [text] carries an invite. Cheap enough for a render path. */
    fun isInvite(text: String): Boolean = parse(text) != null

    /**
     * What the chat LIST shows for an invite. The raw token in a conversation preview would
     * be noise, so the marker never reaches the list.
     */
    fun preview(text: String): String =
        text.lines().firstOrNull { !it.trim().startsWith(SCHEME) && it.isNotBlank() }
            ?: "🎮 Game invite"
}
