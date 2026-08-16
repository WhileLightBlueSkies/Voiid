// Stories backend — 24h ephemeral media, E2EE (see docs/STORIES_PROTOCOL.md).
//
// ============================== THE PRIVACY MODEL ==================================
// A story is `POST /messages/send`'s fan-out with the recipient set widened from one
// peer's devices to a chosen audience's devices. The blob is encrypted ONCE on-device
// with a fresh random AES-256-GCM key (e2e-core `encryptMedia`), PUT ONCE straight to
// R2 via a presigned URL, and a ~400-byte JSON envelope carrying that key is encrypted
// ONCE PER TARGET DEVICE over that device's existing Double Ratchet session and stored
// in `story_keys` — structurally identical to `message_ciphertexts`.
//
// What this process therefore holds, per endpoint:
//   * an opaque R2 object key (the bytes never transit this process — presigned PUT/GET)
//   * a WRAPPER mime (application/octet-stream) and a ciphertext byte count
//   * one opaque per-device blob it cannot decrypt
//   * routing ids: author user/device, recipient device ids, timestamps
// It NEVER holds: the media key, the nonce, the real mime, the caption, the dimensions,
// or a single plaintext byte. Every endpoint below is annotated with how it upholds that.
//
// WHAT WE DO NOT HIDE, and must never claim to: `story_keys` has one row per recipient
// DEVICE and `devices.user_id` maps each to a user, so the server can enumerate exactly
// who a story was sent to. There is no sealed sender in Voiid and one cannot be added
// (the e2e-core surface is frozen), and the fan-out must be addressed to real device ids
// for the relay to work. This is stated plainly in the protocol doc and in the client's
// audience picker. Do not soften it.
// ===================================================================================
import { Router } from 'express';
import { randomUUID } from 'crypto';
import { assertOpaque } from '@voiid/common-utils';
import { query } from '../db';
import { blockedUserIds } from '../blocking';
import { publisher } from '../redis';
import { requireAuth } from '../auth';
import { b64, asyncHandler } from '../util';
import { presignPut, presignGet, deleteObject, r2Configured } from '../r2';
import { sendWakePush, PushMeta } from '../push';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Max per-request fan-out. Larger audiences post the first batch and append the rest
// via POST /stories/:id/keys — one giant request would hold a connection open for
// thousands of inserts and time out halfway, leaving a half-delivered story.
const MAX_KEYS_PER_REQUEST = 1000;
// Rolling-24h post cap. Not a moral judgement — it bounds how much a single account
// can push into every contact's device and into R2 before the reaper catches up.
const MAX_STORIES_PER_DAY = 20;
// Feed/receipt page size. A device that has been offline pulls in pages, not one query.
const FEED_LIMIT = 200;

// Content-free wake push to a set of devices (Section 4.14). Same shape as the private
// helper in routes/messages.ts — duplicated rather than exported from there so this
// feature cannot regress the message path. Fire-and-forget: the HTTP response must NOT
// wait on push delivery.
//
// PRIVACY: `meta` carries ONLY `type` + `story_id`. A caption, thumbnail, author name,
// or any part of the envelope here would be a golden-rule violation.
function scheduleWakePush(whereSql: string, params: unknown[], meta?: PushMeta): void {
  query<{ push_token: string; push_provider: string }>(
    `select push_token, push_provider from devices
       where ${whereSql} and revoked_at is null
         and push_token is not null and push_provider is not null`,
    params
  )
    .then((targets) => {
      if (targets.length) void sendWakePush(targets, meta);
    })
    .catch((e) => console.warn('[push] story wake lookup failed:', (e as Error).message));
}

// Resolve the caller's device id: JWT claim first, else `?device_id=` (matches
// prekeys.ts / messages.ts — the JWT does not always carry a device claim).
function callerDeviceId(req: any): string | null {
  const fromAuth = req.auth?.device_id;
  if (typeof fromAuth === 'string' && fromAuth) return fromAuth;
  const fromQuery = req.query?.device_id;
  return typeof fromQuery === 'string' && fromQuery ? fromQuery : null;
}

