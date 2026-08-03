// Clips backend — short-form public video (grid feed + reels player).
//
// ============================ NOT END-TO-END ENCRYPTED ============================
// Read the header of 022_clips.sql before touching this file. Clips are PUBLIC
// broadcast content: the media is plaintext in R2, and this server can read the
// video, the caption, and who liked/viewed what. That is a deliberate, scoped
// exception — there is no fixed recipient set to encrypt to, and the product
// requires server-attributed counts. It is NOT a precedent: messages, calls,
// locations and moments remain E2EE and nothing here touches those paths.
//
// The one rule this file DOES share with stories.ts: the bytes never transit this
// process. Upload and playback are presigned R2 URLs; we store an object key.
// =================================================================================
import { Router } from 'express';
import { randomUUID } from 'crypto';
import { query } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';
import { presignPut, presignGet, deleteObject, r2Configured } from '../r2';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Feed page size. The grid is 3-up, so 30 is 10 rows — roughly two screens of
// scroll, which is the right prefetch depth without minting thumbnail URLs nobody
// looks at.
const FEED_LIMIT_DEFAULT = 30;
const FEED_LIMIT_MAX = 60;
const COMMENTS_LIMIT_DEFAULT = 50;
const COMMENTS_LIMIT_MAX = 100;
// Rolling-24h post cap: bounds how much one account can push into R2 and into
// everyone's feed. Same intent as MAX_STORIES_PER_DAY.
const MAX_CLIPS_PER_DAY = 30;
const MAX_CAPTION_LEN = 2200;
const MAX_COMMENT_LEN = 1000;
// Hard caps, enforced HERE as well as on-device. A client-only cap is not a cap.
const MAX_DURATION_MS = 90_000;      // 90s
const MAX_BYTE_SIZE = 100 * 1024 * 1024;

/**
 * node-pg returns bigint as a STRING (it cannot promise every int8 fits in a JS
 * number), so `byte_size` would ship as `"812340"` and hard-fail a typed Swift
 * `Int` / Kotlin `Long` decode. Convert at the response boundary rather than
 * casting to int in SQL, which would silently wrap above 2 GB. (Same helper and
 * reasoning as routes/stories.ts.)
 */
function withNumericByteSize<T extends { byte_size?: unknown }>(rows: T[]): T[] {
  // Every bigint column, not just the baseline: a per-rendition size left as a string
  // fails a Swift `Int?` / Kotlin `Long?` decode exactly as hard as byte_size would.
  const bigintCols = ['byte_size', 'byte_size_sd', 'byte_size_hd', 'byte_size_fhd'];
  for (const row of rows) {
    for (const col of bigintCols) {
      const value = (row as any)[col];
      if (value != null) (row as any)[col] = Number(value);
    }
  }
  return rows;
}

/**
 * Keyset cursor: opaque `<iso8601>_<uuid>` encoding the last row's
 * (created_at, id). Keyset and NOT `OFFSET` — an infinite grid paged by offset
 * silently duplicates and skips tiles whenever somebody posts mid-scroll, which
 * is the single most common bug in this feature shape.
 */
function parseCursor(raw: unknown): { createdAt: string; id: string } | null {
  if (typeof raw !== 'string' || !raw) return null;
  const sep = raw.lastIndexOf('_');
  if (sep <= 0) return null;
  const createdAt = raw.slice(0, sep);
  const id = raw.slice(sep + 1);
  if (!UUID_RE.test(id) || Number.isNaN(Date.parse(createdAt))) return null;
  return { createdAt, id };
}

function makeCursor(row: { created_at: string | Date; id: string }): string {
  const iso = row.created_at instanceof Date ? row.created_at.toISOString() : row.created_at;
  return `${iso}_${row.id}`;
}

function clampLimit(raw: unknown, fallback: number, max: number): number {
  const n = typeof raw === 'string' ? parseInt(raw, 10) : NaN;
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(n, max);
}

