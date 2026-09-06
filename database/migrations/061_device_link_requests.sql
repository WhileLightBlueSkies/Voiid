-- =================================================================================
-- 061 — linking a companion device becomes a durable, atomic thing
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────────
--
-- The whole linking handshake lived in Redis as one JSON blob, and every transition was
-- read-modify-write across three separate round trips:
--
--   approve:  GET the state -> check it says "pending" -> INSERT the device -> SET "approved"
--   poll:     GET the state -> check it says "approved" -> DEL the key -> return the token
--
-- Neither sequence is atomic, and both are reachable concurrently by design — the QR is on a
-- screen and the approving phone and the waiting browser are separate clients.
--
--   * TWO ACCOUNTS APPROVING AT ONCE both read "pending" and both register a device. One of
--     them ends up holding a device row nobody will ever use, and which account the waiting
--     browser is handed is decided by whichever SET landed last.
--   * TWO POLLS both read "approved" before either DELs, and the session credential is handed
--     out twice.
--   * A CRASH between the device INSERT and the SET leaves a registered device and a token
--     stuck on "pending": the browser polls forever and the device row is an orphan.
--   * A REDIS RESTART loses every link in flight, which is the ordinary cost of using a cache
--     as the system of record for a security handshake.
--
-- ── WHY A TABLE AND NOT A LUA SCRIPT ─────────────────────────────────────────────
--
-- The issue allows "an appropriate Redis transaction/script OR durable database transaction".
-- A row and `select ... for update` gives atomicity AND durability in the same move, and it
-- collapses the pending -> approving -> approved -> consumed machine the issue describes into
-- something simpler: with the device insert, the session and the state change in ONE
-- transaction, there is no intermediate state to be stuck in. Either the link is approved or
-- nothing happened.
--
-- ── THE TOKEN AT REST ────────────────────────────────────────────────────────────
--
-- `session_token` holds a real credential between approval and collection. That is not new —
-- it sat in Redis for the same window — but it is worth naming: the row is deleted the moment
-- it is collected, `expires_at` bounds it to minutes, and the sweep below removes anything
-- that was never collected. It should never be read by anything except the poll that consumes it.
-- =================================================================================

create table if not exists device_link_requests (
    -- The value encoded into the QR. Opaque, random, and the primary key so a duplicate is a
    -- constraint violation rather than an overwrite.
    token               text primary key,

    -- pending  -> waiting for a trusted device to approve it
    -- approved -> a device and session exist; the credential is waiting to be collected
    -- There is deliberately no 'approving': the transaction that approves does everything.
    status              text not null default 'pending',

    -- What the new device told us about itself at request time. Held here rather than
    -- re-supplied at approval, so the approving device cannot change what it is approving.
    platform            text not null,
    registration_id     integer not null,
    identity_public_key bytea not null,
    device_name         text,

    -- Filled by the approval, in the same transaction that creates them.
    approved_by         uuid references users(id) on delete cascade,
    device_id           uuid references devices(id) on delete set null,
    session_token       text,

    expires_at          timestamptz not null,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),

    constraint device_link_requests_status_check
        check (status in ('pending', 'approved')),
    -- An approved row has all three, a pending row has none. This is the invariant that makes
    -- "half-linked" unrepresentable rather than merely unlikely.
    constraint device_link_requests_approved_coherent
        check ((status = 'approved') = (approved_by is not null and device_id is not null and session_token is not null))
);

-- The expiry sweep, and the only query that is not by primary key.
create index if not exists idx_device_link_requests_expiry
    on device_link_requests (expires_at);

drop trigger if exists trg_device_link_requests_updated_at on device_link_requests;
create trigger trg_device_link_requests_updated_at before update on device_link_requests
    for each row execute function set_updated_at();

insert into data_retention_policy
    (table_name, personal_data, purpose, retention_basis, declared_interval, enforced_by,
     sweep_rule, counsel_note)
values
    ('device_link_requests',
     'A pending companion device''s public identity key and platform, and — for the few minutes between approval and collection — the account that approved it and the session credential minted for it.',
     'Carry a QR linking handshake between two devices atomically, so that two approvals cannot both register a device and two polls cannot both collect the credential.',
     'until_expiry', null, 'retention_worker',
     'Deleted on collection, which is the normal path. Anything not collected is deleted once expires_at has passed (minutes). A row that outlives its expiry is a credential nobody claimed and must not sit around.',
     '[COUNSEL] Unreviewed. Note specifically that session_token is a live credential at rest for the duration of the handshake — the same exposure the previous Redis implementation had, now written down rather than implicit.')
on conflict (table_name) do nothing;
