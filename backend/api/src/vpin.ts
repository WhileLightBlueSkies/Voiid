// V PIN — an 8-digit PIN whose guesses the SERVER counts, so the limit is real.
//
// ── WHY THIS EXISTS, AND WHAT IT REPLACES ──────────────────────────────────────────
// The first PIN (routes/recovery.ts, "legacy") handed the PIN-locked backup key to any
// signed-in caller and let the CLIENT report whether its guess worked. In this threat
// model the client is the attacker, so that counter was telemetry, not a limit: a stolen
// token fetched the envelope once and guessed offline forever (S04).
//
// Here the order is reversed. The envelope is RELEASED ONLY AFTER the server has checked
// a proof of the PIN itself, and the server — not the client — counts every wrong proof.
//
//   * The phone never sends the PIN. It sends `proof = PBKDF2-SHA256(pin, salt, 600k)`,
//     a one-way stretch of it (see `PROOF_*` below; both apps compute it identically).
//   * The server stores only `HMAC(k_verify, proof)`, keyed with a secret derived from
//     VOIID_SECRETBOX_KEY. A copy of the DATABASE alone cannot be used to test guesses —
//     the attacker also needs the process environment.
//   * The envelope (the backup key, already locked on the phone with Argon2id + AES-GCM)
//     is sealed a SECOND time with the server key, bound to its owner, so a database copy
//     alone yields nothing to guess against either.
//   * 5 wrong proofs lock the PIN for 24 hours. The lock is checked BEFORE the proof, so
//     a locked PIN refuses even the right answer — otherwise the lock is a speed bump.
//
// ── WHAT IT DEFENDS, HONESTLY ──────────────────────────────────────────────────────
//   stolen login token / phone   → 5 guesses per 24h against 10^8 PINs. Real.
//   stolen database              → nothing usable without VOIID_SECRETBOX_KEY.
//   whole server (db + env)      → the verifier and envelope can be attacked offline.
//                                  Closing that needs a hardware enclave (Signal's SVR).
//                                  This design does not claim to.
// The 24-word phrase remains the recovery path with real cryptographic strength, and
// always works — including while the PIN is locked.
//
// Pure apart from the key: no database, clock injectable, so every rule is testable.
import { createHmac, hkdfSync, timingSafeEqual } from 'crypto';
import { open, seal, secretboxKey } from './secretbox';

/** The row's PIN scheme. 1 = legacy client-reported envelope; 2 = this. */
export const VPIN_VERSION = 2;

/** Wrong proofs allowed before the lock. Then the counter starts again from zero. */
export const VPIN_MAX_ATTEMPTS = 5;

/** How long a lock lasts. */
export const VPIN_LOCK_MS = 24 * 60 * 60 * 1000;

// ── The proof, as the apps compute it ──────────────────────────────────────────────
// Recorded here as the single source of truth; iOS (VPinProof.swift) and Android
// (VPinProof.kt) must match it byte for byte, and test/vpin.test.ts pins a known answer.
//   password   = the 8-digit PIN, UTF-8
//   salt       = "voiid.vpin.auth.v1:" || authSalt (the 16 raw bytes)
//   iterations = 600000   (OWASP 2023 minimum for PBKDF2-HMAC-SHA256)
//   length     = 32 bytes, sent base64
export const PROOF_SALT_PREFIX = 'voiid.vpin.auth.v1:';
export const PROOF_ITERATIONS = 600_000;
export const PROOF_BYTES = 32;
export const AUTH_SALT_BYTES = 16;

const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

/** Decode standard base64 of an exact byte length, or null. Strict: no whitespace, no url alphabet. */
export function decodeExact(value: unknown, bytes: number): Buffer | null {
  if (typeof value !== 'string' || !BASE64_RE.test(value)) return null;
  const buf = Buffer.from(value, 'base64');
  // Round-trip check rejects non-canonical encodings that decode to the right length.
  if (buf.length !== bytes || buf.toString('base64') !== value) return null;
  return buf;
}

/**
 * The verifier key: HKDF from the secretbox key, under its own label.
 *
 * Deliberately NOT the secretbox key itself. One key doing two jobs (AES encryption and
 * HMAC) is a textbook mistake; deriving a sibling key keeps them independent.
 */
function verifierKey(): Buffer {
  const master = secretboxKey();
  if (!master) throw new Error('V PIN needs VOIID_SECRETBOX_KEY');
  return Buffer.from(hkdfSync('sha256', master, Buffer.alloc(0), 'voiid vpin verifier v1', 32));
}

/** HMAC(k_verify, proof), base64. This is what is stored — never the proof. */
export function verifierFor(proof: Buffer): string {
  return createHmac('sha256', verifierKey()).update(proof).digest('base64');
}

/** Constant-time check of a presented proof against the stored verifier. */
export function proofMatches(proof: Buffer, storedVerifier: string): boolean {
  const expected = Buffer.from(storedVerifier, 'base64');
  const actual = createHmac('sha256', verifierKey()).update(proof).digest();
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

/**
 * Seal the (already PIN-locked) envelope for storage, bound to its owner.
 *
 * The owner id travels INSIDE the sealed plaintext and is checked on open, so a sealed
 * blob copied onto another account's row does not open there.
 */
export function sealEnvelope(userId: string, envelope: unknown): string {
  return seal(JSON.stringify({ u: userId, w: envelope }));
}

/** Reverse `sealEnvelope`; null if it does not open or belongs to someone else. */
export function openEnvelope(userId: string, sealed: string | null | undefined): unknown | null {
  const text = open(sealed);
  if (text === null) return null;
  try {
    const parsed = JSON.parse(text);
    return parsed && parsed.u === userId ? parsed.w : null;
  } catch {
    return null;
  }
}

// ── The lock ─────────────────────────────────────────────────────────────────────────

export interface VPinState {
  failedAttempts: number;
  lockedUntil: Date | null;
}

/** Seconds left on an active lock, or null if the PIN is usable now. */
export function lockSecondsLeft(lockedUntil: Date | null, nowMs = Date.now()): number | null {
  if (!lockedUntil) return null;
  const ms = lockedUntil.getTime() - nowMs;
  return ms > 0 ? Math.ceil(ms / 1000) : null;
}

/**
 * State after one WRONG proof.
 *
 * The 5th wrong proof locks for 24h and resets the counter, so once the lock expires the
 * person gets a fresh 5 — the limit is "5 per 24 hours", not "5 ever". A lock that had
 * already EXPIRED counts as no lock: its counter was reset when it was set.
 */
export function afterWrongProof(state: VPinState, nowMs = Date.now()): VPinState {
  const failed = state.failedAttempts + 1;
  if (failed >= VPIN_MAX_ATTEMPTS) {
    return { failedAttempts: 0, lockedUntil: new Date(nowMs + VPIN_LOCK_MS) };
  }
  return { failedAttempts: failed, lockedUntil: null };
}

/** Attempts remaining before the next lock. */
export function attemptsLeft(state: VPinState): number {
  return Math.max(0, VPIN_MAX_ATTEMPTS - state.failedAttempts);
}
