// Community host threads — THE ONE SCOPED EXCEPTION TO 020_reachability.sql.
//
// ── WHAT THIS FILE IS ALLOWED TO DO, AND NOTHING ELSE ────────────────────────────
//
// 020_reachability.sql defines exactly three ways to open a conversation:
//
//   1. mutual contacts       -> opens directly
//   2. one-way contact       -> opens as a REQUEST (Accept / Decline)
//   3. @username + 6-digit PIN -> opens as a REQUEST
//
// This file adds a fourth, and it is member -> COMMUNITY OWNER only. Joining a space is
// consent to be ASKED QUESTIONS BY ITS MEMBERS. It is not consent to be messaged by every
// other member. A 5,000-member community must never become 5,000 mutual messaging rights;
// that is a spam amplifier with a friendly name.
//
// ── HOW MEMBER -> MEMBER IS MADE IMPOSSIBLE, NOT MERELY UNIMPLEMENTED ────────────
//
// Three independent structures have to be defeated before this endpoint could open a chat
// between two ordinary members:
//
//   * THERE IS NO TARGET PARAMETER. The only input is the community id. The peer is read
//     from `communities.owner_id` (029/030 make that column the single authority, precisely
//     so this lookup cannot return two rows or be pointed somewhere else). Adding a
//     `target_user_id` to the body of this route is the bug, and it would be visible in the
//     diff of this file as a new field — which is the point.
//   * community_host_threads HAS NOWHERE TO PUT A SECOND MEMBER. Its columns are
//     (community_id, member_user_id, conversation_id). Recording a member->member thread
//     would require a migration, which requires a review.
//   * `opened_via = 'community'` says on the membership row how this chat came to exist, so
//     an audit can answer "how did this stranger reach me?" honestly rather than by guessing.
//
// IF YOU EVER FIND CODE THAT READS COMMUNITY MEMBERSHIP TO AUTHORISE A MESSAGE BETWEEN TWO
// ORDINARY MEMBERS, THAT IS A BUG — the same rule 029_creator_profiles.sql states for
// follows. Membership is a social graph. A social graph quietly becoming a messaging graph
// is the exact failure mode these gates exist to prevent. Fix the caller; do not widen this.
//
// ── ENCRYPTION ───────────────────────────────────────────────────────────────────
//
// ZERO NEW CRYPTOGRAPHY. The thread is an ordinary `type='direct'` conversation carried by
// the existing Double Ratchet; the server stores and relays opaque ciphertext exactly as it
// does for every other 1:1. What is new here is only the server-side AUTHORISATION to create
// the conversation row, and the note recording that it happened.
//
// ── WHY A SEPARATE ROUTE FILE ────────────────────────────────────────────────────
//
// The repair plan puts this endpoint in `routes/communities.ts`. It lives on its own instead
// because the reachability exception is the one piece of the communities feature that can
// weaken the messaging product if it is edited carelessly, and a small file whose whole
// header is "here is why this is narrow" is far harder to widen by accident than three lines
// buried in a 900-line CRUD router. Paths are declared in full and the router is mounted at
// the API root, so it neither depends on nor collides with the mount order of the general
// communities router (a one-segment `/:handle` route can never match a two-segment
// `/:id/host-thread` path).
import { Router } from 'express';
import { pool, query } from '../db';
import { requireAuth } from '../auth';
import { rateLimit } from '../security';

const router = Router();

// ─────────────────────────────────────────────────────────────────────────────────
// Creation limits.
//
// Two layers, because they stop different attacks. The IP-keyed `rateLimit` middleware
// blunts a script; the per-USER counts below are the real limit, since a single account
// walking a directory and opening a line to every host it can find is the abuse this feature
// invents. Both are deliberately generous for a human — a person who joins eleven communities
// in an hour and messages every host is not a person.
//
// Counted over community_host_threads rows (i.e. over CREATIONS), so reopening an existing
// thread is free forever. Being throttled out of a conversation you already have would be a
// self-inflicted outage, not a defence.
// ─────────────────────────────────────────────────────────────────────────────────
const HOST_THREAD_MAX_PER_HOUR = 10;
const HOST_THREAD_MAX_PER_DAY = 30;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type HostTarget =
  | { ok: true; ownerId: string }
  | { ok: false; status: number; error: string };

