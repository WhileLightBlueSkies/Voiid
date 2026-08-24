// Ludo schema-v2 engine adapter (LUDO_GAME_SPEC.md §5, §6, §12–§16).
//
// THE SERVER OWNS EVERYTHING THAT MATTERS: the die, rules, legal moves, deadlines, results,
// and the sequence number. Clients render and submit intent only.
//
// WHY THE OLD ENGINE WAS REPLACED IN PLACE: v1 had a 45-second clock, seat-count-dependent
// pawn counts, creator-fixed colours and no authoritative presentation timeline. v2 keeps the
// useful shape — durable state, the secret channel, the sweeper-driven clock — and replaces
// the behaviour this contract forbids. A v1 state found on restore is ABANDONED with a clear
// version reason rather than converted mid-match (§20 P1).
//
// ACTIONS AND SEQ: every accepted transition produces EXACTLY ONE action and the runtime
// increments seq once for it. A transition that both moves a pawn and changes the seat packs
// BOTH facts into that one action (`fromSeat`, `actorSeat`, `roll`, `move`,
// `presentationEndsAt`) rather than emitting two frames — a client animates an action at most
// once (§6), so two actions for one transition would double-render it.
import { randomUUID } from 'node:crypto';
import type {
    ApplyResult,
    GameEngine,
    GameInput,
    GameOutcome,
    GameStatePayload,
} from '../GameEngine';
import {
    destination,
    FINISHED,
    HOME_LANE_BASE,
    MAX_SEATS,
    SEAT_COLORS,
    TOKENS_PER_SEAT,
    TRACK_COUNT,
    YARD,
    path,
} from './board';
import {
    activeSeats,
    finishedPawns,
    legalMoves,
    nextActiveSeat,
    pickAutoMove,
    resolveCapture,
} from './rules';
import { DiceRng } from './rng';
import {
    RULES_VERSION,
    SCHEMA_VERSION,
    type ActionType,
    type LastAction,
    type LudoMode,
    type LudoPublicState,
    type LudoStateV2,
    type SeatView,
} from './types';

/** Border sweep (360 ms) + die relocation / pip cross-fade (120 ms) (§12.3). */
export const TRANSITION_MS = 480;
/** Die roll choreography total (§14.3). */
export const ROLL_SETTLE_MS = 940;
/** The per-decision server clock (§13). */
export const TURN_WINDOW_MS = 30_000;

/** Hop chain duration for n cells (§15). */
export const hopMs = (n: number) => (n === 0 ? 0 : 120 + 92 * (n - 1));
const CAPTURE_EXTRA_MS = 480;
const FINISH_EXTRA_MS = 550;

export interface FrameContext {
    serverNow: number;
    /** userId -> connection state, maintained by the runtime's presence tracker. */
    connections: Record<string, 'connected' | 'disconnected'>;
    /** userId -> projected display name FOR THIS VIEWER's frame. */
    names: Record<string, string>;
}

/** Opaque, match-scoped, non-reversible seat id. Never a raw user id. */
function opaqueSeatId(matchKey: string, seat: number): string {
    return `seat-${matchKey.slice(0, 8)}-${seat}`;
}

class LudoEngineV2 implements GameEngine {
    private s: LudoStateV2;
    private rng: DiceRng;
    private matchKey: string;
    private ctx: FrameContext | null = null;

    constructor(state: LudoStateV2, rng: DiceRng, matchKey: string) {
        this.s = state;
        this.rng = rng;
        this.matchKey = matchKey;
    }

    setFrameContext(ctx: FrameContext): void {
        this.ctx = ctx;
    }

    // --- Lifecycle -----------------------------------------------------------------------

