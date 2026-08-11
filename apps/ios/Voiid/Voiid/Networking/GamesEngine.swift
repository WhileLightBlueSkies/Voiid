//
//  GamesEngine.swift
//  Voiid
//
//  Client half of the games system (docs/GAMES.md §4). Mirrors LocationShareEngine's
//  shape: owns the WS subscription for game frames, exposes the current match as an
//  observable, and turns local taps into `game_input` frames on the socket the app
//  already holds open for chat.
//
//  THE RULE FOR EVERY GAME SCREEN: this client is a renderer, not a referee. It never
//  decides whose turn it is, whether a move is legal, or who won — it draws whatever
//  `state` currently holds and sends taps. Optimistic local updates are deliberately
//  ABSENT: predicting the board then correcting it on the server frame is how you get
//  pieces that flicker and un-place themselves. A move round-trip is a few tens of
//  milliseconds on the existing socket, which is well under the threshold where a tap
//  feels laggy for a turn-based game.
//
//  TRANSPORT SPLIT (same shape as location):
//    match lifecycle (create/join/history) → REST, durable, authorized once
//    moves + state                         → WS relay only, ephemeral, never persisted here
//
//  NOT ENCRYPTED, AND WHY: game payloads are readable by the server, unlike messages. The
//  server referees, so it must read moves. The INVITE is still an ordinary E2EE message.
//

import Foundation
import Combine
// CGPoint for decoded body points, and CACurrentMediaTime for the interpolation clock —
// monotonic, unlike Date(), so it cannot jump when the system clock is adjusted mid-match.
import CoreGraphics
import QuartzCore

extension Notification.Name {
    static let voiidGameState = Notification.Name("voiidGameState")
    /// Join tapped on a game-invite bubble in a chat. userInfo: match_id, slug.
    ///
    /// The board lives in the Games tab's navigation stack, and the bubble is several layers
    /// deep in a different tab, so this crosses that gap the same way the group-call and
    /// story deep links do.
    static let voiidOpenGameMatch = Notification.Name("voiidOpenGameMatch")
}

/// Authoritative Tic Tac Toe state as broadcast by backend/games.
struct TicTacToeState {
    /// Seat order — index doubles as the mark (0 = X, 1 = O).
    let players: [String]
    /// 9 cells, row-major. Each is the seat index that owns it, or nil.
    let board: [Int?]
    /// Nil once the match is over.
    let turnUserId: String?
    let finished: Bool
    let winnerUserId: String?
    /// Winning triple, so the view highlights it without re-deriving the win.
    let line: [Int]?

    static func parse(_ payload: [String: Any]) -> TicTacToeState? {
        guard let players = payload["players"] as? [String],
              let rawBoard = payload["board"] as? [Any] else { return nil }
        let board: [Int?] = rawBoard.map { $0 as? Int }
        return TicTacToeState(
            players: players,
            board: board,
            turnUserId: payload["turnUserId"] as? String,
            finished: (payload["finished"] as? Bool) ?? false,
            winnerUserId: payload["winnerUserId"] as? String,
            line: payload["line"] as? [Int])
    }
}

/// Authoritative Rock Paper Scissors state (backend/games/src/engine/rps).
///
/// NOTE WHAT IS ABSENT: the opponent's pending throw. While a round is open the server sends
/// only `hasThrown` — booleans, never the choices — because RPS is simultaneous and leaking
/// the first throw would let whoever moves second win every time. The view therefore CANNOT
/// render the opponent's hand mid-round, by design: there is nothing to render. Resolved
/// rounds arrive in `history`, where both throws are safe to show.
struct RpsState {
    /// One resolved round: both throws, and who took it.
    struct Round {
        /// "rock" | "paper" | "scissors", by seat.
        let `throws`: [String]
        /// Seat that won, or nil for a tie.
        let winner: Int?
    }

    let players: [String]
    /// Rounds needed to take the match (server default 3).
    let target: Int
    /// Rounds won, by seat.
    let wins: [Int]
    /// Whether each seat has thrown THIS round. Never what they threw.
    let hasThrown: [Bool]
    /// Resolved rounds, oldest first.
    let history: [Round]
    let finished: Bool
    let winnerUserId: String?

