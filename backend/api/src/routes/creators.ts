// Creator profiles + the follow graph — the public identity behind Clips.
//
// ============================ NOT END-TO-END ENCRYPTED ============================
// Read the header of 029_creator_profiles.sql before touching this file. A creator profile
// is broadcast identity: shown to strangers, server-counted, discoverable by search. None of
// that is expressible under E2EE. Messages, calls, locations and moments are unaffected.
// =================================================================================
//
// ── A FOLLOW IS NOT A MESSAGING RIGHT ────────────────────────────────────────────
// Nothing in this file may ever be read by reachability.ts to authorise a conversation.
// Following someone lets you watch their public clips and nothing else; the three paths in
// 020_reachability.sql (mutual contact / one-way contact / @username + PIN) remain the only
// ways to open a chat. A creator with a million followers gains zero inbound message rights.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';
import { presignGet, presignPut, r2Configured } from '../r2';

const router = Router();

const HANDLE_RE = /^[a-z][a-z0-9_]{2,19}$/;
const MAX_DISPLAY_NAME = 40;
const MAX_BIO = 160;
const MAX_LINK = 200;
const LIST_LIMIT_DEFAULT = 30;
const LIST_LIMIT_MAX = 60;

function clampLimit(raw: unknown, def: number, max: number): number {
  const n = typeof raw === 'string' ? parseInt(raw, 10) : NaN;
  return Number.isFinite(n) ? Math.min(Math.max(n, 1), max) : def;
}

/**
 * Postgres raises unique_violation (23505) both from the lower() indexes and from the
 * cross-table trigger in 029. Either way the user-facing truth is the same — the name is
 * gone — so it becomes a 409 rather than a 500.
 */
function isTaken(e: unknown): boolean {
  return typeof e === 'object' && e !== null && (e as { code?: string }).code === '23505';
}

/** Public shape. Deliberately omits user_id: see the note in GET /:handle. */
async function publicProfile(row: any, viewerId: string) {
  const [{ following }] = await query<{ following: boolean }>(
    `select exists (select 1 from creator_follows
                     where follower_id = $1 and followee_id = $2) as following`,
    [viewerId, row.user_id]
  );
  return {
    handle: row.handle,
    display_name: row.display_name,
    bio: row.bio,
    link_url: row.link_url,
    avatar_url: r2Configured() && row.avatar_r2_key
      ? await presignGet(row.avatar_r2_key).catch(() => null)
      : null,
    follower_count: row.follower_count,
    following_count: row.following_count,
    clip_count: row.clip_count,
    is_verified: row.is_verified,
    is_self: row.user_id === viewerId,
    following,
  };
}

// ─────────────────────────────────────────────────────────────────────────────────
// GET /creators/me -> { profile } | { profile: null }
//
// null is a 200, not a 404. "You have no creator profile yet" is the normal state for the
// vast majority of users — they are here to message — and making the client treat it as an
// error would mean every Clips screen opens by handling a failure.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/me', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query<any>(
    `select * from creator_profiles where user_id = $1`, [user_id]);
  if (!rows[0]) return res.json({ profile: null });
  return res.json({ profile: await publicProfile(rows[0], user_id) });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /creators/handle-available?handle=
//
// So the composer can show "taken" as you type rather than at submit. This is ADVISORY, and
// the create endpoint re-checks under the real constraint — between this call and the insert
// someone else can take the name, and only the database can settle that race.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/handle-available', requireAuth, asyncHandler(async (req, res) => {
  const handle = String(req.query.handle ?? '').toLowerCase();
  if (!HANDLE_RE.test(handle)) {
    return res.json({ available: false, reason: 'format' });
  }
  const { user_id } = (req as any).auth;
  // All three namespaces at once — reserved words, other people's chat usernames, and other
  // people's creator handles — because 029 enforces all three and a checker that knows about
  // fewer of them would green-light a name the insert then rejects.
  const rows = await query<{ taken: boolean }>(
    `select exists (
        select 1 from reserved_handles where handle = $1
        union all
        select 1 from users where lower(username) = $1 and id <> $2
        union all
        select 1 from creator_profiles where lower(handle) = $1 and user_id <> $2
     ) as taken`,
    [handle, user_id]
  );
  return res.json({ available: !rows[0].taken, reason: rows[0].taken ? 'taken' : null });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /creators  { handle, display_name?, bio?, link_url? }