/**
 * Sign thumbnail URLs for a page of clips. Done in parallel — 30 sequential
 * presign round-trips would dominate the feed's latency.
 *
 * Playback URLs are deliberately NOT signed here: a 30-tile page would mint 30
 * video URLs that mostly go unused and expire before the user taps one. The
 * video URL is minted on demand by GET /clips/:id/playback.
 */
async function attachThumbUrls<T extends { thumb_r2_key?: string | null }>(rows: T[]): Promise<T[]> {
  if (!r2Configured()) return rows;
  await Promise.all(
    rows.map(async (row) => {
      if (!row.thumb_r2_key) return;
      try {
        (row as any).thumb_url = await presignGet(row.thumb_r2_key);
      } catch (e) {
        // A tile with no thumb URL renders its placeholder — far better than
        // failing the whole page because one object is missing.
        console.warn('[clips] thumb presign failed:', (e as Error).message);
      }
    })
  );
  return rows;
}

// Columns every clip-returning endpoint selects, so the client decodes one shape
// everywhere. `liked_by_me` is per-caller, hence the parameterised user id.
const CLIP_COLUMNS = `
  c.id, c.author_id, c.r2_key, c.thumb_r2_key, c.caption, c.duration_ms,
  c.width, c.height, c.byte_size, c.view_count, c.like_count, c.comment_count,
  c.created_at, c.cover_source,
  -- WHICH renditions exist, not their keys: the client needs this to choose a quality
  -- before calling /playback, but handing out object keys it cannot presign anyway
  -- would just widen the surface for no gain.
  (c.r2_key_sd  is not null) as has_sd,
  (c.r2_key_hd  is not null) as has_hd,
  (c.r2_key_fhd is not null) as has_fhd,
  c.byte_size_sd, c.byte_size_hd, c.byte_size_fhd,
  u.full_name  as author_name,
  u.photo_url  as author_photo_url,
  exists (select 1 from clip_likes l where l.clip_id = c.id and l.user_id = $1) as liked_by_me
`;

