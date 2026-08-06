-- 030_communities.sql — Communities: a server-side container holding N E2EE channels.
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- Same scoped exception as 022_clips.sql and 029_creator_profiles.sql, made again here
-- for the container and ONLY for the container. Stated plainly, surface by surface:
--
--   Channel messages (incl. announcements) .. E2EE, MLS (011). Unchanged by this file.
--   Member <-> host private DM ............... E2EE, Double Ratchet (006). Unchanged.
--   Name / description / avatar / handle ..... SERVER-READABLE. It is shown to people who
--                                              are NOT members and have not joined; that is
--                                              broadcast identity, the same argument as 029.
--   Search / discovery index ................. SERVER-READABLE. The server cannot match a
--                                              query against a name it cannot read.
--   Member roster + roles .................... SERVER-READABLE. The server gates joins,
--                                              enforces admin-only endpoints, and fans MLS
--                                              Welcome/Commit out per member — it necessarily
--                                              knows who is in. Audience-as-metadata, the
--                                              stance already taken in 017_stories.sql.
--   Invite-link tokens ....................... SERVER-READABLE by construction: a revocable
--                                              server-side capability (see the table below).
--   Tournaments / events / tickets (later) ... SERVER-READABLE, per 024_games.sql for match
--                                              state, and because money needs an external
--                                              processor, webhooks, refunds and tax records.
--                                              A ticket the server cannot read cannot be
--                                              validated at the door or refunded.
--
-- WHY THE CONTAINER CANNOT BE A CONVERSATION: an outsider must be able to read the info card
-- BEFORE joining, and `GET /conversations/:id` is member-only by design. Encrypting a card
-- whose whole purpose is to be shown to strangers is not a thing that can be done.
--
-- Messages, calls, locations and moments are UNAFFECTED and remain end-to-end encrypted.
-- Nothing in this file is a precedent for weakening any of them.
-- =================================================================================
--
-- ── THE CENTRAL RULE, RESTATED: JOINING IS NOT A MESSAGING RIGHT ─────────────────
--
-- 020_reachability.sql defines exactly three ways to open a conversation: mutual contacts,
-- a one-way contact (as a request), or @username + the 6-digit contact PIN (as a request).
-- 029_creator_profiles.sql says any code reading the public graph to authorise a message is
-- a bug, not a feature. Community membership is a public graph.
--
-- This file adds ONE narrow fourth path, and it is member -> COMMUNITY OWNER only
-- (`community_host_threads` + `opened_via = 'community'`). Joining a space is consent to be
-- asked questions by its members; it is NOT consent to be messaged by every other member.
-- A 5,000-member community must not become 5,000 mutual messaging rights — that is a spam
-- amplifier with a friendly name.
--
-- The scope rule is enforced STRUCTURALLY, not by convention: `community_host_threads` has
-- no column capable of naming a second member. There is no way to write a member->member row
-- into it, so widening this exception requires a migration and a review, not a one-line diff
-- in a route. Keep it that way.
--
-- ── WHAT IS DELIBERATELY NOT IN THIS FILE ────────────────────────────────────────
--
-- Tournaments and events/orders/tickets get their own migrations; nothing about them is
-- created here. This schema is shaped so they bolt on without a rewrite — see the PHASE-2
-- HOOKS note at the bottom for exactly which decisions above are load-bearing for that.