/**
 * node-pg returns `bigint` as a STRING (it cannot promise every int8 fits in a JS
 * number), so `byte_size` would ship as `"812340"` and blow up a typed client decode
 * — Swift `Int` / Kotlin `Long` against a JSON string is a hard failure, not a
 * fallback. Convert at the response boundary rather than casting to `int` in SQL,
 * which would silently wrap above 2 GB.
 */
function withNumericByteSize<T extends { byte_size?: unknown }>(rows: T[]): T[] {
  for (const row of rows) {
    if (row.byte_size != null) (row as any).byte_size = Number(row.byte_size);
  }
  return rows;
}

/**
 * Validate a `keys[]` / `receipts[]` bundle. Returns an error string, or null when OK.
 *
 * `assertOpaque` per entry is the golden-rule gate: it rejects an entry that smuggles a
 * plaintext-ish field (`plaintext`/`body`/`text_content`/`message_text`) alongside the
 * ciphertext. The ciphertext itself is never decoded here beyond base64 -> bytea.
 */
function validateEnvelopeBundle(entries: unknown, field: string): string | null {
  if (!Array.isArray(entries) || entries.length === 0) {
    return `${field} must be a non-empty array`;
  }
  for (const entry of entries as any[]) {
    if (!entry || typeof entry !== 'object') {
      return `each ${field}[] entry must be an object`;
    }
    if (typeof entry.recipient_device_id !== 'string' || !UUID_RE.test(entry.recipient_device_id)) {
      return `each ${field}[] entry requires a uuid recipient_device_id`;
    }
    if (typeof entry.ciphertext !== 'string' || !entry.ciphertext) {
      return `each ${field}[] entry requires ciphertext`;
    }
    try {
      assertOpaque(entry);
    } catch (e) {
      return (e as Error).message;
    }
  }
  return null;
}

/**
 * Insert one opaque envelope per target device and relay a ROUTING-ONLY signal.
 *
 * Two things this deliberately does:
 *  1. Resolves the device ids against `devices` FIRST and inserts only for rows that
 *     exist and are not revoked. Without that, one bogus/stale device id in the bundle
 *     raises a foreign-key violation and fails the WHOLE story — and a revoked device
 *     would be handed key material it must never get.
 *  2. Publishes ONCE PER USER with only `{story_id, author_id, recipient_device_ids}`.
 *     A device's ciphertext is NEVER placed on the shared `channel:user:<id>` — each
 *     woken device calls GET /stories/feed and pulls its own blob.
 */