// ─────────────────────────────────────────────────────────────────────────────────
// POST /clips/presign-upload  { mime? }
//   -> { key, upload_url, thumb_key, thumb_upload_url,
//        renditions: { sd: {key, upload_url}, hd: {…}, fhd: {…} } }
//
// Mints EVERY URL in one round-trip: the client PUTs up to three renditions plus the
// cover back-to-back, and a round-trip per file would add latency before the progress
// bar can even start moving. Unused renditions simply never get PUT — the URLs expire
// on their own and the orphan sweep handles anything half-written.
//
// All five keys share one uuid stem so they are trivially correlatable in the bucket
// and a single prefix delete removes an entire clip.
//
// The `media/clips/` prefix keeps the untouched `startsWith('media/')` guard in
// routes/media.ts satisfied (zero edits to that shared file) AND gives R2 a distinct
// prefix for the orphan lifecycle rule. The <uid> namespace is what POST /clips
// checks to prove the caller owns the key it claims.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/presign-upload', requireAuth, asyncHandler(async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const { user_id } = (req as any).auth;
  const mime = typeof req.body?.mime === 'string' ? req.body.mime : 'video/mp4';

  const id = randomUUID();
  const base = `media/clips/${user_id}/${id}`;
  const key = `${base}.mp4`;           // baseline / original
  const thumb_key = `${base}.jpg`;
  const sdKey = `${base}_sd.mp4`;
  const hdKey = `${base}_hd.mp4`;
  const fhdKey = `${base}_fhd.mp4`;

  const [upload_url, thumb_upload_url, sdUrl, hdUrl, fhdUrl] = await Promise.all([
    presignPut(key, mime),
    presignPut(thumb_key, 'image/jpeg'),
    presignPut(sdKey, mime),
    presignPut(hdKey, mime),
    presignPut(fhdKey, mime),
  ]);

  return res.json({
    key,
    upload_url,
    thumb_key,
    thumb_upload_url,
    renditions: {
      sd: { key: sdKey, upload_url: sdUrl },
      hd: { key: hdKey, upload_url: hdUrl },
      fhd: { key: fhdKey, upload_url: fhdUrl },
    },
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /clips  { clip_id, r2_key, thumb_r2_key, caption?, duration_ms?, width?,
//                height?, byte_size? } -> { clip_id, created_at }
//
// Called only AFTER both R2 PUTs succeed, so the row is born 'ready'. See the
// migration header for why there is no 'uploading' state.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const {
    clip_id, r2_key, thumb_r2_key, caption, duration_ms, width, height, byte_size,
    r2_key_sd, r2_key_hd, r2_key_fhd,
    byte_size_sd, byte_size_hd, byte_size_fhd,
    cover_source,
  } = req.body ?? {};

  if (typeof clip_id !== 'string' || !UUID_RE.test(clip_id)) {
    return res.status(400).json({ error: 'clip_id must be a uuid (client-generated)' });
  }

  // AUTHORIZATION: the caller may only claim object keys inside its OWN namespace,
  // and the tail must be the uuid presign-upload minted (optionally with a rendition
  // suffix). Without the tail check a caller could point a clip at an arbitrary
  // attacker-chosen key.
  const prefix = `media/clips/${user_id}/`;
  const ownsKey = (k: unknown, ext: string, suffix = ''): boolean => {
    if (typeof k !== 'string' || !k.startsWith(prefix) || !k.endsWith(`${suffix}${ext}`)) return false;
    const tail = k.slice(prefix.length, k.length - ext.length - suffix.length);
    return UUID_RE.test(tail);
  };
  if (!ownsKey(r2_key, '.mp4')) {
    return res.status(400).json({ error: 'r2_key does not belong to this user' });
  }
  if (!ownsKey(thumb_r2_key, '.jpg')) {
    return res.status(400).json({ error: 'thumb_r2_key does not belong to this user' });
  }
  // Renditions are OPTIONAL (a 480p source is never upscaled), but any that IS
  // supplied must pass the same ownership check as the baseline.
  for (const [value, suffix] of [
    [r2_key_sd, '_sd'], [r2_key_hd, '_hd'], [r2_key_fhd, '_fhd'],
  ] as const) {
    if (value != null && !ownsKey(value, '.mp4', suffix)) {
      return res.status(400).json({ error: `r2_key${suffix} does not belong to this user` });
    }
  }
  if (cover_source != null && cover_source !== 'frame' && cover_source !== 'upload') {
    return res.status(400).json({ error: "cover_source must be 'frame' or 'upload'" });
  }

  if (caption != null && (typeof caption !== 'string' || caption.length > MAX_CAPTION_LEN)) {
    return res.status(400).json({ error: `caption must be a string under ${MAX_CAPTION_LEN} chars` });
  }
  const intOrNull = (v: unknown, name: string, max: number): number | null | string => {
    if (v == null) return null;
    if (!Number.isSafeInteger(v) || (v as number) < 0) return `${name} must be a non-negative integer`;
    if ((v as number) > max) return `${name} exceeds the maximum`;
    return v as number;
  };
  const dur = intOrNull(duration_ms, 'duration_ms', MAX_DURATION_MS);
  if (typeof dur === 'string') return res.status(400).json({ error: dur });
  const size = intOrNull(byte_size, 'byte_size', MAX_BYTE_SIZE);
  if (typeof size === 'string') return res.status(400).json({ error: size });
  const w = intOrNull(width, 'width', 100_000);
  if (typeof w === 'string') return res.status(400).json({ error: w });
  const h = intOrNull(height, 'height', 100_000);
  if (typeof h === 'string') return res.status(400).json({ error: h });
  const sizeSd = intOrNull(byte_size_sd, 'byte_size_sd', MAX_BYTE_SIZE);
  if (typeof sizeSd === 'string') return res.status(400).json({ error: sizeSd });
  const sizeHd = intOrNull(byte_size_hd, 'byte_size_hd', MAX_BYTE_SIZE);
  if (typeof sizeHd === 'string') return res.status(400).json({ error: sizeHd });
  const sizeFhd = intOrNull(byte_size_fhd, 'byte_size_fhd', MAX_BYTE_SIZE);
  if (typeof sizeFhd === 'string') return res.status(400).json({ error: sizeFhd });

  // Rolling-24h post cap.
  const posted = await query<{ n: number }>(
    `select count(*)::int as n from clips
      where author_id = $1 and created_at > now() - interval '24 hours'`,
    [user_id]
  );
  if ((posted[0]?.n ?? 0) >= MAX_CLIPS_PER_DAY) {
    return res.status(429).json({ error: 'clip limit reached' });
  }

  let created: { created_at: string };
  try {
    const rows = await query<{ created_at: string }>(
      `insert into clips (id, author_id, r2_key, thumb_r2_key, caption, duration_ms,
                          width, height, byte_size,
                          r2_key_sd, r2_key_hd, r2_key_fhd,
                          byte_size_sd, byte_size_hd, byte_size_fhd, cover_source)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9,
                 $10, $11, $12, $13, $14, $15, coalesce($16, 'frame'))
         returning created_at`,
      [clip_id, user_id, r2_key, thumb_r2_key, caption ?? null, dur, w, h, size,
       r2_key_sd ?? null, r2_key_hd ?? null, r2_key_fhd ?? null,
       sizeSd, sizeHd, sizeFhd, cover_source ?? null]
    );
    created = rows[0];
  } catch (e) {
    // 23505 = unique_violation: the client retried a post that already landed.
    // Idempotent by design — the client generated the id precisely so a retry
    // after a dropped response cannot double-post.
    if ((e as any)?.code === '23505') return res.status(409).json({ error: 'clip already exists' });
    throw e;
  }

  return res.json({ clip_id, created_at: created.created_at });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /clips/feed?cursor=&limit= -> { clips: [...], next_cursor }
//
// Newest-first over live, ready clips from everybody (an explore-style grid).
// Thumbnail URLs are signed; video URLs are not (see attachThumbUrls).
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/feed', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const limit = clampLimit(req.query.limit, FEED_LIMIT_DEFAULT, FEED_LIMIT_MAX);
  const cursor = parseCursor(req.query.cursor);

  // Fetch limit+1 to learn whether another page exists without a second COUNT query.
  const rows = await query<any>(
    `select ${CLIP_COLUMNS}
       from clips c
       join users u on u.id = c.author_id
      where c.deleted_at is null and c.status = 'ready'
        ${cursor ? 'and (c.created_at, c.id) < ($2::timestamptz, $3::uuid)' : ''}
      order by c.created_at desc, c.id desc
      limit ${limit + 1}`,
    cursor ? [user_id, cursor.createdAt, cursor.id] : [user_id]
  );

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  await attachThumbUrls(page);

  return res.json({
    clips: withNumericByteSize(page),
    next_cursor: hasMore && page.length ? makeCursor(page[page.length - 1]) : null,
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /clips/mine?cursor=&limit= -> { clips: [...], next_cursor }
// The author's own grid. Includes their soft-hidden-from-feed states so they can
// see and retry anything that failed.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/mine', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const limit = clampLimit(req.query.limit, FEED_LIMIT_DEFAULT, FEED_LIMIT_MAX);
  const cursor = parseCursor(req.query.cursor);

  const rows = await query<any>(
    `select ${CLIP_COLUMNS}
       from clips c
       join users u on u.id = c.author_id
      where c.author_id = $1 and c.deleted_at is null
        ${cursor ? 'and (c.created_at, c.id) < ($2::timestamptz, $3::uuid)' : ''}
      order by c.created_at desc, c.id desc
      limit ${limit + 1}`,
    cursor ? [user_id, cursor.createdAt, cursor.id] : [user_id]
  );

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  await attachThumbUrls(page);

  return res.json({
    clips: withNumericByteSize(page),
    next_cursor: hasMore && page.length ? makeCursor(page[page.length - 1]) : null,
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /clips/:id/playback?quality=sd|hd|fhd -> { playback_url, quality, byte_size }
//
// Minted on demand, short-lived. See attachThumbUrls for why this is not in /feed.
//
// QUALITY IS A REQUEST, NOT A GUARANTEE. Renditions are produced on-device and any of
// them can legitimately be missing (a 480p source is never upscaled to 1080p), so the
// resolved key walks DOWN the ladder from what was asked for and finally falls back to
// the always-present baseline `r2_key`. The response reports which rendition was
// actually served so the client can label the stream honestly instead of assuming.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/:id/playback', requireAuth, asyncHandler(async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const clipId = req.params.id;
  if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'invalid clip id' });

  const requested = typeof req.query.quality === 'string' ? req.query.quality : 'hd';
  if (!['sd', 'hd', 'fhd'].includes(requested)) {
    return res.status(400).json({ error: "quality must be 'sd', 'hd' or 'fhd'" });
  }

  const rows = await query<{
    r2_key: string;
    r2_key_sd: string | null; r2_key_hd: string | null; r2_key_fhd: string | null;
    byte_size: string | null;
    byte_size_sd: string | null; byte_size_hd: string | null; byte_size_fhd: string | null;
  }>(
    `select r2_key, r2_key_sd, r2_key_hd, r2_key_fhd,
            byte_size, byte_size_sd, byte_size_hd, byte_size_fhd
       from clips
      where id = $1 and deleted_at is null and status = 'ready'`,
    [clipId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'clip not found' });
  const row = rows[0];

  // Preference order per request, degrading toward smaller files. Asking for `sd` never
  // silently upgrades to a 1080p download on a metered connection — it steps UP only
  // after every smaller option is exhausted.
  const ladder: Record<string, Array<'sd' | 'hd' | 'fhd'>> = {
    sd: ['sd', 'hd', 'fhd'],
    hd: ['hd', 'sd', 'fhd'],
    fhd: ['fhd', 'hd', 'sd'],
  };
  const keyOf = { sd: row.r2_key_sd, hd: row.r2_key_hd, fhd: row.r2_key_fhd };
  const sizeOf = { sd: row.byte_size_sd, hd: row.byte_size_hd, fhd: row.byte_size_fhd };

  let served: 'sd' | 'hd' | 'fhd' | 'original' = 'original';
  let key = row.r2_key;
  let size = row.byte_size;
  for (const step of ladder[requested]) {
    if (keyOf[step]) {
      served = step;
      key = keyOf[step]!;
      size = sizeOf[step];
      break;
    }
  }

  const playback_url = await presignGet(key);
  return res.json({
    playback_url,
    quality: served,
    byte_size: size != null ? Number(size) : null,
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /clips/:id/view -> { view_count }
//
// Idempotent per (clip, user): the insert is the dedupe, and the counter is only
// bumped when the insert actually created a row. The client calls this after a
// >=2s watch, never on tile appearance — counting scroll-past impressions as views
// inflates the number the entire grid is built around.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/view', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const clipId = req.params.id;
  if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'invalid clip id' });

  const inserted = await query<{ clip_id: string }>(
    `insert into clip_views (clip_id, user_id)
       select $1, $2 from clips where id = $1 and deleted_at is null
       on conflict do nothing
       returning clip_id`,
    [clipId, user_id]
  );

  if (inserted.length) {
    const rows = await query<{ view_count: number }>(
      `update clips set view_count = view_count + 1 where id = $1 returning view_count`,
      [clipId]
    );
    return res.json({ view_count: rows[0]?.view_count ?? 0 });
  }

  // Already viewed (or clip gone) — return the current count so the client's
  // optimistic number is corrected either way.
  const rows = await query<{ view_count: number }>(
    `select view_count from clips where id = $1 and deleted_at is null`,
    [clipId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'clip not found' });
  return res.json({ view_count: rows[0].view_count });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /clips/:id/like -> { liked, like_count }
// DELETE /clips/:id/like -> { liked, like_count }
//
// Both return the AUTHORITATIVE count. The client applies its optimistic flip on
// tap and then overwrites with this number — optimistic UI must never be allowed
// to become the source of truth, or a rapid double-tap permanently desyncs the
// displayed count from the table.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/like', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const clipId = req.params.id;
  if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'invalid clip id' });

  const inserted = await query<{ clip_id: string }>(
    `insert into clip_likes (clip_id, user_id)
       select $1, $2 from clips where id = $1 and deleted_at is null
       on conflict do nothing
       returning clip_id`,
    [clipId, user_id]
  );

  if (inserted.length) {
    const rows = await query<{ like_count: number }>(
      `update clips set like_count = like_count + 1 where id = $1 returning like_count`,
      [clipId]
    );
    return res.json({ liked: true, like_count: rows[0]?.like_count ?? 0 });
  }

  const rows = await query<{ like_count: number }>(
    `select like_count from clips where id = $1 and deleted_at is null`,
    [clipId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'clip not found' });
  return res.json({ liked: true, like_count: rows[0].like_count });
}));

