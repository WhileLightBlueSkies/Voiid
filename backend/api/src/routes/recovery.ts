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
// ── THE DESIGN NOW (S04): THE PIN WRAP IS RETIRED ─────────────────────────────
//
// S04 offered two reviewed ways out: a high-entropy recovery secret, or a
// server-assisted protocol (OPRF/SVR). The first is taken, because it needs NO new
// cryptography — the 24-word BIP39 phrase (256 bits, generated on-device, never
// sent here) already exists and is already the recovery path with real strength.
//
//   * NEW PIN WRAPS ARE REFUSED (PUT /key → 410). The apps no longer create one:
//     backup setup shows the phrase and makes the person prove they wrote it down.
//     No new offline-guessable envelope is ever written.
//   * OLD WRAPS STILL RESTORE (GET /key, metered as before) — the versioned
//     migration S04 requires, so nobody's existing backup is stranded. After a
//     restore, and from Settings, the app deletes the wrap (DELETE /key) once the
//     person has saved their phrase, shrinking what a stolen token or database
//     can reach toward nothing.
//   * GET /status says whether a wrap exists WITHOUT handing it out, so the app can
//     decide to offer the PIN at all without counting as a fetch.
//
// VOIID_RECOVERY_PIN_WRAPS=legacy re-enables PUT for a deployment that still has
// clients creating wraps. It exists for rollouts and tests, not as a product mode.
//
// What remains for review is the phrase path itself (BIP39 + AES-256-GCM in
// e2e-core recovery.rs) — standard primitives, unchanged, and still marked pending
// external cryptographic review there. This change removes the weak path; it does
// not certify the strong one.
//
// ── THE V PIN (version 2): A PIN WHOSE GUESSES THE SERVER COUNTS ──────────────────
//
// The PIN is back, rebuilt so the limit is real. PUT /pin stores it; POST /pin/unlock
// checks a proof of it and releases the envelope ONLY when the proof matches, counting
// every wrong one server-side: 5 wrong → locked 24h. Design, crypto and threat model are
// in ../vpin.ts. Everything above this note describes version-1 (legacy) rows.
//
// The two schemes share a row (096) but never each other's routes:
//   * GET /key and POST /attempt-result touch version-1 rows ONLY. GET /key must never
//     hand out a V PIN envelope unchecked, and attempt-result must never let a client
//     "report success" to clear a lock the server set.
//   * PUT /key (legacy, behind the rollout switch) writes a clean version-1 row.
import { Router } from 'express';
import { query, withTransaction } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';
import { rateLimit } from '../security';
import { secretboxAvailable } from '../secretbox';
import {
  AUTH_SALT_BYTES,
  PROOF_BYTES,
  VPIN_MAX_ATTEMPTS,
  VPIN_VERSION,
  afterWrongProof,
  attemptsLeft,
  decodeExact,
  lockSecondsLeft,
  openEnvelope,
  proofMatches,
  sealEnvelope,
  verifierFor,
} from '../vpin';
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
  // Retired (see the header). A new wrap would be a new offline-guessable envelope.
  if (process.env.VOIID_RECOVERY_PIN_WRAPS !== 'legacy') {
    return res.status(410).json({
      error: 'PIN backup has been replaced by your recovery phrase. Update Voiid and save your phrase.',
      code: 'pin_recovery_retired',
    });
  }
  const wrapped = req.body?.wrapped_key ?? req.body;
  if (!isValidWrappedKey(wrapped)) {
    return res.status(400).json({ error: 'invalid wrapped_key (expected { version:int, salt, nonce, ciphertext } as base64)' });
  }
  // Persist ONLY the four known fields — never store client-supplied extras.
  const value = pickWrappedKey(wrapped);
  await query(
    `insert into recovery_keys (user_id, wrapped_key, failed_attempts, locked_until, pin_version)
       values ($1, $2, 0, null, 1)
       on conflict (user_id) do update set
         wrapped_key     = excluded.wrapped_key,
         pin_version     = 1,
         pin_auth_salt   = null,
         pin_verifier    = null,
         sealed_envelope = null,
         failed_attempts = 0,
         locked_until    = null,
         fetch_count     = 0,
         last_fetched_at = null`,
    [user_id, JSON.stringify(value)]
  );
  res.json({ stored: true });
}));

// GET /recovery/status — does a legacy PIN wrap exist? Answers WITHOUT returning
// it, so it is not a fetch: the app uses it to decide whether to offer a PIN at all.
//
// `has_pin_wrap` keeps its original meaning — a LEGACY wrap — so an older app that reads
// it never offers its old PIN flow for a V PIN it cannot unlock. `vpin` is the new state:
// the salt the phone needs to compute its proof, attempts left, and any active lock.
router.get('/status', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query<{
    pin_version: number;
    pin_auth_salt: string | null;
    failed_attempts: number;
    locked_until: Date | null;
  }>(
    `select pin_version, pin_auth_salt, failed_attempts, locked_until
       from recovery_keys where user_id = $1`,
    [user_id]
  );
  const row = rows[0];
  if (!row || row.pin_version !== VPIN_VERSION) {
    return res.json({ has_pin_wrap: !!row, vpin: null });
  }
  const retryAfter = lockSecondsLeft(row.locked_until);
  res.json({
    has_pin_wrap: false,
    vpin: {
      auth_salt: row.pin_auth_salt,
      max_attempts: VPIN_MAX_ATTEMPTS,
      attempts_left: retryAfter === null ? attemptsLeft({ failedAttempts: row.failed_attempts, lockedUntil: null }) : 0,
      locked_until: retryAfter === null ? null : row.locked_until,
      retry_after: retryAfter,
    },
  });
}));

