-- 001_users.sql
-- VOIID identity: phone number is identity (verified via OTP). No username system.
-- Display name = full name from signup. Identity + sessions are OURS (not Firebase, not Supabase Auth).

create extension if not exists "pgcrypto";

create table if not exists users (
    id              uuid primary key default gen_random_uuid(),
    phone_number    text not null unique,            -- E.164, e.g. +91XXXXXXXXXX. Our canonical identity.
    full_name       text,                            -- shown if contact not saved locally
    email           text,
    photo_url       text,                            -- R2 reference; profile photo (not E2E content)
    bio             text,
    status_text     text,
    -- DPDP: lawful consent capture at signup
    consent_given_at timestamptz,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    -- soft-delete for account-deletion flow; true purge handled by erasure job (DPDP)
    deleted_at      timestamptz
);

create index if not exists idx_users_phone on users (phone_number);

-- keep updated_at fresh
create or replace function set_updated_at() returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_users_updated_at on users;
create trigger trg_users_updated_at before update on users
    for each row execute function set_updated_at();
