// Rock Paper Scissors — best-of-N, simultaneous reveal.
//
// THE INTERESTING PROBLEM HERE IS SIMULTANEITY, and it is why this game is worth having
// server-authoritative even though the rules are trivial. Both players choose at the same
// time, so the server must hold each throw WITHOUT revealing it until both have arrived.
// If the relay simply forwarded throws, whoever moved second would see the first player's
// choice and win every round. So:
//
//   * a throw is stored server-side and NEVER included in the state sent to the opponent
//     while the round is open — `serialize()` reports only that a player "has thrown";
//   * both throws are revealed in the same broadcast, once the round resolves.
//
// That is a real cheat this design prevents, unlike Tic Tac Toe where the board is public
// by nature. It also means a client cannot "wait and see" — there is nothing to see.
//
// Best-of-N (default 3) rather than single-round: one round of RPS is a coin flip, and a
// coin flip does not make a satisfying match record on the leaderboard.
import type {
  ApplyResult,
  GameEngine,
  GameFactory,
  GameInput,
  GameStatePayload,
} from '../GameEngine';

type Throw = 'rock' | 'paper' | 'scissors';
const THROWS: Throw[] = ['rock', 'paper', 'scissors'];

/** What each throw defeats. */
const BEATS: Record<Throw, Throw> = {
  rock: 'scissors',
  paper: 'rock',
  scissors: 'paper',
};

interface RoundLog {
  throws: [Throw, Throw];
  /** Seat that won the round, or null for a tie. */
  winner: number | null;
}

interface State {
  players: string[];
  /** Rounds needed to win the match. */
  target: number;
  wins: [number, number];
  /** Current round's throws, held secret until both are in. */
  pending: [Throw | null, Throw | null];
  history: RoundLog[];
  finished: boolean;
  winnerIdx: number | null;
}

class RPSEngine implements GameEngine {
  private s: State;

  constructor(state: State) {
    this.s = state;
  }

  applyInput(playerId: string, input: GameInput): ApplyResult {
    if (this.s.finished) return { accepted: false };

    const idx = this.s.players.indexOf(playerId);
    if (idx === -1) return { accepted: false };

    const choice = input.throw;
    if (typeof choice !== 'string' || !THROWS.includes(choice as Throw)) {
      return { accepted: false };
    }
    // One throw per round. Re-throwing would let a player change their mind after the
    // opponent commits, which is the same information leak as seeing their choice.
    if (this.s.pending[idx] !== null) return { accepted: false };

    this.s.pending[idx] = choice as Throw;

    // Round still open — the opponent has not thrown. Accepted, and the broadcast will say
    // only that this player has thrown, never what.
    if (this.s.pending[0] === null || this.s.pending[1] === null) {
      return { accepted: true };
    }

    // Both in: resolve.
    const [a, b] = this.s.pending as [Throw, Throw];
    let roundWinner: number | null = null;
    if (a !== b) roundWinner = BEATS[a] === b ? 0 : 1;

    this.s.history.push({ throws: [a, b], winner: roundWinner });
    if (roundWinner !== null) this.s.wins[roundWinner] += 1;
    this.s.pending = [null, null];

    if (this.s.wins[0] >= this.s.target || this.s.wins[1] >= this.s.target) {
      const w = this.s.wins[0] > this.s.wins[1] ? 0 : 1;
      this.s.finished = true;
      this.s.winnerIdx = w;
      return {
        accepted: true,
        outcome: {
          winnerId: this.s.players[w],
          // Score is rounds won, not 1/0 — a 3-0 sweep and a 3-2 grind are different
          // results and the history should be able to tell them apart.
          scores: {
            [this.s.players[0]]: this.s.wins[0],
            [this.s.players[1]]: this.s.wins[1],
          },
        },
      };
    }

    return { accepted: true };
  }

  serialize(): GameStatePayload {
    return {
      players: this.s.players,
      target: this.s.target,
      wins: this.s.wins,
      // CRITICAL: booleans, never the throws themselves. The whole anti-cheat property of
      // this game rests on this line not leaking `pending`.
      hasThrown: [this.s.pending[0] !== null, this.s.pending[1] !== null],
      // History is safe to send in full — every round in it is already resolved.
      history: this.s.history,
      finished: this.s.finished,
      winnerUserId: this.s.winnerIdx === null ? null : this.s.players[this.s.winnerIdx],
    };
  }

  /**
   * The throws, and ONLY the throws. Persisted server-side between inputs; never broadcast.
   * Same reason as cricket: the runtime round-trips serialize/restore on every input, so a throw
   * omitted from serialize() was lost immediately and the round could never resolve.
   */
  serializeSecret(): GameStatePayload {
    return { pending: this.s.pending };
  }

  isFinished(): boolean {
    return this.s.finished;
  }
}

export const rps: GameFactory = {
  slug: 'rps',
  // No tickHz: reactive, like every other turn-based game here.
  create(playerIds: string[]): GameEngine {
    return new RPSEngine({
      players: [...playerIds],
      target: 3,
      wins: [0, 0],
      pending: [null, null],
      history: [],
      finished: false,
      winnerIdx: null,
    });
  },
  restore(state: GameStatePayload, secret?: GameStatePayload): GameEngine {
    const players = state.players as string[];
    const history = (state.history as RoundLog[]) ?? [];
    return new RPSEngine({
      players,
      target: (state.target as number) ?? 3,
      wins: (state.wins as [number, number]) ?? [0, 0],
      // Pending throws are NOT in the serialized payload (by design — see serialize). A
      // match restored mid-round therefore reopens that round, which costs one replayed
      // throw and never leaks a choice. Losing a round's throws is strictly better than
      // persisting them where the opponent's client could ever receive them.
      // Throws come back on the SECRET channel, never from `state` — they are persisted for the
      // server's own use and never appear in a broadcast. A restore without a secret (Redis lost)
      // reopens the round: one replayed throw, nothing leaked.
      pending: (secret?.pending as [Throw | null, Throw | null]) ?? [null, null],
      history,
      finished: (state.finished as boolean) ?? false,
      winnerIdx:
        state.winnerUserId === null || state.winnerUserId === undefined
          ? null
          : players.indexOf(state.winnerUserId as string),
    });
  },
};
