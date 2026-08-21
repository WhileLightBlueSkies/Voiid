// Communities — the server-side container that holds N end-to-end-encrypted channels.
//
// ============================ NOT END-TO-END ENCRYPTED ============================
// Read the header of 030_communities.sql before touching this file. Everything this router
// reads and writes — the name, description, avatar, handle, roster, roles, invite tokens and
// the search index — is SERVER-READABLE, and has to be: an outsider must be able to see the
// info card before joining, the server gates joins and fans MLS control messages out per
// member, and a server that cannot read a name cannot match a search against it.
//
// What stays encrypted, and is not touched here: every channel message (MLS, 011), including
// announcements, and the member->host DM (Double Ratchet, 006). This router creates
// conversations and membership rows. It never sees a key or a plaintext, and nothing in it
// is a precedent for weakening messaging.
// =================================================================================
//
// ── A JOIN IS NOT A MESSAGING RIGHT ──────────────────────────────────────────────
//
// 020_reachability.sql defines the only three ways to open a 1:1 (mutual contact / one-way
// contact as a request / @username + 6-digit PIN). Joining a community adds none of them.
// The one narrow exception — member -> the community OWNER, never member -> member — lives
// in routes/communityHostThreads.ts, on its own, with its own header explaining why it is
// narrow. NOTHING IN THIS FILE MAY BE READ TO AUTHORISE A CONVERSATION. If you find yourself
// joining community_members to answer "may A message B", that is the bug 029_creator_
// profiles.sql forbids, wearing a different hat.
//
// ── THE DIVISION OF LABOUR WITH MLS ──────────────────────────────────────────────
//
// This router only ever writes the SERVER-SIDE membership (`conversation_members`), which is
// what message fan-out and the pending-fetch query read. The cryptographic half — Welcome to
// the new member, Commit to everyone else — is produced by a CLIENT that already holds the
// group state and shipped via /mls/group-events. That is the same split conversations.ts
// documents for adding a member to an ordinary group; a server that could add someone to an
// MLS group by itself would be a server that holds group secrets.
//
// Because of that split, a join has to TELL somebody to commit. It notifies the owner and
// admins only — see publishMembershipNotice — deliberately not all members, since a publish
// per member is the O(members) cost item 3.20 exists to avoid.
//
// ── ROUTE ORDER MATTERS HERE ─────────────────────────────────────────────────────
//
// `GET /:handle` is a one-segment wildcard, so every literal one-segment route (/search,
// /mine) must be declared ABOVE it or it swallows them. That is also why 032_community_
// route_handles.sql reserves those words as handles: a community that managed to take the
// handle @search would be permanently unreachable through its own info-card route.
import { Router } from 'express';
import { randomBytes } from 'crypto';
import { pool, query } from '../db';
import { requireAuth } from '../auth';
import { rateLimit } from '../security';
import { asyncHandler } from '../util';
import { publisher } from '../redis';
import { presignGet, r2Configured } from '../r2';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Same grammar as users.username (010), creator_profiles.handle (029) and the
// communities_handle_format check in 030 — the three share one namespace, so a validator
// that disagreed with any of them would only move the failure from a 400 to a 500.
const HANDLE_RE = /^[a-z][a-z0-9_]{2,19}$/;

const MAX_NAME = 60;         // communities_name_len
const MAX_DESCRIPTION = 500; // communities_description_len
const MAX_CHANNEL_NAME = 60;
const SEARCH_LIMIT_DEFAULT = 20;
const SEARCH_LIMIT_MAX = 50;
const MEMBER_PAGE_DEFAULT = 50;
const MEMBER_PAGE_MAX = 200;

// ─────────────────────────────────────────────────────────────────────────────────
// Item 3.20 — the two numbers that keep MLS fan-out survivable.
//
// EVERY MEMBER OF A COMMUNITY IS IN EVERY CHANNEL of it. So the real fan-out cost is not
// members, it is members x channels: each join has to be Committed into each channel's MLS
// group, and mls_group_events takes ONE ROW PER RECIPIENT (011). The per-channel ceiling is
// `communities.max_members` (a column, default 512, hard-capped at 1024 by a check
// constraint, so no admin UPDATE can raise it past what the plumbing survives) and the
// number of channels is capped here, because nothing in the schema can bound it.
//
// 20 channels x 512 members is ~10k control-message rows for one join in the worst case.
// That is the number to beat before either cap moves.
//
// Raising `max_members` is deliberately NOT exposed as an API field anywhere in this file.
// It is an operational act — the fan-out batching in routes/mls.ts has to be watched in
// production first — and an operator running one UPDATE is a decision with a person attached
// to it, which a PATCH field is not.
// ─────────────────────────────────────────────────────────────────────────────────
const MAX_CHANNELS_PER_COMMUNITY = 20;

// How many owner/admin clients get poked to perform the MLS Commit for a join. Bounded so a
// community that appointed 300 admins does not turn every join into 300 Redis publishes —
// one committer is enough, and the rest is redundancy.
const COMMIT_NOTICE_FANOUT = 25;

/**
 * Postgres unique_violation. Raised by the lower(handle) index AND by the cross-table
 * assert_handle_available() trigger in 030, AND by idx_community_one_announcement. The
 * caller decides what it means in context; the code is the only thing shared.
 */
function isUniqueViolation(e: unknown): boolean {
  return typeof e === 'object' && e !== null && (e as { code?: string }).code === '23505';
}

/**
 * Neutralise LIKE metacharacters in user input.
 *
 * Without this, a search for `%` matches every discoverable community and `_` matches any
 * single character — the user typed literal characters and got a pattern. Backslash first,
 * or it re-escapes the escapes.
 */
function escapeLike(s: string): string {
  return s.replace(/\\/g, '\\\\').replace(/%/g, '\\%').replace(/_/g, '\\_');
}

function clampInt(raw: unknown, def: number, max: number): number {
  const n = typeof raw === 'string' ? parseInt(raw, 10) : NaN;
  return Number.isFinite(n) ? Math.min(Math.max(n, 1), max) : def;
}

function trimmed(v: unknown, max: number): string | null {
  if (v == null) return null;
  const s = String(v).trim();
  return s ? s.slice(0, max) : null;
}

type CommunityRow = {
  id: string;
  owner_id: string;
  handle: string;
  name: string;
  description: string | null;
  avatar_r2_key: string | null;
  discoverable: boolean;
  join_policy: string;
  member_count: number;
  max_members: number;
  suspended_at: string | null;
  created_at: string;
};

/**
 * The card an outsider is allowed to see. This shape is the whole reason the container is a
 * table and not a conversation — `GET /conversations/:id` is member-only by design, and a
 * card whose purpose is to be shown to strangers cannot be encrypted to them.
 *
 * EVERY KEY IS ALWAYS PRESENT, null rather than omitted. Swift's Codable throws keyNotFound
 * on an absent key, so a response that drops `description` when it happens to be empty
 * breaks the iOS client for exactly the communities that did not write one.
 *
 * `owner_id` is included because the clients need it to render "you are the host" and to
 * decide whether to offer "Message host" at all. It is not a messaging grant — see the
 * header.
 */
