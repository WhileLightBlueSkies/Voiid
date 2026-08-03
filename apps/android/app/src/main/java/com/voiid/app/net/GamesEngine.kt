package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
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
        private const val TAG = "GamesEngine"

        /** Matches the server's snake tick rate — see [steer] for why input is capped to it. */
        private const val STEER_INTERVAL_MS = 100L
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

    /**
     * Authoritative Snake state (backend/games/src/engine/snake).
     *
     * THE FIRST CONTINUOUS GAME, and the first that needs more from this layer than "parse
     * and draw". The server ticks at 10 Hz, so a renderer drawing frames as they land would
     * show 10 fps of visible stepping. The screen therefore keeps the PREVIOUS frame too and
     * interpolates between the pair (see `SnakeArenaScreen.kt`).
     *
     * That is interpolation, not prediction — it draws only positions the server has already
     * confirmed, slightly in the past. It cannot invent a position, so the
     * "renderer, not referee" rule at the top of this file still holds exactly.
     *
     * Mirrors iOS `SnakeState`.
     */
    data class SnakeState(
        val players: List<String>,
        val snakes: List<Snake>,
        val food: List<Food>,
        val time: Double,
        val arenaRadius: Double,
        val duration: Double,
        val finished: Boolean,
        val winnerUserId: String?,
    ) {
        data class Snake(
            val id: String,
            val isBot: Boolean,
            val x: Double,
            val y: Double,
            val heading: Double,
            val mass: Double,
            val alive: Boolean,
            val boosting: Boolean,
            /** Absolute body points, head first, already decoded from the wire's delta form. */
            val path: List<Point>,
            val kills: Int,
            val deaths: Int,
            val score: Int,
            val invulnUntil: Double,
            val colorIndex: Int,
        )

        data class Point(val x: Double, val y: Double)

        /** [value]: 1 = standard, 2 = corpse, 0.5 = boost drop. */
        data class Food(val id: Int, val x: Double, val y: Double, val value: Double)
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

    /**
     * Current snake frame and the one before it.
     *
     * The previous frame is kept because the renderer interpolates between the two: at a
     * 10 Hz tick, drawing each frame on arrival would visibly step. It also supplies the
     * baseline that food deltas are applied against.
     */
    private val _snake = MutableStateFlow<SnakeState?>(null)
    val snake: StateFlow<SnakeState?> = _snake.asStateFlow()

    private val _snakePrevious = MutableStateFlow<SnakeState?>(null)
    val snakePrevious: StateFlow<SnakeState?> = _snakePrevious.asStateFlow()

    /**
     * Uptime millis at which the current snake frame landed, so the screen knows how far to
     * interpolate. Deliberately elapsedRealtime rather than wall clock — the two differ by an
     * unknown offset from the server and only the local one paces drawing, and a wall clock
     * can jump mid-match.
     */
    @Volatile var snakeFrameAt: Long = 0L
        private set

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
            "snake" -> {
                // Parse against the CURRENT frame, because food deltas are relative to it,
                // then shift it into `previous` for the renderer to interpolate from.
                val next = parseSnake(payload, _snake.value) ?: return
                _snakePrevious.value = _snake.value
                _snake.value = next
                snakeFrameAt = android.os.SystemClock.elapsedRealtime()
            }
            else -> _state.value = parse(payload)
        }
    }

    /**
     * Decode one snake's body.
     *
     * The wire form is `[headX, headY, dx, dy, ...]` in `pathStep` units — absolute
     * coordinates only for the head, deltas after, because consecutive body points sit a few
     * units apart and their deltas are far shorter to encode. Long snakes are also decimated
     * past the head, which needs no handling here: a halved segment is simply a longer delta,
     * and the curve through the points has the same shape.
     */
    private fun decodePath(raw: List<Double>, step: Double): List<SnakeState.Point> {
        if (raw.size < 2) return emptyList()
        val out = ArrayList<SnakeState.Point>(raw.size / 2)
        var x = raw[0]
        var y = raw[1]
        out.add(SnakeState.Point(x, y))
        var i = 2
        while (i + 1 < raw.size) {
            x += raw[i] * step
            y += raw[i + 1] * step
            out.add(SnakeState.Point(x, y))
            i += 2
        }
        return out
    }

    /** `previous` supplies the food field when this frame carries only a delta. */
    private fun parseSnake(payload: JsonObject, previous: SnakeState?): SnakeState? {
        val players = payload.arr("players")?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?: return null
        val rawSnakes = payload.arr("snakes") ?: return null
        val step = payload.dbl("pathStep") ?: 1.0

        val snakes = rawSnakes.mapNotNull { entry ->
            val o = entry as? JsonObject ?: return@mapNotNull null
            val id = o.str("id") ?: return@mapNotNull null
            SnakeState.Snake(
                id = id,
                isBot = o.bool("bot") ?: false,
                x = o.dbl("x") ?: 0.0,
                y = o.dbl("y") ?: 0.0,
                heading = o.dbl("h") ?: 0.0,
                mass = o.dbl("m") ?: 0.0,
                alive = o.bool("a") ?: false,
                boosting = o.bool("b") ?: false,
                path = decodePath(
                    o.arr("p")?.mapNotNull { (it as? JsonPrimitive)?.doubleOrNull } ?: emptyList(),
                    step),
                kills = o.int("k") ?: 0,
                deaths = o.int("d") ?: 0,
                score = o.int("s") ?: 0,
                invulnUntil = o.dbl("iv") ?: 0.0,
                colorIndex = o.int("c") ?: 0,
            )
        }

        // Food arrives as a full snapshot or as add/remove deltas. Rebuilding from the
        // previous frame is what keeps it off the wire ~90% of the time.
        val food = LinkedHashMap<Int, SnakeState.Food>()
        fun addEntries(arr: JsonArray?) {
            arr?.forEach { entry ->
                val nums = (entry as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.doubleOrNull }
                if (nums != null && nums.size >= 4) {
                    val id = nums[3].toInt()
                    food[id] = SnakeState.Food(id, nums[0], nums[1], nums[2])
                }
            }
        }

        if (payload.bool("foodFull") != false) {
            addEntries(payload.arr("food"))
        } else {
            previous?.food?.forEach { food[it.id] = it }
            addEntries(payload.arr("foodAdd"))
            payload.arr("foodDel")?.forEach { entry ->
                (entry as? JsonPrimitive)?.intOrNull?.let { food.remove(it) }
            }
        }

        return SnakeState(
            players = players,
            snakes = snakes,
            food = food.values.toList(),
            time = payload.dbl("t") ?: 0.0,
            arenaRadius = payload.dbl("arenaRadius") ?: 1400.0,
            duration = payload.dbl("duration") ?: 180.0,
            finished = payload.bool("finished") ?: false,
            winnerUserId = payload.str("winnerUserId"),
        )
    }

    private fun parseCricket(payload: JsonObject): CricketState? {
        val players = payload.arr("players")?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?: return null
        val history = payload.arr("history")?.mapNotNull { entry ->
            val obj = entry as? JsonObject ?: return@mapNotNull null
            val picks = obj.arr("picks")?.mapNotNull { (it as? JsonPrimitive)?.intOrNull }
                ?: return@mapNotNull null
            CricketState.Ball(
                picks = picks,
                battingSeat = obj.int("battingSeat") ?: 0,
                innings = obj.int("innings") ?: 1,
                runs = obj.int("runs") ?: 0,
                wicket = obj.bool("wicket") ?: false,
            )
        } ?: emptyList()
        fun ints(key: String, fallback: List<Int>) =
            payload.arr(key)?.map { (it as? JsonPrimitive)?.intOrNull ?: 0 } ?: fallback
        return CricketState(
            players = players,
            overs = payload.int("overs") ?: 2,
            innings = payload.int("innings") ?: 1,
            battingSeat = payload.int("battingSeat") ?: 0,
            scores = ints("scores", listOf(0, 0)),
            wickets = ints("wickets", listOf(0, 0)),
            ballsBowled = payload.int("ballsBowled") ?: 0,
            ballsTotal = payload.int("ballsTotal") ?: 12,
            wicketsPerInnings = payload.int("wicketsPerInnings") ?: 2,
            target = payload.int("target"),
            hasPicked = payload.arr("hasPicked")?.map {
                (it as? JsonPrimitive)?.booleanOrNull ?: false
            } ?: listOf(false, false),
            history = history,
            finished = payload.bool("finished") ?: false,
            winnerUserId = payload.str("winnerUserId"),
        )
    }

    private fun parseRps(payload: JsonObject): RpsState? {
        val players = payload.arr("players")?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?: return null
        val history = payload.arr("history")?.mapNotNull { entry ->
            val obj = entry as? JsonObject ?: return@mapNotNull null
            val throws = obj.arr("throws")?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                ?: return@mapNotNull null
            RpsState.Round(
                throws = throws,
                winner = obj.int("winner"),
            )
        } ?: emptyList()
        return RpsState(
            players = players,
            target = payload.int("target") ?: 3,
            wins = payload.arr("wins")?.map { (it as? JsonPrimitive)?.intOrNull ?: 0 }
                ?: listOf(0, 0),
            hasThrown = payload.arr("hasThrown")?.map {
                (it as? JsonPrimitive)?.booleanOrNull ?: false
            } ?: listOf(false, false),
            history = history,
            finished = payload.bool("finished") ?: false,
            winnerUserId = payload.str("winnerUserId"),
        )
    }

    private fun parse(payload: JsonObject): TicTacToeState? {
        val players = payload.arr("players")?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?: return null
        val board = payload.arr("board")?.map { (it as? JsonPrimitive)?.intOrNull } ?: return null
        return TicTacToeState(
            players = players,
            board = board,
            turnUserId = payload.str("turnUserId"),
            finished = payload.bool("finished") ?: false,
            winnerUserId = payload.str("winnerUserId"),
            line = payload.arr("line")?.mapNotNull { (it as? JsonPrimitive)?.intOrNull },
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
        _snake.value = null
        _snakePrevious.value = null
        pendingHeading = null
        lastSentBoost = false
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
            android.util.Log.i(TAG, "create: slug=$slug peer=$opponentId convo=$conversationId opts=$options")
            val id = service.create(slug, listOf(opponentId), options)
            android.util.Log.i(TAG, "create: match minted id=$id — sending invite")
            // Everything the poster bubble and the rich notification need travels INSIDE the
            // encrypted body — which is what lets the recipient's banner name the game while the
            // push that woke their device said only "New message".
            val meta = GameInvite.Meta(
                game = gameName,
                from = myUserId?.let {
                    com.voiid.app.store.UserDirectory.displayName(it, "")
                }.orEmpty(),
                overs = options["overs"] ?: 0,
                format = if (slug == "rps") "first to 3" else "",
                sentAt = System.currentTimeMillis(),
            )
            ChatEngine.get(appContext)
                .sendText(GameInvite.encode(slug, id, meta), conversationId, opponentId)
            android.util.Log.i(TAG, "create: invite message sent for $id")
            open(id)
            id
        }.getOrElse {
            // LOG IT. A bare runCatching here meant any failure — a 500 from the match POST, a
            // missing prekey on the peer, a decrypt error — produced no lobby, no invite and no
            // banner, with nothing to say which. That silence is why this looked like "the invite
            // feature doesn't work" rather than one nameable failure.
            android.util.Log.e(TAG, "create FAILED: ${it::class.java.simpleName}: ${it.message}", it)
            _joinError.value = "Couldn't send the invite: ${it.message}"
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

    /**
     * Steer. [heading] is radians in world space; [boost] is whether the pedal is held.
     *
     * Rate-limited to the server's tick rate rather than sent on every touch callback. A drag
     * fires far faster than 10 Hz and the extra frames cannot change anything — the server
     * reads the latest heading once per tick and discards the rest — so sending them would
     * burn uplink and radio for no visible effect, and would trip the per-match input limit.
     *
     * Unsent changes are not queued: the newest heading replaces the last, which is the right
     * semantics for a continuous control. A stale heading has no value.
     */
    fun steer(context: Context, heading: Double, boost: Boolean) {
        val id = matchId ?: return
        val s = _snake.value ?: return
        if (s.finished) return

        val now = android.os.SystemClock.elapsedRealtime()
        // Boost edges go immediately: a dropped press is a lost fight, and it is an edge
        // rather than a continuous value.
        val boostChanged = boost != lastSentBoost
        if (!boostChanged && now - lastSteerSentAt < STEER_INTERVAL_MS) {
            pendingHeading = heading
            return
        }

        lastSteerSentAt = now
        lastSentBoost = boost
        pendingHeading = null
        WebSocketClient.get(context).sendGameInput(id, """{"h":$heading,"boost":$boost}""")
    }

    /**
     * Flush a heading that arrived between sends. Called by the renderer each frame, so a
     * finger that stops moving still lands its final direction.
     */
    fun flushSteering(context: Context) {
        val heading = pendingHeading ?: return
        if (android.os.SystemClock.elapsedRealtime() - lastSteerSentAt < STEER_INTERVAL_MS) return
        steer(context, heading, lastSentBoost)
    }

    private var lastSteerSentAt = 0L
    private var lastSentBoost = false
    private var pendingHeading: Double? = null

    /**
     * Create a SOLO match — one human against server-side bots — and enter it.
     *
     * No invite and no opponent, unlike [create]. Snake is the first game whose catalog row
     * allows `min_players = 1`, which is what lets a match exist with a single seat.
     *
     * The bots run on the SERVER, so this stays a pure renderer: practice and multiplayer are
     * the same code path on both sides, and a bug in one is a bug in both rather than two
     * implementations drifting apart. That is the difference between this and the `*Bot.kt`
     * screens, which simulate turn-based opponents locally because those games have no
     * continuous state to keep in sync.
     */
    suspend fun createSolo(slug: String, options: Map<String, Int> = emptyMap()): String? {
        return runCatching {
            val id = service.create(slug, emptyList(), options)
            open(id)
            id
        }.getOrElse {
            _joinError.value = "Couldn't start the match."
            null
        }
    }

    fun leave() {
        matchId = null
        pendingHeading = null
        lastSentBoost = false
        _snake.value = null
        _snakePrevious.value = null
        _state.value = null
        _rps.value = null
        _cricket.value = null
        _joinError.value = null
        lastSeq = -1
    }
}

/**
 * SAFE JSON ACCESSORS.
 *
 * `payload["line"]?.jsonArray` looks null-safe and is not: `?.` guards a MISSING key, but the
 * server sends an explicit `null` for absent values (line, target, winnerUserId), and `.jsonArray`
 * on a JsonNull THROWS. That crashed the app the instant the first frame of an unfinished game
 * arrived — the lobby opened, the opening state landed, and the process died.
 *
 * These return null for both "missing" and "explicitly null", which is what every caller here
 * actually wants.
 */
private fun JsonObject.arr(key: String): JsonArray? = (this[key] as? JsonArray)

private fun JsonObject.prim(key: String): JsonPrimitive? =
    (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }

private fun JsonObject.str(key: String): String? = prim(key)?.contentOrNull
private fun JsonObject.int(key: String): Int? = prim(key)?.intOrNull
private fun JsonObject.bool(key: String): Boolean? = prim(key)?.booleanOrNull
private fun JsonObject.dbl(key: String): Double? = prim(key)?.doubleOrNull
