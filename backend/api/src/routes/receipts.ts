// Read-receipt routes (Section 4.8). Delivery/read state is metadata, not content.
// Marking a message read clears its 'is_pending' so it stops appearing in offline pending fetch.
import { Router } from 'express';
import { query } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';

const router = Router();

// POST /receipts/mark — { message_ids:[...], status:'delivered'|'read' }
// Records receipts for the caller and notifies senders over their Redis channel.
/**
 * The caller's device, from the token OR the request.
 *
 * IT IS ALMOST NEVER IN THE TOKEN. POST /auth/firebase issues `{ user_id }` with no device
 * claim — only device LINKING (routes/linking.ts) includes one — so on every normally
 * logged-in device `req.auth.device_id` is undefined. Reading it alone meant every receipt
 * was written against a NULL device, which is the NULL-upsert path 027 had to repair.
 *
 * Same shape as `callerDeviceId` in messages.ts and stories.ts, which already solved this.
 */
function callerDeviceId(req: any): string | null {
  const fromAuth = req.auth?.device_id;
  if (typeof fromAuth === 'string' && fromAuth) return fromAuth;
  const fromBody = req.body?.device_id;
  if (typeof fromBody === 'string' && fromBody) return fromBody;
  const fromQuery = req.query?.device_id;
  return typeof fromQuery === 'string' && fromQuery ? fromQuery : null;
}

router.post('/mark', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const device_id = callerDeviceId(req);
  const { message_ids, status = 'delivered' } = req.body ?? {};
  if (!Array.isArray(message_ids) || !message_ids.length) {
    return res.status(400).json({ error: 'message_ids array required' });
  }
  if (!['delivered', 'read'].includes(status)) {
    return res.status(400).json({ error: "status must be 'delivered' or 'read'" });
  }

  const tsCol = status === 'read' ? 'read_at' : 'delivered_at';

  // TWO conflict targets, chosen by whether we have a device id.
  //
  // `on conflict (message_id, user_id, device_id)` CANNOT match when device_id is null:
  // Postgres treats NULLs as distinct, so the row never collides and every mark inserted a
  // duplicate instead of updating — silently bypassing the never-downgrade guard below and
  // accumulating one row per call. 027 adds the matching partial indexes; this names them.
  const conflictTarget = device_id
    ? '(message_id, user_id, device_id) where device_id is not null'
    : '(message_id, user_id) where device_id is null';

  for (const mid of message_ids) {
    await query(
      `insert into message_read_receipts (message_id, user_id, device_id, status, ${tsCol})
         values ($1, $2, $3, $4, now())
         on conflict ${conflictTarget}
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
