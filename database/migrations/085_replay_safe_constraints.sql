-- 085_replay_safe_constraints.sql — make 065's constraint survive a second replay.
--
-- 065 does a bare `alter table ... add constraint`, which has no IF NOT EXISTS. Applying the
-- migration set twice against the same database therefore aborts there. That matters because
-- the migration-replay CI job does exactly that, and because a developer re-running the set
-- locally should not need a fresh database.
--
-- ── WHY A NEW FILE AND NOT AN EDIT TO 065 ───────────────────────────────────────
-- I edited 065 in place first, which was wrong and the deploy caught it:
--
--     [migrate] aborted: 065_web_companion_link_proof.sql: checksum mismatch
--
-- migrate.mjs records a sha256 of every file it applies and refuses to continue when one
-- changes. That refusal is correct — an already-applied migration that quietly changes shape
-- is how two environments end up with different schemas and nobody can tell which is right.
-- The rule it enforces is in its own error message: restore the applied file, add a new one.
--
-- So every file I touched is restored byte-for-byte to the version whose hash is recorded,
-- and all the guards live here instead. That is 065, 066, 067, 069, 070 and 071 — I first
-- assumed only 065 had been applied, which was wrong: the others were recorded too and would
-- have aborted the deploy in turn.
--
-- Everything below is written to be safe whether or not the original already did it, because
-- on an existing database it has, and on a fresh one 085 runs after the file that did.

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'device_link_poll_hash_length') then
        alter table device_link_requests add constraint device_link_poll_hash_length
            check (poll_secret_hash is null or octet_length(poll_secret_hash) = 32);
    end if;
end $$;

-- 066: two constraints on communities.
do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'communities_official_key_check') then
        alter table communities add constraint communities_official_key_check
            check (official_key is null or official_key in ('jobs', 'feedback', 'updates'));
    end if;
    if not exists (select 1 from pg_constraint where conname = 'communities_posting_policy_check') then
        alter table communities add constraint communities_posting_policy_check
            check (posting_policy in ('members', 'managers'));
    end if;
end $$;

-- 067: commission columns, the balance constraint and its trigger.
alter table communities  add column if not exists event_commission_bps integer not null default 2500;
alter table event_orders add column if not exists commission_bps integer;
alter table event_orders add column if not exists commission_minor bigint;
alter table event_orders add column if not exists organiser_minor bigint;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'event_order_commission_balanced') then
        alter table event_orders add constraint event_order_commission_balanced check (
          (commission_bps is null and commission_minor is null and organiser_minor is null) or
          (commission_bps is not null and commission_minor is not null and organiser_minor is not null
           and commission_minor >= 0 and organiser_minor >= 0
           and commission_minor + organiser_minor = amount_minor));
    end if;
end $$;

-- `create trigger` has no IF NOT EXISTS either. Dropping first is safe: it is recreated
-- immediately, pointing at the same function.
drop trigger if exists event_order_commission_snapshot on event_orders;
create trigger event_order_commission_snapshot before insert or update on event_orders
  for each row execute function snapshot_event_commission();

-- 070: admission columns on event_orders.
alter table event_orders add column if not exists admission_mode text;

-- 071: the singleton collection row. ON CONFLICT rather than a guard, because the whole
-- point of the row is that there is exactly one.
insert into admin_usage_collection(id) values(true) on conflict (id) do nothing;