async function publicCard(row: CommunityRow) {
  return {
    id: row.id,
    handle: row.handle,
    name: row.name,
    description: row.description ?? null,
    avatar_url:
      r2Configured() && row.avatar_r2_key
        ? await presignGet(row.avatar_r2_key).catch(() => null)
        : null,
    member_count: row.member_count,
    join_policy: row.join_policy,
    discoverable: row.discoverable,
    owner_id: row.owner_id,
    suspended: row.suspended_at != null,
    created_at: row.created_at,
  };
}

const COMMUNITY_COLUMNS = `id, owner_id, handle, name, description, avatar_r2_key,
                           discoverable, join_policy, member_count, max_members,
                           suspended_at, created_at`;

/**
 * Resolve a community by uuid OR by handle, in one probe either way.
 *
 * Both spellings are accepted on the read path because a deep link
 * (https://voiid.app/c/<handle>?i=<token>) arrives holding a handle while every mutating
 * route below takes the uuid. Forcing the client to translate would just mean two round
 * trips before a Join button can render. The MUTATING routes are uuid-only on purpose: a
 * handle is renameable, and an authorisation decision should not be keyed on something that
 * can change hands.
 */
async function findCommunity(idOrHandle: string): Promise<CommunityRow | undefined> {
  if (UUID_RE.test(idOrHandle)) {
    return (
      await query<CommunityRow>(`select ${COMMUNITY_COLUMNS} from communities where id = $1`, [
        idOrHandle,
      ])
    )[0];
  }
  const handle = idOrHandle.toLowerCase();
  if (!HANDLE_RE.test(handle)) return undefined;
  return (
    await query<CommunityRow>(
      `select ${COMMUNITY_COLUMNS} from communities where lower(handle) = $1`,
      [handle]
    )
  )[0];
}

type Membership = { role: string; state: string };

async function membershipOf(communityId: string, userId: string): Promise<Membership | undefined> {
  return (
    await query<Membership>(
      `select role, state from community_members where community_id = $1 and user_id = $2`,
      [communityId, userId]
    )
  )[0];
}

type Managed =
  | { ok: true; community: CommunityRow; role: string }
  | { ok: false; status: number; error: string };

/**
 * Assert the caller may administer this community: active owner or active admin.
 *
 * `communities.owner_id` is checked as well as the roster row because 030 makes that column
 * the authority on who the host is — the owner keeps control even if their mirror roster row
 * were somehow missing. `state = 'active'` is load-bearing on the roster side: rows are
 * retained after a leave or a ban so that bans survive, and a banned ex-admin must not keep
 * moderator powers along with the row.
 */
async function requireManager(communityId: string, userId: string): Promise<Managed> {
  if (!UUID_RE.test(communityId)) {
    return { ok: false, status: 400, error: 'community id must be a uuid' };
  }
  const community = (
    await query<CommunityRow>(`select ${COMMUNITY_COLUMNS} from communities where id = $1`, [
      communityId,
    ])
  )[0];
  if (!community) return { ok: false, status: 404, error: 'no such community' };

  if (community.owner_id === userId) return { ok: true, community, role: 'owner' };

  const m = await membershipOf(communityId, userId);
  if (!m || m.state !== 'active' || (m.role !== 'admin' && m.role !== 'owner')) {
    return { ok: false, status: 403, error: 'only the owner or an admin can do that' };
  }
  return { ok: true, community, role: m.role };
}

/**
 * Tell the people who can actually perform the MLS Commit that the roster moved.
 *
 * Item 3.20, restated as a design rule: a membership change must NOT cost one Redis publish
 * per member. The server cannot commit to an MLS group itself (it holds no group state), so
 * SOMEBODY's client has to — and the owner/admins are both the smallest sufficient set and
 * the devices most likely to be online for a community they run. Everyone else finds out the
 * ordinary way, when the Commit arrives on /mls/group-events.
 *
 * Pipelined (one round trip, not N) and best-effort: this is a nudge, not the source of
 * truth. If Redis is down the membership rows are still correct and the next client to sync
 * reconciles. Never let it fail the request that already committed.
 */
async function publishMembershipNotice(
  communityId: string,
  subjectUserId: string,
  event: 'community_member_joined' | 'community_member_left',
  channelIds: string[]
): Promise<void> {
  try {
    const admins = await query<{ user_id: string }>(
      `select user_id from community_members
        where community_id = $1 and state = 'active' and role in ('owner', 'admin')
        limit ${COMMIT_NOTICE_FANOUT}`,
      [communityId]
    );
    if (!admins.length) return;
    const body = JSON.stringify({
      type: event,
      community_id: communityId,
      user_id: subjectUserId,
      conversation_ids: channelIds,
    });
    const pipe = publisher.pipeline();
    for (const a of admins) pipe.publish(`channel:user:${a.user_id}`, body);
    await pipe.exec();
  } catch (e) {
    console.warn('[communities] membership notice failed:', (e as Error).message);
  }
}

/** The channels of a community, in display order. Small by construction (see the cap). */
async function channelsOf(communityId: string) {
  return query<{ conversation_id: string; kind: string; position: number; name: string | null }>(
    `select ch.conversation_id, ch.kind, ch.position, c.name
       from community_channels ch
       join conversations c on c.id = ch.conversation_id
      where ch.community_id = $1
      order by ch.position, ch.created_at`,
    [communityId]
  );
}

// ═════════════════════════════════════════════════════════════════════════════════
// CREATE
// ═════════════════════════════════════════════════════════════════════════════════

