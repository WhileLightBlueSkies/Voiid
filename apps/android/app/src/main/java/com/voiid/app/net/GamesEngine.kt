package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Client half of the games system (docs/GAMES.md §4). Mirrors iOS `GamesEngine.swift`:
 * subscribes to game frames via [GamesRelay], exposes the current match as a StateFlow,
 * and turns taps into `game_input` frames on the socket the app already holds open.
 *
 * THE RULE FOR EVERY GAME SCREEN: this is a renderer, not a referee. It never decides
 * whose turn it is, whether a move is legal, or who won — it draws what the server sent.
 * Optimistic local updates are deliberately ABSENT: predicting the board and then
 * correcting it on the server frame is how pieces flicker and un-place themselves.
 */
class GamesEngine private constructor(context: Context) : GamesRelay.StateSink {

    companion object {
        @Volatile private var instance: GamesEngine? = null
        fun get(context: Context): GamesEngine =
            instance ?: synchronized(this) {
                instance ?: GamesEngine(context.applicationContext).also { instance = it }
            }
    }

    /** Authoritative Tic Tac Toe state as broadcast by backend/games. */
    data class TicTacToeState(
        /** Seat order — index doubles as the mark (0 = X, 1 = O). */
        val players: List<String>,
        /** 9 cells, row-major. Each is the seat index that owns it, or null. */
        val board: List<Int?>,
        /** Null once the match is over. */
        val turnUserId: String?,
        val finished: Boolean,
        val winnerUserId: String?,
        /** Winning triple, so the view highlights it without re-deriving the win. */
        val line: List<Int>?,
    )

    private val appContext = context.applicationContext
    private val tokens = TokenStore.get(context)
    private val service = GamesService(ApiClient(tokens))

    private val _state = MutableStateFlow<TicTacToeState?>(null)
    val state: StateFlow<TicTacToeState?> = _state.asStateFlow()

    private val _joinError = MutableStateFlow<String?>(null)
    val joinError: StateFlow<String?> = _joinError.asStateFlow()

    private var matchId: String? = null

    /**
     * Last seq applied. Out-of-order frames are dropped — the same defensive posture as
     * the offline-buffer/flush pattern elsewhere. WS is TCP so this is rare, but a late
     * frame would otherwise resurrect a stale board.
     */
    private var lastSeq: Int = -1

    val myUserId: String? get() = tokens.userId

    init {
        GamesRelay.subscribe(this)
    }

    override fun onState(matchId: String, game: String, seq: Int, payload: JsonObject) {
        // A frame for a match this screen isn't showing is not ours to render.
        if (matchId != this.matchId) return
        if (seq < lastSeq) return
        lastSeq = seq
        _state.value = parse(payload)
    }

    private fun parse(payload: JsonObject): TicTacToeState? {
        val players = payload["players"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull }
            ?: return null
        val board = payload["board"]?.jsonArray?.map { it.jsonPrimitive.intOrNull } ?: return null
        return TicTacToeState(
            players = players,
            board = board,
            turnUserId = payload["turnUserId"]?.jsonPrimitive?.contentOrNull,
            finished = payload["finished"]?.jsonPrimitive?.booleanOrNull ?: false,
            winnerUserId = payload["winnerUserId"]?.jsonPrimitive?.contentOrNull,
            line = payload["line"]?.jsonArray?.mapNotNull { it.jsonPrimitive.intOrNull },
        )
    }

    /**
     * Enter a match. The opening board arrives as a `game_state` frame, not from this
     * call — the server builds it (wake-then-fetch, same as Stories).
     */
    suspend fun open(matchId: String) {
        this.matchId = matchId
        _state.value = null
        _joinError.value = null
        lastSeq = -1
        runCatching { service.join(matchId) }
            .onFailure { _joinError.value = "Couldn't join this match." }
    }

    /**
     * Create a match against one opponent, TELL THEM, and enter it. Returns the id, or null
     * on failure.
     *
     * THE INVITE IS THE POINT. `POST /games/matches` deliberately sends no notification of
     * its own (see routes/games.ts) — it only mints the row. Without the [ChatEngine] send
     * below, the opponent is a player in a match they are never told about, and the creator
     * stares at a board nobody can join. That was the bug: the match existed, the invite
     * never did.
     *
     * The invite goes out BEFORE we open the board so a failure to reach the peer surfaces
     * as an error instead of a board that will never get a second player. It travels as an
     * ordinary E2EE text message ([GameInvite]) so wake, push, and offline retry are the
     * ones the message pipe already gets right.
     */
    suspend fun create(
        slug: String,
        opponentId: String,
        conversationId: String,
        gameName: String,
    ): String? {
        return runCatching {
            val id = service.create(slug, listOf(opponentId))
            ChatEngine.get(appContext)
                .sendText(GameInvite.encode(slug, id, gameName), conversationId, opponentId)
            open(id)
            id
        }.getOrElse {
            _joinError.value = "Couldn't send the invite."
            null
        }
    }

    /**
     * Tap a cell. Fire-and-forget by design: the board changes when the SERVER says it
     * changed. An illegal tap is ignored server-side and no frame comes back.
     */
    fun play(context: Context, cell: Int) {
        val id = matchId ?: return
        val s = _state.value ?: return
        if (s.finished) return
        WebSocketClient.get(context).sendGameInput(id, """{"cell":$cell}""")
    }

    fun leave() {
        matchId = null
        _state.value = null
        _joinError.value = null
        lastSeq = -1
    }
}
