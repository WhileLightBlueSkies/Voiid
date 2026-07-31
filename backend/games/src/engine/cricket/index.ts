// Hand Cricket — simultaneous reveal, two innings, overs-limited.
//
// See docs/GAMES_HAND_CRICKET.md for the rules and why each house rule was chosen. This file
// is the normative implementation of them.
//
// THIS IS THE SAME ANTI-CHEAT PROBLEM AS RPS, and it is solved the same way. Both players
// pick a number secretly and reveal together, so the server must hold each pick WITHOUT
// revealing it until both have arrived:
//
//   * a pick is stored server-side and NEVER included in the state sent to the opponent
//     while the ball is open — `serialize()` reports only that a player "has picked";
//   * both picks are revealed in the same broadcast, once the ball resolves.
//
// If a future change ever puts `pending` into serialize(), the game is broken: the player who
// picks second could match the batter's number at will (a guaranteed wicket) or dodge it
// forever (unlimited runs). That single line is the whole game.
//
// WHAT'S NEW HERE RELATIVE TO RPS: innings. A match has phases (bat, chase, done), a target,
// role reversal and an over clock. That is real state the server owns, and the reason hand
// cricket can't be a client-only feature even though the arithmetic is trivial.
import type {
  ApplyResult,
  GameEngine,
  GameFactory,
  GameInput,
  GameOutcome,
  GameStatePayload,
} from '../GameEngine';

const BALLS_PER_OVER = 6;
const WICKETS_PER_INNINGS = 2;
const MIN_OVERS = 1;
const MAX_OVERS = 5;
const DEFAULT_OVERS = 2;
/** Picks are 0-6 inclusive. 0 is a closed fist — a dot ball, and out if matched. */
const MIN_PICK = 0;
const MAX_PICK = 6;

type Seat = 0 | 1;

interface BallLog {
  /** Both picks, by seat. Safe to send: the ball is already resolved. */
  picks: [number, number];
  battingSeat: Seat;
  innings: 1 | 2;
  /** Runs off the bat. 0 on a wicket or a dot ball. */
  runs: number;
  wicket: boolean;
}

interface State {
  players: string[];
  /** 1-5, fixed at creation. */
  overs: number;
  battingSeat: Seat;
  innings: 1 | 2;
  scores: [number, number];
  wickets: [number, number];
  /** Balls bowled in the CURRENT innings; resets on the switch. */
  ballsBowled: number;
  /** Runs the chasing side needs to WIN. Null during the first innings. */
  target: number | null;
  /** Secret picks for the ball in progress. NEVER serialized. */
  pending: [number | null, number | null];
  history: BallLog[];
  finished: boolean;
  winnerIdx: Seat | null;
}

const other = (s: Seat): Seat => (s === 0 ? 1 : 0);

class CricketEngine implements GameEngine {
  private s: State;

  constructor(state: State) {
    this.s = state;
  }

  applyInput(playerId: string, input: GameInput): ApplyResult {
    if (this.s.finished) return { accepted: false };

    const idx = this.s.players.indexOf(playerId);
    if (idx === -1) return { accepted: false };
    const seat = idx as Seat;

    const pick = input.pick;
    if (
      typeof pick !== 'number' ||
      !Number.isInteger(pick) ||
      pick < MIN_PICK ||
      pick > MAX_PICK
    ) {
      return { accepted: false };
    }
    // One pick per ball. Re-picking would let a player change their mind after the opponent
    // commits, which is the same information leak as seeing their choice.
    if (this.s.pending[seat] !== null) return { accepted: false };

    this.s.pending[seat] = pick;

    // Ball still open — the opponent hasn't picked. Accepted, and the broadcast will say
    // only that this player has picked, never what.
    if (this.s.pending[0] === null || this.s.pending[1] === null) {
      return { accepted: true };
    }

    return this.resolveBall();
  }

  /** Both picks are in. Score it, log it, and advance the innings if this ball ended one. */
  private resolveBall(): ApplyResult {
    const picks = [this.s.pending[0]!, this.s.pending[1]!] as [number, number];
    const bat = this.s.battingSeat;
    // Same number = out. This INCLUDES 0 vs 0 (see the spec): one rule, no exceptions, or a
    // batter could block forever against a bowler who also picks 0.
    const wicket = picks[0] === picks[1];
    const runs = wicket ? 0 : picks[bat];

    if (wicket) {
      this.s.wickets[bat] += 1;
    } else {
      this.s.scores[bat] += runs;
    }
    this.s.ballsBowled += 1;
    this.s.history.push({
      picks,
      battingSeat: bat,
      innings: this.s.innings,
      runs,
      wicket,
    });
    this.s.pending = [null, null];

    // A chase that reaches the target ends immediately — no playing out the overs.
    if (this.s.innings === 2 && this.s.target !== null && this.s.scores[bat] >= this.s.target) {
      return this.finish(bat);
    }

    const inningsOver =
      this.s.wickets[bat] >= WICKETS_PER_INNINGS ||
      this.s.ballsBowled >= this.s.overs * BALLS_PER_OVER;

    if (!inningsOver) return { accepted: true };

    if (this.s.innings === 1) {
      // Switch. The chaser needs one MORE than the first score, so an equal total is a tie
      // rather than a win — matching how the draw is stored for the other games.
      this.s.innings = 2;
      this.s.battingSeat = other(bat);
      this.s.ballsBowled = 0;
      this.s.target = this.s.scores[bat] + 1;
      return { accepted: true };
    }

    // Second innings ended short of the target: whoever batted first wins. Equal = tie.
    const chaser = bat;
    const defender = other(bat);
    if (this.s.scores[chaser] === this.s.scores[defender]) return this.finish(null);
    return this.finish(this.s.scores[chaser] > this.s.scores[defender] ? chaser : defender);
  }

