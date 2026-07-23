-- 012_recovery.sql
-- Account recovery + encrypted backups (pairs with e2e-core src/recovery.rs).
--
-- SECURITY MODEL: the server stores ONLY opaque, client-encrypted material.
--   * recovery_keys.wrapped_key — a PinWrappedSecret (Argon2id + AES-256-GCM wrap
--     of the master backup secret, produced by recovery.rs). The server never sees
--     the PIN or the secret; a wrong PIN fails the GCM tag on-device.
--   * backups — metadata only; the E2E-encrypted backup blob itself lives in R2.
-- There is ALSO a BIP39 recovery phrase, but that is CLIENT-SIDE ONLY — the phrase
-- IS the secret (BIP39 entropy), so the server stores nothing for it.
--
-- Guess limiting: failed_attempts/locked_until slow ONLINE PIN guessing on a new
-- device. A fully-breached server + a weak PIN is still offline-brute-forceable
-- against wrapped_key (accepted "no-SGX" trade-off; the BIP39 phrase is the strong
-- fallback). An SGX-backed secure value recovery (SVR) service is a future upgrade
-- that would close the offline attack.

-- One PIN-wrapped master secret per user. wrapped_key is an opaque PinWrappedSecret
-- { version, salt, nonce, ciphertext } — the server cannot interpret its contents.
create table if not exists recovery_keys (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null unique references users(id) on delete cascade,
    wrapped_key     jsonb not null,                    -- opaque PinWrappedSecret
    failed_attempts integer not null default 0,        -- consecutive failed online PIN attempts
    locked_until    timestamptz,                       -- online-guessing cooldown; null = not locked
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
create index if not exists idx_recovery_keys_user on recovery_keys (user_id);

drop trigger if exists trg_recovery_keys_updated_at on recovery_keys;
create trigger trg_recovery_keys_updated_at before update on recovery_keys
    for each row execute function set_updated_at();

-- Encrypted backup metadata. The ciphertext blob lives in R2 at r2_object_key;
-- this row is the pointer + size. One current backup per user (upserted on PUT).
create table if not exists backups (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null unique references users(id) on delete cascade,
    r2_object_key   text not null,                     -- opaque R2 object key (ciphertext)
    size_bytes      bigint not null,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
create index if not exists idx_backups_user on backups (user_id);

drop trigger if exists trg_backups_updated_at on backups;
create trigger trg_backups_updated_at before update on backups
    for each row execute function set_updated_at();
