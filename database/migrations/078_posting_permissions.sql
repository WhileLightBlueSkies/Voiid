-- Who may post: the Home feed and each Space, with the same four-value vocabulary.
--
-- ── WHY FOUR VALUES AND NOT A BOOLEAN ───────────────────────────────────────────────
--
-- Home was `members | managers` and a Space was `everyone | admins`: two spellings of the
-- same idea, neither able to say "nobody" or "these particular people". A host who wants a
-- read-only Resources Space had no way to express it — 047 even anticipated that case in a
-- comment and then shipped a two-value check that could not represent it.
--
--   everyone  — any active member
--   managers  — the owner and community admins
--   selected  — an explicit allowlist, PLUS managers (see below)
--   none      — nobody; the feed is read-only, including for the owner
--
-- One vocabulary for both levels, because "who can post here" is one question asked twice.
-- The old values are migrated rather than kept as synonyms: two names for one state is how
-- a check ends up testing the wrong one.
--
-- ── WHY `selected` STILL INCLUDES MANAGERS ──────────────────────────────────────────
--
-- An allowlist that could lock out the owner would let an admin panel mistake make a
-- community unadministrable, with no way back in. Managers are always able to post; the
-- allowlist ADDS people rather than replacing the role check.
--
-- `none` is deliberately different: it is a statement about the SPACE, not about people, so
-- it applies to everyone. A host who needs to post to a `none` Space changes the policy
-- first — one deliberate act, visible in the settings screen, rather than a silent exception.

-- ── HOME FEED ───────────────────────────────────────────────────────────────────────
alter table communities drop constraint if exists communities_posting_policy_check;

update communities set posting_policy = 'everyone' where posting_policy = 'members';

alter table communities
  add constraint communities_posting_policy_check
  check (posting_policy in ('everyone', 'managers', 'selected', 'none'));

-- THE DEFAULT CHANGES. It was 'members', so every community ever created let any member
-- publish to its public Home feed — confirmed as live behaviour by the 2026-09-15 audit.
-- Existing rows keep whatever they have; only new communities get the safer default.
alter table communities alter column posting_policy set default 'managers';

-- ── SPACES ──────────────────────────────────────────────────────────────────────────
alter table community_channels drop constraint if exists community_channels_posting_check;

update community_channels set posting = 'managers' where posting = 'admins';

alter table community_channels
  add constraint community_channels_posting_check
  check (posting in ('everyone', 'managers', 'selected', 'none'));

-- ── THE ALLOWLIST ───────────────────────────────────────────────────────────────────
--
-- One table for both levels. `channel_id` NULL means the community's Home feed, which is
-- the same convention the posts table will use for Space-scoped posts — one rule to learn.
--
-- No unique index can cover "(community_id, user_id) where channel_id is null" and the
-- channel case at once, so both partial indexes exist and the pair is the constraint.
create table if not exists community_post_allowlist (
    community_id uuid not null references communities(id) on delete cascade,
    -- NULL = the Home feed. A Space is identified by its conversation id, which IS the
    -- primary key of community_channels (030).
    channel_id   uuid references community_channels(conversation_id) on delete cascade,
    user_id      uuid not null references users(id) on delete cascade,
    -- Who granted it, for the same reason every moderation row records an actor: a
    -- permission nobody can account for is one nobody can review.
    granted_by   uuid references users(id) on delete set null,
    granted_at   timestamptz not null default now()
);

create unique index if not exists community_post_allowlist_home
    on community_post_allowlist (community_id, user_id) where channel_id is null;
create unique index if not exists community_post_allowlist_space
    on community_post_allowlist (channel_id, user_id) where channel_id is not null;

-- The hot query is "may this person post here", asked on every composer render.
create index if not exists community_post_allowlist_lookup
    on community_post_allowlist (user_id, community_id);
