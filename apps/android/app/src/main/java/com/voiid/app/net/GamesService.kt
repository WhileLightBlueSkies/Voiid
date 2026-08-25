package com.voiid.app.net

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Match lifecycle only (docs/GAMES.md §3): catalog, create, join, history. The durable,
 * authorized half of the games system.
 *
 * There is deliberately NO move call here. Moves are WS-only (GamesEngine) — an HTTP
 * round-trip per tap would add latency to the one interaction that must feel immediate,
 * the same reasoning that keeps position fixes off the REST path.
 *
 * Mirrors iOS `GamesAPI.swift`.
 */
class GamesService(private val api: ApiClient) {

    private val json = Json { ignoreUnknownKeys = true }

    @Serializable
    data class CatalogGame(
        val id: String,
        val slug: String,
        val name: String,
        val category: String,
        val min_players: Int,
        val max_players: Int,
        val icon_key: String? = null,
    )

    @Serializable
    private data class CatalogResponse(val games: List<CatalogGame>)

    @Serializable
    data class CreateResponse(val match_id: String, val players: List<String>)

    /**
     * One opponent's head-to-head record with the caller. Scoped to people actually
     * played — never a global ranking (see the route header for why).
     */
    @Serializable
    data class LeaderboardRow(
        val opponent_id: String,
        val full_name: String? = null,
        val username: String? = null,
        val played: Int,
        val wins: Int,
        val draws: Int,
        val losses: Int,
    )

    @Serializable
    private data class LeaderboardResponse(val leaderboard: List<LeaderboardRow>)

    /** Wins per person among people the caller has finished matches with. */
    suspend fun leaderboard(slug: String? = null): List<LeaderboardRow> {
        val path = if (slug != null) "games/leaderboard?game=$slug" else "games/leaderboard"
        val body = api.request("GET", path)
        return json.decodeFromString<LeaderboardResponse>(body).leaderboard
    }

    /** The catalog. Static and small; callers may cache it for the session. */
    suspend fun catalog(): List<CatalogGame> {
        val body = api.request("GET", "games")
        return json.decodeFromString<CatalogResponse>(body).games
    }

    /**
     * Mint a match. The CALLER then sends the invite as an ordinary E2EE message carrying
     * this id — this endpoint sends no notification of its own, so one invite produces
     * exactly one alert, from the message path that already handles wake and push.
     */
    suspend fun create(
        slug: String,
        opponentIds: List<String>,
        /**
         * Per-game settings chosen at creation (hand cricket's over count). Stored on the
         * match row and validated by the ENGINE — this client sends, it does not police.
         */
        options: Map<String, Int> = emptyMap(),
        /**
         * Snake's chosen skin id. A separate field because [options] is string->int across
         * every game, and widening that for one game's cosmetic would touch four others.
         */
        skin: String? = null,
    ): String {
        val ids = opponentIds.joinToString(",") { "\"" + it + "\"" }
        val opts = options.entries.joinToString(",") { "\"${it.key}\":${it.value}" }
        val skinField = if (skin != null) ",\"skin\":\"$skin\"" else ""
        val body = api.request(
            "POST", "games/matches",
            """{"slug":"$slug","opponent_ids":[$ids],"options":{$opts}$skinField}""",
        )
        return json.decodeFromString<CreateResponse>(body).match_id
    }

    /**
     * Enter a match. The opening board does NOT come back here — the server builds it and
     * broadcasts a `game_state` frame to every player.
     */
    suspend fun join(matchId: String) {
        api.request("POST", "games/matches/$matchId/join", "{}")
    }

    /** An invite the caller has received but not joined. Drives the home-screen banners. */
    @Serializable
    data class PendingInvite(
        val match_id: String,
        val slug: String,
        val name: String,
        val icon_key: String? = null,
        /** Lifted out of the options bag by the server; 0 when the game has no such setting. */
        val overs: Int = 0,
        val inviter_id: String? = null,
        val inviter_name: String? = null,
        val sent_at: Long = 0,
        val expires_at: Long = 0,
        /** Server's verdict on whether the window has passed — not the client's clock. */
        val missed: Boolean = false,
    )

    @Serializable
    private data class InvitesResponse(val invites: List<PendingInvite>)

    /** Invites waiting on the caller: live ones to accept, missed ones to acknowledge. */
    suspend fun invites(): List<PendingInvite> {
        val body = api.request("GET", "games/invites")
        return json.decodeFromString<InvitesResponse>(body).invites
    }

    /**
     * Decline an invite, or abandon a lobby nobody joined. Same call for both — they are the
     * same state change (a 'waiting' match that will never start).
     */
    suspend fun decline(matchId: String) {
        api.request("POST", "games/matches/$matchId/decline", "{}")
    }

    /** Tell the server a player is deliberately backing out of a LIVE match screen — as
     * opposed to [decline], which is for a match that never started. Without this a
     * continuous game's tick loop had nothing telling it a player left, so backing out of
     * Snake left the match ticking (and broadcasting `game_state` at full rate) for up to its
     * full duration. See docs/GAMES_SNAKE_BUGS.md.
     *
     * Fire-and-forget from the caller's perspective — [GamesEngine.leave] clears local state
     * unconditionally regardless of whether this network call lands. */
    suspend fun leave(matchId: String) {
        api.request("POST", "games/matches/$matchId/leave", "{}")
    }