//
// THE GATE. A profile is required before posting a clip (the user's decision), and this is
// where it gets created — on demand, at first post, not at signup. See 029's header for why
// manufacturing a public identity for every account is both a privacy and a namespace
// problem.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const handle = String(req.body?.handle ?? '').trim().toLowerCase();
  if (!HANDLE_RE.test(handle)) {
    return res.status(400).json({
      error: 'handle must be 3-20 chars, start with a letter, and use only a-z, 0-9 and _',
    });
  }

  const display_name = req.body?.display_name
    ? String(req.body.display_name).trim().slice(0, MAX_DISPLAY_NAME) : null;
  const bio = req.body?.bio ? String(req.body.bio).trim().slice(0, MAX_BIO) : null;
  const link_url = req.body?.link_url
    ? String(req.body.link_url).trim().slice(0, MAX_LINK) : null;

  try {
    const rows = await query<any>(
      `insert into creator_profiles (user_id, handle, display_name, bio, link_url)
            values ($1, $2, $3, $4, $5)
       returning *`,
      [user_id, handle, display_name, bio, link_url]
    );
    return res.status(201).json({ profile: await publicProfile(rows[0], user_id) });
  } catch (e) {
    if (isTaken(e)) return res.status(409).json({ error: 'that handle is taken' });
    throw e;
  }
}));

// ─────────────────────────────────────────────────────────────────────────────────
// PATCH /creators/me
//
// The handle is CHANGEABLE but rate-limited to once every 30 days. Free renaming lets an
// account build an audience under one name, sell it, and vanish — and it breaks every link
// anyone shared. Thirty days is long enough to make that unattractive and short enough to
// fix a typo you notice next week.
// ─────────────────────────────────────────────────────────────────────────────────
router.patch('/me', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const existing = await query<any>(
    `select * from creator_profiles where user_id = $1`, [user_id]);
  if (!existing[0]) return res.status(404).json({ error: 'no creator profile' });

  const sets: string[] = [];
  const vals: unknown[] = [user_id];

  if (req.body?.handle !== undefined) {
    const handle = String(req.body.handle).trim().toLowerCase();
    if (!HANDLE_RE.test(handle)) return res.status(400).json({ error: 'invalid handle' });
    if (handle !== existing[0].handle) {
      const changed = await query<{ recent: boolean }>(
        `select coalesce(max(created_at) > now() - interval '30 days', false) as recent
           from creator_handle_history where user_id = $1`, [user_id]);
      if (changed[0]?.recent) {
        return res.status(429).json({ error: 'handle can only be changed once every 30 days' });
      }
      vals.push(handle);
      sets.push(`handle = $${vals.length}`);
    }
  }

  for (const [field, max] of [['display_name', MAX_DISPLAY_NAME],
                              ['bio', MAX_BIO],
                              ['link_url', MAX_LINK]] as const) {
    if (req.body?.[field] !== undefined) {
      const v = req.body[field] === null
        ? null : String(req.body[field]).trim().slice(0, max as number) || null;
      vals.push(v);
      sets.push(`${field} = $${vals.length}`);
    }
  }

  if (!sets.length) {
    return res.json({ profile: await publicProfile(existing[0], user_id) });
  }

  try {
    const rows = await query<any>(
      `update creator_profiles set ${sets.join(', ')}, updated_at = now()
        where user_id = $1 returning *`, vals);
    // Recorded AFTER the update succeeds, so a rejected handle does not burn the 30-day
    // window. The old handle is kept so an audience following a stale link can be redirected.
    if (rows[0].handle !== existing[0].handle) {
      await query(
        `insert into creator_handle_history (user_id, old_handle, new_handle)
              values ($1, $2, $3)`,
        [user_id, existing[0].handle, rows[0].handle]
      );
    }
    return res.json({ profile: await publicProfile(rows[0], user_id) });
  } catch (e) {
    if (isTaken(e)) return res.status(409).json({ error: 'that handle is taken' });
    throw e;
  }
}));

