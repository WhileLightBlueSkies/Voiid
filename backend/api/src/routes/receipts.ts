// Receipts are private metadata. Authorization and writes share one transaction.
import { Router } from 'express';
import { pool } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';
import { resolveActiveDevice, UUID_RE } from '../deviceAuthorization';

const router = Router();

router.post('/mark', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { message_ids, status = 'delivered' } = req.body ?? {};
  if (!Array.isArray(message_ids) || !message_ids.length || message_ids.length > 500) {
    return res.status(400).json({ error: 'message_ids must contain 1 to 500 uuids' });
  }
  if (!['delivered', 'read'].includes(status)) {
    return res.status(400).json({ error: "status must be 'delivered' or 'read'" });
  }
  if (!message_ids.every((id: unknown) => typeof id === 'string' && UUID_RE.test(id))) {
    return res.status(400).json({ error: 'message_ids must be uuids' });
  }
  const ids = [...new Set<string>(message_ids.map((id: string) => id.toLowerCase()))].sort();
  const client = await pool.connect();
  let notifications: { id: string; sender_id: string; status: string }[] = [];
  try {
    await client.query('begin');
    const deviceId = await resolveActiveDevice(
      req, user_id, client.query.bind(client), req.body?.device_id ?? req.query.device_id, true,
    );
    if (deviceId === undefined) {
      await client.query('rollback');
      return res.status(403).json({ error: 'forbidden' });
    }

    // Membership alone does not entitle a device to a fanout message. Its ciphertext
    // must actually be addressed to that device. Device-less clients retain legacy access.
    // Share locks serialize membership removal/device revocation with this receipt batch.
    const { rows: allowed } = await client.query<{ id: string; sender_id: string }>(
      `select m.id, m.sender_id from messages m
         join conversation_members cm on cm.conversation_id = m.conversation_id
        where m.id = any($1::uuid[]) and cm.user_id = $2 and cm.left_at is null
          and (m.ciphertext is not null or exists (
            select 1 from message_ciphertexts mc
             where mc.message_id = m.id and mc.recipient_device_id = $3::uuid
          ))
        order by m.id for share of m, cm`,
      [ids, user_id, deviceId],
    );
    if (allowed.length !== ids.length) {
      await client.query('rollback');
      return res.status(403).json({ error: 'forbidden' });
    }

    // 027 supplies separate partial unique indexes for real-device and NULL-device rows.
    const conflictTarget = deviceId
      ? '(message_id, user_id, device_id) where device_id is not null'
      : '(message_id, user_id) where device_id is null';
    const { rows: changed } = await client.query<{ message_id: string; status: string }>(
      `insert into message_read_receipts
         (message_id, user_id, device_id, status, delivered_at, read_at)
       select id, $2::uuid, $3::uuid, $4, now(), case when $4 = 'read' then now() end
         from unnest($1::uuid[]) as batch(id)
       on conflict ${conflictTarget} do update
         set status = excluded.status,
             delivered_at = coalesce(message_read_receipts.delivered_at, excluded.delivered_at),
             read_at = coalesce(message_read_receipts.read_at, excluded.read_at)
       where message_read_receipts.status is distinct from 'read'
       returning message_id, status`,
      [ids, user_id, deviceId, status],
    );
    const senders = new Map(allowed.map((m) => [m.id, m.sender_id]));
    notifications = changed
      .filter((r) => senders.get(r.message_id) !== user_id)
      .map((r) => ({ id: r.message_id, sender_id: senders.get(r.message_id)!, status: r.status }));
    // Do not clear messages.is_pending: it is shared by every recipient. Legacy fetch
    // excludes this caller's read receipts; durable device acknowledgements belong to M02.
    await client.query('commit');
  } catch (error) {
    await client.query('rollback');
    throw error;
  } finally {
    client.release();
  }

  for (const receipt of notifications) {
    try {
      await publisher.publish(`channel:user:${receipt.sender_id}`, JSON.stringify({
        type: 'receipt', message_id: receipt.id, by_user: user_id, status: receipt.status,
      }));
    } catch {
      // Database state is committed; history polling recovers the tick. A relay outage
      // must not turn successful persistence into an ambiguous HTTP failure.
      console.warn('[receipts] relay notification failed');
    }
  }
  res.json({ marked: ids.length, status });
}));