// POST /communities
//   { id, handle, name, description?, avatar_r2_key?, discoverable?, join_policy?,
//     announcement_channel_name?, general_channel_name? }
//
// ONE TRANSACTION creates: the container, two group conversations (an announcement channel
// and a general chat), their community_channels links, the owner's roster row, and the
// owner's membership in both conversations. Half of that is useless without the other half —
// a community with no channels cannot be entered, and a channel with no container cannot be
// moderated — so it is all-or-nothing.
//
// THE ID COMES FROM THE CLIENT, exactly like clips (022) and for the same reason 030 spells
// out: with a multi-step create, a client that retries a timed-out POST must land on the same
// row or it silently mints a second, half-wired community. `on conflict (id) do nothing`
// below turns the retry into a lookup. There is no server-side default for this column, so
// forgetting to send one is a 400, not a surprise uuid.
router.post(
  '/',
  requireAuth,
  // Tighter than the router-wide ceiling: one create is three INSERTs, two new conversations
  // and a permanent claim on a name in a namespace shared with every username on the platform.
  // Handle-squatting at scale is the abuse this stops.
  rateLimit({ max: 10, windowSeconds: 3600, bucket: 'community-create' }),
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const body = req.body ?? {};

    const id = String(body.id ?? '');
    if (!UUID_RE.test(id)) {
      return res.status(400).json({ error: 'id (a client-generated uuid) is required' });
    }
    const handle = String(body.handle ?? '').trim().toLowerCase();
    if (!HANDLE_RE.test(handle)) {
      return res.status(400).json({
        error: 'handle must be 3-20 chars, start with a letter, and use only a-z, 0-9 and _',
      });
    }
    const name = trimmed(body.name, MAX_NAME);
    if (!name) return res.status(400).json({ error: 'name is required' });

    const description = trimmed(body.description, MAX_DESCRIPTION);
    const avatarKey = trimmed(body.avatar_r2_key, 400);
    const discoverable = body.discoverable === true;
    const joinPolicy = String(body.join_policy ?? 'open');
    if (!['open', 'approval', 'invite_only'].includes(joinPolicy)) {
      return res.status(400).json({ error: "join_policy must be open, approval or invite_only" });
    }
    const announcementName = trimmed(body.announcement_channel_name, MAX_CHANNEL_NAME) ?? 'Announcements';
    const generalName = trimmed(body.general_channel_name, MAX_CHANNEL_NAME) ?? 'General';

    const client = await pool.connect();
    try {
      await client.query('begin');

      // `do nothing` rather than `do update`: a retry must not be able to rewrite a community
      // that already exists — including one owned by somebody else, which is what an attacker
      // guessing ids would be attempting.
      const created = (
        await client.query<CommunityRow>(
          `insert into communities (id, owner_id, handle, name, description, avatar_r2_key,
                                    discoverable, join_policy)
                values ($1, $2, $3, $4, $5, $6, $7, $8)
           on conflict (id) do nothing
             returning ${COMMUNITY_COLUMNS}`,
          [id, user_id, handle, name, description, avatarKey, discoverable, joinPolicy]
        )
      ).rows[0];

      if (!created) {
        // Somebody already holds this id. If it is this caller's own community, this is the
        // retry the client-supplied pk exists to make safe: report the existing thing.
        await client.query('rollback');
        const existing = (
          await query<CommunityRow>(`select ${COMMUNITY_COLUMNS} from communities where id = $1`, [id])
        )[0];
        if (!existing || existing.owner_id !== user_id) {
          return res.status(409).json({ error: 'that community id is already taken' });
        }
        return res.json({
          community: await publicCard(existing),
          channels: await channelsOf(id),
          existed: true,
        });
      }

      // The channels. Ordinary `type='group'` conversations — real MLS groups the GroupEngine
      // both clients already ship renders without knowing what a community is. The container
      // is metadata ABOUT E2EE rooms; it does not sit inside them.
      const announcement = (
        await client.query<{ id: string }>(
          `insert into conversations (type, name, created_by) values ('group', $1, $2) returning id`,
          [announcementName, user_id]
        )
      ).rows[0];
      const general = (
        await client.query<{ id: string }>(
          `insert into conversations (type, name, created_by) values ('group', $1, $2) returning id`,
          [generalName, user_id]
        )
      ).rows[0];

      await client.query(
        `insert into community_channels (conversation_id, community_id, kind, position)
              values ($1, $3, 'announcement', 0), ($2, $3, 'chat', 1)`,
        [announcement.id, general.id, id]
      );

      // The creator is 'admin' on the conversations (the role conversations.ts already
      // understands for group management) and 'owner' on the roster (the role this router
      // and the announcement-posting guard understand). Two vocabularies, deliberately not
      // merged: conversation roles govern one chat, community roles govern the container.
      await client.query(
        `insert into conversation_members (conversation_id, user_id, role)
              values ($1, $3, 'admin'), ($2, $3, 'admin')`,
        [announcement.id, general.id, user_id]
      );

      // The roster row. idx_community_one_owner makes a second one impossible, so ownership
      // transfer must be demote-then-promote inside a transaction rather than two UPDATEs.
      await client.query(
        `insert into community_members (community_id, user_id, role, state)
              values ($1, $2, 'owner', 'active')`,
        [id, user_id]
      );

      await client.query('commit');

      // RE-READ rather than returning the row the INSERT gave back. `member_count` is
      // maintained by a trigger on community_members, and the owner's roster row is written
      // three statements AFTER the container — so the RETURNING row says 0 members forever,
      // and the client would render "0 members" on a community that has one. Anything
      // trigger-maintained has to be read after the write that moves it.
      const fresh = (
        await query<CommunityRow>(`select ${COMMUNITY_COLUMNS} from communities where id = $1`, [id])
      )[0];
      return res.status(201).json({
        community: await publicCard(fresh ?? created),
        channels: await channelsOf(id),
        existed: false,
      });
    } catch (e) {
      await client.query('rollback');
      // 23505 here is the handle: either the lower(handle) unique index or the cross-table
      // trigger from 029/030 that keeps @acme from meaning both a person and a space. The
      // user-facing truth is the same in both cases.
      if (isUniqueViolation(e)) {
        return res.status(409).json({ error: 'that handle is already taken' });
      }
      throw e;
    } finally {
      client.release();
    }
  })
);

// ═════════════════════════════════════════════════════════════════════════════════
// DISCOVERY  (declare every literal one-segment route ABOVE `GET /:handle`)
// ═════════════════════════════════════════════════════════════════════════════════

// GET /communities/search?q=&limit=
//
// Only `discoverable and suspended_at is null` — the partial indexes in 030 cover exactly
// that set, and opting in to discovery is a deliberate act (a community made for twelve
// friends must never surface because its creator never found a toggle).
//
// Handle match is a PREFIX (index-backed). Name match is a substring ILIKE, which cannot use
// a btree and degrades to a scan bounded by the partial index predicate — acceptable at MVP
// scale and called out as such in 030; the fix is a pg_trgm GIN index in its own migration,
// once the extension is confirmed present on the box.
router.get(
  '/search',
  requireAuth,
  asyncHandler(async (req, res) => {
    const q = String(req.query.q ?? '').trim();
    // Two characters minimum. A one-character query returns most of the directory sorted by
    // size, which is a scrape, not a search.
    if (q.length < 2) return res.json({ communities: [] });
    const limit = clampInt(req.query.limit, SEARCH_LIMIT_DEFAULT, SEARCH_LIMIT_MAX);
    const pattern = escapeLike(q.toLowerCase());

    const rows = await query<CommunityRow>(
      `select ${COMMUNITY_COLUMNS}
         from communities
        where discoverable and suspended_at is null
          and (lower(handle) like $1 or name ilike $2)
        order by member_count desc, id
        limit $3`,
      [`${pattern}%`, `%${escapeLike(q)}%`, limit]
    );
    res.json({ communities: await Promise.all(rows.map(publicCard)) });
  })
);

