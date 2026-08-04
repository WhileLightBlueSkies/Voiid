// Admin routes — the moderation plane (see 028_admin_users.sql).
//
// A SEPARATE AUTH SYSTEM, ON PURPOSE. Every other router here authenticates a Voiid USER via
// `requireAuth`, which resolves a JWT minted from an SMS OTP. This one does not, and must
// not: a phone number is a credential someone else's carrier controls, and a SIM swap should
// never also grant the ability to read every clip on the platform. Admins have their own
// table, their own email+password credential, and no path from a user session to this plane.
//
// SESSIONS ARE SERVER-SIDE. A stateless JWT cannot be revoked before it expires — a lost
// admin laptop would mean waiting it out or rotating the signing secret for everyone. A row
// can be deleted. For a plane that can take content down, instant revocation is worth the
// lookup on every request.
//
// NOTHING HERE TOUCHES E2EE CONTENT. Admins can read clips because clips are public
// plaintext by design (022_clips.sql). Messages, calls, locations and moments remain
// end-to-end encrypted and are not readable from this router or any other — there is no
// endpoint, and no key, that would let one.
import { Router } from 'express';
import type { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcryptjs';
import { createHash, randomBytes, timingSafeEqual } from 'crypto';
import { pool, query } from '../db';
import { presignGet, deleteObject, r2Configured } from '../r2';

const router = Router();

/** 12 hours. Long enough for a working session, short enough that a forgotten laptop lapses. */
const SESSION_TTL_SECONDS = 12 * 60 * 60;

/**
 * Tokens are stored HASHED, never raw.
 *
 * SHA-256 rather than bcrypt, deliberately: this is a 256-bit random value, not a
 * user-chosen password, so there is no dictionary to slow down — and it is checked on every
 * request, where bcrypt's cost would be paid on every page load for no security gain.
 */
function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

function clientIp(req: Request): string | null {
  return (req.headers['x-forwarded-for'] as string)?.split(',')[0]?.trim()
    || req.socket?.remoteAddress
    || null;
}

/** Record an admin action. Best-effort: a failed audit write must not fail the action. */
async function audit(adminId: string | null, action: string,
                     targetType?: string, targetId?: string, detail?: unknown) {
  try {
    await query(
      `insert into admin_audit_log (admin_id, action, target_type, target_id, detail)
       values ($1, $2, $3, $4, $5)`,
      [adminId, action, targetType ?? null, targetId ?? null,
       detail == null ? null : JSON.stringify(detail)]
    );
  } catch {
    // Swallow. An audit failure is worth neither a 500 nor blocking a takedown.
  }
}

// ─────────────────────────────────────────────────────────────────────────────────
// Auth middleware
// ─────────────────────────────────────────────────────────────────────────────────

interface AdminAuth { adminId: string; email: string; name: string | null }

async function requireAdmin(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'admin auth required' });
  }
  const rows = await query<{ admin_id: string; email: string; name: string | null; disabled_at: string | null }>(
    `select s.admin_id, a.email, a.name, a.disabled_at
       from admin_sessions s
       join admin_users a on a.id = s.admin_id
      where s.token_hash = $1 and s.expires_at > now()
      limit 1`,
    [hashToken(header.slice(7))]
  );
  const row = rows[0];
  // A disabled admin's sessions die immediately rather than lingering until expiry — that
  // is most of the point of revocable sessions.
  if (!row || row.disabled_at) {
    return res.status(401).json({ error: 'invalid or expired session' });
  }
  (req as any).admin = { adminId: row.admin_id, email: row.email, name: row.name } as AdminAuth;
  next();
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/login  { email, password }
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/login', async (req, res) => {
  const email = String(req.body?.email ?? '').trim().toLowerCase();
  const password = String(req.body?.password ?? '');
  if (!email || !password) return res.status(400).json({ error: 'email and password required' });

  const rows = await query<{ id: string; password_hash: string; name: string | null; disabled_at: string | null }>(
    `select id, password_hash, name, disabled_at from admin_users where lower(email) = $1 limit 1`,
    [email]
  );
  const admin = rows[0];

  // ONE indistinguishable failure for "no such admin", "wrong password" and "disabled".
  // Anything else turns this endpoint into an oracle for which emails are admins — the
  // single most useful thing an attacker could learn from it.
  //
  // bcrypt.compare runs even with no matching row, against a dummy hash, so the response
  // time does not reveal whether the email exists.
  const hash = admin?.password_hash
    ?? '$2a$10$invalidinvalidinvalidinvalidinvalidinvalidinvalidinvalidinv';
  const ok = await bcrypt.compare(password, hash);
  if (!admin || !ok || admin.disabled_at) {
    await audit(admin?.id ?? null, 'admin.login_failed', 'admin', email,
                { ip: clientIp(req) });
    return res.status(401).json({ error: 'invalid credentials' });
  }

  const token = randomBytes(32).toString('base64url');
  await query(
    `insert into admin_sessions (token_hash, admin_id, expires_at, user_agent, ip)
     values ($1, $2, now() + ($3 || ' seconds')::interval, $4, $5)`,
    [hashToken(token), admin.id, String(SESSION_TTL_SECONDS),
     req.headers['user-agent'] ?? null, clientIp(req)]
  );
  await query(`update admin_users set last_login_at = now() where id = $1`, [admin.id]);
  await audit(admin.id, 'admin.login', 'admin', admin.id, { ip: clientIp(req) });

  res.json({ token, expires_in: SESSION_TTL_SECONDS, name: admin.name, email });
});

