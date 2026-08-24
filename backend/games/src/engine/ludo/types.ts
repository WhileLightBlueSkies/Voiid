// Ludo schema-v2 state types (LUDO_GAME_SPEC.md §6).
//
// Type names are normative across TypeScript, Swift and Kotlin; only casing differs. The
// PUBLIC frame (LudoPublicState) is what a client receives. Raw user IDs, RNG seed/counter,
// processed command IDs, presence timestamps and acceptance state are SERVER-ONLY (§6) —
// they live in LudoSecret / the runtime's LiveMatch record and never serialize into a frame.

import type { SeatColor } from './board';

export const SCHEMA_VERSION = 2;
export const RULES_VERSION = 'ludo-classic-1';

export type LudoMode = 'duel' | 'four';
export type MatchStatus = 'waiting' | 'active' | 'finished' | 'abandoned';
export type Participation = 'waiting' | 'active' | 'dropped' | 'winner';

/** Per-seat public facts. `displayName` is filled per recipient at projection time. */
export interface SeatView {
    seat: number;
    seatId: string;
    color: SeatColor;
    displayName?: string;
    participation: Participation;
    connection: 'connected' | 'disconnected';
    timeoutStreak: number;
    finishedPawns: number;
    captures: number;
}

export interface TurnView {
    seat: number;
    serial: number;
    phase: 'awaitingRoll' | 'awaitingMove' | 'none';
    opensAt: number;
    deadlineAt: number;
    sixStreak: number;
    rollId: string | null;
    value: number | null;
    legalTokenIds: number[];
    automated: boolean;
}

export type ActionType =
    | 'turnChanged'
    | 'roll'
    | 'move'
    | 'autoTurn'
    | 'capture'
    | 'drop'
    | 'end';

export interface ActionRoll {
    rollId: string;
    value: number;
    auto: boolean;
}

export interface ActionMove {
    tokenId: number;
    from: number;
    to: number;
    /** Intermediate squares INCLUDING the landing cell; [] for a yard entry. */
    path: number[];
    captured: { seat: number; tokenId: number; from: number; to: number } | null;
}

/**
 * What just happened, for exactly-once client animation (§9). `id` is stable across
 * persistence and re-broadcast; clients keep `lastRenderedActionId` per match.
 */
export interface LastAction {
    id: string;
    type: ActionType;
    committedAt: number;
    /**
     * Universal presentation window end (§15): the moment every client may open the next
     * border sweep / turn. Local fast-forward never moves it earlier.
     */
    presentationEndsAt: number;
    actorSeat: number;
    fromSeat?: number;
    roll?: ActionRoll;
    move?: ActionMove;
}

export interface LudoPublicTurn extends Omit<TurnView, 'seat'> {
    seat: number;
}

/** The full wire payload, before per-viewer name projection. */
export interface LudoPublicState {
    schemaVersion: 2;
    rulesVersion: string;
    mode: LudoMode;
    status: MatchStatus;
    serverNow: number;
    viewerSeat: number | null;
    seats: SeatView[];
    tokensPerSeat: 4;
    tokens: number[][];
    turn: TurnView | null;
    lastAction: LastAction | null;
    winnerSeat: number | null;
    endReason: string | null;
    seedCommitment: string | null;
}

/** SERVER-ONLY. Never in any frame. */
export interface LudoSecretState {
    rng: { seed: string; counter: number };
    /** Raw user ids by physical seat. Kept beside the RNG so restore() can rebuild players. */
    players: (string | null)[];
    accepted: boolean[];
}

/** The engine's persisted logical object — everything needed to rebuild exactly (§20 P1). */
export interface LudoStateV2 {
    schemaVersion: typeof SCHEMA_VERSION;
    rulesVersion: string;
    mode: LudoMode;
    status: MatchStatus;
    started: boolean;

    /** Physical seats 0..3; null for an unassigned seat. SERVER-ONLY raw ids. */
    players: (string | null)[];
    accepted: boolean[];
    participation: Participation[];
    timeoutStreak: number[];
    captures: number[];

    /** [seat][pawn] -> position encoding. Always four pawns for an assigned seat. */
    tokens: number[][];

    startedByRng: boolean;
    firstSeatChosen: boolean;
    activeSeat: number;
    turnSerial: number;
    phase: 'awaitingRoll' | 'awaitingMove' | 'none';
    opensAt: number | null;
    deadlineAt: number | null;
    sixStreak: number;
    rollId: string | null;
    rollValue: number | null;
    legalTokenIds: number[];
    automated: boolean;
    /** True when this uninterrupted turn used ANY auto action (roll or move). */
    turnHadAutoAction: boolean;

    actionCounter: number;
    lastAction: LastAction | null;

    winnerSeat: number | null;
    endReason: string | null;
}
