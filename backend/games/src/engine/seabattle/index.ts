// Sea Battle — the first async game, and the first hidden-state game where the hidden thing
// belongs to a player rather than to a moment (docs/games/future/SEA_BATTLE.md).
//
// WHAT MAKES THIS DIFFERENT FROM EVERY GAME BEFORE IT. Tic Tac Toe, RPS and Hand Cricket all
// require both players to be looking at their phones at the same time; the match sits in Redis
// for an hour and evaporates. Sea Battle has no such requirement. A turn is one tap, and the
// interval between turns can be nine seconds or nine hours because there is nothing to react to
// — you are not dodging, you are deducing. A match played across a working day is not a degraded
// version of this game, it is the normal version.
//
// That is why the engine is the small part. The rules here are ~400 lines of discrete checks;
// the things that make the game work are the durable state table, the deadline sweeper and the
// per-recipient wire, all of which are shared infrastructure.
//
// SERVER-AUTHORITATIVE, CONCRETELY. A client can express exactly two things: "here is my fleet"
// and "I fire at square N". §5 of the doc enumerates why neither is worth lying about — the
// fleet is validated into legality and is only writable once, and a shot's outcome is computed
// here against a secret the client has never seen. There is no frame that moves a ship out from
// under an incoming shot, because "move a ship" is not expressible.
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
  CELLS,
  FLEET_CELLS,
  FLEET_SPEC,
  randomFleet,
  validateFleet,
  type Ship,
} from './fleet';

export type Phase = 'placing' | 'firing' | 'done';

/** 0 miss, 1 hit, 2 hit-and-sunk. Parallel to `shots`. */
export type ShotResult = 0 | 1 | 2;

interface State {
  players: string[];
  phase: Phase;
  /** Seat to move. Null during `placing`, where both may act, and once done. */
  turn: number | null;
  /** Packed 0-99 in fire order, indexed by the FIRING seat. */
  shots: number[][];
  results: ShotResult[][];
  /** Ship type ids sunk, indexed by the seat whose fleet lost them. */
  sunk: number[][];
  /** Revealed outlines of those sunk ships, same indexing. */
  sunkCells: number[][];
  placed: boolean[];
  moveCount: number;
  seed: number;
  deadlineAt: number | null;
  finished: boolean;
  winnerIdx: number | null;
  lastShot: number | null;
  lastResult: ShotResult | null;
  /** Set when a match ended without being played out; distinguishes the outcome shapes. */
  endedBy: 'win' | 'resign' | 'timeout' | 'abandoned' | null;
  /** THE SECRET. Never in serialize(), never in a client frame until sunk or match end. */
  fleets: Ship[][];
}

// --- Deadlines (§13.2) ---------------------------------------------------------------
//
// 24 HOURS, NOT 60 SECONDS. GAMES.md §7 and CROSS_CUTTING.md §6 both propose "60s to move or
// forfeit". That number is right for a live turn-based game and catastrophic for this one: it
// would forfeit every async match on its first turn, which is every match this game exists for.
// The 60s figure is per-game, not global, and Sea Battle's is a day.
const TURN_DEADLINE_MS = 24 * 60 * 60 * 1000;
// Placement gets the same window. An invite accepted and then ignored is the same problem.
const PLACEMENT_DEADLINE_MS = 24 * 60 * 60 * 1000;

class SeaBattleEngine implements GameEngine {
  private s: State;

  constructor(state: State) {
    this.s = state;
  }

  // --- Input ---------------------------------------------------------------------------

  applyInput(playerId: string, input: GameInput): ApplyResult {
    if (this.s.finished) return { accepted: false };

    const seat = this.s.players.indexOf(playerId);
    // The runtime checks membership too, but an engine that trusts its caller is one refactor
    // away from being wrong.
    if (seat === -1) return { accepted: false };

    if (input.resign === true) return this.resign(seat);
    if (this.s.phase === 'placing') return this.place(seat, input);
    if (this.s.phase === 'firing') return this.fire(seat, input);
    return { accepted: false };
  }

