// Story reaper — deletes expired story ciphertext from R2 and expired rows from Postgres.
//
// ============================ READ THIS FIRST ======================================
// THE REAPER IS NOT WHAT MAKES A STORY EXPIRE. Every server read path in
// backend/api/src/routes/stories.ts filters `expires_at > now()`, and every client
// read path does the same locally. A story is invisible the instant it expires even if
// this process has been dead for a week. What the reaper does is CLEAN UP: it removes
// the ciphertext from R2 and the rows from the DB so expired content stops existing at
// rest. Never make visibility depend on it.
// ===================================================================================
//
// THE 1-HOUR GRACE: a client that started a download at T+23:59 must not 404 mid-fetch,
// so rows are only reaped an hour after they expire. The bucket lifecycle rule on prefix
// `media/stories/` (48h) is set WIDER than that on purpose — the reaper, not a console
// setting, is the primary mechanism; the rule only catches orphans.
//
// ROWS AND OBJECTS EXPIRE INDEPENDENTLY, so both clients must tolerate:
//   * object gone, row present -> "This story is no longer available"
//   * row gone, object present -> harmless ciphertext garbage, swept by the lifecycle rule
import { pool, query } from './db';
import { deleteObject, r2Configured } from './r2';

/** Rows per pass. Bounded so one pass cannot hold a connection for minutes. */
const BATCH = 200;
/** Grace after expires_at before anything is deleted. */
const GRACE = "interval '1 hour'";
/** Failed R2 deletes before we drop the row anyway and let the lifecycle rule finish. */
const MAX_REAP_ATTEMPTS = 5;

export interface ReapResult {
  claimed: number;
  objectsDeleted: number;
  rowsDeleted: number;
  failed: number;
  abandoned: number;
  /** Object keys we could not delete and have written down instead (C04). Counted here so
   *  health can report a growing backlog rather than a silent one. */
  objectsQueued: number;
}

/**
 * One reaping pass.
 *
 * Claim -> commit -> then do the slow network I/O. `for update skip locked` means two
 * worker instances never claim the same batch inside the same transaction; committing
 * BEFORE the R2 round-trips means a slow bucket cannot hold row locks (and therefore
 * cannot block a concurrent DELETE /stories/:id from the author). The residual race —
 * two instances claiming the same row in successive transactions — is harmless: both
 * DeleteObject and `delete from stories where id = $1` are idempotent.
 */

/**
 * Remember an object we did not delete (C04).
 *
 * Reuses `erasure_pending_objects` rather than inventing a second queue: it is already the
 * table for "an object that still needs deleting", it is already drained by the erasure pass,
 * and it is already reported on /health. Two queues would mean two drains and two things to
 * forget about.
 *
 * Never throws — a pass must not die because the retry queue is unwritable — and never logs
 * the key, which names a user's media.
 */
async function queueObject(key: string | null, why: string, result: ReapResult): Promise<void> {
  // An empty or missing key is not a file to chase. Stories predating object storage have one.
  if (!key) return;
  await query(
    `insert into erasure_pending_objects (r2_key, attempts, last_attempt_at, last_error)
     values ($1, 1, now(), $2)
     on conflict (r2_key) do update
        set attempts = erasure_pending_objects.attempts + 1,
            last_attempt_at = now(),
            last_error = excluded.last_error`,
    [key, why.slice(0, 500)]
  ).then(() => { result.objectsQueued++; })
   .catch(() => { /* the pass must not die because the retry queue is unwritable */ });
}

export async function reapStories(): Promise<ReapResult> {
  const result: ReapResult = { claimed: 0, objectsDeleted: 0, rowsDeleted: 0, failed: 0, abandoned: 0, objectsQueued: 0 };

  const client = await pool.connect();
  let batch: { id: string; r2_key: string }[];
  try {
    await client.query('begin');
    const claimed = await client.query<{ id: string; r2_key: string }>(
      `select id, r2_key from stories
        where expires_at < now() - ${GRACE}
          and reap_attempts < $1
        order by expires_at
        limit $2
        for update skip locked`,
      [MAX_REAP_ATTEMPTS, BATCH]
    );
    batch = claimed.rows;
    await client.query('commit');
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    client.release();
  }

  result.claimed = batch.length;

  for (const row of batch) {
    try {
      // No R2 configured (a normal dev state) => skip the object and still drop the
      // row. Leaving rows forever because a dev box has no bucket would be worse.
      //
      // BUT THE KEY IS KEPT (C04). The story row is the only thing that knows this object's
      // key, so dropping the row without recording it leaves a file in the bucket that
      // nothing in the system can name any more. That was justified by a lifecycle rule the
      // audit could not verify — and an unverified lifecycle rule is not evidence of deletion.
      if (r2Configured()) {
        await deleteObject(row.r2_key);
        result.objectsDeleted++;
      } else {
        await queueObject(row.r2_key, 'storage not configured', result);
      }
      // Cascades story_keys + story_receipts.
      await query(`delete from stories where id = $1`, [row.id]);
      result.rowsDeleted++;
    } catch (e) {
      result.failed++;
      // Backoff counter, NOT a retry loop: a permanently broken key must not be
      // re-attempted forever at the head of the queue.
      await query(`update stories set reap_attempts = reap_attempts + 1 where id = $1`, [row.id]).catch(
        () => {}
      );
      console.warn(`[workers] reap failed for story ${row.id}: ${(e as Error).message}`);
    }
  }

  // Second pass: rows that have failed MAX_REAP_ATTEMPTS times are deleted anyway. The
  // bucket lifecycle rule reaps their objects. A single stuck row must NEVER block the
  // whole queue — otherwise one unreachable key freezes expiry for every user.
  //
  // THE KEYS ARE RETURNED TOO, and queued before the rows are gone (C04). This used to
  // `returning id` and point at a bucket lifecycle rule for the objects — a rule this audit
  // could not verify, which makes it a hope rather than a mechanism. The key now moves into
  // the same durable queue erasure uses, so a restored bucket drains it and a persistent
  // outage leaves a visible backlog instead of silence.
  const abandoned = await query<{ id: string; r2_key: string }>(
    `delete from stories
      where expires_at < now() - ${GRACE}
        and reap_attempts >= $1
      returning id, r2_key`,
    [MAX_REAP_ATTEMPTS]
  );
  result.abandoned = abandoned.length;
  for (const row of abandoned) {
    await queueObject(row.r2_key, `abandoned after ${MAX_REAP_ATTEMPTS} failed deletes`, result);
  }
  if (result.abandoned) {
    console.warn(
      `[workers] abandoned ${result.abandoned} story row(s) after ${MAX_REAP_ATTEMPTS} failed R2 deletes; ` +
        `${result.objectsQueued} object key(s) queued for a later pass`
    );
  }

  return result;
}