-- ─────────────────────────────────────────────────────────────────────────────────
-- The container
--
-- One row per community. Everything an outsider is allowed to see before joining lives here
-- and nowhere else, so the "public card" query is one primary-key or one handle lookup and
-- never touches the roster or the channels.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists communities (
    -- CLIENT-supplied, like clips (022) and unlike conversations (005). Creation is a
    -- multi-step transaction — container + two group conversations + channel rows + the
    -- owner's roster row — so a client that retries a timed-out POST must land on the same
    -- id or it silently creates a second, half-wired community. The pk is the idempotency
    -- key; there is deliberately no default to generate one server-side.
    id            uuid primary key,

    -- The authority on who the owner is. `community_members.role = 'owner'` mirrors this for
    -- cheap role checks, but THIS column is what the host-DM exception (3.18) must read: one
    -- unambiguous target, no join through a roster that a bug could return two rows from.
    -- ON DELETE CASCADE: account erasure (DPDP) must not be blocked by a container the user
    -- happens to own. The product answer is ownership TRANSFER before deletion; until that
    -- ships, deleting the owner deletes the container. The channel conversations survive as
    -- ordinary MLS groups (see community_channels) so members do not lose their history.
    owner_id      uuid not null references users(id) on delete cascade,

    -- Same grammar as users.username (010) and creator_profiles.handle (029), because those
    -- three share ONE namespace — see the trigger below. Printed on posters and in invite
    -- links (https://voiid.app/c/<handle>), so it is public by construction.
    handle        text not null,

    -- What renders in the directory. Separate from handle so it can carry spaces, capitals
    -- and non-Latin scripts; bounded in CHARACTERS, not bytes, so a Devanagari or CJK name
    -- gets the same allowance as a Latin one.
    name          text not null,
    description   text,
    -- R2 key, PLAINTEXT like creator avatars (029:88-90). NOT the E2EE profile photo from
    -- 021 — that one is encrypted to a known audience and must not be reused here.
    avatar_r2_key text,

    -- OPT-IN to search, false by default, the same stance 029 takes about not manufacturing
    -- public identity for people who did not ask for it. A community created for twelve
    -- friends must not turn up in a stranger's search because the creator never found a
    -- toggle. `false` also means link-only communities are the safe default (the WhatsApp
    -- shape) and open discovery is the deliberate act.
    discoverable  boolean not null default false,

    -- open        -> join lands 'active' immediately
    -- approval    -> join lands 'pending', an admin promotes it
    -- invite_only -> join requires a live community_invites token
    join_policy   text not null default 'open',

    -- DENORMALISED, trigger-maintained (see bump_community_member_count). Source of truth is
    -- community_members; this is the READ path. The directory shows a member count on every
    -- card and cannot afford a count(*) per card.
    member_count  int not null default 0,

    -- THE MLS FAN-OUT CAP, as a column so it can be raised per-community later, with a hard
    -- ceiling so it cannot be raised past what the plumbing survives. Every join Commits to
    -- the whole channel and mls_group_events takes ONE ROW PER RECIPIENT (011, mls.ts): at
    -- 5,000 members a single join writes thousands of rows plus a Redis publish each. 512 is
    -- the MVP number; the ceiling moves toward WhatsApp-order 1024 only after the KeyPackage
    -- consumption loop and the event insert loop are batched. ENFORCEMENT LIVES IN THE JOIN
    -- ROUTE — a check constraint cannot see the roster — but the ceiling here means no admin
    -- action, and no bad UPDATE, can set a number that melts the fan-out.
    max_members   int not null default 512,

    -- Reversible moderation, mirroring creator_profiles (029:108-111). Suspension hides the
    -- community from search and blocks joins without destroying the roster or the channels,
    -- so a wrongful suspension is undoable.
    suspended_at     timestamptz,
    suspended_reason text,

    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),

    constraint communities_handle_format
        check (handle ~ '^[a-z][a-z0-9_]{2,19}$'),
    constraint communities_name_len
        check (char_length(name) between 1 and 60),
    constraint communities_description_len
        check (description is null or char_length(description) <= 500),
    constraint communities_join_policy_check
        check (join_policy in ('open', 'approval', 'invite_only')),
    constraint communities_max_members_range
        check (max_members between 2 and 1024)
);

-- lower() for the same reason 010 and 029 do it: @Acme and @acme cannot be two communities.
-- The format check already forces lowercase; the index does not depend on it staying.
create unique index if not exists idx_communities_handle_lower
    on communities (lower(handle));

-- The directory listing: biggest first, only what a stranger may see. Partial so the index
-- carries only rows discovery can actually return.
create index if not exists idx_communities_discoverable
    on communities (member_count desc, id)
    where discoverable and suspended_at is null;

