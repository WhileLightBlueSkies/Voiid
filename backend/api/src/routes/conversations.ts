// Conversation routes (Section 10). Direct (1:1) and group conversations.
// Server stores only metadata + membership; message content stays ciphertext (see messages.ts).
import { Router } from 'express';
import { pool, query } from '../db';
import { isBlockedEitherWay, blockedUserIds } from '../blocking';
import { publisher } from '../redis';
import { asyncHandler } from '../util';
import { requireAuth } from '../auth';

const router = Router();

// POST /conversations/create
//   direct: { type:'direct', member_id }              -> idempotent (returns existing 1:1 if present)
//   group:  { type:'group', name, photo_url?, member_ids:[...] }

// ─────────────────────────────────────────────────────────────────────────────────
// GROUP SCALE AND ROLES (036_group_roles.sql)
//
// A group has EXACTLY ONE owner, up to 50 admins and up to 1000 members. The one-owner
// rule is enforced by a partial unique index rather than by these routes, so a bug here
// cannot produce two owners — the insert simply fails.
//
// 1000 is a transport limit, not a product opinion: MLS generates O(members) commit rows
// per join, so the ceiling is set where the fan-out still behaves. Signal's equivalent is
// a hard 1001 delivered by remote config.
// ─────────────────────────────────────────────────────────────────────────────────
const MAX_GROUP_MEMBERS = 1000;
const MAX_GROUP_ADMINS = 50;

type SystemEventKind =
  | 'members_added' | 'member_removed' | 'member_left'
  | 'role_changed' | 'ownership_transferred';

/**
 * Write a system event into the conversation's timeline.
 *
 * STRUCTURED, NOT PRE-BAKED ENGLISH. The row names the kind and the actors; the client
 * composes the sentence. That is the only way the same event reads as "You made Priyanshu
 * an admin" for one person and "Nehal made Priyanshu an admin" for another — and the only
 * way it can ever be localized.
 *
 * ciphertext is NULL, which is exactly what the fan-out path already writes for its
 * canonical metadata row, so nothing downstream needs a new case. The opacity assertion
 * that guards client bodies does not apply: this body is ours, and it carries no message
 * content — only ids the server already stores in order to route.
 */
