// Ludo rules as executable logic (LUDO_GAME_SPEC.md §5.3, §5.5).
//
// Pure functions over the state in types.ts. The engine (index.ts) is the only consumer that
// mutates; tests consume these directly so a rule change cannot ship without its test.

import {
    destination,
    HOME_LANE_BASE,
    HOME_LANE_COUNT,
    isFinishedPos,
    isSafe,
    onTrack,
    path,
    progressOf,
    TRACK_COUNT,
    YARD,
} from './board';
import type { LudoStateV2, SeatView } from './types';

/**
 * Squares an opponent has blocked against `seat`: two or more of ONE other colour on a
 * non-safe shared-track cell.
 *
 * BLOCKS CANNOT FORM ON SAFE CELLS. Tokens may stack there — they are already safe — but
 * such a stack does not block passage.
 */
export function blockedSquares(state: LudoStateV2, seat: number): Set<number> {
    const counts = new Map<number, Map<number, number>>();
    for (let s = 0; s < state.players.length; s++) {
        if (s === seat || !isActiveSeat(state, s)) continue;
        for (const p of state.tokens[s]) {
            if (!onTrack(p) || isSafe(p)) continue;
            const bySeat = counts.get(p) ?? new Map<number, number>();
            bySeat.set(s, (bySeat.get(s) ?? 0) + 1);
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

/** An ASSIGNED, accepted seat that has not dropped and whose owner has not won. */
export function isActiveSeat(state: LudoStateV2, seat: number): boolean {
    if (state.players[seat] === null || state.players[seat] === undefined) return false;
    return state.participation[seat] === 'active' || state.participation[seat] === 'waiting';
}

export function activeSeats(state: LudoStateV2): number[] {
    const out: number[] = [];
    for (let s = 0; s < state.players.length; s++) if (isActiveSeat(state, s)) out.push(s);
    return out;
}

/** The next active seat clockwise from `from`, skipping unassigned and dropped seats. */
export function nextActiveSeat(state: LudoStateV2, from: number): number {
    const n = state.players.length;
    for (let i = 1; i <= n; i++) {
        const candidate = (from + i) % n;
        if (isActiveSeat(state, candidate)) return candidate;
    }
    return from;
}

/** Finished-pawn count per seat, derived rather than stored so it can never drift. */
export function finishedPawns(state: LudoStateV2, seat: number): number {
    return state.tokens[seat].filter(isFinishedPos).length;
}

/**
 * Which of this seat's tokens can legally move with this die.
 *
 * THE ONE DEFINITION OF "WHAT CAN THIS PLAYER DO". Blocks are applied here over the whole
 * board because they are the only rule that depends on more than the moving token.
 */
export function legalMoves(state: LudoStateV2, seat: number, die: number): number[] {
    const blocked = blockedSquares(state, seat);
    const legal: number[] = [];

    for (let t = 0; t < state.tokens[seat].length; t++) {
        const from = state.tokens[seat][t];
        const to = destination(from, die, seat);
        if (to === null) continue;

        // An opponent block can neither be landed on NOR passed, so the whole path is checked
        // rather than just the destination.
        if (path(from, die, seat).some((sq) => blocked.has(sq))) continue;

        if (onTrack(to)) {
            // Exactly two same-colour pawns form a block; a third may not join it. Safe cells
            // are exempt — any colours may coexist there.
            if (!isSafe(to)) {
                const own = state.tokens[seat].filter((p, i) => i !== t && p === to).length;
                if (own >= 2) continue;
            }
            // A pawn may not enter from the yard into a cell blocked by TWO OF ITS OWN colour
            // either — an own-block start cell is closed to entry. Opponents on the start cell
            // are fine: starts are safe cells and safe cells never capture or block.
            if (from === YARD && ownBlockOn(state, seat, t, to)) continue;
        }

        legal.push(t);
    }

    return legal;
}

function ownBlockOn(state: LudoStateV2, seat: number, mover: number, at: number): boolean {
    let own = 0;
    for (let i = 0; i < state.tokens[seat].length; i++) {
        if (i === mover) continue;
        if (state.tokens[seat][i] === at) own++;
    }
    return own >= 2;
}

/**
 * Resolve a landed token. Returns the captured [seat, tokenId] or null.
 *
 * Landing on a non-safe shared-track cell occupied by exactly one opponent pawn captures it.
 * No capture occurs in yards, home lanes, center/home, or safe cells. At most one opponent
 * pawn can be captured, because landing on an opponent BLOCK was already illegal.
 */
export function resolveCapture(
    state: LudoStateV2,
    seat: number,
    to: number,
): { seat: number; tokenId: number } | null {
    if (!onTrack(to) || isSafe(to)) return null;
    for (let s = 0; s < state.tokens.length; s++) {
        if (s === seat) continue;
        const idx = state.tokens[s].findIndex((p) => p === to);
        if (idx !== -1 && isActiveSeat(state, s)) return { seat: s, tokenId: idx };
    }
    return null;
}

/**
 * The deterministic timeout move (§5.5). Rank every legal move by this lexicographic tuple,
 * highest first:
 *
 *   1. would win the match          5. lands on a safe cell
 *   2. reaches FINISHED             6. enters/advances in the home lane
 *   3. captures an opponent         7. greatest resulting progress from this pawn's start
 *   4. leaves the yard              8. lowest pawn index
 *
 * Shared by timeout auto-play and tests; clients never duplicate it.
 */
export function pickAutoMove(
    state: LudoStateV2,
    seat: number,
    die: number,
    legal: number[],
): number | null {
    if (legal.length === 0) return null;
    let best: number | null = null;
    let bestRank: number[] | null = null;

    for (const t of legal) {
        const from = state.tokens[seat][t];
        const to = destination(from, die, seat);
        if (to === null) continue;

        const captures = resolveCapture(state, seat, to) !== null;
        // Would-win: every one of the seat's pawns is at FINISHED once this token lands there.
        const wins = state.tokens[seat].every(
            (p, i) => (i === t ? isFinishedPos(to) : isFinishedPos(p)),
        );
        // Resulting progress from this pawn's start. Lane steps outrank every track square and
        // FINISHED outranks every lane step.
        const progress = isFinishedPos(to)
            ? TRACK_COUNT + HOME_LANE_COUNT
            : onTrack(to)
                ? progressOf(to, seat)
                : TRACK_COUNT + (to - HOME_LANE_BASE);

        const rank: number[] = [
            wins ? 1 : 0,
            isFinishedPos(to) ? 1 : 0,
            captures ? 1 : 0,
            from === YARD ? 1 : 0,
            isSafe(to) ? 1 : 0,
            to >= HOME_LANE_BASE && !isFinishedPos(to) ? to - HOME_LANE_BASE : -1,
            progress,
            -t,
        ];
        if (bestRank === null || rankGreater(rank, bestRank)) {
            bestRank = rank;
            best = t;
        }
    }
    return best ?? legal[0];
}

function rankGreater(a: number[], b: number[]): boolean {
    for (let i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) return a[i] > b[i];
    }
    return false;
}
