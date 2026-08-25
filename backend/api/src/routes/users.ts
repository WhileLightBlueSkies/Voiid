// User / profile routes (Section 10). Identity is ours (Supabase Postgres); profile is not E2E content.
import { Router } from 'express';
import { query } from '../db';
import { isBlockedEitherWay } from '../blocking';
import { requireAuth, invalidateAccountState, revokeAccountSessions } from '../auth';
import { asyncHandler } from '../util';

const router = Router();

// ─────────────────────────────────────────────────────────────────────────────────
// Availability status — users.status_text.
//
// THE COLUMN IS OLD; NOTHING EVER READ OR WROTE IT. It has been `text` since 001, and until
// now no route accepted it and no client set it. That freedom is exactly why this closes it
// down to a FIXED VOCABULARY rather than opening a free-text field:
//
//   • Free text here is user-generated content shown to strangers — `GET /users/:id` and
//     `GET /reachability/by-username` both hand a profile to someone who may never have met
//     the owner. That needs a length cap, a moderation queue and a reports.ts target type,
//     none of which exist for this field. `bio` already occupies the "write something about
//     yourself" slot and already travels with the user as a reportable subject; a SECOND
//     free-text surface buys nothing and costs a moderation surface.
//   • A closed set is also the only shape a client can localise, sort or draw as a coloured
//     dot. "Busy" renders as a swatch; an arbitrary sentence cannot.
//
// Clearing is `null`, not an empty string, so "no status" has exactly one representation and
// a row cannot be simultaneously unset and set-to-blank.
//
// NOTE WHAT IS NOT HERE: nothing in this list changes delivery, notification or ringing
// behaviour anywhere in the API. It is a label the owner chooses and viewers read. In
// particular `dnd` does NOT suppress push — the notification path never reads this column —
// and the client is required to say so rather than let the name imply it.
const STATUS_VALUES = ['available', 'busy', 'away', 'dnd'] as const;
type StatusValue = (typeof STATUS_VALUES)[number];
function isStatusValue(v: unknown): v is StatusValue {
  return typeof v === 'string' && (STATUS_VALUES as readonly string[]).includes(v);
}

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

// ─────────────────────────────────────────────────────────────────────────────────
// User game preferences — first-run walkthrough markers (LUDO_GAME_SPEC.md §10).
//
// The walkthrough seen-state is PERSISTED CROSS-DEVICE here, while the client writes its own
// local copy immediately without waiting on this call (a subway tunnel must not force a
// player through seven steps twice). Versioned, so a future rules refresh can raise the bar.
// ─────────────────────────────────────────────────────────────────────────────────

// GET /users/me/preferences — everything this device should mirror locally.
router.get('/me/preferences', requireAuth, asyncHandler(async (req, res) => {
  const { user_id: userId } = (req as any).auth as { user_id: string };
  const rows = await query<{ preferences: Record<string, number> }>(
    `select preferences from user_game_preferences where user_id = $1`,
    [userId]
  );
  res.json({ preferences: rows[0]?.preferences ?? {} });
}));

// PUT /users/me/preferences/ludo-walkthrough — body: { version: 1 }.
router.put('/me/preferences/ludo-walkthrough', requireAuth, asyncHandler(async (req, res) => {
  const { user_id: userId } = (req as any).auth as { user_id: string };
  const version = req.body?.version;
  if (!Number.isInteger(version) || (version as number) < 1 || (version as number) > 1000) {
    return res.status(400).json({ error: 'version must be a positive integer' });
  }
  await query(
    `insert into user_game_preferences (user_id, preferences, updated_at)
     values ($1, jsonb_set('{}'::jsonb, '{ludoWalkthrough}', $2::jsonb), now())
     on conflict (user_id) do update
       set preferences = greatest(
             user_game_preferences.preferences,
             jsonb_set(user_game_preferences.preferences, '{ludoWalkthrough}', $2::jsonb)
           ),
           updated_at = now()`,
    [userId, JSON.stringify(version)]
  );
  res.json({ ok: true });
}));

