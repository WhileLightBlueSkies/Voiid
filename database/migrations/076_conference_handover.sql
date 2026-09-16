-- Serialize rollback with committing the P2P -> room handover.
alter table calls add column if not exists escalation_completed_at timestamptz;
