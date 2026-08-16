// User blocking — block, unblock, and list.
//
// The iOS Block button has been raising "Blocking isn't available yet" beneath a dialog
// that promises "They won't be able to message or call you." These are the routes that
// make the promise true; enforcement lives at each affected call site and shares one
// predicate module (src/blocking.ts).
//
// ── BLOCKING IS SILENT ────────────────────────────────────────────────────────────
// Nothing here notifies the blocked user, and nothing exposes "who blocked me". A blocked
// person should not be able to distinguish being blocked from the other person being
// offline, having deleted their account, or simply not replying. GET /blocks therefore
// returns only the caller's OWN outgoing blocks — there is deliberately no route that
// answers "has X blocked me", because that question is the whole thing we are hiding.
//
// ── BLOCKING DOES NOT DELETE ──────────────────────────────────────────────────────
// Blocking someone does not erase history, remove either party from shared groups, or
// cancel anything in flight. It changes what happens NEXT. Users who want the history gone
// have delete-for-me; conflating the two would make Block destructive and unrecoverable,
// and people press Block in a hurry.
import { Router } from 'express';
import { query } from '../db';
import { redis } from '../redis';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';

const router = Router();

/**
 * Mirror the block pair into Redis, for the websocket process.
 *
 * The WS server relays typing indicators and holds NO database connection by design (see
 * the `auth:revoked:` note in backend/websocket/src/index.ts, which solves the same problem
 * the same way). Postgres is the authority; this is a cache the WS layer can consult on a
 * hot path without growing a database dependency.
 *
 * SYMMETRIC KEYS, because enforcement is symmetric. Both `block:a:b` and `block:b:a` are
 * written, so the WS server can answer "may these two see each other" with a single GET
 * rather than two.
 *
 * No TTL: a block lasts until it is lifted. Best-effort — a Redis failure must never fail
 * the block itself, which is already committed to Postgres by the time we get here. The
 * cost of a lost mirror is a typing indicator leaking until the next write, which is a far
 * smaller harm than a Block button that errors.
 */
async function mirrorBlockToRedis(a: string, b: string, blocked: boolean): Promise<void> {
  try {
    if (blocked) {
      await redis.set(`block:${a}:${b}`, '1');
      await redis.set(`block:${b}:${a}`, '1');
    } else {
      await redis.del(`block:${a}:${b}`);
      await redis.del(`block:${b}:${a}`);
    }
  } catch {
    /* Postgres remains the authority; every API-side check reads it directly. */
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// POST /blocks — { user_id } — block someone.
//
// IDEMPOTENT. Pressing Block twice, or on two devices, must not 409: the caller's intent
// is "this person is blocked", and that is already true. `on conflict do nothing` keeps the
// original created_at, so the timestamp reflects when the block actually began.
router.post('/', requireAuth, asyncHandler(async (req, res) => {
  const blockerId = (req as any).auth.user_id;
  const targetId = req.body?.user_id;

  if (typeof targetId !== 'string' || !UUID_RE.test(targetId)) {
    return res.status(400).json({ error: 'user_id must be a uuid' });
  }
  // 039 has a check constraint for this, but a clear message beats a constraint violation.
  if (targetId === blockerId) {
    return res.status(400).json({ error: 'cannot block yourself' });
  }

  // Confirm the target exists and is not already erased. Without this, a typo'd uuid
  // silently "succeeds" and the user believes they blocked someone they did not.
  const exists = await query<{ one: number }>(
    `select 1 as one from users where id = $1 and deleted_at is null limit 1`,
    [targetId]
  );
  if (!exists.length) return res.status(404).json({ error: 'user not found' });

  await query(
    `insert into user_blocks (blocker_user_id, blocked_user_id)
       values ($1, $2)
       on conflict (blocker_user_id, blocked_user_id) do nothing`,
    [blockerId, targetId]
  );

  await mirrorBlockToRedis(blockerId, targetId, true);
  res.json({ blocked: true, user_id: targetId });
}));

// DELETE /blocks/:user_id — unblock.
//
// Also idempotent, and for the same reason: `blocked: false` is the caller's intent whether
// or not a row was there to remove. Reporting 404 for an already-unblocked user would make
// clients handle an error that means "you already got what you wanted".
router.delete('/:user_id', requireAuth, asyncHandler(async (req, res) => {
  const blockerId = (req as any).auth.user_id;
  const targetId = req.params.user_id;

  if (!UUID_RE.test(targetId)) {
    return res.status(400).json({ error: 'user_id must be a uuid' });
  }

  await query(
    `delete from user_blocks where blocker_user_id = $1 and blocked_user_id = $2`,
    [blockerId, targetId]
  );

  // Clear the mirror ONLY if no block survives in the other direction. A mutual block
  // where one side unblocks is still a block — dropping the cache key here would let
  // typing indicators flow again while Postgres still says these two cannot interact.
  const reverse = await query<{ one: number }>(
    `select 1 as one from user_blocks
      where blocker_user_id = $1 and blocked_user_id = $2 limit 1`,
    [targetId, blockerId]
  );
  if (!reverse.length) await mirrorBlockToRedis(blockerId, targetId, false);

  res.json({ blocked: false, user_id: targetId });
}));

// GET /blocks — the caller's blocked-users list, for the settings screen.
//
// OUTGOING ONLY. This never reveals who has blocked the caller; see the header note.
// Joins users for display, and skips erased accounts so the list does not show ghosts.
router.get('/', requireAuth, asyncHandler(async (req, res) => {
  const blockerId = (req as any).auth.user_id;
  const rows = await query(
    `select u.id, u.username, u.full_name, u.photo_url, b.created_at as blocked_at
       from user_blocks b
       join users u on u.id = b.blocked_user_id
      where b.blocker_user_id = $1 and u.deleted_at is null
      order by b.created_at desc`,
    [blockerId]
  );
  res.json({ blocked: rows });
}));

export default router;
