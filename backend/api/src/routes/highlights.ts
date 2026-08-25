// Creator story highlights — the curated shelves on a public creator profile.
//
// ============================ NOT END-TO-END ENCRYPTED ============================
// Read the header of 048_creator_highlights.sql before touching this file. A highlight is a
// curated shelf on a PUBLIC page; its whole purpose is to be seen by strangers who follow
// nobody and hold no key. That is the same broadcast-identity argument 029_creator_profiles.sql
// makes for the avatar beside it, and it is a scoped exception, not a precedent.
//
// STILL END-TO-END ENCRYPTED and untouched by this file: messages, calls, locations, moments
// and backups. Nothing here shares a code path with any of them.
// =================================================================================
//
// ── A FOLLOW IS STILL NOT A MESSAGING RIGHT ──────────────────────────────────────
// 029 says any code reading the public graph to authorise a message is a bug, and this file
// adds public-graph surface while changing that not at all. Nothing here grants reachability,
// and the profile screen that renders these shelves deliberately has no Message button.
//
// ── CLIPS ONLY, AND THE FK IS WHAT SAYS SO ───────────────────────────────────────
// creator_highlight_items references clips(id) and nothing else. A highlight cannot hold a
// message, a moment or a story — those are E2EE and audience-scoped, and putting one on a
// public shelf would be a disclosure dressed as a feature. This router adds NO second path to
// populate a shelf: every insert below goes through that one foreign key.
//
// ── WHY THIS IS ITS OWN FILE, MOUNTED AT THE ROOT ────────────────────────────────
// The read path is keyed on a HANDLE ('/creators/:handle/highlights') because that is what a
// public profile URL carries, while every write path is keyed on the highlight's own uuid
// ('/highlights/:id'). Those are two prefixes, so — exactly like tournaments.ts and events.ts —
// the paths are declared IN FULL and the router mounts with no prefix of its own.
//
// It is not in creators.ts for a second reason: that router ends with a one-segment wildcard
// ('GET /:handle'), and a '/highlights' route added after it would be swallowed by the
// wildcard while looking correct in the source.
import { Router } from 'express';
import { pool, query } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';
import { presignGet, r2Configured } from '../r2';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const MAX_TITLE = 40;          // creator_highlights_title_len
const MAX_COVER_KEY = 400;
const MAX_HIGHLIGHTS_PER_USER = 30;
const MAX_ITEMS_PER_HIGHLIGHT = 100;

function trimmed(v: unknown, max: number): string | null {
  if (v == null) return null;
  const s = String(v).trim();
  return s ? s.slice(0, max) : null;
}

/**
 * Presign an object key, or null.
 *
 * 048: cover_url is an OBJECT KEY, not an absolute URL — the same convention as avatar_url, so
 * the same presign-on-read path serves both. A null key, an unconfigured R2 and a failed
 * presign all collapse to null, because the client's fallback (the first item's thumbnail) is
 * the same in all three cases and an error here must not fail the whole rail.
 */
async function presignOrNull(key: string | null | undefined): Promise<string | null> {
  if (!key || !r2Configured()) return null;
  return presignGet(key).catch(() => null);
}

/**
 * Shape one shelf for the wire.
 *
 * EVERY KEY IS ALWAYS PRESENT, null rather than omitted — the rule creators.ts and
 * communities.ts both state: Swift's Codable throws `keyNotFound` on an absent key, so
 * dropping `cover_url` for the shelves that have no explicit cover would break the client for
 * the majority case (048: "an explicit cover is the exception").
 */
async function highlightShape(r: any, items: any[]) {
  return {
    id: r.id,
    title: r.title,
    cover_url: await presignOrNull(r.cover_url),
    position: r.position ?? 0,
    item_count: items.length,
    // Always an array, empty rather than absent.
    items,
    created_at: r.created_at,
  };
}

/**
 * The clips on a set of shelves, in order, as one query rather than one per shelf.
 *
 * A rail of ten highlights would otherwise be eleven round trips. The rows come back grouped
 * by highlight so the caller can slot them in without a second pass over the database.
 *
 * A clip that was deleted or removed is FILTERED OUT rather than rendered as a hole — 048
 * anticipates exactly this ("so the shelves that showed it can be corrected rather than
 * rendering a hole"). The join row is left in place: the clip's own delete cascades it, and a
 * route silently deleting shelf contents on a read is a write nobody asked for.
 */
