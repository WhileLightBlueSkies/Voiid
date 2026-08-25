import { randomUUID } from 'node:crypto';
import type { ApplyResult, GameEngine, GameInput, GameOutcome, GameStatePayload } from '../GameEngine';
import {
    FINISHED, MAX_SEATS, SEAT_COLORS, TOKENS_PER_SEAT, YARD, destination, isSafe, path,
} from './board';
import { activeSeats, finishedPawns, legalMoves, nextActiveSeat, resolveCapture } from './rules';
import { pickTimeoutMove } from './autoplay';
import { selectBotMove } from './bot/policy';
import { botDelay } from './bot/scheduler';
import { botName } from './bot/names';
import { DiceRng } from './rng';
import {
    BOT_POLICY_VERSION, RULES_VERSION, SCHEMA_VERSION,
    type ActionType, type BotDifficulty, type ControllerType, type EndReason,
    type LastAction, type LegalMoveView, type LudoMode, type LudoPublicState,
    type LudoStateV3, type RosterEntry, type SeatView, type ViewerRole,
} from './types';

export const TRANSITION_MS = 480;
export const FIRST_TURN_MS = 120;
export const ROLL_SETTLE_MS = 940;
export const TURN_WINDOW_MS = 30_000;
export const hopMs = (n: number) => n === 0 ? 0 : 120 + 92 * (n - 1);
const CAPTURE_EXTRA_MS = 480;
const FINISH_EXTRA_MS = 550;

export interface FrameContext {
    serverNow: number;
    seq?: number;
    connections: Record<string, 'connected' | 'disconnected'>;
    names: Record<string, string>;
}

function opaqueSeatId(matchKey: string, seat: number): string {
    return `seat-${matchKey.slice(0, 8)}-${seat}`;
}
function difficulty(value: unknown): BotDifficulty {
    return value === 'relaxed' || value === 'sharp' ? value : 'balanced';
}

class LudoEngineV3 implements GameEngine {
    private ctx: FrameContext | null = null;

    constructor(
        private s: LudoStateV3,
        private rng: DiceRng,
        private pacingCounter: number,
        private matchKey: string,
    ) {}

    setFrameContext(ctx: FrameContext): void { this.ctx = ctx; }

    accept(userId: string): boolean {
        const seat = this.s.humanUserIds.indexOf(userId);
        if (seat >= 0) this.s.accepted[seat] = true;
        return this.allAccepted();
    }
    allAccepted(): boolean {
        return this.s.assigned.every((assigned, seat) => !assigned || this.s.accepted[seat]);
    }
    startAll(now: number): void {
        if (this.s.started || this.s.status !== 'waiting' || !this.allAccepted()) return;
        for (let seat = 0; seat < MAX_SEATS; seat++) {
            if (this.s.assigned[seat]) this.s.participation[seat] = 'active';
        }
        const seats = activeSeats(this.s);
        if (seats.length === 0) return;
        const first = seats[(this.rng.next() - 1) % seats.length];
        this.s.started = true;
        this.s.startedAt = now;
        this.s.status = 'active';
        this.s.activeSeat = first;
        this.s.turnSerial = 1;
        this.s.phase = 'awaitingRoll';
        this.s.opensAt = now + FIRST_TURN_MS;
        this.openDecision(first, this.s.opensAt);
        this.commitAction('turnChanged', now, { actorSeat: first, presentationEndsAt: this.s.opensAt });
    }

    applyInput(playerId: string, input: GameInput): ApplyResult {
        const now = Date.now();
        if (typeof input.presence === 'boolean') return { accepted: true, silent: true };
        if (input.forfeit === true) return this.forfeit(playerId, now);
        const seat = this.s.humanUserIds.indexOf(playerId);
        if (seat < 0 && this.s.formerControllerUserIds.includes(playerId)) {
            return { accepted: false, rejection: 'NOT_SEAT_CONTROLLER' };
        }
        if (seat < 0) return { accepted: false, rejection: 'NOT_A_PLAYER' };
        if (this.s.controller[seat] !== 'human') return { accepted: false, rejection: 'NOT_SEAT_CONTROLLER' };
        if (this.s.status !== 'active') return { accepted: false, rejection: 'MATCH_NOT_ACTIVE' };
        if (seat !== this.s.activeSeat || input.turnSerial !== this.s.turnSerial) {
            return { accepted: false, rejection: 'NOT_YOUR_TURN' };
        }
        if (input.roll === true) return this.roll(seat, now, false, false);
        if (typeof input.move === 'number') return this.move(seat, input, now, false, 0);
        return { accepted: false };
    }