/**
 * Resolve the ONE legitimate target for a host thread, and prove the caller may reach it.
 *
 * Every rule of the exception is concentrated here so there is a single place to read, and a
 * single place a reviewer has to look at when this file changes:
 *
 *   - the community exists and is not suspended (suspension freezes new contact, exactly as
 *     it freezes joins and discovery, without destroying anything already open);
 *   - the caller is an ACTIVE member. `pending` is not eligible — an applicant to an
 *     approval-gated community has not been let in, and letting them message the owner
 *     anyway would make the approval queue a formality;
 *   - the peer is `communities.owner_id` and is read from that column only.
 *
 * Returns the owner's user id, never a list, never a body-supplied value.
 */
async function resolveHostTarget(communityId: string, callerId: string): Promise<HostTarget> {
  const community = (await query<{ owner_id: string; suspended_at: string | null }>(
    `select owner_id, suspended_at from communities where id = $1`,
    [communityId]
  ))[0];
  if (!community) return { ok: false, status: 404, error: 'no such community' };
  if (community.suspended_at) return { ok: false, status: 403, error: 'this community is suspended' };

  // Membership is checked against the ROSTER, and only ever to answer "may this caller reach
  // the owner". It is never joined to another member row, and there is no code path here that
  // takes a second user id out of it.
  const membership = (await query<{ state: string }>(
    `select state from community_members where community_id = $1 and user_id = $2`,
    [communityId, callerId]
  ))[0];
  if (!membership || membership.state !== 'active') {
    // One message for "never joined", "still pending", "left" and "banned". Distinguishing
    // them would turn this endpoint into an oracle for moderation state the caller is not
    // entitled to read — in particular, a banned account should not be able to confirm
    // the ban from an unrelated endpoint.
    return { ok: false, status: 403, error: 'only active members can message the host' };
  }

  // The owner messaging themselves is a UI mistake, not an attack; a self-conversation would
  // also violate the two-member shape every direct chat here assumes.
  if (community.owner_id === callerId) {
    return { ok: false, status: 400, error: 'you are the host of this community' };
  }

  const owner = (await query<{ id: string }>(
    `select id from users where id = $1 and deleted_at is null`,
    [community.owner_id]
  ))[0];
  if (!owner) return { ok: false, status: 404, error: 'this community has no reachable host' };

  return { ok: true, ownerId: community.owner_id };
}

/**
 * An existing 1:1 between these two, if any — same shape as the reachability route's reuse
 * check (two active membership rows, exactly two members, type 'direct').
 *
 * Returns the caller's peer's membership state too, because a chat that already exists may
 * be one the host DECLINED, and that answer matters (see the POST handler).
 */
