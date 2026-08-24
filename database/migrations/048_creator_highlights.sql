-- 048_creator_highlights.sql — story highlights and a cover photo on a creator profile.
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- Same scoped exception as 029_creator_profiles.sql, restated per surface:
--
--   Cover photo (creator_profiles.cover_url) .. SERVER-READABLE. It is shown on a public
--                                               profile page to people who do not follow the
--                                               creator and hold no key. Broadcast identity,
--                                               exactly like the avatar beside it.
--   Highlights (creator_highlights) ........... SERVER-READABLE. A highlight is a curated
--                                               shelf on a public page; its whole purpose is
--                                               to be seen by strangers.
--   Highlight items ........................... SERVER-READABLE, and only ever reference
--                                               clips, which are already public broadcast
--                                               content (022_clips.sql).
--
-- STILL END-TO-END ENCRYPTED and untouched: messages, calls, locations, moments, backups.
-- Nothing here is a precedent for weakening any of them.
--
-- ── A FOLLOW IS STILL NOT A MESSAGING RIGHT ─────────────────────────────────────
-- 029 says any code reading the public graph to authorise a message is a bug. This file adds
-- more public-graph surface and changes that not at all: nothing here grants reachability, and
-- the profile screen that renders it deliberately has no Message button.
--
-- ── STORIES ARE NOT REUSED ──────────────────────────────────────────────────────
-- 017_stories.sql models an EPHEMERAL, audience-scoped, E2EE post that expires in 24h. A
-- highlight is the opposite on all three counts: permanent, public, and server-readable. They
-- share a name in other products and nothing else here, so they get separate tables rather
-- than a nullable `expires_at` that would let one query accidentally serve the other.

-- ─────────────────────────────────────────────────────────────────────────────────
-- The cover photo
--
-- One column, not a table: a profile has exactly one cover, always read with the profile row.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table creator_profiles
    -- An object key, not an absolute URL — same convention as avatar_url, so the same
    -- presign-on-read path serves both. Null means "no cover", and the client falls back to a
    -- blurred copy of the avatar (see CreatorProfileView.cover).
    add column if not exists cover_url text;

-- ─────────────────────────────────────────────────────────────────────────────────
-- Highlights
--
-- A shelf on the profile. The shelf and its contents are separate tables because a highlight
-- holds many clips and a clip can appear in several highlights — a text[] of clip ids would
-- make every add and remove a read-modify-write of the whole shelf, and would have no way to
-- carry per-item ordering.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists creator_highlights (
    id         uuid primary key default gen_random_uuid(),
    -- Keyed on the profile's user, matching creator_profiles' own key.
    user_id    uuid not null references users(id) on delete cascade,

    title      text not null,
    -- The shelf's cover image. Null means the client falls back to the first item's thumbnail,
    -- which is what most highlights will use — an explicit cover is the exception.
    cover_url  text,

    -- Display order on the rail. Explicit rather than by created_at so a creator can reorder
    -- without their highlights jumping to the end of the row when they edit one.
    position   int not null default 0,
    created_at timestamptz not null default now(),

    constraint creator_highlights_title_len check (char_length(title) between 1 and 40)
);

-- The only query the rail runs: every highlight for one creator, in order.
create index if not exists creator_highlights_user_idx
    on creator_highlights (user_id, position);

-- ─────────────────────────────────────────────────────────────────────────────────
-- What is on a shelf
--
-- Clips only. A highlight cannot contain a message or a moment — those are E2EE and
-- audience-scoped, and putting one on a public shelf would be a disclosure, not a feature.
-- The foreign key is what enforces that: there is nowhere here to name anything but a clip.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists creator_highlight_items (
    highlight_id uuid not null references creator_highlights(id) on delete cascade,
    clip_id      uuid not null references clips(id) on delete cascade,

    position     int not null default 0,
    added_at     timestamptz not null default now(),

    -- A clip appears at most once per shelf, enforced by the key rather than by the route.
    primary key (highlight_id, clip_id)
);

-- Opening one highlight: its clips, in order.
create index if not exists creator_highlight_items_ordered_idx
    on creator_highlight_items (highlight_id, position);

-- "Which shelves is this clip on" — needed when a clip is deleted or made private, so the
-- shelves that showed it can be corrected rather than rendering a hole.
create index if not exists creator_highlight_items_clip_idx
    on creator_highlight_items (clip_id);
