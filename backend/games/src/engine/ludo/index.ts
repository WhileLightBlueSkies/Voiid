// Ludo — the first game in this catalog with more than two seats (docs/games/future/LUDO.md).
//
// WHY IT IS WORTH BUILDING. Every shipped game is 1:1. Ludo is the game a group of four plays,
// and a messenger is where groups of four already are: the app has group conversations, a
// contact graph and a notification pipe, and what it does not have is any reason for four people
// to open it at the same time.
//
// THE SECURITY MODEL IS ONE LINE: THE SEED IS SECRET. Ludo has no hidden player information —
// every token, roll and capture is public to every seat — so there is no per-player projection
// and nothing to leak sideways. The only hidden thing is the FUTURE, and §4.6 is why that
// matters more here than anywhere else in the folder: mulberry32's state IS its seed, so a
// client holding it can compute every future roll of the match in twenty lines. That is not a
// minor leak. Knowing you will roll 6, 6, 2 next completely determines which token to move now.
// A client with the seed does not cheat at Ludo, it solves it.
//
// THE DICE ARE NOT WEIGHTED, AND PLAYERS WILL NOT BELIEVE IT. Six-starved streaks are common —
// the chance of no 6 in six rolls is 33% — and the human pattern-matcher will find them. The
// answer is not to bias the die back; it is that the sequence is reproducible from the seed, so
// a match can be audited after the fact. Adding "fairness" adjustments would make that untrue.
import type {
  ApplyResult,
  GameEngine,
  GameFactory,
  GameInput,
  GameOutcome,
  GameStatePayload,
} from '../GameEngine';
import { Rng } from '../rng';
import {
  COLUMN_BASE,
  HOME,
  MAX_SEATS,
  YARD,
  destination,
  entrySquare,
  inColumn,
  inYard,
  isHome,
  isSafe,
  onTrack,
  path,
  relative,
} from './board';

export type Phase = 'awaitingRoll' | 'awaitingMove' | 'done';

interface LastMove {
  seat: number;
  token: number;
  from: number;
  to: number;
  /** [seat, token] of a token sent home, or null. */
  captured: [number, number] | null;
}

interface State {
  players: string[];
  tokensPerPlayer: number;
  /** [seat][token] -> position encoding (board.ts). */
  tokens: number[][];
  turn: number;
  phase: Phase;
  die: number | null;
  /** Token indices legally movable with `die`. Precomputed, not derived (§4.3). */
  legal: number[];
  sixStreak: number;
  extraTurn: boolean;
  rollsThisTurn: number;
  finishedOrder: number[];
  moveCount: number;
  deadlineAt: number | null;
  lastMove: LastMove | null;
  finished: boolean;
  winnerIdx: number | null;
  /** THE SECRET. Never in serialize() — see the header and §4.6. */
  seed: number;
}

/**
 * 45 seconds, not 60 (§13.2). A Ludo action is "tap the die" then "tap one of at most four
 * tokens"; 45 s is generous for a decision that size and it bounds a 60-turn match at a length
 * people will actually finish.
 */
const TURN_DEADLINE_MS = 45_000;

/**
 * A hard bound on turn length, independent of the three-sixes rule.
 *
 * Extra turns come from three sources that all compose (§2.3), so a pathological sequence could
 * in principle run long. This is a safety property rather than a game rule — the kind of bound
 * that stops a malfunctioning client being handed an endless sequence of turns.
 */
const MAX_ROLLS_PER_TURN = 8;

class LudoEngine implements GameEngine {
  private s: State;
  private rng: Rng;

  constructor(state: State) {
    this.s = state;
    this.rng = new Rng(state.seed);
  }

  // --- Input ---------------------------------------------------------------------------

  applyInput(playerId: string, input: GameInput): ApplyResult {
    if (this.s.finished) return { accepted: false };

    const seat = this.s.players.indexOf(playerId);
    if (seat === -1) return { accepted: false };
    if (seat !== this.s.turn) return { accepted: false }; // out of turn

    if (input.roll === true) return this.roll(seat);
    if (typeof input.move === 'number') return this.move(seat, input.move);
    return { accepted: false };
  }