    /**
     * Select the first active seat AFTER all players accept, using the server-secret RNG
     * (§5.4). Idempotent: the final accept and a racing rejoin converge on one start.
     */
    startAll(now: number): void {
        if (this.s.started || this.s.status !== 'waiting') return;
        for (let s = 0; s < MAX_SEATS; s++) {
            if (this.s.players[s] !== null) this.s.participation[s] = 'active';
        }
        const eligible = activeSeats(this.s);
        if (eligible.length === 0) return;
        const pick = eligible[Math.floor(this.rng.next()) % eligible.length];
        this.s.started = true;
        this.s.status = 'active';
        this.s.activeSeat = pick;
        this.s.turnSerial = 1;
        this.s.phase = 'awaitingRoll';
        this.s.opensAt = now + TRANSITION_MS;
        this.s.deadlineAt = this.s.opensAt + TURN_WINDOW_MS;
        this.s.turnHadAutoAction = false;
        // First authoritative turn: the full border SETS to the first hue without travel
        // because there is no outgoing player (§12.1). One action, opensAt = +480.
        this.commitAction('turnChanged', now, {
            actorSeat: pick,
            presentationEndsAt: now + TRANSITION_MS,
        });
    }

    /** Mark a seat accepted. Returns true when every assigned seat has accepted. */
    accept(userId: string): boolean {
        const seat = this.s.players.indexOf(userId);
        if (seat !== -1) this.s.accepted[seat] = true;
        for (let s = 0; s < MAX_SEATS; s++) {
            if (this.s.players[s] !== null && !this.s.accepted[s]) return false;
        }
        return true;
    }

    /**
     * Explicit forfeit (§11.5, §16). Duel: the other player wins. Four: the seat drops and
     * play continues unless one active seat remains. Killing the app is NOT a forfeit — only
     * this deliberate call reaches here.
     */
    forfeit(userId: string, now: number): ApplyResult {
        const seat = this.s.players.indexOf(userId);
        if (
            seat === -1 ||
            this.s.status === 'finished' ||
            this.s.status === 'abandoned'
        ) {
            return { accepted: false };
        }
        if (!this.s.started) {
            this.s.status = 'abandoned';
            this.s.endReason = 'lobbyCancelled';
            this.commitAction('end', now, { actorSeat: seat });
            return { accepted: true, outcome: { winnerId: null, scores: {} } };
        }
        return this.dropSeat(seat, now, 'playerForfeit');
    }

    private dropSeat(
        seat: number,
        now: number,
        _reason: 'timeoutForfeit' | 'playerForfeit',
    ): ApplyResult {
        this.s.participation[seat] = 'dropped';
        // Remove unfinished pawns from track/home lane: they no longer capture or block.
        // Finished pawns stay finished; yard pawns stay put in the desaturated yard.
        for (let t = 0; t < this.s.tokens[seat].length; t++) {
            const p = this.s.tokens[seat][t];
            if ((p >= 0 && p < TRACK_COUNT) || (p >= HOME_LANE_BASE && p < FINISHED)) {
                this.s.tokens[seat][t] = YARD;
            }
        }
        this.commitAction('drop', now, { actorSeat: seat });

        const remaining = activeSeats(this.s);
        if (remaining.length <= 1) {
            // Duel: the remaining player wins by the reason the seat left. Four-player: a
            // lone survivor wins by lastActive.
            const terminalReason =
                this.s.mode === 'duel' ? _reason : remaining.length === 1 ? 'lastActive' : _reason;
            return this.finish(remaining[0] ?? null, terminalReason, now, false);
        }
        return this.endTurn(now, {});
    }

    // --- Input ---------------------------------------------------------------------------

    applyInput(playerId: string, input: GameInput): ApplyResult {
        const now = Date.now();
        if (typeof input.presence === 'boolean') return { accepted: true, silent: true };
        if (input.forfeit === true) return this.forfeit(playerId, now);

        const seat = this.s.players.indexOf(playerId);
        if (seat === -1) return { accepted: false, rejection: 'NOT_A_PLAYER' };
        if (this.s.status !== 'active') return { accepted: false, rejection: 'MATCH_NOT_ACTIVE' };

        const serialOk =
            typeof input.turnSerial === 'number' && input.turnSerial === this.s.turnSerial;
        if (seat !== this.s.activeSeat || !serialOk) {
            return { accepted: false, rejection: 'NOT_YOUR_TURN' };
        }

        if (input.roll === true) return this.roll(seat, now, false);
        if (typeof input.move === 'number') return this.move(seat, input, now, false);
        return { accepted: false };
    }

