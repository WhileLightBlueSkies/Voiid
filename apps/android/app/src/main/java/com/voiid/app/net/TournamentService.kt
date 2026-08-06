package com.voiid.app.net

import kotlinx.serialization.Serializable

/**
 * Client for the tournament API (plan item 3.22). Mirrors `TournamentService.swift`.
 *
 * The backend shipped complete — brackets, seeding, registration, standings — and nothing on
 * either app referenced it, so no user could see a tournament existed. This is the half that
 * makes it reachable.
 *
 * ## Not E2EE, and that is the design
 * A bracket is a shared public structure inside a community: the server seeds it, advances it
 * and decides who won, which it can only do by reading it. Game MOVES are refereed by
 * `backend/games`; the bracket around them is ordinary server state, exactly like the
 * community container itself. Nothing on this screen claims otherwise.
 *
 * ## Membership is the gate
 * Every endpoint here is community-scoped and the server checks membership on each one; a
 * non-member gets 403 rather than an empty list. This client does not pre-filter on top of
 * that — one authority, not two.
 */
class TournamentService(private val api: ApiClient) {

    /**
     * One tournament, as the list and detail endpoints both return it.
     *
     * Every nullable field and every default is deliberate: this is a RESPONSE model, so a
     * field the server stops sending must degrade the row, not fail the whole decode.
     */
    @Serializable
    data class Tournament(
        val id: String,
        val name: String,
        /** single_elim | double_elim | round_robin — decides what the bracket looks like. */
        val format: String? = null,
        /** draft | registering | running | finished | cancelled. */
        val status: String? = null,
        val game_name: String? = null,
        val game_slug: String? = null,
        val max_players: Int? = null,
        val player_count: Int? = null,
        val starts_at: String? = null,
        val winner_user_id: String? = null,
        /** Whether YOU are on the roster — decides Register vs Withdraw. */
        val registered: Boolean = false,
    )

    @Serializable
    private data class ListResponse(val tournaments: List<Tournament> = emptyList())

    suspend fun list(communityId: String): List<Tournament> {
        val raw = api.request("GET", "communities/$communityId/tournaments")
        return ApiClient.json.decodeFromString(ListResponse.serializer(), raw).tournaments
    }

    /**
     * Join the roster. The server owns capacity and the registration window, so a full or
     * closed tournament is refused there — this client does not gate on `player_count`, which
     * it read some seconds ago and which several people may be racing to fill.
     */
    suspend fun register(id: String) {
        api.request("POST", "tournaments/$id/register")
    }

    suspend fun withdraw(id: String) {
        api.request("POST", "tournaments/$id/withdraw")
    }
}
