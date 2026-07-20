// Online PIN guess-limiting state machine + recovery envelope validation.
//
// Extracted from routes/recovery.ts because this is the control that stands between
// an attacker with a stolen JWT and an ONLINE brute-force of a 6-digit PIN. It is
// pure (no db, no clock coupling — `now` is injectable) so every transition can be
// asserted directly.

/**
 * After this many CONSECUTIVE failed online attempts, lock with an escalating
 * cooldown. (On-device offline attempts against a cached wrap are throttled by the
 * client; this is the online limit for recovering on a NEW device.)
 */
export const LOCK_THRESHOLD = 10;

/**
 * Escalating cooldowns once past the threshold: 15m, then 1h, then 24h (capped),
 * indexed by how many attempts past the threshold we are.
 */
export const LOCK_COOLDOWNS_MS = [15 * 60_000, 60 * 60_000, 24 * 60 * 60_000];

// Validate a PinWrappedSecret shape: version int, salt/nonce/ciphertext non-empty
// base64 strings. We cannot (and must not) inspect the ciphertext — it is opaque —
// so this only checks the envelope. Accepts both standard and url base64 alphabets.
const BASE64_RE = /^[A-Za-z0-9+/_-]+={0,2}$/;

export interface WrappedKey {
  version: number;
  salt: string;
  nonce: string;
  ciphertext: string;
}

export function isValidWrappedKey(v: any): boolean {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return false;
  if (!Number.isInteger(v.version)) return false;
  for (const field of ['salt', 'nonce', 'ciphertext'] as const) {
    if (typeof v[field] !== 'string' || v[field].length === 0 || !BASE64_RE.test(v[field]))
      return false;
  }
  return true;
}

/** Strip to the four known fields — a client's extra keys are never persisted. */
export function pickWrappedKey(v: any): WrappedKey {
  return { version: v.version, salt: v.salt, nonce: v.nonce, ciphertext: v.ciphertext };
}

export interface LockState {
  failed_attempts: number;
  locked_until: Date | null;
  retry_after?: number;
}

/**
 * Apply one FAILED attempt on top of `prevFailed` consecutive failures.
 *
 * Below the threshold: just increment, no lock. At/past it: lock for an escalating
 * cooldown indexed by how far past the threshold we are, capped at the last entry
 * (24h) so the lock never grows unbounded but also never resets by overflowing.
 */
export function applyFailure(prevFailed: number, nowMs: number = Date.now()): LockState {
  const failed = prevFailed + 1;
  if (failed < LOCK_THRESHOLD) return { failed_attempts: failed, locked_until: null };
  const idx = Math.min(failed - LOCK_THRESHOLD, LOCK_COOLDOWNS_MS.length - 1);
  const locked_until = new Date(nowMs + LOCK_COOLDOWNS_MS[idx]);
  return {
    failed_attempts: failed,
    locked_until,
    retry_after: Math.ceil(LOCK_COOLDOWNS_MS[idx] / 1000),
  };
}

/** A SUCCESSFUL unwrap clears both the counter and any active lock. */
export function applySuccess(): LockState {
  return { failed_attempts: 0, locked_until: null };
}

/** Seconds remaining on an active lock, or null when not currently locked. */
export function lockRetryAfter(lockedUntil: Date | null, nowMs: number = Date.now()): number | null {
  if (!lockedUntil) return null;
  const ms = lockedUntil.getTime() - nowMs;
  return ms > 0 ? Math.ceil(ms / 1000) : null;
}