// POST /admin/logout — delete THIS session (not every session for the admin).
router.post('/logout', requireAdmin, async (req, res) => {
  const header = req.headers.authorization!;
  await query(`delete from admin_sessions where token_hash = $1`, [hashToken(header.slice(7))]);
  res.json({ ok: true });
});

/** GET /admin/me — who am I, for the panel's header. Also the session-validity probe. */
router.get('/me', requireAdmin, (req, res) => {
  const a = (req as any).admin as AdminAuth;
  res.json({ email: a.email, name: a.name });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/stats — the dashboard's top row.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/stats', requireAdmin, async (_req, res) => {
  const rows = await query<Record<string, number>>(`
    select
      (select count(*) from users where deleted_at is null)::int          as users,
      (select count(*) from clips where removed_at is null)::int          as clips,
      (select count(*) from clips where removed_at is not null)::int      as clips_removed,
      (select count(*) from clip_comments)::int                           as comments,
      (select count(*) from clips
        where created_at > now() - interval '24 hours'
          and removed_at is null)::int                                    as clips_24h,
      (select count(*) from users
        where created_at > now() - interval '24 hours'
          and deleted_at is null)::int                                    as users_24h
  `);
  res.json(rows[0] ?? {});
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/clips?cursor=&limit=&removed=
//
// The moderation queue. Newest first, keyset-paginated on created_at rather than OFFSET:
// offset pagination re-scans and, worse, SKIPS rows when something is removed mid-scroll —
// which on a moderation queue means missing the clip you were looking for.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/clips', requireAdmin, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 30, 100);
  const cursor = typeof req.query.cursor === 'string' ? req.query.cursor : null;
  const removed = req.query.removed === 'true';

  const rows = await query<any>(
    `select c.id, c.author_id, c.caption, c.thumb_r2_key, c.r2_key,
            c.duration_ms, c.width, c.height, c.byte_size, c.created_at,
            c.removed_at, c.removed_reason,
            c.like_count, c.view_count, c.comment_count,
            u.full_name as author_name, u.username as author_username
       from clips c
       left join users u on u.id = c.author_id
      where ${removed ? 'c.removed_at is not null' : 'c.removed_at is null'}
        ${cursor ? 'and c.created_at < $2' : ''}
      order by c.created_at desc
      limit $1`,
    cursor ? [limit, cursor] : [limit]
  );

  // Thumbnails are signed here rather than returned as raw keys: the panel cannot reach R2
  // directly, and a moderation list without pictures is unusable for its one job.
  const clips = await Promise.all(rows.map(async (c) => ({
    ...c,
    thumb_url: r2Configured() && c.thumb_r2_key
      ? await presignGet(c.thumb_r2_key).catch(() => null)
      : null,
  })));

  res.json({
    clips,
    // Null when the page was not full — the client uses that to stop, rather than issuing
    // one more request that returns nothing.
    next_cursor: rows.length === limit ? rows[rows.length - 1].created_at : null,
  });
});

/** GET /admin/clips/:id/playback — a signed URL for the actual video, to review it. */
router.get('/clips/:id/playback', requireAdmin, async (req, res) => {
  const rows = await query<{ r2_key: string; r2_key_sd: string | null }>(
    `select r2_key, r2_key_sd from clips where id = $1 limit 1`, [req.params.id]);
  const clip = rows[0];
  if (!clip) return res.status(404).json({ error: 'not found' });
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  // SD when available — a moderator is judging content, not picture quality, and the
  // smaller rendition loads faster on a queue you are scrolling through.
  const key = clip.r2_key_sd ?? clip.r2_key;
  res.json({ url: await presignGet(key) });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/clips/:id/remove  { reason }
//
// SOFT delete. The row and the media stay; only visibility changes. A mistaken takedown is
// recoverable, and a disputed one has a record — a hard DELETE destroys the evidence of why
// something was removed, which is exactly what you need when the author asks.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/clips/:id/remove', requireAdmin, async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const reason = String(req.body?.reason ?? '').trim() || null;

  const rows = await query<{ id: string; author_id: string }>(
    `update clips
        set removed_at = now(), removed_by = $2, removed_reason = $3
      where id = $1 and removed_at is null
      returning id, author_id`,
    [req.params.id, a.adminId, reason]
  );
  if (!rows[0]) return res.status(404).json({ error: 'not found or already removed' });

  await audit(a.adminId, 'clip.remove', 'clip', req.params.id,
              { reason, author_id: rows[0].author_id });
  res.json({ ok: true });
});

/** POST /admin/clips/:id/restore — undo a takedown. */
router.post('/clips/:id/restore', requireAdmin, async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const rows = await query<{ id: string }>(
    `update clips set removed_at = null, removed_by = null, removed_reason = null
      where id = $1 and removed_at is not null
      returning id`,
    [req.params.id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'not found or not removed' });
  await audit(a.adminId, 'clip.restore', 'clip', req.params.id);
  res.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────────────────
// DELETE /admin/clips/:id — PERMANENT: the row and every R2 object.
//
// Separate from remove/ for a reason: this one cannot be undone, and the two must never be
// one endpoint with a flag. Reserved for content that genuinely must not persist anywhere.
// ─────────────────────────────────────────────────────────────────────────────────
router.delete('/clips/:id', requireAdmin, async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const rows = await query<{ r2_key: string; thumb_r2_key: string; r2_key_sd: string | null; r2_key_hd: string | null; author_id: string }>(
    `select r2_key, thumb_r2_key, r2_key_sd, r2_key_hd, author_id from clips where id = $1 limit 1`,
    [req.params.id]
  );
  const clip = rows[0];
  if (!clip) return res.status(404).json({ error: 'not found' });

  // R2 FIRST. The keys only exist in the row, so deleting the row first would orphan the
  // objects with nothing left to enumerate them by — storage paid for forever.
  for (const key of [clip.r2_key, clip.thumb_r2_key, clip.r2_key_sd, clip.r2_key_hd]) {
    if (key) await deleteObject(key).catch(() => { /* already gone is success */ });
  }
  await query(`delete from clips where id = $1`, [req.params.id]);

  await audit(a.adminId, 'clip.purge', 'clip', req.params.id, { author_id: clip.author_id });
  res.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/audit — who did what.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/audit', requireAdmin, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const rows = await query(
    `select l.id, l.action, l.target_type, l.target_id, l.detail, l.created_at,
            a.email as admin_email, a.name as admin_name
       from admin_audit_log l
       left join admin_users a on a.id = l.admin_id
      order by l.created_at desc
      limit $1`,
    [limit]
  );
  res.json({ entries: rows });
});

export default router;
export { requireAdmin };
