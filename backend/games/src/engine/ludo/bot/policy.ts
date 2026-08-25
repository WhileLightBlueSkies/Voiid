import {
    destination, FINISHED, HOME_LANE_BASE, HOME_LANE_COUNT, isSafe, onTrack,
    progressOf, TRACK_COUNT, YARD,
} from '../board';
import { legalMoves, rankGreater, resolveCapture } from '../rules';
import type { BotDifficulty, LudoStateV3 } from '../types';

function progress(pos: number, seat: number): number {
    if (pos === FINISHED) return TRACK_COUNT + HOME_LANE_COUNT + 1;
    if (pos >= HOME_LANE_BASE) return TRACK_COUNT + (pos - HOME_LANE_BASE);
    if (onTrack(pos)) return progressOf(pos, seat);
    return -1;
}

function cloneAfter(state: LudoStateV3, seat: number, tokenId: number, to: number): LudoStateV3 {
    const copy = structuredClone(state);
    copy.tokens[seat][tokenId] = to;
    const captured = resolveCapture(copy, seat, to);
    if (captured) copy.tokens[captured.seat][captured.tokenId] = YARD;
    return copy;
}

export function dangerScore(state: LudoStateV3, seat: number, tokenId: number): number {
    const target = state.tokens[seat][tokenId];
    if (!onTrack(target) || isSafe(target)) return 0;
    let score = 0;
    for (let opponent = 0; opponent < 4; opponent++) {
        if (opponent === seat || !state.assigned[opponent]) continue;
        for (let die = 1; die <= 6; die++) {
            for (const pawn of legalMoves(state, opponent, die)) {
                const from = state.tokens[opponent][pawn];
                if (destination(from, die, opponent) !== target) continue;
                score += 7 - die;
            }
        }
    }
    return score;
}

function totalDanger(state: LudoStateV3, seat: number): number {
    return state.tokens[seat].reduce((sum, _p, token) => sum + dangerScore(state, seat, token), 0);
}

function occupiedNonSafe(state: LudoStateV3, seat: number): number {
    return new Set(state.tokens[seat].filter((p) => onTrack(p) && !isSafe(p))).size;
}

/** Proposes a token only. The ordinary engine validator recomputes legality before mutation. */
export function selectBotMove(
    state: LudoStateV3,
    seat: number,
    die: number,
    legal: number[],
    tier: BotDifficulty,
): number | null {
    if (legal.length === 0) return null;
    if (legal.length === 1) return legal[0];
    let best = legal[0];
    let bestRank: number[] | null = null;
    for (const token of legal) {
        const from = state.tokens[seat][token];
        const to = destination(from, die, seat)!;
        const captured = resolveCapture(state, seat, to);
        const after = cloneAfter(state, seat, token, to);
        const wins = after.tokens[seat].every((p) => p === FINISHED);
        const finishes = to === FINISHED;
        const entersHome = to >= HOME_LANE_BASE && to < FINISHED;
        const leavesYard = from === YARD;
        const landsSafe = isSafe(to);
        const movedDangerBefore = dangerScore(state, seat, token);
        const movedDangerAfter = dangerScore(after, seat, token);
        const dangerReduction = movedDangerBefore - movedDangerAfter;
        const spreadGain = occupiedNonSafe(after, seat) - occupiedNonSafe(state, seat);
        const destinationCount = after.tokens[seat].filter((p) => p === to).length;
        const blockGain = onTrack(to) && !isSafe(to) && destinationCount === 2;
        const protectedBlock = blockGain && movedDangerAfter === 0;
        const capturedProgress = captured ? progress(state.tokens[captured.seat][captured.tokenId], captured.seat) : -1;
        const rank = tier === 'relaxed'
            ? [wins ? 1 : 0, captured ? 1 : 0, leavesYard && die === 6 ? 1 : 0,
                finishes ? 1 : 0, entersHome ? 1 : 0, progress(to, seat), spreadGain, -token]
            : tier === 'balanced'
                ? [wins ? 1 : 0, finishes ? 1 : 0, capturedProgress, dangerReduction,
                    leavesYard && die === 6 ? 1 : 0, landsSafe ? 1 : 0, entersHome ? 1 : 0,
                    progress(to, seat), spreadGain, blockGain ? -1 : 0, -token]
                : [wins ? 1 : 0, finishes ? 1 : 0, capturedProgress - movedDangerAfter,
                    movedDangerBefore > 0 && (landsSafe || entersHome) ? 1 : 0, entersHome ? 1 : 0,
                    leavesYard && die === 6 ? 1 : 0, landsSafe ? 1 : 0, protectedBlock ? 1 : 0,
                    -totalDanger(after, seat), progress(to, seat), spreadGain, -token];
        if (bestRank === null || rankGreater(rank, bestRank)) { bestRank = rank; best = token; }
    }
    return best;
}