    static func parse(_ payload: [String: Any]) -> RpsState? {
        guard let players = payload["players"] as? [String] else { return nil }
        let rounds = (payload["history"] as? [[String: Any]] ?? []).compactMap { entry -> Round? in
            guard let picks = entry["throws"] as? [String] else { return nil }
            return Round(throws: picks, winner: entry["winner"] as? Int)
        }
        return RpsState(
            players: players,
            target: (payload["target"] as? Int) ?? 3,
            wins: (payload["wins"] as? [Int]) ?? [0, 0],
            hasThrown: (payload["hasThrown"] as? [Bool]) ?? [false, false],
            history: rounds,
            finished: (payload["finished"] as? Bool) ?? false,
            winnerUserId: payload["winnerUserId"] as? String)
    }
}

/// Authoritative Hand Cricket state (docs/GAMES_HAND_CRICKET.md).
///
/// Same anti-cheat shape as `RpsState`: `hasPicked` is booleans, never the picks. A pick is
/// revealed only once the ball has resolved, in `history`.
struct CricketState {
    /// The toss, before ball one (backend/games/src/engine/cricket).
    ///
    /// A match opens here rather than in play: one seat calls the coin, and whoever wins
    /// elects to bat or bowl. `coin` is NIL until the call has been made — the server
    /// withholds it exactly as it withholds picks, so a client cannot read it and call
    /// correctly every time.
    struct Toss {
        /// Seat that holds the call.
        let callerSeat: Int
        /// What they called, or nil before they have.
        let called: String?
        /// Which face landed. Nil until `called` is set; revealing it earlier would be the
        /// whole cheat.
        let coin: String?
        /// Seat that won the call and now elects. Nil until the call resolves.
        let wonSeat: Int?
        /// "bat" or "bowl", once elected.
        let choice: String?
    }

    /// One resolved ball. Both picks are safe here — the ball is already scored.
    struct Ball {
        let picks: [Int]
        let battingSeat: Int
        let innings: Int
        let runs: Int
        let wicket: Bool
    }

    let players: [String]
    let overs: Int
    /// "toss-call" | "toss-decide" | "play". Nothing is playable until this reads "play".
    let phase: String
    let toss: Toss
    let innings: Int
    /// Seat batting RIGHT NOW. Swaps between innings.
    let battingSeat: Int
    let scores: [Int]
    let wickets: [Int]
    let ballsBowled: Int
    /// `overs * 6`, sent by the server so the client needn't know the balls-per-over rule.
    let ballsTotal: Int
    let wicketsPerInnings: Int
    /// Runs the chasing side needs to WIN. Nil during the first innings.
    let target: Int?
    let hasPicked: [Bool]
    let history: [Ball]
    let finished: Bool
    let winnerUserId: String?

    static func parse(_ payload: [String: Any]) -> CricketState? {
        guard let players = payload["players"] as? [String] else { return nil }
        let balls = (payload["history"] as? [[String: Any]] ?? []).compactMap { entry -> Ball? in
            guard let picks = entry["picks"] as? [Int] else { return nil }
            return Ball(
                picks: picks,
                battingSeat: (entry["battingSeat"] as? Int) ?? 0,
                innings: (entry["innings"] as? Int) ?? 1,
                runs: (entry["runs"] as? Int) ?? 0,
                wicket: (entry["wicket"] as? Bool) ?? false)
        }
        let tossRaw = payload["toss"] as? [String: Any] ?? [:]
        return CricketState(
            players: players,
            overs: (payload["overs"] as? Int) ?? 2,
            // Defaults to "play" so a match created before the toss shipped still renders —
            // the server makes the same assumption on restore.
            phase: (payload["phase"] as? String) ?? "play",
            toss: Toss(
                callerSeat: (tossRaw["callerSeat"] as? Int) ?? 0,
                called: tossRaw["called"] as? String,
                coin: tossRaw["coin"] as? String,
                wonSeat: tossRaw["wonSeat"] as? Int,
                choice: tossRaw["choice"] as? String),
            innings: (payload["innings"] as? Int) ?? 1,
            battingSeat: (payload["battingSeat"] as? Int) ?? 0,
            scores: (payload["scores"] as? [Int]) ?? [0, 0],
            wickets: (payload["wickets"] as? [Int]) ?? [0, 0],
            ballsBowled: (payload["ballsBowled"] as? Int) ?? 0,
            ballsTotal: (payload["ballsTotal"] as? Int) ?? 12,
            wicketsPerInnings: (payload["wicketsPerInnings"] as? Int) ?? 2,
            target: payload["target"] as? Int,
            hasPicked: (payload["hasPicked"] as? [Bool]) ?? [false, false],
            history: balls,
            finished: (payload["finished"] as? Bool) ?? false,
            winnerUserId: payload["winnerUserId"] as? String)
    }
}

