-- 008_contact_sync.sql
-- Contact sync (Section 2.3 / 4.8): matching is LOCAL on-device. The raw contact book is NEVER uploaded.
-- This table only records which VOIID users a given user has discovered, by referencing OUR user ids.
-- It stores NO raw phone numbers from the address book — only resolved VOIID user_id links.

create table if not exists contact_sync (
    id                  uuid primary key default gen_random_uuid(),
    owner_user_id       uuid not null references users(id) on delete cascade,
    -- the matched VOIID user (resolution happens on-device; server only stores the link)
    contact_user_id     uuid not null references users(id) on delete cascade,
    -- locally-saved display name, if the owner chose to sync it (optional; never the raw address book)
    saved_name          text,
    created_at          timestamptz not null default now(),
    unique (owner_user_id, contact_user_id)
);

create index if not exists idx_contact_sync_owner on contact_sync (owner_user_id);