router.delete('/:id/like', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const clipId = req.params.id;
  if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'invalid clip id' });

  const removed = await query<{ clip_id: string }>(
    `delete from clip_likes where clip_id = $1 and user_id = $2 returning clip_id`,
    [clipId, user_id]
  );

  if (removed.length) {
    // greatest(...,0) so a counter that has drifted (manual row surgery, an old
    // bug) can never go negative and render as "-1 likes".
    const rows = await query<{ like_count: number }>(
      `update clips set like_count = greatest(like_count - 1, 0) where id = $1 returning like_count`,
      [clipId]
    );
    return res.json({ liked: false, like_count: rows[0]?.like_count ?? 0 });
  }

  const rows = await query<{ like_count: number }>(
    `select like_count from clips where id = $1 and deleted_at is null`,
    [clipId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'clip not found' });
  return res.json({ liked: false, like_count: rows[0].like_count });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /clips/:id/comments?cursor=&limit= -> { comments: [...], next_cursor }
// Oldest-first (chat-like reading order), keyset-paginated.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/:id/comments', requireAuth, asyncHandler(async (req, res) => {
  const clipId = req.params.id;
  if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'invalid clip id' });
  const limit = clampLimit(req.query.limit, COMMENTS_LIMIT_DEFAULT, COMMENTS_LIMIT_MAX);
  const cursor = parseCursor(req.query.cursor);

  const rows = await query<any>(
    `select cc.id, cc.clip_id, cc.author_id, cc.text, cc.created_at,
            u.full_name as author_name, u.photo_url as author_photo_url
       from clip_comments cc
       join users u on u.id = cc.author_id
      where cc.clip_id = $1 and cc.deleted_at is null
        ${cursor ? 'and (cc.created_at, cc.id) > ($2::timestamptz, $3::uuid)' : ''}
      order by cc.created_at asc, cc.id asc
      limit ${limit + 1}`,
    cursor ? [clipId, cursor.createdAt, cursor.id] : [clipId]
  );

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  return res.json({
    comments: page,
    next_cursor: hasMore && page.length ? makeCursor(page[page.length - 1]) : null,
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /clips/:id/comments  { text } -> { comment }
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/comments', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const clipId = req.params.id;
  if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'invalid clip id' });

  const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
  if (!text) return res.status(400).json({ error: 'text is required' });
  if (text.length > MAX_COMMENT_LEN) {
    return res.status(400).json({ error: `text must be under ${MAX_COMMENT_LEN} chars` });
  }

  const live = await query<{ one: number }>(
    `select 1 as one from clips where id = $1 and deleted_at is null and status = 'ready'`,
    [clipId]
  );
  if (!live[0]) return res.status(404).json({ error: 'clip not found' });

  const id = randomUUID();
  const rows = await query<any>(
    `insert into clip_comments (id, clip_id, author_id, text)
       values ($1, $2, $3, $4)
       returning id, clip_id, author_id, text, created_at`,
    [id, clipId, user_id, text]
  );
  await query(`update clips set comment_count = comment_count + 1 where id = $1`, [clipId]);

  const me = await query<{ full_name: string | null; photo_url: string | null }>(
    `select full_name, photo_url from users where id = $1`,
    [user_id]
  );

  return res.json({
    comment: {
      ...rows[0],
      author_name: me[0]?.full_name ?? null,
      author_photo_url: me[0]?.photo_url ?? null,
    },
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// DELETE /clips/:id/comments/:commentId -> 204
// Author of the COMMENT, or author of the CLIP (so a creator can moderate their
// own post's comments), may delete.
// ─────────────────────────────────────────────────────────────────────────────────
router.delete('/:id/comments/:commentId', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { id: clipId, commentId } = req.params;
  if (!UUID_RE.test(clipId) || !UUID_RE.test(commentId)) {
    return res.status(400).json({ error: 'invalid id' });
  }

  const rows = await query<{ comment_author: string; clip_author: string }>(
    `select cc.author_id as comment_author, c.author_id as clip_author
       from clip_comments cc
       join clips c on c.id = cc.clip_id
      where cc.id = $1 and cc.clip_id = $2 and cc.deleted_at is null`,
    [commentId, clipId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'comment not found' });
  if (rows[0].comment_author !== user_id && rows[0].clip_author !== user_id) {
    return res.status(403).json({ error: 'not allowed to delete this comment' });
  }

  await query(`update clip_comments set deleted_at = now() where id = $1`, [commentId]);
  await query(
    `update clips set comment_count = greatest(comment_count - 1, 0) where id = $1`,
    [clipId]
  );
  return res.status(204).end();
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /clips/:id/presign-thumb -> { thumb_key, thumb_upload_url }
//
// A replacement cover for an EXISTING clip. Mints a fresh uuid stem rather than
// reusing the clip's original thumb key: overwriting the old object in place would
// be invisible to every CDN and client cache still holding the previous cover, so
// the edit would appear to do nothing for exactly the people who already saw it.
// The old object is deleted by PATCH once the new key is committed.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/presign-thumb', requireAuth, asyncHandler(async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const { user_id } = (req as any).auth;
  const clipId = req.params.id;
  if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'invalid clip id' });

  // Prove ownership BEFORE minting a writable URL — otherwise any authenticated
  // caller could obtain a PUT url scoped to their own namespace and then attempt to
  // attach it to somebody else's clip.
  const rows = await query<{ author_id: string }>(
    `select author_id from clips where id = $1 and deleted_at is null`,
    [clipId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'clip not found' });
  if (rows[0].author_id !== user_id) {
    return res.status(403).json({ error: 'not the author of this clip' });
  }

  const thumb_key = `media/clips/${user_id}/${randomUUID()}.jpg`;
  const thumb_upload_url = await presignPut(thumb_key, 'image/jpeg');
  return res.json({ thumb_key, thumb_upload_url });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// PATCH /clips/:id  { caption?, thumb_r2_key?, cover_source? } -> { clip }
//
// Edits the CAPTION and COVER only. The video itself is immutable by design: people
// have already watched, liked and commented on these bytes, and swapping them under
// a stable id turns every existing engagement into an endorsement of something the
// audience never saw. Re-uploading is a new clip.
//
// Both fields are optional and independently applied, so the client can change just
// the caption without re-sending a cover it did not touch.
// ─────────────────────────────────────────────────────────────────────────────────
router.patch('/:id', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const clipId = req.params.id;
  if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'invalid clip id' });

  const { caption, thumb_r2_key, cover_source } = req.body ?? {};

  const hasCaption = caption !== undefined;
  const hasThumb = thumb_r2_key !== undefined;
  if (!hasCaption && !hasThumb) {
    return res.status(400).json({ error: 'nothing to update' });
  }

  // `null` is a meaningful caption value (clear it); a non-string is not.
  if (hasCaption && caption !== null &&
      (typeof caption !== 'string' || caption.length > MAX_CAPTION_LEN)) {
    return res.status(400).json({ error: `caption must be a string under ${MAX_CAPTION_LEN} chars` });
  }
  if (cover_source != null && cover_source !== 'frame' && cover_source !== 'upload') {
    return res.status(400).json({ error: "cover_source must be 'frame' or 'upload'" });
  }

  // Same namespace+uuid-tail proof as POST /clips. A thumb key from presign-thumb has
  // a bare uuid stem, so no rendition suffix is permitted here.
  if (hasThumb) {
    const prefix = `media/clips/${user_id}/`;
    const ok = typeof thumb_r2_key === 'string' &&
      thumb_r2_key.startsWith(prefix) &&
      thumb_r2_key.endsWith('.jpg') &&
      UUID_RE.test(thumb_r2_key.slice(prefix.length, thumb_r2_key.length - '.jpg'.length));
    if (!ok) return res.status(400).json({ error: 'thumb_r2_key does not belong to this user' });
  }

  const existing = await query<{ author_id: string; thumb_r2_key: string }>(
    `select author_id, thumb_r2_key from clips where id = $1 and deleted_at is null`,
    [clipId]
  );
  if (!existing[0]) return res.status(404).json({ error: 'clip not found' });
  if (existing[0].author_id !== user_id) {
    return res.status(403).json({ error: 'not the author of this clip' });
  }
  const oldThumbKey = existing[0].thumb_r2_key;

  // Build the SET list from only the fields actually supplied. coalesce() would be
  // wrong for caption: it cannot distinguish "clear this" from "leave it alone".
  const sets: string[] = [];
  const params: unknown[] = [clipId];
  if (hasCaption) {
    params.push(caption === null ? null : (caption as string));
    sets.push(`caption = $${params.length}`);
  }
  if (hasThumb) {
    params.push(thumb_r2_key);
    sets.push(`thumb_r2_key = $${params.length}`);
    params.push(cover_source ?? 'upload');
    sets.push(`cover_source = $${params.length}`);
  }

  await query(`update clips set ${sets.join(', ')} where id = $1`, params);

  // Drop the superseded cover only after the row commits — deleting first would leave
  // a clip pointing at a missing object if the update then failed.
  if (hasThumb && oldThumbKey && oldThumbKey !== thumb_r2_key && r2Configured()) {
    try {
      await deleteObject(oldThumbKey);
    } catch (e) {
      console.warn('[clips] old thumb delete failed (lifecycle rule will reap):', (e as Error).message);
    }
  }

  // Return the full updated row in the same shape as every other endpoint, so the
  // client can replace its local model wholesale instead of patching fields by hand.
  const updated = await query<any>(
    `select ${CLIP_COLUMNS} from clips c join users u on u.id = c.author_id where c.id = $2`,
    [user_id, clipId]
  );
  await attachThumbUrls(updated);
  return res.json({ clip: withNumericByteSize(updated)[0] });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// DELETE /clips/:id -> 204