async function storeKeysAndRelay(
  storyId: string,
  authorId: string,
  entries: { recipient_device_id: string; ciphertext: string }[]
): Promise<number> {
  const requested = [...new Set(entries.map((e) => e.recipient_device_id))];
  const owners = await query<{ id: string; user_id: string }>(
    `select id, user_id from devices where id = any($1::uuid[]) and revoked_at is null`,
    [requested]
  );
  const live = new Map(owners.map((o) => [o.id, o.user_id]));

  const stored: string[] = [];
  for (const entry of entries) {
    if (!live.has(entry.recipient_device_id)) continue; // unknown/revoked device: skip, never fatal
    // `do nothing` guards a client that repeats a device in the bundle, and makes
    // POST /stories/:id/keys a safe retry for a partially-delivered fan-out.
    const ins = await query<{ story_id: string }>(
      `insert into story_keys (story_id, recipient_device_id, ciphertext)
         values ($1, $2, $3)
         on conflict (story_id, recipient_device_id) do nothing
         returning story_id`,
      [storyId, entry.recipient_device_id, b64(entry.ciphertext)]
    );
    if (ins.length && !stored.includes(entry.recipient_device_id)) stored.push(entry.recipient_device_id);
  }

  if (!stored.length) return 0;

  const byUser = new Map<string, string[]>();
  for (const deviceId of stored) {
    const uid = live.get(deviceId)!;
    const list = byUser.get(uid) ?? [];
    list.push(deviceId);
    byUser.set(uid, list);
  }
  for (const [uid, devIds] of byUser) {
    await publisher.publish(
      `channel:user:${uid}`,
      JSON.stringify({
        type: 'story',
        story_id: storyId,
        author_id: authorId,
        recipient_device_ids: devIds,
      })
    );
  }

  // Wake offline/backgrounded TARGET devices. Content-free: type + story_id only.
  scheduleWakePush('id = any($1::uuid[])', [stored], { type: 'story', story_id: storyId });
  return stored.length;
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /stories/presign-upload  { mime? } -> { key, upload_url }
//
// UPHOLDS THE RULE: hands back a signed URL and nothing else. The ciphertext is PUT
// by the client DIRECTLY to R2 — the bytes never enter this process. `mime` is the
// WRAPPER type; clients MUST send application/octet-stream (or omit it) because the
// real media type rides encrypted inside the per-device envelope. The object key is
// namespaced by uploader so POST /stories can prove the caller owns it.
//
// WHY the `media/stories/` prefix and not plain `media/`: it still satisfies the
// untouched `startsWith('media/')` guard in routes/media.ts (zero edits to that shared
// file) AND gives R2 a distinct prefix for the orphan lifecycle rule (48h).
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/presign-upload', requireAuth, asyncHandler(async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const { user_id } = (req as any).auth;
  const mime = typeof req.body?.mime === 'string' ? req.body.mime : 'application/octet-stream';

  const key = `media/stories/${user_id}/${randomUUID()}`;
  const upload_url = await presignPut(key, mime);
  return res.json({ key, upload_url });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /stories/presign-download  { story_id } -> { download_url }
//
// AUTHORIZATION (this is the whole point of the endpoint existing at all):
// POST /media/presign-download authorizes on "authenticated AND key starts with
// media/" only, so a leaked (media key, object key) pair lets ANY logged-in Voiid
// user fetch the ciphertext. Stories check actual entitlement: the caller must be the
// author, or own a device that holds a `story_keys` row for this story.
//
// HONEST LIMIT: this is defence in depth, NOT a guarantee. The object still sits under
// the `media/` prefix, so the generic endpoint would still serve it to anyone who
// learned the key. Access control is ultimately the E2E media key. Do not describe it
// otherwise in UI or docs.
//
// UPHOLDS THE RULE: returns a URL to CIPHERTEXT. The media key is not in this database.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/presign-download', requireAuth, asyncHandler(async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const { user_id } = (req as any).auth;
  const storyId = req.body?.story_id;
  if (typeof storyId !== 'string' || !UUID_RE.test(storyId)) {
    return res.status(400).json({ error: 'story_id must be a uuid' });
  }

  // One query answers "does it exist, is it live, and may this user have it".
  const rows = await query<{ r2_key: string; entitled: boolean }>(
    `select s.r2_key,
            ( s.author_id = $2
              or exists (select 1 from story_keys k
                           join devices d on d.id = k.recipient_device_id
                          where k.story_id = s.id and d.user_id = $2 and d.revoked_at is null)
            ) as entitled
       from stories s
      where s.id = $1 and s.expires_at > now()`,
    [storyId, user_id]
  );
  // Expired is reported as 404, identically to never-existed: distinguishing them
  // would confirm to a stranger that a given story id was real.
  if (!rows[0]) return res.status(404).json({ error: 'story not found' });
  if (!rows[0].entitled) return res.status(403).json({ error: 'not a recipient of this story' });

  const download_url = await presignGet(rows[0].r2_key);
  return res.json({ download_url });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /stories/feed?device_id=[&include_delivered=1]
//   -> { stories: [{ story_id, author_id, author_device_id, r2_key, media_mime,
//                    byte_size, created_at, expires_at, ciphertext }] }
//
// Returns ONLY the caller device's own envelopes. `expires_at > now()` is applied
// here, not left to the reaper — visibility must be correct even if the worker has
// been dead for a week.
//
// UPHOLDS THE RULE: `ciphertext` is the per-device blob this server cannot decrypt;
// `r2_key` addresses ciphertext; `media_mime` is the wrapper type.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/feed', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const deviceId = callerDeviceId(req);
  if (!deviceId || !UUID_RE.test(deviceId)) {
    return res.status(400).json({ error: 'device_id required' });
  }

  // AUTHORIZATION: the caller may only ever read blobs addressed to a device it owns.
  // Proven here explicitly (and re-asserted inside the SQL below) so passing another
  // user's device id in `?device_id=` cannot reach a single row.
  const owned = await query<{ one: number }>(
    `select 1 as one from devices where id = $1 and user_id = $2 and revoked_at is null`,
    [deviceId, user_id]
  );
  if (!owned[0]) return res.status(403).json({ error: 'device does not belong to this user' });

  // Blocking (039). One query for the whole set, used by both feed paths below — a story
  // audience can be large, and asking per author would be a query per row.
  const blockedAuthors = [...(await blockedUserIds(user_id))];

  // Re-fetch path (reinstall / lost local DB): return already-delivered LIVE rows too
  // without touching delivered_at. A client that loses its database has no other way
  // back to its own key blobs, and the ratchet message is long gone from the sender.
  if (req.query.include_delivered === '1') {
    const all = await query(
      `select s.id as story_id, s.author_id, s.author_device_id, s.r2_key, s.media_mime,
              s.byte_size, s.created_at, s.expires_at,
              translate(encode(k.ciphertext,'base64'), E'\n', '') as ciphertext
         from story_keys k
         join stories s on s.id = k.story_id
        where k.recipient_device_id = $1::uuid and s.expires_at > now()
          -- Blocking (039): never surface a story authored by someone this user has a
          -- block with, in either direction. Filtered in SQL so BOTH feed paths inherit it
          -- rather than one being fixed and the other quietly leaking.
          and not (s.author_id = any($2::uuid[]))
        order by s.created_at asc
        limit ${FEED_LIMIT}`,
      [deviceId, blockedAuthors]
    );
    return res.json({ stories: withNumericByteSize(all) });
  }

  // Atomic mark-and-return, exactly like GET /messages/pending: UPDATE…RETURNING both
  // stamps delivered_at and returns precisely the rows that were still pending — no
  // double-delivery, no race between two concurrent foreground syncs.
  //
  // The CTE exists only to bound the page (Postgres has no LIMIT on UPDATE). It carries
  // the device-ownership join, so an unowned device_id yields an empty set and the
  // UPDATE touches nothing.
  const stories = await query(
    `with pending as (
        select k.story_id
          from story_keys k
          join stories s on s.id = k.story_id
          join devices d on d.id = k.recipient_device_id
         where d.id = $1::uuid and d.user_id = $2::uuid and d.revoked_at is null
           and k.delivered_at is null
           and s.expires_at > now()
           -- Blocking (039), applied in the CTE rather than after the UPDATE. Filtering
           -- later would still stamp delivered_at on a blocked author's row, consuming it
           -- so the key could never be re-fetched if the block were later lifted.
           and not (s.author_id = any($3::uuid[]))
         order by s.created_at asc
         limit ${FEED_LIMIT}
     )
     update story_keys k set delivered_at = now()
       from stories s, pending p
      where k.story_id = p.story_id
        and k.recipient_device_id = $1::uuid
        and s.id = k.story_id
        and k.delivered_at is null
     returning s.id as story_id, s.author_id, s.author_device_id, s.r2_key, s.media_mime,
               s.byte_size, s.created_at, s.expires_at,
               translate(encode(k.ciphertext,'base64'), E'\n', '') as ciphertext`,
    [deviceId, user_id, blockedAuthors]
  );
  return res.json({ stories: withNumericByteSize(stories) });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /stories/mine -> { stories: [...] } — the author's own live stories.
//
// `recipient_device_count` / `delivered_device_count` are ROUTING metadata the server
// already has (it wrote the rows). They are NOT views: a delivered key envelope means
// a device fetched it, not that a human opened the story. The client must label them
// as such — see docs/STORIES_PROTOCOL.md §view receipts.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/mine', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const stories = await query(
    `select s.id as story_id, s.r2_key, s.media_mime, s.byte_size, s.created_at, s.expires_at,
            (select count(*)::int from story_keys k where k.story_id = s.id) as recipient_device_count,
            (select count(*)::int from story_keys k
              where k.story_id = s.id and k.delivered_at is not null) as delivered_device_count
       from stories s
      where s.author_id = $1 and s.expires_at > now()
      order by s.created_at desc`,
    [user_id]
  );
  return res.json({ stories: withNumericByteSize(stories) });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /stories/receipts?device_id= -> { receipts: [{ id, story_id, ciphertext, created_at }] }