    forfeit(userId: string, now: number): ApplyResult {
        const seat = this.s.humanUserIds.indexOf(userId);
        if (seat < 0 || this.s.controller[seat] !== 'human') {
            return { accepted: false, rejection: seat < 0 ? 'NOT_A_PLAYER' : 'NOT_SEAT_CONTROLLER' };
        }
        if (this.s.status !== 'active') return { accepted: false, rejection: 'MATCH_NOT_ACTIVE' };
        if (this.s.mode === 'duel') {
            const winner = activeSeats(this.s).find((candidate) => candidate !== seat) ?? null;
            return this.finish(winner, 'duelForfeit', now, false);
        }
        this.installTakeover(seat, now);
        if (seat === this.s.activeSeat) this.openDecision(seat, Math.max(now, this.s.opensAt ?? now));
        return { accepted: true };
    }

    private timingReject(now: number): ApplyResult | null {
        if (this.s.opensAt !== null && now < this.s.opensAt) return { accepted: false, rejection: 'TOO_EARLY' };
        if (this.s.deadlineAt !== null && now > this.s.deadlineAt) return { accepted: false, rejection: 'DEADLINE_PASSED' };
        return null;
    }

    private roll(seat: number, now: number, timeout: boolean, bot: boolean): ApplyResult {
        if (this.s.phase !== 'awaitingRoll') return { accepted: false, rejection: 'PHASE_MISMATCH' };
        if (!timeout && !bot) { const gate = this.timingReject(now); if (gate) return gate; }
        if (timeout) this.s.turnHadAutoAction = true;
        const value = this.rng.next();
        const rollId = randomUUID();
        this.s.rollId = rollId;
        this.s.rollValue = value;
        this.s.automated = timeout;
        if (value === 6) this.s.sixStreak += 1; else this.s.sixStreak = 0;

        if (this.s.sixStreak >= 3) {
            this.s.sixStreak = 0;
            return this.passAfterRoll(seat, now, rollId, value, timeout);
        }

        const legal = legalMoves(this.s, seat, value);
        this.s.legalTokenIds = legal;
        if (legal.length === 0) {
            if (value === 6) {
                const opensAt = now + ROLL_SETTLE_MS + 120;
                this.s.phase = 'awaitingRoll';
                this.s.rollId = null;
                this.s.rollValue = null;
                this.s.legalTokenIds = [];
                this.s.opensAt = opensAt;
                this.openDecision(seat, opensAt);
                this.commitAction('roll', now, {
                    actorSeat: seat, presentationEndsAt: now + ROLL_SETTLE_MS,
                    roll: { rollId, value, auto: timeout },
                });
                return { accepted: true };
            }
            return this.passAfterRoll(seat, now, rollId, value, timeout);
        }

        this.s.phase = 'awaitingMove';
        const moveOpensAt = now + ROLL_SETTLE_MS;
        this.s.opensAt = moveOpensAt;
        if (timeout) {
            const tokenId = pickTimeoutMove(this.s, seat, value, legal)!;
            return this.move(seat, { move: tokenId, rollId }, now, true, ROLL_SETTLE_MS);
        }
        if (bot) {
            this.openDecision(seat, moveOpensAt);
        } else {
            this.s.deadlineAt = moveOpensAt + TURN_WINDOW_MS;
            this.s.botActionAt = null;
        }
        this.commitAction('roll', now, {
            actorSeat: seat, presentationEndsAt: moveOpensAt,
            roll: { rollId, value, auto: false },
        });
        return { accepted: true };
    }

    private passAfterRoll(seat: number, now: number, rollId: string, value: number, auto: boolean): ApplyResult {
        this.s.rollId = null; this.s.rollValue = null; this.s.legalTokenIds = [];
        return this.endTurn(now, {
            type: auto ? 'autoTurn' : 'roll', actorSeat: seat,
            roll: { rollId, value, auto },
            presentationEndsAt: now + ROLL_SETTLE_MS,
            opensAt: now + ROLL_SETTLE_MS + TRANSITION_MS,
        });
    }