/**
 * POST /receipts/conversation/:id/read — mark EVERYTHING in a conversation read.
 *
 * WHY THIS EXISTS ALONGSIDE /mark
 * ===============================
 * /mark takes message ids, and the client can only name ids it actually holds. History is
 * fetched 50 at a time, so a conversation with 162 unread had its newest 50 marked and the
 * older 112 left unread FOREVER: nothing re-fetches them, so nothing can ever name them,
 * so the badge never cleared no matter how many times the chat was opened. One account in
 * production is sitting on exactly that.
 *
 * Opening a chat means "I have seen this conversation", not "I have seen these fifty
 * message ids". This expresses that directly, with no ceiling the caller has to know
 * about: the work is batched internally and repeats until nothing is left unread.
 *
 * Authorisation is the same rule as /mark — the caller must be a current member — and the
 * insert is the same idempotent upsert, so a message already marked read is untouched and
 * its read_at is preserved.
 */
router.post('/conversation/:id/read', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const conversationId = req.params.id;
  if (!UUID_RE.test(conversationId)) return res.status(403).json({ error: 'forbidden' });

  const readBefore = req.body?.read_before;
  // Disclosure has a separate lower bound: clearing unread counts while private
  // must not make those historical messages eligible when receipts are enabled again.
  const readAfter = req.body?.read_after;
  const disclose = req.body?.send_receipts !== false;
  if (readAfter !== undefined && (typeof readAfter !== 'string' || !Number.isFinite(Date.parse(readAfter)))) {
    return res.status(400).json({ error: 'invalid read_after' });
  }
  if (readBefore !== undefined && (typeof readBefore !== 'string' || !Number.isFinite(Date.parse(readBefore)))) {
    return res.status(400).json({ error: 'invalid read_before' });
  }
  const client = await pool.connect();
  try {
    await client.query('begin');
    const deviceId = await resolveActiveDevice(
      req, user_id, client.query.bind(client), req.body?.device_id ?? req.query.device_id, true,
    );
    if (deviceId === undefined) {
      await client.query('rollback');
      return res.status(403).json({ error: 'forbidden' });
    }
    const { rows: member } = await client.query(
      `select 1 from conversation_members
        where conversation_id = $1 and user_id = $2 and left_at is null for share`,
      [conversationId, user_id],
    );
    if (!member.length) {
      await client.query('rollback');
      return res.status(403).json({ error: 'forbidden' });
    }

    // Freeze the boundary once, including across client retries. New arrivals must
    // remain unread after the user leaves the conversation.
    const { rows: [position] } = await client.query<{ read_before: string }>(
      `update conversation_members set last_read_at = greatest(last_read_at,
          least(coalesce($3::timestamptz, now()), now()))
        where conversation_id = $1 and user_id = $2
        returning least(coalesce($3::timestamptz, now()), now())::text as read_before`,
      [conversationId, user_id, readBefore ?? null],
    );
    if (!disclose) {
      await client.query('commit');
      return res.json({ marked: 0, read_before: position.read_before });
    }

    const conflictTarget = deviceId
      ? '(message_id, user_id, device_id) where device_id is not null'
      : '(message_id, user_id) where device_id is null';
    // Only messages from OTHERS, and only ones not already read. Each pass is BOUNDED so a
    // single statement cannot lock the table across a very long history — but the passes
    // repeat HERE, server-side, until a pass changes nothing.
    //
    // The batching must not leak to the client. The whole reason this endpoint exists is
    // that a ceiling the caller has to know about is a ceiling that silently strands
    // messages: /mark's implicit 50-message limit is what left 112 of 162 unread forever.
    // Re-introducing a 2000-message version of the same bug, and relying on every client
    // to remember to loop, would be the same defect wearing a larger number.
    const BATCH = 2000;
    const MAX_PASSES = 50;          // 100k messages in one conversation; a runaway loop is worse
    const changed: { message_id: string; sender_id: string }[] = [];
    for (let pass = 0; pass < MAX_PASSES; pass++) {
      const { rows: batch } = await client.query<{ message_id: string; sender_id: string }>(
        `with due as (
           select m.id, m.sender_id from messages m
            where m.conversation_id = $1 and m.sender_id <> $2
              and m.created_at <= $5::timestamptz
              and ($6::timestamptz is null or m.created_at > $6::timestamptz)
              and not exists (
                select 1 from message_read_receipts r
                 where r.message_id = m.id and r.user_id = $2 and r.status = 'read')
            order by m.created_at desc limit $4
         ), ins as (
           insert into message_read_receipts
             (message_id, user_id, device_id, status, delivered_at, read_at)
           select id, $2::uuid, $3::uuid, 'read', now(), now() from due
           on conflict ${conflictTarget} do update
             set status = 'read',
                 delivered_at = coalesce(message_read_receipts.delivered_at, excluded.delivered_at),
                 read_at = coalesce(message_read_receipts.read_at, excluded.read_at)
           where message_read_receipts.status is distinct from 'read'
           returning message_id
         )
         select ins.message_id, due.sender_id from ins join due on due.id = ins.message_id`,
        [conversationId, user_id, deviceId, BATCH, position.read_before, readAfter ?? null],
      );
      changed.push(...batch);

      // Stop when nothing is left unread — asked directly, not inferred from the batch.
      //
      // `batch.length < BATCH` would also be correct TODAY, and I verified that against the
      // real schema rather than assuming it: a row enters `due` only when the user has no
      // 'read' receipt for it, and the upsert skips a row only when the conflict-target row
      // is already 'read' — which would have kept it out of `due`. So "matched but
      // unchanged" cannot currently happen, and the two counts agree.
      //
      // That agreement is a coincidence of two separate predicates, not an invariant anyone
      // declared. Narrow `due`, or change the conflict target, and a batch could match rows
      // it cannot change — an empty batch would then end the sweep with thousands still
      // unread, which is the exact failure this endpoint exists to prevent. One COUNT over
      // an indexed predicate, once per 2000 rows, is cheap insurance against silently
      // reintroducing it.
      const { rows: [{ remaining }] } = await client.query<{ remaining: string }>(
        `select count(*) as remaining from (
           select 1 from messages m
            where m.conversation_id = $1 and m.sender_id <> $2
              and m.created_at <= $4::timestamptz
              and ($5::timestamptz is null or m.created_at > $5::timestamptz)
              and not exists (
                select 1 from message_read_receipts r
                 where r.message_id = m.id and r.user_id = $2 and r.status = 'read')
            limit $3
         ) t`,
        [conversationId, user_id, BATCH, position.read_before, readAfter ?? null],
      );
      if (Number(remaining) === 0) break;
      if (pass === MAX_PASSES - 1) throw new Error('conversation read sweep limit reached');
    }
    await client.query('commit');

    // Use the existing message receipt protocol understood by all three clients.
    // Publishing exact changed IDs also avoids marking concurrently sent messages read.
    for (const receipt of changed) {
      try {
        await publisher.publish(`channel:user:${receipt.sender_id}`, JSON.stringify({
          type: 'receipt', message_id: receipt.message_id, by_user: user_id, status: 'read',
        }));
      } catch {
        console.warn('[receipts] conversation relay notification failed');
      }
    }
    res.json({ marked: changed.length, read_before: position.read_before });
  } catch (error) {
    await client.query('rollback').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}));

