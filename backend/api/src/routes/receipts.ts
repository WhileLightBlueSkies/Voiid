// Read-receipt routes (Section 4.8). Delivery/read state is metadata, not content.
// Marking a message read clears its 'is_pending' so it stops appearing in offline pending fetch.
import { Router } from 'express';
import { query } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';

const router = Router();

// POST /receipts/mark — { message_ids:[...], status:'delivered'|'read' }
// Records receipts for the caller and notifies senders over their Redis channel.
router.post('/mark', requireAuth, async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  const { message_ids, status = 'delivered' } = req.body ?? {};
  if (!Array.isArray(message_ids) || !message_ids.length) {
    return res.status(400).json({ error: 'message_ids array required' });
  }
  if (!['delivered', 'read'].includes(status)) {
    return res.status(400).json({ error: "status must be 'delivered' or 'read'" });
  }

  const tsCol = status === 'read' ? 'read_at' : 'delivered_at';
  for (const mid of message_ids) {
    await query(
      `insert into message_read_receipts (message_id, user_id, device_id, status, ${tsCol})
         values ($1, $2, $3, $4, now())
         on conflict (message_id, user_id, device_id)
         do update set status = excluded.status, ${tsCol} = now()
         -- NEVER downgrade: once 'read', a later out-of-order 'delivered' must not
         -- revert it (status only ever advances delivered → read).
         where message_read_receipts.status is distinct from 'read'`,
      [mid, user_id, device_id ?? null, status]
    );
  }

  // Once read, the message is no longer pending for this user's offline fetch.
  if (status === 'read') {
    await query(
      `update messages set is_pending = false, delivered_at = coalesce(delivered_at, now())
         where id = any($1::uuid[])`,
      [message_ids]
    );
  }

  // Notify each original sender so their UI can update ticks.
  const senders = await query<{ sender_id: string; id: string }>(
    `select id, sender_id from messages where id = any($1::uuid[]) and sender_id <> $2`,
    [message_ids, user_id]
  );
  for (const s of senders) {
    await publisher.publish(`channel:user:${s.sender_id}`, JSON.stringify({
      type: 'receipt', message_id: s.id, by_user: user_id, status,
    }));
  }

  res.json({ marked: message_ids.length, status });
});

// GET /receipts/:message_id — receipts for a message (sender checks who delivered/read).
router.get('/:message_id', requireAuth, async (req, res) => {
  const rows = await query(
    `select user_id, device_id, status, delivered_at, read_at
       from message_read_receipts where message_id = $1`,
    [req.params.message_id]
  );
  res.json({ receipts: rows });
});

export default router;