async function findDirectConversation(a: string, b: string) {
  return (await query<{ id: string; peer_state: string }>(
    `select c.id, mb.request_state as peer_state
       from conversations c
       join conversation_members ma
            on ma.conversation_id = c.id and ma.user_id = $1 and ma.left_at is null
       join conversation_members mb
            on mb.conversation_id = c.id and mb.user_id = $2 and mb.left_at is null
      where c.type = 'direct'
        and (select count(*) from conversation_members m
              where m.conversation_id = c.id and m.left_at is null) = 2
      limit 1`,
    [a, b]
  ))[0];
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /communities/:id/host-thread
//
// Open (or reopen) the caller's private line to this community's host. Body is IGNORED —
// see the header: there is no target parameter, by design.
//
// Response: { conversation_id, host_user_id, existed, opened_via }
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/communities/:id/host-thread',
  requireAuth,
  rateLimit({ max: 20, windowSeconds: 60, bucket: 'community-host-thread' }),
  async (req, res) => {
    const { user_id } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    // Validate before touching the database: an uncast non-uuid reaches Postgres as a type
    // error (22P02), which surfaces as a 500 for what is a client mistake.
    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });

    const target = await resolveHostTarget(communityId, user_id);
    if (!target.ok) return res.status(target.status).json({ error: target.error });
    const hostId = target.ownerId;

    // ── Already opened? Free, and idempotent across devices and retries.
    const existingThread = (await query<{ conversation_id: string }>(
      `select conversation_id from community_host_threads
        where community_id = $1 and member_user_id = $2`,
      [communityId, user_id]
    ))[0];
    if (existingThread) {
      return res.json({
        conversation_id: existingThread.conversation_id,
        host_user_id: hostId,
        existed: true,
        opened_via: 'community',
      });
    }

    // ── An ordinary 1:1 between these two may already exist (they are contacts, or one of
    //    them opened a request). Reuse it, and do NOT record it as a host thread: retro-
    //    labelling a personal chat would move it into the host's Community inbox and rewrite
    //    how it says it was opened, which is a lie about provenance for zero benefit.
    const existingDirect = await findDirectConversation(user_id, hostId);
    if (existingDirect) {
      // THE HOST ALREADY SAID NO. `declined` is the only server-visible refusal Voiid has
      // (blocking is client-side), and a community join must not launder around it. Joining a
      // space grants the right to ask its host a question; it does not overrule a host who has
      // explicitly refused this person. Reported as the ordinary membership failure so the
      // refusal is not confirmed back to the sender — same reasoning as
      // POST /reachability/:id/decline, which never tells the sender either.
      if (existingDirect.peer_state === 'declined') {
        return res.status(403).json({ error: 'only active members can message the host' });
      }
      return res.json({
        conversation_id: existingDirect.id,
        host_user_id: hostId,
        existed: true,
        opened_via: null,
      });
    }

    // ── Creation is throttled per user; reuse above is not.
    const counts = (await query<{ hour: string; day: string }>(
      `select
         count(*) filter (where created_at > now() - interval '1 hour')::text as hour,
         count(*) filter (where created_at > now() - interval '1 day')::text  as day
       from community_host_threads where member_user_id = $1`,
      [user_id]
    ))[0];
    if (Number(counts?.hour ?? 0) >= HOST_THREAD_MAX_PER_HOUR ||
        Number(counts?.day ?? 0) >= HOST_THREAD_MAX_PER_DAY) {
      return res.status(429).json({ error: 'Too many new host conversations. Try again later.' });
    }

    const client = await pool.connect();
    try {
      await client.query('begin');
      const conv = (await client.query<{ id: string }>(
        `insert into conversations (type, created_by) values ('direct', $1) returning id`,
        [user_id]
      )).rows[0];

      // BOTH SIDES 'accepted'. This is the whole substance of the exception: the host does not
      // get an Accept/Decline card, because they already consented by hosting a space this
      // person is a member of. `opened_via='community'` is written on both rows so the host's
      // client can group these into a Community inbox section and the member's client can say
      // where the chat came from.
      await client.query(
        `insert into conversation_members (conversation_id, user_id, request_state, opened_via)
         values ($1, $2, 'accepted', 'community'), ($1, $3, 'accepted', 'community')`,
        [conv.id, user_id, hostId]
      );

      // ON CONFLICT DO NOTHING + RETURNING is the race decider: two devices pressing "Message
      // host" at once both reach here, one inserts, the other returns no row and rolls back —
      // taking its now-orphaned conversation with it — then re-reads the winner below. A
      // select-then-insert would leave two conversations and two half-wired threads.
      const claimed = (await client.query<{ conversation_id: string }>(
        `insert into community_host_threads (community_id, member_user_id, conversation_id)
         values ($1, $2, $3)
         on conflict (community_id, member_user_id) do nothing
         returning conversation_id`,
        [communityId, user_id, conv.id]
      )).rows[0];

      if (!claimed) {
        await client.query('rollback');
        const winner = (await query<{ conversation_id: string }>(
          `select conversation_id from community_host_threads
            where community_id = $1 and member_user_id = $2`,
          [communityId, user_id]
        ))[0];
        // A missing winner here means the conflicting row vanished between the two statements
        // (the community or the account was deleted mid-flight). 409, not 500: retrying is the
        // right client behaviour and nothing is broken.
        if (!winner) return res.status(409).json({ error: 'host thread changed, retry' });
        return res.json({
          conversation_id: winner.conversation_id,
          host_user_id: hostId,
          existed: true,
          opened_via: 'community',
        });
      }

      await client.query('commit');
      return res.json({
        conversation_id: conv.id,
        host_user_id: hostId,
        existed: false,
        opened_via: 'community',
      });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /communities/:id/host-thread
//
// Does the caller already have a line to this host? Lets the info card render "Open chat"
// instead of "Message host" WITHOUT creating anything — a GET that silently minted a
// conversation would make every card impression an act of contact.
//
// Returns { conversation_id: null } rather than 404 when there is none: "no thread yet" is
// the normal state, not an error.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/communities/:id/host-thread', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const communityId = String(req.params.id ?? '');
  if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });

  const target = await resolveHostTarget(communityId, user_id);
  if (!target.ok) return res.status(target.status).json({ error: target.error });

  const row = (await query<{ conversation_id: string }>(
    `select conversation_id from community_host_threads
      where community_id = $1 and member_user_id = $2`,
    [communityId, user_id]
  ))[0];

  res.json({
    conversation_id: row?.conversation_id ?? null,
    host_user_id: target.ownerId,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /community-host-threads
//
// Every host thread the caller is on, from BOTH ends: the ones they opened as a member, and
// the ones opened with them as the host. `role` says which.
//
// This exists so the clients can group these conversations into a Community inbox section
// using data they can actually get — `GET /conversations` does not return `opened_via`, and
// that route belongs to another workstream. Keyed on conversation_id, which is what a chat
// list row already has.
//
// It returns IDS AND COMMUNITY CARD FIELDS ONLY. No member names, no last message, nothing
// about content: the messages are E2EE and the server could not describe them if it wanted to.
//
// Mounted at the API root under its own path so it can never be shadowed by a
// `GET /communities/:handle` route — 'community-host-threads' is not a legal handle, but not
// relying on that is cheaper than relying on it.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/community-host-threads', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query(
    `select t.conversation_id,
            t.community_id,
            t.created_at,
            t.status,
            t.status_changed_at,
            c.handle        as community_handle,
            c.name          as community_name,
            c.avatar_r2_key as community_avatar_r2_key,
            case when c.owner_id = $1 then 'host' else 'member' end as role,
            t.member_user_id
       from community_host_threads t
       join communities c on c.id = t.community_id
      where t.member_user_id = $1 or c.owner_id = $1
      order by t.created_at desc
      limit 500`,
    [user_id]
  );
  res.json({ threads: rows });
});

