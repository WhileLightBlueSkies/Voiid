-- =================================================================================
-- 059 — a send can be retried, and the announcement of it survives Redis
--
-- Two failures, both of which end with the user seeing the wrong thing.
--
-- ── 1. A RETRY WAS A SECOND MESSAGE ──────────────────────────────────────────────
--
-- POST /messages/send had no stable client id. If the reply was lost — the socket died, the
-- app was killed, the network changed between "committed" and "200" — the client had no way
-- to know whether the send had landed, and the only safe-looking thing it could do was send
-- again. That produced a second row, a second bubble for the recipient, and no way for the
-- sender to tell which of the two was the real one.
--
-- `client_message_id` is minted on the device before transmission and is stable across every
-- retry of that same message. `payload_fingerprint` is a SHA-256 over what was actually sent,
-- so a retry can be told apart from a DIFFERENT message reusing a key: the first is answered
-- with the original message, the second is refused. Without the fingerprint, a buggy client
-- that reused a counter would silently have its second message swallowed and reported as
-- delivered — a worse failure than the one being fixed, because it is invisible.
--
-- ── THE UNIQUE INDEX IS NULL-FREE BY CONSTRUCTION ────────────────────────────────
--
-- `sender_device_id` is nullable (device-less legacy clients still send). A NULL anywhere in
-- a unique key makes the constraint never match, which would turn every retry back into a new
-- message while looking exactly like it worked — the 027_receipt_null_device bug, with the
-- same shape and a worse blast radius. So the index is on a COALESCED expression, and the
-- all-zero uuid stands in for "no device". It is a partial index because a client that sends
-- no id at all is still supported and must not collide with every other such client.
--
-- ── 2. THE ANNOUNCEMENT WAS FIRE-AND-FORGET ──────────────────────────────────────
--
-- The message row committed, and then the route published a wake to Redis. If that publish
-- failed — Redis restarting, a network blip, the process dying in between — the message
-- existed and NOBODY WAS EVER TOLD. It would surface whenever the recipient next happened to
-- poll, which on a backgrounded phone can be a very long time.
--
-- `message_outbox` makes the obligation durable: the rows are written in the SAME transaction
-- as the message, so a committed message always carries its unsent announcements with it. The
-- route still publishes inline immediately afterwards — that is the fast path and it is what
-- normally settles them — and anything left `pending` is a promise the worker keeps.
--
-- This is at-least-once, deliberately, and the payloads are wake hints rather than content:
-- a duplicate wake costs a redundant fetch of a message the client dedupes by id, while a
-- lost wake costs a message nobody knows about.
-- =================================================================================

alter table messages
    add column if not exists client_message_id   text,
    add column if not exists payload_fingerprint bytea;

do $$ begin
    alter table messages
        add constraint messages_client_id_len
        check (client_message_id is null or char_length(client_message_id) between 1 and 200);
exception when duplicate_object then null;
end $$;

create unique index if not exists idx_messages_client_idempotency
    on messages (
        sender_id,
        coalesce(sender_device_id, '00000000-0000-0000-0000-000000000000'::uuid),
        client_message_id
    )
    where client_message_id is not null;

create table if not exists message_outbox (
    id           uuid primary key default gen_random_uuid(),
    message_id   uuid not null references messages(id) on delete cascade,

    -- The Redis channel this wake is owed to, verbatim ('channel:user:<uuid>'). Stored rather
    -- than recomputed so the worker needs to know nothing about how routing is derived — the
    -- transaction that knew the recipients is the one that wrote them down.
    channel      text not null,
    payload      jsonb not null,

    -- pending   -> owed. The route's inline publish normally settles this within milliseconds.
    -- published -> delivered to Redis at least once.
    -- failed    -> attempted and did not succeed. Retryable; the sweep re-claims it.
    status       text not null default 'pending',
    attempts     int not null default 0,
    -- A worker that dies takes its lease with it, so a row cannot stick in flight forever.
    lease_until  timestamptz,
    last_error   text,
    created_at   timestamptz not null default now(),
    published_at timestamptz
);

do $$ begin
    alter table message_outbox
        add constraint message_outbox_status_check
        check (status in ('pending', 'published', 'failed'));
exception when duplicate_object then null;
end $$;

-- The sweep's only query: oldest owed first, so a backlog drains in the order it was created
-- and one wedged row cannot starve the rest.
create index if not exists idx_message_outbox_owed
    on message_outbox (created_at)
 where status in ('pending', 'failed');

-- Settling the rows the route just wrote, by message.
create index if not exists idx_message_outbox_message
    on message_outbox (message_id);