/// Authoritative Snake state (backend/games/src/engine/snake).
///
/// THE FIRST CONTINUOUS GAME, and the first that needs more from this layer than "parse and
/// draw". The server ticks at 10 Hz, so a renderer that drew frames as they landed would show
/// 10 fps of visible stepping. `SnakeSnapshot` therefore keeps the PREVIOUS frame alongside
/// the current one, and the view interpolates between them (see `SnakeArenaView`).
///
/// That is interpolation, not prediction — it draws only positions the server has already
/// confirmed, just slightly in the past. It cannot invent a position the server never sent,
/// so the no-optimistic-updates rule at the top of this file still holds.
struct SnakeState {
    struct Snake: Identifiable {
        let id: String
        let isBot: Bool
        /// Server-assigned handle for a bot; nil for humans (resolved from the directory).
        let name: String?
        /// Skin id; nil draws the plain palette colour. See `SnakeSkins`.
        let skin: String?
        /// Head radius in world units, straight from the server — the head is drawn at this
        /// width so the visible head is exactly the shape that kills.
        let headRadius: Double
        /// BODY radius in world units, also from the server. Distinct from `headRadius`: the
        /// engine collides bodies against `BODY_RADIUS`, and deriving one from the other
        /// client-side is exactly how the drawn body and the lethal body drifted apart.
        let bodyRadius: Double
        let x: Double
        let y: Double
        let heading: Double
        let mass: Double
        let alive: Bool
        let boosting: Bool
        /// Absolute body points, head first, already decoded from the wire's delta form.
        let path: [CGPoint]
        let kills: Int
        let deaths: Int
        let score: Int
        let invulnUntil: Double
        /// Dead AND past the respawn delay: the client may offer its Respawn button.
        let canRespawn: Bool
        let colorIndex: Int
    }

    /// What to show above the head and in the leaderboard.
    ///
    /// Bots carry their name on the wire; humans are looked up locally, because only this
    /// device knows what it calls its own contacts.
    static func label(for snake: Snake, me: String?) -> String {
        if snake.id == me { return "You" }
        if let n = snake.name, !n.isEmpty { return n }
        return UserDirectory.shared.displayName(snake.id, fallback: "Player")
    }

    struct Food {
        let id: Int
        let position: CGPoint
        /// 1 = standard, 2 = corpse, 0.5 = boost drop.
        let value: Double
    }

    /// One `{k, x, y, id, c?}` entry from the server's per-tick event list.
    ///
    /// TYPED, where the raw `[[String: Any]]` this replaced was not — this was the untyped
    /// dictionary array before the particle/haptic work in GAMES_ANIMATION.md §5.3 needed to
    /// actually consume it. Kept as a nested type here rather than promoted to a top-level
    /// struct because it has no meaning outside a SnakeState frame.
    struct Event {
        /// "death" | "kill" | "eat" | "spawn".
        let kind: String
        let position: CGPoint
        let snakeId: String
        /// Death cause ("border" | "body" | "head"), present only on `death` events.
        let cause: String?
        /// The VICTIM, present only on `kill` events — `snakeId` is already spent naming the
        /// KILLER there, so without this a kill event cannot say who was eaten.
        let victimId: String?
    }