    private timingReject(now: number): ApplyResult | null {
        if (this.s.opensAt !== null && now < this.s.opensAt) {
            return { accepted: false, rejection: 'TOO_EARLY' };
        }
        if (this.s.deadlineAt !== null && now > this.s.deadlineAt) {
            return { accepted: false, rejection: 'DEADLINE_PASSED' };
        }
        return null;
    }

    private roll(seat: number, now: number, auto: boolean): ApplyResult {
        if (this.s.phase !== 'awaitingRoll') {
            return { accepted: false, rejection: 'PHASE_MISMATCH' };
        }
        if (!auto) {
            const gate = this.timingReject(now);
            if (gate) return gate;
        }
        if (auto) this.s.turnHadAutoAction = true;

        const value = this.rng.next();
        const rollId = randomUUID();
        this.s.rollId = rollId;
        this.s.rollValue = value;
        this.s.automated = auto;

        // THREE CONSECUTIVE SIXES FORFEIT THE THIRD ROLL (§5.2 r6): the value is displayed,
        // no pawn moves for it, prior moves remain, play passes clockwise. The streak resets
        // because the seat is handing off regardless.
        if (value === 6) this.s.sixStreak += 1;
        if (this.s.sixStreak >= 3) {
            this.s.sixStreak = 0;
            return this.passAfterRoll(seat, now, rollId, value, auto);
        }

        const legal = legalMoves(this.s, seat, value);

        if (legal.length === 0) {
            // Show the roll, wait for its landing animation, then pass automatically (§5.2 r7).
            // There is no pass button.
            this.s.sixStreak = 0;
            return this.passAfterRoll(seat, now, rollId, value, auto);
        }

        this.s.legalTokenIds = legal;

        if (auto) {
            // Atomic timeout auto-turn (§13): commit the roll AND the deterministic move in ONE
            // accepted transition. An absent player never consumes a second 30-second wait.
            this.s.phase = 'awaitingMove';
            this.s.opensAt = now; // the decision window is not reopening; auto skips gates anyway
            const tokenId = pickAutoMove(this.s, seat, value, legal)!;
            return this.move(seat, { move: tokenId, rollId }, now, true);
        }

        this.s.phase = 'awaitingMove';
        // Awaiting move starts when the mandatory die animation is expected to settle (§13):
        // moveOpensAt = rollCommittedAt + 940.
        const moveOpensAt = now + ROLL_SETTLE_MS;
        this.s.opensAt = moveOpensAt;
        this.s.deadlineAt = moveOpensAt + TURN_WINDOW_MS;
        this.commitAction(auto ? 'autoTurn' : 'roll', now, {
            actorSeat: seat,
            presentationEndsAt: moveOpensAt,
            roll: { rollId, value, auto },
        });
        return { accepted: true };
    }

    /** A roll whose value cannot be used: display it, settle the die, pass clockwise. */
    private passAfterRoll(
        seat: number,
        now: number,
        rollId: string,
        value: number,
        auto: boolean,
    ): ApplyResult {
        this.s.rollValue = null;
        this.s.rollId = null;
        this.s.legalTokenIds = [];
        return this.endTurn(now, {
            roll: { rollId, value, auto },
            // No-legal-move six (or any unusable face): next seat opens at +940 + 480 (§15).
            opensAt: now + ROLL_SETTLE_MS + TRANSITION_MS,
            presentationEndsAt: now + ROLL_SETTLE_MS,
            type: auto ? 'autoTurn' : 'roll',
            actorSeat: seat,
        });
    }

