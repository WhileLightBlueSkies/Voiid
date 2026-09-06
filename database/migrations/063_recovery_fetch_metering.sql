-- S04 — meter the thing the server can actually observe.
--
-- WHAT WAS FALSE. `failed_attempts` moves only when the client POSTs
-- /recovery/attempt-result with success:false. The client is the attacker in this
-- threat model, so it simply does not send that. Worse, it can POST success:true
-- and CLEAR the counter. So the existing columns are ABUSE TELEMETRY about honest
-- clients — they are not a security boundary, and the code used to claim they were.
--
-- WHAT THE SERVER CAN SEE. Exactly one thing: that someone fetched the wrap. That
-- fetch is unforgeable — an offline attacker MUST fetch the envelope at least once
-- before guessing, and cannot un-fetch it. It does not stop offline guessing (once
-- fetched, the wrap is theirs forever), but it bounds how many DISTINCT envelopes a
-- stolen token can harvest, and it makes the harvest visible.
--
-- This does NOT fix S04. S04 needs a reviewed protocol with a real boundary
-- (high-entropy phrase, or server-assisted OPRF/SVR). This makes the existing
-- counters honest and adds the one signal that cannot be faked by the client.
alter table recovery_keys
    add column if not exists fetch_count      integer not null default 0,
    add column if not exists last_fetched_at  timestamptz;

comment on column recovery_keys.failed_attempts is
    'CLIENT-REPORTED consecutive failed unwraps. Abuse telemetry only: a hostile client omits '
    'failures and may report success to reset this. Never treat as a security boundary.';
comment on column recovery_keys.fetch_count is
    'SERVER-OBSERVED count of envelope fetches. Unforgeable by the client. An offline attacker '
    'must fetch at least once, so this bounds and reveals harvesting; it does not prevent '
    'offline guessing against an envelope already fetched.';
