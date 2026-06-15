-- 003_prekeys.sql
-- Prekey server (Section 3.2 "you build"): storage + distribution of PUBLIC prekey bundles.
-- X3DH session setup consumes one one-time prekey per session. Signed prekey rotates every 30 days.

-- Signed prekey: one current per device, rotated every 30 days (Section 4.4).
create table if not exists signed_prekeys (
    id                  uuid primary key default gen_random_uuid(),
    device_id           uuid not null references devices(id) on delete cascade,
    key_id              integer not null,
    public_key          bytea not null,
    signature           bytea not null,               -- signed by the device identity key
    created_at          timestamptz not null default now(),
    unique (device_id, key_id)
);
create index if not exists idx_signed_prekeys_device on signed_prekeys (device_id);

-- One-time prekeys: consumed on session setup, auto-replenished by client.
create table if not exists one_time_prekeys (
    id                  uuid primary key default gen_random_uuid(),
    device_id           uuid not null references devices(id) on delete cascade,
    key_id              integer not null,
    public_key          bytea not null,
    consumed_at         timestamptz,                  -- set when handed out for a session
    created_at          timestamptz not null default now(),
    unique (device_id, key_id)
);
-- fast "give me an unconsumed prekey for this device"
create index if not exists idx_otp_keys_available
    on one_time_prekeys (device_id) where consumed_at is null;

-- Convenience view of a device's current prekey bundle (identity + signed + one available one-time key
-- is assembled in the API by consuming an unconsumed one_time_prekey transactionally).