    private move(seat: number, input: GameInput, now: number, auto: boolean): ApplyResult {
        if (this.s.phase !== 'awaitingMove') {
            return { accepted: false, rejection: 'PHASE_MISMATCH' };
        }
        if (typeof input.rollId !== 'string' || input.rollId !== this.s.rollId) {
            return { accepted: false, rejection: 'ROLL_MISMATCH' };
        }
        if (!auto) {
            const gate = this.timingReject(now);
            if (gate) return gate;
        }
        const token = input.move as number;
        if (!Number.isInteger(token) || !this.s.legalTokenIds.includes(token)) {
            return { accepted: false, rejection: 'ILLEGAL_MOVE' };
        }
        const die = this.s.rollValue;
        if (die === null) return { accepted: false, rejection: 'PHASE_MISMATCH' };
        if (auto) this.s.turnHadAutoAction = true;

        const from = this.s.tokens[seat][token];
        const to = destination(from, die, seat);
        if (to === null) return { accepted: false, rejection: 'ILLEGAL_MOVE' };

        const route = path(from, die, seat);
        this.s.tokens[seat][token] = to;

        // Capture resolves AFTER movement lands (§5.3). At most one opponent pawn can be
        // captured, because landing on an opponent block was already illegal.
        let capturedPayload:
            | NonNullable<NonNullable<LastAction['move']>['captured']>
            | null = null;
        const cap = resolveCapture(this.s, seat, to);
        if (cap) {
            const capFrom = this.s.tokens[cap.seat][cap.tokenId];
            this.s.tokens[cap.seat][cap.tokenId] = YARD; // back to its ORIGINAL yard slot
            this.s.captures[seat] += 1;
            capturedPayload = {
                seat: cap.seat, tokenId: cap.tokenId, from: capFrom, to: YARD,
            };
        }

        const finished = finishedPawns(this.s, seat) === TOKENS_PER_SEAT;
        const extraMs = cap ? CAPTURE_EXTRA_MS : finished ? FINISH_EXTRA_MS : 0;
        const presentationEndsAt = now + hopMs(route.length) + extraMs;

        const actionType: ActionType = finished ? 'move' : cap ? 'capture' : auto ? 'autoTurn' : 'move';
        this.commitAction(actionType, now, {
            actorSeat: seat,
            presentationEndsAt,
            roll: this.s.rollId ? { rollId: this.s.rollId, value: die, auto } : undefined,
            move: { tokenId: token, from, to, path: route, captured: capturedPayload },
        });

        if (finished) return this.finish(seat, 'win', now, true);

        // A six grants ONE extra roll after the resulting move (§5.2 r5); capturing and
        // finishing do not grant extra rolls. The extra roll opens 120 ms after the mandatory
        // presentation ends (§12.3).
        if (die === 6) {
            this.s.phase = 'awaitingRoll';
            this.s.rollValue = null;
            this.s.rollId = null;
            this.s.legalTokenIds = [];
            this.s.opensAt = presentationEndsAt + 120;
            this.s.deadlineAt = this.s.opensAt + TURN_WINDOW_MS;
            return { accepted: true };
        }

        return this.endTurn(now, {
            preservePresentation: true,
            opensAt: presentationEndsAt + TRANSITION_MS,
        });
    }

