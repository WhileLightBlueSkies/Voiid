-- 004_otp_sessions.sql
-- OTP auth (Section 4.7). Firebase = SMS sender only; identity is OURS.
-- OTP stored as HASH ONLY (never plaintext). Expiry 5 min; max 3 attempts; rate-limited.

create table if not exists otp_sessions (
    id              uuid primary key default gen_random_uuid(),
    phone_number    text not null,
    otp_hash        text not null,                    -- bcrypt/argon2 hash of the code — NEVER plaintext
    provider        text not null default 'firebase', -- firebase | msg91 | twilio (swappable)
    attempts        integer not null default 0,       -- max 3
    verified_at     timestamptz,
    expires_at      timestamptz not null,             -- created_at + 5 min
    created_at      timestamptz not null default now()
);

create index if not exists idx_otp_phone on otp_sessions (phone_number);
create index if not exists idx_otp_expiry on otp_sessions (expires_at);
