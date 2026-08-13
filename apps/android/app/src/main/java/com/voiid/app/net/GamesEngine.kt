package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
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

        // 60 ms, not the tick period. The server's per-match input limit for a continuous
        // game is tickHz x 120/min (20/s at 10 Hz), so ~16.7/s sits safely under it — and the
        // extra granularity means a direction change waits at most 60 ms to leave the device
        // instead of 100, a visible slice of total input latency.
        private const val STEER_INTERVAL_MS = 60L

        /** ~3 degrees. Below this the thumb is jittering, not turning. */
        private const val HEADING_EPSILON = 0.05

        /**
         * How many server frames the jitter buffer holds.
         *
         * Must comfortably exceed INTERP_DELAY expressed in ticks, or the renderer runs off
         * the end of the buffer and stalls — 8 frames is 800 ms of history against a 250 ms
         * render delay, so even a badly late frame still has something to interpolate toward.
         */
        private const val SNAKE_BUFFER = 8
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
        /** "toss-call" | "toss-decide" | "play". Nothing is playable until this reads "play". */
        val phase: String,
        val toss: Toss,
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

        /**
         * The toss, before ball one (backend/games/src/engine/cricket).
         *
         * A match opens here rather than in play: one seat calls the coin, and whoever wins
         * elects to bat or bowl. [coin] is NULL until the call has been made — the server
         * withholds it exactly as it withholds picks, so a client cannot read it and call
         * correctly every time.
         */
        data class Toss(
            /** Seat that holds the call. */
            val callerSeat: Int,
            /** What they called, or null before they have. */
            val called: String?,
            /** Which face landed. Null until [called] is set; revealing it earlier is the cheat. */
            val coin: String?,
            /** Seat that won the call and now elects. Null until the call resolves. */
            val wonSeat: Int?,
            /** "bat" or "bowl", once elected. */
            val choice: String?,
        )
    }

    /**
     * Authoritative Snake state (backend/games/src/engine/snake).
     *
     * THE FIRST CONTINUOUS GAME, and the first that needs more from this layer than "parse
     * and draw". The server ticks at 10 Hz, so a renderer drawing frames as they land would
     * show 10 fps of visible stepping. Frames are therefore buffered (see [snakeFrames]) and
     * the screen interpolates across them on the server's own clock (see `SnakeArenaScreen.kt`).
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
        /**
         * Deaths/kills/eats/spawns THIS frame, for one-shot VFX. Cleared server-side every
         * tick (backend/games/src/engine/snake/index.ts), so this is never a running log —
         * only what just happened.
         *
         * Was previously dropped by [parseSnake] entirely: the server has always sent this,
         * iOS has always parsed it into `SnakeState.events`, and Android discarded the field
         * on arrival — no particle/haptic system on this platform could exist without it.
         * See docs/GAMES_ANIMATION.md §5.3.
         */
        val events: List<SnakeEvent> = emptyList(),
    ) {
        /** One `{k, x, y, id, c?}` entry. `kind` is "death" | "kill" | "eat" | "spawn". */
        data class SnakeEvent(
            val kind: String,
            val x: Double,
            val y: Double,
            val snakeId: String,
            /** Death cause ("border" | "body" | "head"), present only on `death` events. */
            val cause: String?,
            /**
             * The VICTIM, present only on `kill` events — [snakeId] is already spent naming the
             * KILLER there, so without this a kill event cannot say who was eaten.
             */
            val victimId: String?,
        )

        data class Snake(
            val id: String,
            val isBot: Boolean,
            /** Server-assigned handle for a bot; null for humans (resolved from the directory). */
            val name: String?,
            /** Skin id; null draws the plain palette colour. See `SnakeSkins`. */
            val skin: String?,
            /**
             * Head radius in world units, straight from the server — the body is drawn at this
             * width so the visible snake is exactly the shape that kills.
             */
            val headRadius: Double,
            /**
             * BODY radius in world units, from the server. Distinct from [headRadius]: the
             * engine collides bodies against BODY_RADIUS, and deriving one from the other
             * client-side is exactly how the drawn body and the lethal body drifted apart.
             */
            val bodyRadius: Double,
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
            /** Dead AND past the respawn delay: the client may offer its Respawn button. */
            val canRespawn: Boolean,
            val colorIndex: Int,
        )

        data class Point(val x: Double, val y: Double)

        /** [value]: 1 = standard, 2 = corpse, 0.5 = boost drop. */
        data class Food(val id: Int, val x: Double, val y: Double, val value: Double)
    }

    /**
     * Authoritative Sea Battle state (backend/games/src/engine/seabattle,
     * docs/games/future/SEA_BATTLE.md).
     *
     * THE ONE STRUCTURALLY DIFFERENT STATE IN THIS FILE. Every other game broadcasts the same
     * bytes to everyone; Sea Battle's frame is built per recipient by `serializeForPlayer`, so
     * [myFleet] and [seat] are in YOUR frame and absent from your opponent's. That is why there
     * is no opponent-fleet field and never will be one until the match ends — the information
     * is not withheld by this parser, it never arrives.
     *
     * The corollary matters for rendering: the client cannot derive whether a shot hit. It
     * reads [results], which the server computed — the same posture [RpsState] takes by
     * refusing to model a pending throw.
     *
     * Mirrors iOS `SeaBattleState`.
     */
    data class SeaBattleState(
        val players: List<String>,
        /** "placing" | "firing" | "done". */
        val phase: String,
        /** Seat to fire, or null during placement and once finished. */
        val turn: Int?,
        val turnUserId: String?,
        /** Packed cells (`y * 10 + x`) fired, in order, indexed by the FIRING seat. */
        val shots: List<List<Int>>,
        /** Parallel to [shots]: 0 miss, 1 hit, 2 hit-and-sunk. */
        val results: List<List<Int>>,
        /** Ship type ids sunk, indexed by the seat whose fleet lost them. */
        val sunk: List<List<Int>>,
        /** Revealed outlines of those sunk ships, same indexing. */
        val sunkCells: List<List<Int>>,
        val placed: List<Boolean>,
        /** Ship lengths, from the server, so the renderer never hardcodes the fleet. */
        val fleetSpec: List<Int>,
        val deadlineAt: Double?,
        val finished: Boolean,
        val winnerUserId: String?,
        /** "win" | "resign" | "timeout" | "abandoned" — the post-match line differs for each. */
        val endedBy: String?,
        /**
         * The shot to animate on arrival. Explicit rather than diffed: a client cold-started
         * from a push has no previous frame, and for this game cold start is the normal case.
         */
        val lastShot: Int?,
        val lastResult: Int?,
        /** MY seat. Null means this frame was built for a spectator, not a player. */
        val seat: Int?,
        /** MY fleet. Never the opponent's. */
        val myFleet: List<Ship>,
        /** Both fleets, and only once the match is over. */
        val revealedFleets: List<List<Ship>>?,
    ) {
        data class Ship(val type: Int, val cells: List<Int>, val hits: Int)
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

    private val _seaBattle = MutableStateFlow<SeaBattleState?>(null)
    val seaBattle: StateFlow<SeaBattleState?> = _seaBattle.asStateFlow()

    /** One received snake frame plus when it landed, on the monotonic uptime clock. */
    data class SnakeFrame(val state: SnakeState, val arrivedAtMs: Long)

    /**
     * The last few snake frames, oldest first — a jitter buffer, not just a pair.
     *
     * Interpolating between exactly two frames timed by ARRIVAL was the stutter: WS frames do
     * not land evenly, so the renderer held at a late frame and then jumped when the next one
     * arrived. With a small buffer keyed on the SERVER's `t`, the renderer picks a render time
     * slightly in the past and interpolates between whichever pair brackets it — arrival
     * jitter is absorbed instead of displayed.
     *
     * Arrival uses elapsedRealtime rather than wall clock: a wall clock can jump mid-match.
     */
    private val _snakeFrames = MutableStateFlow<List<SnakeFrame>>(emptyList())
    val snakeFrames: StateFlow<List<SnakeFrame>> = _snakeFrames.asStateFlow()

    /** Latest snake state, for HUD/overlay code with no need to interpolate. */
    val snake: SnakeState? get() = _snakeFrames.value.lastOrNull()?.state

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
            "seabattle" -> _seaBattle.value = parseSeaBattle(payload)
            "snake" -> {
                // Parse against the NEWEST frame, because food deltas are relative to it,
                // then append to the jitter buffer the renderer interpolates across.
                val next = parseSnake(payload, snake) ?: return
                val frame = SnakeFrame(next, android.os.SystemClock.elapsedRealtime())
                _snakeFrames.value = (_snakeFrames.value + frame).takeLast(SNAKE_BUFFER)
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
            // The name rides only on FULL frames (it never changes), so a delta frame
            // inherits it from the previous state. Without this every label would blink out
            // the moment the first delta arrived.
            val carried = previous?.snakes?.firstOrNull { it.id == id }?.name
            SnakeState.Snake(
                id = id,
                isBot = o.bool("bot") ?: false,
                name = o.str("n") ?: carried,
                // Skin rides full frames only, like the name, so a delta frame inherits it.
                skin = o.str("sk") ?: previous?.snakes?.firstOrNull { it.id == id }?.skin,
                headRadius = o.dbl("hr") ?: 11.0,
                bodyRadius = o.dbl("br") ?: 10.0,
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
                canRespawn = o.bool("cr") ?: false,
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

        val events = payload.arr("events")?.mapNotNull { entry ->
            val o = entry as? JsonObject ?: return@mapNotNull null
            val kind = o.str("k") ?: return@mapNotNull null
            val id = o.str("id") ?: return@mapNotNull null
            SnakeState.SnakeEvent(
                kind = kind,
                x = o.dbl("x") ?: 0.0,
                y = o.dbl("y") ?: 0.0,
                snakeId = id,
                cause = o.str("c"),
                victimId = o.str("v"),
            )
        } ?: emptyList()

        return SnakeState(
            players = players,
            snakes = snakes,
            food = food.values.toList(),
            time = payload.dbl("t") ?: 0.0,
            arenaRadius = payload.dbl("arenaRadius") ?: 1400.0,
            duration = payload.dbl("duration") ?: 180.0,
            finished = payload.bool("finished") ?: false,
            winnerUserId = payload.str("winnerUserId"),
            events = events,
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
        val tossObj = payload["toss"] as? JsonObject
        return CricketState(
            players = players,
            overs = payload.int("overs") ?: 2,
            // Defaults to "play" so a match created before the toss shipped still renders —
            // the server makes the same assumption on restore.
            phase = payload.str("phase") ?: "play",
            toss = CricketState.Toss(
                callerSeat = tossObj?.int("callerSeat") ?: 0,
                called = tossObj?.str("called"),
                coin = tossObj?.str("coin"),
                wonSeat = tossObj?.int("wonSeat"),
                choice = tossObj?.str("choice"),
            ),
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

    private fun parseSeaBattle(payload: JsonObject): SeaBattleState? {
        val players = payload.arr("players")?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?: return null

        // Nested int arrays, one per seat. Defaulted to two empty lists rather than null so the
        // renderer can index by seat without guarding every access — an opening frame has these
        // empty, which is a real state rather than a missing one.
        fun intGrid(key: String): List<List<Int>> =
            payload.arr(key)?.map { row ->
                (row as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull } ?: emptyList()
            } ?: listOf(emptyList(), emptyList())

        fun ships(raw: JsonArray?): List<SeaBattleState.Ship> =
            raw?.mapNotNull { entry ->
                val obj = entry as? JsonObject ?: return@mapNotNull null
                val type = obj.int("type") ?: return@mapNotNull null
                val cells = obj.arr("cells")?.mapNotNull { (it as? JsonPrimitive)?.intOrNull }
                    ?: return@mapNotNull null
                SeaBattleState.Ship(type, cells, obj.int("hits") ?: 0)
            } ?: emptyList()

        return SeaBattleState(
            players = players,
            phase = payload.str("phase") ?: "placing",
            turn = payload.int("turn"),
            turnUserId = payload.str("turnUserId"),
            shots = intGrid("shots"),
            results = intGrid("results"),
            sunk = intGrid("sunk"),
            sunkCells = intGrid("sunkCells"),
            placed = payload.arr("placed")?.map {
                (it as? JsonPrimitive)?.booleanOrNull ?: false
            } ?: listOf(false, false),
            fleetSpec = payload.arr("fleetSpec")?.mapNotNull {
                (it as? JsonPrimitive)?.intOrNull
            } ?: listOf(5, 4, 3, 3, 2),
            deadlineAt = payload.dbl("deadlineAt"),
            finished = payload.bool("finished") ?: false,
            winnerUserId = payload.str("winnerUserId"),
            endedBy = payload.str("endedBy"),
            lastShot = payload.int("lastShot"),
            lastResult = payload.int("lastResult"),
            seat = payload.int("seat"),
            myFleet = ships(payload.arr("myFleet")),
            revealedFleets = payload.arr("revealedFleets")?.map { ships(it as? JsonArray) },
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
        _seaBattle.value = null
        _snakeFrames.value = emptyList()
        desiredHeading = null
        desiredBoost = false
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
        /**
         * Snake's chosen skin id. Travels separately because [options] is string->int. A friend
         * match sent none until duels — so a player who had picked a skin got the default snake
         * in the only mode anybody else could see it.
         */
        skin: String? = null,
    ): String? {
        return runCatching {
            android.util.Log.i(TAG, "create: slug=$slug peer=$opponentId convo=$conversationId opts=$options")
            val id = service.create(slug, listOf(opponentId), options, skin)
            android.util.Log.i(TAG, "create: match minted id=$id — sending invite")
            // Everything the poster bubble and the rich notification need travels INSIDE the
            // encrypted body — which is what lets the recipient's banner name the game while the
            // push that woke their device said only "New message".
            val meta = GameInvite.Meta(
                game = gameName,
                // "Unknown" is the directory's INTERNAL sentinel for "no row", not a name — and on
                // a fresh install our own row isn't written until the first profile fetch lands,
                // so an invite sent before then would literally read "🎮 Unknown invited you to…".
                // Collapsing it to empty lets GameInvite.encode's existing blank-guard say
                // "Someone", which is what the sender meant.
                from = myUserId
                    ?.let { com.voiid.app.store.UserDirectory.displayName(it, "") }
                    ?.takeIf { it != "Unknown" }
                    .orEmpty(),
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
     * Call the toss. [side] is "heads" or "tails".
     *
     * Fire-and-forget like every other input here. The server refuses a call from the seat that
     * does not hold it, so this does not police whose turn it is — it only avoids sending a
     * frame we already know is pointless.
     */
    fun callToss(context: Context, side: String) {
        val id = matchId ?: return
        val s = _cricket.value ?: return
        if (s.finished) return
        WebSocketClient.get(context).sendGameInput(id, """{"call":"$side"}""")
    }

    /** Elect to bat or bowl after winning the toss. [choice] is "bat" or "bowl". */
    fun electToss(context: Context, choice: String) {
        val id = matchId ?: return
        val s = _cricket.value ?: return
        if (s.finished) return
        WebSocketClient.get(context).sendGameInput(id, """{"elect":"$choice"}""")
    }

    /**
     * Commit a whole Sea Battle fleet. Five ships, one frame.
     *
     * ATOMIC BY DESIGN, and the client must not "helpfully" send ships one at a time: the
     * server treats a half-placed fleet as no fleet, so per-ship frames would leave a state
     * legal to nobody and let a client stall having placed four. The fleet is legal in full or
     * rejected in full (SEA_BATTLE.md §4.7).
     */
    fun placeFleet(context: Context, ships: List<SeaBattleState.Ship>) {
        val id = matchId ?: return
        val s = _seaBattle.value ?: return
        if (s.finished) return
        val body = ships.joinToString(",") { ship ->
            """{"type":${ship.type},"cells":[${ship.cells.joinToString(",")}]}"""
        }
        WebSocketClient.get(context).sendGameInput(id, """{"place":[$body]}""")
    }

    /**
     * Fire at one packed cell (0–99).
     *
     * Fire-and-forget like every other input. The client does NOT predict the outcome — it
     * starts the shell animation and the arriving frame decides what that resolves into
     * (SEA_BATTLE.md §3.3). Predicting a hit would be predicting authority.
     */
    fun fire(context: Context, cell: Int) {
        val id = matchId ?: return
        val s = _seaBattle.value ?: return
        if (s.finished) return
        WebSocketClient.get(context).sendGameInput(id, """{"fire":$cell}""")
    }

    /** Resign. A result, not an abandonment — it counts as a loss (SEA_BATTLE.md §13.4). */
    fun resignSeaBattle(context: Context) {
        val id = matchId ?: return
        val s = _seaBattle.value ?: return
        if (s.finished) return
        WebSocketClient.get(context).sendGameInput(id, """{"resign":true}""")
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
        // Record the intent unconditionally. Whether it goes on the wire is decided by the
        // pacer below, never here — a control the player is actively holding must not be
        // able to fall out of the loop.
        desiredHeading = heading
        desiredBoost = boost
        if (boost != lastSentBoost) flush(context)
    }

    /**
     * Send the current desired heading, at most once per interval.
     *
     * NO "has it moved enough" TEST. An earlier version skipped sends when the new heading
     * was within a few degrees of a reference, and every variant of that idea was broken:
     *
     *  - against the last SENT heading, a respawn (which resets the snake's heading server
     *    side) left the client convinced it had nothing to say;
     *  - against the SERVER's heading it was worse, because the snake is continuously
     *    turning TOWARD the desired heading, so the two converge by design — sends stopped
     *    the moment the turn completed, and any later drift was never corrected.
     *
     * Both produced the same symptom: steering works, then silently stops forever. A
     * continuous control is cheap to resend and catastrophic to under-send, so it is simply
     * paced at a fixed rate while a finger is down and while the heading differs at all.
     */
    fun flush(context: Context) {
        val id = matchId ?: return
        val s = snake ?: return
        if (s.finished) return

        // A DEAD SNAKE IS NOT STEERABLE, and pretending otherwise starved the one frame that
        // mattered. Nothing paused this pacer on death, so the client kept sending headings at
        // 10-15/s at a snake that was not in the arena — straight into the same per-match input
        // budget the respawn frame has to come out of. By the time the 2.5 s delay elapsed and
        // the button became tappable, the budget was reliably gone and Respawn did nothing.
        val mine = s.snakes.firstOrNull { it.id == myUserId }
        if (mine != null && !mine.alive) return

        val h = desiredHeading ?: return
        val now = android.os.SystemClock.elapsedRealtime()
        val boostChanged = desiredBoost != lastSentBoost
        if (!boostChanged && now - lastSteerSentAt < STEER_INTERVAL_MS) return

        lastSteerSentAt = now
        lastSentBoost = desiredBoost
        WebSocketClient.get(context).sendGameInput(id, """{"h":$h,"boost":$desiredBoost}""")
    }

    /**
     * Flush a heading that arrived between sends. Called by the renderer each frame, so a
     * finger that stops moving still lands its final direction.
     */
    fun flushSteering(context: Context) = flush(context)

    /**
     * The finger left the stick. Stop resending, but do NOT send a final heading — the snake
     * keeps whatever direction it had, which is what the genre expects and what the server
     * already does.
     */
    fun releaseSteering() {
        desiredHeading = null
    }

    /** Ask the server to put a dead snake back in. Ignored until the delay has elapsed. */
    fun requestRespawn(context: Context) {
        val id = matchId ?: return
        WebSocketClient.get(context).sendGameInput(id, """{"respawn":true}""")
    }

    private var lastSteerSentAt = 0L
    private var lastSentBoost = false
    /** What the player is asking for right now; resent on a fixed cadence while set. */
    private var desiredHeading: Double? = null
    private var desiredBoost = false

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
    suspend fun createSolo(
        slug: String,
        options: Map<String, Int> = emptyMap(),
        skin: String? = null,
    ): String? {
        return runCatching {
            val id = service.create(slug, emptyList(), options, skin)
            open(id)
            id
        }.getOrElse {
            _joinError.value = "Couldn't start the match."
            null
        }
    }

    fun leave() {
        // Tell the server BEFORE clearing local state, not after — matchId is null the moment
        // this function returns. Fire-and-forget on its own IO scope: local state clears
        // unconditionally below regardless of whether this network call lands, matching
        // GroupCallService's identical fire-and-forget pattern elsewhere in this package. See
        // GamesService.leave's doc comment for what this fixes (an abandoned Snake match
        // ticking, and flooding this socket with game_state, for up to its full duration with
        // nobody watching).
        matchId?.let { id ->
            CoroutineScope(Dispatchers.IO).launch {
                runCatching { service.leave(id) }
            }
        }

        matchId = null
        desiredHeading = null
        desiredBoost = false
        lastSentBoost = false
        _snakeFrames.value = emptyList()
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