// GET /users/me/preferences/ludo-walkthrough — current seen version (0 = never seen).
router.get('/me/preferences/ludo-walkthrough', requireAuth, asyncHandler(async (req, res) => {
  const { user_id: userId } = (req as any).auth as { user_id: string };
  const rows = await query<{ v: number | null }>(
    `select preferences->'ludoWalkthrough' as v from user_game_preferences where user_id = $1`,
    [userId]
  );
  res.json({ version: rows[0]?.v ?? 0 });
}));

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
    contact_pin_hash: string | null; contact_pin_enc: string | null;
    contact_pin_set_at: string | null;
    encrypted_photo_url: string | null; profile_key_version: number;
  }>(
    `select id, full_name, photo_url, bio, status_text, username, phone_number,
            photo_privacy, about_privacy, contact_pin_hash, contact_pin_enc, contact_pin_set_at,
            encrypted_photo_url, profile_key_version
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
  // Blocking (043) hides the same fields the 'nobody' scope hides — photo and bio — by
  // folding into the single `allowed` choke point rather than patching each field, so a
  // future field added here inherits the rule automatically instead of silently leaking.
  //
  // Name and username stay visible ON PURPOSE. A blocked user must still be able to see
  // who they are looking at (a chat header, an old group thread), and those are the two
  // fields a stranger already gets from any conversation they share. Hiding them would
  // announce the block rather than conceal it.
  const blockedPair = !isOwner && (await isBlockedEitherWay(viewerId, targetId));
  const allowed = (scope: string) =>
    isOwner || (!blockedPair && (scope === 'everyone' || (scope === 'contacts' && viewerIsContact)));

  // ── Availability status rides the LAST-SEEN gate, not photo_privacy and not about_privacy.
  //
  // A status is presence information: "Away" and "Do not disturb" say something about where
  // the person is and whether they are attending their phone, which is the same class of
  // fact `last_seen_privacy` exists to withhold. Gating it under About instead would leave a
  // second door into the same room — someone who set last-seen to 'nobody' would still be
  // broadcasting "Away", and would reasonably think they had closed that.
  //
  // `canSeeLastSeen` is CALLED rather than reimplemented, deliberately. It is the single
  // source of truth the presence routes already share, including its ordering (blocking
  // short-circuits the scope) and its direction (the TARGET's address book decides, not the
  // viewer's). A local copy of those two subtleties is a copy that will drift.
  const showStatus = await canSeeLastSeen(viewerId, targetId);

  res.json({
    user: {
      id: u.id,
      full_name: u.full_name,
      username: u.username,
      // Hidden reads as null — the same shape as "never set one" — so a viewer cannot tell a
      // privacy setting from an unset field, exactly as hidden presence is indistinguishable
      // from being offline.
      status_text: showStatus ? u.status_text : null,
      photo_url: allowed(u.photo_privacy) ? u.photo_url : null,
      // The ENCRYPTED avatar object, plus the key version it was encrypted under. A client
      // holding an older version knows its wrapped key is stale and re-fetches, rather than
      // failing a decrypt and being unable to tell that apart from corruption.
      //
      // Both are useless without the wrapped key, which only reaches devices the owner has an
      // established session with — so exposing them here leaks nothing.
      encrypted_photo_url: allowed(u.photo_privacy) ? u.encrypted_photo_url : null,
      profile_key_version: u.profile_key_version,
      bio: allowed(u.about_privacy) ? u.bio : null,
      // The phone number is the account's identity and is returned ONLY to the owner
      // (self), never to anyone else — it is how a user recovers their own real number on
      // a device that didn't capture it at OTP time. Others never receive it.
      phone_number: isOwner ? u.phone_number : undefined,
      // Contact PIN state — OWNER ONLY, and only WHETHER one is set. The PIN itself has
      // exactly one door, GET /reachability/contact-pin, so there is a single place to audit
      // for this disclosure rather than two that can drift apart.
      //
      // Leaking `has_contact_pin` to a non-owner would be a small but real oracle: it tells
      // a stranger whether the account is reachable by handle at all. That answer belongs to
      // GET /reachability/by-username, which is the deliberate, rate-limited door for it.
      // Either storage scheme counts: checking only the hash would report "no PIN" for
      // every user who rotated after migration 026. See reachability.ts `hasPin`.
      has_contact_pin: isOwner ? !!(u.contact_pin_hash || u.contact_pin_enc) : undefined,
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
  // Availability status — validated against the closed vocabulary, in the same shape as the
  // privacy enums below rather than passed through like `bio`. An unvalidated write here
  // would put arbitrary caller-supplied text on a profile that strangers can read, which is
  // precisely what choosing a fixed set was meant to prevent; the column's type does not
  // enforce it, so this is the only place that can.
  //
  // `null` clears. It is accepted explicitly because `add` skips only `undefined`, so
  // "remove my status" and "don't touch my status" stay distinguishable — a client that
  // conflated them could never turn one off.
  if (status_text !== undefined) {
    if (status_text !== null && !isStatusValue(status_text)) {
      return res.status(400).json({ error: `status_text must be null or one of ${STATUS_VALUES.join(', ')}` });
    }
    add('status_text', status_text);
  }
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

// ─────────────────────────────────────────────────────────────────────────────────
// Presence — online + last_seen, with users.last_seen_privacy enforced.
//
// TWO ROUTES, ONE GATE. `/status/:id` answers for one user and `/presence` answers for many,
// and they MUST agree: a batch endpoint that is even slightly more permissive than the single
// one is a probe — a caller who cannot see Ravi's presence one way asks the other way. So the
// rule lives exactly once, in `presenceFor` below, and both routes call it. Do not inline a
// second copy of this logic anywhere, however small the shortcut looks.
// ─────────────────────────────────────────────────────────────────────────────────

/**
 * May `viewerId` see `targetId`'s last-seen (and therefore their online state)?
 *
 * THE SINGLE SOURCE OF TRUTH for presence visibility. Extracted from `/status/:id`, whose
 * behaviour it reproduces exactly — including its ordering, where blocking is checked BEFORE
 * the privacy scope and short-circuits it.
 */
async function canSeeLastSeen(viewerId: string, targetId: string): Promise<boolean> {
  // Your own presence is never hidden from you.
  if (viewerId === targetId) return true;
  // Blocking (043) hides presence in BOTH directions, and does it by reusing the existing
  // hidden shape — `online: false, last_seen: null` — rather than a distinctive error.
  // That is the same answer a viewer gets from someone whose scope is 'nobody', so a
  // blocked user cannot tell a block from a privacy setting.
  if (await isBlockedEitherWay(viewerId, targetId)) return false;

  const prow = await query<{ last_seen_privacy: string }>(
    `select last_seen_privacy from users where id = $1`, [targetId]);
  const scope = prow[0]?.last_seen_privacy ?? 'everyone';
  if (scope === 'nobody') return false;
  if (scope === 'contacts') {
    // NOTE THE DIRECTION: it is the TARGET's address book that decides, not the viewer's.
    // 'contacts' means "people I have in my contacts", so the owner of the row is the target.
    const c = await query(
      `select 1 from contact_sync where owner_user_id = $1 and contact_user_id = $2 limit 1`,
      [targetId, viewerId]);
    return c.length > 0;
  }
  return true;
}

/** One user's presence, already gated. The shape both routes serve. */
async function presenceFor(viewerId: string, targetId: string) {
  const { redis } = await import('../redis');
  const showLastSeen = await canSeeLastSeen(viewerId, targetId);
  // Redis is only READ once the gate has said yes for last_seen; `online` is read either way
  // but discarded when hidden, because the answer must not vary in TIMING between a visible
  // and a hidden user any more than it varies in shape.
  const online = await redis.get(`user:${targetId}:online`);
  const lastSeen = showLastSeen ? await redis.get(`user:${targetId}:last_seen`) : null;
  return {
    user_id: targetId,
    // When last-seen is hidden, online is hidden too (they leak the same info).
    online: showLastSeen ? online === '1' : false,
    last_seen: lastSeen ? Number(lastSeen) : null,
  };
}

// GET /users/status/:id — online + last_seen, with last_seen_privacy enforced.
router.get('/status/:id', requireAuth, asyncHandler(async (req, res) => {
  const viewerId = (req as any).auth.user_id;
  res.json(await presenceFor(viewerId, req.params.id));
}));

// POST /users/presence — body: { user_ids: string[] } → { presence: [...] }
//
// WHY THIS EXISTS: the Games tab wants presence for everyone the player has a direct
// conversation with. Per-user that is N round trips over a mobile link for a screen that
// re-polls every minute; a friends list of a dozen people would spend a dozen requests to
// draw one row of avatars.
//
// BOUNDED, because an unbounded id list is an enumeration primitive: hand the server ten
// thousand ids and it happily reports which of them are awake right now. 64 is comfortably
// above any plausible direct-conversation count on one screen and far below useful for
// sweeping a user table. Over the cap is a 400, not a silent truncation — a caller that
// asked about 200 people and got 64 answers cannot tell which 136 were dropped.
//
// THE GATE IS PER USER AND IS THE SAME GATE. Every id goes through `presenceFor`
// individually; there is no batched shortcut around it. A user this viewer may not see comes
// back `online: false, last_seen: null` — present in the response and indistinguishable from
// someone who is genuinely offline, exactly as the single route answers. Absent ids would
// themselves be a signal ("the server declined to answer about Ravi").
const PRESENCE_BATCH_MAX = 64;
router.post('/presence', requireAuth, asyncHandler(async (req, res) => {
  const viewerId = (req as any).auth.user_id;
  const ids = req.body?.user_ids;
  if (!Array.isArray(ids)) return res.status(400).json({ error: 'user_ids must be an array' });
  // De-duplicated before the cap is applied, so a client that sends the same id twice is not
  // punished for it, and so the cap counts real subjects rather than list entries.
  const unique = [...new Set(ids.filter((v: unknown): v is string => typeof v === 'string' && v.length > 0))];
  if (unique.length > PRESENCE_BATCH_MAX) {
    return res.status(400).json({ error: `at most ${PRESENCE_BATCH_MAX} user_ids` });
  }
  if (!unique.length) return res.json({ presence: [] });
  // Concurrent rather than sequential: each entry is two or three cheap indexed reads, and
  // serialising 64 of them would make the batch route slower than the N calls it replaces.
  const presence = await Promise.all(unique.map((id) => presenceFor(viewerId, id)));
  res.json({ presence });
}));

// POST /users/consent — DPDP lawful consent capture at signup (Section 4.13).
router.post('/consent', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  await query(`update users set consent_given_at = now() where id = $1`, [user_id]);
  res.json({ consent_recorded: true });
});

// DELETE /users/me — account deletion (DPDP true purge, Section 4.13).
// Soft-delete immediately; the erasure worker performs the hard purge. Device trust is
// revoked now, because that is what stops the account being USED while it waits.
router.delete('/me', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  // photo_url and encrypted_photo_url are deliberately NOT nulled here.
  //
  // They are the only pointers to the avatar objects in R2, and backend/workers/src/erasure.ts
  // reads them to delete those objects. Clearing them at soft-delete time destroyed the
  // pointer before the worker could follow it, so the images survived in the bucket forever —
  // unreachable, unenumerable, and still personal data. That is the opposite of erasure.
  //
  // Not nulling them exposes nothing: every read path already filters on `deleted_at`, so the
  // row is not served to anyone. The worker nulls them once the objects are actually gone.
  await query(
    `update users set deleted_at = now(), full_name = null, email = null,
                      bio = null, status_text = null
      where id = $1`,
    [user_id]
  );
  await query(`update devices set revoked_at = now() where user_id = $1`, [user_id]);
  // The route's comment claimed prekeys were removed here; nothing removed them. An
  // unconsumed one-time prekey belonging to a deleted account is material a sender could
  // still be handed to open a session with an identity that no longer exists.
  await query(
    `delete from one_time_prekeys where device_id in (select id from devices where user_id = $1)`,
    [user_id]
  );
  await query(
    `delete from signed_prekeys where device_id in (select id from devices where user_id = $1)`,
    [user_id]
  );
  // Revoking devices does not revoke the TOKEN — it infers reachability from device state,
  // while the JWT names an identity and is good for up to 30 more days. requireAuth is what
  // actually enforces the deletion now; this just drops its cached verdict so the very next
  // request is rejected instead of the one after the cache TTL.
  await invalidateAccountState(user_id);
  // …and tell the WebSocket relay, which has no database and would otherwise keep honouring
  // this user's token for the life of the JWT on the service that carries the actual traffic.
  await revokeAccountSessions(user_id);
  res.json({ deleted: true, note: 'soft-deleted; hard purge runs via erasure job (DPDP)' });
});

export default router;