// GET /communities/mine — the Communities tab.
//
// Includes `pending` so an applicant to an approval-gated community can see that they asked
// and are waiting, rather than staring at a Join button that does nothing on the second tap.
router.get(
  '/mine',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const rows = await query<CommunityRow & { my_role: string; my_state: string }>(
      `select ${COMMUNITY_COLUMNS.split(',').map((c) => `c.${c.trim()}`).join(', ')},
              m.role as my_role, m.state as my_state
         from community_members m
         join communities c on c.id = m.community_id
        where m.user_id = $1 and m.state in ('active', 'pending')
        order by m.joined_at desc
        limit 200`,
      [user_id]
    );
    res.json({
      communities: await Promise.all(
        rows.map(async (r) => ({
          ...(await publicCard(r)),
          membership_state: r.my_state,
          membership_role: r.my_role,
        }))
      ),
    });
  })
);

// GET /communities/invites/:token — resolve an invite link WITHOUT redeeming it.
//
// The landing screen for https://voiid.app/c/<handle>?i=<token> (item 3.21) needs to show
// the card and a Join button. Redeeming on a GET would mean every link preview, every
// accidental tap and every crawler burns a use of a max_uses link.
//
// Declared before `/:id/invites` — the two shapes cannot actually collide (a uuid is never
// the literal 'invites'), but relying on that is more fragile than ordering them.
router.get(
  '/invites/:token',
  requireAuth,
  asyncHandler(async (req, res) => {
    const token = String(req.params.token ?? '');
    const row = (
      await query<{ community_id: string; valid: boolean }>(
        `select community_id,
                (revoked_at is null
                 and (expires_at is null or expires_at > now())
                 and (max_uses  is null or use_count < max_uses)) as valid
           from community_invites where token = $1`,
        [token]
      )
    )[0];
    // One answer for "no such token", "revoked", "expired" and "used up": a probe that
    // distinguishes them is an oracle for guessing tokens, and the user-facing action is the
    // same in every case — ask the host for a new link.
    if (!row || !row.valid) return res.status(404).json({ error: 'this invite link is no longer valid' });

    const community = (
      await query<CommunityRow>(`select ${COMMUNITY_COLUMNS} from communities where id = $1`, [
        row.community_id,
      ])
    )[0];
    if (!community) return res.status(404).json({ error: 'this invite link is no longer valid' });
    if (community.suspended_at) return res.status(403).json({ error: 'this community is suspended' });

    const { user_id } = (req as any).auth;
    const m = await membershipOf(community.id, user_id);
    res.json({
      community: await publicCard(community),
      membership_state: m?.state ?? null,
      membership_role: m?.role ?? null,
    });
  })
);

// GET /communities/:handle  (or /communities/:uuid)
//
// THE INFO CARD, AND IT WORKS FOR NON-MEMBERS. This is the whole reason the container is not
// a conversation: `GET /conversations/:id` is member-only by design, and the card exists to
// be shown to people who have not joined.
//
// `channels` is an ARRAY THAT IS ALWAYS PRESENT — empty for non-members rather than absent,
// because an absent key is a Codable keyNotFound crash on iOS. Non-members get no channel
// ids at all: a conversation id is the handle you fetch messages with, and while the
// ciphertext would be useless to them, handing out the identifiers of rooms they are not in
// is metadata leakage for nothing.
router.get(
  '/:handle',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const community = await findCommunity(String(req.params.handle ?? ''));
    if (!community) return res.status(404).json({ error: 'no such community' });

    const m = await membershipOf(community.id, user_id);
    const isActive = m?.state === 'active';
    res.json({
      community: await publicCard(community),
      membership_state: m?.state ?? null,
      membership_role: m?.role ?? null,
      channels: isActive ? await channelsOf(community.id) : [],
    });
  })
);

// ═════════════════════════════════════════════════════════════════════════════════
// JOIN / LEAVE
// ═════════════════════════════════════════════════════════════════════════════════

// POST /communities/:id/join   { invite_token? }
//
// ── THE MEMBER CAP (item 3.20) ───────────────────────────────────────────────────
//
// The transaction opens with `select ... for update` on the communities row, and that lock is
// the cap. `member_count` is trigger-maintained on that same row, so holding it means the
// count cannot move underneath the comparison: without the lock, 200 simultaneous joins into
// a community with one seat left all read the same 511 and all insert. Joins to ONE community
// serialise; joins to different communities do not touch each other.
//
// The ceiling is read from `communities.max_members`, never hardcoded here, so raising it is
// an UPDATE against a check constraint that stops at 1024 — see the note at the top of this
// file for why it is not a PATCH field.
//
// ── THE INVITE TOKEN ─────────────────────────────────────────────────────────────
//
// Redeemed with the single conditional UPDATE ... RETURNING quoted in 030. A select-then-
// update loses the max_uses race: two clients spending the last use of a max_uses=1 link both
// pass the SELECT and both join. The row lock the UPDATE takes is what serialises it.
//
// Redemption happens INSIDE the transaction and AFTER the cap check, so a join that fails
// because the community is full does not silently burn a use of the link.
router.post(
  '/:id/join',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });
    const inviteToken =
      typeof req.body?.invite_token === 'string' && req.body.invite_token ? req.body.invite_token : null;

    const client = await pool.connect();
    try {
      await client.query('begin');

      const community = (
        await client.query<CommunityRow>(
          `select ${COMMUNITY_COLUMNS} from communities where id = $1 for update`,
          [communityId]
        )
      ).rows[0];
      if (!community) {
        await client.query('rollback');
        return res.status(404).json({ error: 'no such community' });
      }
      if (community.suspended_at) {
        await client.query('rollback');
        return res.status(403).json({ error: 'this community is suspended' });
      }

      const existing = (
        await client.query<Membership>(
          `select role, state from community_members where community_id = $1 and user_id = $2`,
          [communityId, user_id]
        )
      ).rows[0];

      if (existing?.state === 'banned') {
        await client.query('rollback');
        return res.status(403).json({ error: 'you cannot join this community' });
      }
      if (existing?.state === 'active' || existing?.state === 'pending') {
        // Idempotent: pressing Join twice, or on two devices, is not an error.
        await client.query('rollback');
        return res.json({
          community_id: communityId,
          state: existing.state,
          existed: true,
          channels: existing.state === 'active' ? await channelsOf(communityId) : [],
        });
      }

      // ── What state does this join land in? ────────────────────────────────────
      //
      // The POLICY decides the state; the TOKEN only decides eligibility. In particular a
      // valid link into an `approval` community still lands 'pending' — an owner who chose
      // "I approve everyone" did not mean "unless they have a link", and a link that
      // silently overrode the queue would make approval decorative.
      let landState: 'active' | 'pending';
      if (community.join_policy === 'invite_only') {
        if (!inviteToken) {
          await client.query('rollback');
          return res.status(403).json({ error: 'this community is invite only' });
        }
        landState = 'active';
      } else if (community.join_policy === 'approval') {
        landState = 'pending';
      } else {
        landState = 'active';
      }

      // The cap applies only to seats actually taken. A pending applicant is not in any
      // channel and costs no MLS fan-out, so queuing behind a full community is allowed —
      // the seat is re-checked at approval time, which is where it can actually be refused.
      if (landState === 'active' && community.member_count >= community.max_members) {
        await client.query('rollback');
        return res.status(409).json({
          error: 'this community is full',
          max_members: community.max_members,
        });
      }

      let redeemedToken: string | null = null;
      if (inviteToken) {
        const redeemed = (
          await client.query<{ community_id: string }>(
            `update community_invites set use_count = use_count + 1
              where token = $1 and revoked_at is null
                and (expires_at is null or expires_at > now())
                and (max_uses  is null or use_count < max_uses)
              returning community_id`,
            [inviteToken]
          )
        ).rows[0];
        // No row returned == invalid link. Also refuse a live token minted for a DIFFERENT
        // community — otherwise any valid token anywhere is a skeleton key for invite_only.
        if (!redeemed || redeemed.community_id !== communityId) {
          await client.query('rollback');
          if (community.join_policy === 'invite_only') {
            return res.status(403).json({ error: 'this invite link is no longer valid' });
          }
          return res.status(400).json({ error: 'this invite link is no longer valid' });
        }
        redeemedToken = inviteToken;
      }

      // Rejoin after leaving is an upsert on a NULL-FREE pk — (community_id, user_id) — so
      // ON CONFLICT actually matches. A nullable column in the conflict target is the bug
      // 027_receipt_null_device.sql exists to fix: the upsert silently becomes a second
      // INSERT and fails on the pk instead.
      //
      // `role` is deliberately NOT overwritten: promotion and demotion belong to the admin
      // endpoints, and a rejoin must neither silently promote nor silently demote.
      await client.query(
        `insert into community_members (community_id, user_id, role, state, invited_via, joined_at, left_at)
              values ($1, $2, 'member', $3, $4, now(), null)
         on conflict (community_id, user_id) do update
                set state       = excluded.state,
                    joined_at   = now(),
                    left_at     = null,
                    invited_via = coalesce(excluded.invited_via, community_members.invited_via)`,
        [communityId, user_id, landState, redeemedToken]
      );

      // Server-side channel membership, in ONE statement over the channel set rather than a
      // query per channel (item 3.20: no per-recipient loops on a join path). The CLIENT then
      // completes the cryptographic half via /mls — see the header.
      let channelIds: string[] = [];
      if (landState === 'active') {
        const inserted = await client.query<{ conversation_id: string }>(
          `insert into conversation_members (conversation_id, user_id, role)
                select ch.conversation_id, $2, 'member'
                  from community_channels ch
                 where ch.community_id = $1
           on conflict (conversation_id, user_id) do update set left_at = null
             returning conversation_id`,
          [communityId, user_id]
        );
        channelIds = inserted.rows.map((r) => r.conversation_id);
      }

      await client.query('commit');

      if (landState === 'active') {
        void publishMembershipNotice(communityId, user_id, 'community_member_joined', channelIds);
      }
      return res.json({
        community_id: communityId,
        state: landState,
        existed: false,
        channels: landState === 'active' ? await channelsOf(communityId) : [],
      });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  })
);

