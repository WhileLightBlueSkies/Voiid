// Messaging relay (Section 10 realtime flow). Server stores CIPHERTEXT ONLY, then publishes to the
// recipient's Redis channel; the WS instance holding the socket pushes it down. Offline -> DB -> pending fetch.
import { Router } from 'express';
import { assertOpaque } from '@voiid/common-utils';
import { query } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';
import { b64, asyncHandler } from '../util';

const router = Router();

// POST /messages/send  { conversation_id, ciphertext(b64), content_type?, media_url?, media_mime? }
router.post('/send', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  const { conversation_id, ciphertext, content_type, media_url, media_mime } = req.body ?? {};
  if (!conversation_id || !ciphertext) {
    return res.status(400).json({ error: 'conversation_id and ciphertext required' });
  }
  // Golden rule (Section 4.14): the server only ever relays opaque ciphertext — reject plaintext-ish payloads.
  try { assertOpaque(req.body ?? {}); } catch (e) {
    return res.status(400).json({ error: (e as Error).message });
  }

  const rows = await query<{ id: string; created_at: string }>(
    `insert into messages (conversation_id, sender_id, sender_device_id, ciphertext, content_type, media_url, media_mime)
       values ($1, $2, $3, $4, coalesce($5,'text'), $6, $7)
       returning id, created_at`,
    [conversation_id, user_id, device_id ?? null, b64(ciphertext), content_type, media_url, media_mime]
  );
  const message = rows[0];

  // Route to each active member's user channel; WS instance with the live socket delivers it.
  const members = await query<{ user_id: string }>(
    `select user_id from conversation_members
       where conversation_id = $1 and left_at is null and user_id <> $2`,
    [conversation_id, user_id]
  );
  for (const m of members) {
    await publisher.publish(`channel:user:${m.user_id}`, JSON.stringify({
      type: 'message',
      message_id: message.id,
      conversation_id,
    }));
  }

  res.json({ message_id: message.id, created_at: message.created_at });
}));

// GET /messages/conversation/:id?before=&limit= — paginated history (ciphertext; client decrypts)
router.get('/conversation/:id', requireAuth, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 100);
  const before = req.query.before as string | undefined;
  const rows = await query(
    `select id, sender_id, encode(ciphertext,'base64') as ciphertext, content_type, media_url, media_mime, created_at
       from messages
       where conversation_id = $1 ${before ? 'and created_at < $3' : ''}
       order by created_at desc limit $2`,
    before ? [req.params.id, limit, before] : [req.params.id, limit]
  );
  res.json({ messages: rows });
});

// GET /messages/pending/:user_id — offline fetch on reconnect
router.get('/pending/:user_id', requireAuth, async (req, res) => {
  const rows = await query(
    `select m.id, m.conversation_id, m.sender_id,
            encode(m.ciphertext,'base64') as ciphertext, m.content_type, m.media_url, m.created_at
       from messages m
       join conversation_members cm on cm.conversation_id = m.conversation_id
       where cm.user_id = $1 and cm.left_at is null and m.is_pending = true
       order by m.created_at asc`,
    [req.params.user_id]
  );
  res.json({ messages: rows });
});

export default router;
