// Account recovery routes (pairs with e2e-core src/recovery.rs). The server stores
// ONLY the opaque PinWrappedSecret (Argon2id + AES-256-GCM wrap of the master
// backup secret) and never sees the PIN or the secret. The separate BIP39 recovery
// phrase is CLIENT-SIDE ONLY — nothing is stored here for it.
//
// ─────────────────────────────────────────────────────────────────────────────
// THREAT MODEL — READ THIS BEFORE CHANGING ANYTHING HERE (S04)
// ─────────────────────────────────────────────────────────────────────────────
//
// This file previously described `failed_attempts`/`locked_until` as "SERVER-SIDE
// guess limiting". THAT CLAIM WAS FALSE, and the comment saying so was the most
// dangerous thing in the file, because it invited people to rely on a boundary
// that does not exist.
//
// Why it is false: the counter moves ONLY when the client POSTs
// /recovery/attempt-result with success:false. In this threat model the client IS
// the attacker. It can:
//   * fetch the wrap once and guess offline forever, reporting nothing at all;
//   * omit its failures, so the counter never rises;
//   * POST success:true and RESET the counter and clear an active lock.
// A control the attacker can decline to trigger, and can unilaterally reset, is
// not a security boundary. It is abuse telemetry about HONEST clients — useful
// for spotting a confused or misbehaving device, and nothing more.
//
// WHAT ACTUALLY DEFENDS THE SECRET, honestly stated:
//   1. The BIP39 phrase. High entropy, never sent to the server. This is the only
//      recovery path with real cryptographic strength, and it is the fallback the
//      product should be steering users toward.
//   2. The PIN wrap. Argon2id raises the cost per guess, but a 6-digit PIN is
//      ~20 bits. Against an attacker holding the envelope, Argon2id buys time, not
//      safety. Assume a determined attacker who fetches the wrap recovers a short
//      PIN offline.
//
// STOLEN TOKEN: can fetch the envelope (metered below, see fetch_count) and then
//   guess the PIN offline at their own pace. Server lockout does not apply, because
//   nothing forces them to come back. Mitigation is PIN entropy and the phrase.
// STOLEN DATABASE: gets every envelope at once, with the same consequence and no
//   fetch metering at all. `failed_attempts` is worthless here.
//
// WHAT THE SERVER CAN ACTUALLY ENFORCE, and now does: the envelope FETCH. An
// offline attacker must fetch at least once and cannot un-fetch. So fetches are
// counted server-side, rate-limited, and visible. This bounds harvesting and makes
// it observable. It does NOT make offline guessing hard.
//
// S04 IS NOT CLOSED BY THIS FILE. Closing it needs a reviewed design — a
// high-entropy recovery secret, or a server-assisted protocol (OPRF/SVR) that
// enforces attempts without handing out an offline verifier — and S04 states
// explicitly that a cryptographic reviewer must approve it and that this is a
// release gate. What is done here is code-level only: the false claims are gone,
// the counters are atomic, and the one unforgeable signal is recorded.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';
import {
  isValidWrappedKey,
  pickWrappedKey,
  applyFailure,
  applySuccess,
  lockRetryAfter,
} from '../recoveryLockout';

const router = Router();

/**
 * How many envelope fetches a user may make before the server refuses.
 *
 * Deliberately generous: an honest user re-recovers rarely, but a legitimate one
 * retrying across a flaky network or several devices must not be locked out of
 * their own account. The point is to bound HARVESTING and make it visible, not to
 * pretend this stops an attacker who already holds one envelope.
 *
 * Reset by storing a new wrap (PUT /key), which is what a genuine recovery does.
 */
const FETCH_LIMIT = Number(process.env.VOIID_RECOVERY_FETCH_LIMIT) || 25;
const FETCH_COOLDOWN_SECONDS = 24 * 60 * 60;

// The lockout state machine + envelope validation live in ../recoveryLockout so
// they can be unit-tested without a database. See that module for the thresholds
// and the escalating-cooldown schedule.

// PUT /recovery/key — upsert the caller's PinWrappedSecret. Body is the wrap
// itself: { version, salt, nonce, ciphertext } (also accepted nested under
// `wrapped_key`). Storing a new wrap resets the failure counter + clears any lock.
router.put('/key', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const wrapped = req.body?.wrapped_key ?? req.body;
  if (!isValidWrappedKey(wrapped)) {
    return res.status(400).json({ error: 'invalid wrapped_key (expected { version:int, salt, nonce, ciphertext } as base64)' });
  }
  // Persist ONLY the four known fields — never store client-supplied extras.
  const value = pickWrappedKey(wrapped);
  await query(
    `insert into recovery_keys (user_id, wrapped_key, failed_attempts, locked_until)
       values ($1, $2, 0, null)
       on conflict (user_id) do update set
         wrapped_key     = excluded.wrapped_key,
         failed_attempts = 0,
         locked_until    = null,
         fetch_count     = 0,
         last_fetched_at = null`,
    [user_id, JSON.stringify(value)]
  );
  res.json({ stored: true });
}));

