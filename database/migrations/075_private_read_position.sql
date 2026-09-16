-- Recipient-owned read state is independent of sender-visible receipts.
alter table conversation_members add column if not exists last_read_at timestamptz;