// POST /communities/:id/leave
//
// Sets state='left' rather than deleting the row: the row is what makes a ban survive a leave
// (leave-and-rejoin must not be a way around moderation) and what makes the rejoin above a
// clean upsert. 030 flags that retained row as a retention surface with an open [COUNSEL]
// question in docs/research/11_admin_dpdp.md §6 — how long it may be kept is not settled
// here, and this route must not pretend otherwise by pruning on its own schedule.
//
// The OWNER cannot leave. Their row is the target of the host-DM exception and the authority
// on who the host is; a community whose owner walked out would have no reachable host and no
// one who can appoint one. Ownership transfer is the product answer and does not exist yet,
// so this is an honest 400 rather than a broken container.
router.post(
  '/:id/leave',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });

    const community = (
      await query<{ owner_id: string }>(`select owner_id from communities where id = $1`, [communityId])
    )[0];
    if (!community) return res.status(404).json({ error: 'no such community' });
    if (community.owner_id === user_id) {
      return res.status(400).json({ error: 'the owner cannot leave their own community' });
    }

    const client = await pool.connect();
    try {
      await client.query('begin');
      const updated = (
        await client.query(
          `update community_members set state = 'left', left_at = now()
            where community_id = $1 and user_id = $2 and state in ('active', 'pending')`,
          [communityId, user_id]
        )
      ).rowCount;
      if (!updated) {
        await client.query('rollback');
        return res.json({ left: false });
      }

      // Drop out of every channel in one statement. The MLS removal Commit that
      // cryptographically evicts them is issued by a remaining member's client, exactly as
      // conversations.ts documents for group removal — the server holds no group state and
      // could not produce it.
      const removed = await client.query<{ conversation_id: string }>(
        `update conversation_members set left_at = now()
          where user_id = $2 and left_at is null
            and conversation_id in (select conversation_id from community_channels where community_id = $1)
          returning conversation_id`,
        [communityId, user_id]
      );
      await client.query('commit');

      void publishMembershipNotice(
        communityId,
        user_id,
        'community_member_left',
        removed.rows.map((r) => r.conversation_id)
      );
      return res.json({ left: true });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  })
);

// ═════════════════════════════════════════════════════════════════════════════════
// MEMBERSHIP ADMINISTRATION
// ═════════════════════════════════════════════════════════════════════════════════

// GET /communities/:id/members?state=&limit=&offset=
//
// MEMBER-ONLY. The roster is server-readable (030 says so plainly) but that does not make it
// public: who is in a space is exactly the kind of metadata a stranger should not be able to
// enumerate. `state=pending` is narrower still — the moderation queue is owner/admin only.
router.get(
  '/:id/members',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });

    const state = String(req.query.state ?? 'active');
    if (!['active', 'pending', 'banned', 'left'].includes(state)) {
      return res.status(400).json({ error: 'unknown state filter' });
    }

    const me = await membershipOf(communityId, user_id);
    const community = (
      await query<{ owner_id: string }>(`select owner_id from communities where id = $1`, [communityId])
    )[0];
    if (!community) return res.status(404).json({ error: 'no such community' });

    const isManager = community.owner_id === user_id || (me?.state === 'active' && me.role === 'admin');
    if (state !== 'active' && !isManager) {
      return res.status(403).json({ error: 'only the owner or an admin can do that' });
    }
    if (me?.state !== 'active' && !isManager) {
      return res.status(403).json({ error: 'only members can see the roster' });
    }

    const limit = clampInt(req.query.limit, MEMBER_PAGE_DEFAULT, MEMBER_PAGE_MAX);
    const offset = Math.max(0, Number(req.query.offset) || 0);
    const rows = await query(
      `select m.user_id, m.role, m.state, m.joined_at,
              u.full_name, u.username, u.photo_url
         from community_members m
         join users u on u.id = m.user_id
        where m.community_id = $1 and m.state = $2 and u.deleted_at is null
        order by m.joined_at desc
        limit $3 offset $4`,
      [communityId, state, limit, offset]
    );
    res.json({ members: rows, limit, offset });
  })
);

