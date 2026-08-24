-- 047_community_home.sql — the Home tab: posts, a pinned announcement, About links, and the
-- Space metadata the Spaces tab renders.
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- Same scoped exception as 030_communities.sql, and for the same reason — restated per
-- surface, because "it's like the last one" is not a thing a reader should have to take on
-- faith:
--
--   Posts (community_posts) ................. SERVER-READABLE. A post is a BROADCAST to the
--                                             whole community, including — for a discoverable
--                                             community — people who have not joined and hold
--                                             no MLS key. There is no key that is "everyone
--                                             who might later look", so a feed the server
--                                             cannot read is a feed that cannot be served.
--                                             This is the 029_creator_profiles.sql argument:
--                                             broadcast identity is not private correspondence.
--   Post reactions / comment counts ......... SERVER-READABLE. They are aggregates over the
--                                             above, and aggregating ciphertext is not a
--                                             thing this system can do.
--   Announcement (community_announcements) .. SERVER-READABLE. Same as a post; it is the one
--                                             pinned to the top.
--   About links (community_links) ........... SERVER-READABLE. Shown on the public info card,
--                                             to non-members, by definition.
--   Space metadata (purpose, posting policy). SERVER-READABLE. The card is shown to decide
--                                             WHETHER to join a Space; it cannot be gated on
--                                             already being in it.
--
-- STILL END-TO-END ENCRYPTED, and untouched by this file: channel messages (MLS, 011), the
-- member<->host DM (Double Ratchet, 006), calls, locations and moments. Nothing here is a
-- precedent for weakening any of them.
--
-- ── WHY POSTS ARE NOT CHANNEL MESSAGES ──────────────────────────────────────────
-- A channel message is addressed to the channel's MLS group: to read it you must hold a key,
-- which means you must be a member, which means the feed cannot render for the non-member
-- browsing a discoverable community. The Home feed is the surface that sells the community to
-- someone who has not joined. Those are two different delivery models and collapsing them
-- would break one of the two.
-- =================================================================================

-- ─────────────────────────────────────────────────────────────────────────────────
-- Posts
--
-- The Home feed. One row per post; media lives in the existing object store and is referenced
-- by URL, the same shape clips (022) uses.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists community_posts (
    id           uuid primary key default gen_random_uuid(),
    community_id uuid not null references communities(id) on delete cascade,
    -- The author. ON DELETE SET NULL rather than CASCADE: deleting an account must not silently
    -- rewrite the community's history out from under everyone who replied to it. A null author
    -- renders as "Deleted account", which is the honest thing to show.
    author_id    uuid references users(id) on delete set null,

    body         text not null,
    -- Optional media. A URL, not bytes — same as clips. Null is the common case.
    media_url    text,

    -- Denormalised counters. Kept here rather than counted per render because the feed reads
    -- them on every row and a count(*) per post per scroll is the query that kills the tab.
    -- The routes that write reactions own keeping these true.
    like_count    int not null default 0,
    comment_count int not null default 0,

    -- Moderation. A removed post stays in the table so a moderator can see what they removed
    -- and an appeal has something to point at; the feed query filters it out.
    removed_at   timestamptz,
    removed_by   uuid references users(id) on delete set null,

    created_at   timestamptz not null default now(),
    edited_at    timestamptz,

    constraint community_posts_body_len check (char_length(body) between 1 and 5000),
    constraint community_posts_counts_nonneg check (like_count >= 0 and comment_count >= 0)
);

-- The only query the feed runs: one community's live posts, newest first. Partial on
-- removed_at so removed rows cost nothing in the index the hot path uses.
create index if not exists community_posts_feed_idx
    on community_posts (community_id, created_at desc)
    where removed_at is null;

-- "Everything this account wrote", for account deletion and for a moderator reviewing someone.
create index if not exists community_posts_author_idx
    on community_posts (author_id, created_at desc);

-- ─────────────────────────────────────────────────────────────────────────────────
-- Likes
--
-- A join table rather than a counter alone: without it, "did I like this?" cannot be answered
-- and the heart cannot render filled. The counter above is the aggregate; this is the truth.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists community_post_likes (
    post_id    uuid not null references community_posts(id) on delete cascade,
    user_id    uuid not null references users(id) on delete cascade,
    created_at timestamptz not null default now(),

    -- One like per person per post, enforced by the key rather than by the route.
    primary key (post_id, user_id)
);

