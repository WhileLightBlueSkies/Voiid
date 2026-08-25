import { createHmac } from 'node:crypto';
import type { BotDifficulty } from '../types';

const ROLL_BOUNDS: Record<BotDifficulty, readonly [number, number]> = {
    relaxed: [900, 1500], balanced: [700, 1200], sharp: [1050, 1750],
};
const MOVE_BOUNDS: Record<BotDifficulty, readonly [number, number]> = {
    relaxed: [500, 900], balanced: [650, 1050], sharp: [900, 1500],
};

/** Separate HMAC domain: bot pacing can never consume or change a future die. */
export function botDelay(
    seedHex: string,
    counter: number,
    difficulty: BotDifficulty,
    phase: 'awaitingRoll' | 'awaitingMove',
): number {
    const bytes = createHmac('sha256', Buffer.from(seedHex, 'hex'))
        .update(`ludo-bot-pacing:${counter}:${phase}`).digest();
    const [lo, hi] = phase === 'awaitingRoll' ? ROLL_BOUNDS[difficulty] : MOVE_BOUNDS[difficulty];
    return lo + (bytes.readUInt32BE(0) % (hi - lo + 1));
}