// GET /recovery/key — return the stored wrap so the caller can attempt PIN unwrap.
// 429 (with Retry-After) while locked out from too many failed online attempts;
// 404 if the user never stored a wrap.
router.get('/key', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;

  // One statement: read the state and record the fetch together. The fetch is the
  // only thing here the client cannot lie about, so it must not be lost to a race
  // between two concurrent fetches, and it must be recorded even for a request that
  // is about to be refused — a lockout the attacker triggers is still a fetch
  // ATTEMPT worth seeing.
  const rows = await query<{
    wrapped_key: unknown;
    locked_until: Date | null;
    fetch_count: number;
  }>(
    `update recovery_keys
        set fetch_count = fetch_count + 1,
            last_fetched_at = now()
      where user_id = $1
      returning wrapped_key, locked_until, fetch_count`,
    [user_id]
  );
  const row = rows[0];
  if (!row) return res.status(404).json({ error: 'no recovery key found' });

  const retryAfter = lockRetryAfter(row.locked_until);
  if (retryAfter !== null) {
    res.setHeader('Retry-After', String(retryAfter));
    return res.status(429).json({ error: 'recovery locked', retry_after: retryAfter, locked_until: row.locked_until });
  }

  // Metering the fetch is a REAL limit, unlike the client-reported counter: an
  // offline attacker cannot avoid fetching, so this is the one place the server has
  // a say. It bounds how much a stolen token can harvest; it does not protect an
  // envelope already handed out.
  if (row.fetch_count > FETCH_LIMIT) {
    res.setHeader('Retry-After', String(FETCH_COOLDOWN_SECONDS));
    return res.status(429).json({
      error: 'too many recovery key fetches',
      retry_after: FETCH_COOLDOWN_SECONDS,
    });
  }

  // wrapped_key is jsonb — node-pg returns it already parsed into an object.
  res.json({ wrapped_key: row.wrapped_key });
}));

// POST /recovery/attempt-result { success: boolean } — the client reports the
// outcome of an unwrap attempt so the SERVER can enforce online guess limiting.
// success:false increments the counter (locking with an escalating cooldown past
// the threshold); success:true resets the counter + clears the lock.
router.post('/attempt-result', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const success = req.body?.success;
  if (typeof success !== 'boolean') {
    return res.status(400).json({ error: 'success (boolean) required' });
  }

  if (success) {
    // NOTE the asymmetry, and that it is not fixable here: an attacker can call
    // this to clear the counter. That is precisely why the counter is telemetry
    // rather than a boundary, and why the fetch meter above exists.
    const state = applySuccess();
    const rows = await query<{ user_id: string }>(
      `update recovery_keys set failed_attempts = 0, locked_until = null
        where user_id = $1 returning user_id`,
      [user_id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'no recovery key found' });
    return res.json({ failed_attempts: state.failed_attempts, locked_until: state.locked_until });
  }

  // ATOMIC (S04). This was select-then-update across two statements: two concurrent
  // failure reports both read the same `failed_attempts`, both wrote the same n+1,
  // and one of the two failures vanished. Under READ COMMITTED an attacker could
  // hold the counter down by reporting failures in parallel — the telemetry lied in
  // the attacker's favour, which is the worst direction for it to lie.
  //
  // Now the increment happens inside the statement, so it is serialized by the row
  // lock, and the lock schedule is computed from the value the database produced.
  const rows = await query<{ failed_attempts: number }>(
    `update recovery_keys set failed_attempts = failed_attempts + 1
      where user_id = $1 returning failed_attempts`,
    [user_id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'no recovery key found' });

  // applyFailure takes the PREVIOUS count and adds one, so hand it the value before
  // this increment; the database has already applied the +1.
  const state = applyFailure(rows[0].failed_attempts - 1);
  await query(
    `update recovery_keys set locked_until = $2 where user_id = $1`,
    [user_id, state.locked_until]
  );
  if (state.retry_after != null) res.setHeader('Retry-After', String(state.retry_after));
  res.json({
    failed_attempts: state.failed_attempts,
    locked_until: state.locked_until,
    retry_after: state.retry_after,
  });
}));

export default router;
