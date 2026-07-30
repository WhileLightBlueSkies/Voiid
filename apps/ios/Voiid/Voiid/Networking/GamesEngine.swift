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
        return CricketState(
            players: players,
            overs: (payload["overs"] as? Int) ?? 2,
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
        self.joinError = nil
        self.lastSeq = -1
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
            _ = try await ChatEngine.shared.sendText(
                GameInvite.encode(slug: slug, matchId: id, gameName: gameName),
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

    func leave() {
        matchId = nil
        state = nil
        rps = nil
        cricket = nil
        joinError = nil
        lastSeq = -1
    }
}
