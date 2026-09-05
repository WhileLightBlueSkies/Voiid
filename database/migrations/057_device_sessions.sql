-- =================================================================================
-- 057 — a session becomes a row, and revocation stops being a guess
--
-- Before this, "logged in" was a signature and nothing else. POST /auth/firebase minted a
-- 30-day JWT carrying only user_id; logout discarded it client-side; the API re-checked
-- that the ACCOUNT still existed but never that this DEVICE was still trusted. So a device
-- the user had explicitly revoked kept full access for up to a month — it could upload
-- prekeys (and, via routes/prekeys.ts, un-revoke ITSELF), send, fetch history and open a
-- socket on the relay. There was no server-side object a revocation could even be written
-- to. This migration creates one.
--
-- ── device_sessions ──────────────────────────────────────────────────────────────
--
-- One row per (device, sign-in). The JWT carries its `sid`, so authorization becomes a row
-- lookup that a revoke can invalidate, rather than a signature check that nothing can.
-- The row is the DURABLE authority: Redis in front of it is a 10-second cache, so losing
-- Redis costs a database round-trip, never a resurrected session. That direction matters —
-- a deny-list held only in a cache fails OPEN when the cache is flushed, which is precisely
-- the failure this issue exists to remove.
--
-- Why a table rather than a version counter on `devices`: revocation needs to distinguish
-- "this sign-in ended" from "this device is gone", and a per-session row keeps sign-in
-- history for the security-events trail. A counter would collapse both into one number and
-- lose which credential was actually cancelled.
--
-- `on delete cascade` on both parents: a session cannot outlive its device or its account,
-- and DPDP erasure (030) already removes the user row.
--
-- ── devices.revoked_reason ───────────────────────────────────────────────────────
--
-- `revoked_at` alone conflated two opposite events. Registering a device revokes its
-- same-platform siblings (a reinstall supersedes the old row), and prekey upload un-revokes
-- a device precisely so a superseded-but-live device can recover — that recovery path was
-- also, unavoidably, an "un-revoke me" button for a device the USER had revoked on purpose.
-- Separating the reasons lets the recovery keep working for 'superseded' while an explicit
-- 'user_revoked' becomes final: only a fresh registration, which needs a credential the
-- revoked device no longer has, can bring it back.
--
-- BACKFILL. Rows already revoked predate the distinction. Before this migration the only
-- writers of `revoked_at` were the sibling-superseding update in POST /devices/register and
-- DELETE /devices/:device_id, and the first vastly dominates in practice. 'superseded' is
-- therefore both the accurate label for almost all of them and the SAFE one to be wrong
-- about in the permissive direction: it preserves today's recovery behaviour for existing
-- rows instead of retroactively locking devices out on an assumption. New explicit revokes
-- are labelled correctly from the moment this ships.
-- =================================================================================

alter table devices add column if not exists revoked_reason text;

update devices
   set revoked_reason = 'superseded'
 where revoked_at is not null
   and revoked_reason is null;

create table if not exists device_sessions (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null references users(id) on delete cascade,
    device_id       uuid not null references devices(id) on delete cascade,
    -- Free-text, not an enum: the values ('user_revoked', 'superseded', 'account_deleted',
    -- 'logout') are an operational vocabulary that will grow, and a CHECK constraint here
    -- would make adding one a migration on a hot table.
    revoked_reason  text,
    revoked_at      timestamptz,
    last_seen_at    timestamptz,
    created_at      timestamptz not null default now()
);

-- The authorization lookup on every authenticated request: by primary key, with the user
-- and device pinned in the predicate so a session id alone proves nothing.
create index if not exists idx_device_sessions_device on device_sessions (device_id);
create index if not exists idx_device_sessions_active
    on device_sessions (user_id, device_id) where revoked_at is null;