-- Prefix search on the handle ("@ac" -> @acme) over the same visible set.
--
-- WHAT THIS DOES NOT DO: substring search on `name` (ILIKE '%q%') cannot use a btree, so that
-- query degrades to a scan bounded by the partial predicate above — acceptable at MVP scale,
-- not at a million rows. The fix is a pg_trgm GIN index, and it is deliberately NOT created
-- here: `create extension pg_trgm` needs privileges the deploy-time migration runner is not
-- guaranteed to have, and a failed CREATE EXTENSION aborts the whole migration transaction.
-- It gets its own migration once the extension is confirmed present on the box.
create index if not exists idx_communities_handle_prefix
    on communities (lower(handle) text_pattern_ops)
    where discoverable and suspended_at is null;

drop trigger if exists trg_communities_updated_at on communities;
create trigger trg_communities_updated_at before update on communities
    for each row execute function set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────────
-- Invite links
--
-- Declared BEFORE the roster because a membership row points back at the link that produced
-- it (abuse forensics: "which link is bringing the spam").
--
-- WHY A PLAIN SERVER TOKEN AND NOT SIGNAL'S SCHEME: Signal puts the group master key and the
-- join password in the URL FRAGMENT, which never reaches its server, because Signal's group
-- STATE is encrypted too (zkgroup). Voiid's roster is server-visible by design — the server
-- gates joins and fans out MLS events per member — so there is no encrypted group state for a
-- fragment to protect. A server-side capability is simpler, honestly non-E2EE, and above all
-- REVOCABLE, which a key in a URL is not.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists community_invites (
    -- The token IS the pk: one indexed probe to resolve a link, and no separate id to leak.
    -- 32 bytes of CSPRNG output, base64url — unguessable is the entire security property, so
    -- the API must mint this with crypto random bytes and never a counter, timestamp or uuid
    -- (a v4 uuid is only 122 bits and looks guessable to anyone who has seen one).
    token        text primary key,
    community_id uuid not null references communities(id) on delete cascade,

    -- NULLABLE, ON DELETE SET NULL: the link is a property of the community, not of the
    -- moderator who minted it. Erasing that person's account (DPDP) must remove the personal
    -- reference without silently revoking every live invite the community depends on.
    created_by   uuid references users(id) on delete set null,

    -- All three limits are optional and independent; null means "no limit on this axis".
    expires_at   timestamptz,
    max_uses     int,
    use_count    int not null default 0,
    -- Revocation is a timestamp, not a delete, so a revoked link stays auditable and a
    -- re-mint of the same random token (astronomically unlikely) still cannot resurrect it.
    revoked_at   timestamptz,
    created_at   timestamptz not null default now(),

    constraint community_invites_token_len
        check (char_length(token) between 22 and 64),
    constraint community_invites_max_uses_positive
        check (max_uses is null or max_uses > 0),
    constraint community_invites_use_count_nonneg
        check (use_count >= 0)
);

-- "Show me this community's live links" — the manage-invites screen.
create index if not exists idx_community_invites_live
    on community_invites (community_id, created_at desc)
    where revoked_at is null;

-- REDEMPTION MUST BE ONE STATEMENT, not select-then-update. Two clients redeeming the last
-- use of a max_uses=1 link concurrently will both pass a SELECT check and both join. The
-- join route must spend the use with a single conditional UPDATE that returns the row:
--
--   update community_invites set use_count = use_count + 1
--    where token = $1 and revoked_at is null
--      and (expires_at is null or expires_at > now())
--      and (max_uses  is null or use_count < max_uses)
--   returning community_id;
--
-- No row returned == invalid link. The row lock the UPDATE takes is what serialises the race.