  /**
   * Roll the die. Its own step, deliberately (§3.3).
   *
   * Not one frame with the move: the die must be broadcast and visible BEFORE the move is
   * chosen. It is the drama, it bounds what the client knows (the server would otherwise be
   * judging a move against a roll the client had not seen), and auto-move is only expressible
   * if rolling is its own step.
   */
  private roll(seat: number): ApplyResult {
    if (this.s.phase !== 'awaitingRoll') return { accepted: false };

    // Safety bound, checked before the draw so a runaway turn cannot consume the sequence.
    if (this.s.rollsThisTurn >= MAX_ROLLS_PER_TURN) return this.endTurn();

    const die = 1 + Math.floor(this.rng.next() * 6);
    this.s.die = die;
    this.s.rollsThisTurn += 1;
    this.s.moveCount += 1;
    this.s.seed = this.rng.seed;

    if (die === 6) {
      this.s.sixStreak += 1;
      // THREE CONSECUTIVE 6s FORFEITS THE TURN AND THE THIRD 6 IS NOT USED (§2.3).
      //
      // Not decoration: without it a lucky streak is unbounded, and it is the only thing
      // preventing a modified or malfunctioning client from being handed endless turns. A rule
      // that also happens to be a safety property.
      if (this.s.sixStreak >= 3) {
        this.s.die = null;
        return this.endTurn();
      }
    } else {
      this.s.sixStreak = 0;
    }

    const legal = this.legalMoves(seat, die);
    this.s.legal = legal;

    // ZERO LEGAL MOVES -> the turn passes automatically, in the same frame as the roll. A
    // "you have no moves, tap to continue" prompt is a tap that changes nothing (§3.4).
    if (legal.length === 0) return this.endTurn();

    this.s.phase = 'awaitingMove';
    this.s.deadlineAt = Date.now() + TURN_DEADLINE_MS;
    return { accepted: true };
  }

  private move(seat: number, token: number): ApplyResult {
    if (this.s.phase !== 'awaitingMove') return { accepted: false };
    if (!Number.isInteger(token)) return { accepted: false };
    // MEMBERSHIP IN THE SERVER'S OWN SET, not a re-derivation from the client's claim. The
    // legal set was computed when the roll landed; checking against it is what makes validation,
    // auto-move, timeout and the bot four consumers of one rule rather than four rule sets.
    if (!this.s.legal.includes(token)) return { accepted: false };

    const die = this.s.die;
    if (die === null) return { accepted: false };

    const from = this.s.tokens[seat][token];
    const to = destination(from, die, seat);
    if (to === null) return { accepted: false };

    this.s.tokens[seat][token] = to;

    // Capture: landing on a square with EXACTLY ONE opponent token sends it home. Two or more
    // is a block and was already excluded from the legal set, so multi-capture is impossible by
    // construction rather than by a check.
    let captured: [number, number] | null = null;
    if (onTrack(to) && !isSafe(to)) {
      for (let s2 = 0; s2 < this.s.tokens.length; s2++) {
        if (s2 === seat) continue;
        const idx = this.s.tokens[s2].findIndex((p) => p === to);
        if (idx !== -1) {
          this.s.tokens[s2][idx] = YARD;
          captured = [s2, idx];
          break;
        }
      }
    }

    this.s.lastMove = { seat, token, from, to, captured };
    this.s.moveCount += 1;

    // EXTRA TURNS COMPOSE TO ONE, NOT TWO (§2.3). The flag is boolean, not a counter —
    // capturing with a 6 grants one extra turn, or a good turn spirals.
    const grantsExtra = die === 6 || captured !== null || to === HOME;

    // A player finishes when ALL their tokens are home, and the MATCH ends on the first
    // finisher — not "play on for second place", which would leave two people continuing a game
    // they cannot win (§2.6).
    if (this.s.tokens[seat].every(isHome)) {
      this.s.finishedOrder.push(seat);
      return this.finish(seat);
    }

    if (grantsExtra) {
      this.s.extraTurn = true;
      this.s.phase = 'awaitingRoll';
      this.s.die = null;
      this.s.legal = [];
      this.s.deadlineAt = Date.now() + TURN_DEADLINE_MS;
      return { accepted: true };
    }

    return this.endTurn();
  }