  /**
   * Placement arrives as ONE frame containing the whole fleet, not five frames.
   *
   * Per-ship frames would make a half-placed fleet a legal intermediate state that has to be
   * validated, persisted and rendered — and would let a client commit four ships and stall
   * forever. One frame is atomic: the fleet is legal in full or rejected in full.
   */
  private place(seat: number, input: GameInput): ApplyResult {
    if (this.s.placed[seat]) return { accepted: false }; // no re-placing, ever

    const raw = input.place;
    if (!Array.isArray(raw)) return { accepted: false };

    // Rebuilt field by field, never cast. cricket/index.ts documents what a blanket cast costs:
    // an engine whose fields are undefined, and a serialize() that throws and takes the service
    // down with every match that outlived it.
    const ships: Ship[] = raw.map((r: any) => ({
      type: r?.type,
      cells: Array.isArray(r?.cells) ? [...r.cells] : [],
      hits: 0,
    }));

    if (validateFleet(ships) !== null) return { accepted: false };

    this.s.fleets[seat] = ships;
    this.s.placed[seat] = true;

    if (this.s.placed[0] && this.s.placed[1]) {
      this.s.phase = 'firing';
      // `turn` was decided at create() and has been held through placement, so the coin is not
      // re-flipped here — a restore mid-placement must not be able to reassign the first shot.
      this.s.deadlineAt = Date.now() + TURN_DEADLINE_MS;
    }

    this.s.moveCount += 1;
    return { accepted: true };
  }

  private fire(seat: number, input: GameInput): ApplyResult {
    if (this.s.turn !== seat) return { accepted: false }; // out of turn

    const cell = input.fire;
    if (typeof cell !== 'number' || !Number.isInteger(cell) || cell < 0 || cell >= CELLS) {
      return { accepted: false };
    }
    // A square may only be fired at once. The client greys fired cells out, so this only trips
    // on a stale or modified client — and per GameEngine.ts a rejected input costs the server
    // one rejection and produces no broadcast.
    if (this.s.shots[seat].includes(cell)) return { accepted: false };

    const target = 1 - seat;
    const fleet = this.s.fleets[target];
    const ship = fleet.find((sh) => sh.cells.includes(cell));

    let result: ShotResult = 0;
    if (ship) {
      ship.hits += 1;
      if (ship.hits >= ship.cells.length) {
        result = 2;
        this.s.sunk[target].push(ship.type);
        // Once a ship is sunk its squares are public information (§2.4), so they are promoted
        // out of the secret into public state at the moment of sinking. Without this a client
        // that reconnects mid-match sees hit markers but no outlines, and the endgame deduction
        // — the whole reason sinks are announced — is gone.
        this.s.sunkCells[target].push(...ship.cells);
      } else {
        result = 1;
      }
    }

    this.s.shots[seat].push(cell);
    this.s.results[seat].push(result);
    this.s.lastShot = cell;
    this.s.lastResult = result;
    this.s.moveCount += 1;

    // Match ends the instant all 17 squares of one fleet are hit.
    const sunkCellCount = fleet.reduce((n, sh) => n + sh.hits, 0);
    if (sunkCellCount >= FLEET_CELLS) {
      return this.finish(seat, 'win');
    }

    // ONE SHOT PER TURN — a hit does NOT grant another (§2.3).
    //
    // Extra-shot-on-hit is the more common house rule and it is better in a living room, where
    // the other player is watching the streak. It is actively bad async: "you keep shooting
    // while you keep hitting" means one player takes six turns in ninety seconds while the other
    // gets six notifications for a game they cannot act in. It converts a predictable rhythm
    // into one where the notification cadence tells you you are losing before you open the app.
    //
    // Fixed alternation also makes the sweeper trivial: exactly one player is ever on the clock.
    this.s.turn = target;
    this.s.deadlineAt = Date.now() + TURN_DEADLINE_MS;
    return { accepted: true };
  }

  /**
   * Resignation is a RESULT, not an abandonment (§13.4).
   *
   * It must count as a loss in the head-to-head, and a match nobody played must not. Conflating
   * them makes the head-to-head record untrustworthy, and a record nobody trusts is worse than
   * no record at all.
   */
  private resign(seat: number): ApplyResult {
    return this.finish(1 - seat, 'resign');
  }

