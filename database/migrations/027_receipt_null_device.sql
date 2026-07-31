-- 027_receipt_null_device.sql
--
-- THE RECEIPT UPSERT NEVER FIRED FOR A NULL device_id.
--
-- 007 declared `unique (message_id, user_id, device_id)` with device_id NULLABLE
-- (`references devices(id) on delete set null`). In Postgres a unique constraint treats NULLs
-- as DISTINCT, so two rows with the same message + user and a NULL device do not collide.
--
-- routes/receipts.ts upserts with `on conflict (message_id, user_id, device_id)`. When the
-- caller's token carries no device_id — `device_id ?? null` — that conflict target can never
-- match, so every mark INSERTS instead of updating. Consequences, in order of severity:
--
--   1. The `where message_read_receipts.status is distinct from 'read'` guard is bypassed.
--      That guard is the ONLY thing preventing a late out-of-order 'delivered' from
--      downgrading a 'read'. With separate rows there is nothing to downgrade — but there
--      are now two contradictory rows for one recipient.
--   2. Rows accumulate without bound: one per mark call, forever, for the same message.
--   3. GET /messages aggregates with bool_or(r.status = 'read'), which is why the sender
--      could still see Seen and the bug stayed invisible from the outside.
--
-- Verified against a scratch Postgres: two NULL-device upserts produce TWO rows
-- ('delivered','read'); the same pair with a real device_id correctly produces ONE ('read').
--
-- THE FIX: make the uniqueness NULL-aware rather than making device_id NOT NULL. A receipt
-- from a client whose token predates per-device auth is still a valid receipt, and forcing a
-- device id would mean either dropping those or inventing a fake one.
--
-- Two partial indexes, which is the standard way to express this before Postgres 15's
-- NULLS NOT DISTINCT (not assumed here — this must run on whatever the deployment has):
--   * device_id IS NOT NULL -> uniqueness on the full triple, as today
--   * device_id IS NULL     -> uniqueness on (message_id, user_id), so the NULL row is
--                              genuinely one row per recipient
--
-- Both are what `on conflict` needs to infer a target, so the route can name each explicitly.

-- ─────────────────────────────────────────────────────────────────────────────────
-- Collapse the duplicates 007 allowed, keeping the FURTHEST-ADVANCED state.
--
-- Ordering is by status rank, not by id or timestamp: receipts can be written out of order
-- (a delayed 'delivered' arriving after a 'read'), so "latest row wins" would silently
-- downgrade exactly the messages this migration exists to fix. Timestamps are merged with
-- max() across the group so neither delivered_at nor read_at is lost with the discarded row.
-- ─────────────────────────────────────────────────────────────────────────────────
with ranked as (
    select id,
           message_id,
           user_id,
           row_number() over (
               partition by message_id, user_id
               order by case status when 'read' then 2 when 'delivered' then 1 else 0 end desc,
                        id
           ) as rn
      from message_read_receipts
     where device_id is null
),
merged as (
    select r.message_id,
           r.user_id,
           max(m.delivered_at) as delivered_at,
           max(m.read_at)      as read_at
      from ranked r
      join message_read_receipts m
        on m.message_id = r.message_id and m.user_id = r.user_id and m.device_id is null
     group by r.message_id, r.user_id
)
update message_read_receipts t
   set delivered_at = coalesce(t.delivered_at, mg.delivered_at),
       read_at      = coalesce(t.read_at, mg.read_at)
  from ranked r
  join merged mg on mg.message_id = r.message_id and mg.user_id = r.user_id
 where t.id = r.id and r.rn = 1;

delete from message_read_receipts t
 using (
    select id,
           row_number() over (
               partition by message_id, user_id
               order by case status when 'read' then 2 when 'delivered' then 1 else 0 end desc,
                        id
           ) as rn
      from message_read_receipts
     where device_id is null
 ) d
 where t.id = d.id and d.rn > 1;

-- ─────────────────────────────────────────────────────────────────────────────────
-- Replace the table constraint with two partial indexes.
--
-- The constraint has to go: it is what makes the NULL case unenforceable, and a constraint
-- and an index covering the same triple would just be duplicated work on every write.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table message_read_receipts
    drop constraint if exists message_read_receipts_message_id_user_id_device_id_key;

create unique index if not exists idx_receipts_unique_device
    on message_read_receipts (message_id, user_id, device_id)
    where device_id is not null;

create unique index if not exists idx_receipts_unique_no_device
    on message_read_receipts (message_id, user_id)
    where device_id is null;

comment on index idx_receipts_unique_no_device is
    'Makes ON CONFLICT work for receipts from a token with no device_id. Without it the '
    'nullable column in the old unique constraint made every such upsert insert a new row, '
    'bypassing the never-downgrade guard. See 027.';
