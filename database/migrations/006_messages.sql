-- 006_messages.sql
-- Messages: the server stores CIPHERTEXT ONLY (Section 4.1). No plaintext column exists, by design.
-- Media bytes never live in the DB or on instance disk — only an R2 reference to encrypted bytes.

create table if not exists messages (
    id                  uuid primary key default gen_random_uuid(),
    conversation_id     uuid not null references conversations(id) on delete cascade,
    sender_id           uuid not null references users(id) on delete set null,
    sender_device_id    uuid references devices(id) on delete set null,
    -- Per-recipient-device ciphertext is delivered via the relay; this row is the canonical stored blob.
    -- For 1:1 (Double Ratchet) and group (Sender Keys), the payload is opaque to the server.
    ciphertext          bytea not null,                -- ENCRYPTED payload — server can never decrypt
    content_type        text not null default 'text',  -- text | image | voice | document
    -- media is encrypted on-device, uploaded to R2; we store only the reference + decryption is client-side
    media_url           text,                          -- R2 object key for encrypted media bytes (nullable)
    media_mime          text,
    -- metadata visible to server (Section 4.8): timestamp, sender, recipient(s) via conversation, status
    created_at          timestamptz not null default now(),
    -- delivery lifecycle (metadata only, not content)
    delivered_at        timestamptz,
    -- offline relay: message stays pending until each recipient device fetches it
    is_pending          boolean not null default true
);

create index if not exists idx_messages_conversation on messages (conversation_id, created_at desc);
create index if not exists idx_messages_pending on messages (conversation_id) where is_pending;
create index if not exists idx_messages_sender on messages (sender_id);
