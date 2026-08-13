// The shared deterministic PRNG, promoted out of snake/geometry.ts on its second consumer
// (docs/games/future/README.md §1.3).
//
// It lived in geometry.ts because Snake was the only game that drew anything. Nothing about
// mulberry32 is snake-shaped, and Sea Battle needs the same guarantee for the same reason, so
// the class moves here and geometry.ts re-exports it — no shipped Snake code changes.
//
// Math.random() would be fatal here, not merely untidy: the runtime rebuilds the engine from
// serialized state on every single input (index.ts), so an engine using global randomness
// would produce a different world each time it was restored. Determinism is what lets state
// round-trip through Redis unchanged.
//
// WHERE THE SEED IS SERIALIZED IS A PER-GAME DECISION, NOT A CONVENTION TO COPY. The rule
// (README.md §1.3): the seed goes in serializeSecret() whenever a future draw is information
// a player would pay for. Snake puts it in serialize() and is right to — its draws are pellet
// positions and bot jitter. Ludo and Voiid Cards must not, because the next draw is the dice
// and the shuffle. Sea Battle may, because its only remaining draw produces the caller's own
// fleet. Re-run that check per game rather than copying whichever engine you read last.
export class Rng {
  private s: number;

  constructor(seed: number) {
    this.s = seed >>> 0;
  }

  /** Current seed, so it can be serialized and the sequence resumed exactly. */
  get seed(): number {
    return this.s;
  }

  next(): number {
    this.s = (this.s + 0x6d2b79f5) >>> 0;
    let t = this.s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  range(lo: number, hi: number): number {
    return lo + this.next() * (hi - lo);
  }

  /** Integer in [0, n). Used for picking a cell, an orientation, or a seat. */
  int(n: number): number {
    return Math.floor(this.next() * n) % n;
  }
}
