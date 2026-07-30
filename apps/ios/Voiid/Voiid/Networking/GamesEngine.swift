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

@MainActor
final class GamesEngine: ObservableObject {
    static let shared = GamesEngine()

    /// The match this device is currently showing, if any.
    @Published private(set) var matchId: String?
    @Published private(set) var state: TicTacToeState?
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
        state = TicTacToeState.parse(payload)
    }

    /// Enter a match. The opening board arrives as a `game_state` frame, not in this
    /// response — the server builds it, which is why there is nothing to render until the
    /// frame lands (wake-then-fetch, same as Stories).
    func open(matchId: String) async {
        self.matchId = matchId
        self.state = nil
        self.joinError = nil
        self.lastSeq = -1
        do {
            try await api.join(matchId: matchId)
        } catch {
            joinError = "Couldn't join this match."
        }
    }

    /// Create a match against one opponent and enter it. Returns the id so the caller can
    /// send the invite over the ordinary encrypted message path.
    func create(slug: String, opponentId: String) async -> String? {
        do {
            let id = try await api.create(slug: slug, opponentIds: [opponentId])
            await open(matchId: id)
            return id
        } catch {
            joinError = "Couldn't start the game."
            return nil
        }
    }

    /// Tap a cell. Fire-and-forget by design: the board changes when the SERVER says it
    /// changed. An illegal tap is simply ignored server-side and no frame comes back.
    func play(cell: Int) {
        guard let matchId, let state, !state.finished else { return }
        WebSocketClient.shared.sendGameInput(matchId: matchId, payload: ["cell": cell])
    }

    func leave() {
        matchId = nil
        state = nil
        joinError = nil
        lastSeq = -1
    }
}
