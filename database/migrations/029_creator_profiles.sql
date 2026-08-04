-- 029_creator_profiles.sql — the public creator identity behind Clips, and the follow graph.
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- Same scoped exception as 022_clips.sql, and for the same reason. A creator profile is
-- BROADCAST identity: it is shown to strangers who have not signed up yet, it carries
-- server-attributed follower counts, and it is discoverable by search. None of that is
-- expressible under E2EE, which needs a known recipient set at write time.
--
-- Messages, calls, locations and moments are UNAFFECTED and remain end-to-end encrypted.
-- Nothing in this file is a precedent for weakening any of them.
-- =================================================================================
--
-- ── THE CENTRAL RULE: A FOLLOW IS NOT A MESSAGING RIGHT ──────────────────────────
--
-- 020_reachability.sql defines exactly three ways to open a conversation: mutual contacts,
-- a one-way contact (as a request), or @username + the 6-digit contact PIN (as a request).
--
-- FOLLOWING ADDS NO FOURTH PATH. A creator with a million followers has a million people who
-- can watch their clips and zero extra people who can message them. This is deliberate and
-- is the whole reason the creator identity is a SEPARATE table rather than more columns on
-- `users`: the public graph and the reachability graph must not be joinable into each other
-- by accident. Any future code that reads `creator_follows` to decide whether a message is
-- allowed is a bug, not a feature.
--
-- ── WHY THE HANDLE IS SEPARATE FROM users.username ───────────────────────────────
--
-- users.username (010) is a PRIVATE lookup key: it is half of the credential pair that opens
-- a message request, and it is only useful to someone who also has your PIN. A creator handle
-- is the opposite — it is meant to be printed on a poster.
--
-- Forcing them to be the same value would mean that going public with a creator name silently
-- publishes the messaging lookup key too, which quietly weakens 020 for exactly the users
-- most likely to be targeted. So they are distinct columns with distinct semantics.
--
-- BUT THEY SHARE ONE NAMESPACE. Both are checked against `reserved_handles` and against each
-- other (see the cross-uniqueness trigger below), because "@nehal" meaning two different
-- people in two different parts of one app is an impersonation vector. Separate meaning,
-- one pool of names.

-- ─────────────────────────────────────────────────────────────────────────────────
-- Reserved handles
--
-- Seeded before the profile table so the constraint has something to check against. These
-- are names that must never belong to a user: routes that would become ambiguous
-- (/settings, /about), and identities that invite impersonation (admin, support, voiid).
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists reserved_handles (
    handle text primary key,
    reason text
);

insert into reserved_handles (handle, reason) values
    ('admin','impersonation'), ('administrator','impersonation'), ('support','impersonation'),
    ('help','impersonation'), ('voiid','brand'), ('team','impersonation'),
    ('official','impersonation'), ('staff','impersonation'), ('security','impersonation'),
    ('moderator','impersonation'), ('mod','impersonation'), ('root','impersonation'),
    ('settings','route'), ('about','route'), ('login','route'), ('signup','route'),
    ('explore','route'), ('search','route'), ('clips','route'), ('privacy','route'),
    ('terms','route'), ('api','route'), ('www','route'), ('me','route'), ('you','route')
