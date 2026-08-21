-- 046: the three things the create wizard asks for and had nowhere to put.
--
-- The five-step flow collects a category, a set of rules and whether members may invite.
-- Two of those five steps had no server-side home, so the wizard either discarded them
-- silently or could not ship. Discarding what a user just chose is the worse failure: it is
-- invisible, and it teaches them their choices do not matter.

alter table communities
    -- Free text rather than an enum. The picker offers six, but a category list is a product
    -- decision that changes more often than a schema should, and a CHECK constraint here
    -- means a migration every time marketing adds one.
    add column if not exists category text,
    -- Whether an ordinary member may create invites. Invite-only communities force this off
    -- (an invite-only community where everyone invites is not invite-only), which the client
    -- enforces at the point of choosing and this default matches.
    add column if not exists members_can_invite boolean not null default true;

-- Rules are a LIST, not a column. They are ordered, individually editable and individually
-- removable, and cramming them into a text[] or a json blob makes every one of those a
-- read-modify-write of the whole set.
create table if not exists community_rules (
    id           uuid primary key default gen_random_uuid(),
    community_id uuid not null references communities(id) on delete cascade,
    -- What the rule says. The title is what renders in a list; the detail is the sentence
    -- under it, and is optional because a short rule does not need explaining.
    title        text not null,
    detail       text,
    -- Display order. Explicit rather than by created_at, so a host can reorder without the
    -- rules jumping to the end of the list when they edit one.
    position     int not null default 0,
    created_at   timestamptz not null default now(),

    constraint community_rules_title_len check (char_length(title) between 1 and 120),
    constraint community_rules_detail_len check (detail is null or char_length(detail) <= 400)
);

-- The only query this table serves: every rule for one community, in order.
create index if not exists community_rules_community_idx
    on community_rules (community_id, position);
