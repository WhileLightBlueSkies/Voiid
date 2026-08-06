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
// endpoint, and no key, that would let one. The people-facing surfaces added below (the
// users list, the device viewer, the data-principal console) do not change that: they show
// ACCOUNT metadata and acts of administration, and there is nothing else for them to show.
//
// TWO ROLES (033_admin_roles.sql). `moderator` works the clip queue, all of whose actions
// are reversible. `admin` additionally holds every power that touches a PERSON or destroys
// data: the irreversible clip purge, the per-user device and security view, device
// revocation, and the whole DPDP console. The gate is `requireRole('admin')` applied per
// route rather than an `if` inside each handler, because the failure mode of a role system
// is a new privileged endpoint nobody remembered to gate, and a missing middleware in a
// route definition is visible in review in a way a missing branch is not.
import { Router } from 'express';
import type { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcryptjs';
import { createHash, randomBytes, timingSafeEqual } from 'crypto';
import { pool, query } from '../db';
import { presignGet, deleteObject, r2Configured } from '../r2';
import { clientIp } from '../security';
import { invalidateAccountState } from '../auth';

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

type AdminRole = 'moderator' | 'admin';

interface AdminAuth { adminId: string; email: string; name: string | null; role: AdminRole }

async function requireAdmin(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'admin auth required' });
  }
  const rows = await query<{ admin_id: string; email: string; name: string | null; role: string; disabled_at: string | null }>(
    `select s.admin_id, a.email, a.name, a.role, a.disabled_at
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
  // The role is read from the ROW on every request, not baked into the session at login.
  // A demotion has to take effect on the next request for the same reason a disable does:
  // the alternative is telling an operator "we removed their access" while a live tab keeps
  // the power they just took away.
  //
  // Anything other than 'admin' falls back to the least privilege rather than throwing, so
  // an unrecognised value in the column can only ever cost access, never grant it.
  const role: AdminRole = row.role === 'admin' ? 'admin' : 'moderator';
  (req as any).admin = { adminId: row.admin_id, email: row.email, name: row.name, role } as AdminAuth;
  next();
}

/**
 * Gate a route on a role. Always used AFTER requireAdmin, which is what populates req.admin.
 *
 * The denial is audited. An attempt to reach a privileged endpoint from a moderator session
 * is either a UI bug or the interesting half of an incident, and neither is discoverable if
 * the 403 is silent.
 */
function requireRole(required: AdminRole) {
  return async (req: Request, res: Response, next: NextFunction) => {
    const a = (req as any).admin as AdminAuth | undefined;
    if (!a) return res.status(401).json({ error: 'admin auth required' });
    if (required === 'admin' && a.role !== 'admin') {
      await audit(a.adminId, 'admin.forbidden', 'route', `${req.method} ${req.baseUrl}${req.path}`,
                  { role: a.role, required });
      return res.status(403).json({ error: 'this action requires the admin role' });
    }
    next();
  };
}

/**
 * Phone numbers are masked EVERYWHERE this router returns one, with no unmask endpoint.
 *
 * The admin plane's jobs are moderating public content and answering rights requests, and
 * neither needs to read a full phone number: a support case starts from a number somebody
 * already has, which the users search can confirm by lookup. So the panel can verify a
 * number you hold and cannot harvest one you do not — which is the whole of what the job
 * requires, and data minimisation applies to the admin plane too.
 *
 * Keeps the dialling prefix and the last two digits: enough to tell two accounts apart in a
 * list, not enough to dial or to re-identify.
 */
function maskPhone(phone: string | null): string | null {
  if (!phone) return null;
  if (phone.length <= 5) return '•'.repeat(phone.length);
  return `${phone.slice(0, 3)}${'•'.repeat(phone.length - 5)}${phone.slice(-2)}`;
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

/**
 * GET /admin/me — who am I, for the panel's header. Also the session-validity probe.
 *
 * `role` is returned so the panel can hide what this session cannot do. That is a courtesy
 * to the operator, NOT the control: every privileged route carries requireRole on the
 * server, and a hand-crafted request from a moderator session is refused there.
 */
router.get('/me', requireAdmin, (req, res) => {
  const a = (req as any).admin as AdminAuth;
  res.json({ email: a.email, name: a.name, role: a.role });
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
          and deleted_at is null)::int                                    as users_24h,
      -- The two numbers that make a rights queue visible on the screen people actually
      -- open. A DPDP request breaches its period by being forgotten, not by being refused,
      -- so the overdue count belongs where somebody will see it without navigating to it.
      (select count(*) from dpdp_requests where closed_at is null)::int    as dpdp_open,
      (select count(*) from dpdp_requests
        where closed_at is null and due_at < now())::int                  as dpdp_overdue
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
//
// ADMIN ROLE ONLY (033_admin_roles.sql). Every other action on the clip queue is
// reversible, and a moderator's whole job is performed with those. Handing the one
// irreversible action to everyone who can log in was the pre-role default, not a decision.
// ─────────────────────────────────────────────────────────────────────────────────
router.delete('/clips/:id', requireAdmin, requireRole('admin'), async (req, res) => {
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
// GET /admin/audit?action=&target_type=&target_id=&admin_id=&cursor=&limit=
//
// Who did what. The endpoint existed and worked; until now nothing rendered it, so the
// accountability record the panel writes on every action was write-only.
//
// KEYSET ON `id`, NOT OFFSET, for the reason the clips queue already documents: offset
// pagination re-scans and skips rows when the underlying set shifts mid-scroll. Here the
// set only grows at the head, but `id` is a bigserial issued in insertion order, so
// ordering by it is identical to ordering by created_at and gives a cursor that cannot
// tie — two entries written in the same millisecond would make a created_at cursor either
// repeat or skip one of them.
//
// Every filter is optional and every one of them is an equality on an indexed or
// low-cardinality column; there is deliberately no free-text search over `detail`, which
// would be a full scan over jsonb on a table that only grows.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/audit', requireAdmin, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : null);

  const action = str(req.query.action);
  const targetType = str(req.query.target_type);
  const targetId = str(req.query.target_id);
  const adminId = str(req.query.admin_id);
  const cursor = str(req.query.cursor);

  // Built positionally so an absent filter contributes no parameter at all — simpler to
  // read than a chain of `$n is null or col = $n`, and it keeps the planner honest.
  const where: string[] = [];
  const params: unknown[] = [limit];
  const add = (sql: string, value: unknown) => { params.push(value); where.push(sql.replace('$?', `$${params.length}`)); };

  if (action)     add('l.action = $?', action);
  if (targetType) add('l.target_type = $?', targetType);
  if (targetId)   add('l.target_id = $?', targetId);
  if (adminId)    add('l.admin_id = $?::uuid', adminId);
  if (cursor)     add('l.id < $?::bigint', cursor);

  const rows = await query<{ id: string }>(
    `select l.id, l.admin_id, l.action, l.target_type, l.target_id, l.detail, l.created_at,
            a.email as admin_email, a.name as admin_name
       from admin_audit_log l
       left join admin_users a on a.id = l.admin_id
      ${where.length ? `where ${where.join(' and ')}` : ''}
      order by l.id desc
      limit $1`,
    params
  );

  res.json({
    entries: rows,
    // Null when the page was not full, so the client stops rather than issuing one more
    // request that returns nothing.
    next_cursor: rows.length === limit ? rows[rows.length - 1].id : null,
  });
});

// ═════════════════════════════════════════════════════════════════════════════════
// PEOPLE
//
// Everything below this line concerns a PERSON rather than a piece of public content, and
// is gated accordingly. The line drawn between the two roles is:
//
//   * the users LIST is readable by a moderator, because the author of a reported clip has
//     to be identifiable to be moderated — and every phone number in it is masked, with no
//     endpoint anywhere that unmasks one;
//   * one named person's DEVICES and SECURITY HISTORY, and any action against their
//     account, require the admin role. That is a different kind of access from "who posted
//     this", and a moderation contractor has no reason to hold it.
//
// Nothing here reads content. It cannot: there is no key on this server.
// ═════════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/users?search=&cursor=&limit=&deleted=
//
// SEARCH IS EXACT-ISH BY DESIGN. A phone term must be at least 6 digits and matches by
// suffix; a username matches by prefix; a uuid matches exactly. What it deliberately does
// NOT support is the query that returns everyone whose number starts with a given operator
// prefix, because that is enumeration rather than lookup, and this list is the one place in
// the product where enumeration would be cheap.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/users', requireAdmin, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 30, 100);
  const cursor = typeof req.query.cursor === 'string' && req.query.cursor ? req.query.cursor : null;
  const deleted = req.query.deleted === 'true';
  const search = typeof req.query.search === 'string' ? req.query.search.trim() : '';

  const where: string[] = [deleted ? 'u.deleted_at is not null' : 'u.deleted_at is null'];
  const params: unknown[] = [limit];
  const add = (sql: string, value: unknown) => { params.push(value); where.push(sql.replace('$?', `$${params.length}`)); };

  if (search) {
    const digits = search.replace(/[^0-9]/g, '');
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(search)) {
      add('u.id = $?::uuid', search);
    } else if ((search.startsWith('+') || /^[0-9\s-]+$/.test(search)) && digits.length >= 6) {
      // Suffix match: numbers are stored E.164 with a country code the person searching
      // may not have typed. Anchored at the END so a partial prefix cannot sweep a range.
      add(`u.phone_number like '%' || $?`, digits);
    } else if (/^[0-9\s+-]+$/.test(search)) {
      // A short numeric term is rejected rather than silently treated as a name search,
      // which would look like "no such user" for a number that exists.
      return res.status(400).json({ error: 'phone search needs at least 6 digits' });
    } else {
      // Prefix, not substring: `%term%` on a name column is a full scan and, worse, lets
      // one query surface everyone whose name contains a common syllable.
      add(`(u.username ilike $? || '%' or u.full_name ilike $? || '%')`, search);
      // The `add` helper substitutes one placeholder; the second reference reuses it.
      where[where.length - 1] = where[where.length - 1].replace(
        /\$\d+ \|\| '%'\)$/, `$${params.length} || '%')`);
    }
  }
  if (cursor) add('u.created_at < $?', cursor);

  const rows = await query<any>(
    `select u.id, u.phone_number, u.username, u.full_name, u.created_at, u.deleted_at,
            u.consent_given_at,
            (select count(*) from clips c where c.author_id = u.id and c.deleted_at is null)::int as clip_count,
            (select count(*) from devices d where d.user_id = u.id and d.revoked_at is null)::int as device_count
       from users u
      where ${where.join(' and ')}
      order by u.created_at desc
      limit $1`,
    params
  );

  res.json({
    // The raw column never leaves this function. Masking in the SELECT would have been
    // tidier, but doing it here means one place to read and no way for a future `select
    // u.*` to route around it.
    users: rows.map(({ phone_number, ...u }) => ({ ...u, phone_masked: maskPhone(phone_number) })),
    next_cursor: rows.length === limit ? rows[rows.length - 1].created_at : null,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/users/:id — one person: devices, recent security events, consent, requests.
