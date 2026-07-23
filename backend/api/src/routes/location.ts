// Location sharing — SESSION lifecycle only (docs/LOCATION.md §9).
//
// ============================== THE RULE FOR THIS FILE ==============================
// NO COORDINATE MAY EVER REACH THE SERVER. Not in a request, not in a response, not in
// a log line. This router creates, lists, extends, revokes and ends *shares* — "user A
// is sharing with users B and C until 15:42" — and nothing else. Positions are
// encrypted on-device under a key minted by the client (`generateMasterSecret`), handed
// to the audience inside an ordinary E2EE control message, and streamed as opaque
// ciphertext over the WebSocket relay. They are never persisted anywhere on the server.
//
// There is DELIBERATELY no `POST /location/update` route. If one existed, someone would
// eventually put a coordinate in it. Fixes are WS-only, and the WS handler treats the
// payload as an opaque base64 string it copies and never parses.
//
// Every handler runs BOTH guards on the whole body before doing anything:
//   assertOpaque        — no plaintext message-body fields
//   assertNoCoordinates — no lat/lon/accuracy/geo/... field, at any nesting depth
// ====================================================================================
//
// Revocation is the other half of the job. A share must be stoppable server-side so an
// OFFLINE recipient still learns it ended: ending or revoking publishes a `loc_stop`
// routing signal to the target's Redis channel (same frame shape the WS relay emits, so
// clients need one handler) and deletes the target's buffered last fix, which is what
// stops a stopped share being resurrected from that buffer on reconnect.
//
// EXPIRY needs no worker. There is no scheduled job anywhere in this repo, so instead
// `expires_at` lives on the row and EVERY read path filters `expires_at > now() and
// ended_at is null`. An expired share is therefore invisible and unusable the moment it
// expires, whether or not anything ever cleans it up — and the clients hold `expiresAt`
// locally too, so a recipient hides the marker on time with zero network contact. Row
// removal is opportunistic housekeeping in GET /shares, not a correctness requirement.
import { Router } from 'express';
import { assertOpaque, assertNoCoordinates } from '@voiid/common-utils';
import { query } from '../db';
import { publisher, redis } from '../redis';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Conversation live shares are one of three fixed durations — 15 min / 1 h / 8 h. A
// free-form number would be an indefinite share with extra steps.
const CONVERSATION_DURATIONS = [900, 3600, 28800];
// Map presence has no picker, but a hard 24h ceiling: visibility is never something you
// forget about for a week. The client re-arms it while the app is used.
const MAP_MAX_DURATION = 86400;
// Map audience cap. A per-contact allow-list that needs 200 entries isn't an allow-list.
const MAP_MAX_TARGETS = 200;
// Conversation shares fan out to the members of one conversation; the cap only exists
// so a malformed client can't ask us to write an unbounded target set.
const CONVERSATION_MAX_TARGETS = 512;

// Mirrors backend/websocket's `loc:last:<user>` buffer key. Ending or revoking a share
// must reach into that buffer, or a recipient reconnecting inside the TTL would be
// handed the final fix of a share that has already been stopped.
const lastFixKey = (userId: string) => `loc:last:${userId}`;

interface ShareRow {
  id: string;
  owner_user_id: string;
  kind: string;
  conversation_id: string | null;
  started_at: string;
  expires_at: string;
  ended_at: string | null;
}

/**
 * Tell a set of recipients that a share is over, on every channel that can carry it.
 *
 * Best-effort by construction: Redis pub/sub reaches only live sockets, and the durable
 * `live_stop`/`map_off` control MESSAGE (sent by the client over the normal E2EE message
 * path) is what reaches an offline recipient. The real guarantee is neither of these —
 * it is `expires_at`, which both sides already hold. This is the fast path on top.
 *
 * Deleting the buffered last fix is the part that MUST happen: without it a recipient
 * who reconnects within LOC_BUFFER_TTL gets replayed the final position of a share the
 * sharer has already stopped.
 */
async function signalStop(shareId: string, ownerUserId: string, targetUserIds: string[]): Promise<void> {
  const frame = JSON.stringify({
    type: 'loc_stop',
    share_id: shareId,
    from_user_id: ownerUserId,
    ts: Date.now(),
  });
  await Promise.all(
    targetUserIds.map(async (uid) => {
      try {
        await redis.hdel(lastFixKey(uid), shareId);
        await publisher.publish(`channel:user:${uid}`, frame);
      } catch {
        // A Redis hiccup must not fail the HTTP call: the row is already ended, so the
        // recipient still stops at expiry (and on the durable control message).
      }
    })
  );
}