/** POST /creators/me/avatar-presign -> a PUT url for the public (plaintext) avatar. */
router.post('/me/avatar-presign', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const ct = String(req.body?.content_type ?? 'image/jpeg');
  if (!/^image\/(jpeg|png|webp)$/.test(ct)) {
    return res.status(400).json({ error: 'avatar must be jpeg, png or webp' });
  }
  // Namespaced by uid so POST /me can prove the caller owns the key it later claims — the
  // same ownership check clips.ts does for video keys.
  const key = `media/creator-avatars/${user_id}/${Date.now()}.jpg`;
  return res.json({ avatar_r2_key: key, upload_url: await presignPut(key, ct) });
}));

/** POST /creators/me/avatar { avatar_r2_key } — attach an uploaded avatar. */
router.post('/me/avatar', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const key = String(req.body?.avatar_r2_key ?? '');
  if (!key.startsWith(`media/creator-avatars/${user_id}/`)) {
    return res.status(400).json({ error: 'avatar key does not belong to this user' });
  }
  const rows = await query<any>(
    `update creator_profiles set avatar_r2_key = $2, updated_at = now()
      where user_id = $1 returning *`, [user_id, key]);
  if (!rows[0]) return res.status(404).json({ error: 'no creator profile' });
  return res.json({ profile: await publicProfile(rows[0], user_id) });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /creators/:handle
//
// Public profile by handle. Returns 404 for a suspended profile rather than a "suspended"
// state: the moderation status of an account is not information a stranger is owed, and
// exposing it turns the API into a way to enumerate who has been actioned.
//
// NO user_id IN THE RESPONSE. A creator profile is public and a user_id is the key that other
// parts of this system authorise against; handing it to anyone who views a profile would
// hand out the input to every id-keyed endpoint. Follow/unfollow below take the HANDLE.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/:handle', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const handle = String(req.params.handle).toLowerCase();
  const rows = await query<any>(
    `select * from creator_profiles where lower(handle) = $1 and suspended_at is null`,
    [handle]
  );
  if (!rows[0]) {
    // Fall back to the rename history so shared links survive a handle change.
    const moved = await query<{ new_handle: string }>(
      `select new_handle from creator_handle_history
        where lower(old_handle) = $1 order by created_at desc limit 1`, [handle]);
    if (moved[0]) return res.status(301).json({ moved_to: moved[0].new_handle });
    return res.status(404).json({ error: 'not found' });
  }
  return res.json({ profile: await publicProfile(rows[0], user_id) });
}));