-- ─────────────────────────────────────────────────────────────────────────────────
-- The roster
--
-- PRIMARY KEY (community_id, user_id) — both NOT NULL by virtue of being in a pk. This is not
-- cosmetic: a NULL anywhere in a unique constraint makes ON CONFLICT never match, which turns
-- an upsert into a silent second INSERT (the bug 027_receipt_null_device.sql exists to fix).
-- Rejoin-after-leave is exactly the reinstate-on-conflict upsert that conversations.ts already
-- does for group members, so the conflict target has to be NULL-free.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists community_members (
    community_id uuid not null references communities(id) on delete cascade,
    user_id      uuid not null references users(id) on delete cascade,

    -- owner  -> exactly one, mirrors communities.owner_id (that column is the authority)
    -- admin  -> may post to announcement channels, approve/ban, mint invites
    -- member -> everything else
    role         text not null default 'member',

    -- active  -> in the community, counted, in the channels
    -- pending -> asked to join a join_policy='approval' community; NOT counted, NOT in any
    --            channel, and NOT eligible for the host-DM exception
    -- left    -> departed; row kept so a rejoin is an upsert and so bans survive leaves
    -- banned  -> refused re-entry until an admin lifts it
    --
    -- DEVIATION FROM THE PLAN SKETCH, on purpose: the sketch had state in
    -- ('active','pending','banned') PLUS a nullable left_at, which makes "has this person
    -- left?" answerable from two columns that can disagree. One enum is the truth; left_at is
    -- only the timestamp of the departure, and the check below forbids the contradiction.
    state        text not null default 'active',

    joined_at    timestamptz not null default now(),
    left_at      timestamptz,

    -- Which link brought them in, if any. ON DELETE SET NULL so revoking/pruning an invite
    -- never destroys a membership.
    invited_via  text references community_invites(token) on delete set null,

    primary key (community_id, user_id),

    constraint community_members_role_check
        check (role in ('owner', 'admin', 'member')),
    constraint community_members_state_check
        check (state in ('active', 'pending', 'left', 'banned')),
    -- An active member has not left. Prevents the two-sources-of-truth bug described above.
    constraint community_members_active_not_left
        check (state <> 'active' or left_at is null)
);

-- EXACTLY ONE OWNER ROW per community, enforced structurally rather than by hoping every
-- future admin endpoint remembers. Ownership transfer is demote-then-promote inside one
-- transaction; anything that would leave two owners fails loudly instead of producing a
-- community where two people can both be "the host" the member-DM exception points at.
create unique index if not exists idx_community_one_owner
    on community_members (community_id)
    where role = 'owner';

-- "Who is in this community", the roster screen and the MLS fan-out source. Partial: pending,
-- left and banned rows are a different, much rarer query.
create index if not exists idx_community_members_active
    on community_members (community_id, joined_at desc)
    where state = 'active';

-- "Which communities am I in" — drives the Communities tab and, critically, the membership
-- assertion the host-thread endpoint makes. Single probe on (user_id, community_id).
create index if not exists idx_community_members_user
    on community_members (user_id, community_id)
    where state = 'active';

-- The moderation queue: pending join requests for one community, oldest first.
create index if not exists idx_community_members_pending
    on community_members (community_id, joined_at asc)
    where state = 'pending';

-- ─────────────────────────────────────────────────────────────────────────────────
-- Channels
--
-- A channel is an ordinary `conversations` row of type 'group' — a real MLS group with real
-- E2EE, rendered by the GroupEngine both clients already ship. This table is only the LINK
-- that says which container it belongs to. No message content, no keys, nothing new to
-- encrypt: the container is metadata about E2EE rooms, not a weakening of them.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists community_channels (
    -- conversation_id AS THE PRIMARY KEY, so a conversation belongs to at most one community.
    -- This is what makes the announcement posting check (3.19) affordable: the message send
    -- path does ONE pk probe that returns zero or one row, so ordinary 1:1 and group sends
    -- pay a single index lookup and nothing else.
    conversation_id uuid primary key references conversations(id) on delete cascade,
    community_id    uuid not null references communities(id) on delete cascade,

    -- announcement -> owner/admin may post; every member may read. MLS CANNOT ENFORCE THIS:
    --                 it grants every member both decrypt AND send capability, so posting
    --                 rights are a server-side role check in the send path or they do not
    --                 exist. The UI hiding the composer is decoration.
    -- chat         -> everybody posts.
    kind            text not null default 'chat',
    -- Display order in the channel list. Not unique: reordering by rewriting one row must not
    -- have to renumber the others.
    position        int not null default 0,
    created_at      timestamptz not null default now(),

    constraint community_channels_kind_check
        check (kind in ('announcement', 'chat'))
);