-- "Which of these posts have I liked", for a feed page in one query.
create index if not exists community_post_likes_user_idx
    on community_post_likes (user_id, post_id);

-- ─────────────────────────────────────────────────────────────────────────────────
-- The pinned announcement
--
-- A TABLE, not a boolean on community_posts, and not a single column on communities.
--
-- Not a flag on posts: an announcement outlives the feed. Pinning post #4000 and letting it
-- age out of the feed query would take the announcement with it.
--
-- Not a column on communities: history matters. A host wants to see what was pinned last
-- month, and an announcement that is overwritten in place cannot answer that. The partial
-- unique index below gives the "only one at a time" the UI promises while keeping the rest.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists community_announcements (
    id           uuid primary key default gen_random_uuid(),
    community_id uuid not null references communities(id) on delete cascade,
    author_id    uuid references users(id) on delete set null,

    title        text not null,
    body         text not null,

    -- Null once unpinned. The row stays; only its currency ends.
    pinned_at    timestamptz not null default now(),
    unpinned_at  timestamptz,

    created_at   timestamptz not null default now(),

    constraint community_announcements_title_len check (char_length(title) between 1 and 140),
    constraint community_announcements_body_len  check (char_length(body) between 1 and 2000)
);

-- ONE live announcement per community, enforced structurally. The Home tab renders exactly one
-- and a second would silently pick a winner by sort order; this makes that a write error
-- instead of a rendering accident.
create unique index if not exists community_announcements_one_live_idx
    on community_announcements (community_id)
    where unpinned_at is null;

-- The history view, newest first.
create index if not exists community_announcements_history_idx
    on community_announcements (community_id, pinned_at desc);

-- ─────────────────────────────────────────────────────────────────────────────────
-- About links
--
-- A list, for the same reason community_rules (046) is a list: ordered, individually editable,
-- individually removable. A json blob makes each of those a read-modify-write of the whole set.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists community_links (
    id           uuid primary key default gen_random_uuid(),
    community_id uuid not null references communities(id) on delete cascade,

    -- What it is called ("Website") and where it goes. `value` is text, not a url type: the
    -- About tab also carries a contact address and a "read the handbook" label, and forcing
    -- every row to parse as a URL would exclude both.
    label        text not null,
    value        text not null,
    -- An SF Symbol name chosen by the host from a fixed client-side set. Free text rather than
    -- an enum for the same reason 046 left `category` unconstrained: the set changes more often
    -- than a schema should.
    icon         text,

    position     int not null default 0,
    created_at   timestamptz not null default now(),

    constraint community_links_label_len check (char_length(label) between 1 and 60),
    constraint community_links_value_len check (char_length(value) between 1 and 500)
);

-- The only query: every link for one community, in order.
create index if not exists community_links_community_idx
    on community_links (community_id, position);

-- ─────────────────────────────────────────────────────────────────────────────────
-- Space metadata
--
-- The Spaces tab renders a purpose line, a posting policy and a pin state per Space.
-- community_channels (030) has none of those, so the client currently invents them.
--
-- Added to the EXISTING table rather than a side table: these are attributes of the channel,
-- one row each, always read together with it. A join to fetch three columns would be a join on
-- every render of the tab.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table community_channels
    -- The sentence under the Space's name. Optional — a Space called "Jobs" explains itself.
    add column if not exists purpose text,
    -- Who may post. 'everyone' | 'admins'. NOT derived from kind='announcement': a host may
    -- want a read-only Resources Space that is not the announcement channel, and the one
    -- announcement channel per community is already unique-indexed in 030 for other reasons.
    add column if not exists posting text not null default 'everyone',
    -- Pinned Spaces sort to the top for everyone. Nullable timestamp rather than a boolean so
    -- ties break by when they were pinned.
    add column if not exists pinned_at timestamptz;

alter table community_channels
    drop constraint if exists community_channels_posting_check;
alter table community_channels
    add constraint community_channels_posting_check
    check (posting in ('everyone', 'admins'));

alter table community_channels
    drop constraint if exists community_channels_purpose_len;
alter table community_channels
    add constraint community_channels_purpose_len
    check (purpose is null or char_length(purpose) <= 200);

-- The Spaces tab's order: pinned first, then the host's order. NULLS LAST puts unpinned
-- Spaces after pinned ones without a coalesce the planner cannot use.
create index if not exists community_channels_ordered_idx
    on community_channels (community_id, pinned_at desc nulls last, position);
