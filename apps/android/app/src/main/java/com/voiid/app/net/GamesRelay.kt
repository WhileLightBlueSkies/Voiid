package com.voiid.app.net

import kotlinx.serialization.json.JsonObject

/**
 * The integration seam between the WS transport and whatever game screen is open —
 * docs/GAMES.md §4. Mirrors [LocationRelay], and exists for the same reason: a single
 * mutable callback on WebSocketClient would let one consumer clobber another, and a
 * subscriber list keeps the shared-file edit down to one fan-out call.
 *
 * Unlike LocationRelay, what crosses here is NOT opaque: game state is readable, because
 * the server referees the match and must read moves to validate them. That is a scoped
 * exception to this app's E2EE posture (docs/GAMES.md §2) and applies to game state only
 * — the invite that starts a match is still an ordinary encrypted message.
 *
 * A subscriber MUST ignore any match_id it is not currently showing.
 */
object GamesRelay {

    /** Inbound authoritative state for one match (WS `game_state`). */
    fun interface StateSink {
        fun onState(matchId: String, game: String, seq: Int, payload: JsonObject)
    }

    private val sinks = mutableListOf<StateSink>()

    fun subscribe(s: StateSink) = synchronized(sinks) { if (!sinks.contains(s)) sinks.add(s) }
    fun unsubscribe(s: StateSink) = synchronized(sinks) { sinks.remove(s) }

    fun dispatchState(matchId: String, game: String, seq: Int, payload: JsonObject) {
        val snapshot = synchronized(sinks) { sinks.toList() }
        snapshot.forEach { it.onState(matchId, game, seq, payload) }
    }
}
