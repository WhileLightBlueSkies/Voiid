// Auth routes (Section 10 Phase 0). Firebase = OTP sender only; our backend owns identity + JWT.
// OTP stored as HASH ONLY; expiry 5 min; max 3 attempts.
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { getSmsProvider } from '@voiid/common-utils';
import { query } from '../db';
import { issueToken } from '../auth';

const router = Router();
const sms = getSmsProvider();

function randomOtp(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

// POST /auth/request-otp  { phone_number }
router.post('/request-otp', async (req, res) => {
  const { phone_number } = req.body ?? {};
  if (!phone_number) return res.status(400).json({ error: 'phone_number required' });

  const code = randomOtp();
  const otp_hash = await bcrypt.hash(code, 10);
  const expires = new Date(Date.now() + 5 * 60 * 1000);

  await query(
    `insert into otp_sessions (phone_number, otp_hash, expires_at) values ($1, $2, $3)`,
    [phone_number, otp_hash, expires]
  );
  await sms.sendOtp(phone_number, code); // Firebase/MSG91 — sender only

  res.json({ sent: true, expires_at: expires });
});

// POST /auth/verify-otp  { phone_number, code }  -> upserts OUR user, issues OUR JWT
router.post('/verify-otp', async (req, res) => {
  const { phone_number, code } = req.body ?? {};
  if (!phone_number || !code) return res.status(400).json({ error: 'phone_number and code required' });

  const rows = await query<{ id: string; otp_hash: string; attempts: number; expires_at: string }>(
    `select id, otp_hash, attempts, expires_at from otp_sessions
       where phone_number = $1 and verified_at is null and expires_at > now()
       order by created_at desc limit 1`,
    [phone_number]
  );
  const session = rows[0];
  if (!session) return res.status(400).json({ error: 'no valid otp; request a new one' });
  if (session.attempts >= 3) return res.status(429).json({ error: 'too many attempts' });

  const ok = await bcrypt.compare(code, session.otp_hash);
  if (!ok) {
    await query(`update otp_sessions set attempts = attempts + 1 where id = $1`, [session.id]);
    return res.status(401).json({ error: 'invalid code' });
  }
  await query(`update otp_sessions set verified_at = now() where id = $1`, [session.id]);

  // Upsert OUR user record (identity is ours, on Supabase Postgres).
  const userRows = await query<{ id: string }>(
    `insert into users (phone_number) values ($1)
       on conflict (phone_number) do update set updated_at = now()
       returning id`,
    [phone_number]
  );
  const user_id = userRows[0].id;

  res.json({ token: issueToken({ user_id }), user_id });
});

// POST /auth/logout — client discards token; server-side revocation list is a Phase 0+ enhancement.
router.post('/logout', (_req, res) => res.json({ ok: true }));

export default router;
