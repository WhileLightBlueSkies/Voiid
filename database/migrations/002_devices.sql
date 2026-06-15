-- 002_devices.sql
-- Device trust model (Section 4.3). Identity = phone; devices establish trust independently.
-- Each device has unique key material. Server stores PUBLIC keys only — private keys NEVER leave the device.

create table if not exists devices (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references users(id) on delete cascade,
    device_name         text,                         -- e.g. "iPhone 15", "Web"
    platform            text not null,                -- ios | android | web
    registration_id     integer not null,             -- libsignal registration id
    -- PUBLIC identity key only. Private identity key stays in hardware-backed storage on device.
    identity_public_key bytea not null,
    -- push delivery target for content-free wake notifications (no plaintext ever in a push)
    push_token          text,
    push_provider       text,                         -- apns | fcm
    last_seen_at        timestamptz,
    revoked_at          timestamptz,                  -- device revocation invalidates sessions immediately
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    unique (user_id, registration_id)
);

create index if not exists idx_devices_user on devices (user_id);
create index if not exists idx_devices_active on devices (user_id) where revoked_at is null;

drop trigger if exists trg_devices_updated_at on devices;
create trigger trg_devices_updated_at before update on devices
    for each row execute function set_updated_at();
