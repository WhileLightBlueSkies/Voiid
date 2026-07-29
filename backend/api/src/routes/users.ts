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

// GET /users/:id — public profile, with per-field privacy enforced.
//   photo_privacy / about_privacy ∈ everyone | contacts | nobody. A 'contacts'-scoped
//   field is returned only when the VIEWER is someone the OWNER has saved (a contact_sync
//   row: owner = :id, contact = viewer). 'nobody' hides it from everyone but the owner.
router.get('/:id', requireAuth, async (req, res) => {
  const viewerId = (req as any).auth.user_id;
  const targetId = req.params.id;
  const rows = await query<{
    id: string; full_name: string | null; photo_url: string | null; bio: string | null;
    status_text: string | null; username: string | null; phone_number: string | null;
    photo_privacy: string; about_privacy: string;
    contact_pin_hash: string | null; contact_pin_set_at: string | null;
  }>(
    `select id, full_name, photo_url, bio, status_text, username, phone_number,
            photo_privacy, about_privacy, contact_pin_hash, contact_pin_set_at
       from users where id = $1 and deleted_at is null`,
    [targetId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'user not found' });
  const u = rows[0];

  // The owner always sees their own fields; otherwise apply the visibility rules.
  const isOwner = viewerId === targetId;
  let viewerIsContact = false;
  if (!isOwner && (u.photo_privacy === 'contacts' || u.about_privacy === 'contacts')) {
    const c = await query(
      `select 1 from contact_sync where owner_user_id = $1 and contact_user_id = $2 limit 1`,
      [targetId, viewerId]
    );
    viewerIsContact = c.length > 0;
  }
  const allowed = (scope: string) =>
    isOwner || scope === 'everyone' || (scope === 'contacts' && viewerIsContact);

  res.json({
    user: {
      id: u.id,
      full_name: u.full_name,
      username: u.username,
      status_text: u.status_text,
      photo_url: allowed(u.photo_privacy) ? u.photo_url : null,
      bio: allowed(u.about_privacy) ? u.bio : null,
      // The phone number is the account's identity and is returned ONLY to the owner
      // (self), never to anyone else — it is how a user recovers their own real number on
      // a device that didn't capture it at OTP time. Others never receive it.
      phone_number: isOwner ? u.phone_number : undefined,
      // Contact PIN state — OWNER ONLY, and never the PIN itself. The hash is one-way, so
      // the digits genuinely cannot be re-read; revealing it means rotating it
      // (POST /reachability/contact-pin/rotate), which is the point.
      //
      // Leaking `has_contact_pin` to a non-owner would be a small but real oracle: it tells
      // a stranger whether the account is reachable by handle at all. That answer belongs to
      // GET /reachability/by-username, which is the deliberate, rate-limited door for it.
      has_contact_pin: isOwner ? !!u.contact_pin_hash : undefined,
      contact_pin_set_at: isOwner ? u.contact_pin_set_at : undefined,
    },
  });
});

// POST /users/profile/update — { full_name?, email?, photo_url?, bio?, status_text?, username? }
router.post('/profile/update', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const { full_name, email, photo_url, bio, status_text, username,
          photo_privacy, about_privacy, last_seen_privacy } = req.body ?? {};
  const PRIVACY = new Set(['everyone', 'contacts', 'nobody']);

  // Diagnostic (presence only, no values) — shows whether the client actually
  // sends each field. Helps catch "email not saving" = app not sending it.
  console.log('[profile/update] fields present:',
    { name: full_name !== undefined, email: email !== undefined, username: username !== undefined,
      bio: bio !== undefined, photo: photo_url !== undefined });

  // Build a partial update from only provided fields.
  const fields: string[] = [];
  const vals: unknown[] = [];
  const add = (col: string, v: unknown) => { if (v !== undefined) { fields.push(`${col} = $${fields.length + 1}`); vals.push(v); } };
  add('full_name', full_name);
  add('email', email);
  add('photo_url', photo_url);
  add('bio', bio);
  add('status_text', status_text);
  // Privacy visibility — validate the enum so a bad value can't corrupt enforcement.
  for (const [col, v] of [['photo_privacy', photo_privacy], ['about_privacy', about_privacy],
                          ['last_seen_privacy', last_seen_privacy]] as const) {
    if (v !== undefined) {
      if (!PRIVACY.has(String(v))) return res.status(400).json({ error: `invalid ${col}` });
      add(col, v);
    }
  }

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

// GET /users/status/:id — online + last_seen, with last_seen_privacy enforced.
router.get('/status/:id', requireAuth, async (req, res) => {
  const viewerId = (req as any).auth.user_id;
  const targetId = req.params.id;
  const { redis } = await import('../redis');

  // Resolve last-seen visibility for THIS viewer.
  let showLastSeen = true;
  if (viewerId !== targetId) {
    const prow = await query<{ last_seen_privacy: string }>(
      `select last_seen_privacy from users where id = $1`, [targetId]);
    const scope = prow[0]?.last_seen_privacy ?? 'everyone';
    if (scope === 'nobody') showLastSeen = false;
    else if (scope === 'contacts') {
      const c = await query(
        `select 1 from contact_sync where owner_user_id = $1 and contact_user_id = $2 limit 1`,
        [targetId, viewerId]);
      showLastSeen = c.length > 0;
    }
  }

  const online = await redis.get(`user:${targetId}:online`);
  const lastSeen = showLastSeen ? await redis.get(`user:${targetId}:last_seen`) : null;
  res.json({
    user_id: targetId,
    // When last-seen is hidden, online is hidden too (they leak the same info).
    online: showLastSeen ? online === '1' : false,
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
