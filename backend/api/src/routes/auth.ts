// Auth routes. Firebase Phone Auth runs on the CLIENT (it sends + verifies the
// OTP and returns a Firebase ID token). Our server verifies that token and
// issues OUR JWT — identity + JWT are ours (Section 2.2 boundary).
import { Router } from 'express';
import { query } from '../db';
import { issueBootstrapToken, requireAuth, revokeDeviceSessions } from '../auth';
import { clientIp, logSecurityEvent } from '../security';
import { verifyFirebaseToken } from '../firebase';
import { asyncHandler } from '../util';

const router = Router();

// POST /auth/firebase  { id_token }  -> verify with Firebase, upsert our user, issue our JWT.
// `id_token` is the Firebase ID token the app gets after completing Phone Auth.
// In dev (AUTH_DEV_BYPASS=1) a token "dev:<phone>" is accepted without Firebase.
router.post('/firebase', asyncHandler(async (req, res) => {
  const { id_token } = req.body ?? {};
  if (!id_token) return res.status(400).json({ error: 'id_token required' });

  let phone_number: string;
  try {
    ({ phone_number } = await verifyFirebaseToken(id_token));
  } catch (e) {
    // Log the REAL reason to the server console (pm2 logs) — e.g. wrong project
    // (audience mismatch), expired token, or missing phone_number. Not returned
    // to the client.
    console.error('[auth/firebase] verify failed:', (e as Error).message);
    // The address is the whole point of this record: without it a burst of failures is
    // an unattributable count, and credential stuffing looks like ordinary noise. Safe to
    // trust only because `trust proxy` is set (index.ts) — otherwise a caller could forge
    // failed logins against any address it liked.
    await logSecurityEvent('failed_login', {
      ip_address: clientIp(req) ?? undefined,
      metadata: { reason: 'firebase_verify_failed' },
    });
    return res.status(401).json({ error: 'invalid or expired token' });
  }

  // Upsert OUR user record (identity is ours, on Supabase Postgres).
  //
  // `deleted_at` is in the returning clause deliberately: without it this upsert quietly
  // resurrects a soft-deleted account and hands back a working 30-day token for an identity
  // that every read path filters out — an account neither erased nor usable.
  const userRows = await query<{ id: string; full_name: string | null; username: string | null; deleted_at: string | null }>(
    `insert into users (phone_number) values ($1)
       on conflict (phone_number) do update set updated_at = now()
       returning id, full_name, username, deleted_at`,
    [phone_number]
  );
  const user = userRows[0];

  // Fail closed rather than silently reinstate. Clearing deleted_at here would restore
  // everything the user asked us to erase on the strength of an OTP alone; if product wants
  // reinstatement inside the grace window it has to be a deliberate, audited action. The
  // number frees itself once the DPDP erasure job purges the row.
  if (user.deleted_at) {
    await logSecurityEvent('failed_login', {
      user_id: user.id,
      phone_number,
      ip_address: clientIp(req) ?? undefined,
      metadata: { reason: 'account_deleted' },
    });
    return res.status(403).json({ error: 'account deleted', code: 'account_deleted' });
  }

  // profile_complete = the user has already finished signup (name + username), so
  // the app can skip the Signup/Profile screens and go straight to the chats.
  const profile_complete = !!(user.full_name && user.username);

  // A BOOTSTRAP credential, not a session. Proving the phone number is not proving which
  // handset is holding it, so this token can do exactly one thing: register a device and
  // trade itself for a device-bound session (POST /devices/register returns that token).
  // Everything else is refused once VOIID_SESSION_CUTOFF has passed.
  res.json({ token: issueBootstrapToken(user.id), user_id: user.id, profile_complete });
}));

// POST /auth/logout — end THIS device's session, server-side.
//
// This used to return { ok: true } and do nothing at all: the token stayed valid for the
// rest of its 30 days, so "log out" meant "please forget this string" and a device whose
// user had signed out kept sending, fetching and uploading keys. The session row is now
// revoked, the device is marked revoked_by the user (so a prekey upload cannot quietly
// reinstate it), and any socket that device holds is closed.
//
// Scoped to the caller's OWN device. A legacy token naming no device has nothing to revoke —
// it is not bound to one — and says so rather than guessing which device to sign out.
router.post('/logout', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  if (!device_id) return res.json({ ok: true, revoked: false });

  // Ownership is re-checked in the statement itself: device_id arrives from a signed claim,
  // but a claim is not a row, and this write must never reach another account's device.
  const rows = await query<{ id: string }>(
    `update devices set revoked_at = now(), revoked_reason = 'user_revoked', updated_at = now()
      where id = $1 and user_id = $2
      returning id`,
    [device_id, user_id]
  );
  if (!rows[0]) return res.json({ ok: true, revoked: false });

  await revokeDeviceSessions([device_id], 'logout');
  await logSecurityEvent('device_revoked', { user_id, device_id, metadata: { via: 'logout' } });
  res.json({ ok: true, revoked: true });
}));

export default router;
