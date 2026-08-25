// Ludo die randomness (LUDO_GAME_SPEC.md §5.4).
//
// THE SECURITY MODEL IS ONE LINE: THE SEED IS SECRET, AND IT IS NOT A PRNG STATE A CLIENT
// COULD REPLAY. The old mulberry32 seed WAS its state — a client holding it could compute
// every future roll in twenty lines. Schema v2 replaces it with a 256-bit secret and
// HMAC-SHA256 in counter mode:
//
//   stream = HMAC-SHA256(seed, "ludo-roll-v3:" || counter)  → bytes
//
// Each roll consumes one counter step; the face comes from rejection sampling over the first
// two bytes so 1..6 is UNBIASED (a bare `h % 6` would bias 1..4 by 0.0015% — invisible to a
// player, but it would make the sequence non-reproducible-from-the-audit-record, which is the
// property that matters).
//
// WHAT IS PERSISTED WHERE: seed + counter ride serializeSecret() — the server-only channel,
// same one Sea Battle's hidden picks use. Clients get a seed COMMITMENT at match start
// (sha256(seed)) and the seed itself only in the terminal audit record, so a finished match
// can be proven fair after the fact but never predicted during one.
import { createHash, createHmac, randomBytes } from 'node:crypto';

const STREAM_PREFIX = 'ludo-roll-v3:';

/** One uniform 1..6 value per call; `counter` advances exactly once. */
export class DiceRng {
    private constructor(
        /** Hex-encoded 256-bit secret. Never serialized to a client. */
        readonly seedHex: string,
        private counter: number,
    ) {}

    static generate(): DiceRng {
        return new DiceRng(randomBytes(32).toString('hex'), 0);
    }

    static fromState(state: { seed?: unknown; counter?: unknown }): DiceRng | null {
        if (typeof state?.seed !== 'string' || !/^[0-9a-f]{64}$/.test(state.seed)) return null;
        const counter = state.counter;
        if (typeof counter !== 'number' || !Number.isInteger(counter) || counter < 0) return null;
        return new DiceRng(state.seed, counter);
    }

    get state(): { seed: string; counter: number } {
        return { seed: this.seedHex, counter: this.counter };
    }

    /** sha256 of the hex seed — publishable at match start without revealing the seed. */
    commitment(): string {
        return createHash('sha256').update(this.seedHex).digest('hex');
    }

    next(): number {
        for (;;) {
            const stream = createHmac('sha256', Buffer.from(this.seedHex, 'hex'))
                .update(STREAM_PREFIX + this.counter).digest();
            this.counter += 1;
            for (let offset = 0; offset + 1 < stream.length; offset += 2) {
                const r = stream.readUInt16BE(offset);
                if (r < 65532) return (r % 6) + 1;
            }
        }
    }
}

/**
 * The stable hash behind whole-turn counts and Z direction for the die tumble
 * (§14.3). Derived from `matchId + rollId`, NOT from the value — every path lands on the
 * already-known face regardless.
 */
export function tumbleHash(matchId: string, rollId: string): number {
    const h = createHash('sha256').update(`${matchId}:${rollId}`).digest();
    return h.readUInt32BE(0);
}
