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
 * message ids". This expresses that directly, in one statement, with no ceiling.
 *
 * Authorisation is the same rule as /mark — the caller must be a current member — and the
 * insert is the same idempotent upsert, so a message already marked read is untouched and
 * its read_at is preserved.
 */
router.post('/conversation/:id/read', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const conversationId = req.params.id;
  if (!UUID_RE.test(conversationId)) return res.status(403).json({ error: 'forbidden' });

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

    const conflictTarget = deviceId
      ? '(message_id, user_id, device_id) where device_id is not null'
      : '(message_id, user_id) where device_id is null';
    // Only messages from OTHERS, and only ones not already read. Bounded so a single call
    // cannot lock the table on a very long history; the client repeats until nothing is
    // returned, which is also what makes it safe to retry.
    const { rows: changed } = await client.query<{ message_id: string; sender_id: string }>(
      `with due as (
         select m.id, m.sender_id from messages m
          where m.conversation_id = $1 and m.sender_id <> $2
            and not exists (
              select 1 from message_read_receipts r
               where r.message_id = m.id and r.user_id = $2 and r.status = 'read')
          order by m.created_at desc limit 2000
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
      [conversationId, user_id, deviceId],
    );
    await client.query('commit');

    // Tell each sender their message was read. Deduped by sender: a hundred messages from
    // one person is one fact about that conversation, not a hundred relay publishes.
    for (const senderId of new Set(changed.map((r) => r.sender_id))) {
      try {
        await publisher.publish(`channel:user:${senderId}`, JSON.stringify({
          type: 'receipt', conversation_id: conversationId, by_user: user_id, status: 'read',
        }));
      } catch {
        console.warn('[receipts] conversation relay notification failed');
      }
    }
    res.json({ marked: changed.length });
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