//
// An AUTHOR device pulls its pending view receipts. Same UPDATE…RETURNING mark-and-
// return as the feed. The viewer identity is INSIDE `ciphertext` (only the author's
// devices can open it) — there is no viewer column to return.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/receipts', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const deviceId = callerDeviceId(req);
  if (!deviceId || !UUID_RE.test(deviceId)) {
    return res.status(400).json({ error: 'device_id required' });
  }
  const owned = await query<{ one: number }>(
    `select 1 as one from devices where id = $1 and user_id = $2 and revoked_at is null`,
    [deviceId, user_id]
  );
  if (!owned[0]) return res.status(403).json({ error: 'device does not belong to this user' });

  const receipts = await query(
    `with pending as (
        select r.id
          from story_receipts r
          join devices d on d.id = r.recipient_device_id
         where d.id = $1::uuid and d.user_id = $2::uuid and d.revoked_at is null
           and r.delivered_at is null
         order by r.created_at asc
         limit ${FEED_LIMIT}
     )
     update story_receipts r set delivered_at = now()
       from pending p
      where r.id = p.id and r.delivered_at is null
     returning r.id, r.story_id,
               translate(encode(r.ciphertext,'base64'), E'\n', '') as ciphertext,
               r.created_at`,
    [deviceId, user_id]
  );
  return res.json({ receipts });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /stories