//
// ADMIN ROLE ONLY, and AUDITED AS A READ. Almost everything else in this router audits
// mutations only, which is the usual rule; this is the deliberate exception. Reading one
// named individual's device list and security history is the kind of access that gets
// misused quietly, and "nobody can tell who looked" is the property that makes it possible.
// One row per view is cheap.
//
// NO last_seen_at. The column exists on `devices` and is never written — grepping the
// backend finds three reads and zero writes — so surfacing it would render a permanently
// empty field that reads as "this device has never been used". Displaying a value we do not
// maintain is worse than omitting it. Writing it on every authenticated request is the fix,
// and it belongs in the auth path, not here.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/users/:id', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const id = req.params.id;

  const users = await query<any>(
    `select id, phone_number, username, full_name, email, bio, status_text,
            consent_given_at, created_at, updated_at, deleted_at
       from users where id = $1 limit 1`,
    [id]
  );
  const user = users[0];
  if (!user) return res.status(404).json({ error: 'not found' });

  const [devices, events, consents, requests] = await Promise.all([
    query(
      `select id, device_name, platform, registration_id, push_provider,
              os_version, app_version, created_at, revoked_at
         from devices where user_id = $1 order by created_at desc`,
      [id]
    ),
    // Bounded window AND bounded count: security_events is swept at 90 days
    // (030_dpdp.sql), so an unbounded query here would still be small — but "still small"
    // is a property of the retention worker running, and this endpoint should not depend
    // on that. `metadata` is included: unlike the user-facing export, an operator
    // investigating an incident is exactly who it is for.
    query(
      `select id, event_type, ip_address, metadata, created_at
         from security_events
        where user_id = $1 and created_at > now() - interval '90 days'
        order by created_at desc limit 100`,
      [id]
    ),
    query(
      `select notice_version, language, purposes, given_at, given_via, withdrawn_at, withdrawn_via
         from consent_records where user_id = $1 order by given_at desc`,
      [id]
    ),
    query(
      `select id, kind, status, opened_at, due_at, closed_at, resolution
         from dpdp_requests where user_id = $1 order by opened_at desc`,
      [id]
    ),
  ]);

  await audit(a.adminId, 'user.view', 'user', id);

  const { phone_number, ...rest } = user;
  res.json({
    user: { ...rest, phone_masked: maskPhone(phone_number) },
    devices,
    security_events: events,
    consent_records: consents,
    dpdp_requests: requests,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/users/:id/revoke-devices  { reason }
//
// Revokes every device on the account: no device can be sent to, and no prekey bundle is
// returned for one, so inbound sessions stop.
//
// WHAT THIS DOES NOT DO, stated here and repeated in the panel because an operator who
// believes otherwise will make a bad call in an incident: it does NOT end the user's API
// access. A Voiid user session is a stateless JWT valid for up to 30 days, and
// `POST /auth/logout` is a no-op — the same non-revocability the ADMIN plane explicitly
// rejected for itself (see the header of this file). Until user sessions are revocable
// server-side (repair plan Fix 9 / docs/research/11_admin_dpdp.md §2.7), this button
// removes the account's ability to RECEIVE, not its ability to act.
//
// A reason is required. "Why was this account cut off" is the question that arrives later,
// and an audit entry that cannot answer it is decoration.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/users/:id/revoke-devices', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const reason = String(req.body?.reason ?? '').trim();
  if (!reason) return res.status(400).json({ error: 'a reason is required' });

  const exists = await query<{ id: string }>(`select id from users where id = $1 limit 1`, [req.params.id]);
  if (!exists[0]) return res.status(404).json({ error: 'not found' });

  // `revoked_at is null` in the predicate keeps this idempotent and keeps the original
  // revocation timestamp: re-running it must not move the moment a device was cut off.
  const revoked = await query<{ id: string }>(
    `update devices set revoked_at = now()
      where user_id = $1 and revoked_at is null
      returning id`,
    [req.params.id]
  );

  await audit(a.adminId, 'user.revoke_devices', 'user', req.params.id,
              { reason, devices_revoked: revoked.length });
  res.json({
    ok: true,
    devices_revoked: revoked.length,
    note: 'Inbound sessions stopped. The user\'s existing API token remains valid until it expires — user sessions are not yet revocable server-side.',
  });
});

