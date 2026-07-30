// Tic Tac Toe — the first rules module, and the reference for every game after it.
//
// Chosen as the first game precisely because the rules are trivial: it exercises the
// whole path (invite -> match -> move -> validate -> broadcast -> win -> persist) without
// any of the risk living in the game itself. If a bug shows up while building this, the
// bug is in the plumbing, which is exactly what the first slice is meant to flush out.
//
// SERVER-AUTHORITATIVE, CONCRETELY. The client sends only "I tap cell 4". It does not
// send whose turn it is, what mark to draw, or whether the game ended — all three are
// decided here. A modified client can lie about the cell index and nothing else, and
// every lie it can tell is rejected below: out of range, already occupied, not your turn,
// game already over. There is no input that lets a client move twice or place the
// opponent's mark, because those are not expressible in the frame.
import type {
  ApplyResult,
  GameEngine,
  GameFactory,
  GameInput,
  GameStatePayload,
} from '../GameEngine';

/** Cell is the index of the player in `players` who owns it, or null if empty. */
type Cell = 0 | 1 | null;

interface State {
  players: string[];      // [X, O] — index doubles as the mark
  board: Cell[];          // 9 cells, row-major
  turn: number;           // index into players
  finished: boolean;
  winnerIdx: number | null;
  /** Winning cell triple, so the client can highlight it without re-deriving the win. */
  line: number[] | null;
  moves: number;
}

const LINES = [
  [0, 1, 2], [3, 4, 5], [6, 7, 8],   // rows
  [0, 3, 6], [1, 4, 7], [2, 5, 8],   // columns
  [0, 4, 8], [2, 4, 6],              // diagonals
];

class TicTacToeEngine implements GameEngine {
  private s: State;

  constructor(state: State) {
    this.s = state;
  }

  applyInput(playerId: string, input: GameInput): ApplyResult {
    if (this.s.finished) return { accepted: false };

    const idx = this.s.players.indexOf(playerId);
    // Not a player in this match. The runtime checks membership too, but an engine that
    // trusts its caller is one refactor away from being wrong.
    if (idx === -1) return { accepted: false };
    if (idx !== this.s.turn) return { accepted: false }; // out of turn

    const cell = input.cell;
    if (typeof cell !== 'number' || !Number.isInteger(cell) || cell < 0 || cell > 8) {
      return { accepted: false };
    }
    if (this.s.board[cell] !== null) return { accepted: false }; // occupied

    this.s.board[cell] = idx as Cell;
    this.s.moves += 1;

    const line = LINES.find(
      ([a, b, c]) =>
        this.s.board[a] !== null &&
        this.s.board[a] === this.s.board[b] &&
        this.s.board[b] === this.s.board[c]
    );

    if (line) {
      this.s.finished = true;
      this.s.winnerIdx = idx;
      this.s.line = line;
      return {
        accepted: true,
        outcome: {
          winnerId: this.s.players[idx],
          // 1/0 rather than a running tally: a single match has exactly one winner, and
          // score is what leaderboards will sum later.
          scores: Object.fromEntries(
            this.s.players.map((p, i) => [p, i === idx ? 1 : 0])
          ),
        },
      };
    }

    if (this.s.moves === 9) {
      // Draw: finished, but winnerId stays null (see the migration's note on why those
      // are separate facts).
      this.s.finished = true;
      return {
        accepted: true,
        outcome: {
          winnerId: null,
          scores: Object.fromEntries(this.s.players.map((p) => [p, 0])),
        },
      };
    }

    this.s.turn = 1 - this.s.turn;
    return { accepted: true };
  }

  serialize(): GameStatePayload {
    return {
      players: this.s.players,
      board: this.s.board,
      turn: this.s.turn,
      // Send the id, not just the index — the client renders "your turn" by comparing to
      // its own user id and should not have to know the seating convention.
      turnUserId: this.s.finished ? null : this.s.players[this.s.turn],
      finished: this.s.finished,
      winnerUserId: this.s.winnerIdx === null ? null : this.s.players[this.s.winnerIdx],
      line: this.s.line,
      moves: this.s.moves,
    };
  }

  isFinished(): boolean {
    return this.s.finished;
  }
}

export const tictactoe: GameFactory = {
  slug: 'tictactoe',
  // No tickHz: turn-based, so the runtime never starts a loop for these matches.
  create(playerIds: string[]): GameEngine {
    return new TicTacToeEngine({
      players: [...playerIds],
      board: Array(9).fill(null) as Cell[],
      // Seat order decides who is X, and the caller fixes seat order when the match is
      // created. First player to join goes first.
      turn: 0,
      finished: false,
      winnerIdx: null,
      line: null,
      moves: 0,
    });
  },
  restore(state: GameStatePayload): GameEngine {
    return new TicTacToeEngine({
      players: state.players as string[],
      board: state.board as Cell[],
      turn: state.turn as number,
      finished: state.finished as boolean,
      winnerIdx:
        state.winnerUserId === null || state.winnerUserId === undefined
          ? null
          : (state.players as string[]).indexOf(state.winnerUserId as string),
      line: (state.line as number[] | null) ?? null,
      moves: state.moves as number,
    });
  },
};
