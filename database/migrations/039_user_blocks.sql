-- 039_user_blocks.sql
--
-- User-level blocking. Until now Voiid had none: the iOS Block button raised
-- "Blocking isn't available yet", directly beneath a dialog promising "They won't be
-- able to message or call you." This table is the first half of making that true.
--
-- WHY THIS IS NOT `request_state = 'declined'`
-- --------------------------------------------
-- 020_reachability added `conversation_members.request_state`, and 'declined' is a real
-- refusal — but it is scoped to ONE CONVERSATION. A blocked user can open a new
-- conversation, be added to a group alongside you, ring you, or read your profile and
-- last-seen. Blocking is a property of the PAIR OF USERS, independent of any conversation,
-- so it needs its own table.
--
-- DIRECTIONAL, NOT MUTUAL
-- -----------------------
-- One row means "blocker no longer wants contact from blocked". It says nothing about the
-- reverse direction, which is a separate row if it exists at all. Enforcement asks "is
-- there a block in EITHER direction between these two users" precisely because a block
-- must also stop the BLOCKER from messaging the person they blocked — otherwise blocking
-- someone becomes a way to talk at them while they cannot reply.
--
-- WHAT A BLOCK DELIBERATELY DOES NOT DO
-- -------------------------------------
-- It does not delete history, remove either party from existing groups, or notify the
-- blocked user. Silence is the point: the blocked party should not be able to distinguish
-- "blocked" from "offline", which is why enforcement returns success-shaped responses or
-- stale data rather than a distinctive error. See the enforcement notes in
-- backend/api/src/blocking.ts.

create table if not exists user_blocks (
    id              uuid primary key default gen_random_uuid(),
    -- The user who pressed Block.
    blocker_user_id uuid not null references users(id) on delete cascade,
    -- The user they blocked.
    blocked_user_id uuid not null references users(id) on delete cascade,
    created_at      timestamptz not null default now(),

    -- One row per direction per pair. Unblocking DELETEs, so re-blocking is a fresh insert
    -- and `created_at` always reflects the CURRENT block rather than a historical one.
    unique (blocker_user_id, blocked_user_id),

    -- Blocking yourself is meaningless and would make every self-conversation (Note to
    -- Self) unreachable, since enforcement checks both directions on a pair.
    constraint user_blocks_no_self check (blocker_user_id <> blocked_user_id)
);

-- "Who have I blocked" — the settings list, and the blocker-side half of the pair check.
create index if not exists idx_user_blocks_blocker on user_blocks (blocker_user_id);

-- "Who has blocked me" — the blocked-side half. Enforcement runs on EVERY message send,
-- call, and profile fetch, so this direction must be indexed too; without it the pair
-- check degrades to a sequential scan on the hot path.
create index if not exists idx_user_blocks_blocked on user_blocks (blocked_user_id);

comment on table user_blocks is
    'Directional user blocks. Enforcement checks BOTH directions for a pair (see '
    'backend/api/src/blocking.ts) so a block also stops the blocker from messaging the '
    'person they blocked. Unblock deletes the row.';