    private move(seat: number, input: GameInput, now: number, timeout: boolean, rollLeadMs: number): ApplyResult {
        if (this.s.phase !== 'awaitingMove') return { accepted: false, rejection: 'PHASE_MISMATCH' };
        if (typeof input.rollId !== 'string' || input.rollId !== this.s.rollId) {
            return { accepted: false, rejection: 'ROLL_MISMATCH' };
        }
        if (!timeout && this.s.controller[seat] === 'human') {
            const gate = this.timingReject(now); if (gate) return gate;
        }
        const tokenId = input.move as number;
        const die = this.s.rollValue;
        const recomputed = die === null ? [] : legalMoves(this.s, seat, die);
        if (!Number.isInteger(tokenId) || die === null || !recomputed.includes(tokenId)) {
            return { accepted: false, rejection: 'ILLEGAL_MOVE' };
        }
        if (timeout) this.s.turnHadAutoAction = true;
        const from = this.s.tokens[seat][tokenId];
        const to = destination(from, die, seat)!;
        const route = path(from, die, seat);
        this.s.tokens[seat][tokenId] = to;
        let capturedPayload: NonNullable<LastAction['move']>['captured'] = null;
        const captured = resolveCapture(this.s, seat, to);
        if (captured) {
            const capFrom = this.s.tokens[captured.seat][captured.tokenId];
            this.s.tokens[captured.seat][captured.tokenId] = YARD;
            this.s.captures[seat] += 1;
            capturedPayload = { ...captured, from: capFrom, to: YARD };
        }
        const pawnFinished = to === FINISHED;
        const matchFinished = finishedPawns(this.s, seat) === TOKENS_PER_SEAT;
        const moveMs = from === YARD ? 360 : hopMs(route.length);
        const extraMs = captured ? CAPTURE_EXTRA_MS : pawnFinished ? FINISH_EXTRA_MS : 0;
        const presentationEndsAt = now + rollLeadMs + moveMs + extraMs;
        const actionType: ActionType = timeout ? 'autoTurn' : captured ? 'capture' : 'move';
        this.commitAction(actionType, now, {
            actorSeat: seat, presentationEndsAt,
            roll: this.s.rollId ? { rollId: this.s.rollId, value: die, auto: timeout } : undefined,
            move: { tokenId, from, to, path: route, captured: capturedPayload },
        });
        if (matchFinished) return this.finish(seat, 'allPawnsHome', now, true);
        if (die === 6) {
            this.s.phase = 'awaitingRoll'; this.s.rollId = null; this.s.rollValue = null;
            this.s.legalTokenIds = []; this.s.opensAt = presentationEndsAt + 120;
            this.openDecision(seat, this.s.opensAt);
            return { accepted: true };
        }
        return this.endTurn(now, { preservePresentation: true, opensAt: presentationEndsAt + TRANSITION_MS });
    }

    private endTurn(now: number, opts: {
        preservePresentation?: boolean; opensAt: number; presentationEndsAt?: number;
        roll?: { rollId: string; value: number; auto: boolean }; type?: ActionType; actorSeat?: number;
    }): ApplyResult {
        const outgoing = this.s.activeSeat;
        this.s.timeoutStreak[outgoing] = this.s.turnHadAutoAction ? this.s.timeoutStreak[outgoing] + 1 : 0;
        const takeover = this.s.controller[outgoing] === 'human' && this.s.timeoutStreak[outgoing] >= 3;
        this.s.turnHadAutoAction = false; this.s.automated = false; this.s.rollValue = null;
        this.s.rollId = null; this.s.legalTokenIds = []; this.s.sixStreak = 0;
        const next = nextActiveSeat(this.s, outgoing);
        this.s.activeSeat = next; this.s.turnSerial += 1; this.s.phase = 'awaitingRoll';
        this.s.opensAt = Math.max(opts.opensAt, now + TRANSITION_MS);
        this.openDecision(next, this.s.opensAt);

        if (takeover) {
            this.installTakeover(outgoing, now, false);
            const previous = this.s.lastAction;
            this.commitAction('controllerChanged', now, {
                actorSeat: next, fromSeat: outgoing,
                presentationEndsAt: previous?.presentationEndsAt ?? (this.s.opensAt - TRANSITION_MS),
                roll: previous?.roll, move: previous?.move,
            });
        } else if (opts.preservePresentation && this.s.lastAction) {
            this.s.lastAction.fromSeat = outgoing;
            this.s.lastAction.actorSeat = next;
        } else {
            this.commitAction(opts.type ?? 'turnChanged', now, {
                actorSeat: next, fromSeat: outgoing,
                presentationEndsAt: opts.presentationEndsAt ?? this.s.opensAt - TRANSITION_MS,
                ...(opts.roll ? { roll: opts.roll } : {}),
            });
        }
        return { accepted: true };
    }