    let players: [String]
    let snakes: [Snake]
    let food: [Food]
    let time: Double
    let arenaRadius: Double
    let duration: Double
    let finished: Bool
    let winnerUserId: String?
    /// Deaths/kills/eats/spawns THIS frame, for one-shot effects. Cleared server-side every
    /// tick (backend/games/src/engine/snake/index.ts), so this is never a running log — only
    /// what just happened between the previous frame and this one.
    let events: [Event]

    /// Decode one snake's body.
    ///
    /// The wire form is `[headX, headY, dx, dy, dx, dy, ...]` in `pathStep` units — absolute
    /// coordinates only for the head, deltas thereafter, because consecutive body points are
    /// a few units apart and their deltas are far shorter to encode. Long snakes are also
    /// decimated past the head, which needs no handling here: a halved segment is simply a
    /// longer delta, and the curve through the points is the same shape.
    private static func decodePath(_ raw: [Double], step: Double) -> [CGPoint] {
        guard raw.count >= 2 else { return [] }
        var points: [CGPoint] = [CGPoint(x: raw[0], y: raw[1])]
        var x = raw[0], y = raw[1]
        var i = 2
        while i + 1 < raw.count {
            x += raw[i] * step
            y += raw[i + 1] * step
            points.append(CGPoint(x: x, y: y))
            i += 2
        }
        return points
    }

