// DPDP erasure worker — turns "deleted_at is set" into "the personal data is gone".
//
// ============================ READ THIS FIRST ======================================
// THIS IS THE JOB THAT `DELETE /users/me` HAS BEEN PROMISING SINCE DAY ONE. That route
// soft-deletes and answers "soft-deleted; hard purge runs via erasure job (DPDP)". The
// job did not exist, so `users.phone_number` and `users.username` were retained forever
// after someone asked to be erased. A phone number IS the identity in this system, so
// that was the largest single retention exposure in the codebase (Act s.8(7): erase when
// the purpose is no longer served).
//
// IT ALSO CLOSES A LOCKOUT. A security fix landed before this worker did: verify-otp now
// REJECTS a soft-deleted account (403 account_deleted) rather than silently resurrecting
// it, and requireAuth re-checks account state on every request and fails closed once the
// row is gone. That was correct — an OTP is not consent to undo an erasure — but with no
// purge running it meant a deleted number was locked out PERMANENTLY: the row survives,
// the unique index on phone_number never releases the number, and that person can never
// use Voiid again. This worker is what makes the lockout temporary. Deleting the row is
// simultaneously the privacy control and the thing that gives the number back.
// ===================================================================================
//
// ORDERING IS LOAD-BEARING. Two rules, both of which exist because of what a crash in the
// middle would leave behind:
//
//   1. R2 OBJECTS BEFORE THE ROWS THAT NAME THEM — the same rule admin.ts's clip purge
//      follows. The keys live only in the rows; delete the rows first and the objects are
//      orphaned with nothing left to enumerate them by, paid for forever.
//
//   2. PHONE-KEYED DELETES BEFORE THE users ROW. `otp_sessions` and `security_events`
//      hold the phone number as a plain column with no foreign key, so they are reachable
//      only via `users.phone_number`. Delete the user first and those rows become
//      unreachable personal data — the exact failure this worker exists to prevent.
//
// WHAT THIS DELETES BEYOND THE users ROW: almost everything is `on delete cascade` from
// users already (devices -> prekeys + message_ciphertexts + profile_keys, contact_sync,
// location_shares, stories, clips + comments + likes + views, conversation_members,
// consent_records, creator profile + follows, MLS key packages and welcomes). The
// explicit statements below are only for what the cascade CANNOT reach.
//
// WHAT IT CANNOT DELETE, stated plainly because a DPDP response has to be honest about it:
//   * Message ciphertext already delivered to other people's devices. That is their copy
//     of a conversation they were part of, and the server could not read it in any case.
//   * Media objects referenced only from inside an E2EE payload (`media/<uid>/<uuid>`):
//     the reference lives in ciphertext the server cannot open, so nothing here can
//     enumerate them. The bucket lifecycle rule is the only net, and that is a gap worth
//     writing down rather than pretending away.
//   * MLS group membership. Group state is cryptographic and lives in the clients; a
//     server-side row delete cannot remove a member from a group, only a client commit can.
//   * Copies on other users' devices, which are theirs.
//
// THE GRACE PERIOD IS AN ENGINEERING PLACEHOLDER (see ERASURE_GRACE_DAYS below).
import { pool, query } from './db';
import { deleteObject, r2Configured } from './r2';

// ── The retention policy, as constants, because that is the whole reason this process
//    exists rather than a pg_cron job: the period must be reviewable in a diff.
//
// [COUNSEL] 30 days is the number docs/research/11_admin_dpdp.md proposes and explicitly
// flags as unreviewed (§6.3). It is not legal advice and nothing here certifies
// compliance with anything. §2.10 raises the policy question this code cannot answer:
// inside the window, does a re-login CANCEL the erasure request or is the account already
// gone? This worker implements "already gone" — it re-reads `deleted_at` inside the
// deleting transaction, so any future audited reinstatement path only has to clear that
// column for the erasure to stop.
const ERASURE_GRACE_DAYS = 30;

/** Users per pass. Each one is several statements plus network I/O; bounded so one pass
 *  cannot hold a connection for minutes or stampede R2. */
const BATCH = 25;

/** Queued object deletes retried per pass. Bounded for the same reason. */
const OBJECT_RETRY_BATCH = 100;

/** Failed erasures before a user row is parked and reported on /health instead of
 *  re-failing at the head of the queue forever. Parked means SOMEBODY ASKED TO BE ERASED
 *  AND WAS NOT — it is a page-a-human state, not a quiet one. */
const MAX_ERASURE_ATTEMPTS = 5;