/** End one share and notify its (non-revoked) audience. Idempotent. */
async function endShare(share: ShareRow): Promise<void> {
  await query(
    `update location_shares set ended_at = coalesce(ended_at, now()) where id = $1`,
    [share.id]
  );
  const targets = await query<{ target_user_id: string }>(
    `select target_user_id from location_share_targets
       where share_id = $1 and revoked_at is null`,
    [share.id]
  );
  await signalStop(share.id, share.owner_user_id, targets.map((t) => t.target_user_id));
}

/** Load a share the caller OWNS and that is still active. 404/403 otherwise. */
async function loadOwnedActiveShare(shareId: string, userId: string): Promise<
  { ok: true; share: ShareRow } | { ok: false; status: number; error: string }
> {
  if (!UUID_RE.test(shareId)) return { ok: false, status: 400, error: 'invalid share id' };
  const rows = await query<ShareRow>(
    `select id, owner_user_id, kind, conversation_id, started_at, expires_at, ended_at
       from location_shares where id = $1`,
    [shareId]
  );
  const share = rows[0];
  if (!share) return { ok: false, status: 404, error: 'share not found' };
  if (share.owner_user_id !== userId) return { ok: false, status: 403, error: 'not your share' };
  // Already ended or expired: not an error worth failing a client over (a duplicate
  // stop is the normal shape of "stop" being retried), but nothing left to do either.
  if (share.ended_at || new Date(share.expires_at).getTime() <= Date.now()) {
    return { ok: false, status: 409, error: 'share is not active' };
  }
  return { ok: true, share };
}

/**
 * Both guards, on the whole body, before any handler logic. Returns an error string to
 * send as 400, or null when the body is clean.
 */
function rejectNonOpaqueBody(body: unknown): string | null {
  try {
    assertOpaque((body ?? {}) as Record<string, unknown>);
    assertNoCoordinates(body ?? {});
    return null;
  } catch (e) {
    return (e as Error).message;
  }
}

// POST /location/shares
//   { kind: 'conversation'|'map', conversation_id?, target_user_ids: [...], duration_seconds }
//   -> 201 { share_id, expires_at }
//
// THE SHARE KEY APPEARS IN NEITHER THE REQUEST NOR THE RESPONSE. Key distribution is
// entirely client-side, inside an E2EE control message — which is also where the real
// authorization lives, since only a device holding a live ratchet/MLS session can get it.
router.post('/shares', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const bad = rejectNonOpaqueBody(req.body);
  if (bad) return res.status(400).json({ error: bad });

  const { kind, conversation_id, target_user_ids, duration_seconds } = req.body ?? {};

  if (kind !== 'conversation' && kind !== 'map') {
    return res.status(400).json({ error: "kind must be 'conversation' or 'map'" });
  }
  if (typeof duration_seconds !== 'number' || !Number.isFinite(duration_seconds)) {
    return res.status(400).json({ error: 'duration_seconds must be a number' });
  }
  if (kind === 'conversation' && !CONVERSATION_DURATIONS.includes(duration_seconds)) {
    return res.status(400).json({
      error: `duration_seconds must be one of ${CONVERSATION_DURATIONS.join(', ')}`,
    });
  }
  if (kind === 'map' && (!Number.isInteger(duration_seconds) || duration_seconds < 60 || duration_seconds > MAP_MAX_DURATION)) {
    return res.status(400).json({ error: `duration_seconds must be 60..${MAP_MAX_DURATION}` });
  }
  if (!Array.isArray(target_user_ids) || target_user_ids.length === 0) {
    return res.status(400).json({ error: 'target_user_ids must be a non-empty array' });
  }

  // Dedupe and drop self: sharing with yourself is a no-op that would otherwise create a
  // target row whose only effect is an extra publish back to the sharer.
  const targets: string[] = [];
  for (const t of target_user_ids) {
    if (typeof t !== 'string' || !UUID_RE.test(t)) {
      return res.status(400).json({ error: 'target_user_ids must be uuids' });
    }
    if (t !== user_id && !targets.includes(t)) targets.push(t);
  }
  if (!targets.length) return res.status(400).json({ error: 'target_user_ids must name someone other than you' });

  const maxTargets = kind === 'map' ? MAP_MAX_TARGETS : CONVERSATION_MAX_TARGETS;
  if (targets.length > maxTargets) {
    return res.status(400).json({ error: `at most ${maxTargets} targets for kind '${kind}'` });
  }

  let convId: string | null = null;
  if (kind === 'conversation') {
    if (typeof conversation_id !== 'string' || !UUID_RE.test(conversation_id)) {
      return res.status(400).json({ error: 'conversation_id must be a uuid' });
    }
    convId = conversation_id;

    // Authorization: the caller must be an ACTIVE member, and so must every target.
    // This is the only place membership can be checked at all — the WS relay that
    // carries the fixes has no database (docs/LOCATION.md §9, "stated gap").
    const me = await query<{ one: number }>(
      `select 1 as one from conversation_members
         where conversation_id = $1 and user_id = $2 and left_at is null`,
      [convId, user_id]
    );
    if (!me[0]) return res.status(403).json({ error: 'not a member of this conversation' });

    const members = await query<{ user_id: string }>(
      `select user_id from conversation_members
         where conversation_id = $1 and left_at is null and user_id = any($2::uuid[])`,
      [convId, targets]
    );
    const active = new Set(members.map((m) => m.user_id));
    if (targets.some((t) => !active.has(t))) {
      return res.status(403).json({ error: 'every target must be an active member of this conversation' });
    }
  } else if (conversation_id != null) {
    return res.status(400).json({ error: "kind 'map' must not carry a conversation_id" });
  }

  // One emitting share per (owner, kind, conversation). v1 has a single emitting device,
  // so starting a new share supersedes the old one — and the old audience is told, rather
  // than being left watching a marker that will never move again until its timer runs out.
  // `is not distinct from` so the map case (conversation_id null) matches correctly.
  const superseded = await query<ShareRow>(
    `select id, owner_user_id, kind, conversation_id, started_at, expires_at, ended_at
       from location_shares
      where owner_user_id = $1 and kind = $2 and conversation_id is not distinct from $3::uuid
        and ended_at is null and expires_at > now()`,
    [user_id, kind, convId]
  );
  for (const prior of superseded) await endShare(prior);

  const inserted = await query<{ id: string; expires_at: string }>(
    `insert into location_shares (owner_user_id, kind, conversation_id, expires_at)
       values ($1, $2, $3, now() + make_interval(secs => $4))
       returning id, expires_at`,
    [user_id, kind, convId, duration_seconds]
  );
  const share = inserted[0];

  // Single statement rather than a loop: the target set is bounded and this keeps share
  // creation to two round-trips even for a 200-person map audience.
  await query(
    `insert into location_share_targets (share_id, target_user_id)
       select $1::uuid, unnest($2::uuid[])
       on conflict (share_id, target_user_id) do nothing`,
    [share.id, targets]
  );

  return res.status(201).json({
    share_id: share.id,
    kind,
    conversation_id: convId,
    expires_at: share.expires_at,
    target_count: targets.length,
  });
}));