on conflict (handle) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────────
-- Creator profiles
--
-- ONE PER USER, created on demand. The user's answer to "is the social profile connected to
-- this number?" is yes — it hangs off users(id), which is the phone-verified account. That
-- gives abuse handling a real anchor: a banned creator cannot re-register a profile without
-- a new verified number.
--
-- It is NOT created at signup. The overwhelming majority of Voiid users are here to message,
-- and manufacturing a public identity for someone who never posts is both a privacy problem
-- (a searchable profile they never asked for) and a namespace problem (it burns a handle).
-- The row is created the first time someone tries to post — the gate the user specified.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists creator_profiles (
    user_id       uuid primary key references users(id) on delete cascade,

    -- The public name. Lowercase, 3–20, letters/digits/underscore, must start with a letter —
    -- deliberately identical to the users.username grammar (010) so that one shared namespace
    -- has one set of rules and neither table can mint a name the other would reject.
    handle        text not null,
    -- What renders in the feed. Separate from handle so it can carry spaces, capitals and
    -- non-Latin scripts — the user asked about global reach, and a display name is where that
    -- has to work. Length is bounded in CHARACTERS, not bytes, so a Devanagari or CJK name
    -- gets the same allowance as a Latin one.
    display_name  text,
    bio           text,
    -- R2 key, PLAINTEXT like clip media (see header). Not the E2EE profile photo from 021 —
    -- that one is encrypted to a known audience and must not be reused for a public surface.
    avatar_r2_key text,
    link_url      text,

    -- DENORMALISED COUNTERS, exactly as clips.view_count is (022). Source of truth is
    -- creator_follows; these are the read path. A profile header showing follower count on
    -- every feed tile cannot afford a count(*) per render.
    follower_count  int not null default 0,
    following_count int not null default 0,
    clip_count      int not null default 0,

    -- FUTURE, and deliberately inert for now. The user's roadmap is a creator economy with
    -- ads and monetisation; these columns exist so the shape is settled before money touches
    -- it, but nothing reads them yet. is_verified is manual-only (admin action, audited).
    is_verified   boolean not null default false,
    -- Payouts/KYC live in their own table when they land — NOT here. Financial identity has a
    -- different retention and access profile than public identity, and merging them means
    -- every feed query touches a row containing tax data.

    -- Moderation, mirroring clips.removed_at from 028. Suspension hides the profile and its
    -- clips without destroying the follow graph, so a wrongful suspension is reversible.
    suspended_at     timestamptz,
    suspended_reason text,

    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),

    constraint creator_profiles_handle_format
        check (handle ~ '^[a-z][a-z0-9_]{2,19}$'),
    -- char_length, not octet_length: see display_name above.
    constraint creator_profiles_display_name_len
        check (display_name is null or char_length(display_name) between 1 and 40),
    constraint creator_profiles_bio_len
        check (bio is null or char_length(bio) <= 160),
    constraint creator_profiles_link_len
        check (link_url is null or char_length(link_url) <= 200)
);

-- lower() for the same reason 010 does it: handles are case-insensitively unique, so
-- @Nehal and @nehal cannot be two people. The format check already forces lowercase, but the
-- index does not depend on that check staying in place.
create unique index if not exists idx_creator_handle_lower
    on creator_profiles (lower(handle));

-- Discovery: "creators you may know", search-by-follower-count.
create index if not exists idx_creator_followers
    on creator_profiles (follower_count desc)
    where suspended_at is null;

-- ─────────────────────────────────────────────────────────────────────────────────
-- Cross-table handle uniqueness
--
-- A unique index cannot span two tables, so this is a trigger. It is the mechanism behind
-- "separate meaning, one pool of names" in the header: taking @nehal as a creator must make
-- it unavailable as a chat username and vice versa.
--
-- WHY IT MATTERS: without it, one person could hold @acme as a chat username while another
-- holds @acme as a creator handle. Every "search for @acme" surface in the app would then
-- have to explain which one it meant, and the honest answer is that one of them is
-- impersonating the other.
--
-- The check EXCLUDES the row's own owner, so a user who already has username @nehal can take
-- creator handle @nehal — same person, no conflict.
-- ─────────────────────────────────────────────────────────────────────────────────
-- ONE function serving two tables whose NEW records have different shapes. The name and the
-- owner are pulled out FIRST, via to_jsonb, because PL/pgSQL resolves every field reference
-- in a statement before deciding which branch runs: writing `new.handle` anywhere in this
-- body — even inside an `if tg_table_name = 'creator_profiles'` arm that never executes for
-- users — fails with `record "new" has no field "handle"` on every users write. to_jsonb
-- sidesteps that by turning the record into a value with optional keys.
create or replace function assert_handle_available() returns trigger as $$
declare
    j      jsonb := to_jsonb(new);
    is_cp  boolean := tg_table_name = 'creator_profiles';
    name   text := lower(j ->> (case when is_cp then 'handle' else 'username' end));
    owner  uuid := (j ->> (case when is_cp then 'user_id' else 'id' end))::uuid;