export interface ErasureResult {
  /** Users claimed for erasure this pass. */
  claimed: number;
  /** Users whose row is actually gone. */
  usersErased: number;
  /** R2 objects deleted this pass (including retries of previously queued keys). */
  objectsDeleted: number;
  /** R2 deletes that failed and were queued for retry. */
  objectsQueued: number;
  /** Keys still waiting in erasure_pending_objects after this pass. */
  objectsPending: number;
  /** Rows touched by the explicit (non-cascade) statements, per table: deletes, plus the
   *  counter repairs and IP redactions that have to travel with them. */
  rowsAffected: Record<string, number>;
  /** Users whose erasure threw this pass. */
  failed: number;
  /** Users parked past MAX_ERASURE_ATTEMPTS. Non-zero needs a human. */
  stuck: number;
}

/** R2 keys are only ever minted by the server with this prefix. `users.photo_url` is
 *  client-supplied through the profile update endpoint and may hold an absolute URL from
 *  an older client rather than an object key — handing that to DeleteObject would at best
 *  do nothing and at worst name a key we do not own, so it is filtered out here. */
function isOwnObjectKey(key: string | null): key is string {
  return typeof key === 'string' && key.startsWith('media/');
}

/** Delete one object, queueing the key for a later pass if the bucket refuses. Never
 *  throws: a broken bucket must not stop the row deletion that follows it. */
async function deleteObjectOrQueue(key: string, result: ErasureResult): Promise<void> {
  // No R2 configured is a normal dev state. Erasure must still purge the database —
  // retaining a phone number because a dev box has no bucket would be the wrong failure.
  if (!r2Configured()) return;
  try {
    await deleteObject(key);
    result.objectsDeleted++;
  } catch (e) {
    result.objectsQueued++;
    // ON CONFLICT so a key that fails on two boxes at once, or across passes, does not
    // raise on the primary key and abort the erasure it is attached to.
    await query(
      `insert into erasure_pending_objects (r2_key, attempts, last_attempt_at, last_error)
       values ($1, 1, now(), $2)
       on conflict (r2_key) do update
          set attempts = erasure_pending_objects.attempts + 1,
              last_attempt_at = now(),
              last_error = excluded.last_error`,
      [key, (e as Error).message.slice(0, 500)]
    ).catch(() => { /* the pass must not die because the retry queue is unwritable */ });
  }
}

/** Retry keys whose delete failed on an earlier pass. Runs first so a recovered bucket
 *  drains the backlog even when nothing new is due for erasure. */
async function retryPendingObjects(result: ErasureResult): Promise<void> {
  if (!r2Configured()) return;
  const pending = await query<{ r2_key: string }>(
    `select r2_key from erasure_pending_objects order by queued_at limit $1`,
    [OBJECT_RETRY_BATCH]
  );
  for (const row of pending) {
    try {
      await deleteObject(row.r2_key);
      result.objectsDeleted++;
      // The row exists only to chase the object; it dies with it.
      await query(`delete from erasure_pending_objects where r2_key = $1`, [row.r2_key]);
    } catch (e) {
      await query(
        `update erasure_pending_objects
            set attempts = attempts + 1, last_attempt_at = now(), last_error = $2
          where r2_key = $1`,
        [row.r2_key, (e as Error).message.slice(0, 500)]
      ).catch(() => {});
    }
  }
}

/**
 * One erasure pass.
 *
 * Claim -> commit -> slow network I/O -> a second short transaction for the deletes.
 * `for update skip locked` stops two workers claiming the same batch in one transaction;
 * committing before the R2 round-trips stops a slow bucket holding row locks on live
 * user rows. The residual race — two boxes claiming the same user in successive
 * transactions — is harmless: DeleteObject is idempotent, and the deleting transaction
 * re-checks `deleted_at ... for update`, so the loser finds no row and does nothing.
 */
