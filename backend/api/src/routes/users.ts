// User / profile routes (Section 10). Identity is ours (Supabase Postgres); profile is not E2E content.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';

const router = Router();

// GET /users/:id — public profile (full_name shown when contact not saved locally).
router.get('/:id', requireAuth, async (req, res) => {
  const rows = await query(
    `select id, full_name, photo_url, bio, status_text from users where id = $1 and deleted_at is null`,
    [req.params.id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'user not found' });
  res.json({ user: rows[0] });
});

// POST /users/profile/update — { full_name?, email?, photo_url?, bio?, status_text? }
router.post('/profile/update', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const { full_name, email, photo_url, bio, status_text } = req.body ?? {};

  // Build a partial update from only provided fields.
  const fields: string[] = [];
  const vals: unknown[] = [];
  const add = (col: string, v: unknown) => { if (v !== undefined) { fields.push(`${col} = $${fields.length + 1}`); vals.push(v); } };
  add('full_name', full_name);
  add('email', email);
  add('photo_url', photo_url);
  add('bio', bio);
  add('status_text', status_text);
  if (!fields.length) return res.status(400).json({ error: 'no fields to update' });

  vals.push(user_id);
  const rows = await query(
    `update users set ${fields.join(', ')} where id = $${vals.length} and deleted_at is null
       returning id, full_name, email, photo_url, bio, status_text`,
    vals
  );
  if (!rows[0]) return res.status(404).json({ error: 'user not found' });
  res.json({ user: rows[0] });
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