/**
 * Move one member's state, with the cap re-checked whenever the move takes a seat.
 *
 * Approve (pending -> active) is a JOIN in everything but name: it takes a seat and puts the
 * person into every channel, so it goes through the same locked cap check the join route
 * uses. Approving past the cap would be the same melt by a slower road.
 */
async function setMemberState(
  communityId: string,
  targetUserId: string,
  next: 'active' | 'left' | 'banned'
): Promise<{ status: number; body: Record<string, unknown> }> {
  const client = await pool.connect();
  try {
    await client.query('begin');
    const community = (
      await client.query<CommunityRow>(
        `select ${COMMUNITY_COLUMNS} from communities where id = $1 for update`,
        [communityId]
      )
    ).rows[0];
    if (!community) {
      await client.query('rollback');
      return { status: 404, body: { error: 'no such community' } };
    }
    // The owner is not moderatable. Banning the person the host-DM exception points at would
    // leave the community with no reachable host, and idx_community_one_owner would refuse
    // the follow-up anyway.
    if (community.owner_id === targetUserId) {
      await client.query('rollback');
      return { status: 400, body: { error: 'the owner cannot be removed or banned' } };
    }

    const current = (
      await client.query<Membership>(
        `select role, state from community_members where community_id = $1 and user_id = $2`,
        [communityId, targetUserId]
      )
    ).rows[0];
    if (!current) {
      await client.query('rollback');
      return { status: 404, body: { error: 'that person is not in this community' } };
    }

    if (next === 'active') {
      if (current.state === 'active') {
        await client.query('rollback');
        return { status: 200, body: { state: 'active', changed: false } };
      }
      if (current.state === 'banned') {
        await client.query('rollback');
        return { status: 400, body: { error: 'unban this person before approving them' } };
      }
      if (community.member_count >= community.max_members) {
        await client.query('rollback');
        return {
          status: 409,
          body: { error: 'this community is full', max_members: community.max_members },
        };
      }
    }

    // Two statements rather than one with CASE on a bind parameter: the caller already knows
    // which way this goes, and `community_members_active_not_left` (030) refuses an active row
    // that still carries a left_at — so which column gets now() is not a detail to compute in
    // SQL from a parameter Postgres has to infer a type for.
    if (next === 'active') {
      await client.query(
        `update community_members set state = 'active', left_at = null, joined_at = now()
          where community_id = $1 and user_id = $2`,
        [communityId, targetUserId]
      );
    } else {
      await client.query(
        `update community_members set state = $3, left_at = now()
          where community_id = $1 and user_id = $2`,
        [communityId, targetUserId, next]
      );
    }

    let channelIds: string[] = [];
    if (next === 'active') {
      const added = await client.query<{ conversation_id: string }>(
        `insert into conversation_members (conversation_id, user_id, role)
              select ch.conversation_id, $2, 'member'
                from community_channels ch
               where ch.community_id = $1
         on conflict (conversation_id, user_id) do update set left_at = null
           returning conversation_id`,
        [communityId, targetUserId]
      );
      channelIds = added.rows.map((r) => r.conversation_id);
    } else {
      const dropped = await client.query<{ conversation_id: string }>(
        `update conversation_members set left_at = now()
          where user_id = $2 and left_at is null
            and conversation_id in (select conversation_id from community_channels where community_id = $1)
          returning conversation_id`,
        [communityId, targetUserId]
      );
      channelIds = dropped.rows.map((r) => r.conversation_id);
    }

    await client.query('commit');
    void publishMembershipNotice(
      communityId,
      targetUserId,
      next === 'active' ? 'community_member_joined' : 'community_member_left',
      channelIds
    );
    return { status: 200, body: { state: next, changed: true } };
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }
}

// POST /communities/:id/members/:userId/approve — pending -> active (owner/admin).
router.post(
  '/:id/members/:userId/approve',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });
    const target = String(req.params.userId ?? '');
    if (!UUID_RE.test(target)) return res.status(400).json({ error: 'user id must be a uuid' });

    const out = await setMemberState(gate.community.id, target, 'active');
    res.status(out.status).json(out.body);
  })
);

// POST /communities/:id/members/:userId/remove — active|pending -> left (owner/admin).
// A removal is reversible by rejoining; a ban is not. Keeping them as separate verbs means a
// moderator has to choose the harsher one on purpose.
router.post(
  '/:id/members/:userId/remove',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });
    const target = String(req.params.userId ?? '');
    if (!UUID_RE.test(target)) return res.status(400).json({ error: 'user id must be a uuid' });
    if (target === user_id) return res.status(400).json({ error: 'use leave to remove yourself' });

    const out = await setMemberState(gate.community.id, target, 'left');
    res.status(out.status).json(out.body);
  })
);

// POST /communities/:id/members/:userId/ban — refuse re-entry until lifted (owner/admin).
router.post(
  '/:id/members/:userId/ban',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });
    const target = String(req.params.userId ?? '');
    if (!UUID_RE.test(target)) return res.status(400).json({ error: 'user id must be a uuid' });
    if (target === user_id) return res.status(400).json({ error: 'you cannot ban yourself' });

    // An admin banning another admin would be a moderation civil war; only the owner may act
    // on someone who holds the same powers.
    const targetRole = (await membershipOf(gate.community.id, target))?.role;
    if (targetRole === 'admin' && gate.role !== 'owner') {
      return res.status(403).json({ error: 'only the owner can ban an admin' });
    }

    const out = await setMemberState(gate.community.id, target, 'banned');
    res.status(out.status).json(out.body);
  })
);

// POST /communities/:id/members/:userId/unban — banned -> left, i.e. "may apply again".
//
// NOT straight to active: lifting a ban restores the right to ask, not membership itself.
// Sending them to 'left' means the ordinary join route runs again, with the cap check and the
// join policy applied — which is where those rules belong.
router.post(
  '/:id/members/:userId/unban',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });
    const target = String(req.params.userId ?? '');
    if (!UUID_RE.test(target)) return res.status(400).json({ error: 'user id must be a uuid' });

    const changed = await query(
      `update community_members set state = 'left'
        where community_id = $1 and user_id = $2 and state = 'banned'
        returning user_id`,
      [gate.community.id, target]
    );
    res.json({ state: 'left', changed: changed.length > 0 });
  })
);