begin
    if name is null then
        return new;
    end if;

    if exists (select 1 from reserved_handles where handle = name) then
        raise exception '% is reserved', name using errcode = 'unique_violation';
    end if;

    -- The opposite table only. Same-table uniqueness is already enforced by each table's own
    -- lower() unique index, and duplicating it here would just produce a worse error message.
    if is_cp then
        if exists (select 1 from users
                    where lower(username) = name and id <> owner) then
            raise exception 'handle % is taken', name using errcode = 'unique_violation';
        end if;
    else
        if exists (select 1 from creator_profiles
                    where lower(handle) = name and user_id <> owner) then
            raise exception 'username % is taken', name using errcode = 'unique_violation';
        end if;
    end if;
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_creator_handle_available on creator_profiles;
create trigger trg_creator_handle_available
    before insert or update of handle on creator_profiles
    for each row execute function assert_handle_available();

-- The mirror side. `when (new.username is not null)` so the millions of users who never set
-- a username never pay for this trigger.
drop trigger if exists trg_username_available on users;
create trigger trg_username_available
    before insert or update of username on users
    for each row when (new.username is not null)
    execute function assert_handle_available();

-- ─────────────────────────────────────────────────────────────────────────────────
-- Handle rename history
--
-- Two jobs. First, RATE LIMITING: a handle can change once every 30 days, and this table is
-- what the API checks — free renaming lets an account build an audience under one name, sell
-- it, and disappear.
--
-- Second, LINK SURVIVAL: an old handle resolves to a 301 pointing at the current one, so a
-- link someone put in a bio last month still lands on the right creator instead of a 404.
--
-- The old handle is NOT held in reserve — once released, anyone may take it. Holding names
-- forever would burn the namespace, and the 301 correctly stops applying the moment someone
-- else legitimately owns the name (the lookup only runs when no live profile matches).
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists creator_handle_history (
    id         bigserial primary key,
    user_id    uuid not null references users(id) on delete cascade,
    old_handle text not null,
    new_handle text not null,
    created_at timestamptz not null default now()
);

-- The rate-limit check is "most recent change for this user".
create index if not exists idx_handle_history_user
    on creator_handle_history (user_id, created_at desc);
-- The 301 lookup is by old handle.
create index if not exists idx_handle_history_old
    on creator_handle_history (lower(old_handle), created_at desc);