//   { story_id, r2_key, media_mime?, byte_size?, sender_device_id?,
//     keys: [{ recipient_device_id, ciphertext(b64) }, ...] }
//   -> { story_id, created_at, expires_at, delivered_devices }
//
// UPHOLDS THE RULE: every `ciphertext` is an opaque per-device blob; `r2_key` addresses
// ciphertext already sitting in R2; `media_mime` is the wrapper type; `byte_size` is a
// CIPHERTEXT length. `assertOpaque` rejects a body (or an entry) carrying a
// plaintext-ish field. There is no field on this endpoint through which a media key
// could arrive, and the server never fetches the object.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id: authDeviceId } = (req as any).auth;
  const { story_id, r2_key, media_mime, byte_size, sender_device_id, keys } = req.body ?? {};

  // Golden rule first, before anything is read out of the body.
  try {
    assertOpaque(req.body ?? {});
  } catch (e) {
    return res.status(400).json({ error: (e as Error).message });
  }

  if (typeof story_id !== 'string' || !UUID_RE.test(story_id)) {
    return res.status(400).json({ error: 'story_id must be a uuid (client-generated)' });
  }
  // AUTHORIZATION: the caller may only claim an object key inside its OWN namespace,
  // and the tail must be exactly the uuid presign-upload minted. Without the tail check
  // a caller could point a story at `media/stories/<self>/../<someone-else>` shapes or
  // at an arbitrary attacker-chosen key.
  const keyPrefix = `media/stories/${user_id}/`;
  const keyTail = typeof r2_key === 'string' && r2_key.startsWith(keyPrefix)
    ? r2_key.slice(keyPrefix.length)
    : null;
  if (!keyTail || !UUID_RE.test(keyTail)) {
    return res.status(400).json({ error: 'r2_key does not belong to this user' });
  }
  if (media_mime != null && (typeof media_mime !== 'string' || media_mime.length > 128)) {
    return res.status(400).json({ error: 'media_mime must be a short string' });
  }
  if (byte_size != null && (!Number.isSafeInteger(byte_size) || byte_size < 0)) {
    return res.status(400).json({ error: 'byte_size must be a non-negative integer' });
  }
  if (!Array.isArray(keys) || keys.length === 0) {
    return res.status(400).json({ error: 'keys must be a non-empty array' });
  }
  if (keys.length > MAX_KEYS_PER_REQUEST) {
    return res.status(413).json({ error: 'audience too large' });
  }
  const bad = validateEnvelopeBundle(keys, 'keys');
  if (bad) return res.status(400).json({ error: bad });

  // AUTHORIZATION: a body-supplied sender_device_id must be one of the caller's own
  // devices — otherwise a user could attribute a story to somebody else's device (and
  // the FK would blow up on a fabricated id).
  let deviceId: string | null = sender_device_id ?? authDeviceId ?? null;
  if (deviceId != null) {
    if (typeof deviceId !== 'string' || !UUID_RE.test(deviceId)) {
      return res.status(400).json({ error: 'sender_device_id must be a uuid' });
    }
    const own = await query<{ one: number }>(
      `select 1 as one from devices where id = $1 and user_id = $2`,
      [deviceId, user_id]
    );
    if (!own[0]) return res.status(400).json({ error: 'sender_device_id does not belong to this user' });
  }

  // Rolling-24h post cap.
  const posted = await query<{ n: number }>(
    `select count(*)::int as n from stories
      where author_id = $1 and created_at > now() - interval '24 hours'`,
    [user_id]
  );
  if ((posted[0]?.n ?? 0) >= MAX_STORIES_PER_DAY) {
    return res.status(429).json({ error: 'story limit reached' });
  }

  // expires_at is SERVER-computed. The envelope also carries the author's claimed
  // expiry, but that is only an offline fallback for an already-cached story — this
  // column is what every read path filters on.
  let created: { created_at: string; expires_at: string };
  try {
    const rows = await query<{ created_at: string; expires_at: string }>(
      `insert into stories (id, author_id, author_device_id, r2_key, media_mime, byte_size, expires_at)
         values ($1, $2, $3, $4, coalesce($5,'application/octet-stream'), $6, now() + interval '24 hours')
         returning created_at, expires_at`,
      [story_id, user_id, deviceId, r2_key, media_mime ?? null, byte_size ?? null]
    );
    created = rows[0];
  } catch (e) {
    // 23505 = unique_violation: the client retried a post that already landed.
    if ((e as any)?.code === '23505') return res.status(409).json({ error: 'story already exists' });
    throw e;
  }

  const delivered = await storeKeysAndRelay(story_id, user_id, keys);

  return res.json({
    story_id,
    created_at: created.created_at,
    expires_at: created.expires_at,
    delivered_devices: delivered,
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /stories/:id/keys  { keys: [...] } -> { added: N }
//
// Author-only append to a LIVE story. Covers (a) devices skipped at post time because
// their one-time prekeys ran dry, (b) a recipient registering a NEW device inside the
// 24h window. Same insert + relay + push path as POST /stories.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/keys', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const storyId = req.params.id;
  const { keys } = req.body ?? {};

  if (!UUID_RE.test(storyId)) return res.status(400).json({ error: 'invalid story id' });
  try {
    assertOpaque(req.body ?? {});
  } catch (e) {
    return res.status(400).json({ error: (e as Error).message });
  }
  if (!Array.isArray(keys) || keys.length === 0) {
    return res.status(400).json({ error: 'keys must be a non-empty array' });
  }
  if (keys.length > MAX_KEYS_PER_REQUEST) {
    return res.status(413).json({ error: 'audience too large' });
  }
  const bad = validateEnvelopeBundle(keys, 'keys');
  if (bad) return res.status(400).json({ error: bad });

  const rows = await query<{ author_id: string }>(
    `select author_id from stories where id = $1 and expires_at > now()`,
    [storyId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'story not found' });
  // AUTHORIZATION: only the author may widen a story's audience.
  if (rows[0].author_id !== user_id) {
    return res.status(403).json({ error: 'not the author of this story' });
  }

  const added = await storeKeysAndRelay(storyId, user_id, keys);
  return res.json({ added });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /stories/:id/receipt  { receipts: [{ recipient_device_id, ciphertext }] }
//   -> { accepted: N }
//
// UPHOLDS THE RULE: the receipt payload (`{story_id, viewer_id, viewed_at}`) is
// encrypted to the author's devices over the 1:1 ratchet before it gets here. This
// process stores an opaque blob and never learns a viewed_at it can attribute from
// the row alone.
//
// HONEST CAVEAT, stated so nobody mistakes the missing column for a defence: the API
// authenticates whoever POSTs, so the server CAN observe "user A submitted a receipt
// for story S at time T". We do not STORE that, and there is no sealed sender to
// remove it. That is exactly why view receipts default to OFF on the clients.
//
// NO PUSH from this endpoint, ever: a view receipt must never wake a device.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/receipt', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const storyId = req.params.id;
  const { receipts } = req.body ?? {};

  if (!UUID_RE.test(storyId)) return res.status(400).json({ error: 'invalid story id' });
  try {
    assertOpaque(req.body ?? {});
  } catch (e) {
    return res.status(400).json({ error: (e as Error).message });
  }
  if (!Array.isArray(receipts) || receipts.length === 0) {
    return res.status(400).json({ error: 'receipts must be a non-empty array' });
  }
  if (receipts.length > MAX_KEYS_PER_REQUEST) {
    return res.status(413).json({ error: 'too many receipts' });
  }
  const bad = validateEnvelopeBundle(receipts, 'receipts');
  if (bad) return res.status(400).json({ error: bad });

  const stories = await query<{ author_id: string }>(
    `select author_id from stories where id = $1`,
    [storyId]
  );
  if (!stories[0]) return res.status(404).json({ error: 'story not found' });
  const authorId = stories[0].author_id;

  // AUTHORIZATION 1: you cannot claim to have viewed a story you were never sent.
  // (The author's own linked devices hold key rows too, so an author viewing their
  // own story from a second device still passes.)
  const entitled = await query<{ one: number }>(
    `select 1 as one from story_keys k
       join devices d on d.id = k.recipient_device_id
      where k.story_id = $1 and d.user_id = $2
      limit 1`,
    [storyId, user_id]
  );
  if (!entitled[0]) return res.status(403).json({ error: 'not a recipient of this story' });

  // AUTHORIZATION 2: every receipt target must be a live device of the story's AUTHOR.
  // Without this the endpoint would be a free write primitive into any device's queue.
  const targets = [...new Set((receipts as any[]).map((r) => r.recipient_device_id))];
  const authorDevices = await query<{ id: string }>(
    `select id from devices where id = any($1::uuid[]) and user_id = $2 and revoked_at is null`,
    [targets, authorId]
  );
  const allowed = new Set(authorDevices.map((d) => d.id));
  if (targets.some((t) => !allowed.has(t))) {
    return res.status(403).json({ error: 'receipt target is not the story author' });
  }

  let accepted = 0;
  for (const entry of receipts as { recipient_device_id: string; ciphertext: string }[]) {
    await query(
      `insert into story_receipts (story_id, recipient_device_id, ciphertext)
         values ($1, $2, $3)`,
      [storyId, entry.recipient_device_id, b64(entry.ciphertext)]
    );
    accepted++;
  }

  // Routing-only signal to the author's live sockets; the blobs are pulled via
  // GET /stories/receipts. Deliberately NO wake push.
  await publisher.publish(
    `channel:user:${authorId}`,
    JSON.stringify({ type: 'story_receipt', story_id: storyId })
  );

  return res.json({ accepted });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// DELETE /stories/:id -> 204
//
// Author-only. Deletes the R2 object, then the row (story_keys + story_receipts
// cascade), then tells live recipients to drop it.
//
// NOT A SECURITY OPERATION, and the client's confirm dialog must say so: anyone who
// already downloaded and decrypted the media keeps it forever. No primitive in
// e2e-core expires, rotates, or zeroizes a delivered key.
// ─────────────────────────────────────────────────────────────────────────────────
router.delete('/:id', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const storyId = req.params.id;
  if (!UUID_RE.test(storyId)) return res.status(400).json({ error: 'invalid story id' });

  const rows = await query<{ author_id: string; r2_key: string }>(
    `select author_id, r2_key from stories where id = $1`,
    [storyId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'story not found' });
  // AUTHORIZATION: only the author may delete.
  if (rows[0].author_id !== user_id) {
    return res.status(403).json({ error: 'not the author of this story' });
  }

  // Collect recipients BEFORE the delete cascades story_keys away.
  const recipients = await query<{ user_id: string }>(
    `select distinct d.user_id from story_keys k
       join devices d on d.id = k.recipient_device_id
      where k.story_id = $1`,
    [storyId]
  );

  // Best-effort object delete. If R2 is unreachable we still drop the rows — the
  // user asked for the story to be gone, and the bucket lifecycle rule on
  // `media/stories/` reaps the orphaned ciphertext within 48h.
  if (r2Configured()) {
    try {
      await deleteObject(rows[0].r2_key);
    } catch (e) {
      console.warn('[stories] r2 delete failed (lifecycle rule will reap):', (e as Error).message);
    }
  }

  await query(`delete from stories where id = $1`, [storyId]);

  for (const r of recipients) {
    await publisher.publish(
      `channel:user:${r.user_id}`,
      JSON.stringify({ type: 'story_deleted', story_id: storyId })
    );
  }

  return res.status(204).end();
}));

export default router;
