-- 081_social_profiles.sql — creator_profiles becomes THE social profile.
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- Unchanged from 029: this is broadcast identity, server-readable by design. What changes is
-- its SCOPE. It was named for Clips; nothing in it was ever Clips-specific — handle, display
-- name, avatar, bio, counts, verification, suspension are what every public surface needs.
-- Communities and Games now read the same row, so one person is one identity everywhere they
-- are public.
-- =================================================================================
--
-- ── WHY THIS IS NOT COSMETIC ────────────────────────────────────────────────────
-- Communities and Games currently join `users` for display, selecting `u.photo_url`. That
-- column is the E2EE PROFILE PHOTO (021) — encrypted to a known audience, i.e. people the
-- user actually connected with. A community roster is visible to every member and a game
-- invite reaches strangers, so those surfaces were showing a photo that was encrypted for a
-- private audience. 029 created `avatar_r2_key` as plaintext precisely so public surfaces
-- would stop reusing the private one; Clips honoured that and the other two never did.
--
-- Renaming the table is what makes that mistake hard to repeat: a developer joining
-- `social_profiles` for a public surface is doing the obvious thing, where joining
-- `creator_profiles` from a community roster looked wrong and so was never done.
--
-- ── THE TRIGGER FUNCTION IS THE DANGEROUS PART ──────────────────────────────────
-- `assert_handle_available()` (030) branches on `tg_table_name` compared against STRING
-- LITERALS. After a rename `tbl` is 'social_profiles', so `tbl <> 'creator_profiles'` is true
-- while writing to that very table: it would check the table against itself, find the row
-- being inserted, and fail EVERY profile creation with "handle is taken". That is a runtime
-- failure no build catches, so the function is recreated here in the same transaction as the
-- rename. Do not split them.
--
-- ── IDEMPOTENT ──────────────────────────────────────────────────────────────────
-- Guarded on the old name existing, so a re-run after a partial apply is a no-op rather than
-- an error.

-- ─────────────────────────────────────────────────────────────────────────────────
-- 1. The tables
-- ─────────────────────────────────────────────────────────────────────────────────

do $$
begin
    if to_regclass('public.creator_profiles') is not null
       and to_regclass('public.social_profiles') is null then
        alter table creator_profiles rename to social_profiles;
    end if;

    if to_regclass('public.creator_handle_history') is not null
       and to_regclass('public.social_handle_history') is null then
        alter table creator_handle_history rename to social_handle_history;
    end if;

    if to_regclass('public.creator_follows') is not null
       and to_regclass('public.social_follows') is null then
        alter table creator_follows rename to social_follows;
    end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────────
-- 2. Named constraints and indexes
--
-- Renamed for readability only — a constraint called creator_profiles_handle_format on a
-- table called social_profiles is the kind of drift that makes the next person doubt which
-- one is authoritative. Each is guarded because 048/054 added some of them later.
-- ─────────────────────────────────────────────────────────────────────────────────

do $$
begin
    if exists (select 1 from pg_constraint where conname = 'creator_profiles_handle_format') then
        alter table social_profiles rename constraint creator_profiles_handle_format
            to social_profiles_handle_format;
    end if;
    if exists (select 1 from pg_constraint where conname = 'creator_profiles_display_name_len') then
        alter table social_profiles rename constraint creator_profiles_display_name_len
            to social_profiles_display_name_len;
    end if;
    if exists (select 1 from pg_constraint where conname = 'creator_profiles_bio_len') then
        alter table social_profiles rename constraint creator_profiles_bio_len
            to social_profiles_bio_len;
    end if;
    if exists (select 1 from pg_constraint where conname = 'creator_profiles_link_len') then
        alter table social_profiles rename constraint creator_profiles_link_len
            to social_profiles_link_len;
    end if;

    if to_regclass('public.idx_creator_profiles_discoverable') is not null then
        alter index idx_creator_profiles_discoverable
            rename to idx_social_profiles_discoverable;
    end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────────
-- 3. The handle-namespace trigger
--
-- Recreated with the new table name. The asymmetry, the `wanted` variable name and the
-- owner-exclusion rules are carried over verbatim from 030 — see that file's header for why
-- each one is the way it is. ONLY the table name changes.
-- ─────────────────────────────────────────────────────────────────────────────────

create or replace function assert_handle_available() returns trigger as $$
declare
    j      jsonb := to_jsonb(new);
    tbl    text  := tg_table_name;
    wanted text  := lower(j ->> (case when tbl = 'users' then 'username' else 'handle' end));
    owner  uuid  := (j ->> (case tbl when 'users'           then 'id'
                                     when 'social_profiles' then 'user_id'
                                     else                        'owner_id' end))::uuid;
begin
    if wanted is null then
        return new;
    end if;

    if exists (select 1 from reserved_handles where handle = wanted) then
        raise exception '% is reserved', wanted using errcode = 'unique_violation';
    end if;

    if tbl <> 'users' then
        if exists (select 1 from users u
                    where lower(u.username) = wanted
                      and (tbl = 'communities' or u.id <> owner)) then
            raise exception 'handle % is taken', wanted using errcode = 'unique_violation';
        end if;
    end if;

    if tbl <> 'social_profiles' then
        if exists (select 1 from social_profiles sp
                    where lower(sp.handle) = wanted
                      and (tbl = 'communities' or sp.user_id <> owner)) then
            raise exception 'handle % is taken', wanted using errcode = 'unique_violation';
        end if;
    end if;

    if tbl <> 'communities' then
        if exists (select 1 from communities c where lower(c.handle) = wanted) then
            raise exception 'handle % is taken', wanted using errcode = 'unique_violation';
        end if;
    end if;

    return new;
end;
$$ language plpgsql;

-- The trigger itself is renamed for the same readability reason as the constraints. It still
-- points at the same function, which now knows the new name.
do $$
begin
    if exists (select 1 from pg_trigger where tgname = 'trg_creator_handle_available') then
        alter trigger trg_creator_handle_available on social_profiles
            rename to trg_social_handle_available;
    end if;
end $$;

comment on table social_profiles is
    'Public social identity: one row per user, shared by Clips, Communities and Games. Plaintext by design — see 029 and 081 headers. Never confuse avatar_r2_key (public) with users.photo_url (E2EE).';