    private installTakeover(seat: number, now: number, commit = true): void {
        const former = this.s.humanUserIds[seat];
        if (former) this.s.formerControllerUserIds[seat] = former;
        this.s.controller[seat] = 'bot';
        this.s.botDifficulty[seat] = 'balanced';
        this.s.botPolicyVersion[seat] = BOT_POLICY_VERSION;
        this.s.timeoutStreak[seat] = 0;
        const used = new Set(this.s.botNames.filter((name): name is string => !!name));
        this.s.botNames[seat] = botName(this.rng.seedHex, seat, used);
        if (commit) this.commitAction('controllerChanged', now, { actorSeat: seat, presentationEndsAt: now + 160 });
    }

    private openDecision(seat: number, opensAt: number): void {
        if (this.s.controller[seat] === 'bot') {
            this.s.deadlineAt = null;
            const tier = this.s.botDifficulty[seat] ?? 'balanced';
            this.s.botActionAt = opensAt + botDelay(this.rng.seedHex, this.pacingCounter++, tier,
                this.s.phase === 'awaitingMove' ? 'awaitingMove' : 'awaitingRoll');
        } else {
            this.s.botActionAt = null;
            this.s.deadlineAt = opensAt + TURN_WINDOW_MS;
        }
    }

    private finish(winnerSeat: number | null, reason: EndReason, now: number, preserve: boolean): ApplyResult {
        if (!preserve) this.commitAction('end', now, { actorSeat: winnerSeat ?? -1 });
        if (winnerSeat !== null) this.s.participation[winnerSeat] = 'winner';
        this.s.winnerSeat = winnerSeat;
        this.s.winnerController = winnerSeat === null ? null : this.s.controller[winnerSeat];
        this.s.winnerUserId = winnerSeat === null || this.s.controller[winnerSeat] === 'bot'
            ? null : this.s.humanUserIds[winnerSeat];
        this.s.endReason = reason; this.s.status = reason === 'serverIntegrityError' || reason === 'legacyVersionAbandoned'
            ? 'abandoned' : 'finished';
        this.s.phase = 'none'; this.s.deadlineAt = null; this.s.botActionAt = null;
        this.s.rollId = null; this.s.rollValue = null; this.s.legalTokenIds = [];
        return { accepted: true, outcome: this.outcome() };
    }

    private outcome(): GameOutcome {
        const scores: Record<string, number> = {};
        for (let seat = 0; seat < MAX_SEATS; seat++) {
            const uid = this.s.humanUserIds[seat]; if (uid) scores[uid] = finishedPawns(this.s, seat);
        }
        return { winnerId: this.s.winnerUserId, scores };
    }

    private commitAction(type: ActionType, committedAt: number, rest: Partial<LastAction>): void {
        this.s.actionCounter += 1;
        this.s.lastAction = { id: String(this.s.actionCounter), type, committedAt,
            presentationEndsAt: committedAt, actorSeat: this.s.activeSeat, ...rest };
    }

    deadlineAt(): number | null {
        if (this.s.status !== 'active') return null;
        return this.s.deadlineAt ?? this.s.botActionAt;
    }
    onTimeout(): ApplyResult {
        const now = Date.now();
        if (this.s.status !== 'active') return { accepted: false };
        const seat = this.s.activeSeat;
        if (this.s.controller[seat] === 'bot') {
            if (this.s.botActionAt === null || now < this.s.botActionAt) return { accepted: false };
            if (this.s.phase === 'awaitingRoll') return this.roll(seat, now, false, true);
            if (this.s.phase === 'awaitingMove' && this.s.rollId && this.s.rollValue !== null) {
                const legal = legalMoves(this.s, seat, this.s.rollValue);
                const token = selectBotMove(this.s, seat, this.s.rollValue, legal, this.s.botDifficulty[seat] ?? 'balanced');
                if (token === null) return { accepted: false };
                return this.move(seat, { move: token, rollId: this.s.rollId }, now, false, 0);
            }
            return { accepted: false };
        }
        if (this.s.deadlineAt === null || now < this.s.deadlineAt) return { accepted: false };
        if (this.s.phase === 'awaitingRoll') return this.roll(seat, now, true, false);
        if (this.s.phase === 'awaitingMove' && this.s.rollId && this.s.rollValue !== null) {
            const legal = legalMoves(this.s, seat, this.s.rollValue);
            const token = pickTimeoutMove(this.s, seat, this.s.rollValue, legal);
            return token === null ? { accepted: false } : this.move(seat, { move: token, rollId: this.s.rollId }, now, true, 0);
        }
        return { accepted: false };
    }

