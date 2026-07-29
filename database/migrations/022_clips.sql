-- 022_clips.sql — Clips: short-form public video (the grid feed + reels player).
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- This is a DELIBERATE, SCOPED exception to the app's "server never sees plaintext"
-- rule, and it must never be read as a precedent for weakening messaging E2EE.
--
-- WHY: stories/moments encrypt to a KNOWN, FIXED audience — one key envelope per
-- recipient device (see 017_stories.sql). A clip is a BROADCAST: there is no
-- recipient set at post time, anyone may discover it, and the product requires
-- server-attributed view/like/comment counts. You cannot encrypt to "everyone, some
-- of whom have not signed up yet", and a server that cannot read the row cannot
-- count it. So clip media is stored as PLAINTEXT in R2 under `media/clips/`.
--
-- WHAT THIS MEANS, stated plainly so the UI can say it: clips are public content.
-- The server can read the video, the caption, and who liked/viewed what. Messages,
-- calls, locations and moments are unaffected and remain E2EE.
-- =================================================================================

create table if not exists clips (
    id              uuid primary key,                 -- CLIENT-supplied (cf. stories/calls):
                                                      -- lets the client build optimistic local
                                                      -- state before the row exists, and makes
                                                      -- POST retries idempotent via the pk.
    author_id       uuid not null references users(id) on delete cascade,
    -- media/clips/<uid>/<uuid>.mp4 — PLAINTEXT (see header). The uid namespace is what
    -- POST /clips checks to prove the caller owns the key it is claiming.
    r2_key          text not null,
    -- The grid renders THIS, never the video. A 3-column grid pulling 30 videos to
    -- paint 30 tiles would be unusable on mobile data; the thumb is a ~40 KB JPEG.
    thumb_r2_key    text not null,
    caption         text,
    duration_ms     int,
    -- Stored so the player can letterbox and the grid can reserve the right box
    -- WITHOUT downloading and probing the file first (which is what causes the
    -- layout to jump after first paint).
    width           int,
    height          int,
    byte_size       bigint,

    -- DENORMALISED COUNTERS. The source of truth is the clip_likes / clip_views /
    -- clip_comments tables; these columns are the READ path. Counting rows per tile
    -- on every feed page would be the feed's dominant cost — the reference design
    -- puts a view count on every single tile.
    view_count      int not null default 0,
    like_count      int not null default 0,
    comment_count   int not null default 0,

    -- 'ready' | 'failed'. A row is only ever INSERTED once both R2 PUTs have
    -- succeeded, so it is born 'ready'; 'failed' exists for a post-hoc transcode/
    -- moderation reject. There is deliberately no 'uploading' state — creating the
    -- row up front would leave a permanently broken tile in every viewer's feed when
    -- a client dies mid-upload. Orphaned R2 objects are swept by the worker instead.
    status          text not null default 'ready',
    created_at      timestamptz not null default now(),
    -- Soft delete: the row survives so counters/comments do not cascade-vanish from
    -- other users' open feeds mid-scroll; the reaper clears the R2 objects.
    deleted_at      timestamptz
);

-- THE feed query: newest-first over live, ready clips. Partial so the index only
-- carries rows the feed can actually return. Keyset pagination reads (created_at, id)
-- in this exact order — never OFFSET, which duplicates and skips tiles whenever
-- somebody posts mid-scroll.
create index if not exists idx_clips_feed
    on clips (created_at desc, id desc)
    where deleted_at is null and status = 'ready';

-- A single author's grid (own profile / "my clips").
create index if not exists idx_clips_author
    on clips (author_id, created_at desc)
    where deleted_at is null;

-- ── Likes ────────────────────────────────────────────────────────────────────────
-- Presence of the row IS the like; there is no boolean to get out of sync. The
-- composite pk gives "has this user liked this clip" a single index probe and makes
-- a double-tap race an on-conflict no-op rather than a double count.
create table if not exists clip_likes (
    clip_id     uuid not null references clips(id) on delete cascade,
    user_id     uuid not null references users(id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (clip_id, user_id)
);

-- ── Views ────────────────────────────────────────────────────────────────────────
-- One row per (clip, user) — the pk is what makes view counting idempotent, so a
-- user rewatching a clip ten times does not inflate the number the whole grid is
-- built around. The client only calls the endpoint after a >=2s watch.
create table if not exists clip_views (
    clip_id     uuid not null references clips(id) on delete cascade,
    user_id     uuid not null references users(id) on delete cascade,
    viewed_at   timestamptz not null default now(),
    primary key (clip_id, user_id)
);

-- ── Comments ─────────────────────────────────────────────────────────────────────
-- Flat (no threading) in v1. Soft-deleted so comment_count and pagination cursors
-- stay stable for clients holding an open list.
create table if not exists clip_comments (
    id          uuid primary key,
    clip_id     uuid not null references clips(id) on delete cascade,
    author_id   uuid not null references users(id) on delete cascade,
    text        text not null,
    created_at  timestamptz not null default now(),
    deleted_at  timestamptz
);

-- Comment list for one clip, oldest-first, keyset-paginated on (created_at, id).
create index if not exists idx_clip_comments_clip
    on clip_comments (clip_id, created_at asc, id asc)
    where deleted_at is null;
