-- 080_creator_age_interests.sql — Age/birth date & algorithm interests for creator profiles.
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- See 029_creator_profiles.sql header. The creator profile is broadcast identity.
-- `birth_date` is CAPTURED PRIVATELY on the creator profile:
--   1. Used for safety and age gating (e.g. minor vs adult content safety).
--   2. Used by the recommendation algorithm to serve age-appropriate content.
--   3. NEVER returned on public profile lookups (sent only when is_self = true).
--
-- `interests` stores topic category tags (e.g. 'tech', 'gaming', 'comedy') chosen at
-- setup to seed the Explore recommendation algorithm.
-- =================================================================================

alter table creator_profiles
    add column if not exists birth_date date check (birth_date is null or birth_date <= current_date),
    add column if not exists interests text[] not null default '{}';

comment on column creator_profiles.birth_date is 'Private date of birth for age verification, safety gating and algorithm curation. Never shown publicly.';
comment on column creator_profiles.interests is 'Topic interests selected by the user to seed the recommendation feed.';
