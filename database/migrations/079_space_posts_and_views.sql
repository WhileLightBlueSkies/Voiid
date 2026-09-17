-- Spaces become post feeds, and posts gain a view counter.
--
-- ── A SPACE IS A FEED, NOT A CHAT ───────────────────────────────────────────────────
--
-- `community_channels.conversation_id` is the PRIMARY KEY (030): a Space literally IS a
-- conversation, which is why opening one lands in a chat. The product it wants to be is the
-- community Home page scoped to one topic — the same posts, likes and comments, filtered.
--
-- `community_posts.channel_id` is that scoping, and it is NULLABLE on purpose:
--
--     NULL          the community Home feed        (every post that exists today)
--     <channel id>  that Space's feed
--
-- The same convention the allowlist already uses (078), so there is one rule to learn
-- rather than two to keep in step. Nullable also means no backfill and no migration of
-- existing rows: every post written before this belongs to Home, which is exactly where it
-- already was.
--
-- THE EXISTING CONVERSATIONS ARE LEFT ALONE. A Space's chat history is real E2EE message
-- data; this migration does not convert, move or delete any of it. The conversation stays
-- addressable by the same id, and a Space can carry both until the product decides what to
-- do with the chat half. Destroying message history to enable a feed would be the kind of
-- irreversible step a schema change should never take on its own.
alter table community_posts
    add column if not exists channel_id uuid references community_channels(conversation_id) on delete cascade;

-- The hot query becomes "posts in this Space, newest first" and "posts in Home, newest
-- first". One partial index for each, because Home is `channel_id is null` and a plain
-- composite index cannot serve a null-predicate scan efficiently.
create index if not exists community_posts_space_idx
    on community_posts (channel_id, created_at desc) where channel_id is not null;
create index if not exists community_posts_home_idx
    on community_posts (community_id, created_at desc) where channel_id is null;

-- A post in a Space must belong to the community that owns the Space. Without this a
-- crafted request could file a post into another community's Space, and the feed query —
-- which filters by channel — would happily show it there.
create or replace function community_post_channel_matches() returns trigger as $$
begin
    if new.channel_id is not null and not exists (
        select 1 from community_channels c
         where c.conversation_id = new.channel_id and c.community_id = new.community_id
    ) then
        raise exception 'channel % does not belong to community %', new.channel_id, new.community_id;
    end if;
    return new;
end;
$$ language plpgsql;

drop trigger if exists community_post_channel_check on community_posts;
create trigger community_post_channel_check
    before insert or update of channel_id, community_id on community_posts
    for each row execute function community_post_channel_matches();

-- ── VIEWS: A COUNT, AND DELIBERATELY NOTHING ELSE ───────────────────────────────────
--
-- No `post_views(post_id, user_id)` table, on purpose. A per-person record would be a new
-- category of personal data to secure, disclose under DPDP, honour erasure requests for and
-- hand over on a lawful demand — all to render a number. The counter answers the product
-- question ("how many people saw this") and cannot answer the invasive one ("did SHE see
-- it"), because the information simply is not kept.
--
-- The same reasoning the schema already applies to likes: `like_count` exists as a counter
-- AND a join table only because the heart has to render filled for the person looking. A
-- view has no such per-person UI, so it has no such table.
alter table community_posts add column if not exists view_count int not null default 0;

alter table community_posts drop constraint if exists community_posts_counts_nonneg;
alter table community_posts
    add constraint community_posts_counts_nonneg
    check (like_count >= 0 and comment_count >= 0 and view_count >= 0);
