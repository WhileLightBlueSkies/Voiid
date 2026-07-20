// Account recovery routes (pairs with e2e-core src/recovery.rs). The server stores
// ONLY the opaque PinWrappedSecret (Argon2id + AES-256-GCM wrap of the master
// backup secret) and never sees the PIN or the secret. The separate BIP39 recovery
// phrase is CLIENT-SIDE ONLY — nothing is stored here for it.
//
// SECURITY MODEL: failed_attempts/locked_until below are SERVER-SIDE guess limiting
// that slows ONLINE PIN guessing (recovering on a new device). A fully-breached
// server + a weak PIN is still offline-brute-forceable against the stored wrap
// (accepted "no-SGX" trade-off); the strong fallback is the BIP39 phrase. An
// SGX-backed secure value recovery (SVR) service is a future upgrade that would
// close the offline attack.
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
         locked_until    = null`,
    [user_id, JSON.stringify(value)]
  );
  res.json({ stored: true });
}));

// GET /recovery/key — return the stored wrap so the caller can attempt PIN unwrap.
// 429 (with Retry-After) while locked out from too many failed online attempts;
// 404 if the user never stored a wrap.
router.get('/key', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query<{ wrapped_key: unknown; locked_until: Date | null }>(
    `select wrapped_key, locked_until from recovery_keys where user_id = $1`,
    [user_id]
  );
  const row = rows[0];
  if (!row) return res.status(404).json({ error: 'no recovery key found' });

  const retryAfter = lockRetryAfter(row.locked_until);
  if (retryAfter !== null) {
    res.setHeader('Retry-After', String(retryAfter));
    return res.status(429).json({ error: 'recovery locked', retry_after: retryAfter, locked_until: row.locked_until });
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

  const rows = await query<{ failed_attempts: number }>(
    `select failed_attempts from recovery_keys where user_id = $1`,
    [user_id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'no recovery key found' });

  if (success) {
    const state = applySuccess();
    await query(
      `update recovery_keys set failed_attempts = 0, locked_until = null where user_id = $1`,
      [user_id]
    );
    return res.json({ failed_attempts: state.failed_attempts, locked_until: state.locked_until });
  }

  // Wrong PIN — increment, and once past the threshold apply an escalating cooldown.
  const state = applyFailure(rows[0].failed_attempts);
  await query(
    `update recovery_keys set failed_attempts = $2, locked_until = $3 where user_id = $1`,
    [user_id, state.failed_attempts, state.locked_until]
  );
  if (state.retry_after != null) res.setHeader('Retry-After', String(state.retry_after));
  res.json({
    failed_attempts: state.failed_attempts,
    locked_until: state.locked_until,
    retry_after: state.retry_after,
  });
}));

export default router;
