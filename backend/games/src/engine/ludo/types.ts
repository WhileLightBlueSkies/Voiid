import type { SeatColor } from './board';

export const SCHEMA_VERSION = 3;
export const RULES_VERSION = 'ludo-classic-2';
export const BOT_POLICY_VERSION = 'ludo-bot-1';

export type LudoMode = 'duel' | 'four';
export type MatchStatus = 'waiting' | 'active' | 'finished' | 'abandoned';
export type Participation = 'waiting' | 'active' | 'winner';
export type ControllerType = 'human' | 'bot';
export type BotDifficulty = 'relaxed' | 'balanced' | 'sharp';
export type ViewerRole = 'controller' | 'formerController' | 'none';
export type EndReason = 'allPawnsHome' | 'duelForfeit' | 'serverIntegrityError' | 'legacyVersionAbandoned';

export interface RosterEntry { kind: ControllerType; userId?: string; difficulty?: BotDifficulty }
export interface SeatView {
    seat: number; seatId: string; color: SeatColor; displayName: string;
    controller: ControllerType; botMarker: 'BOT' | null; botDifficulty: BotDifficulty | null;
    participation: Participation; connection: 'connected' | 'disconnected';
    timeoutStreak: number; finishedPawns: number; captures: number;
}
export interface LegalMoveView {
    tokenId: number; to: number; path: number[];
    capture: { seat: number; tokenId: number } | null; isSafe: boolean;
}
export interface TurnView {
    seat: number; serial: number; phase: 'awaitingRoll' | 'awaitingMove'; opensAt: number;
    deadlineAt: number | null; botActionAt: number | null; sixStreak: number;
    rollId: string | null; value: number | null; legalMoves: LegalMoveView[]; automated: boolean;
}
export type ActionType = 'turnChanged' | 'roll' | 'move' | 'autoTurn' | 'capture' | 'controllerChanged' | 'end';
export interface ActionRoll { rollId: string; value: number; auto: boolean }
export interface ActionMove {
    tokenId: number; from: number; to: number; path: number[];
    captured: { seat: number; tokenId: number; from: number; to: number } | null;
}
export interface LastAction {
    id: string; type: ActionType; committedAt: number; presentationEndsAt: number;
    actorSeat: number; fromSeat?: number; roll?: ActionRoll; move?: ActionMove;
}
export interface LudoPublicState {
    schemaVersion: 3; rulesVersion: typeof RULES_VERSION; mode: LudoMode; status: MatchStatus;
    seq: number; serverNow: number; viewerSeat: number | null; viewerRole: ViewerRole;
    seats: SeatView[]; tokensPerSeat: 4; tokens: number[][]; turn: TurnView | null;
    lastAction: LastAction | null; winnerSeat: number | null; endReason: EndReason | null;
    seedCommitment: string | null;
}

/** Complete persisted logical state. Raw identities and scheduler/RNG facts never serialize. */
export interface LudoStateV3 {
    schemaVersion: typeof SCHEMA_VERSION; rulesVersion: typeof RULES_VERSION;
    mode: LudoMode; status: MatchStatus; started: boolean;
    assigned: boolean[]; controller: ControllerType[]; humanUserIds: (string | null)[];
    formerControllerUserIds: (string | null)[]; botDifficulty: (BotDifficulty | null)[];
    botNames: (string | null)[]; botPolicyVersion: (string | null)[]; accepted: boolean[];
    participation: Participation[]; timeoutStreak: number[]; captures: number[]; tokens: number[][];
    activeSeat: number; turnSerial: number; phase: 'awaitingRoll' | 'awaitingMove' | 'none';
    opensAt: number | null; deadlineAt: number | null; botActionAt: number | null;
    sixStreak: number; rollId: string | null; rollValue: number | null; legalTokenIds: number[];
    automated: boolean; turnHadAutoAction: boolean; actionCounter: number; lastAction: LastAction | null;
    winnerSeat: number | null; winnerController: ControllerType | null; winnerUserId: string | null;
    endReason: EndReason | null; startedAt: number | null;
}
export interface LudoSecretState { rng: { seed: string; counter: number }; pacingCounter: number }