    /**
     * Play the same people again, at the same settings.
     *
     * Mints a NEW match rather than reopening the finished one: the old row holds a result the
     * leaderboard already counted, and rewriting it would change something a player has seen.
     * The server re-checks permission exactly as it does for a fresh invite, so a stale match id
     * is not a bypass.
     *
     * Returns the new match id, which the caller opens exactly as it would after [create].
     */
    suspend fun rematch(matchId: String): String {
        val body = api.request("POST", "games/matches/$matchId/rematch", "{}")
        return json.decodeFromString<CreateResponse>(body).match_id
    }

    // ── Daily challenge (docs/games/CROSS_CUTTING.md §5) ────────────────────────────────

    /**
     * One row of today's board. GLOBAL, unlike [LeaderboardRow] — see the route header: the
     * comparison is meaningful precisely because everyone played the same arena.
     */
    @Serializable
    data class DailyRow(
        val user_id: String,
        val full_name: String? = null,
        val username: String? = null,
        val score: Int,
    )

    @Serializable
    data class DailyMine(
        /** Null while a run is still going — which is how "playing" is told from "played". */
        val score: Int? = null,
        val status: String,
    )

    @Serializable
    data class DailyResponse(
        val day: String,
        val seed: Long,
        val leaderboard: List<DailyRow> = emptyList(),
        val mine: DailyMine? = null,
    )

    @Serializable
    private data class DailyStartResponse(val match_id: String, val day: String)

    suspend fun daily(): DailyResponse {
        val body = api.request("GET", "games/daily")
        return json.decodeFromString<DailyResponse>(body)
    }

    /**
     * Start today's run. Throws on 409 — they already played, which is the rule rather than an
     * error to retry.
     */
    suspend fun startDaily(skin: String?): String {
        val skinField = if (skin != null) "\"skin\":\"$skin\"" else ""
        val body = api.request("POST", "games/daily", "{$skinField}")
        return json.decodeFromString<DailyStartResponse>(body).match_id
    }

    // ── LUDO SCHEMA V3 (LUDO_GAME_SPEC.md §7.1) ─────────────────────────────────────────

    /**
     * Create a Ludo match from a chat conversation. The SERVER re-verifies membership,
     * blocks and exact seat counts — the client list is convenience only.
     *
     * @param idempotencyKey stable per create attempt; a retry returns the SAME match.
     */
    suspend fun createLudo(
        mode: String,
        creatorId: String,
        opponentIds: List<String>,
        conversationId: String?,
        gameName: String,
        idempotencyKey: String? = null,
        bots: Int = 0,
        difficulty: String = "balanced",
    ): CreateResponse {
        require(mode == "duel" || mode == "four") { "mode must be duel or four" }
        val opponents = opponentIds.joinToString(",") { "\"" + it + "\"" }
        val humans = (listOf(creatorId) + opponentIds).joinToString(",") {
            "{\"kind\":\"human\",\"user_id\":\"$it\"}"
        }
        val botEntries = List(bots) { "{\"kind\":\"bot\",\"difficulty\":\"$difficulty\"}" }
        val roster = (listOf(humans).filter { it.isNotEmpty() } + botEntries).joinToString(",")
        val idem = if (idempotencyKey != null) ",\"idempotency_key\":\"$idempotencyKey\"" else ""
        val conversation = conversationId?.let { ",\"conversation_id\":\"$it\"" } ?: ""
        val body = api.request(
            "POST", "games/matches",
            """{"slug":"ludo","mode":"$mode","opponent_ids":[$opponents],""" +
                """"roster":[$roster],"options":{"mode":"$mode"},"game_name":"$gameName"$conversation$idem}""",
        )
        return json.decodeFromString<CreateResponse>(body)
    }

    class LudoSnapshot(val seq: Int, val payload: JsonObject)

    /** Durable truth for one match, projected for THIS viewer (§9). */
    suspend fun ludoSnapshot(matchId: String): LudoSnapshot {
        val body = api.request("GET", "games/matches/$matchId/snapshot")
        val obj = json.parseToJsonElement(body).jsonObject
        val seq = obj["seq"]?.jsonPrimitive?.intOrNull ?: 0
        val payload = obj["payload"] as? JsonObject ?: JsonObject(emptyMap())
        return LudoSnapshot(seq, payload)
    }

    /** Deliberate exit from an ACTIVE match; backgrounding is never this call (§11.5). */
    suspend fun forfeit(matchId: String) {
        api.request("POST", "games/matches/$matchId/forfeit", "{}")
    }

    /** Persist the first-run walkthrough seen version cross-device (§10). Fire-and-forget upstream. */
    suspend fun setWalkthroughSeen(version: Int) {
        api.request(
            "PUT", "users/me/preferences/ludo-walkthrough",
            """{"version":$version}""",
        )
    }

    suspend fun walkthroughSeen(): Int {
        val body = api.request("GET", "users/me/preferences/ludo-walkthrough")
        val v = json.parseToJsonElement(body).jsonObject["version"]?.jsonPrimitive?.intOrNull ?: 0
        return v
    }
}
