-- 007_message_read_receipts.sql
-- Delivery/read status is metadata (Section 4.8) — not content. Tracked per recipient device.

create table if not exists message_read_receipts (
    id              uuid primary key default gen_random_uuid(),
    message_id      uuid not null references messages(id) on delete cascade,
    user_id         uuid not null references users(id) on delete cascade,
    device_id       uuid references devices(id) on delete set null,
    status          text not null default 'delivered', -- delivered | read
    delivered_at    timestamptz,
    read_at         timestamptz,
    unique (message_id, user_id, device_id)
);

create index if not exists idx_receipts_message on message_read_receipts (message_id);
create index if not exists idx_receipts_user on message_read_receipts (user_id);