export async function runErasure(): Promise<ErasureResult> {
  const startedAt = Date.now();
  const result: ErasureResult = {
    claimed: 0,
    usersErased: 0,
    objectsDeleted: 0,
    objectsQueued: 0,
    objectsPending: 0,
    rowsAffected: {},
    failed: 0,
    stuck: 0,
  };

  await retryPendingObjects(result);

  // ── Claim ────────────────────────────────────────────────────────────────────────
  const claimClient = await pool.connect();
  let batch: { id: string; phone_number: string }[];
  try {
    await claimClient.query('begin');
    const claimed = await claimClient.query<{ id: string; phone_number: string }>(
      `select id, phone_number from users
        where deleted_at is not null
          and deleted_at < now() - make_interval(days => $1)
          and erasure_attempts < $2
        order by deleted_at
        limit $3
        for update skip locked`,
      [ERASURE_GRACE_DAYS, MAX_ERASURE_ATTEMPTS, BATCH]
    );
    batch = claimed.rows;
    await claimClient.query('commit');
  } catch (e) {
    await claimClient.query('rollback').catch(() => {});
    throw e;
  } finally {
    claimClient.release();
  }
  result.claimed = batch.length;

  for (const user of batch) {
    try {
      await eraseUser(user.id, user.phone_number, result);
    } catch (e) {
      result.failed++;
      await query(`update users set erasure_attempts = erasure_attempts + 1 where id = $1`, [
        user.id,
      ]).catch(() => {});
      // No user id, no phone number in the log line: this process must not become the
      // place a deleted identity survives in a log file.
      console.error(`[workers] erasure failed for one user: ${(e as Error).message}`);
    }
  }

  // Parked rows are a standing alarm, so they are counted every pass and not only on the
  // pass that parked them.
  const stuck = await query<{ n: string }>(
    `select count(*)::text as n from users
      where deleted_at is not null
        and deleted_at < now() - make_interval(days => $1)
        and erasure_attempts >= $2`,
    [ERASURE_GRACE_DAYS, MAX_ERASURE_ATTEMPTS]
  );
  result.stuck = Number(stuck[0]?.n ?? 0);
  if (result.stuck) {
    console.error(
      `[workers] ${result.stuck} account(s) requested erasure and could NOT be erased after ` +
        `${MAX_ERASURE_ATTEMPTS} attempts — this needs a human, the data is still there`
    );
  }

  const pending = await query<{ n: string }>(
    `select count(*)::text as n from erasure_pending_objects`
  );
  result.objectsPending = Number(pending[0]?.n ?? 0);

  await recordPass(result, Date.now() - startedAt);
  return result;
}

/** Erase one account. Idempotent: every step is safe to repeat, and the transaction
 *  re-checks the claim so a reinstated account is never erased by a stale one. */