// DELETE /recovery/key — remove the caller's legacy PIN wrap. Called once the person
// has saved their recovery phrase. Only ever shrinks what can be attacked.
router.delete('/key', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query(`delete from recovery_keys where user_id = $1 returning user_id`, [user_id]);
  res.json({ deleted: rows.length > 0 });
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
    last_fetched_at: Date;
  }>(
    `update recovery_keys
        set fetch_count = case
              when last_fetched_at is null or last_fetched_at <= now() - ($3 * interval '1 second') then 1
              else least(fetch_count + 1, $2 + 1) end,
            last_fetched_at = case
              when last_fetched_at is null or last_fetched_at <= now() - ($3 * interval '1 second') or fetch_count < $2
              then now() else last_fetched_at end
      where user_id = $1 and pin_version = 1
      returning wrapped_key, locked_until, fetch_count, last_fetched_at`,
    [user_id, FETCH_LIMIT, FETCH_COOLDOWN_SECONDS]
  );
  const row = rows[0];
  if (!row) return notLegacy(user_id, res);

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
    const retryAfterSeconds = Math.max(1, Math.ceil((new Date(row.last_fetched_at).getTime()
      + FETCH_COOLDOWN_SECONDS * 1000 - Date.now()) / 1000));
    res.setHeader('Retry-After', String(retryAfterSeconds));
    return res.status(429).json({
      error: 'too many recovery key fetches',
      retry_after: retryAfterSeconds,
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
        where user_id = $1 and pin_version = 1 returning user_id`,
      [user_id]
    );
    if (!rows[0]) return notLegacy(user_id, res);
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
      where user_id = $1 and pin_version = 1 returning failed_attempts`,
    [user_id]
  );
  if (!rows[0]) return notLegacy(user_id, res);

  // applyFailure takes the PREVIOUS count and adds one, so hand it the value before
  // this increment; the database has already applied the +1.
  const state = applyFailure(rows[0].failed_attempts - 1);
  await query(
    `update recovery_keys set locked_until = greatest(locked_until, $2::timestamptz)
      where user_id = $1 and pin_version = 1`,
    [user_id, state.locked_until]
  );
  if (state.retry_after != null) res.setHeader('Retry-After', String(state.retry_after));
  res.json({
    failed_attempts: state.failed_attempts,
    locked_until: state.locked_until,
    retry_after: state.retry_after,
  });
}));

/**
 * A legacy route reached for a row that is not legacy. A V PIN answers 409 with a code the
 * apps recognise, so an outdated app says "update to use your V PIN" instead of "not set";
 * no row at all stays 404 as before.
 */
async function notLegacy(userId: string, res: any) {
  const rows = await query(`select 1 from recovery_keys where user_id = $1 and pin_version = $2`,
    [userId, VPIN_VERSION]);
  if (rows.length) {
    return res.status(409).json({ error: 'This account uses a V PIN. Update Voiid to use it.', code: 'vpin_required' });
  }
  return res.status(404).json({ error: 'no recovery key found' });
}

// ── V PIN ─────────────────────────────────────────────────────────────────────────

// PUT /recovery/pin { wrapped_key: {version,salt,nonce,ciphertext}, auth_salt, proof }
//
// Store (or replace) the caller's V PIN. The envelope is the backup key already locked on
// the phone with the PIN (e2e-core wrap_with_pin); `proof` is the phone's PBKDF2 of the
// PIN over `auth_salt`. The server keeps HMAC(proof) and the envelope sealed again — never
// the proof itself. Replacing a PIN clears any lock: the new envelope is a new secret, and
// a stolen token that "resets" the lock this way destroys the very envelope it wanted.
router.put('/pin', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  if (!secretboxAvailable()) {
    // Without the server key there is no verifier key and no sealing. Refuse loudly
    // rather than store a PIN that a database copy alone could attack.
    return res.status(503).json({ error: 'V PIN is not available on this server.', code: 'vpin_unavailable' });
  }
  const wrapped = req.body?.wrapped_key;
  const salt = decodeExact(req.body?.auth_salt, AUTH_SALT_BYTES);
  const proof = decodeExact(req.body?.proof, PROOF_BYTES);
  if (!isValidWrappedKey(wrapped) || !salt || !proof) {
    return res.status(400).json({
      error: `expected { wrapped_key: {version,salt,nonce,ciphertext}, auth_salt: ${AUTH_SALT_BYTES} bytes base64, proof: ${PROOF_BYTES} bytes base64 }`,
    });
  }
  await query(
    `insert into recovery_keys
       (user_id, wrapped_key, pin_version, pin_auth_salt, pin_verifier, sealed_envelope,
        failed_attempts, locked_until)
     values ($1, null, $2, $3, $4, $5, 0, null)
     on conflict (user_id) do update set
       wrapped_key     = null,
       pin_version     = excluded.pin_version,
       pin_auth_salt   = excluded.pin_auth_salt,
       pin_verifier    = excluded.pin_verifier,
       sealed_envelope = excluded.sealed_envelope,
       failed_attempts = 0,
       locked_until    = null,
       fetch_count     = 0,
       last_fetched_at = null`,
    [user_id, VPIN_VERSION, salt.toString('base64'), verifierFor(proof),
     sealEnvelope(user_id, pickWrappedKey(wrapped))]
  );
  res.json({ stored: true, max_attempts: VPIN_MAX_ATTEMPTS });
}));