async function emitSystemEvent(
  conversationId: string,
  actorId: string,
  kind: SystemEventKind,
  detail: Record<string, unknown> = {},
  client?: { query: (q: string, v?: unknown[]) => Promise<{ rows: any[] }> }
): Promise<void> {
  const run = client
    ? (q: string, v: unknown[]) => client.query(q, v).then(r => r.rows)
    : (q: string, v: unknown[]) => query<any>(q, v);
  const rows = await run(
    `insert into messages (conversation_id, sender_id, ciphertext, content_type, system_event)
          values ($1, $2, null, 'system', $3::jsonb)
       returning id, created_at`,
    [conversationId, actorId, JSON.stringify({ kind, actor_id: actorId, ...detail })]
  );
  const row = rows[0];
  if (!row) return;
  // Live members hear it on the channel they already listen to, so a role change lands in
  // an open conversation without a refetch.
  const members = await run(
    `select user_id from conversation_members
      where conversation_id = $1 and left_at is null`,
    [conversationId]
  );
  const frame = JSON.stringify({
    type: 'system_event', conversation_id: conversationId, message_id: row.id,
    created_at: row.created_at, event: { kind, actor_id: actorId, ...detail },
  });
  for (const m of members) {
    publisher.publish(`channel:user:${m.user_id}`, frame).catch(() => { /* best effort */ });
  }
}

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

    // Blocking (039). Checked BEFORE the idempotent lookup, so a blocked pair cannot even
    // resurface an existing 1:1 into their chat list by "creating" it again.
    //
    // 404, not 403: a distinctive error would tell the blocked party a block exists. This
    // is the same shape the endpoint returns for a user id that does not exist, which is
    // what someone unreachable should look like.
    if (await isBlockedEitherWay(user_id, member_id)) {
      return res.status(404).json({ error: 'user not found' });
    }

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
      // Checked before anything is written: a 1200-member create should fail as a request,
    // not halfway through inserting rows.
    if (members.length > MAX_GROUP_MEMBERS) {
      return res.status(400).json({
        error: `a group can have at most ${MAX_GROUP_MEMBERS} members`,
        code: 'group_full',
      });
    }
    const client = await pool.connect();
    try {
      await client.query('begin');
      const conv = (await client.query(
        `insert into conversations (type, name, photo_url, created_by) values ('group', $1, $2, $3) returning id`,
        [name, photo_url ?? null, user_id]
      )).rows[0];
      // The creator is the OWNER, not merely an admin. Every group needs exactly one, and
      // creation is the only moment one can be assigned without a transfer.
      for (const m of members) {
        await client.query(
          `insert into conversation_members (conversation_id, user_id, role) values ($1, $2, $3)`,
          [conv.id, m, m === user_id ? 'owner' : 'member']
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

  return res.status(400).json({ error: "type must be 'direct', 'group', or 'self'" });
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
  if (caller.role !== 'admin' && caller.role !== 'owner') {
    return res.status(403).json({ error: 'only an admin can add members' });
  }

  // Blocking (039). An admin may not drag someone they have a block with into a group —
  // that is the obvious way to route around a block, and it is the harassment vector the
  // feature exists to close.
  //
  // Scoped to the ADDER's blocks only. A block between the invitee and some OTHER member
  // is deliberately not checked here: those two already share whatever groups they share,
  // and letting one member's block veto an unrelated invitation would hand anyone a silent
  // veto over a group they are merely a member of.
  const adderBlocks = await blockedUserIds(user_id);
  const blockedInvitee = (userIds as string[]).find((u) => adderBlocks.has(u));
  if (blockedInvitee) {
    return res.status(403).json({ error: 'cannot add a user you have blocked or who has blocked you' });
  }

  // COUNTED INSIDE A TRANSACTION HOLDING THE CONVERSATION ROW. Two admins adding at the
  // same moment would each read a count below the cap and both proceed, so a "1000-member
  // limit" checked outside a lock is not a limit. `for update` on the conversations row
  // serialises them without locking the membership itself.
  const addClient = await pool.connect();
  try {
    await addClient.query('begin');
    await addClient.query(`select 1 from conversations where id = $1 for update`, [convId]);

    const active = Number((await addClient.query(
      `select count(*)::text as n from conversation_members
        where conversation_id = $1 and left_at is null`,
      [convId]
    )).rows[0].n);

    // Only people who are not already present count against the cap — re-adding someone who
    // never left must not be refused because the group is full of them.
    const incoming = [...new Set(userIds as string[])];
    const present = new Set((await addClient.query(
      `select user_id from conversation_members
        where conversation_id = $1 and user_id = any($2::uuid[]) and left_at is null`,
      [convId, incoming]
    )).rows.map((r: any) => r.user_id));
    const joining = incoming.filter((u) => !present.has(u));

    if (active + joining.length > MAX_GROUP_MEMBERS) {
      await addClient.query('rollback');
      return res.status(409).json({
        error: `a group can have at most ${MAX_GROUP_MEMBERS} members`,
        code: 'group_full',
      });
    }

    for (const uid of joining) {
      // ROLE IS RESET ON REINSTATE, and this is not cosmetic: a former OWNER re-added while
      // still carrying role='owner' trips the one-owner index in 036 and the insert fails
      // outright, making that person impossible to re-add. Anyone who returns comes back as
      // a member and can be promoted again.
      await addClient.query(
        `insert into conversation_members (conversation_id, user_id, role) values ($1, $2, 'member')
           on conflict (conversation_id, user_id)
           do update set left_at = null, role = 'member'`,
        [convId, uid]
      );
    }
    await addClient.query('commit');
    if (joining.length) {
      await emitSystemEvent(convId, user_id, 'members_added', { target_ids: joining });
    }
    return res.json({ added: joining.length });
  } catch (e) {
    await addClient.query('rollback');
    throw e;
  } finally {
    addClient.release();
  }
});

// ─────────────────────────────────────────────────────────────────────────────────
// PATCH /:id/members/:userId/role  { role: 'admin' | 'member' }
//
// Promote a member to admin, or demote an admin back. Ownership is NOT changed here —
// that is a transfer, and giving a group away should not share a code path with handing
// someone a moderation badge.
//
// WHO MAY DO WHAT, and the asymmetry is deliberate: an admin may promote, because growing
// the moderation team is how a large group stays manageable. Only the OWNER may demote an
// admin, because otherwise fifty admins are fifty people who can each strip the other
// forty-nine, and the first one to act wins.
// ─────────────────────────────────────────────────────────────────────────────────
router.patch('/:id/members/:userId/role', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const convId = req.params.id;
  const targetId = req.params.userId;
  const nextRole = req.body?.role;

  if (nextRole !== 'admin' && nextRole !== 'member') {
    return res.status(400).json({ error: "role must be 'admin' or 'member'" });
  }
  if (targetId === user_id) {
    return res.status(400).json({ error: 'you cannot change your own role' });
  }

  const client = await pool.connect();
  try {
    await client.query('begin');
    // Same lock as the add path: the admin cap is only a cap if concurrent promotions
    // cannot each read a count below it.
    await client.query(`select 1 from conversations where id = $1 for update`, [convId]);

    const rows = (await client.query(
      `select user_id, role from conversation_members
        where conversation_id = $1 and user_id = any($2::uuid[]) and left_at is null`,
      [convId, [user_id, targetId]]
    )).rows as Array<{ user_id: string; role: string }>;

    const caller = rows.find((r) => r.user_id === user_id);
    const target = rows.find((r) => r.user_id === targetId);
    if (!caller) { await client.query('rollback'); return res.status(403).json({ error: 'not a member of this conversation' }); }
    if (!target) { await client.query('rollback'); return res.status(404).json({ error: 'that person is not in this group' }); }

    if (caller.role !== 'owner' && caller.role !== 'admin') {
      await client.query('rollback');
      return res.status(403).json({ error: 'only an admin can change roles' });
    }
    if (target.role === 'owner') {
      await client.query('rollback');
      return res.status(403).json({ error: "the owner's role can only change by transferring ownership" });
    }
    if (nextRole === 'member' && target.role === 'admin' && caller.role !== 'owner') {
      await client.query('rollback');
      return res.status(403).json({ error: 'only the owner can dismiss an admin' });
    }
    if (target.role === nextRole) {
      await client.query('rollback');
      return res.json({ role: nextRole, unchanged: true });
    }

    if (nextRole === 'admin') {
      const admins = Number((await client.query(
        `select count(*)::text as n from conversation_members
          where conversation_id = $1 and role = 'admin' and left_at is null`,
        [convId]
      )).rows[0].n);
      if (admins >= MAX_GROUP_ADMINS) {
        await client.query('rollback');
        return res.status(409).json({
          error: `a group can have at most ${MAX_GROUP_ADMINS} admins`,
          code: 'too_many_admins',
        });
      }
    }

    await client.query(
      `update conversation_members set role = $3
        where conversation_id = $1 and user_id = $2 and left_at is null`,
      [convId, targetId, nextRole]
    );
    await client.query('commit');

    await emitSystemEvent(convId, user_id, 'role_changed', {
      target_id: targetId, new_role: nextRole, previous_role: target.role,
    });
    return res.json({ role: nextRole });
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /:id/transfer-ownership  { user_id }
//
// Hand the group to someone else. Owner-only, and the two halves run in ONE transaction:
// the one-owner index in 036 means a demote-then-promote that failed between the two
// statements would leave a group with no owner at all — unable to transfer again, and
// unable to block a last-admin exit. Demoting first (rather than promoting first) is what
// keeps the index from tripping mid-transaction.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/transfer-ownership', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const convId = req.params.id;
  const targetId = req.body?.user_id;

  if (typeof targetId !== 'string' || !targetId) {
    return res.status(400).json({ error: 'user_id required' });
  }
  if (targetId === user_id) {
    return res.status(400).json({ error: 'you already own this group' });
  }

  const client = await pool.connect();
  try {
    await client.query('begin');
    await client.query(`select 1 from conversations where id = $1 for update`, [convId]);

    const rows = (await client.query(
      `select user_id, role from conversation_members
        where conversation_id = $1 and user_id = any($2::uuid[]) and left_at is null`,
      [convId, [user_id, targetId]]
    )).rows as Array<{ user_id: string; role: string }>;

    const caller = rows.find((r) => r.user_id === user_id);
    const target = rows.find((r) => r.user_id === targetId);
    if (caller?.role !== 'owner') {
      await client.query('rollback');
      return res.status(403).json({ error: 'only the owner can transfer ownership' });
    }
    if (!target) {
      await client.query('rollback');
      return res.status(404).json({ error: 'that person is not in this group' });
    }

    // Order matters: demote first so the partial unique index never sees two owners.
    await client.query(
      `update conversation_members set role = 'admin'
        where conversation_id = $1 and user_id = $2`,
      [convId, user_id]
    );
    await client.query(
      `update conversation_members set role = 'owner'
        where conversation_id = $1 and user_id = $2`,
      [convId, targetId]
    );
    await client.query('commit');

    await emitSystemEvent(convId, user_id, 'ownership_transferred', { target_id: targetId });
    return res.json({ owner_id: targetId });
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }
}));

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