// POST /communities/:id/members/:userId/role   { role: 'admin' | 'member' }
//
// OWNER ONLY, and 'owner' is not an assignable value. Ownership is a transfer, not a grant:
// idx_community_one_owner forbids two owner rows, so it has to be demote-then-promote in one
// transaction, and that endpoint does not exist yet. Letting this route write 'owner' would
// mean discovering the constraint as a 500 in production.
router.post(
  '/:id/members/:userId/role',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });
    if (gate.role !== 'owner') return res.status(403).json({ error: 'only the owner can change roles' });

    const target = String(req.params.userId ?? '');
    if (!UUID_RE.test(target)) return res.status(400).json({ error: 'user id must be a uuid' });
    if (target === user_id) return res.status(400).json({ error: 'you already own this community' });

    const role = String(req.body?.role ?? '');
    if (role !== 'admin' && role !== 'member') {
      return res.status(400).json({ error: "role must be 'admin' or 'member'" });
    }

    const updated = await query(
      `update community_members set role = $3
        where community_id = $1 and user_id = $2 and state = 'active' and role <> 'owner'
        returning user_id`,
      [gate.community.id, target, role]
    );
    if (!updated.length) return res.status(404).json({ error: 'that person is not an active member' });

    // Community role and conversation role are separate vocabularies, and both have to move:
    // the community role governs announcement posting (see communityGuard.ts) while the
    // conversation role is what conversations.ts checks for add/remove inside one channel.
    await query(
      `update conversation_members set role = $3
        where user_id = $2
          and conversation_id in (select conversation_id from community_channels where community_id = $1)`,
      [gate.community.id, target, role === 'admin' ? 'admin' : 'member']
    );
    res.json({ role, changed: true });
  })
);

// ═════════════════════════════════════════════════════════════════════════════════
// THE CONTAINER + ITS CHANNELS
// ═════════════════════════════════════════════════════════════════════════════════

// PATCH /communities/:id   { name?, description?, avatar_r2_key?, discoverable?, join_policy? }
//
// The handle is NOT editable here. Renaming a handle breaks every printed invite link and
// every pasted URL, and 029 already established that renames need history rows and rate
// limiting to be done honestly — that is its own endpoint and its own migration, not a field
// quietly accepted by a general PATCH.
//
// `max_members` is not editable either; see the note at the top of this file.
router.patch(
  '/:id',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

    const body = req.body ?? {};
    const sets: string[] = [];
    const params: unknown[] = [gate.community.id];
    const push = (sql: string, value: unknown) => {
      params.push(value);
      sets.push(`${sql} = $${params.length}`);
    };

    if (body.name !== undefined) {
      const name = trimmed(body.name, MAX_NAME);
      if (!name) return res.status(400).json({ error: 'name cannot be empty' });
      push('name', name);
    }
    // `description: null` clears it; an absent key leaves it alone. The two have to be
    // distinguishable or there is no way to remove a description once written.
    if (body.description !== undefined) push('description', trimmed(body.description, MAX_DESCRIPTION));
    if (body.avatar_r2_key !== undefined) push('avatar_r2_key', trimmed(body.avatar_r2_key, 400));
    if (body.discoverable !== undefined) push('discoverable', body.discoverable === true);
    if (body.join_policy !== undefined) {
      const jp = String(body.join_policy);
      if (!['open', 'approval', 'invite_only'].includes(jp)) {
        return res.status(400).json({ error: 'join_policy must be open, approval or invite_only' });
      }
      push('join_policy', jp);
    }
    if (!sets.length) return res.status(400).json({ error: 'nothing to update' });

    const rows = await query<CommunityRow>(
      `update communities set ${sets.join(', ')} where id = $1 returning ${COMMUNITY_COLUMNS}`,
      params
    );
    // Deleted between the authorisation read and the write. 404, not a crash in publicCard.
    if (!rows[0]) return res.status(404).json({ error: 'no such community' });
    res.json({ community: await publicCard(rows[0]) });
  })
);

// GET /communities/:id/channels — the Spaces list.
//
// Channels could be CREATED and never LISTED, so the client had no way to render Spaces at
// all. The name lives on the conversation (community_channels carries only the link, the kind
// and the order), which is why this joins rather than selecting one table.
//
// Members only. A non-member learning a community's channel names tells them what is
// discussed inside it, which is exactly what a private community is withholding.
router.get(
  '/:id/channels',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });

    const me = await membershipOf(communityId, user_id);
    const community = (
      await query<{ owner_id: string }>(`select owner_id from communities where id = $1`, [communityId])
    )[0];
    if (!community) return res.status(404).json({ error: 'no such community' });
    const isOwner = community.owner_id === user_id;
    if (!isOwner && me?.state !== 'active') {
      return res.status(403).json({ error: 'only members can see this community\u2019s Spaces' });
    }

    // channelsOf already exists and is used elsewhere — one query, one place to fix.
    res.json({ channels: await channelsOf(communityId) });
  })
);

// POST /communities/:id/channels   { name, kind? }
//
// A new channel is a new MLS group that EVERY ACTIVE MEMBER is put into — which is why the
// count is capped (item 3.20: the fan-out cost is members x channels, and only one of those
// two factors is bounded by the schema) and why the member insert is a single INSERT ... SELECT
// over the roster rather than a loop of 512 statements.
//
// Only ONE announcement channel is allowed, enforced by idx_community_one_announcement rather
// than by this route remembering to check: a second one would double the fan-out cost of
// every join for no product reason and make "the announcement channel" ambiguous for the
// "ask host about this" reply flow.
router.post(
  '/:id/channels',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

    const name = trimmed(req.body?.name, MAX_CHANNEL_NAME);
    if (!name) return res.status(400).json({ error: 'name is required' });
    const kind = String(req.body?.kind ?? 'chat');
    if (kind !== 'chat' && kind !== 'announcement') {
      return res.status(400).json({ error: "kind must be 'chat' or 'announcement'" });
    }

    const existing = await channelsOf(gate.community.id);
    if (existing.length >= MAX_CHANNELS_PER_COMMUNITY) {
      return res.status(409).json({
        error: `a community can have at most ${MAX_CHANNELS_PER_COMMUNITY} channels`,
      });
    }
    const position = existing.reduce((max, c) => Math.max(max, c.position), -1) + 1;

    const client = await pool.connect();
    try {
      await client.query('begin');
      const conv = (
        await client.query<{ id: string }>(
          `insert into conversations (type, name, created_by) values ('group', $1, $2) returning id`,
          [name, user_id]
        )
      ).rows[0];
      await client.query(
        `insert into community_channels (conversation_id, community_id, kind, position)
              values ($1, $2, $3, $4)`,
        [conv.id, gate.community.id, kind, position]
      );
      // ONE statement for the whole roster. Community owner/admins land as conversation
      // admins so the existing group-management endpoints keep working inside the channel.
      const added = await client.query(
        `insert into conversation_members (conversation_id, user_id, role)
              select $1, m.user_id,
                     case when m.role in ('owner', 'admin') then 'admin' else 'member' end
                from community_members m
               where m.community_id = $2 and m.state = 'active'
         on conflict (conversation_id, user_id) do nothing`,
        [conv.id, gate.community.id]
      );
      await client.query('commit');
      return res.status(201).json({
        channel: { conversation_id: conv.id, kind, position, name },
        members_added: added.rowCount ?? 0,
      });
    } catch (e) {
      await client.query('rollback');
      if (isUniqueViolation(e)) {
        return res.status(409).json({ error: 'this community already has an announcement channel' });
      }
      throw e;
    } finally {
      client.release();
    }
  })
);