async function eraseUser(userId: string, phone: string, result: ErasureResult): Promise<void> {
  // ── 1. Objects first ───────────────────────────────────────────────────────────
  // One query rather than four round-trips, and `like 'media/%'` inside SQL so a stray
  // absolute URL in photo_url never reaches the bucket client.
  const keyRows = await query<{ key: string }>(
    `select key from (
        select r2_key as key from stories where author_id = $1
        union all
        select unnest(array[r2_key, thumb_r2_key, r2_key_sd, r2_key_hd, r2_key_fhd])
          from clips where author_id = $1
        union all
        select avatar_r2_key from creator_profiles where user_id = $1
        union all
        select unnest(array[photo_url, encrypted_photo_url]) from users where id = $1
     ) k
      where key is not null and key like 'media/%'`,
    [userId]
  );
  // De-duplicated: the same key can legitimately appear twice (photo_url never migrated
  // to encrypted_photo_url), and paying for two DeleteObject calls is pointless.
  for (const key of new Set(keyRows.map((r) => r.key).filter(isOwnObjectKey))) {
    await deleteObjectOrQueue(key, result);
  }

  // ── 2. Rows, in one transaction ────────────────────────────────────────────────
  const client = await pool.connect();
  try {
    await client.query('begin');

    // Re-check the claim under a row lock. A second worker that claimed the same user
    // finds nothing here and does nothing; a reinstated account (deleted_at cleared)
    // drops out of the erasure set at exactly this point, which is what makes
    // reinstatement implementable later as a single UPDATE.
    const live = await client.query<{ id: string }>(
      `select id from users
        where id = $1 and deleted_at is not null
          and deleted_at < now() - make_interval(days => $2)
        for update`,
      [userId, ERASURE_GRACE_DAYS]
    );
    if (!live.rows[0]) {
      await client.query('rollback');
      return;
    }

    const count = (table: string, n: number | null) => {
      if (n) result.rowsAffected[table] = (result.rowsAffected[table] ?? 0) + n;
    };

    // Denormalised counters on OTHER people's clips. clips.comment_count / like_count /
    // view_count are maintained by the route handlers, not by a trigger (022_clips.sql),
    // so the cascade about to remove this user's comments, likes and views would leave
    // every clip they ever touched permanently over-counted. Decrementing here — inside
    // the same transaction as the delete, so it can neither double-apply nor half-apply —
    // is the only place that drift can be prevented. Rows belonging to clips this user
    // authored are updated too and then cascade away; harmless.
    const commentFix = await client.query(
      `update clips c set comment_count = greatest(c.comment_count - x.n, 0)
         from (select clip_id, count(*)::int as n from clip_comments
                where author_id = $1 and deleted_at is null
                group by clip_id) x
        where c.id = x.clip_id`,
      [userId]
    );
    count('clips.comment_count_fixed', commentFix.rowCount);
    const likeFix = await client.query(
      `update clips c set like_count = greatest(c.like_count - x.n, 0)
         from (select clip_id, count(*)::int as n from clip_likes
                where user_id = $1 group by clip_id) x
        where c.id = x.clip_id`,
      [userId]
    );
    count('clips.like_count_fixed', likeFix.rowCount);
    const viewFix = await client.query(
      `update clips c set view_count = greatest(c.view_count - x.n, 0)
         from (select clip_id, count(*)::int as n from clip_views
                where user_id = $1 group by clip_id) x
        where c.id = x.clip_id`,
      [userId]
    );
    count('clips.view_count_fixed', viewFix.rowCount);

    // The PIN brute-force ledger keeps rows where this user was the SENDER on purpose
    // (020_reachability.sql: a deleted attacker account must not erase the evidence of
    // its attempts) and nulls sender_user_id via the cascade. What the cascade does not
    // touch is `sender_ip`, which is this user's IP address and would outlive them by
    // the whole 90-day sweep window. Keep the evidence row, drop the identifier — that
    // satisfies both the ledger's reason for existing and s.8(7).
    const pinIps = await client.query(
      `update contact_pin_attempts set sender_ip = null
        where sender_user_id = $1 and sender_ip is not null`,
      [userId]
    );
    count('contact_pin_attempts.sender_ip_nulled', pinIps.rowCount);

    // Phone-keyed tables. NO foreign key reaches these, so they are only findable while
    // users.phone_number still exists — hence before the delete, not after.
    const otp = await client.query(`delete from otp_sessions where phone_number = $1`, [phone]);
    count('otp_sessions', otp.rowCount);

    // Both predicates matter: post-auth rows carry user_id with a null phone, pre-auth
    // rows (failed logins, OTP abuse, and the account_deleted rejections this very user
    // generated every time they tried to log back in) carry the phone with a null user_id.
    const sec = await client.query(
      `delete from security_events where user_id = $1 or phone_number = $2`,
      [userId, phone]
    );
    count('security_events', sec.rowCount);

    // Visible collateral, logged rather than prevented: communities.owner_id cascades, so
    // erasing an owner destroys the community and every channel in it for everybody else.
    // That is the schema's deliberate choice (030_communities.sql) and erasure is not the
    // place to overrule it, but it must not happen silently — if this number is ever
    // non-zero, ownership transfer is the product gap it is pointing at.
    const owned = await client.query<{ n: string }>(
      `select count(*)::text as n from communities where owner_id = $1`,
      [userId]
    );
    const ownedCount = Number(owned.rows[0]?.n ?? 0);
    if (ownedCount) {
      console.warn(
        `[workers] erasure is deleting ${ownedCount} community/communities owned by the erased ` +
          'account, along with their channels and membership — no ownership-transfer path exists'
      );
      count('communities_destroyed', ownedCount);
    }

    // THE ROW. This is the statement that removes the phone number, releases the unique
    // index, and ends the login lockout the security fix created.
    const gone = await client.query(`delete from users where id = $1`, [userId]);
    if (gone.rowCount) {
      result.usersErased++;
      count('users', gone.rowCount);
    }

    await client.query('commit');
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

/** Evidence that the pass ran. COUNTS ONLY — no user id, no phone number, no object key
 *  (see 032_erasure.sql). Silent passes are not logged: a row per five minutes forever
 *  would bury the ones that mean something. */
async function recordPass(result: ErasureResult, durationMs: number): Promise<void> {
  if (!result.usersErased && !result.objectsDeleted && !result.objectsQueued) return;
  await query(
    `insert into erasure_log
        (grace_interval, users_erased, objects_deleted, objects_queued, deleted_counts, duration_ms)
     values (make_interval(days => $1), $2, $3, $4, $5::jsonb, $6)`,
    [
      ERASURE_GRACE_DAYS,
      result.usersErased,
      result.objectsDeleted,
      result.objectsQueued,
      JSON.stringify(result.rowsAffected),
      durationMs,
    ]
  ).catch((e) => {
    // Losing the evidence row must not undo the erasure — the deletion already committed
    // and re-running would be a no-op anyway.
    console.error(`[workers] erasure ran but could not be logged: ${(e as Error).message}`);
  });

  // Keep the declared policy honest about what is actually enforced. 030_dpdp.sql's
  // `users` row says the erasure worker owns that table; this writes back the grace
  // period the code is really using, so a console showing declared vs enforced surfaces
  // drift instead of hiding it.
  await query(
    `update data_retention_policy
        set enforced_interval = make_interval(days => $1),
            last_sweep_at = now(),
            last_sweep_deleted = $2
      where table_name = 'users'`,
    [ERASURE_GRACE_DAYS, result.usersErased]
  ).catch(() => {});
}
