-- 010_username.sql
-- Username for the Clips feature ONLY (messaging identity stays the phone number).
-- Nullable (existing users won't have one until they pick it), globally unique,
-- case-insensitive, with a format rule. Not used for auth or contact matching.

alter table users
    add column if not exists username text;

-- Format: 3–20 chars, lowercase letters/digits/underscore, must start with a letter.
-- (Enforced here so bad values can't reach the DB even if a client skips validation.)
alter table users
    drop constraint if exists users_username_format;
alter table users
    add constraint users_username_format
    check (username is null or username ~ '^[a-z][a-z0-9_]{2,19}$');

-- Case-insensitive uniqueness: two users can't take "Nehal" and "nehal".
-- (Format already forces lowercase, but the functional index is defensive.)
create unique index if not exists idx_users_username_lower
    on users (lower(username))
    where username is not null;
