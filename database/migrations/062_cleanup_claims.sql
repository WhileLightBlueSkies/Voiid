-- Cleanup intent survives metadata deletion. Tokens fence expired workers.
alter table erasure_pending_objects
  add column if not exists claim_token uuid,
  add column if not exists lease_until timestamptz,
  add column if not exists next_attempt_at timestamptz not null default now();
create index if not exists erasure_pending_objects_due
  on erasure_pending_objects(next_attempt_at, queued_at);