-- The channel list for one community, in display order.
create index if not exists idx_community_channels_list
    on community_channels (community_id, position, created_at);

-- AT MOST ONE announcement channel per community. Every member is auto-joined to it, so a
-- second one doubles the MLS fan-out cost of every join for no product reason, and makes
-- "the announcement channel" ambiguous for the "ask host about this" reply flow.
create unique index if not exists idx_community_one_announcement
    on community_channels (community_id)
    where kind = 'announcement';

-- ─────────────────────────────────────────────────────────────────────────────────
-- The member -> host private line  (THE SCOPED REACHABILITY EXCEPTION)
--
-- One 1:1 conversation per (community, member), pointing at the community OWNER. The
-- conversation itself is an ordinary Double-Ratchet direct chat — ZERO NEW CRYPTOGRAPHY, the
-- server sees ciphertext exactly as it does for every other 1:1. What is new is only the
-- AUTHORISATION to open it, recorded here.
--
-- READ THE COLUMN LIST. There is no `peer_user_id`. The other end is not a parameter — it is
-- always the owner of `community_id`, resolved from communities.owner_id at creation time.
-- That is the point: a route CANNOT be edited to let member A open a thread with member B,
-- because this table has nowhere to put B. Widening the exception requires a migration, which
-- requires a review, which is the only reliable defence against the failure mode 029:13-23
-- describes — a social graph quietly becoming a messaging graph.
--
-- WHY NO host_user_id COLUMN: the two participants are already on the conversation's
-- membership rows, and a second user column here is precisely the shape that would make
-- member->member expressible. If ownership transfers, the existing thread keeps working (it
-- is just a 1:1 between two people) and the NEXT thread opens against the new owner.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists community_host_threads (
    community_id    uuid not null references communities(id) on delete cascade,
    member_user_id  uuid not null references users(id) on delete cascade,
    conversation_id uuid not null references conversations(id) on delete cascade,
    created_at      timestamptz not null default now(),

    -- IDEMPOTENCY: "message the host" pressed twice, or pressed on two devices at once, must
    -- reuse the one thread rather than mint a second. NULL-free pk so the upsert's ON CONFLICT
    -- actually matches (027 again).
    primary key (community_id, member_user_id),

    -- One conversation is the host thread for at most one (community, member) pair. Stops a
    -- pre-existing direct chat from being retro-labelled as several communities' host threads.
    unique (conversation_id)
);

-- The host's inbox: "all the people asking me about this community", newest first.
create index if not exists idx_host_threads_community
    on community_host_threads (community_id, created_at desc);

-- ─────────────────────────────────────────────────────────────────────────────────
-- Widen the reachability gate by exactly one value
--
-- 020 constrained opened_via to ('contact','username') — the three documented paths. Adding
-- 'community' makes the fourth path SAY SO on the membership row, which is what lets the host
-- group these into a "Community" inbox section and what lets an audit answer "how did this
-- stranger get into my chat list?" honestly.
--
-- The constraint is the ledger, not the gate. The gate is the host-thread endpoint asserting
-- an active membership and targeting communities.owner_id; this value only records that it
-- happened. Do not read it as permission.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table conversation_members
    drop constraint if exists conversation_members_opened_via_check;
alter table conversation_members
    add constraint conversation_members_opened_via_check
    check (opened_via is null or opened_via in ('contact', 'username', 'community'));

