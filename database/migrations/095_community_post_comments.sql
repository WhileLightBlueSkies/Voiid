-- 095: comments on community Home posts.
--
-- community_posts has carried comment_count since 047, but there was nowhere to put a
-- comment, so the number could only ever be zero and the post card had no way to talk
-- back. This is that table.
--
-- Like posts, comments are SERVER-READABLE: a post is a broadcast to a community, and its
-- replies are part of the same public thread. A removed comment keeps its row (removed_at)
-- so a moderator can see what was taken down — the same rule posts follow.

create table if not exists community_post_comments (
    id          uuid primary key default gen_random_uuid(),
    post_id     uuid not null references community_posts(id) on delete cascade,
    -- SET NULL, as for posts: deleting an account must not rewrite a thread others replied in.
    author_id   uuid references users(id) on delete set null,
    body        text not null,
    created_at  timestamptz not null default now(),
    removed_at  timestamptz,
    removed_by  uuid references users(id) on delete set null,

    constraint community_post_comments_body_len check (char_length(body) between 1 and 1000)
);

-- A post's thread, oldest first.
create index if not exists community_post_comments_post_idx
    on community_post_comments (post_id, created_at)
    where removed_at is null;
