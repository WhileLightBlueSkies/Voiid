// User / profile routes (Section 10). Identity is ours (Supabase Postgres); profile is not E2E content.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';

const router = Router();

// Username rules (Clips feature only — NOT messaging identity): 3–20 chars,
// must start with a letter, lowercase letters/digits/underscore. Mirrors the DB
// CHECK constraint in migration 010. Returns null if valid, else a reason.
const USERNAME_RE = /^[a-z][a-z0-9_]{2,19}$/;
function usernameError(u: unknown): string | null {
  if (typeof u !== 'string') return 'username required';
  if (u.length < 3 || u.length > 20) return '3–20 characters';
  if (!USERNAME_RE.test(u)) return 'use lowercase letters, digits, underscore; start with a letter';
  return null;
}

// GET /users/username-available?username=foo — check format + availability.
// Registered BEFORE /:id so it isn't swallowed by the id route.
router.get('/username-available', requireAuth, async (req, res) => {
  const u = String(req.query.username ?? '').toLowerCase();
  const err = usernameError(u);
  if (err) return res.json({ available: false, reason: err });
  const rows = await query(
    `select 1 from users where lower(username) = $1 and deleted_at is null limit 1`,
    [u]
  );
  res.json({ available: rows.length === 0 });
});

// GET /users/:id — public profile (full_name shown when contact not saved locally).
router.get('/:id', requireAuth, async (req, res) => {
  const rows = await query(
    `select id, full_name, photo_url, bio, status_text, username from users where id = $1 and deleted_at is null`,
    [req.params.id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'user not found' });
  res.json({ user: rows[0] });
});

// POST /users/profile/update — { full_name?, email?, photo_url?, bio?, status_text?, username? }
router.post('/profile/update', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const { full_name, email, photo_url, bio, status_text, username } = req.body ?? {};

  // Build a partial update from only provided fields.
  const fields: string[] = [];
  const vals: unknown[] = [];
  const add = (col: string, v: unknown) => { if (v !== undefined) { fields.push(`${col} = $${fields.length + 1}`); vals.push(v); } };
  add('full_name', full_name);
  add('email', email);
  add('photo_url', photo_url);
  add('bio', bio);
  add('status_text', status_text);

  // Username (Clips handle): validate format, normalize to lowercase. Uniqueness
  // is enforced by the DB; we translate a unique-violation into a clean 409.
  if (username !== undefined) {
    const u = String(username).toLowerCase();
    const err = usernameError(u);
    if (err) return res.status(400).json({ error: `invalid username: ${err}` });
    add('username', u);
  }

  if (!fields.length) return res.status(400).json({ error: 'no fields to update' });

  vals.push(user_id);
  try {
    const rows = await query(
      `update users set ${fields.join(', ')} where id = $${vals.length} and deleted_at is null
         returning id, full_name, email, photo_url, bio, status_text, username`,
      vals
    );
    if (!rows[0]) return res.status(404).json({ error: 'user not found' });
    res.json({ user: rows[0] });
  } catch (e: any) {
    // 23505 = unique_violation (username taken between the availability check and now).
    if (e?.code === '23505') return res.status(409).json({ error: 'username already taken' });
    throw e;
  }
});

// GET /users/status/:id — online + last_seen (metadata, Section 4.8). Sourced from Redis presence.
router.get('/status/:id', requireAuth, async (req, res) => {
  const { redis } = await import('../redis');
  const online = await redis.get(`user:${req.params.id}:online`);
  const lastSeen = await redis.get(`user:${req.params.id}:last_seen`);
  res.json({
    user_id: req.params.id,
    online: online === '1',
    last_seen: lastSeen ? Number(lastSeen) : null,
  });
});

// POST /users/consent — DPDP lawful consent capture at signup (Section 4.13).
router.post('/consent', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  await query(`update users set consent_given_at = now() where id = $1`, [user_id]);
  res.json({ consent_recorded: true });
});

// DELETE /users/me — account deletion (DPDP true purge, Section 4.13).
// Soft-delete immediately; an erasure job performs the hard purge. Devices/prekeys removed now (revoke trust).
router.delete('/me', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  await query(`update users set deleted_at = now(), full_name = null, email = null, photo_url = null, bio = null, status_text = null where id = $1`, [user_id]);
  await query(`update devices set revoked_at = now() where user_id = $1`, [user_id]);
  res.json({ deleted: true, note: 'soft-deleted; hard purge runs via erasure job (DPDP)' });
});

export default router;
