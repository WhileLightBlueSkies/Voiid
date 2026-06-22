-- 011_mls.sql
-- MLS (RFC 9420) group-messaging plumbing (Phase 3). The server stores/relays only
-- OPAQUE MLS bytes — KeyPackages (public), Welcome/Commit control messages, and
-- application ciphertext (which rides the existing messages table). No group keys.

-- Public KeyPackages a device publishes so others can add it to a group.
-- One-time use (consumed when someone adds the device), mirroring one-time prekeys.
create table if not exists mls_key_packages (
    id            uuid primary key default gen_random_uuid(),
    user_id       uuid not null references users(id) on delete cascade,
    device_id     uuid not null references devices(id) on delete cascade,
    key_package   bytea not null,           -- opaque TLS-serialized KeyPackage
    created_at    timestamptz not null default now(),
    consumed_at   timestamptz
);
create index if not exists idx_mls_kp_user_unconsumed
    on mls_key_packages (user_id) where consumed_at is null;

-- Group control messages (Welcome to a new member, Commit to existing members).
-- Delivered once to each recipient, then marked delivered. Payload is opaque MLS.
create table if not exists mls_group_events (
    id                 uuid primary key default gen_random_uuid(),
    conversation_id    uuid not null references conversations(id) on delete cascade,
    sender_user_id     uuid not null references users(id) on delete cascade,
    recipient_user_id  uuid not null references users(id) on delete cascade,
    kind               text not null check (kind in ('welcome','commit')),
    payload            bytea not null,       -- opaque Welcome or Commit
    ratchet_tree       bytea,                -- present for 'welcome' (join needs it)
    created_at         timestamptz not null default now(),
    delivered_at       timestamptz
);
create index if not exists idx_mls_events_recipient_undelivered
    on mls_group_events (recipient_user_id) where delivered_at is null;