// ═════════════════════════════════════════════════════════════════════════════════
// THE DATA-PRINCIPAL REQUEST CONSOLE (repair plan 3.27; 034_dpdp_requests.sql)
//
// ADMIN ROLE ONLY, all of it. Working this queue means reading what somebody asked us
// about their own data and, for an erasure, starting something irreversible.
//
// The console holds no content and cannot produce any. What a rights request against an
// end-to-end-encrypted product can be answered with is metadata, and the export that
// answers it is assembled in routes/dpdp.ts from an allow-list that is checked at boot.
//
// [COUNSEL] The response periods on these rows are engineering placeholders written by
// routes/dpdp.ts from a named constant, and nothing in this console asserts that any of
// them is the legally required one. See docs/research/11_admin_dpdp.md §6.
// ═════════════════════════════════════════════════════════════════════════════════

/**
 * Which statuses a request may move to from which.
 *
 * A TABLE, not a chain of ifs, because the interesting property is what is ABSENT: there is
 * no transition out of `done` or `rejected`. A closed request stays closed — reopening one
 * would silently restart an SLA clock that has already been reported as met, and the honest
 * way to revisit a decision is a new request that says so.
 */
const DPDP_TRANSITIONS: Record<string, string[]> = {
  verifying:   ['open'],
  in_progress: ['open', 'verifying'],
  done:        ['open', 'verifying', 'in_progress'],
  rejected:    ['open', 'verifying', 'in_progress'],
};

