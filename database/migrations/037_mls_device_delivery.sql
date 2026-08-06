-- 037_mls_device_delivery.sql — per-DEVICE MLS event delivery, and one payload per event.
--
-- ── THE BUG THIS FIXES ───────────────────────────────────────────────────────────
-- `mls_group_events` was keyed on recipient_user_id, and GET /mls/group-events marked
-- EVERY undelivered row for that user delivered on the first fetch. So on an account with
-- two devices, whichever one polled first consumed the commits and the other never saw
-- them — not "later", never.
--
-- A LOST COMMIT IS NOT RECOVERABLE. `max_past_epochs = 0` in the MLS core, so a member who
-- misses one commit cannot decrypt anything from that epoch onward and cannot catch up:
-- their copy of the group is dead and the only repair is being removed and re-added. A
-- second device was therefore guaranteed to be broken from its first sync.
--
-- ── THE SECOND PROBLEM: O(N²) STORAGE ────────────────────────────────────────────
-- One row per recipient meant one COPY of the payload per recipient. A commit in a
-- 1000-member group wrote 1000 rows each carrying the full ciphertext, and group creation
-- posts a commit per already-added member per add — roughly 500,000 rows at N=1000, each
-- with a payload. The event is identical for everyone; only WHO HAS SEEN IT differs.
--
-- So the payload moves to one row per event and delivery becomes its own tiny table. That
-- is also what makes per-device delivery affordable: tracking N_devices instead of N_users
-- would have multiplied a payload copy, and now multiplies only a pair of ids.
--
-- NO CRYPTO CHANGES HERE. This is storage and delivery. The payloads are the same opaque
-- bytes, produced and consumed by the same code.

-- ─────────────────────────────────────────────────────────────────────────────────
-- Delivery, tracked per device
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists mls_event_deliveries (
    event_id     uuid not null references mls_group_events(id) on delete cascade,
    -- The DEVICE, not the user. That distinction is the entire fix.
    device_id    uuid not null references devices(id) on delete cascade,
    -- Denormalised so the hot query ("what does this device still need") is one index scan
    -- and never joins back to the event to find out whose it is.
    recipient_user_id uuid not null references users(id) on delete cascade,
    delivered_at timestamptz,
    primary key (event_id, device_id)
);

-- THE hot query: undelivered rows for one device, oldest first. Partial, because a
-- delivered row is never read again — it exists only to prove the device got it.
create index if not exists idx_mls_deliveries_pending
    on mls_event_deliveries (device_id, event_id)
    where delivered_at is null;

-- Used by the sweep that reaps events every recipient has taken.
create index if not exists idx_mls_deliveries_event
    on mls_event_deliveries (event_id);

-- ─────────────────────────────────────────────────────────────────────────────────
-- Backfill
--
-- Existing rows are per-user, so fan them out to that user's live devices. UNDELIVERED
-- rows only: a row already marked delivered was consumed by whichever device fetched it,
-- and re-queueing it for the others cannot help — see max_past_epochs above. Those groups
-- are already broken on the second device and this migration cannot un-break them.
--
-- Recorded here rather than silently skipped, because "why does my iPad show an empty
-- group" has an answer and it is this.
-- ─────────────────────────────────────────────────────────────────────────────────
insert into mls_event_deliveries (event_id, device_id, recipient_user_id)
select e.id, d.id, e.recipient_user_id
  from mls_group_events e
  join devices d
    on d.user_id = e.recipient_user_id
   and d.revoked_at is null
 where e.delivered_at is null
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────────
-- Slimming the event row
--
-- `recipient_user_id` stays for now, NOT NULL and still populated by the fan-out, because
-- dropping it would break any deploy where old code briefly runs against new schema. It is
-- no longer READ by the delivery path — mls_event_deliveries is the authority — and a
-- later migration can drop it once every instance is on the new code.
--
-- Same for delivered_at: left in place, no longer consulted.
-- ─────────────────────────────────────────────────────────────────────────────────
comment on column mls_group_events.recipient_user_id is
  'LEGACY. Delivery is tracked in mls_event_deliveries, per DEVICE. Kept only so a rolling '
  'deploy of old code does not break; do not read it.';
comment on column mls_group_events.delivered_at is
  'LEGACY. See recipient_user_id. mls_event_deliveries.delivered_at is the truth.';