  private finish(winner: Seat | null): ApplyResult {
    this.s.finished = true;
    this.s.winnerIdx = winner;
    return { accepted: true, outcome: this.outcome() };
  }

  private outcome(): GameOutcome {
    // Runs are the natural score here, so game_match_results carries something meaningful
    // rather than a placement flag alone.
    const scores: Record<string, number> = {};
    this.s.players.forEach((id, i) => {
      scores[id] = this.s.scores[i as Seat];
    });
    return {
      winnerId: this.s.winnerIdx === null ? null : this.s.players[this.s.winnerIdx],
      scores,
    };
  }

  serialize(): GameStatePayload {
    return {
      players: this.s.players,
      overs: this.s.overs,
      innings: this.s.innings,
      battingSeat: this.s.battingSeat,
      scores: this.s.scores,
      wickets: this.s.wickets,
      ballsBowled: this.s.ballsBowled,
      // Sent rather than derived so the renderer never has to know BALLS_PER_OVER.
      ballsTotal: this.s.overs * BALLS_PER_OVER,
      wicketsPerInnings: WICKETS_PER_INNINGS,
      target: this.s.target,
      // CRITICAL: booleans, never the picks themselves. The whole anti-cheat property of
      // this game rests on this line not leaking `pending`.
      hasPicked: [this.s.pending[0] !== null, this.s.pending[1] !== null],
      // History is safe to send in full — every ball in it is already resolved.
      history: this.s.history,
      finished: this.s.finished,
      winnerUserId: this.s.winnerIdx === null ? null : this.s.players[this.s.winnerIdx],
    };
  }

  /**
   * The picks, and ONLY the picks. Persisted server-side between inputs; never broadcast.
   * Without this the runtime's serialize/restore cycle dropped each pick the instant it was made
   * and the ball never resolved (see GameEngine.serializeSecret).
   */
  serializeSecret(): GameStatePayload {
    return { pending: this.s.pending };
  }

  isFinished(): boolean {
    return this.s.finished;
  }
}

/** Seat index for a user id, or null when there is no winner (a tie) or no match. */
function seatOf(userId: unknown, players: string[]): Seat | null {
  if (typeof userId !== 'string') return null;
  const i = players.indexOf(userId);
  return i === 0 || i === 1 ? (i as Seat) : null;
}

/** Clamp whatever the client asked for into a legal over count. */
function normalizeOvers(raw: unknown): number {
  if (typeof raw !== 'number' || !Number.isInteger(raw)) return DEFAULT_OVERS;
  return Math.min(MAX_OVERS, Math.max(MIN_OVERS, raw));
}

export const cricket: GameFactory = {
  slug: 'cricket',
  // No tickHz: reactive, like every other turn-based game here.
  create(playerIds: string[], options?: Record<string, unknown>): GameEngine {
    // Who bats first is RANDOM and announced in the opening frame, rather than a coin-toss
    // UI: that would be a second interaction before the game starts.
    const battingSeat: Seat = Math.random() < 0.5 ? 0 : 1;
    return new CricketEngine({
      players: [...playerIds],
      overs: normalizeOvers(options?.overs),
      battingSeat,
      innings: 1,
      scores: [0, 0],
      wickets: [0, 0],
      ballsBowled: 0,
      target: null,
      pending: [null, null],
      history: [],
      finished: false,
      winnerIdx: null,
    });
  },
  restore(state: GameStatePayload, secret?: GameStatePayload): GameEngine {
    // Rebuilt FIELD BY FIELD, not by casting the payload: `serialize()` deliberately omits
    // `pending`, so a blanket cast produces an engine whose pending is undefined, and the
    // very next serialize() throws — taking the games service down with any match that
    // outlived a process restart.
    return new CricketEngine({
      players: state.players as string[],
      overs: normalizeOvers(state.overs),
      battingSeat: (state.battingSeat as Seat) ?? 0,
      innings: (state.innings as 1 | 2) ?? 1,
      scores: (state.scores as [number, number]) ?? [0, 0],
      wickets: (state.wickets as [number, number]) ?? [0, 0],
      ballsBowled: (state.ballsBowled as number) ?? 0,
      target: (state.target as number | null) ?? null,
      // Picks are NEVER persisted (they are the one secret in the game), so a match restored
      // mid-ball reopens that ball. Costs one replayed pick and leaks nothing — the same
      // trade the RPS engine makes, for the same reason.
      // Picks come back on the SECRET channel, never from `state` — persisted for the server's
      // own use and never broadcast. A restore without a secret reopens the ball: one replayed
      // pick, nothing leaked.
      pending: (secret?.pending as [number | null, number | null]) ?? [null, null],
      history: (state.history as BallLog[]) ?? [],
      finished: (state.finished as boolean) ?? false,
      // Recovered from the USER ID, because that is what serialize() emits — reading a
      // `winnerIdx` that was never in the payload would silently un-win a finished match.
      winnerIdx: seatOf(state.winnerUserId, state.players as string[]),
    });
  },
};