// GET /location/shares -> { outbound: [...], inbound: [...] }
// Active, unexpired, unrevoked only. This is how a reinstalled or relinked device
// discovers "you still have a share running" instead of broadcasting silently forever.
router.get('/shares', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;

  const outbound = await query<ShareRow & { targets: string[] | null }>(
    `select s.id, s.owner_user_id, s.kind, s.conversation_id, s.started_at, s.expires_at, s.ended_at,
            coalesce(array_agg(t.target_user_id) filter (where t.revoked_at is null), '{}'::uuid[]) as targets
       from location_shares s
       left join location_share_targets t on t.share_id = s.id
      where s.owner_user_id = $1 and s.ended_at is null and s.expires_at > now()
      group by s.id
      order by s.started_at desc`,
    [user_id]
  );

  const inbound = await query<ShareRow>(
    `select s.id, s.owner_user_id, s.kind, s.conversation_id, s.started_at, s.expires_at, s.ended_at
       from location_shares s
       join location_share_targets t on t.share_id = s.id
      where t.target_user_id = $1 and t.revoked_at is null
        and s.ended_at is null and s.expires_at > now()
      order by s.started_at desc`,
    [user_id]
  );

  // Opportunistic housekeeping. There is no worker process in this repo and this feature
  // creates zero R2 objects, so there is nothing to reap but small, long-dead rows — and
  // correctness never depended on them being gone (every read filters on expires_at).
  // Fire-and-forget so a slow delete can't add latency to the client's poll.
  void query(
    `delete from location_shares where expires_at < now() - interval '7 days'`
  ).catch(() => { /* housekeeping is never worth failing a request over */ });

  return res.json({
    outbound: outbound.map((s) => ({
      share_id: s.id,
      kind: s.kind,
      conversation_id: s.conversation_id,
      started_at: s.started_at,
      expires_at: s.expires_at,
      target_user_ids: s.targets ?? [],
    })),
    inbound: inbound.map((s) => ({
      share_id: s.id,
      kind: s.kind,
      conversation_id: s.conversation_id,
      owner_user_id: s.owner_user_id,
      started_at: s.started_at,
      expires_at: s.expires_at,
    })),
  });
}));