  private finish(winnerIdx: number | null, by: State['endedBy']): ApplyResult {
    this.s.finished = true;
    this.s.phase = 'done';
    this.s.turn = null;
    this.s.winnerIdx = winnerIdx;
    this.s.deadlineAt = null;
    this.s.endedBy = by;
    return { accepted: true, outcome: this.outcome() };
  }

  /**
   * `scores` is SHOTS FIRED, lower being better.
   *
   * That is the number this game is about, what a personal best is measured in, and the only
   * number that makes two matches comparable. Floor is 17; a strong human is high 30s to mid
   * 40s; random shooting is ~95.
   *
   * Because lower is better here and higher is better in every other game, Sea Battle must not
   * be added to the global leaderboard until score direction is representable — it sorts
   * descending, so adding this unchanged puts the worst player in the app on top (§2.5).
   */
  private outcome(): GameOutcome {
    // An abandoned match is scored {} — the honest record of a match that did not finish, the
    // same shape handleLeave writes. A resignation is NOT this: it has a winner and real counts.
    if (this.s.winnerIdx === null) return { winnerId: null, scores: {} };
    return {
      winnerId: this.s.players[this.s.winnerIdx],
      scores: Object.fromEntries(this.s.players.map((p, i) => [p, this.s.shots[i].length])),
    };
  }

  // --- Deadlines -----------------------------------------------------------------------

  deadlineAt(): number | null {
    return this.s.finished ? null : this.s.deadlineAt;
  }

  /**
   * The deadline fired. Whether it is real is decided here, not by the sweeper.
   *
   * The sweeper pops a set member without knowing whether the player has since moved, so a
   * rejection means "stale — the current deadline stands" and the runtime re-registers it. That
   * check is what stops a duplicated sweeper delivery forfeiting someone who already played.
   */
  onTimeout(): ApplyResult {
    if (this.s.finished || this.s.deadlineAt === null) return { accepted: false };
    if (Date.now() < this.s.deadlineAt) return { accepted: false };

    if (this.s.phase === 'placing') {
      const p0 = this.s.placed[0];
      const p1 = this.s.placed[1];
      // Neither placed: nobody played, so nobody won and it counts for nothing. One placed: the
      // player who showed up wins by walkover.
      if (!p0 && !p1) return this.finish(null, 'abandoned');
      return this.finish(p0 ? 0 : 1, 'timeout');
    }

    if (this.s.phase === 'firing' && this.s.turn !== null) {
      return this.finish(1 - this.s.turn, 'timeout');
    }

    return { accepted: false };
  }

  // --- Serialization -------------------------------------------------------------------

  /**
   * The PUBLIC, persistence-complete shape. The runtime hands this straight back to restore(),
   * so anything missing here is silently reset on the next input — and it is also what a
   * spectator or any seatless caller sees, which is why nothing private is in it.
   *
   * Two fields here exist only because the doc's field-by-field exercise found them:
   * `sunkCells`, without which a reconnecting client loses every ship outline, and `deadlineAt`,
   * without which every process restart silently hands an AFK player a fresh 24 hours.
   */
  serialize(): GameStatePayload {
    return {
      players: this.s.players,
      phase: this.s.phase,
      turn: this.s.turn,
      // The id as well as the seat, so the client renders "your turn" by comparing to its own
      // user id and never has to know the seating convention — same reason tictactoe sends it.
      turnUserId: this.s.turn === null ? null : this.s.players[this.s.turn],
      shots: this.s.shots,
      // STORED, NOT DERIVED, and deliberately against the "nothing derivable is stored" instinct
      // snake/index.ts argues for. That instinct is about a payload sent 12x/sec. Deriving
      // results would make the PUBLIC state depend on the SECRET state, so a restore that lost
      // the secret would silently turn every past hit into a miss.
      results: this.s.results,
      sunk: this.s.sunk,
      sunkCells: this.s.sunkCells,
      placed: this.s.placed,
      // Sent so the renderer never hardcodes the fleet and an older client cannot disagree with
      // the server about how much fleet is left — the same argument as cricket serializing
      // ballsTotal rather than making the renderer know BALLS_PER_OVER.
      fleetSpec: [...FLEET_SPEC],
      moveCount: this.s.moveCount,
      // PUBLIC, DELIBERATELY, and one of only two games in the folder allowed this (README §1.3).
      // The rule is that the seed goes in the secret whenever a future draw is information a
      // player would pay for. Here it is not: the first-move draw has already happened by the
      // time any client sees a frame, and the placement draw only ever produces YOUR OWN fleet,
      // which you are about to be shown anyway. Do NOT copy this into Ludo or Voiid Cards, where
      // the next draw is the dice and the shuffle.
      seed: this.s.seed,
      deadlineAt: this.s.deadlineAt,
      finished: this.s.finished,
      // The id rather than the index, for the reason cricket documents: storing a field
      // serialize() does not emit is how a finished match silently un-wins itself on restore.
      winnerUserId: this.s.winnerIdx === null ? null : this.s.players[this.s.winnerIdx],
      endedBy: this.s.endedBy,
      // The shot to animate on arrival. A client could diff `shots` against its previous copy,
      // but a client that just cold-started has no previous copy and would animate nothing or
      // everything — and for an async game, cold start is the normal case.
      lastShot: this.s.lastShot,
      lastResult: this.s.lastResult,
      // Only ever non-null once the match is over (see serializeForPlayer).
      revealedFleets: this.s.finished ? this.s.fleets : null,
    };
  }

