// Auth routes. Firebase Phone Auth runs on the CLIENT (it sends + verifies the
// OTP and returns a Firebase ID token). Our server verifies that token and
// issues OUR JWT — identity + JWT are ours (Section 2.2 boundary).
import { Router } from 'express';
import { query } from '../db';
import { issueToken } from '../auth';
import { logSecurityEvent } from '../security';
import { verifyFirebaseToken } from '../firebase';

const router = Router();

// POST /auth/firebase  { id_token }  -> verify with Firebase, upsert our user, issue our JWT.
// `id_token` is the Firebase ID token the app gets after completing Phone Auth.
// In dev (AUTH_DEV_BYPASS=1) a token "dev:<phone>" is accepted without Firebase.
router.post('/firebase', async (req, res) => {
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
    await logSecurityEvent('failed_login', { metadata: { reason: 'firebase_verify_failed' } });
    return res.status(401).json({ error: 'invalid or expired token' });
  }

  // Upsert OUR user record (identity is ours, on Supabase Postgres).
  const userRows = await query<{ id: string; full_name: string | null; username: string | null }>(
    `insert into users (phone_number) values ($1)
       on conflict (phone_number) do update set updated_at = now()
       returning id, full_name, username`,
    [phone_number]
  );
  const user = userRows[0];

  // profile_complete = the user has already finished signup (name + username), so
  // the app can skip the Signup/Profile screens and go straight to the chats.
  const profile_complete = !!(user.full_name && user.username);

  res.json({ token: issueToken({ user_id: user.id }), user_id: user.id, profile_complete });
});

// POST /auth/logout — client discards token; server-side revocation is a later enhancement.
router.post('/logout', (_req, res) => res.json({ ok: true }));

export default router;