  /**
   * Which of this seat's tokens can legally move with this die.
   *
   * THE ONE DEFINITION OF "WHAT CAN THIS PLAYER DO" (§4.2). Blocks are applied here, over the
   * whole board, because they are the only rule that depends on more than the moving token.
   */
  private legalMoves(seat: number, die: number): number[] {
    const blocked = this.blockedSquares(seat);
    const legal: number[] = [];

    for (let t = 0; t < this.s.tokens[seat].length; t++) {
      const from = this.s.tokens[seat][t];
      const to = destination(from, die, seat);
      if (to === null) continue;

      // An opponent's block can neither be landed on NOR passed (§2.4), so the whole path is
      // checked rather than just the destination.
      if (path(from, die, seat).some((sq) => blocked.has(sq))) continue;

      // A token may not land on a square holding two or more of its OWN colour — that would
      // stack a third onto a block (§2.2).
      if (onTrack(to)) {
        const own = this.s.tokens[seat].filter((p, i) => i !== t && p === to).length;
        if (own >= 2) continue;
      }

      legal.push(t);
    }

    return legal;
  }

  /**
   * Squares an opponent has blocked against `seat`: two or more of one other colour.
   *
   * BLOCKS CANNOT FORM ON SAFE SQUARES. Tokens may stack there — they are already safe — but
   * such a stack does not block passage. This bounds the worst case: a permanent block on an
   * entry square would lock a player out of the game entirely (§2.4).
   */
  private blockedSquares(seat: number): Set<number> {
    const counts = new Map<number, Map<number, number>>();
    for (let s2 = 0; s2 < this.s.tokens.length; s2++) {
      if (s2 === seat) continue;
      for (const p of this.s.tokens[s2]) {
        if (!onTrack(p) || isSafe(p)) continue;
        const bySeat = counts.get(p) ?? new Map<number, number>();
        bySeat.set(s2, (bySeat.get(s2) ?? 0) + 1);
        counts.set(p, bySeat);
      }
    }
    const blocked = new Set<number>();
    for (const [square, bySeat] of counts) {
      for (const n of bySeat.values()) {
        if (n >= 2) { blocked.add(square); break; }
      }
    }
    return blocked;
  }

  /** Hand the turn to the next seat that has not already finished. */
  private endTurn(): ApplyResult {
    this.s.phase = 'awaitingRoll';
    this.s.die = null;
    this.s.legal = [];
    this.s.sixStreak = 0;
    this.s.extraTurn = false;
    this.s.rollsThisTurn = 0;

    const n = this.s.players.length;
    let next = this.s.turn;
    for (let i = 1; i <= n; i++) {
      const candidate = (this.s.turn + i) % n;
      if (!this.s.finishedOrder.includes(candidate)) { next = candidate; break; }
    }
    this.s.turn = next;
    this.s.deadlineAt = Date.now() + TURN_DEADLINE_MS;
    this.s.moveCount += 1;
    return { accepted: true };
  }

  private finish(winnerIdx: number | null): ApplyResult {
    this.s.finished = true;
    this.s.phase = 'done';
    this.s.winnerIdx = winnerIdx;
    this.s.die = null;
    this.s.legal = [];
    this.s.deadlineAt = null;
    return { accepted: true, outcome: this.outcome() };
  }

  /**
   * `scores` is TOKENS HOME (0-4), so higher is better and it drops onto the existing
   * leaderboard unchanged — unlike Sea Battle, whose lower-is-better score cannot (§2.5 there).
   */
  private outcome(): GameOutcome {
    const scores = Object.fromEntries(
      this.s.players.map((p, i) => [p, this.s.tokens[i].filter(isHome).length])
    );
    return {
      winnerId: this.s.winnerIdx === null ? null : this.s.players[this.s.winnerIdx],
      scores: this.s.winnerIdx === null ? {} : scores,
    };
  }

  // --- Deadlines -----------------------------------------------------------------------

  deadlineAt(): number | null {
    return this.s.finished ? null : this.s.deadlineAt;
  }

  /**
   * AUTO-PLAY, NOT FORFEIT, and this is the key decision (§13.2).
   *
   * CROSS_CUTTING.md §6 proposes "60 s -> forfeit" for turn-based games. That is right for a
   * 2-player game where the absent player only hurts their opponent. It is WRONG for Ludo:
   * forfeiting one of four players mid-match ruins the game for the other three — the board
   * changes shape, the remaining odds change, and the match becomes something nobody signed up
   * for. Auto-play keeps the game intact. The absent player plays badly and probably loses,
   * which is the correct consequence.
   */
  onTimeout(): ApplyResult {
    if (this.s.finished || this.s.deadlineAt === null) return { accepted: false };
    if (Date.now() < this.s.deadlineAt) return { accepted: false };

    const seat = this.s.turn;
    if (this.s.phase === 'awaitingRoll') return this.roll(seat);

    if (this.s.phase === 'awaitingMove' && this.s.legal.length > 0) {
      // The mid-skill policy, not a random pick: capture > home > enter > furthest. Auto-play
      // stands in for the player, so it should not be visibly worse than they would have been.
      return this.move(seat, this.autoPick(seat));
    }

    return { accepted: false };
  }