//
// Soft delete (the row survives so counters and open comment lists do not
// cascade-vanish from other users' feeds mid-scroll), then best-effort R2 cleanup.
//
// NOT A SECURITY OPERATION, and the confirm dialog must say so: anyone who already
// watched or downloaded the video keeps it. Clips were never encrypted (see header).
// ─────────────────────────────────────────────────────────────────────────────────
router.delete('/:id', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const clipId = req.params.id;
  if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'invalid clip id' });

  const rows = await query<{
    author_id: string; r2_key: string; thumb_r2_key: string;
    r2_key_sd: string | null; r2_key_hd: string | null; r2_key_fhd: string | null;
  }>(
    `select author_id, r2_key, thumb_r2_key, r2_key_sd, r2_key_hd, r2_key_fhd
       from clips where id = $1 and deleted_at is null`,
    [clipId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'clip not found' });
  if (rows[0].author_id !== user_id) {
    return res.status(403).json({ error: 'not the author of this clip' });
  }

  await query(`update clips set deleted_at = now() where id = $1`, [clipId]);

  // Best-effort, and EVERY rendition — deleting only the baseline would leave up to
  // three orphaned videos per clip paying storage forever. If R2 is unreachable we
  // still soft-delete: the user asked for the clip to be gone, and the bucket
  // lifecycle rule on `media/clips/` is the net.
  if (r2Configured()) {
    const keys = [
      rows[0].r2_key, rows[0].thumb_r2_key,
      rows[0].r2_key_sd, rows[0].r2_key_hd, rows[0].r2_key_fhd,
    ].filter((k): k is string => !!k);
    for (const key of keys) {
      try {
        await deleteObject(key);
      } catch (e) {
        console.warn('[clips] r2 delete failed (lifecycle rule will reap):', (e as Error).message);
      }
    }
  }

  return res.status(204).end();
}));

export default router;