async function itemsFor(highlightIds: string[]): Promise<Map<string, any[]>> {
  const byHighlight = new Map<string, any[]>();
  for (const id of highlightIds) byHighlight.set(id, []);
  if (!highlightIds.length) return byHighlight;

  const rows = await query<any>(
    `select i.highlight_id, i.position, i.added_at,
            c.id as clip_id, c.thumb_r2_key, c.caption, c.duration_ms,
            c.width, c.height, c.view_count, c.like_count
       from creator_highlight_items i
       join clips c on c.id = i.clip_id
      where i.highlight_id = any($1::uuid[])
        and c.deleted_at is null and c.removed_at is null and c.status = 'ready'
      order by i.highlight_id, i.position, i.added_at`,
    [highlightIds]
  );

  for (const r of rows) {
    byHighlight.get(r.highlight_id)?.push({
      clip_id: r.clip_id,
      thumb_url: await presignOrNull(r.thumb_r2_key),
      caption: r.caption ?? null,
      duration_ms: r.duration_ms ?? null,
      width: r.width ?? null,
      height: r.height ?? null,
      view_count: r.view_count ?? 0,
      like_count: r.like_count ?? 0,
      position: r.position ?? 0,
    });
  }
  return byHighlight;
}

type Owned =
  | { ok: true; highlightId: string }
  | { ok: false; status: number; error: string };

/**
 * Assert the caller owns this shelf.
 *
 * ONE probe, with the ownership test in the WHERE rather than read-then-compare: the row is
 * either the caller's or it does not exist as far as this endpoint is concerned.
 *
 * "Not yours" and "no such highlight" get the SAME 404. Distinguishing them would confirm
 * which highlight ids exist on other people's profiles to anyone willing to guess, and the
 * caller's next move is identical either way.
 */
async function requireOwnHighlight(highlightId: string, userId: string): Promise<Owned> {
  if (!UUID_RE.test(highlightId)) {
    return { ok: false, status: 400, error: 'highlight id must be a uuid' };
  }
  const row = (
    await query<{ id: string }>(
      `select id from creator_highlights where id = $1 and user_id = $2`,
      [highlightId, userId]
    )
  )[0];
  if (!row) return { ok: false, status: 404, error: 'no such highlight' };
  return { ok: true, highlightId: row.id };
}

// ─────────────────────────────────────────────────────────────────────────────────
// GET /creators/:handle/highlights — the rail on a public profile, with its clips.
//
// PUBLIC, like the profile it sits on. `requireAuth` still applies (every route in this API
// does) but no relationship to the creator is required: not following, not a mutual contact,
// nothing. That is what "public shelf" means.
//
// A SUSPENDED profile 404s rather than returning an empty rail, matching `GET /creators/:handle`:
// the moderation status of an account is not information a stranger is owed, and an endpoint
// that answered differently for a suspended profile would be a way to enumerate who has been
// actioned.
//
// `is_self` rides along so the client can offer the edit affordances without a second probe
// and without comparing ids it should not be handed — 029 keeps user_id out of the public
// profile shape for exactly that reason, so this answers the question instead of exposing the
// input to it.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/creators/:handle/highlights',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const handle = String(req.params.handle ?? '').toLowerCase();

    const profile = (
      await query<{ user_id: string }>(
        `select user_id from creator_profiles
          where lower(handle) = $1 and suspended_at is null`,
        [handle]
      )
    )[0];
    if (!profile) return res.status(404).json({ error: 'not found' });

    const rows = await query<any>(
      `select id, title, cover_url, position, created_at
         from creator_highlights
        where user_id = $1
        order by position, created_at`,
      [profile.user_id]
    );
    const items = await itemsFor(rows.map((r) => r.id));

    res.json({
      highlights: await Promise.all(rows.map((r) => highlightShape(r, items.get(r.id) ?? []))),
      is_self: profile.user_id === user_id,
    });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /highlights   { title, cover_url?, position? } — create one. Owner only, implicitly.