    serialize(): GameStatePayload { return { ludo: this.s }; }
    serializeSecret(): GameStatePayload { return { ludo: { rng: this.rng.state, pacingCounter: this.pacingCounter } }; }

    serializeForPlayer(playerId: string): GameStatePayload {
        const ctx = this.ctx ?? { serverNow: Date.now(), seq: 0, connections: {}, names: {} };
        const currentSeat = this.s.humanUserIds.findIndex((uid, seat) => uid === playerId && this.s.controller[seat] === 'human');
        const formerSeat = this.s.formerControllerUserIds.indexOf(playerId);
        const viewerSeat = currentSeat >= 0 ? currentSeat : formerSeat >= 0 ? formerSeat : null;
        const viewerRole: ViewerRole = currentSeat >= 0 ? 'controller' : formerSeat >= 0 ? 'formerController' : 'none';
        const seats: SeatView[] = [];
        for (let seat = 0; seat < MAX_SEATS; seat++) {
            if (!this.s.assigned[seat]) continue;
            const uid = this.s.humanUserIds[seat];
            const controller = this.s.controller[seat];
            seats.push({
                seat, seatId: opaqueSeatId(this.matchKey, seat), color: SEAT_COLORS[seat], controller,
                displayName: controller === 'bot' ? (this.s.botNames[seat] ?? `Bot ${seat + 1}`)
                    : uid ? (ctx.names[uid] ?? `Player ${seat + 1}`) : `Player ${seat + 1}`,
                botMarker: controller === 'bot' ? 'BOT' : null,
                botDifficulty: controller === 'bot' ? this.s.botDifficulty[seat] : null,
                participation: this.s.participation[seat],
                connection: controller === 'bot' ? 'connected' : uid ? (ctx.connections[uid] ?? 'disconnected') : 'disconnected',
                timeoutStreak: this.s.timeoutStreak[seat], finishedPawns: finishedPawns(this.s, seat),
                captures: this.s.captures[seat],
            });
        }
        const legalViews: LegalMoveView[] = this.s.phase === 'awaitingMove' && this.s.rollValue !== null
            ? this.s.legalTokenIds.map((tokenId) => {
                const from = this.s.tokens[this.s.activeSeat][tokenId];
                const to = destination(from, this.s.rollValue!, this.s.activeSeat)!;
                return { tokenId, to, path: path(from, this.s.rollValue!, this.s.activeSeat),
                    capture: resolveCapture(this.s, this.s.activeSeat, to), isSafe: isSafe(to) };
            }) : [];
        const payload: LudoPublicState = {
            schemaVersion: 3, rulesVersion: RULES_VERSION, mode: this.s.mode, status: this.s.status,
            seq: ctx.seq ?? 0, serverNow: ctx.serverNow, viewerSeat, viewerRole, seats,
            tokensPerSeat: 4, tokens: this.s.tokens.map((row) => [...row]),
            turn: this.s.status === 'active' && this.s.phase !== 'none' ? {
                seat: this.s.activeSeat, serial: this.s.turnSerial, phase: this.s.phase,
                opensAt: this.s.opensAt ?? ctx.serverNow, deadlineAt: this.s.deadlineAt,
                botActionAt: this.s.botActionAt, sixStreak: this.s.sixStreak, rollId: this.s.rollId,
                value: this.s.rollValue, legalMoves: legalViews, automated: this.s.automated,
            } : null,
            lastAction: this.s.lastAction, winnerSeat: this.s.winnerSeat, endReason: this.s.endReason,
            seedCommitment: this.rng.commitment(),
        };
        return { ludoV3: payload };
    }
    isFinished(): boolean { return this.s.status === 'finished' || this.s.status === 'abandoned'; }
}

class LegacyAbandonEngine implements GameEngine {
    applyInput(): ApplyResult { return { accepted: false, rejection: 'MATCH_NOT_ACTIVE' }; }
    serialize(): GameStatePayload { return { legacyAbandoned: 'legacyVersionAbandoned' }; }
    deadlineAt(): number | null { return null; }
    onTimeout(): ApplyResult { return { accepted: false }; }
    isFinished(): boolean { return true; }
}

