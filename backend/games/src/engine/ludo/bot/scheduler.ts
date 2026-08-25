import { createHmac } from 'node:crypto';
import type { BotDifficulty } from '../types';

// Rolling involves no decision, so a bot should not sit on it. The roll animation itself
// already holds ROLL_SETTLE_MS so the number can be read; stacking a second of "thinking" on
// top of that is what made a table of bots feel stalled, especially early on when nobody can
// leave home and every turn is roll-and-pass.
const ROLL_BOUNDS: Record<BotDifficulty, readonly [number, number]> = {
    relaxed: [380, 620], balanced: [300, 520], sharp: [420, 700],
};
// Choosing a token IS a decision, so it reads better with a beat of thought behind it — but it
// is still bounded well inside BOT_TURN_BUDGET_MS so a bot's whole turn stays predictable.
const MOVE_BOUNDS: Record<BotDifficulty, readonly [number, number]> = {
    relaxed: [500, 780], balanced: [560, 860], sharp: [700, 1000],
};

/**
 * The hard ceiling on a bot's whole turn, roll plus move, excluding the roll animation the
 * client plays. Nothing schedules past this: a bot that appears to be thinking for longer than
 * a person would is indistinguishable from one that has stopped responding.
 */
export const BOT_TURN_BUDGET_MS = 3_000;

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
    const delay = lo + (bytes.readUInt32BE(0) % (hi - lo + 1));
    // Belt and braces: whatever the bounds say, one leg of a bot turn never eats the budget.
    return Math.min(delay, BOT_TURN_BUDGET_MS / 2);
}