-- ─────────────────────────────────────────────────────────────────────────────────
-- One namespace, now three tables
--
-- 029 established "separate meaning, one pool of names": taking @nehal as a creator makes it
-- unavailable as a chat username and vice versa, because "@acme" meaning two different things
-- in two parts of one app is an impersonation vector. Community handles join that pool —
-- they are the most public name of the three (they go in invite links people paste into other
-- apps), so they are exactly the names worth squatting.
--
-- THE ASYMMETRY, and why it is right: users <-> creator_profiles excludes the row's own owner,
-- because those two rows are the SAME HUMAN — the person holding username @nehal may take
-- creator handle @nehal. A community is a DIFFERENT ENTITY from its owner, so no exclusion
-- applies in either direction: if @acme resolves to a person, it cannot also resolve to a
-- space, not even a space that person owns. Otherwise "message @acme" and "join @acme" mean
-- two things and the app has to guess which.
--
-- The to_jsonb dance is inherited from 029 and is load-bearing: PL/pgSQL resolves every field
-- reference in the body before deciding which branch runs, so writing `new.handle` anywhere —
-- even in an arm that never executes for `users` — fails with `record "new" has no field
-- "handle"` on every users write. to_jsonb turns the record into a value with optional keys.
--
-- THE LOCAL VARIABLE IS `wanted`, NOT `name`, and that rename is not cosmetic. 029 could call
-- it `name` because neither `users` nor `creator_profiles` has a column by that name;
-- `communities` does. PL/pgSQL resolves an unqualified identifier in a query against BOTH the
-- table's columns and the function's variables, so `where lower(handle) = name` inside the
-- communities arm aborts every write with `column reference "name" is ambiguous`. Do not
-- rename it back, and think twice before adding a variable named after any column of the
-- three tables this function queries.
-- ─────────────────────────────────────────────────────────────────────────────────
create or replace function assert_handle_available() returns trigger as $$
declare
    j      jsonb := to_jsonb(new);
    tbl    text  := tg_table_name;
    wanted text  := lower(j ->> (case when tbl = 'users' then 'username' else 'handle' end));
    -- The identity behind the row. For a community this is the owning USER, which is
    -- deliberately NOT used as an exclusion below — see the asymmetry note above.
    owner  uuid  := (j ->> (case tbl when 'users'             then 'id'
                                     when 'creator_profiles'  then 'user_id'
                                     else                          'owner_id' end))::uuid;
begin
    if wanted is null then
        return new;
    end if;

    if exists (select 1 from reserved_handles where handle = wanted) then
        raise exception '% is reserved', wanted using errcode = 'unique_violation';
    end if;

    -- Each arm checks the OTHER tables only. Same-table uniqueness is already enforced by each
    -- table's own lower() unique index, and duplicating it here would only produce a worse
    -- error message. `tbl = 'communities' or ...` is the asymmetry: no owner exclusion when a
    -- community is claiming the name.
    if tbl <> 'users' then
        if exists (select 1 from users u
                    where lower(u.username) = wanted
                      and (tbl = 'communities' or u.id <> owner)) then
            raise exception 'handle % is taken', wanted using errcode = 'unique_violation';
        end if;
    end if;

    if tbl <> 'creator_profiles' then
        if exists (select 1 from creator_profiles cp
                    where lower(cp.handle) = wanted
                      and (tbl = 'communities' or cp.user_id <> owner)) then
            raise exception 'handle % is taken', wanted using errcode = 'unique_violation';
        end if;
    end if;

    if tbl <> 'communities' then
        if exists (select 1 from communities c where lower(c.handle) = wanted) then
            raise exception 'handle % is taken', wanted using errcode = 'unique_violation';
        end if;
    end if;

    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_community_handle_available on communities;
create trigger trg_community_handle_available
    before insert or update of handle on communities
    for each row execute function assert_handle_available();

-- Names that must never belong to a community: the routes an invite link would collide with
-- (voiid.app/c/<handle> sits next to these), and the identities that invite impersonation.
-- This only affects FUTURE writes — the trigger does not run over existing rows, so nobody
-- already holding one of these loses it.
insert into reserved_handles (handle, reason) values
    ('community','route'), ('communities','route'), ('events','route'), ('event','route'),
    ('tickets','route'), ('ticket','route'), ('tournament','route'), ('tournaments','route'),
    ('join','route'), ('invite','route'), ('invites','route'), ('discover','route'),
    ('host','impersonation'), ('hosts','impersonation')
