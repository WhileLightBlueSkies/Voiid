// Frame budgets for the relay (R02).
//
// ── WHY AN AGGREGATE BUDGET EXISTS AT ALL ────────────────────────────────────────
//
// Every limiter here used to be per-TYPE and per-KEY: location had a token bucket per share,
// calls had one per call, games had one per match. Each is correct on its own and together
// they left a gap nothing was watching — a client could spread traffic across typing,
// session_reset, loc_stop and heartbeat, none of which had any limit at all, and stay under
// every individual ceiling while costing the process unbounded Redis work.
//
// So one budget counts EVERY frame on a socket, in frames and in bytes, and it is checked
// before any parsing or Redis call. The per-type limits stay: they shape a specific
// behaviour (how often one share may move), while this one bounds the socket as a whole.
//
// Both are pure and clock-injectable, so the tests do not sleep.

export type Clock = () => number;

/** A fixed-window allowance over frames AND bytes. Whichever runs out first refuses. */
export class SocketBudget {
  private frames = 0;
  private bytes = 0;
  private windowStart: number;

  constructor(
    private readonly limits: { frames: number; bytes: number; windowMs: number },
    private readonly now: Clock = Date.now
  ) {
    this.windowStart = this.now();
  }

  /** True if this frame is within budget. Call once per frame, before doing any work. */
  admit(size: number): boolean {
    const at = this.now();
    if (at - this.windowStart >= this.limits.windowMs) {
      this.windowStart = at;
      this.frames = 0;
      this.bytes = 0;
    }
    if (this.frames + 1 > this.limits.frames) return false;
    if (this.bytes + size > this.limits.bytes) return false;
    this.frames += 1;
    this.bytes += size;
    return true;
  }
}

interface Bucket {
  count: number;
  windowStart: number;
  /** Whether a refusal for this bucket has already been logged. See `warnOnce`. */
  warned?: boolean;
}

/**
 * A per-key fixed-window limiter that cannot be grown without bound.
 *
 * ── THE TWO BUGS THIS REPLACES ───────────────────────────────────────────────────
 *
 * The location limiter was a bare `Map` keyed by a CLIENT-SUPPLIED share id, and it was
 * neither capped nor pruned. That gave a client two things it should not have had:
 *
 *   1. A fresh allowance per invented key. The limit was per share, so a client that made up
 *      a new share id every frame was never limited by it at all.
 *   2. Unbounded growth for the life of the socket, one entry per invented id.
 *
 * The first is now mostly answered upstream — a share id that resolves to no authorised
 * recipients does no work (see recipients.ts) — and the aggregate SocketBudget answers the
 * rest. This class closes the memory side without reopening the allowance side: it drops only
 * EXPIRED buckets, so no live key can be pushed out and come back with a fresh allowance.
 * When the map is full of live buckets it refuses new keys outright.
 */
export class BoundedRateMap {
  private readonly buckets = new Map<string, Bucket>();

  constructor(
    private readonly opts: { max: number; limit: number; windowMs: number },
    private readonly now: Clock = Date.now
  ) {}

  get size(): number {
    return this.buckets.size;
  }

  admit(key: string): boolean {
    const at = this.now();
    this.pruneExpired(at);

    const bucket = this.buckets.get(key);
    if (bucket) {
      if (bucket.count >= this.opts.limit) return false;
      bucket.count += 1;
      return true;
    }

    // A key with no live bucket needs an entry, and the ceiling is hard.
    //
    // ONLY EXPIRED BUCKETS ARE EVER DROPPED — never a live one to make room. Evicting a live
    // bucket would hand the evicted key a fresh allowance the moment it came back, so a
    // client could cycle keys to reset its own limit: the same bypass the unbounded map had,
    // wearing a different hat. Refusing instead means a socket that invents keys fills the
    // map with live buckets and is then refused outright, which is the safe direction.
    //
    // `max` is sized well above any honest number of simultaneous shares, so a real client
    // never reaches it; the socket-wide SocketBudget is the backstop either way.
    if (this.buckets.size >= this.opts.max) return false;
    this.buckets.set(key, { count: 1, windowStart: at });
    return true;
  }

  /** A share that ended: drop its bucket so a long-lived socket does not accumulate them. */
  delete(key: string): void {
    this.buckets.delete(key);
  }

  /**
   * True the FIRST time it is asked for a given live bucket, false afterwards.
   *
   * Exists so a refusal can be logged once per window instead of once per dropped frame.
   * That diagnostic is not decoration: when the game limit silently throttled Snake the
   * failure was invisible from both ends — the phone saw its frames vanish and the games
   * service simply never heard from the player. One line per match is what made it nameable,
   * and it cannot become a log flood because the flag lives on the bucket.
   */
  warnOnce(key: string): boolean {
    const bucket = this.buckets.get(key);
    if (!bucket || bucket.warned) return false;
    bucket.warned = true;
    return true;
  }

  /**
   * Full scan rather than a stop-at-first-live walk: `windowStart` is set when a bucket is
   * created and never moved, so insertion order is NOT window order and an early exit would
   * leave expired buckets behind. The map is capped at `max`, so this is a bounded scan.
   */
  private pruneExpired(at: number): void {
    for (const [key, bucket] of this.buckets) {
      if (at - bucket.windowStart >= this.opts.windowMs) this.buckets.delete(key);
    }
  }
}