//
// There is no `user_id` in the body and there must never be one: the shelf is keyed on the
// AUTHENTICATED caller. A client-supplied owner would let anyone add shelves to anyone's
// profile, which is the exact shape of authorisation bug this API's helpers exist to prevent.
//
// A CREATOR PROFILE IS REQUIRED. creator_highlights is keyed on users(id), so the FK alone
// would happily accept a shelf from an account with no public page — one that nothing can ever
// render, because the only read route resolves a handle. Checked here rather than left to
// produce an invisible row.
//
// `position` defaults to the end so creating a shelf does not reshuffle the rail.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/highlights',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;

    const profile = (
      await query<{ user_id: string }>(`select user_id from creator_profiles where user_id = $1`, [
        user_id,
      ])
    )[0];
    if (!profile) {
      return res.status(409).json({ error: 'create a creator profile before adding highlights' });
    }

    const title = trimmed(req.body?.title, MAX_TITLE);
    // creator_highlights_title_len would reject an empty title as a 500; catch it as a 400.
    if (!title) return res.status(400).json({ error: 'title is required' });
    const coverUrl = req.body?.cover_url !== undefined ? trimmed(req.body.cover_url, MAX_COVER_KEY) : null;

    const existing = await query<{ n: number; max_position: number | null }>(
      `select count(*)::int as n, max(position) as max_position
         from creator_highlights where user_id = $1`,
      [user_id]
    );
    if ((existing[0]?.n ?? 0) >= MAX_HIGHLIGHTS_PER_USER) {
      return res.status(409).json({
        error: `a profile can have at most ${MAX_HIGHLIGHTS_PER_USER} highlights`,
      });
    }
    const explicit = req.body?.position !== undefined ? Math.trunc(Number(req.body.position)) : undefined;
    if (explicit !== undefined && !Number.isFinite(explicit)) {
      return res.status(400).json({ error: 'position must be a number' });
    }
    const position = explicit ?? (existing[0]?.max_position ?? -1) + 1;

    const rows = await query<any>(
      `insert into creator_highlights (user_id, title, cover_url, position)
            values ($1, $2, $3, $4)
       returning id, title, cover_url, position, created_at`,
      [user_id, title, coverUrl, position]
    );
    res.status(201).json({ highlight: await highlightShape(rows[0], []) });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// PATCH /highlights/:id   { title?, cover_url?, position? } — rename / recover / reorder.