  /**
   * The greedy policy, shared by timeout auto-play and the server's own bot seat.
   *
   * Deliberately the MIDDLE band from §11.1 rather than the strongest: an absent player's
   * tokens being played expertly would be its own unfairness to the three people still there.
   */
  private autoPick(seat: number): number {
    const die = this.s.die ?? 0;
    let best = this.s.legal[0];
    let bestScore = -Infinity;

    for (const t of this.s.legal) {
      const from = this.s.tokens[seat][t];
      const to = destination(from, die, seat);
      if (to === null) continue;

      let score = 0;
      if (to === HOME) score += 100;
      // A capture is worth more than anything except finishing: it undoes an opponent's whole
      // journey and grants another turn.
      if (onTrack(to) && !isSafe(to)) {
        const captures = this.s.tokens.some(
          (row, s2) => s2 !== seat && row.includes(to)
        );
        if (captures) score += 80;
      }
      if (inYard(from)) score += 40;         // getting a token out is nearly always right
      if (isSafe(to)) score += 15;
      if (inColumn(to)) score += 10;
      score += onTrack(to) ? relative(to, seat) * 0.1 : 0;  // else advance the furthest

      if (score > bestScore) { bestScore = score; best = t; }
    }

    return best;
  }

  // --- Serialization -------------------------------------------------------------------

  serialize(): GameStatePayload {
    return {
      players: this.s.players,
      tokensPerPlayer: this.s.tokensPerPlayer,
      tokens: this.s.tokens,
      turn: this.s.turn,
      turnUserId: this.s.finished ? null : this.s.players[this.s.turn],
      // THE FIELD A NAIVE DESIGN LOSES, and losing it is a real exploit: a restore defaulting to
      // `awaitingRoll` lets a player who has already rolled a 2 roll again for a better number.
      // The serialize/restore round trip happens on EVERY input, so this is not a rare case.
      phase: this.s.phase,
      die: this.s.die,
      // Stored rather than derived so validation, auto-move, timeout and the client's highlight
      // all read the same answer. Deriving it in three places is how three subtly different rule
      // sets appear.
      legal: this.s.legal,
      // Lose this and the three-sixes rule never fires, removing the only bound on turn length.
      sixStreak: this.s.sixStreak,
      // Lose this and every extra turn is silently forfeited — which changes the game's balance
      // completely and would be nearly invisible in testing.
      extraTurn: this.s.extraTurn,
      rollsThisTurn: this.s.rollsThisTurn,
      finishedOrder: this.s.finishedOrder,
      moveCount: this.s.moveCount,
      // Serialized rather than recomputed from "now": recomputing on restore would hand an AFK
      // player a fresh 45 seconds on every process restart, and with restarts happening on every
      // input the timer would never fire at all.
      deadlineAt: this.s.deadlineAt,
      lastMove: this.s.lastMove,
      finished: this.s.finished,
      winnerUserId: this.s.winnerIdx === null ? null : this.s.players[this.s.winnerIdx],
      // NOT PRESENT, DELIBERATELY: the RNG state. See serializeSecret.
    };
  }

  /**
   * THE MOST IMPORTANT METHOD IN THIS ENGINE, and where Ludo departs from Snake.
   *
   * Snake puts its seed straight into serialize(), on the wire, and is right to: its draws are
   * pellet positions and bot jitter, and knowing where a pellet appears a frame early is worth
   * nothing. In Ludo the next draw is the dice.
   *
   * A lost seed is quieter and worse than a crash: the engine would reseed, so every roll would
   * come from a fresh sequence seeded identically on every input. In the worst case the die
   * returns the same face forever; in the best case the sequence is silently non-random.
   * Neither looks like a failure and both take a long time to diagnose — which is why restore
   * logs loudly rather than carrying on.
   */
  serializeSecret(): GameStatePayload {
    return { rng: this.s.seed };
  }

  isFinished(): boolean {
    return this.s.finished;
  }
}

