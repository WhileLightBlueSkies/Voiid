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

/** Which side of the coin a player called. */
export type CoinSide = 'heads' | 'tails';
/** What the toss winner elected to do. */
export type TossChoice = 'bat' | 'bowl';

/**
 * THE TOSS, as its own phase before ball one.
 *
 * A match no longer starts in `bat` — it starts in `toss`, and no pick is accepted until the
 * toss resolves. Two steps, because that is the real game:
 *
 *   `call`   the seat holding the call picks heads or tails. The coin is flipped AT CREATION
 *            (see `coin`), not when the call arrives — see the anti-cheat note there.
 *   `decide` whoever won the call elects to bat or bowl.
 *
 * Choosing to BOWL first is a genuine tactic and not a formality: batting second means you
 * know the target, which in a two-wicket format is worth a lot. A toss that only decides who
 * bats throws that decision away, which is why this is two steps and not one.
 */
type Phase = 'toss-call' | 'toss-decide' | 'play';

interface TossState {
  /**
   * The coin, decided AT MATCH CREATION and never mutated.
   *
   * FLIPPED UP FRONT, DELIBERATELY. If it were flipped when the call arrived, the result
   * would depend on input the server received from a player, and any future bug that leaked
   * or reordered that would let someone win every toss. Deciding it before anyone can speak
   * makes the call a pure guess against a value that already exists — the same posture as
   * `pending`: the secret exists, and simply is never serialized until it is safe.
   */
  coin: CoinSide;
  /** Seat that gets to call. Random, so neither seat has a structural edge. */
  callerSeat: Seat;
  /** What the caller said. Null until they call. */
  called: CoinSide | null;
  /** Set once the call resolves: the seat that won the toss and now chooses. */
  wonSeat: Seat | null;
  /** What the winner elected. Null until they choose. */
  choice: TossChoice | null;
}

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
  /** `play` once the toss has resolved. No pick is accepted before then. */
  phase: Phase;
  toss: TossState;
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

    // THE TOSS OWNS THE OPENING PHASES. A `pick` arriving before the toss resolves is
    // rejected outright rather than queued: accepting it would let a client that skipped the
    // toss UI start playing while its opponent is still on the coin.
    if (this.s.phase !== 'play') return this.applyToss(seat, input);

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

  /**
   * The two toss inputs: `{ call: 'heads' | 'tails' }` then `{ elect: 'bat' | 'bowl' }`.
   *
   * Both are seat-checked. Only the caller may call, and only the toss WINNER may elect —
   * without those checks the loser could send `elect` first and take the decision, which is
   * the entire prize being handed to the wrong player.
   */
  private applyToss(seat: Seat, input: GameInput): ApplyResult {
    if (this.s.phase === 'toss-call') {
      if (seat !== this.s.toss.callerSeat) return { accepted: false };
      const call = input.call;
      if (call !== 'heads' && call !== 'tails') return { accepted: false };
      if (this.s.toss.called !== null) return { accepted: false };

      this.s.toss.called = call;
      // The coin was decided at creation; the call is a guess against a value that already
      // exists, so this comparison cannot be influenced by anything the client sent.
      this.s.toss.wonSeat = call === this.s.toss.coin ? seat : other(seat);
      this.s.phase = 'toss-decide';
      return { accepted: true };
    }

    // toss-decide
    if (seat !== this.s.toss.wonSeat) return { accepted: false };
    const elect = input.elect;
    if (elect !== 'bat' && elect !== 'bowl') return { accepted: false };
    if (this.s.toss.choice !== null) return { accepted: false };

    this.s.toss.choice = elect;
    this.s.battingSeat = elect === 'bat' ? seat : other(seat);
    this.s.phase = 'play';
    return { accepted: true };
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
      phase: this.s.phase,
      toss: {
        callerSeat: this.s.toss.callerSeat,
        called: this.s.toss.called,
        wonSeat: this.s.toss.wonSeat,
        choice: this.s.toss.choice,
        // THE COIN IS WITHHELD UNTIL IT IS CALLED, for the same reason `pending` is withheld
        // until both picks are in: a client that could read it before calling would win every
        // toss. Once `called` is set the outcome is already decided, so revealing it then
        // gives away nothing — and the client needs it to show which face landed.
        coin: this.s.toss.called === null ? null : this.s.toss.coin,
      },
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
    // The coin rides the secret channel too. `serialize()` withholds it until the call, so
    // without this a match that outlived a process restart would come back with no coin at
    // all and re-flip it — turning a call already made into a fresh 50/50.
    return { pending: this.s.pending, coin: this.s.toss.coin };
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
    // THE MATCH OPENS ON A TOSS, not on a silent coin-flip. This used to pick battingSeat
    // randomly and announce it, on the grounds that a toss UI is "a second interaction before
    // the game starts" — which was true, and was the wrong trade for THIS game. The toss is
    // part of cricket, and electing to bowl first is a real decision rather than ceremony.
    //
    // `battingSeat` still gets a value here so no field is ever undefined, but it is
    // provisional: the toss overwrites it before a single pick is accepted.
    const coin: CoinSide = Math.random() < 0.5 ? 'heads' : 'tails';
    const callerSeat: Seat = Math.random() < 0.5 ? 0 : 1;
    return new CricketEngine({
      players: [...playerIds],
      overs: normalizeOvers(options?.overs),
      phase: 'toss-call',
      toss: { coin, callerSeat, called: null, wonSeat: null, choice: null },
      battingSeat: 0,
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
    const toss = (state.toss ?? {}) as Record<string, unknown>;
    return new CricketEngine({
      players: state.players as string[],
      overs: normalizeOvers(state.overs),
      // A match created BEFORE the toss shipped has no phase and is already in progress;
      // defaulting it to 'play' lets it finish under the old rules rather than being dragged
      // back to a toss it already passed.
      phase: (state.phase as Phase) ?? 'play',
      toss: {
        // Off the secret channel; `serialize()` withholds it until the call. Falling back to
        // the serialized value covers a match whose call already happened.
        coin: (secret?.coin as CoinSide) ?? (toss.coin as CoinSide) ?? 'heads',
        callerSeat: (toss.callerSeat as Seat) ?? 0,
        called: (toss.called as CoinSide | null) ?? null,
        wonSeat: (toss.wonSeat as Seat | null) ?? null,
        choice: (toss.choice as TossChoice | null) ?? null,
      },
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
