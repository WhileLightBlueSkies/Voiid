// Conversation routes (Section 10). Direct (1:1) and group conversations.
// Server stores only metadata + membership; message content stays ciphertext (see messages.ts).
import { Router } from 'express';
import { pool, query } from '../db';
import { requireAuth } from '../auth';

const router = Router();

// POST /conversations/create
//   direct: { type:'direct', member_id }              -> idempotent (returns existing 1:1 if present)
//   group:  { type:'group', name, photo_url?, member_ids:[...] }
router.post('/create', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const { type = 'direct', member_id, name, photo_url, member_ids } = req.body ?? {};

  // ── Note to Self ─────────────────────────────────────────────────────────────────
  //
  // A private scratchpad: your own chat, with exactly one member — you. Used for notes,
  // links, and forwarding things to yourself, the way every major messenger now offers.
  //
  // Its own TYPE, not a 'direct' with a duplicate member row. The direct path identifies a
  // 1:1 by "exactly two active members", and a self-chat with two rows of the same user id
  // would satisfy that query and start colliding with real conversations. One member, one
  // type, no ambiguity.
  //
  // STILL E2E. Nothing here weakens that: notes are encrypted on-device to the author's
  // OTHER devices, exactly like any message, and the server stores ciphertext it cannot
  // read. With a single device there are no targets, which the client handles — see the
  // note-to-self path in ChatEngine.
  if (type === 'self') {
    // Idempotent. There is exactly one of these per user, ever.
    const existing = await query<{ id: string }>(
      `select c.id from conversations c
         join conversation_members m on m.conversation_id = c.id and m.user_id = $1 and m.left_at is null
        where c.type = 'self'
        limit 1`,
      [user_id]
    );
    if (existing[0]) return res.json({ conversation_id: existing[0].id, existed: true });

    const client = await pool.connect();
    try {
      await client.query('begin');
      const conv = (await client.query(
        `insert into conversations (type, created_by) values ('self', $1) returning id`,
        [user_id]
      )).rows[0];
      await client.query(
        `insert into conversation_members (conversation_id, user_id) values ($1,$2)`,
        [conv.id, user_id]
      );
      await client.query('commit');
      return res.json({ conversation_id: conv.id, existed: false });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  }

  if (type === 'direct') {
    if (!member_id) return res.status(400).json({ error: 'member_id required for direct' });
    // Self-chats have their own type above — this stays blocked so a 'direct' can never be
    // created with a duplicate member and start matching the two-member lookup.
    if (member_id === user_id) return res.status(400).json({ error: 'cannot create direct conversation with self' });

    // Idempotent: reuse an existing 1:1 between exactly these two users.
    const existing = await query<{ id: string }>(
      `select c.id from conversations c
         join conversation_members m1 on m1.conversation_id = c.id and m1.user_id = $1 and m1.left_at is null
         join conversation_members m2 on m2.conversation_id = c.id and m2.user_id = $2 and m2.left_at is null
        where c.type = 'direct'
          and (select count(*) from conversation_members m where m.conversation_id = c.id and m.left_at is null) = 2
        limit 1`,
      [user_id, member_id]
    );
    if (existing[0]) return res.json({ conversation_id: existing[0].id, existed: true });

    const client = await pool.connect();
    try {
      await client.query('begin');
      const conv = (await client.query(
        `insert into conversations (type, created_by) values ('direct', $1) returning id`,
        [user_id]
      )).rows[0];
      await client.query(
        `insert into conversation_members (conversation_id, user_id) values ($1,$2),($1,$3)`,
        [conv.id, user_id, member_id]
      );
      await client.query('commit');
      return res.json({ conversation_id: conv.id, existed: false });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  }

  if (type === 'group') {
    if (!name) return res.status(400).json({ error: 'name required for group' });
    const members: string[] = Array.from(new Set([user_id, ...((member_ids as string[]) ?? [])]));
    const client = await pool.connect();
    try {
      await client.query('begin');
      const conv = (await client.query(
        `insert into conversations (type, name, photo_url, created_by) values ('group', $1, $2, $3) returning id`,
        [name, photo_url ?? null, user_id]
      )).rows[0];
      // creator is admin; others are members
      for (const m of members) {
        await client.query(
          `insert into conversation_members (conversation_id, user_id, role) values ($1, $2, $3)`,
          [conv.id, m, m === user_id ? 'admin' : 'member']
        );
      }
      await client.query('commit');
      return res.json({ conversation_id: conv.id });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  }

  return res.status(400).json({ error: "type must be 'direct' or 'group'" });
});

// GET /conversations?device_id= — list the caller's active conversations with last-message
// preview (ciphertext) + unread count. The preview coalesces to THIS device's fan-out ciphertext
// (message_ciphertexts) so multi-device previews decrypt; legacy single-ciphertext rows fall
// through unchanged. device_id comes from the JWT claim or ?device_id= (matches prekeys.ts).
router.get('/', requireAuth, async (req, res) => {
  const { user_id, device_id: authDeviceId } = (req as any).auth;
  const deviceId = (typeof authDeviceId === 'string' && authDeviceId)
    ? authDeviceId
    : (typeof req.query.device_id === 'string' && req.query.device_id ? req.query.device_id : null);
  const rows = await query(
    `select c.id, c.type, c.name, c.photo_url, c.updated_at,
            lm.last_message_at,
            translate(encode(lm.ciphertext,'base64'), E'\n', '') as last_ciphertext,
            lm.content_type as last_content_type,
            coalesce(uc.unread, 0)::int as unread_count
       from conversations c
       join conversation_members me on me.conversation_id = c.id and me.user_id = $1 and me.left_at is null
            -- Pending and declined requests are NOT chats. They live in the Requests inbox
            -- (GET /reachability/pending) until accepted; without this filter a stranger's
            -- first message would appear in the main list, which is the entire thing the
            -- Accept/Decline gate exists to prevent.
            and me.request_state = 'accepted'
       left join lateral (
         select coalesce(mc.ciphertext, m.ciphertext) as ciphertext, m.content_type, m.created_at as last_message_at
           from messages m
           left join message_ciphertexts mc on mc.message_id = m.id and mc.recipient_device_id = $2::uuid
           where m.conversation_id = c.id
           order by m.created_at desc limit 1
       ) lm on true
       left join lateral (
         select count(*) as unread
           from messages m
           left join message_read_receipts r
             on r.message_id = m.id and r.user_id = $1 and r.status = 'read'
          where m.conversation_id = c.id and m.sender_id <> $1 and r.id is null
       ) uc on true
      order by coalesce(lm.last_message_at, c.updated_at) desc`,
    [user_id, deviceId]
  );
  res.json({ conversations: rows });
});

// GET /conversations/:id — detail + active members (caller must be a member).
router.get('/:id', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const isMember = await query(
    `select 1 from conversation_members where conversation_id = $1 and user_id = $2 and left_at is null`,
    [req.params.id, user_id]
  );
  if (!isMember[0]) return res.status(403).json({ error: 'not a member of this conversation' });

  const conv = (await query(
    `select id, type, name, photo_url, created_by, created_at from conversations where id = $1`,
    [req.params.id]
  ))[0];
  if (!conv) return res.status(404).json({ error: 'conversation not found' });

  const members = await query(
    `select cm.user_id, cm.role, cm.joined_at, u.full_name, u.photo_url
       from conversation_members cm
       join users u on u.id = cm.user_id
      where cm.conversation_id = $1 and cm.left_at is null`,
    [req.params.id]
  );
  res.json({ conversation: conv, members });
});

// POST /:id/members — add members to a group conversation (admin only). This
// updates the server-side membership used for message fan-out; the MLS Welcome/
// Commit that actually lets the new member decrypt is distributed separately by
// the client via /mls/group-events. Idempotent: re-adding an active member is a
// no-op; a previously-removed member (left_at set) is reinstated.
router.post('/:id/members', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const convId = req.params.id;
  const userIds: unknown = req.body?.user_ids;
  if (!Array.isArray(userIds) || userIds.length === 0 || !userIds.every((u) => typeof u === 'string')) {
    return res.status(400).json({ error: 'user_ids (non-empty string array) required' });
  }

  const conv = (await query<{ type: string }>(`select type from conversations where id = $1`, [convId]))[0];
  if (!conv) return res.status(404).json({ error: 'conversation not found' });
  if (conv.type !== 'group') return res.status(400).json({ error: 'can only add members to a group' });

  // Caller must be an active admin of this group.
  const caller = (await query<{ role: string }>(
    `select role from conversation_members where conversation_id = $1 and user_id = $2 and left_at is null`,
    [convId, user_id]
  ))[0];
  if (!caller) return res.status(403).json({ error: 'not a member of this conversation' });
  if (caller.role !== 'admin') return res.status(403).json({ error: 'only an admin can add members' });

  // Upsert each as an active member. `left_at` reset reinstates a prior member;
  // role left untouched on conflict so an existing admin stays an admin.
  for (const uid of userIds as string[]) {
    await query(
      `insert into conversation_members (conversation_id, user_id, role) values ($1, $2, 'member')
         on conflict (conversation_id, user_id) do update set left_at = null`,
      [convId, uid]
    );
  }
  res.json({ added: (userIds as string[]).length });
});

// DELETE /:id/members/:userId — remove a member from a group (admin removes
// anyone; a member may remove themselves to leave). Sets left_at so fan-out stops
// reaching them; the MLS rekey/Commit that cryptographically removes them is
// distributed separately by the client.
router.delete('/:id/members/:userId', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const convId = req.params.id;
  const target = req.params.userId;

  const caller = (await query<{ role: string }>(
    `select role from conversation_members where conversation_id = $1 and user_id = $2 and left_at is null`,
    [convId, user_id]
  ))[0];
  if (!caller) return res.status(403).json({ error: 'not a member of this conversation' });
  if (target !== user_id && caller.role !== 'admin') {
    return res.status(403).json({ error: 'only an admin can remove another member' });
  }

  await query(
    `update conversation_members set left_at = now()
       where conversation_id = $1 and user_id = $2 and left_at is null`,
    [convId, target]
  );
  res.json({ removed: true });
});

export default router;
