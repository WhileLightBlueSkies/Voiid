-- ─────────────────────────────────────────────────────────────────────────────────
-- 054_creator_privacy.sql
--
-- Privacy controls for the PUBLIC creator profile (029).
--
-- 029's own header is explicit that this surface is public by design: server-attributed
-- follower counts, discoverable by search, deliberately separate from the E2EE messaging
-- identity. Nothing here changes that contract — a public profile stays public. What it
-- adds is the creator's control over HOW MUCH of it is public, which did not exist at all:
-- before this, publishing a single clip meant your handle, avatar, bio, link, counts and
-- entire grid were visible to every authenticated user with no way to narrow any of it.
--
-- WHY THESE COLUMNS AND NOT A `private` BOOLEAN
-- A single "private account" flag is the obvious design and the wrong one here. It conflates
-- decisions that people genuinely make differently: plenty of creators want a visible grid
-- but no visible follower count, or a discoverable profile that does not surface in search.
-- Each flag below is one decision a creator can actually articulate.
--
-- DEFAULTS PRESERVE TODAY'S BEHAVIOUR EXACTLY.
-- Every column defaults to the current visible state, so this migration changes nothing for
-- anyone until they choose otherwise. A privacy migration that silently hides existing
-- creators' content would be a worse failure than having no controls.
-- ─────────────────────────────────────────────────────────────────────────────────

alter table creator_profiles
    -- Who may see the clip grid on this profile. 'everyone' is today's behaviour.
    -- 'followers' still shows the profile itself — handle, avatar, bio — but the grid is
    -- withheld, which is the "you can find me, you cannot browse me" middle ground that a
    -- single private flag cannot express.
    add column if not exists grid_visibility text not null default 'everyone'
        check (grid_visibility in ('everyone', 'followers', 'nobody')),

    -- Follower/following counts on the header. Independent of the grid: a creator may be
    -- happy to show work and not the size of their audience.
    add column if not exists show_counts boolean not null default true,

    -- Whether this profile may be returned by search/discovery surfaces. It does NOT make
    -- the profile unreachable — a direct link still resolves, which is what keeps shared
    -- links and @mentions working. "Not listed", not "not found".
    add column if not exists discoverable boolean not null default true,

    -- Whether anyone may follow. Turning this off does not remove existing followers; it
    -- refuses NEW ones. Removing an audience someone already built is a destructive act and
    -- must be a separate, explicit choice, never a side effect of flipping a switch.
    add column if not exists allow_follows boolean not null default true,

    -- Whether other people's comments appear on this creator's clips. Comment rows are not
    -- deleted when this is off — they are withheld — so turning it back on restores the
    -- conversation rather than having destroyed it.
    add column if not exists allow_comments boolean not null default true;

-- Discovery surfaces filter on this, so it is worth an index once there are enough rows to
-- matter. Partial: only the visible ones are ever scanned for.
create index if not exists idx_creator_profiles_discoverable
    on creator_profiles (handle)
    where discoverable and suspended_at is null;

comment on column creator_profiles.grid_visibility is
    'everyone | followers | nobody — who may see this creator''s clip grid';
comment on column creator_profiles.discoverable is
    'Listed in search/discovery. A direct link still resolves either way.';