// ─────────────────────────────────────────────────────────────────────────────────
// PATCH /communities/:id/host-thread/:memberId/status  { status }
//
// Move one thread along the queue: unread -> open -> resolved (any order; a host may reopen).
//
// HOST ONLY, and checked here rather than inferred from the caller reaching this route. The
// member owns their side of the conversation but not the QUEUE — a member marking their own
// complaint resolved is exactly the thing a moderation queue must not permit.
//
// Deliberately NOT reusing resolveHostTarget: that answers "may this caller message the
// owner", which is the members' question and returns 403 for the owner's own community if
// they are not on their own roster. The question here is "is this caller the owner".
// ─────────────────────────────────────────────────────────────────────────────────
const THREAD_STATUSES = new Set(['unread', 'open', 'resolved']);

router.patch(
  '/communities/:id/host-thread/:memberId/status',
  requireAuth,
  rateLimit({ max: 60, windowSeconds: 60, bucket: 'community-host-thread-status' }),
  async (req, res) => {
    const { user_id } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    const memberId = String(req.params.memberId ?? '');
    const status = String((req.body ?? {}).status ?? '');

    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });
    if (!UUID_RE.test(memberId)) return res.status(400).json({ error: 'member id must be a uuid' });
    if (!THREAD_STATUSES.has(status)) {
      return res.status(400).json({ error: 'status must be unread, open or resolved' });
    }

    const community = (await query<{ owner_id: string }>(
      `select owner_id from communities where id = $1`,
      [communityId]
    ))[0];
    // 404 for "not the owner" as well as "no such community": a caller who is not the host
    // must not learn whether a community id exists by watching the status code change.
    if (!community || community.owner_id !== user_id) {
      return res.status(404).json({ error: 'no such community' });
    }

    const updated = await query<{ conversation_id: string }>(
      `update community_host_threads
          set status = $3, status_changed_at = now(), status_changed_by = $4
        where community_id = $1 and member_user_id = $2
        returning conversation_id`,
      [communityId, memberId, status, user_id]
    );
    if (!updated.length) return res.status(404).json({ error: 'no such thread' });

    res.json({ status, conversation_id: updated[0].conversation_id });
  }
);

export default router;
