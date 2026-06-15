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

  if (type === 'direct') {
    if (!member_id) return res.status(400).json({ error: 'member_id required for direct' });
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

// GET /conversations — list the caller's active conversations with last-message preview (ciphertext) + unread count.
router.get('/', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query(
    `select c.id, c.type, c.name, c.photo_url, c.updated_at,
            lm.last_message_at,
            encode(lm.ciphertext,'base64') as last_ciphertext,
            lm.content_type as last_content_type,
            coalesce(uc.unread, 0)::int as unread_count
       from conversations c
       join conversation_members me on me.conversation_id = c.id and me.user_id = $1 and me.left_at is null
       left join lateral (
         select m.ciphertext, m.content_type, m.created_at as last_message_at
           from messages m where m.conversation_id = c.id
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
    [user_id]
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

export default router;
