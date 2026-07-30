package com.voiid.app.net

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The wire form of a game invite (docs/GAMES.md §3).
 *
 * WHY A TEXT-CARRIED JSON ENVELOPE AND NOT A NEW MESSAGE TYPE: the invite must arrive with a
 * push, survive the recipient being offline, and be end-to-end encrypted. The ordinary text
 * pipe already does all three, correctly, including the retry-on-reconnect queue. A bespoke
 * content_type would mean a second server contract, a second push path, and a second thing to
 * get wrong.
 *
 * SO AN INVITE IS A TEXT MESSAGE whose body is a readable line followed by a JSON payload.
 * The readable line matters for two reasons: an older build that doesn't know this format
 * shows a sensible sentence instead of a blank bubble, and the SERVER never sees any of it —
 * the whole body is inside the ratchet, which is what lets the notification name the game
 * without Apple or Google ever learning who invited whom to what.
 *
 * FORMAT:
 *   <human line>
 *   voiid:game/<slug>/<matchId>
 *   voiid:gamemeta/<base64-free JSON>
 *
 * The marker lines go LAST and are matched by prefix, so text before them is harmless. The
 * meta line is OPTIONAL: [parse] succeeds on the slug/matchId pair alone, so invites sent by
 * an older client still open the right board.
 *
 * Mirrors iOS `GameInvite.swift`.
 */
object GameInvite {

    private const val SCHEME = "voiid:game/"
    private const val META = "voiid:gamemeta/"

    /** How long an invite stays live before it counts as missed. */
    const val EXPIRY_MS = 10 * 60 * 1000L

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /**
     * Everything the poster bubble and the rich notification need, so neither has to guess.
     *
     * All of it travels INSIDE the E2EE body. That is the reason a notification can say
     * "Nehal invited you to Hand Cricket · 3 overs" while the push that woke the device said
     * only "New message": the device decrypts, then rewrites its own banner.
     */
    @Serializable
    data class Meta(
        /** Display name of the game, e.g. "Hand Cricket". */
        val game: String = "",
        /** Who sent it, for the poster and the banner. */
        val from: String = "",
        /** Bot difficulty label if relevant, else blank. Online games have no level. */
        val level: String = "",
        /** Overs for hand cricket; 0 when the game has no such setting. */
        val overs: Int = 0,
        /** "first to 3" style summary, or blank. */
        val format: String = "",
        /** Epoch millis the invite was created — the expiry clock starts here. */
        val sentAt: Long = 0L,
    ) {
        /**
         * One line of game settings for the poster, assembled from whatever is set. Built here
         * rather than in each UI so Android and iOS describe an invite identically.
         */
        fun detailLine(): String = buildList {
            if (overs > 0) add("$overs ${if (overs == 1) "over" else "overs"}")
            if (format.isNotBlank()) add(format)
            if (level.isNotBlank()) add(level)
        }.joinToString(" · ")

        val isExpired: Boolean
            get() = sentAt > 0 && System.currentTimeMillis() - sentAt > EXPIRY_MS

        /** Millis remaining, floored at zero. Drives the countdown on the home-screen banner. */
        val remainingMs: Long
            get() = if (sentAt <= 0) EXPIRY_MS
                    else (sentAt + EXPIRY_MS - System.currentTimeMillis()).coerceAtLeast(0)
    }

    /** A parsed invite. [matchId] is what `POST /games/matches/:id/join` needs. */
    data class Parsed(
        val slug: String,
        val matchId: String,
        /** Null when the sender was an older build that didn't attach meta. */
        val meta: Meta?,
    )

    /**
     * Build the message body for an invite to [matchId].
     *
     * The human line names the game so an older client's bubble still reads correctly.
     */
    fun encode(slug: String, matchId: String, meta: Meta): String = buildString {
        append("🎮 ${meta.from.ifBlank { "Someone" }} invited you to ${meta.game}")
        val details = meta.detailLine()
        if (details.isNotBlank()) append(" · $details")
        append('\n')
        append(SCHEME).append(slug).append('/').append(matchId).append('\n')
        append(META).append(json.encodeToString(Meta.serializer(), meta))
    }

    /**
     * Recover the invite from a message body, or null if this isn't one.
     *
     * Tolerant of trailing whitespace and of text before the markers, because the body is a
     * user-visible string that other code (previews, forwarding) may have touched. A malformed
     * meta line degrades to `meta = null` rather than failing the whole parse — the match id is
     * the part that matters.
     */
    fun parse(text: String): Parsed? {
        val lines = text.lines().map { it.trim() }
        val idLine = lines.lastOrNull { it.startsWith(SCHEME) } ?: return null
        val parts = idLine.removePrefix(SCHEME).split("/")
        if (parts.size != 2) return null
        val (slug, matchId) = parts
        if (slug.isBlank() || matchId.isBlank()) return null

        val meta = lines.lastOrNull { it.startsWith(META) }?.let { line ->
            runCatching {
                json.decodeFromString(Meta.serializer(), line.removePrefix(META))
            }.getOrNull()
        }
        return Parsed(slug, matchId, meta)
    }

    /** True if [text] carries an invite. Cheap enough for a render path. */
    fun isInvite(text: String): Boolean = parse(text) != null

    /**
     * What a notification or the chat list shows. Never the marker lines — a raw
     * `voiid:game/...` in a banner or conversation preview is noise.
     */
    fun preview(text: String): String =
        text.lines().firstOrNull {
            val t = it.trim()
            t.isNotBlank() && !t.startsWith(SCHEME) && !t.startsWith(META)
        } ?: "🎮 Game invite"
}