function normalizedRoster(playerIds: string[], options?: Record<string, unknown>): RosterEntry[] {
    const raw = Array.isArray(options?.roster) ? options!.roster as Array<Record<string, unknown>> : [];
    if (raw.length === 2 || raw.length === 4) {
        return raw.map((entry) => entry.kind === 'bot'
            ? { kind: 'bot', difficulty: difficulty(entry.difficulty) }
            : { kind: 'human', userId: String(entry.userId ?? entry.user_id ?? '') });
    }
    return playerIds.map((userId) => ({ kind: 'human', userId }));
}

export const ludo = {
    slug: 'ludo',
    create(playerIds: string[], options?: Record<string, unknown>): GameEngine {
        const roster = normalizedRoster(playerIds, options);
        const mode: LudoMode = options?.mode === 'four' || roster.length === 4 ? 'four' : 'duel';
        const seed = options?.rngSeed;
        const rng = typeof seed === 'string' && /^[0-9a-f]{64}$/.test(seed)
            ? DiceRng.fromState({ seed, counter: 0 })! : DiceRng.generate();
        const physical = mode === 'duel' ? [0, 2] : [0, 1, 2, 3];
        for (let i = physical.length - 1; i > 0; i--) {
            const j = (rng.next() - 1) % (i + 1); [physical[i], physical[j]] = [physical[j], physical[i]];
        }
        const assigned = Array(MAX_SEATS).fill(false) as boolean[];
        const controller = Array(MAX_SEATS).fill('human') as ControllerType[];
        const humanUserIds = Array(MAX_SEATS).fill(null) as (string | null)[];
        const formerControllerUserIds = Array(MAX_SEATS).fill(null) as (string | null)[];
        const botDifficulty = Array(MAX_SEATS).fill(null) as (BotDifficulty | null)[];
        const botNames = Array(MAX_SEATS).fill(null) as (string | null)[];
        const botPolicyVersion = Array(MAX_SEATS).fill(null) as (string | null)[];
        const accepted = Array(MAX_SEATS).fill(false) as boolean[];
        const used = new Set<string>();
        roster.slice(0, physical.length).forEach((entry, index) => {
            const seat = physical[index]; assigned[seat] = true; controller[seat] = entry.kind;
            if (entry.kind === 'bot') {
                botDifficulty[seat] = difficulty(entry.difficulty); botPolicyVersion[seat] = BOT_POLICY_VERSION;
                botNames[seat] = botName(rng.seedHex, seat, used); used.add(botNames[seat]!); accepted[seat] = true;
            } else {
                humanUserIds[seat] = entry.userId || playerIds[index] || null;
                accepted[seat] = humanUserIds[seat] === playerIds[0];
            }
        });
        const state: LudoStateV3 = {
            schemaVersion: 3, rulesVersion: RULES_VERSION, mode, status: 'waiting', started: false,
            assigned, controller, humanUserIds, formerControllerUserIds, botDifficulty, botNames,
            botPolicyVersion, accepted, participation: Array(MAX_SEATS).fill('waiting'),
            timeoutStreak: [0, 0, 0, 0], captures: [0, 0, 0, 0],
            tokens: assigned.map((yes) => yes ? Array(4).fill(YARD) : []), activeSeat: 0,
            turnSerial: 0, phase: 'none', opensAt: null, deadlineAt: null, botActionAt: null,
            sixStreak: 0, rollId: null, rollValue: null, legalTokenIds: [], automated: false,
            turnHadAutoAction: false, actionCounter: 0, lastAction: null, winnerSeat: null,
            winnerController: null, winnerUserId: null, endReason: null, startedAt: null,
        };
        return new LudoEngineV3(state, rng, 0, randomUUID());
    },
    restore(state: GameStatePayload, secret?: GameStatePayload): GameEngine {
        const inner = (state as { ludo?: unknown }).ludo as LudoStateV3 | undefined;
        if (!inner || inner.schemaVersion !== 3 || inner.rulesVersion !== RULES_VERSION) return new LegacyAbandonEngine();
        const secretInner = (secret as { ludo?: { rng?: unknown; pacingCounter?: unknown } } | undefined)?.ludo;
        const rng = DiceRng.fromState((secretInner?.rng ?? {}) as { seed?: unknown; counter?: unknown });
        if (!rng) {
            inner.status = 'abandoned'; inner.endReason = 'serverIntegrityError'; inner.phase = 'none';
            inner.deadlineAt = null; inner.botActionAt = null;
            return new LudoEngineV3(inner, DiceRng.generate(), 0, randomUUID());
        }
        const pacingCounter = typeof secretInner?.pacingCounter === 'number' ? secretInner.pacingCounter : 0;
        return new LudoEngineV3(inner, rng, pacingCounter, randomUUID());
    },
};
