-- =================================================================================
-- 060 — delivery is something the DEVICE reports, not something the server assumes
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────────
--
-- GET /messages/pending stamped `message_ciphertexts.delivered_at` in the same statement
-- that READ the ciphertext, and that transaction committed before the response left the
-- process. Everything after that point was assumed rather than known: the socket could drop,
-- the phone could be killed on the walk from the tunnel to the platform, the disk write could
-- fail. The row said delivered, the next fetch omitted it, and the message was gone — with no
-- error raised anywhere and nothing to retry from. GET /messages/conversation did the same
-- thing as a side effect of scrolling.
--
-- Fetch is now a read. `delivered_at` is written by POST /messages/ack, which a device sends
-- only after the ciphertext is durably on its own storage.
--
-- ── THE THREE STATES, WHICH USED TO BE TWO ───────────────────────────────────────
--
--   server-accepted  the `messages` row exists. We have it; nobody has it yet.
--   client-stored    `delivered_at` (fan-out) or a `message_deliveries` row (legacy). A
--                    specific DEVICE has it on disk. This is the state that was being
--                    inferred from "we sent some bytes".
--   user-read        `message_read_receipts`. A person looked at it.
--
-- ── WHY LEGACY NEEDS ITS OWN TABLE ───────────────────────────────────────────────
--
-- A fan-out message has one row per recipient device, so per-device delivery has somewhere
-- to live. A legacy single-ciphertext message has ONE row shared by everyone in the
-- conversation, and its delivery state was the `messages.is_pending` boolean — one bit for
-- every recipient. One device marking it collapsed it for all of them, which in a group is
-- the whole point of the bug: your phone fetching a message deleted it from your tablet's
-- queue and from every other member's.
--
-- `message_deliveries` is that missing dimension. `device_id` is nullable because a
-- device-less legacy client still exists (027), and the unique index coalesces it to a
-- sentinel rather than including a NULL — a NULL in a unique key never matches, so the
-- constraint would silently permit unbounded duplicates while looking correct.
--
-- `is_pending` is left in place and untouched. It is still read by the legacy fetch as the
-- sender's "this was never picked up" flag, and rewriting that column's meaning in the same
-- change that fixes delivery would make both harder to reason about.
-- =================================================================================

create table if not exists message_deliveries (
    message_id      uuid not null references messages(id) on delete cascade,
    user_id         uuid not null references users(id) on delete cascade,
    -- Null for a device-less legacy client. See the coalesce in the index below.
    device_id       uuid references devices(id) on delete cascade,
    acknowledged_at timestamptz not null default now()
);

create unique index if not exists idx_message_deliveries_unique
    on message_deliveries (
        message_id,
        user_id,
        coalesce(device_id, '00000000-0000-0000-0000-000000000000'::uuid)
    );

-- The legacy pending query's anti-join: "what has this device NOT acknowledged yet".
create index if not exists idx_message_deliveries_recipient
    on message_deliveries (user_id, device_id, message_id);

-- ─────────────────────────────────────────────────────────────────────────────────
-- RETENTION, DECLARED RATHER THAN LEFT IMPLICIT
--
-- M02 asks for explicit rules for acknowledged and unacknowledged data, and the honest
-- statement is that both live for the lifetime of the account and neither is swept on a
-- clock today. Writing that down is the point: a policy table row is reviewable, and
-- "nobody ever wrote one" is not.
--
-- The reason a time sweep would be wrong HERE, specifically: an unacknowledged ciphertext is
-- a message its recipient has not received yet. Deleting it on age would destroy undelivered
-- mail for exactly the users worst served by the product — someone offline for a fortnight,
-- someone whose phone is in a drawer. If a cap is ever wanted it belongs with a deliberate
-- product decision about how long Voiid holds undelivered mail, not as a side effect of a
-- retention default.
-- ─────────────────────────────────────────────────────────────────────────────────
insert into data_retention_policy
    (table_name, personal_data, purpose, retention_basis, declared_interval, enforced_by,
     sweep_rule, counsel_note)
values
    ('message_ciphertexts',
     'One opaque, end-to-end encrypted blob per recipient device, plus the recipient device id and the time that device acknowledged storing it. The server holds no key and cannot read the content; the metadata is who was addressed and when they picked it up.',
     'Carry a message to each of a recipient''s devices and know which of them still need it. `delivered_at` is what stops a device being handed the same message forever, and what tells a sender their message arrived.',
     'account_lifetime', null, 'erasure_worker',
     'No time sweep, deliberately. Rows die with the conversation and with the account, via ON DELETE CASCADE from messages; the erasure worker owns them. An UNACKNOWLEDGED row is undelivered mail, and deleting it on age would silently destroy messages for the users least able to fetch them promptly — someone offline for two weeks, someone whose phone is in a drawer. Any cap on how long undelivered mail is held must be a product decision made on purpose, not a retention default.',
     '[COUNSEL] Unreviewed. The content is ciphertext the server cannot read, but the row is still an assertion that two accounts exchanged a message at a time — traffic metadata, which several regimes treat as personal data in its own right. Whether account_lifetime is defensible for that metadata, and whether a delivered-and-acknowledged blob should be dropped sooner than the account it belongs to, are both open.')
on conflict (table_name) do nothing;

insert into data_retention_policy
    (table_name, personal_data, purpose, retention_basis, declared_interval, enforced_by,
     sweep_rule, counsel_note)
values
    ('message_deliveries',
     'Which recipient device acknowledged storing which legacy single-ciphertext message, and when. No content: the row is an acknowledgement and nothing else.',
     'Track legacy delivery PER RECIPIENT. Before this table one shared flag on the message stood in for every recipient, so one device fetching a message removed it from every other device''s queue.',
     'account_lifetime', null, 'erasure_worker',
     'No time sweep. Rows die with the message and with the account, via ON DELETE CASCADE from both messages and users; the erasure worker owns them. Sweeping these on age would make an old message pending again for a device that already has it, which is the exact duplicate this table exists to prevent.',
     '[COUNSEL] Unreviewed, and the same open question as message_ciphertexts: this is delivery metadata about a pair of accounts, held for the life of the account, with no content attached.')
on conflict (table_name) do nothing;