// PATCH /communities/:id/channels/:conversationId   { name?, position? }
router.patch(
  '/:id/channels/:conversationId',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });
    const conversationId = String(req.params.conversationId ?? '');
    if (!UUID_RE.test(conversationId)) return res.status(400).json({ error: 'channel id must be a uuid' });

    // conversation_id is the pk of community_channels, so this both authorises and locates in
    // one probe — and proves the channel belongs to THIS community rather than another one
    // the caller also administers.
    const link = (
      await query<{ kind: string }>(
        `select kind from community_channels where conversation_id = $1 and community_id = $2`,
        [conversationId, gate.community.id]
      )
    )[0];
    if (!link) return res.status(404).json({ error: 'no such channel in this community' });

    const name = req.body?.name !== undefined ? trimmed(req.body.name, MAX_CHANNEL_NAME) : undefined;
    if (name === null) return res.status(400).json({ error: 'name cannot be empty' });
    const position =
      req.body?.position !== undefined ? Math.trunc(Number(req.body.position)) : undefined;
    if (position !== undefined && !Number.isFinite(position)) {
      return res.status(400).json({ error: 'position must be a number' });
    }

    if (name !== undefined) {
      await query(`update conversations set name = $2 where id = $1`, [conversationId, name]);
    }
    if (position !== undefined) {
      await query(`update community_channels set position = $2 where conversation_id = $1`, [
        conversationId,
        position,
      ]);
    }
    res.json({ updated: true });
  })
);

// DELETE /communities/:id/channels/:conversationId
//
// Deletes the conversation, which cascades the messages — this is destructive for every
// member, not just the caller, so it is owner/admin only and refuses the announcement
// channel outright. The announcement channel is the one every member is auto-joined to and
// the one the "ask host about this" flow quotes from; deleting it would break both while
// looking like tidying up. Recreate it deliberately if it really has to go.
router.delete(
  '/:id/channels/:conversationId',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });
    const conversationId = String(req.params.conversationId ?? '');
    if (!UUID_RE.test(conversationId)) return res.status(400).json({ error: 'channel id must be a uuid' });

    const link = (
      await query<{ kind: string }>(
        `select kind from community_channels where conversation_id = $1 and community_id = $2`,
        [conversationId, gate.community.id]
      )
    )[0];
    if (!link) return res.status(404).json({ error: 'no such channel in this community' });
    if (link.kind === 'announcement') {
      return res.status(400).json({ error: 'the announcement channel cannot be deleted' });
    }
    const remaining = await channelsOf(gate.community.id);
    if (remaining.length <= 1) {
      return res.status(400).json({ error: 'a community must keep at least one channel' });
    }

    // Deleting the conversation cascades community_channels, conversation_members and the
    // messages. One statement, and the FK graph does the rest.
    await query(`delete from conversations where id = $1`, [conversationId]);
    res.json({ deleted: true });
  })
);

// ═════════════════════════════════════════════════════════════════════════════════
// INVITE LINKS
// ═════════════════════════════════════════════════════════════════════════════════

// POST /communities/:id/invites   { expires_in_hours?, max_uses? }
//
// The token is 32 bytes of CSPRNG output in base64url (43 chars, inside the 22..64 the schema
// allows). UNGUESSABLE IS THE ENTIRE SECURITY PROPERTY — this is a bearer capability, so it
// must never be derived from a counter, a timestamp or a uuid (a v4 uuid carries 122 bits and
// looks guessable to anyone who has seen one).
//
// Unlike Signal's group links, no key material rides in the URL: Voiid's roster is
// server-visible by design, so there is no encrypted group state for a fragment to protect —
// and a server-side capability is the one that can actually be REVOKED.
router.post(
  '/:id/invites',
  requireAuth,
  // A bearer capability, so minting is throttled: a script that can produce unlimited live
  // tokens turns "revocable" into a formality, because there is always another link.
  rateLimit({ max: 30, windowSeconds: 3600, bucket: 'community-invite-mint' }),
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

    const hours = req.body?.expires_in_hours;
    let expiresAt: string | null = null;
    if (hours !== undefined && hours !== null) {
      const n = Number(hours);
      if (!Number.isFinite(n) || n <= 0 || n > 24 * 365) {
        return res.status(400).json({ error: 'expires_in_hours must be between 1 and 8760' });
      }
      expiresAt = new Date(Date.now() + n * 3600_000).toISOString();
    }
    let maxUses: number | null = null;
    if (req.body?.max_uses !== undefined && req.body.max_uses !== null) {
      const n = Math.trunc(Number(req.body.max_uses));
      // community_invites_max_uses_positive would reject <= 0 as a 500; catch it here.
      if (!Number.isFinite(n) || n <= 0) {
        return res.status(400).json({ error: 'max_uses must be a positive integer' });
      }
      maxUses = n;
    }

    const token = randomBytes(32).toString('base64url');
    const rows = await query(
      `insert into community_invites (token, community_id, created_by, expires_at, max_uses)
            values ($1, $2, $3, $4, $5)
       returning token, expires_at, max_uses, use_count, created_at`,
      [token, gate.community.id, user_id, expiresAt, maxUses]
    );
    res.status(201).json({
      invite: rows[0],
      // Built here so both clients and the admin panel produce the identical link shape and
      // nobody has to reimplement it (item 3.21 handles the receiving end).
      url: `https://voiid.app/c/${gate.community.handle}?i=${token}`,
    });
  })
);

// GET /communities/:id/invites — the manage-links screen (owner/admin). Live links only.
router.get(
  '/:id/invites',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

    const rows = await query(
      `select token, created_by, expires_at, max_uses, use_count, created_at
         from community_invites
        where community_id = $1 and revoked_at is null
        order by created_at desc
        limit 100`,
      [gate.community.id]
    );
    res.json({
      invites: rows.map((r: any) => ({
        ...r,
        url: `https://voiid.app/c/${gate.community.handle}?i=${r.token}`,
      })),
    });
  })
);

// DELETE /communities/:id/invites/:token — revoke.
//
// A timestamp, not a delete: a revoked link stays auditable ("which link brought the spam"),
// and community_members.invited_via keeps pointing at something real.
router.delete(
  '/:id/invites/:token',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const gate = await requireManager(String(req.params.id ?? ''), user_id);
    if (!gate.ok) return res.status(gate.status).json({ error: gate.error });

    const revoked = await query(
      `update community_invites set revoked_at = now()
        where token = $1 and community_id = $2 and revoked_at is null
        returning token`,
      [String(req.params.token ?? ''), gate.community.id]
    );
    res.json({ revoked: revoked.length > 0 });
  })
);

export default router;