-- ─────────────────────────────────────────────────────────────────────────────────
-- The follow graph
--
-- DIRECTED and UNRECIPROCATED, like Instagram and unlike the contact model: following is a
-- one-way subscription that needs no consent from the followee, because — per the header —
-- it grants nothing except seeing public content that was already public.
--
-- Not public yet, per the user's decision ("we need the backend and everything ready for
-- it"). The table and counters are live so the data accrues correctly from day one; the
-- follower LIST is simply not exposed by any endpoint until that ships. Backfilling a social
-- graph later is impossible, so it starts recording now.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists creator_follows (
    follower_id uuid not null references users(id) on delete cascade,
    followee_id uuid not null references users(id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (follower_id, followee_id),
    -- Cheap insurance against a self-follow inflating someone's own follower count.
    constraint creator_follows_no_self check (follower_id <> followee_id)
);

-- "Who follows me", newest first — the follower list, and the notification fan-out source.
create index if not exists idx_follows_followee
    on creator_follows (followee_id, created_at desc);
-- "Who do I follow" — drives the following-feed query.
create index if not exists idx_follows_follower
    on creator_follows (follower_id, created_at desc);

-- ─────────────────────────────────────────────────────────────────────────────────
-- Counter maintenance
--
-- In a TRIGGER, not in application code. The counters are denormalised, so the only way they
-- stay truthful is if every write path updates them — and there will be more write paths
-- than this one (admin actions, account deletion cascade, future bulk imports). A trigger
-- cannot be forgotten by a future endpoint the way a service-layer call can.
--
-- Both statements run inside the caller's transaction, so the count and the edge commit
-- together or not at all.
-- ─────────────────────────────────────────────────────────────────────────────────
create or replace function bump_follow_counts() returns trigger as $$
begin
    if tg_op = 'INSERT' then
        update creator_profiles set follower_count = follower_count + 1
         where user_id = new.followee_id;
        update creator_profiles set following_count = following_count + 1
         where user_id = new.follower_id;
    elsif tg_op = 'DELETE' then
        -- greatest(...,0): a counter must never render as -1 on a public profile, even if a
        -- historical row somehow double-deletes.
        update creator_profiles set follower_count = greatest(follower_count - 1, 0)
         where user_id = old.followee_id;
        update creator_profiles set following_count = greatest(following_count - 1, 0)
         where user_id = old.follower_id;
    end if;
    return null;
end;
$$ language plpgsql;

drop trigger if exists trg_follow_counts on creator_follows;
create trigger trg_follow_counts
    after insert or delete on creator_follows
    for each row execute function bump_follow_counts();

-- clip_count, same argument. Counts live clips only: a removed or deleted clip must not
-- still be advertised on the profile header.
create or replace function bump_clip_count() returns trigger as $$
begin
    if tg_op = 'INSERT' and new.deleted_at is null and new.removed_at is null then
        update creator_profiles set clip_count = clip_count + 1 where user_id = new.author_id;
    elsif tg_op = 'DELETE' and old.deleted_at is null and old.removed_at is null then
        update creator_profiles set clip_count = greatest(clip_count - 1, 0)
         where user_id = old.author_id;
    elsif tg_op = 'UPDATE' then
        -- Visibility is a function of BOTH flags, so compare the combined state rather than
        -- either column alone — a takedown and an author-delete must not double-decrement.
        if (old.deleted_at is null and old.removed_at is null)
           is distinct from (new.deleted_at is null and new.removed_at is null) then
            if new.deleted_at is null and new.removed_at is null then
                update creator_profiles set clip_count = clip_count + 1
                 where user_id = new.author_id;
            else
                update creator_profiles set clip_count = greatest(clip_count - 1, 0)
                 where user_id = new.author_id;
            end if;
        end if;
    end if;
    return null;
end;
$$ language plpgsql;

drop trigger if exists trg_clip_count on clips;
create trigger trg_clip_count
    after insert or delete or update of deleted_at, removed_at on clips
    for each row execute function bump_clip_count();

-- ─────────────────────────────────────────────────────────────────────────────────
-- Backfill
--
-- Existing clips have no profile behind them. This is intentionally a no-op in the normal
-- case: the wipe script (scripts/wipe-clips.mjs) empties the clips table before this ships,
-- exactly so that no clip exists without a creator profile. It is here for safety if the
-- migration runs against a database that was not wiped, so the invariant
-- "every clip has an author profile" holds either way.
-- ─────────────────────────────────────────────────────────────────────────────────
insert into creator_profiles (user_id, handle, display_name)
select distinct on (c.author_id)
       c.author_id,
       -- Derive from username when it exists, else a stable per-user fallback. The suffix is
       -- from the uuid, so a re-run produces the same handle rather than a second collision.
       coalesce(u.username, 'creator_' || replace(substr(c.author_id::text, 1, 8), '-', '')),
       u.full_name
  from clips c
  join users u on u.id = c.author_id
 where not exists (select 1 from creator_profiles p where p.user_id = c.author_id)
on conflict (user_id) do nothing;
