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

    /**
     * Authoritative Rock Paper Scissors state (backend/games/src/engine/rps).
     *
     * NOTE WHAT IS ABSENT: the opponent's pending throw. While a round is open the server
     * sends only [hasThrown] — booleans, never the choices — because RPS is simultaneous and
     * leaking the first throw would let whoever moves second win every time. The view
     * therefore CANNOT render the opponent's hand mid-round, by design: there is nothing to
     * render. Resolved rounds arrive in [history], where both throws are safe to show.
     */
    data class RpsState(
        /** Seat order. Index 0 and 1 map to the two entries in [wins] and [hasThrown]. */
        val players: List<String>,
        /** Rounds needed to take the match (server default 3). */
        val target: Int,
        /** Rounds won, by seat. */
        val wins: List<Int>,
        /** Whether each seat has thrown THIS round. Never what they threw. */
        val hasThrown: List<Boolean>,
        /** Resolved rounds, oldest first. Safe to show in full. */
        val history: List<Round>,
        val finished: Boolean,
        val winnerUserId: String?,
    ) {
        /** One resolved round: both throws, and who took it. */
        data class Round(
            /** "rock" | "paper" | "scissors", by seat. */
            val throws: List<String>,
            /** Seat that won, or null for a tie. */
            val winner: Int?,
        )
    }

    /**
     * Authoritative Hand Cricket state (docs/GAMES_HAND_CRICKET.md).
     *
     * Same anti-cheat shape as [RpsState]: [hasPicked] is booleans, never the picks. A pick is
     * revealed only once the ball has resolved, in [history].
     */
    data class CricketState(
        val players: List<String>,
        val overs: Int,
        val innings: Int,
        /** Seat batting RIGHT NOW. Swaps between innings. */
        val battingSeat: Int,
        val scores: List<Int>,
        val wickets: List<Int>,
        val ballsBowled: Int,
        /** `overs * 6`, sent by the server so the client needn't know the balls-per-over rule. */
        val ballsTotal: Int,
        val wicketsPerInnings: Int,
        /** Runs the chasing side needs to WIN. Null during the first innings. */
        val target: Int?,
        val hasPicked: List<Boolean>,
        val history: List<Ball>,
        val finished: Boolean,
        val winnerUserId: String?,
    ) {
        /** One resolved ball. Both picks are safe here — the ball is already scored. */
        data class Ball(
            val picks: List<Int>,
            val battingSeat: Int,
            val innings: Int,
            val runs: Int,
            val wicket: Boolean,
        )
    }

    private val appContext = context.applicationContext
    private val tokens = TokenStore.get(context)
    private val service = GamesService(ApiClient(tokens))

    private val _state = MutableStateFlow<TicTacToeState?>(null)
    val state: StateFlow<TicTacToeState?> = _state.asStateFlow()

    /**
     * RPS state, for the RPS renderer. A SEPARATE flow rather than a sealed `GameState`
     * union: each screen renders exactly one game and would have to cast out of a union on
     * every frame anyway, and a mistyped cast is a crash where an unused null flow is inert.
     */
    private val _rps = MutableStateFlow<RpsState?>(null)
    val rps: StateFlow<RpsState?> = _rps.asStateFlow()

    private val _cricket = MutableStateFlow<CricketState?>(null)
    val cricket: StateFlow<CricketState?> = _cricket.asStateFlow()

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
        // Dispatch on the game the SERVER named, not on anything the client remembered: the
        // frame is the authority on what it contains.
        when (game) {
            "rps" -> _rps.value = parseRps(payload)
            "cricket" -> _cricket.value = parseCricket(payload)
            else -> _state.value = parse(payload)
        }
    }

    private fun parseCricket(payload: JsonObject): CricketState? {
        val players = payload["players"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull }
            ?: return null
        val history = payload["history"]?.jsonArray?.mapNotNull { entry ->
            val obj = entry as? JsonObject ?: return@mapNotNull null
            val picks = obj["picks"]?.jsonArray?.mapNotNull { it.jsonPrimitive.intOrNull }
                ?: return@mapNotNull null
            CricketState.Ball(
                picks = picks,
                battingSeat = obj["battingSeat"]?.jsonPrimitive?.intOrNull ?: 0,
                innings = obj["innings"]?.jsonPrimitive?.intOrNull ?: 1,
                runs = obj["runs"]?.jsonPrimitive?.intOrNull ?: 0,
                wicket = obj["wicket"]?.jsonPrimitive?.booleanOrNull ?: false,
            )
        } ?: emptyList()
        fun ints(key: String, fallback: List<Int>) =
            payload[key]?.jsonArray?.map { it.jsonPrimitive.intOrNull ?: 0 } ?: fallback
        return CricketState(
            players = players,
            overs = payload["overs"]?.jsonPrimitive?.intOrNull ?: 2,
            innings = payload["innings"]?.jsonPrimitive?.intOrNull ?: 1,
            battingSeat = payload["battingSeat"]?.jsonPrimitive?.intOrNull ?: 0,
            scores = ints("scores", listOf(0, 0)),
            wickets = ints("wickets", listOf(0, 0)),
            ballsBowled = payload["ballsBowled"]?.jsonPrimitive?.intOrNull ?: 0,
            ballsTotal = payload["ballsTotal"]?.jsonPrimitive?.intOrNull ?: 12,
            wicketsPerInnings = payload["wicketsPerInnings"]?.jsonPrimitive?.intOrNull ?: 2,
            target = payload["target"]?.jsonPrimitive?.intOrNull,
            hasPicked = payload["hasPicked"]?.jsonArray?.map {
                it.jsonPrimitive.booleanOrNull ?: false
            } ?: listOf(false, false),
            history = history,
            finished = payload["finished"]?.jsonPrimitive?.booleanOrNull ?: false,
            winnerUserId = payload["winnerUserId"]?.jsonPrimitive?.contentOrNull,
        )
    }

    private fun parseRps(payload: JsonObject): RpsState? {
        val players = payload["players"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull }
            ?: return null
        val history = payload["history"]?.jsonArray?.mapNotNull { entry ->
            val obj = entry as? JsonObject ?: return@mapNotNull null
            val throws = obj["throws"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull }
                ?: return@mapNotNull null
            RpsState.Round(
                throws = throws,
                winner = obj["winner"]?.jsonPrimitive?.intOrNull,
            )
        } ?: emptyList()
        return RpsState(
            players = players,
            target = payload["target"]?.jsonPrimitive?.intOrNull ?: 3,
            wins = payload["wins"]?.jsonArray?.map { it.jsonPrimitive.intOrNull ?: 0 }
                ?: listOf(0, 0),
            hasThrown = payload["hasThrown"]?.jsonArray?.map {
                it.jsonPrimitive.booleanOrNull ?: false
            } ?: listOf(false, false),
            history = history,
            finished = payload["finished"]?.jsonPrimitive?.booleanOrNull ?: false,
            winnerUserId = payload["winnerUserId"]?.jsonPrimitive?.contentOrNull,
        )
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
        _rps.value = null
        _cricket.value = null
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
        /** Per-game settings chosen before the match exists (hand cricket's over count). */
        options: Map<String, Int> = emptyMap(),
    ): String? {
        return runCatching {
            val id = service.create(slug, listOf(opponentId), options)
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

    /**
     * Throw for this RPS round. [choice] is "rock" | "paper" | "scissors".
     *
     * Fire-and-forget like [play]: the round resolves when the SERVER says both throws are
     * in. A second throw in the same round is rejected server-side (re-throwing would let a
     * player change their mind after the opponent commits), so this doesn't police it either.
     */
    fun throwRps(context: Context, choice: String) {
        val id = matchId ?: return
        val s = _rps.value ?: return
        if (s.finished) return
        WebSocketClient.get(context).sendGameInput(id, """{"throw":"$choice"}""")
    }

    /**
     * Pick a number (0–6) for this cricket ball. Same fire-and-forget contract as [play]: the
     * ball resolves when the SERVER says both picks are in, and a second pick on the same ball
     * is rejected server-side.
     */
    fun pickCricket(context: Context, pick: Int) {
        val id = matchId ?: return
        val s = _cricket.value ?: return
        if (s.finished) return
        WebSocketClient.get(context).sendGameInput(id, """{"pick":$pick}""")
    }

    fun leave() {
        matchId = null
        _state.value = null
        _rps.value = null
        _cricket.value = null
        _joinError.value = null
        lastSeq = -1
    }
}