const DPDP_TERMINAL = new Set(['done', 'rejected']);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/dpdp?status=open|closed|all&kind=&cursor=&limit=
//
// The queue. Open requests are ordered by DUE DATE ascending — the oldest deadline first,
// not the newest request — because the only way this queue fails is by something reaching
// its period while sitting behind newer work. Closed requests order by closure, newest
// first, which is how anyone reads a history.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/dpdp', requireAdmin, requireRole('admin'), async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const status = req.query.status === 'closed' ? 'closed' : req.query.status === 'all' ? 'all' : 'open';
  const kind = typeof req.query.kind === 'string' && req.query.kind ? req.query.kind : null;
  const cursor = typeof req.query.cursor === 'string' && req.query.cursor ? req.query.cursor : null;

  const where: string[] = [];
  const params: unknown[] = [limit];
  const add = (sql: string, value: unknown) => { params.push(value); where.push(sql.replace('$?', `$${params.length}`)); };

  if (status === 'open')   where.push('r.closed_at is null');
  if (status === 'closed') where.push('r.closed_at is not null');
  if (kind) add('r.kind = $?', kind);
  if (cursor) add(status === 'open' ? 'r.due_at > $?' : 'r.closed_at < $?', cursor);

  const rows = await query<any>(
    `select r.id, r.user_id, r.kind, r.status, r.subject_note, r.opened_at, r.due_at,
            r.closed_at, r.resolution, r.notes, r.redacted_at,
            (r.closed_at is null and r.due_at < now()) as overdue,
            u.username, u.phone_number, u.deleted_at as subject_deleted_at,
            h.email as handled_by_email
       from dpdp_requests r
       left join users u on u.id = r.user_id
       left join admin_users h on h.id = r.handled_by
      ${where.length ? `where ${where.join(' and ')}` : ''}
      order by ${status === 'open' ? 'r.due_at asc' : 'r.closed_at desc nulls last'}
      limit $1`,
    params
  );

  res.json({
    requests: rows.map(({ phone_number, ...r }) => ({ ...r, phone_masked: maskPhone(phone_number) })),
    next_cursor: rows.length === limit
      ? (status === 'open' ? rows[rows.length - 1].due_at : rows[rows.length - 1].closed_at)
      : null,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/dpdp/:id/status  { status, resolution?, notes? }
//
// ONE CONDITIONAL UPDATE, not select-then-update. Two operators working the queue at once
// would otherwise both read `in_progress` and both write a closure, and the second would
// overwrite the first's resolution and move `closed_at` forward — falsifying the one
// timestamp the row exists to record. The allowed source statuses go into the predicate, so
// a losing writer matches no row and is told so.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/dpdp/:id/status', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const status = String(req.body?.status ?? '');
  const from = DPDP_TRANSITIONS[status];
  if (!from) {
    return res.status(400).json({
      error: `status must be one of: ${Object.keys(DPDP_TRANSITIONS).join(', ')} ` +
             `(a closed request cannot be reopened — open a new one)`,
    });
  }

  const terminal = DPDP_TERMINAL.has(status);
  const resolution = String(req.body?.resolution ?? '').trim() || null;
  const notes = typeof req.body?.notes === 'string' ? req.body.notes.trim().slice(0, 4000) || null : null;

  // Enforced here as well as by dpdp_closed_needs_resolution, so the operator gets "say
  // what you did" rather than a constraint-violation 500.
  if (terminal && !resolution) {
    return res.status(400).json({ error: 'closing a request requires a resolution' });
  }

  const rows = await query<any>(
    `update dpdp_requests
        set status      = $2,
            handled_by  = $3,
            closed_at   = case when $4::boolean then now() else null end,
            resolution  = coalesce($5, resolution),
            notes       = coalesce($6, notes)
      where id = $1
        and status = any($7::text[])
      returning id, kind, status, opened_at, due_at, closed_at, resolution`,
    [req.params.id, status, a.adminId, terminal, resolution, notes, from]
  );
  if (!rows[0]) {
    return res.status(409).json({
      error: 'request not found, already closed, or not in a status this transition allows',
    });
  }

  await audit(a.adminId, 'dpdp.status', 'dpdp_request', req.params.id,
              { to: status, from_allowed: from, kind: rows[0].kind });
  res.json({ request: rows[0] });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/dpdp/:id/start-erasure  { confirm: true }
//
// The one irreversible thing in the console. It does exactly what `DELETE /users/me` does
// — soft-delete the row, null the profile text, revoke every device, drop the cached
// account-state verdict — after which backend/workers/src/erasure.ts owns the actual purge
// once the grace period elapses.
//
// SCOPED THROUGH THE REQUEST ROW, DELIBERATELY. There is no "delete this account" endpoint
// keyed on a user id. The only way to reach this code is a dpdp_requests row of kind
// `erasure` that is open and belongs to an identified principal — so an admin cannot erase
// an account without a recorded request to point at, and widening it later would mean
// visibly removing that constraint rather than adding a parameter.
//
// [COUNSEL] docs/research/11_admin_dpdp.md §2.10 asks whether a re-login inside the grace
// window CANCELS an erasure request or whether the account is already gone. This endpoint
// does not answer it: it sets the same flag the self-service path sets, and the worker
// implements "already gone" by re-checking deleted_at inside its transaction. If counsel
// chooses reinstatement, the change is a deliberate audited un-delete elsewhere, not a
// behaviour change here.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/dpdp/:id/start-erasure', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  // A typed confirmation, because a misclick here is not recoverable.
  if (req.body?.confirm !== true) {
    return res.status(400).json({ error: 'confirm must be true' });
  }

  const client = await pool.connect();
  try {
    await client.query('begin');

    // FOR UPDATE on the request row: two admins hitting this at once must not both run the
    // deletion, and the row lock is what serialises them. The kind/status predicate is what
    // makes the endpoint unable to erase anything that is not a live erasure request.
    const reqRows = await client.query<{ id: string; user_id: string | null; status: string }>(
      `select id, user_id, status from dpdp_requests
        where id = $1 and kind = 'erasure' and closed_at is null
        for update`,
      [req.params.id]
    );
    const request = reqRows.rows[0];
    if (!request) {
      await client.query('rollback');
      return res.status(404).json({ error: 'no open erasure request with that id' });
    }
    if (!request.user_id) {
      await client.query('rollback');
      // The subject is already erased — the FK nulled the link (034_dpdp_requests.sql).
      return res.status(409).json({ error: 'this request no longer has a subject; it was already erased' });
    }

    // The same statements as DELETE /users/me, in the same order, because divergence
    // between two paths that both mean "delete this account" is how one of them ends up
    // leaving something behind.
    const deleted = await client.query<{ id: string }>(
      `update users
          set deleted_at = now(), full_name = null, email = null,
              photo_url = null, bio = null, status_text = null
        where id = $1 and deleted_at is null
        returning id`,
      [request.user_id]
    );
    await client.query(
      `update devices set revoked_at = now() where user_id = $1 and revoked_at is null`,
      [request.user_id]
    );
    await client.query(
      `update dpdp_requests set status = 'in_progress', handled_by = $2 where id = $1`,
      [request.id, a.adminId]
    );

    await client.query('commit');

    // AFTER the commit. Dropping the cached "is this account live" verdict before the
    // transaction lands would let a request in the gap re-populate the cache with the old
    // answer, which is the one thing the invalidation exists to prevent.
    await invalidateAccountState(request.user_id);

    await audit(a.adminId, 'dpdp.start_erasure', 'user', request.user_id,
                { request_id: request.id, already_deleted: deleted.rowCount === 0 });

    res.json({
      ok: true,
      // Honest about the case where the user had already deleted themselves: the request is
      // still progressed, but nothing new happened to the account.
      already_deleted: deleted.rowCount === 0,
      note: 'Account soft-deleted. The erasure worker purges it after the grace period; close ' +
            'this request with a resolution once it has.',
    });
  } catch (err) {
    await client.query('rollback').catch(() => { /* the connection is going back to the pool either way */ });
    throw err;
  } finally {
    client.release();
  }
});

export default router;
export { requireAdmin, requireRole };