    /**
     * Hand the turn to the next active seat, applying the timeout-streak rule (§13).
     *
     * `preservePresentation` keeps the just-committed move/capture action as THE action for
     * this transition and stamps the seat handoff onto it — one seq step, one action, both
     * facts. Otherwise a fresh `turnChanged` (optionally embedding the displayed roll) is
     * committed.
     */
    private endTurn(
        now: number,
        opts: {
            preservePresentation?: boolean;
            opensAt?: number;
            presentationEndsAt?: number;
            roll?: { rollId: string; value: number; auto: boolean };
            type?: ActionType;
            actorSeat?: number;
        },
    ): ApplyResult {
        const outgoing = this.s.activeSeat;
        if (this.s.turnHadAutoAction) {
            this.s.timeoutStreak[outgoing] += 1;
        } else {
            this.s.timeoutStreak[outgoing] = 0;
        }
        this.s.turnHadAutoAction = false;
        this.s.automated = false;
        this.s.rollValue = null;
        this.s.rollId = null;
        this.s.legalTokenIds = [];
        this.s.sixStreak = 0;

        if (this.s.timeoutStreak[outgoing] >= 3) {
            // At three consecutive timed-out turns, mark the seat dropped BEFORE selecting
            // the next active seat (§13).
            return this.dropSeat(outgoing, now, 'timeoutForfeit');
        }

        const next = nextActiveSeat(this.s, outgoing);
        const opensAt = Math.max(opts.opensAt ?? now, now + TRANSITION_MS);
        this.s.activeSeat = next;
        this.s.turnSerial += 1;
        this.s.phase = 'awaitingRoll';
        this.s.opensAt = opensAt;
        this.s.deadlineAt = opensAt + TURN_WINDOW_MS;

        if (opts.preservePresentation && this.s.lastAction) {
            this.s.lastAction.fromSeat = outgoing;
            this.s.lastAction.actorSeat = next;
            this.s.lastAction.presentationEndsAt = opts.presentationEndsAt
                ?? this.s.lastAction.presentationEndsAt;
        } else {
            this.commitAction(opts.type ?? 'turnChanged', now, {
                actorSeat: next,
                fromSeat: outgoing,
                presentationEndsAt: opts.presentationEndsAt ?? opensAt - TRANSITION_MS,
                ...(opts.roll ? { roll: opts.roll } : {}),
            });
        }
        return { accepted: true };
    }

    /**
     * Terminal transition. `preserveLastAction` keeps the winning move as the frame's action
     * so every client can finish presenting it before the result sheet; otherwise (drops,
     * integrity ends) an explicit `end` action is committed.
     */
    private finish(
        winnerSeat: number | null,
        endReason: string,
        now: number,
        preserveLastAction: boolean,
    ): ApplyResult {
        if (!preserveLastAction) {
            this.commitAction('end', now, { actorSeat: winnerSeat ?? -1 });
        }
        if (winnerSeat !== null) this.s.participation[winnerSeat] = 'winner';
        this.s.winnerSeat = winnerSeat;
        this.s.endReason = endReason;
        this.s.status = 'finished';
        this.s.phase = 'none';
        this.s.deadlineAt = null;
        this.s.rollValue = null;
        this.s.rollId = null;
        this.s.legalTokenIds = [];
        return { accepted: true, outcome: this.outcome() };
    }

    private outcome(): GameOutcome {
        if (this.s.winnerSeat === null) return { winnerId: null, scores: {} };
        const scores: Record<string, number> = {};
        for (let s = 0; s < MAX_SEATS; s++) {
            const uid = this.s.players[s];
            if (uid === null) continue;
            scores[uid] = finishedPawns(this.s, s);
        }
        return { winnerId: this.s.players[this.s.winnerSeat], scores };
    }

    private commitAction(
        type: ActionType,
        committedAt: number,
        rest: Partial<LastAction>,
    ): void {
        this.s.actionCounter += 1;
        this.s.lastAction = {
            id: String(this.s.actionCounter),
            type,
            committedAt,
            presentationEndsAt: committedAt,
            actorSeat: this.s.activeSeat,
            ...rest,
        };
    }

    // --- Deadlines -----------------------------------------------------------------------

    deadlineAt(): number | null {
        if (this.s.status !== 'active') return null;
        return this.s.deadlineAt;
    }

    /** Server timeout: auto-play, never an instant loss (§13). */
    onTimeout(): ApplyResult {
        const now = Date.now();
        if (this.s.status !== 'active' || this.s.deadlineAt === null) return { accepted: false };
        if (now < this.s.deadlineAt) return { accepted: false };
        const seat = this.s.activeSeat;
        if (this.s.phase === 'awaitingRoll') return this.roll(seat, now, true);
        if (
            this.s.phase === 'awaitingMove' &&
            this.s.legalTokenIds.length > 0 &&
            this.s.rollId !== null &&
            this.s.rollValue !== null
        ) {
            const tokenId = pickAutoMove(this.s, seat, this.s.rollValue, this.s.legalTokenIds)!;
            return this.move(seat, { move: tokenId, rollId: this.s.rollId }, now, true);
        }
        return { accepted: false };
    }