// POST /recovery/pin/unlock { proof } → { wrapped_key } | 401 wrong | 429 locked
//
// THE LIMIT. One transaction holding the row lock, so two parallel guesses cannot both
// read "4 wrong" and both get a free fifth. Order matters:
//   1. locked?  → refuse, even if this proof is right. Checking the proof first would make
//                 the lock a delay rather than a limit.
//   2. wrong?   → count it; the 5th wrong locks for 24h.
//   3. right    → reset the counter and release the envelope.
// A malformed proof is refused without counting — it is a broken client, not a guess.
// Its own tight rate limit on top of the router's, keyed by user.
router.post('/pin/unlock', requireAuth,
  rateLimit({ max: 10, windowSeconds: 60, bucket: 'vpin-unlock' }),
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const proof = decodeExact(req.body?.proof, PROOF_BYTES);
    if (!proof) return res.status(400).json({ error: `proof must be ${PROOF_BYTES} bytes base64` });
    if (!secretboxAvailable()) {
      return res.status(503).json({ error: 'V PIN is not available on this server.', code: 'vpin_unavailable' });
    }

    const outcome = await withTransaction(async (execute) => {
      const rows = await execute<{
        pin_version: number;
        pin_verifier: string | null;
        sealed_envelope: string | null;
        failed_attempts: number;
        locked_until: Date | null;
      }>(
        `select pin_version, pin_verifier, sealed_envelope, failed_attempts, locked_until
           from recovery_keys where user_id = $1 for update`,
        [user_id]
      );
      const row = rows[0];
      if (!row) return { kind: 'none' as const };
      if (row.pin_version !== VPIN_VERSION || !row.pin_verifier) return { kind: 'legacy' as const };

      const locked = lockSecondsLeft(row.locked_until);
      if (locked !== null) return { kind: 'locked' as const, lockedUntil: row.locked_until!, retryAfter: locked };

      if (!proofMatches(proof, row.pin_verifier)) {
        const next = afterWrongProof({ failedAttempts: row.failed_attempts, lockedUntil: null });
        await execute(
          `update recovery_keys set failed_attempts = $2, locked_until = $3 where user_id = $1`,
          [user_id, next.failedAttempts, next.lockedUntil]
        );
        if (next.lockedUntil) {
          return { kind: 'locked' as const, lockedUntil: next.lockedUntil,
                   retryAfter: lockSecondsLeft(next.lockedUntil) ?? 0, justLocked: true };
        }
        return { kind: 'wrong' as const, attemptsLeft: attemptsLeft(next) };
      }

      await execute(
        `update recovery_keys set failed_attempts = 0, locked_until = null where user_id = $1`,
        [user_id]
      );
      return { kind: 'ok' as const, envelope: openEnvelope(user_id, row.sealed_envelope) };
    });

    switch (outcome.kind) {
      case 'none':
        return res.status(404).json({ error: 'No V PIN is set for this account.', code: 'vpin_not_set' });
      case 'legacy':
        return res.status(409).json({ error: 'This account uses the older PIN.', code: 'vpin_legacy' });
      case 'locked':
        res.setHeader('Retry-After', String(outcome.retryAfter));
        return res.status(429).json({
          error: 'Too many wrong V PINs. Try again later, or use your recovery phrase.',
          code: 'vpin_locked',
          locked_until: outcome.lockedUntil,
          retry_after: outcome.retryAfter,
          just_locked: 'justLocked' in outcome ? outcome.justLocked : false,
        });
      case 'wrong':
        return res.status(401).json({ error: 'Wrong V PIN.', code: 'vpin_wrong', attempts_left: outcome.attemptsLeft });
      case 'ok':
        // The right PIN, but the sealed envelope will not open: the server key changed
        // since it was stored. The PIN cannot be used; the phrase still can.
        if (!outcome.envelope) {
          return res.status(409).json({
            error: 'Your V PIN can no longer be used. Restore with your recovery phrase, then set a new V PIN.',
            code: 'vpin_unreadable',
          });
        }
        return res.json({ wrapped_key: outcome.envelope });
    }
  }));

export default router;
