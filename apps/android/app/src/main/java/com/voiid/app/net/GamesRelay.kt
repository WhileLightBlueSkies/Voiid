package com.voiid.app.net

import kotlinx.serialization.json.JsonObject

/**
 * The integration seam between the WS transport and whatever game screen is open —
 * docs/GAMES.md §4. Mirrors [LocationRelay], and exists for the same reason: a single
 * mutable callback on WebSocketClient would let one consumer clobber another, and a
 * subscriber list keeps the shared-file edit down to one fan-out call.
 *
 * Unlike LocationRelay, what crosses here is NOT opaque: game state is readable, because the
 * server referees the match and must read moves to validate it. That is a scoped exception to
 * this app's E2EE posture (docs/GAMES.md §2) and applies to game state only — the invite that
 * starts a match is still an ordinary encrypted message.
 *
 * A subscriber MUST ignore any match_id it is not currently showing.
 *
 * LUDO SCHEMA V2 adds the §7.2 server-to-client frames: rejections, presence flips, invite
 * card state and terminal endings. Each gets its own sink list so a screen subscribes only to
 * what it renders, and chat surfaces can consume invite status without touching boards.
 */
object GamesRelay {

    /** Inbound authoritative state for one match (WS `game_state`). */
    fun interface StateSink {
        fun onState(matchId: String, game: String, seq: Int, payload: JsonObject)
    }

    /** A submitted command was rejected; `code` is one of the §7.2 codes. */
    data class Rejection(val matchId: String, val commandId: String?, val code: String, val currentSeq: Int)

    fun interface RejectionSink {
        fun onRejected(rejection: Rejection)
    }

    data class Presence(val matchId: String, val seat: Int, val connection: String)

    fun interface PresenceSink {
        fun onPresence(presence: Presence)
    }

    data class InviteStatus(
        val matchId: String,
        val status: String,
        val acceptedSeats: Int,
        val totalSeats: Int,
        val expiresAt: Long,
    )

    fun interface InviteStatusSink {
        fun onInviteStatus(status: InviteStatus)
    }

    data class Ended(val matchId: String, val winnerSeat: Int?, val endReason: String?)

    fun interface EndedSink {
        fun onEnded(ended: Ended)
    }

    private val sinks = mutableListOf<StateSink>()
    private val rejectionSinks = mutableListOf<RejectionSink>()
    private val presenceSinks = mutableListOf<PresenceSink>()
    private val inviteStatusSinks = mutableListOf<InviteStatusSink>()
    private val endedSinks = mutableListOf<EndedSink>()

    fun subscribe(s: StateSink) = synchronized(sinks) { if (!sinks.contains(s)) sinks.add(s) }
    fun unsubscribe(s: StateSink) = synchronized(sinks) { sinks.remove(s) }

    fun subscribeRejections(s: RejectionSink) =
        synchronized(rejectionSinks) { if (!rejectionSinks.contains(s)) rejectionSinks.add(s) }
    fun unsubscribeRejections(s: RejectionSink) = synchronized(rejectionSinks) { rejectionSinks.remove(s) }

    fun subscribePresence(s: PresenceSink) =
        synchronized(presenceSinks) { if (!presenceSinks.contains(s)) presenceSinks.add(s) }
    fun unsubscribePresence(s: PresenceSink) = synchronized(presenceSinks) { presenceSinks.remove(s) }

    fun subscribeInviteStatus(s: InviteStatusSink) =
        synchronized(inviteStatusSinks) { if (!inviteStatusSinks.contains(s)) inviteStatusSinks.add(s) }
    fun unsubscribeInviteStatus(s: InviteStatusSink) = synchronized(inviteStatusSinks) { inviteStatusSinks.remove(s) }

    fun subscribeEnded(s: EndedSink) =
        synchronized(endedSinks) { if (!endedSinks.contains(s)) endedSinks.add(s) }
    fun unsubscribeEnded(s: EndedSink) = synchronized(endedSinks) { endedSinks.remove(s) }

    fun dispatchState(matchId: String, game: String, seq: Int, payload: JsonObject) {
        val snapshot = synchronized(sinks) { sinks.toList() }
        snapshot.forEach { it.onState(matchId, game, seq, payload) }
    }

    fun dispatchRejected(matchId: String, commandId: String?, code: String, currentSeq: Int) {
        val r = Rejection(matchId, commandId, code, currentSeq)
        val snapshot = synchronized(rejectionSinks) { rejectionSinks.toList() }
        snapshot.forEach { it.onRejected(r) }
    }

    fun dispatchPresence(matchId: String, seat: Int, connection: String) {
        val p = Presence(matchId, seat, connection)
        val snapshot = synchronized(presenceSinks) { presenceSinks.toList() }
        snapshot.forEach { it.onPresence(p) }
    }

    fun dispatchInviteStatus(
        matchId: String,
        status: String,
        acceptedSeats: Int,
        totalSeats: Int,
        expiresAt: Long,
    ) {
        val s = InviteStatus(matchId, status, acceptedSeats, totalSeats, expiresAt)
        val snapshot = synchronized(inviteStatusSinks) { inviteStatusSinks.toList() }
        snapshot.forEach { it.onInviteStatus(s) }
    }

    fun dispatchEnded(matchId: String, winnerSeat: Int?, endReason: String?) {
        val e = Ended(matchId, winnerSeat, endReason)
        val snapshot = synchronized(endedSinks) { endedSinks.toList() }
        snapshot.forEach { it.onEnded(e) }
    }
}