    // --- Serialization -------------------------------------------------------------------

    serialize(): GameStatePayload {
        // Persisted ONLY — Redis/Postgres and restore(). Raw user ids ride along because
        // sparse duel seats cannot be rebuilt from game_matches.player_ids alone. Clients
        // NEVER receive this object: Ludo always broadcasts through serializeForPlayer().
        return { ludo: this.s };
    }

    serializeSecret(): GameStatePayload {
        return {
            ludo: {
                rng: this.rng.state,
                players: this.s.players,
                accepted: this.s.accepted,
            },
        };
    }

    /**
     * Per-recipient projection (§6, §11.2). displayName comes from the frame context the
     * runtime supplies; an unauthorized viewer sees neutral labels because the runtime never
     * puts a real name in the map. Raw ids and the RNG never appear here.
     */
    serializeForPlayer(playerId: string): GameStatePayload {
        const ctx = this.ctx ?? { serverNow: Date.now(), connections: {}, names: {} };
        const viewerSeat = this.s.players.indexOf(playerId);
        const seats: SeatView[] = [];
        for (let seat = 0; seat < MAX_SEATS; seat++) {
            const uid = this.s.players[seat];
            if (uid === null) continue;
            seats.push({
                seat,
                seatId: opaqueSeatId(this.matchKey, seat),
                color: SEAT_COLORS[seat],
                displayName: ctx.names[uid] ?? `Player ${seat + 1}`,
                participation: this.s.participation[seat],
                connection:
                    this.s.participation[seat] === 'dropped'
                        ? 'disconnected'
                        : // Unknown presence projects as disconnected — never invent liveness.
                        (ctx.connections[uid] ?? 'disconnected'),
                timeoutStreak: this.s.timeoutStreak[seat],
                finishedPawns: finishedPawns(this.s, seat),
                captures: this.s.captures[seat],
            });
        }

        const payload: LudoPublicState = {
            schemaVersion: SCHEMA_VERSION,
            rulesVersion: RULES_VERSION,
            mode: this.s.mode,
            status: this.s.status,
            serverNow: ctx.serverNow,
            viewerSeat: viewerSeat === -1 ? null : viewerSeat,
            seats,
            tokensPerSeat: TOKENS_PER_SEAT,
            tokens: this.s.tokens.map((row) => [...row]),
            turn:
                this.s.status === 'active'
                    ? {
                          seat: this.s.activeSeat,
                          serial: this.s.turnSerial,
                          phase: this.s.phase,
                          opensAt: this.s.opensAt ?? ctx.serverNow,
                          deadlineAt:
                              this.s.deadlineAt ?? (this.s.opensAt ?? ctx.serverNow) + TURN_WINDOW_MS,
                          sixStreak: this.s.sixStreak,
                          rollId: this.s.rollId,
                          value: this.s.rollValue,
                          legalTokenIds: [...this.s.legalTokenIds],
                          automated: this.s.automated,
                      }
                    : null,
            lastAction: this.s.lastAction,
            winnerSeat: this.s.winnerSeat,
            endReason: this.s.endReason,
            seedCommitment: this.rng.commitment(),
        };
        return { ludoV2: payload };
    }

    isFinished(): boolean {
        return this.s.status === 'finished' || this.s.status === 'abandoned';
    }
}

/** Tombstone for a pre-v2 state: the match is abandoned with a clear version reason. */
class LegacyAbandonEngine implements GameEngine {
    constructor(private reason: string) {}
    applyInput(): ApplyResult {
        return { accepted: false };
    }
    serialize(): GameStatePayload {
        return { legacyAbandoned: this.reason };
    }
    deadlineAt(): number | null {
        return null;
    }
    onTimeout(): ApplyResult {
        return { accepted: false };
    }
    isFinished(): boolean {
        return true;
    }
}