/** GET /creators/:handle/clips — that creator's public grid. */
router.get('/:handle/clips', requireAuth, asyncHandler(async (req, res) => {
  const limit = clampLimit(req.query.limit, LIST_LIMIT_DEFAULT, LIST_LIMIT_MAX);
  const cursor = typeof req.query.cursor === 'string' ? req.query.cursor : null;
  const rows = await query<any>(
    `select c.id, c.thumb_r2_key, c.caption, c.duration_ms, c.width, c.height,
            c.view_count, c.like_count, c.comment_count, c.created_at
       from clips c
       join creator_profiles p on p.user_id = c.author_id
      where lower(p.handle) = $1
        and p.suspended_at is null
        and c.deleted_at is null and c.removed_at is null and c.status = 'ready'
        ${cursor ? 'and c.created_at < $3::timestamptz' : ''}
      order by c.created_at desc
      limit $2`,
    cursor ? [String(req.params.handle).toLowerCase(), limit, cursor]
           : [String(req.params.handle).toLowerCase(), limit]
  );
  const clips = await Promise.all(rows.map(async (c) => ({
    ...c,
    thumb_url: r2Configured() && c.thumb_r2_key
      ? await presignGet(c.thumb_r2_key).catch(() => null) : null,
  })));
  return res.json({
    clips,
    next_cursor: rows.length === limit ? rows[rows.length - 1].created_at : null,
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /creators/:handle/follow  and  DELETE .../follow
//
// No consent step and no request state, unlike a contact (020). That asymmetry is the point:
// a follow grants only the ability to see content that is already public to everyone, so
// there is nothing for the followee to approve. It creates no messaging right whatsoever.
//
// The counters are NOT touched here — the trigger in 029 owns them, so every future write
// path stays consistent without remembering to.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:handle/follow', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const target = await query<{ user_id: string }>(
    `select user_id from creator_profiles
      where lower(handle) = $1 and suspended_at is null`,
    [String(req.params.handle).toLowerCase()]
  );
  if (!target[0]) return res.status(404).json({ error: 'not found' });
  if (target[0].user_id === user_id) {
    return res.status(400).json({ error: 'cannot follow yourself' });
  }

  // on conflict do nothing makes the call idempotent: a double-tap, or a retry after a
  // dropped response, must not error and must not double-count.
  await query(
    `insert into creator_follows (follower_id, followee_id) values ($1, $2)
     on conflict do nothing`,
    [user_id, target[0].user_id]
  );
  const [c] = await query<{ follower_count: number }>(
    `select follower_count from creator_profiles where user_id = $1`, [target[0].user_id]);
  return res.json({ following: true, follower_count: c?.follower_count ?? 0 });
}));

router.delete('/:handle/follow', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const target = await query<{ user_id: string }>(
    `select user_id from creator_profiles where lower(handle) = $1`,
    [String(req.params.handle).toLowerCase()]
  );
  if (!target[0]) return res.status(404).json({ error: 'not found' });
  await query(
    `delete from creator_follows where follower_id = $1 and followee_id = $2`,
    [user_id, target[0].user_id]
  );
  const [c] = await query<{ follower_count: number }>(
    `select follower_count from creator_profiles where user_id = $1`, [target[0].user_id]);
  return res.json({ following: false, follower_count: c?.follower_count ?? 0 });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /creators/feed/following
//
// Clips from creators you follow. Shipped now even though follower LISTS are not public yet
// (the user's decision) — this endpoint exposes only your OWN following set, which you
// already know, so it leaks nothing about anyone else's graph.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/feed/following', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const limit = clampLimit(req.query.limit, LIST_LIMIT_DEFAULT, LIST_LIMIT_MAX);
  const cursor = typeof req.query.cursor === 'string' ? req.query.cursor : null;
  const rows = await query<any>(
    `select c.id, c.author_id, c.thumb_r2_key, c.caption, c.duration_ms,
            c.width, c.height, c.view_count, c.like_count, c.comment_count, c.created_at,
            p.handle as author_handle, p.display_name as author_display_name,
            p.is_verified as author_verified
       from clips c
       join creator_follows f on f.followee_id = c.author_id and f.follower_id = $1
       join creator_profiles p on p.user_id = c.author_id
      where c.deleted_at is null and c.removed_at is null and c.status = 'ready'
        and p.suspended_at is null
        ${cursor ? 'and c.created_at < $3::timestamptz' : ''}
      order by c.created_at desc
      limit $2`,
    cursor ? [user_id, limit, cursor] : [user_id, limit]
  );
  const clips = await Promise.all(rows.map(async (c) => ({
    ...c,
    thumb_url: r2Configured() && c.thumb_r2_key
      ? await presignGet(c.thumb_r2_key).catch(() => null) : null,
  })));
  return res.json({
    clips,
    next_cursor: rows.length === limit ? rows[rows.length - 1].created_at : null,
  });
}));

export default router;