on conflict (handle) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────────
-- member_count maintenance
--
-- IN A TRIGGER, not in application code, for the reason 029:261-271 gives: the counter is
-- denormalised, so it stays truthful only if EVERY write path updates it — and there will be
-- more write paths than the join route (admin approve, ban, remove, leave, the account-erasure
-- cascade, a future bulk import). A trigger cannot be forgotten by a future endpoint the way
-- a service-layer call can, and it runs inside the caller's transaction so the count and the
-- membership commit together or not at all.
--
-- Counts 'active' only: a pending applicant is not a member, and a left/banned row must not
-- keep inflating the number on the public card.
-- ─────────────────────────────────────────────────────────────────────────────────
create or replace function bump_community_member_count() returns trigger as $$
begin
    if tg_op = 'INSERT' then
        if new.state = 'active' then
            update communities set member_count = member_count + 1
             where id = new.community_id;
        end if;
    elsif tg_op = 'DELETE' then
        if old.state = 'active' then
            -- greatest(...,0): a member count must never render as -1 on a public card, even
            -- if some historical row manages to double-delete.
            update communities set member_count = greatest(member_count - 1, 0)
             where id = old.community_id;
        end if;
    elsif tg_op = 'UPDATE' then
        -- Compare the BOOLEAN "is this row counted", not the raw state, so pending->left or
        -- left->banned (neither of which is counted) moves nothing.
        if (old.state = 'active') is distinct from (new.state = 'active') then
            if new.state = 'active' then
                update communities set member_count = member_count + 1
                 where id = new.community_id;
            else
                update communities set member_count = greatest(member_count - 1, 0)
                 where id = old.community_id;
            end if;
        end if;
    end if;
    return null;
end;
$$ language plpgsql;

drop trigger if exists trg_community_member_count on community_members;
create trigger trg_community_member_count
    after insert or delete or update of state on community_members
    for each row execute function bump_community_member_count();

-- ─────────────────────────────────────────────────────────────────────────────────
-- PHASE-2 HOOKS — why events/tickets need no rewrite of anything above
--
-- Written down so the next migration does not "fix" this one:
--
--   * `communities.id` is a stable uuid pk with no natural key mixed in, so community_events
--     (and later `orders`) FK straight at it. Nothing about pricing belongs on the container:
--     a join price is an ORDER of kind 'community_join', not a column here, so the money
--     tables can arrive without touching this file.
--   * Every unique key introduced above is NULL-FREE — (community_id, user_id),
--     (community_id, member_user_id), conversation_id, token. The payments layer's
--     `unique (provider, provider_ref)` webhook-idempotency key must be too, with
--     provider_ref NOT NULL: a NULL there makes ON CONFLICT never match, and the failure mode
--     is a duplicate webhook minting a second paid ticket (027, again — this bug class has
--     already shipped once in this repo).
--   * Ticket holding is NOT membership. An event ticket grants entry to an event, not a row
--     in community_members and therefore not the host-DM exception. Keep them separate.
--   * `community_channels.kind` is a check constraint, not an enum type, so adding a future
--     kind is a drop/add of one constraint rather than an ALTER TYPE with a table rewrite.
--
-- And a flag this file must carry rather than resolve. A `state = 'left'` row is a NEW
-- retention surface: it outlives the membership on purpose, so that bans survive a leave and
-- a rejoin is a clean upsert. How long it may be kept, and whether that period has to be
-- stated in the privacy notice, falls under the open [COUNSEL] question in
-- docs/research/11_admin_dpdp.md §6 item 3 — "defensible retention numbers", still an
-- engineering placeholder there, not a legal answer. The retention sweep must not pick a
-- number for these rows without counsel; nothing here is a compliance determination.