    /// Parse a frame. `previous` supplies the food field when this frame carries only a delta.
    static func parse(_ payload: [String: Any], previous: SnakeState?) -> SnakeState? {
        guard let players = payload["players"] as? [String],
              let rawSnakes = payload["snakes"] as? [[String: Any]] else { return nil }

        let step = (payload["pathStep"] as? Double) ?? 1

        let snakes: [Snake] = rawSnakes.compactMap { s in
            guard let id = s["id"] as? String else { return nil }
            // The name rides only on FULL frames (it never changes), so a delta frame
            // inherits it from the previous state. Without this, every label would blink
            // out the moment the first delta arrived.
            let carried = previous?.snakes.first { $0.id == id }?.name
            return Snake(
                id: id,
                isBot: (s["bot"] as? Bool) ?? false,
                name: (s["n"] as? String) ?? carried,
                // Skin rides full frames only, like the name, so a delta inherits it.
                skin: (s["sk"] as? String)
                    ?? previous?.snakes.first { $0.id == id }?.skin,
                headRadius: (s["hr"] as? Double) ?? 11,
                bodyRadius: (s["br"] as? Double) ?? 10,
                x: (s["x"] as? Double) ?? 0,
                y: (s["y"] as? Double) ?? 0,
                heading: (s["h"] as? Double) ?? 0,
                mass: (s["m"] as? Double) ?? 0,
                alive: (s["a"] as? Bool) ?? false,
                boosting: (s["b"] as? Bool) ?? false,
                path: decodePath((s["p"] as? [Double]) ?? [], step: step),
                kills: (s["k"] as? Int) ?? 0,
                deaths: (s["d"] as? Int) ?? 0,
                score: (s["s"] as? Int) ?? 0,
                invulnUntil: (s["iv"] as? Double) ?? 0,
                canRespawn: (s["cr"] as? Bool) ?? false,
                colorIndex: (s["c"] as? Int) ?? 0)
        }

        // Food arrives as a full snapshot or as add/remove deltas. Rebuilding from the
        // previous frame is what keeps this off the wire 90% of the time.
        var food: [Int: Food] = [:]
        if (payload["foodFull"] as? Bool) ?? true {
            for entry in (payload["food"] as? [[Double]] ?? []) where entry.count >= 4 {
                let id = Int(entry[3])
                food[id] = Food(id: id, position: CGPoint(x: entry[0], y: entry[1]), value: entry[2])
            }
        } else {
            for f in previous?.food ?? [] { food[f.id] = f }
            for entry in (payload["foodAdd"] as? [[Double]] ?? []) where entry.count >= 4 {
                let id = Int(entry[3])
                food[id] = Food(id: id, position: CGPoint(x: entry[0], y: entry[1]), value: entry[2])
            }
            for id in (payload["foodDel"] as? [Int] ?? []) { food.removeValue(forKey: id) }
        }

        let events: [Event] = ((payload["events"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let kind = e["k"] as? String, let id = e["id"] as? String else { return nil }
            return Event(kind: kind,
                        position: CGPoint(x: e["x"] as? Double ?? 0, y: e["y"] as? Double ?? 0),
                        snakeId: id, cause: e["c"] as? String,
                        victimId: e["v"] as? String)
        }

        return SnakeState(
            players: players,
            snakes: snakes,
            food: Array(food.values),
            time: (payload["t"] as? Double) ?? 0,
            arenaRadius: (payload["arenaRadius"] as? Double) ?? 1400,
            duration: (payload["duration"] as? Double) ?? 180,
            finished: (payload["finished"] as? Bool) ?? false,
            winnerUserId: payload["winnerUserId"] as? String,
            events: events)
    }
}

@MainActor
final class GamesEngine: ObservableObject {
    static let shared = GamesEngine()

    /// The match this device is currently showing, if any.
    @Published private(set) var matchId: String?
    @Published private(set) var state: TicTacToeState?
    /// RPS and cricket state, for their renderers.
    ///
    /// SEPARATE published properties rather than one enum: each screen renders exactly one
    /// game and would have to unwrap an enum on every frame anyway, and a mismatched case is
    /// a crash where an unused nil is inert.
    @Published private(set) var rps: RpsState?
    @Published private(set) var cricket: CricketState?
    /// One received snake frame plus when it landed, on the monotonic host clock.
    struct SnakeFrame {
        let state: SnakeState
        let arrivedAt: TimeInterval
    }

    /// The last few snake frames, oldest first — a jitter buffer, not just a pair.
    ///
    /// Interpolating between exactly two frames timed by ARRIVAL was the stutter: WS frames
    /// do not land evenly, so the renderer held at a late frame and then jumped when the next
    /// one arrived. With a small buffer keyed on the SERVER's `t`, the renderer picks a
    /// render time slightly in the past and interpolates between whichever pair brackets it —
    /// arrival jitter is absorbed instead of displayed.
    ///
    /// Arrival times use the monotonic clock, deliberately not the server's `t` alone — the
    /// two clocks differ by an unknown offset, and only the local one paces drawing.
    @Published private(set) var snakeFrames: [SnakeFrame] = []

    /// Latest snake state, for HUD/overlay code that has no need to interpolate.
    var snake: SnakeState? { snakeFrames.last?.state }

    /// Plain (non-published) read of the frame buffer, for the Metal renderer.
    ///
    /// The renderer runs on the display link, not on the main actor's render pass, and must
    /// not participate in SwiftUI invalidation — reading the @Published array from there is
    /// what tangled the previous Canvas version into a freeze.
    ///
    /// LOCK-PROTECTED, not the bare `nonisolated(unsafe)` var this used to be. That comment
    /// claimed "this is a value-type copy of an array of structs, so the read is safe and
    /// cheap" — value semantics do NOT make the assignment atomic. `Array` is a struct
    /// wrapping a reference to a heap buffer; writing it from the main actor (`ingest`, below)
    /// while the display-link thread reads it concurrently is a genuine data race — undefined
    /// behaviour, not a performance nit. On device this reproduced as the Metal renderer
    /// silently drawing NOTHING: `buildFrame()` read an empty (or torn) array forever even
    /// though `game_state` frames were provably arriving (the SwiftUI leaderboard, driven by
    /// the separate `@Published snakeFrames` above, updated correctly the whole time). No
    /// crash, no log — exactly the shape a torn read produces.
    // `nonisolated` (not `nonisolated(unsafe)`) is correct and safe here specifically BECAUSE
    // the lock makes every access thread-safe regardless of which actor calls in — that is
    // the whole contract `nonisolated` is asking the compiler to trust, and unlike the old
    // `(unsafe)` variant, this one actually earns it.
    private nonisolated let snakeFramesLock = NSLock()
    private nonisolated(unsafe) var _snakeFramesSnapshot: [SnakeFrame] = []
    nonisolated var snakeFramesSnapshot: [SnakeFrame] {
        get { snakeFramesLock.withLock { _snakeFramesSnapshot } }
        set { snakeFramesLock.withLock { _snakeFramesSnapshot = newValue } }
    }

    private static let SNAKE_BUFFER = 8
    /// Set when the join REST call fails, so the screen can show something truthful
    /// instead of an empty board that will never update.
    @Published private(set) var joinError: String?

    /// Last seq applied. Frames are dropped if they arrive out of order — the same
    /// defensive posture as the offline-buffer/flush pattern elsewhere. WS is TCP so this
    /// is rare, but a late frame would otherwise resurrect a stale board.
    private var lastSeq: Int = -1
    private var observer: NSObjectProtocol?
    private let api = GamesAPI()

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .voiidGameState, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in self.ingest(note.userInfo ?? [:]) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func ingest(_ info: [AnyHashable: Any]) {
        guard let mid = info["match_id"] as? String,
              // A frame for a match this screen isn't showing is not ours to render.
              mid == matchId,
              let payload = info["payload"] as? [String: Any] else { return }
        let seq = (info["seq"] as? Int) ?? 0
        guard seq >= lastSeq else { return }
        lastSeq = seq
        // Dispatch on the game the SERVER named, not on anything the client remembered: the
        // frame is the authority on what it contains.
        switch info["game"] as? String {
        case "rps":     rps = RpsState.parse(payload)
        case "cricket": cricket = CricketState.parse(payload)
        case "snake":
            // Parse against the NEWEST frame, because food deltas are relative to it, then
            // append to the jitter buffer the renderer interpolates across.
            guard let next = SnakeState.parse(payload, previous: snake) else { return }
            snakeFrames.append(SnakeFrame(state: next, arrivedAt: CACurrentMediaTime()))
            if snakeFrames.count > Self.SNAKE_BUFFER {
                snakeFrames.removeFirst(snakeFrames.count - Self.SNAKE_BUFFER)
            }
            snakeFramesSnapshot = snakeFrames
        default:        state = TicTacToeState.parse(payload)
        }
    }

    /// Enter a match. The opening board arrives as a `game_state` frame, not in this
    /// response — the server builds it, which is why there is nothing to render until the
    /// frame lands (wake-then-fetch, same as Stories).
    func open(matchId: String) async {
        self.matchId = matchId
        self.state = nil
        self.rps = nil
        self.cricket = nil
        self.snakeFrames = []
        self.snakeFramesSnapshot = []
        self.joinError = nil
        self.lastSeq = -1
        self.desiredHeading = nil
        self.desiredBoost = false
        self.lastSentBoost = false
        do {
            try await api.join(matchId: matchId)
        } catch {
            joinError = "Couldn't join this match."
        }
    }

    /// Create a match against one opponent, TELL THEM, and enter it. Returns the id, or nil
    /// on failure.
    ///
    /// THE INVITE IS THE POINT. `POST /games/matches` deliberately sends no notification of
    /// its own (see routes/games.ts) — it only mints the row. Without the ChatEngine send
    /// below, the opponent is a player in a match they are never told about, and the creator
    /// stares at a board nobody can join. That was the bug: the match existed, the invite
    /// never did.
    ///
    /// The invite goes out BEFORE the board opens so a failure to reach the peer surfaces as
    /// an error instead of a board that will never get a second player. It travels as an
    /// ordinary E2EE text message (`GameInvite`) so wake, push and offline retry are the ones
    /// the message pipe already gets right.
    ///
    /// `options` carries per-game settings chosen before the match exists (hand cricket's
    /// over count). Stored on the match row; the engine validates it.
    func create(
        slug: String,
        opponentId: String,
        conversationId: String,
        gameName: String,
        options: [String: Int] = [:]
    ) async -> String? {
        do {
            let id = try await api.create(
                slug: slug, opponentIds: [opponentId], options: options)
            // Everything the poster bubble and the rich notification need travels INSIDE the
            // encrypted body — which is what lets the recipient's banner name the game while the
            // push that woke their device said only "New message".
            // "Unknown" is the directory's sentinel for "no row", not a name — and an empty
            // fallback can't suppress it, because the resolver rejects an empty fallback and
            // returns the sentinel instead. Left as-is it ships inside the invite and the peer
            // reads "🎮 Unknown invited you to Tic Tac Toe". Mapping it back to "" hands the
            // encoder the empty string its own guard is already waiting for, which reads
            // "Someone". The window is a fresh install that invites before the first profile
            // fetch has written the own-row.
            let ownName = TokenStore.shared.userId
                .map { UserDirectory.shared.displayName($0, fallback: "") } ?? ""
            let meta = GameInvite.Meta(
                game: gameName,
                from: ownName == "Unknown" ? "" : ownName,
                overs: options["overs"] ?? 0,
                format: slug == "rps" ? "first to 3" : "",
                sentAt: GameInvite.nowMs())
            _ = try await ChatEngine.shared.sendText(
                GameInvite.encode(slug: slug, matchId: id, meta: meta),
                conversationId: conversationId,
                peerUserId: opponentId)
            await open(matchId: id)
            return id
        } catch {
            joinError = "Couldn't send the invite."
            return nil
        }
    }

    /// Tap a cell. Fire-and-forget by design: the board changes when the SERVER says it
    /// changed. An illegal tap is simply ignored server-side and no frame comes back.
    func play(cell: Int) {
        guard let matchId, let state, !state.finished else { return }
        WebSocketClient.shared.sendGameInput(matchId: matchId, payload: ["cell": cell])
    }

    /// Throw for this RPS round. `choice` is "rock" | "paper" | "scissors".
    ///
    /// Fire-and-forget like `play`: the round resolves when the SERVER says both throws are
    /// in. A second throw in the same round is rejected server-side, so this doesn't police it.
    func throwRps(_ choice: String) {
        guard let matchId, let rps, !rps.finished else { return }
        WebSocketClient.shared.sendGameInput(matchId: matchId, payload: ["throw": choice])
    }

    /// Pick a number (0–6) for this cricket ball. Same fire-and-forget contract as above.
    func pickCricket(_ pick: Int) {
        guard let matchId, let cricket, !cricket.finished else { return }
        WebSocketClient.shared.sendGameInput(matchId: matchId, payload: ["pick": pick])
    }

    /// Call the toss. `side` is "heads" | "tails".
    ///
    /// Fire-and-forget like every other input here. The server refuses a call from the seat
    /// that does not hold it, so this does not police whose turn it is — it only avoids
    /// sending a frame we already know is pointless.
    func callToss(_ side: String) {
        guard let matchId, let cricket, !cricket.finished else { return }
        WebSocketClient.shared.sendGameInput(matchId: matchId, payload: ["call": side])
    }

    /// Elect to bat or bowl after winning the toss. `choice` is "bat" | "bowl".
    func electToss(_ choice: String) {
        guard let matchId, let cricket, !cricket.finished else { return }
        WebSocketClient.shared.sendGameInput(matchId: matchId, payload: ["elect": choice])
    }

    /// Create a SOLO match — one human against server-side bots — and enter it.
    ///
    /// No invite and no opponent, unlike `create`. Snake is the first game whose catalog row
    /// allows `min_players = 1`, which is what lets a match exist with a single seat.
    ///
    /// The bots run on the SERVER, not here, so this stays a pure renderer: practice and
    /// multiplayer are the same code path on both sides, and a bug in one is a bug in both
    /// rather than two implementations drifting apart. That is the difference between this
    /// and the `*Bot.swift` views, which simulate turn-based opponents locally because those
    /// games have no continuous state to keep in sync.
    func createSolo(
        slug: String, options: [String: Int] = [:], skin: String? = nil
    ) async -> String? {
        do {
            let id = try await api.create(
                slug: slug, opponentIds: [], options: options, skin: skin)
            await open(matchId: id)
            return id
        } catch {
            joinError = "Couldn't start the match."
            return nil
        }
    }

    /// Steer. `heading` is radians in world space; `boost` is whether the pedal is held.
    ///
    /// Rate-limited to the server's tick rate rather than sent on every touch callback. A
    /// drag gesture fires far faster than 10 Hz, and the extra frames cannot change anything:
    /// the server reads the latest heading once per tick and discards the rest. Sending them
    /// anyway would burn uplink and radio on a phone for no visible effect, and would trip
    /// the per-match input limit.
    ///
    /// Unsent changes are not queued — the newest heading simply replaces the last, which is
    /// the correct semantics for a continuous control. A stale heading has no value.
    func steer(heading: Double, boost: Bool) {
        // Record the intent unconditionally. Whether it goes on the wire is decided by the
        // pacer below, never here — a control the player is actively holding must not be
        // able to fall out of the loop.
        desiredHeading = heading
        desiredBoost = boost
        if boost != lastSentBoost { flushSteering() }
    }

    /**
     * Send the current desired heading, at most once per interval.
     *
     * NO "has it moved enough" TEST. An earlier version skipped sends when the new heading
     * was within a few degrees of a reference, and every variant of that was broken:
     * against the last SENT heading a respawn (which resets the heading server side) left
     * the client convinced it had nothing to say; against the SERVER's heading it was worse,
     * because the snake continuously turns TOWARD the desired heading, so the two converge
     * by design and sends stopped the moment a turn completed.
     *
     * Both produced the same symptom: steering works, then silently stops forever. A
     * continuous control is cheap to resend and catastrophic to under-send.
     */
    func flushSteering() {
        guard let matchId, let snake, !snake.finished else { return }
        guard let h = desiredHeading else { return }

        // A DEAD SNAKE IS NOT STEERABLE, and pretending otherwise starved the one frame that
        // mattered. Nothing paused this pacer on death, so the client kept sending headings at
        // 10-15/s at a snake that was not in the arena — straight into the same per-match input
        // budget the respawn frame has to come out of. By the time the 2.5 s delay elapsed and
        // the button became tappable, the budget was reliably gone and Respawn did nothing.
        if let me = TokenStore.shared.userId,
           let mine = snake.snakes.first(where: { $0.id == me }),
           !mine.alive {
            return
        }

        let now = CACurrentMediaTime()
        let boostChanged = desiredBoost != lastSentBoost
        guard boostChanged || now - lastSteerSentAt >= Self.steerInterval else { return }

        lastSteerSentAt = now
        lastSentBoost = desiredBoost
        WebSocketClient.shared.sendGameInput(
            matchId: matchId, payload: ["h": h, "boost": desiredBoost])
    }

    /// The finger left the stick. Stop resending; the snake keeps its heading.
    func releaseSteering() {
        desiredHeading = nil
    }

    /// Ask the server to put a dead snake back in. Ignored until the delay has elapsed.
    func requestRespawn() {
        guard let matchId else { return }
        WebSocketClient.shared.sendGameInput(matchId: matchId, payload: ["respawn": true])
    }

    private static let steerInterval: TimeInterval = 0.06
    private var lastSteerSentAt: TimeInterval = 0
    private var lastSentBoost = false
    /// What the player is asking for right now; resent on a fixed cadence while set.
    private var desiredHeading: Double?
    private var desiredBoost = false

    func leave() {
        // Tell the server BEFORE clearing local state, not after — matchId is nil the moment
        // this function returns, and the API call needs it. Fire-and-forget: local state
        // clears unconditionally below regardless of whether this lands, matching every other
        // "tell the server, don't block the UI on it" call in this file. See GamesAPI.leave's
        // doc comment for what this fixes (an abandoned Snake match ticking, and flooding this
        // socket with game_state, for up to its full duration with nobody watching).
        if let matchId {
            Task { try? await self.api.leave(matchId: matchId) }
        }

        matchId = nil
        state = nil
        rps = nil
        cricket = nil
        snakeFrames = []
        snakeFramesSnapshot = []
        joinError = nil
        lastSeq = -1
        desiredHeading = nil
        desiredBoost = false
        lastSentBoost = false
    }
}