export const ludo = {
    slug: 'ludo',
    create(playerIds: string[], options?: Record<string, unknown>): GameEngine {
        const rawMode = options?.mode;
        const mode: LudoMode =
            rawMode === 'duel' || rawMode === 'four'
                ? rawMode
                : playerIds.length <= 2
                    ? 'duel'
                    : 'four';

        // Test hook: a fixed hex seed makes dice sequences reproducible in CI.
        const seedOpt = options?.rngSeed;
        const rng =
            typeof seedOpt === 'string' && /^[0-9a-f]{64}$/.test(seedOpt)
                ? DiceRng.fromState({ seed: seedOpt, counter: 0 })!
                : DiceRng.generate();

        // Seat assignment is SERVER-SHUFFLED so the creator does not always receive red
        // (§5.4). A duel occupies opposite seats: red (0) and yellow (2).
        const players: (string | null)[] = [null, null, null, null];
        const seatsToFill = mode === 'duel' ? [0, 2] : [0, 1, 2, 3];
        const shuffled = [...seatsToFill];
        for (let i = shuffled.length - 1; i > 0; i--) {
            const j = Math.floor(rng.next()) % (i + 1);
            [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
        }
        playerIds.slice(0, shuffled.length).forEach((uid, i) => {
            players[shuffled[i]] = uid;
        });

        const tokens: number[][] = [];
        for (let s = 0; s < MAX_SEATS; s++) {
            tokens.push(players[s] !== null ? Array(TOKENS_PER_SEAT).fill(YARD) : []);
        }

        const state: LudoStateV2 = {
            schemaVersion: SCHEMA_VERSION,
            rulesVersion: RULES_VERSION,
            mode,
            status: 'waiting',
            started: false,
            players,
            accepted: [false, false, false, false],
            participation: Array(MAX_SEATS).fill('waiting') as LudoStateV2['participation'],
            timeoutStreak: [0, 0, 0, 0],
            captures: [0, 0, 0, 0],
            tokens,
            startedByRng: false,
            firstSeatChosen: false,
            activeSeat: 0,
            turnSerial: 0,
            phase: 'none',
            opensAt: null,
            deadlineAt: null,
            sixStreak: 0,
            rollId: null,
            rollValue: null,
            legalTokenIds: [],
            automated: false,
            turnHadAutoAction: false,
            actionCounter: 0,
            lastAction: null,
            winnerSeat: null,
            endReason: null,
        };
        return new LudoEngineV2(state, rng, randomUUID());
    },

    restore(state: GameStatePayload, secret?: GameStatePayload): GameEngine {
        const inner = (state as { ludo?: unknown }).ludo as LudoStateV2 | undefined;
        if (
            !inner ||
            inner.schemaVersion !== SCHEMA_VERSION ||
            inner.rulesVersion !== RULES_VERSION
        ) {
            // Preserve v1 rows only long enough to abandon them with a clear reason (§20 P1);
            // ambiguous live rules are never converted mid-match.
            console.error('[ludo] legacy/incompatible state on restore — abandoning match');
            return new LegacyAbandonEngine('schemaVersionMismatch');
        }

        const secretInner = (secret as { ludo?: unknown } | undefined)?.ludo as
            | { rng?: unknown; players?: unknown; accepted?: unknown }
            | undefined;
        const rng = DiceRng.fromState(
            (secretInner?.rng ?? {}) as { seed?: unknown; counter?: unknown },
        );
        if (!rng) {
            // IF RNG SECRET STATE IS MISSING, ABANDON — never reseed and continue silently (§16).
            console.error('[ludo] RNG secret state missing on restore — abandoning match');
            inner.status = 'abandoned';
            inner.endReason = 'serverIntegrityError';
            inner.phase = 'none';
            inner.deadlineAt = null;
            return new LudoEngineV2(inner, DiceRng.generate(), randomUUID());
        }

        if (Array.isArray(secretInner?.players)) {
            inner.players = (secretInner.players as (string | null)[]).map((p) =>
                typeof p === 'string' || p === null ? p : null,
            );
        }
        if (Array.isArray(secretInner?.accepted)) {
            inner.accepted = (secretInner.accepted as boolean[]).map((b) => b === true);
        }

        return new LudoEngineV2(inner, rng, randomUUID());
    },
};
