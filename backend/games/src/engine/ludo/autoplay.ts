import { selectBotMove } from './bot/policy';
import type { LudoStateV3 } from './types';

/** Human timeout adapter: the Balanced policy with zero thinking delay. */
export function pickTimeoutMove(state: LudoStateV3, seat: number, die: number, legal: number[]): number | null {
    return selectBotMove(state, seat, die, legal, 'balanced');
}