  /**
   * The INFORMATION projection — the method this game does not exist without (§4.3).
   *
   * Three deliberate properties:
   *  1. ADDITIVE. It returns serialize() plus exactly one private field and never removes
   *     anything, so a spectator's view is a strict subset of a player's.
   *  2. PURE. Called once per recipient. serializeForWire() is allowed to clear delta buffers
   *     and Snake relies on that; this must not, which is why it is a separate method.
   *  3. SAFE BY DEFAULT. A caller with no seat falls through to serialize(), so a leak to a
   *     spectator is structurally impossible rather than merely unwritten.
   *
   * The opponent's fleet is never in any payload sent to a client, at any phase, until the
   * individual ship is sunk — at which point its cells are already in public `sunkCells`. There
   * is no separate "reveal" frame either: the terminal broadcast carries `revealedFleets`, and
   * it goes out before finishMatch clears the Redis key.
   */
  serializeForPlayer(playerId: string): GameStatePayload {
    const seat = this.s.players.indexOf(playerId);
    const base = this.serialize();
    if (seat !== 0 && seat !== 1) return base; // spectator: public state only
    return { ...base, seat, myFleet: this.s.fleets[seat] };
  }

  /**
   * The server's copy of the truth.
   *
   * GameEngine.ts describes the hand-cricket bug this channel exists for. Sea Battle's version
   * is worse and it is worth being explicit about why: cricket's secret is one ball old, and
   * losing it "reopens that ball, costs one replayed pick and leaks nothing". Sea Battle's
   * secret is the entire match. A restore that loses the fleets does not cost a turn — there is
   * no longer any fact about where the ships are, so every subsequent shot would have to be a
   * miss. See restore() for why that must fail loudly rather than continue.
   */
  serializeSecret(): GameStatePayload {
    return { fleets: this.s.fleets };
  }

  isFinished(): boolean {
    return this.s.finished;
  }
}