// POST /location/shares/:id/extend  { duration_seconds } -> { expires_at }
// Owner only. Extends from NOW, not from the old expiry, so "1 more hour" means an hour.
router.post('/shares/:id/extend', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const bad = rejectNonOpaqueBody(req.body);
  if (bad) return res.status(400).json({ error: bad });

  const loaded = await loadOwnedActiveShare(req.params.id, user_id);
  if (!loaded.ok) return res.status(loaded.status).json({ error: loaded.error });

  const { duration_seconds } = req.body ?? {};
  if (typeof duration_seconds !== 'number' || !Number.isFinite(duration_seconds)) {
    return res.status(400).json({ error: 'duration_seconds must be a number' });
  }
  if (loaded.share.kind === 'conversation' && !CONVERSATION_DURATIONS.includes(duration_seconds)) {
    return res.status(400).json({
      error: `duration_seconds must be one of ${CONVERSATION_DURATIONS.join(', ')}`,
    });
  }
  if (loaded.share.kind === 'map' && (!Number.isInteger(duration_seconds) || duration_seconds < 60 || duration_seconds > MAP_MAX_DURATION)) {
    return res.status(400).json({ error: `duration_seconds must be 60..${MAP_MAX_DURATION}` });
  }

  const rows = await query<{ expires_at: string }>(
    `update location_shares set expires_at = now() + make_interval(secs => $2)
       where id = $1 returning expires_at`,
    [loaded.share.id, duration_seconds]
  );
  return res.json({ share_id: loaded.share.id, expires_at: rows[0].expires_at });
}));

// DELETE /location/shares/:id -> { ended: true }
// Owner only. The server-side half of "stop sharing": marks the row ended (so a device
// that reconnects later can't resume it), tells every live recipient, and clears the
// buffered last fix so the share cannot be resurrected from it.
router.delete('/shares/:id', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const bad = rejectNonOpaqueBody(req.body);
  if (bad) return res.status(400).json({ error: bad });

  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'invalid share id' });
  const rows = await query<ShareRow>(
    `select id, owner_user_id, kind, conversation_id, started_at, expires_at, ended_at
       from location_shares where id = $1`,
    [req.params.id]
  );
  const share = rows[0];
  if (!share) return res.status(404).json({ error: 'share not found' });
  if (share.owner_user_id !== user_id) return res.status(403).json({ error: 'not your share' });

  // Deliberately NOT gated on "still active": stopping an already-stopped share is the
  // normal shape of a retry, and re-publishing the stop is harmless and idempotent.
  await endShare(share);
  return res.json({ share_id: share.id, ended: true });
}));

// DELETE /location/shares/:id/targets/:user_id — revoke ONE recipient.
// The client follows this with a `live_stop` to that recipient and a `live_rekey` to
// everyone else, minting a fresh share key; after the rekey the removed recipient's old
// key decrypts nothing further. Revocation stops FUTURE fixes — it cannot un-see a past
// one, and no UI wording may imply otherwise.
router.delete('/shares/:id/targets/:user_id', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const bad = rejectNonOpaqueBody(req.body);
  if (bad) return res.status(400).json({ error: bad });

  const targetId = req.params.user_id;
  if (!UUID_RE.test(targetId)) return res.status(400).json({ error: 'invalid target user id' });

  const loaded = await loadOwnedActiveShare(req.params.id, user_id);
  if (!loaded.ok) return res.status(loaded.status).json({ error: loaded.error });

  const revoked = await query<{ target_user_id: string }>(
    `update location_share_targets set revoked_at = coalesce(revoked_at, now())
       where share_id = $1 and target_user_id = $2
       returning target_user_id`,
    [loaded.share.id, targetId]
  );
  if (!revoked[0]) return res.status(404).json({ error: 'target is not on this share' });

  await signalStop(loaded.share.id, loaded.share.owner_user_id, [targetId]);
  return res.json({ share_id: loaded.share.id, revoked_user_id: targetId });
}));

// POST /location/shares/:id/leave — a RECIPIENT stops seeing this share.
// Symmetric to revoke, from the other side: a viewer can stop receiving someone's
// location without having to ask them to stop sharing. The stop signal goes to the
// LEAVER's own channel (stamped with the owner as `from_user_id`, so the client's single
// loc_stop handler reads it identically) so their other devices drop the share too.
router.post('/shares/:id/leave', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const bad = rejectNonOpaqueBody(req.body);
  if (bad) return res.status(400).json({ error: bad });

  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'invalid share id' });

  const rows = await query<{ owner_user_id: string }>(
    `update location_share_targets t set revoked_at = coalesce(t.revoked_at, now())
       from location_shares s
      where t.share_id = s.id and t.share_id = $1 and t.target_user_id = $2
      returning s.owner_user_id`,
    [req.params.id, user_id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'you are not a target of this share' });

  await signalStop(req.params.id, rows[0].owner_user_id, [user_id]);
  return res.json({ share_id: req.params.id, left: true });
}));

export default router;