//
// `cover_url: null` CLEARS the cover; an absent key leaves it alone. The two have to be
// distinguishable or there is no way to go back to the first-item fallback once an explicit
// cover has been set — the same rule PATCH /communities/:id applies to `description`.
//
// Reordering is one position per request rather than a whole-rail array. 048 gave the column
// its own value precisely so a creator can reorder "without their highlights jumping to the
// end of the row when they edit one"; a bulk reorder endpoint would be the read-modify-write
// of the whole set that the schema is shaped to avoid.
// ─────────────────────────────────────────────────────────────────────────────────
router.patch(
  '/highlights/:id',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireOwnHighlight(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

    const sets: string[] = [];
    const params: unknown[] = [gate.highlightId, user_id];
    const push = (sql: string, value: unknown) => {
      params.push(value);
      sets.push(`${sql} = $${params.length}`);
    };

    if (req.body?.title !== undefined) {
      const title = trimmed(req.body.title, MAX_TITLE);
      if (!title) return res.status(400).json({ error: 'title cannot be empty' });
      push('title', title);
    }
    if (req.body?.cover_url !== undefined) push('cover_url', trimmed(req.body.cover_url, MAX_COVER_KEY));
    if (req.body?.position !== undefined) {
      const n = Math.trunc(Number(req.body.position));
      if (!Number.isFinite(n)) return res.status(400).json({ error: 'position must be a number' });
      push('position', n);
    }
    if (!sets.length) return res.status(400).json({ error: 'nothing to update' });

    // The ownership test is repeated in the WHERE rather than trusted from the probe above: a
    // gate that authorises and a statement that writes should not be able to disagree.
    const rows = await query<any>(
      `update creator_highlights set ${sets.join(', ')}
        where id = $1 and user_id = $2
       returning id, title, cover_url, position, created_at`,
      params
    );
    if (!rows[0]) return res.status(404).json({ error: 'no such highlight' });

    const items = await itemsFor([rows[0].id]);
    res.json({ highlight: await highlightShape(rows[0], items.get(rows[0].id) ?? []) });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// DELETE /highlights/:id — remove a shelf.
//
// A HARD delete, and the items go with it via `on delete cascade` (048). Unlike a post or an
// announcement there is no history to keep and nothing to appeal: a shelf is one creator's
// arrangement of their own already-public clips, and removing it destroys no content — every
// clip it pointed at is untouched and still on the profile grid.
// ─────────────────────────────────────────────────────────────────────────────────
router.delete(
  '/highlights/:id',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireOwnHighlight(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

    const rows = await query<{ id: string }>(
      `delete from creator_highlights where id = $1 and user_id = $2 returning id`,
      [gate.highlightId, user_id]
    );
    res.json({ deleted: rows.length > 0 });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /highlights/:id/items   { clip_id, position? } — put a clip on the shelf.
//
// ── TWO OWNERSHIP CHECKS, NOT ONE ────────────────────────────────────────────────
// The caller must own the SHELF and must also be the AUTHOR of the clip. The first is
// obvious; the second is what stops someone building a shelf out of another creator's clips
// and presenting it on their own profile as their work. The clips are public either way — this
// is about attribution, not access.
//
// ── CLIPS ONLY ───────────────────────────────────────────────────────────────────
// `clip_id` is checked against the clips table and inserted through the one foreign key 048
// provides. There is deliberately no `kind` parameter and no second table this can point at:
// a highlight that could name a moment or a story would put E2EE, audience-scoped content on
// a public shelf.
//
// `on conflict do nothing` makes a retry idempotent — the primary key already says a clip
// appears at most once per shelf, so a double-tap is a no-op rather than a 409.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/highlights/:id/items',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireOwnHighlight(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

    const clipId = String(req.body?.clip_id ?? '');
    if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'clip_id must be a uuid' });

    // Author AND liveness in one probe. A deleted or removed clip cannot be shelved: it would
    // be a row the read path filters out anyway, so accepting it would mean a shelf that
    // silently holds nothing.
    const clip = (
      await query<{ id: string }>(
        `select id from clips
          where id = $1 and author_id = $2
            and deleted_at is null and removed_at is null`,
        [clipId, user_id]
      )
    )[0];
    if (!clip) return res.status(404).json({ error: 'no such clip of yours' });

    const client = await pool.connect();
    try {
      await client.query('begin');
      // The cap and the insert in one transaction: two concurrent adds would otherwise both
      // read the same count and both insert past the ceiling.
      const existing = (
        await client.query<{ n: number; max_position: number | null }>(
          `select count(*)::int as n, max(position) as max_position
             from creator_highlight_items where highlight_id = $1`,
          [gate.highlightId]
        )
      ).rows[0];
      if ((existing?.n ?? 0) >= MAX_ITEMS_PER_HIGHLIGHT) {
        await client.query('rollback');
        return res.status(409).json({
          error: `a highlight can hold at most ${MAX_ITEMS_PER_HIGHLIGHT} clips`,
        });
      }
      const explicit =
        req.body?.position !== undefined ? Math.trunc(Number(req.body.position)) : undefined;
      if (explicit !== undefined && !Number.isFinite(explicit)) {
        await client.query('rollback');
        return res.status(400).json({ error: 'position must be a number' });
      }
      const position = explicit ?? (existing?.max_position ?? -1) + 1;

      const inserted = await client.query(
        `insert into creator_highlight_items (highlight_id, clip_id, position)
              values ($1, $2, $3)
         on conflict (highlight_id, clip_id) do nothing
           returning clip_id`,
        [gate.highlightId, clipId, position]
      );
      await client.query('commit');
      // `added: false` means it was already there — a successful outcome, not an error.
      res.status(201).json({ added: (inserted.rowCount ?? 0) > 0, clip_id: clipId });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// DELETE /highlights/:id/items/:clipId — take a clip off the shelf.
//
// Removes the JOIN ROW ONLY. The clip itself is untouched and stays on the creator's grid —
// unshelving is a curation act, not a deletion, and a route that deleted the clip because it
// was removed from one shelf would be catastrophic and easy to write by accident.
// ─────────────────────────────────────────────────────────────────────────────────
router.delete(
  '/highlights/:id/items/:clipId',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireOwnHighlight(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

    const clipId = String(req.params.clipId ?? '');
    if (!UUID_RE.test(clipId)) return res.status(400).json({ error: 'clip id must be a uuid' });

    const rows = await query<{ clip_id: string }>(
      `delete from creator_highlight_items
        where highlight_id = $1 and clip_id = $2
       returning clip_id`,
      [gate.highlightId, clipId]
    );
    res.json({ removed: rows.length > 0 });
  })
);

export default router;