export const seabattle: GameFactory = {
  slug: 'seabattle',
  // No tickHz: turn-based, so the runtime never starts a loop — and, per matches.ts, this is
  // also what marks the game as durably persisted. Nothing here advances on its own; the only
  // time-dependent value is deadlineAt, which is an absolute timestamp and therefore correct
  // however long the process was down.
  create(playerIds: string[], options?: Record<string, unknown>): GameEngine {
    // Seeded from the clock at creation and then threaded explicitly. See rng.ts for why
    // Math.random() would be fatal in an engine rebuilt on every input.
    const seedOpt = options?.seed;
    const seed =
      typeof seedOpt === 'number' && Number.isFinite(seedOpt)
        ? seedOpt >>> 0
        : (Date.now() ^ (Math.random() * 0xffffffff)) >>> 0;
    const rng = new Rng(seed);

    // Who fires first. One draw, at create, and it is announced in the opening frame exactly as
    // hand cricket announces the toss. It is drawn HERE rather than when placement completes so
    // that a restore mid-placement cannot re-flip it.
    const first = rng.int(2);

    return new SeaBattleEngine({
      players: [...playerIds],
      phase: 'placing',
      // Held through placement and consumed when firing opens.
      turn: first,
      shots: [[], []],
      results: [[], []],
      sunk: [[], []],
      sunkCells: [[], []],
      placed: [false, false],
      moveCount: 0,
      seed: rng.seed,
      // The placement clock runs from creation, not from the second join — a clock that only
      // starts once both players are present would never fire on an invite nobody accepts.
      deadlineAt: Date.now() + PLACEMENT_DEADLINE_MS,
      finished: false,
      winnerIdx: null,
      lastShot: null,
      lastResult: null,
      endedBy: null,
      fleets: [[], []],
    });
  },

  restore(state: GameStatePayload, secret?: GameStatePayload): GameEngine {
    const players = state.players as string[];
    const phase = (state.phase as Phase) ?? 'placing';

    // REBUILT FIELD BY FIELD, NEVER CAST — the mistake cricket/index.ts documents, where a
    // blanket cast produced an engine whose fields were undefined and whose very next
    // serialize() threw, taking the service down with every match that outlived a restart.
    const rawFleets = (secret as { fleets?: unknown } | undefined)?.fleets;
    const fleets: Ship[][] = Array.isArray(rawFleets)
      ? (rawFleets as any[]).map((f) =>
          Array.isArray(f)
            ? f.map((sh: any) => ({
                type: sh?.type,
                cells: Array.isArray(sh?.cells) ? [...sh.cells] : [],
                hits: typeof sh?.hits === 'number' ? sh.hits : 0,
              }))
            : []
        )
      : [[], []];
    while (fleets.length < 2) fleets.push([]);

    const placed = (state.placed as boolean[] | undefined) ?? [false, false];

    // A LOST SECRET IN THE FIRING PHASE IS FATAL, AND MUST BE LOUD.
    //
    // The engine cannot invent fleets: inventing them produces a match whose past results
    // contradict its present ones, where a square recorded as a hit is now empty water. And it
    // must not silently continue, because a match that quietly stops being winnable is worse
    // than one that visibly ended. The correct behaviour is to abandon with winnerId: null —
    // the same honest shape handleLeave writes for a match that did not finish.
    //
    // This should be effectively unreachable now that 040's durable table stores state and
    // secret in the same row, written in the same statement. Naming it is the point: the
    // failure has to be loud rather than quietly wrong.
    const lostSecret =
      phase === 'firing' && (fleets[0].length === 0 || fleets[1].length === 0);
    if (lostSecret) {
      console.error('[seabattle] secret lost on restore — abandoning match');
    }

    return new SeaBattleEngine({
      players,
      phase: lostSecret ? 'done' : phase,
      turn: lostSecret ? null : ((state.turn as number | null) ?? null),
      shots: (state.shots as number[][] | undefined) ?? [[], []],
      results: (state.results as ShotResult[][] | undefined) ?? [[], []],
      sunk: (state.sunk as number[][] | undefined) ?? [[], []],
      sunkCells: (state.sunkCells as number[][] | undefined) ?? [[], []],
      placed: [placed[0] === true, placed[1] === true],
      moveCount: (state.moveCount as number | undefined) ?? 0,
      seed: (state.seed as number | undefined) ?? 1,
      // Serialized rather than recomputed from "now". Recomputing on restore would silently give
      // an AFK player a fresh 24 hours on every process restart — a naive design loses this
      // field, and loses it in the direction of never forfeiting anyone.
      deadlineAt: lostSecret ? null : ((state.deadlineAt as number | null) ?? null),
      finished: lostSecret ? true : (state.finished as boolean) === true,
      winnerIdx: lostSecret
        ? null
        : state.winnerUserId === null || state.winnerUserId === undefined
          ? null
          : players.indexOf(state.winnerUserId as string),
      lastShot: (state.lastShot as number | null) ?? null,
      lastResult: (state.lastResult as ShotResult | null) ?? null,
      endedBy: lostSecret ? 'abandoned' : ((state.endedBy as State['endedBy']) ?? null),
      fleets,
    });
  },
};

/** Exposed for the client's Random button and for practice-mode bots. */
export { randomFleet, validateFleet, FLEET_SPEC };
