package com.voiid.app.net

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

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
    private data class CreateResponse(val match_id: String, val players: List<String>)

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
    ): String {
        val ids = opponentIds.joinToString(",") { "\"" + it + "\"" }
        val opts = options.entries.joinToString(",") { "\"${it.key}\":${it.value}" }
        val body = api.request(
            "POST", "games/matches",
            """{"slug":"$slug","opponent_ids":[$ids],"options":{$opts}}""",
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
}