export const ludo: GameFactory = {
  slug: 'ludo',
  // No tickHz: turn-based, so no loop, and (per matches.ts) durably persisted.
  create(playerIds: string[], options?: Record<string, unknown>): GameEngine {
    const seats = Math.max(2, Math.min(MAX_SEATS, playerIds.length));

    // TOKEN COUNT IS THE LENGTH DECISION (§2.7), and the most player-visible departure from the
    // Ludo people think they know.
    //
    // A classic four-player game runs 30-45 minutes, which is a bad fit for a game played inside
    // a chat. Defaults are chosen so no default configuration exceeds ~20 minutes: 4 tokens at
    // two players, 2 tokens at three or four. The full game stays available to anyone who asks
    // for it; it is simply not what a player gets by tapping through.
    //
    // UNTRUSTED, so clamped exactly as cricket clamps its over count.
    const raw = options?.tokens;
    const requested = typeof raw === 'number' && Number.isInteger(raw) ? raw : null;
    const fallback = seats <= 2 ? 4 : 2;
    const tokensPerPlayer = requested === null ? fallback : Math.max(2, Math.min(4, requested));

    const seedOpt = options?.seed;
    const seed =
      typeof seedOpt === 'number' && Number.isFinite(seedOpt)
        ? seedOpt >>> 0
        : (Date.now() ^ (Math.random() * 0xffffffff)) >>> 0;

    return new LudoEngine({
      players: [...playerIds],
      tokensPerPlayer,
      tokens: playerIds.map(() => Array(tokensPerPlayer).fill(YARD)),
      turn: 0,
      phase: 'awaitingRoll',
      die: null,
      legal: [],
      sixStreak: 0,
      extraTurn: false,
      rollsThisTurn: 0,
      finishedOrder: [],
      moveCount: 0,
      deadlineAt: Date.now() + TURN_DEADLINE_MS,
      lastMove: null,
      finished: false,
      winnerIdx: null,
      seed,
    });
  },

  restore(state: GameStatePayload, secret?: GameStatePayload): GameEngine {
    const players = state.players as string[];

    // Rebuilt field by field, never cast — the mistake cricket/index.ts documents, where a
    // blanket cast produced an engine whose fields were undefined and whose next serialize()
    // threw, taking the service down with every match that outlived a restart.
    const rawTokens = state.tokens as number[][] | undefined;
    const tokensPerPlayer = (state.tokensPerPlayer as number | undefined) ?? 4;
    const tokens: number[][] = Array.isArray(rawTokens)
      ? rawTokens.map((row) =>
          Array.isArray(row) ? row.map((p) => (typeof p === 'number' ? p : YARD)) : []
        )
      : players.map(() => Array(tokensPerPlayer).fill(YARD));

    // THE SEED COMES FROM THE SECRET, NEVER FROM THE STATE (§4.6) — the same shape cricket uses
    // for `pending`. A restore with no secret must reseed LOUDLY: a match whose dice sequence
    // restarted is a match that quietly stopped being fair, and nothing else would report it.
    const rawSeed = (secret as { rng?: unknown } | undefined)?.rng;
    let seed: number;
    if (typeof rawSeed === 'number' && Number.isFinite(rawSeed)) {
      seed = rawSeed >>> 0;
    } else {
      seed = (Date.now() ^ (Math.random() * 0xffffffff)) >>> 0;
      console.error('[ludo] RNG state lost on restore — dice sequence reseeded');
    }

    return new LudoEngine({
      players,
      tokensPerPlayer,
      tokens,
      turn: (state.turn as number | undefined) ?? 0,
      phase: (state.phase as Phase | undefined) ?? 'awaitingRoll',
      die: (state.die as number | null | undefined) ?? null,
      legal: (state.legal as number[] | undefined) ?? [],
      sixStreak: (state.sixStreak as number | undefined) ?? 0,
      extraTurn: (state.extraTurn as boolean | undefined) ?? false,
      rollsThisTurn: (state.rollsThisTurn as number | undefined) ?? 0,
      finishedOrder: (state.finishedOrder as number[] | undefined) ?? [],
      moveCount: (state.moveCount as number | undefined) ?? 0,
      deadlineAt: (state.deadlineAt as number | null | undefined) ?? null,
      lastMove: (state.lastMove as LastMove | null | undefined) ?? null,
      finished: (state.finished as boolean) === true,
      winnerIdx:
        state.winnerUserId === null || state.winnerUserId === undefined
          ? null
          : players.indexOf(state.winnerUserId as string),
      seed,
    });
  },
};
