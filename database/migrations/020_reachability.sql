-- 020_reachability.sql
--
-- WHO IS ALLOWED TO MESSAGE YOU.
--
-- Until now anyone holding your user id could open a 1:1, because the only way to find that
-- id was address-book discovery — the address book WAS the gate. Introducing username search
-- removes that gate, so it is replaced here with two explicit ones:
--
--   1. mutual contacts        -> chat opens directly (both sides have each other saved)
--   2. one-way contact        -> arrives as a REQUEST (Accept / Decline)
--   3. found by @username     -> must present the target's 6-digit PIN, THEN a REQUEST
--
-- Path 2 is deliberately not auto-accepted. Treating "I have your number" as sufficient is
-- what turns a leaked number list into spam on other platforms; requiring the contact link to
-- be MUTUAL costs a real acquaintance one tap and costs a bulk sender everything.
--
-- NOTHING HERE TOUCHES THE ENCRYPTION. This is server-side authorisation for creating a
-- conversation row. Key exchange and the Double Ratchet are unchanged; a pending request is
-- ordinary ciphertext the server cannot read, simply not yet surfaced as a normal chat.

-- ─────────────────────────────────────────────────────────────────────────────────
-- The contact PIN
--
-- A proof-of-acquaintance token, given out of band ("my Voiid is @nehal, PIN 418302").
-- It is NOT a password and MUST NOT gate account access: knowing it only lets someone open
-- a request, which the recipient still has to accept.
--
-- HASHED, never plaintext. Six digits is a 1,000,000 space — small enough that a database
-- leak plus a fast hash would be reversible in seconds, so this uses bcrypt like every other
-- secret in the system.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table users
    add column if not exists contact_pin_hash text,
    add column if not exists contact_pin_set_at timestamptz;

-- ─────────────────────────────────────────────────────────────────────────────────
-- Request state
--
-- Lives on the MEMBERSHIP, not the conversation: a 1:1 has two sides with different states —
-- the sender has implicitly accepted by sending, the recipient has not. One flag on the
-- conversation would need a second column to record WHOSE pending it is, which is the same
-- thing with more room for bugs. Per-member also generalises to group invites for free.
--
-- Default 'accepted' so every EXISTING membership keeps working untouched.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table conversation_members
    add column if not exists request_state text not null default 'accepted',
    -- How this conversation was opened, so the UI can say "found you via @handle".
    add column if not exists opened_via text;

alter table conversation_members
    drop constraint if exists conversation_members_request_state_check;
alter table conversation_members
    add constraint conversation_members_request_state_check
    check (request_state in ('pending', 'accepted', 'declined'));

alter table conversation_members
    drop constraint if exists conversation_members_opened_via_check;
alter table conversation_members
    add constraint conversation_members_opened_via_check
    check (opened_via is null or opened_via in ('contact', 'username'));

-- Pending requests are read on every conversation list load, for one user at a time.
create index if not exists idx_members_pending
    on conversation_members (user_id, request_state)
    where request_state = 'pending';

-- ─────────────────────────────────────────────────────────────────────────────────
-- Brute-force ledger
--
-- RATE LIMITING IS THE WHOLE SECURITY MODEL HERE, not a nicety. Six digits is 1,000,000
-- combinations, which an unthrottled attacker exhausts in minutes — without this table the
-- PIN is decoration.
--
-- Keyed on the TARGET (plus whatever we know about the sender) rather than only on the
-- sender's user id, so making a fresh account does not reset the counter against a victim.
-- `sender_user_id` is nullable and ON DELETE SET NULL precisely so a deleted attacker account
-- does not erase the evidence of its attempts.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists contact_pin_attempts (
    id             uuid primary key default gen_random_uuid(),
    target_user_id uuid not null references users(id) on delete cascade,
    sender_user_id uuid references users(id) on delete set null,
    sender_ip      inet,
    succeeded      boolean not null default false,
    attempted_at   timestamptz not null default now()
);

-- The hot path: "how many times has this sender tried this target recently".
create index if not exists idx_pin_attempts_target_time
    on contact_pin_attempts (target_user_id, attempted_at desc);
create index if not exists idx_pin_attempts_sender_time
    on contact_pin_attempts (sender_user_id, attempted_at desc)
    where sender_user_id is not null;