router.get('/:message_id', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  if (!UUID_RE.test(req.params.message_id)) return res.status(403).json({ error: 'forbidden' });
  const client = await pool.connect();
  try {
    await client.query('begin');
    const deviceId = await resolveActiveDevice(
      req, user_id, client.query.bind(client), req.query.device_id, true,
    );
    if (deviceId === undefined) {
      await client.query('rollback');
      return res.status(403).json({ error: 'forbidden' });
    }
    const { rows: allowed } = await client.query(
      `select m.id, m.sender_id from messages m
         join conversation_members cm on cm.conversation_id = m.conversation_id
        where m.id = any($1::uuid[]) and cm.user_id = $2 and cm.left_at is null
          and (m.sender_id = $2 or m.ciphertext is not null or exists (
            select 1 from message_ciphertexts mc
             where mc.message_id = m.id and mc.recipient_device_id = $3::uuid
          ))
        for share of m, cm`,
      [[req.params.message_id.toLowerCase()], user_id, deviceId],
    );
    if (!allowed.length) {
      await client.query('rollback');
      return res.status(403).json({ error: 'forbidden' });
    }
    const { rows } = await client.query(
      `select user_id, device_id, status, delivered_at, read_at
         from message_read_receipts where message_id = $1`,
      [req.params.message_id],
    );
    await client.query('commit');
    res.json({ receipts: rows });
  } catch (error) {
    await client.query('rollback');
    throw error;
  } finally {
    client.release();
  }
}));

export default router;
