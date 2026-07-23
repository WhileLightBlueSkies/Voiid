-- 013_message_ciphertexts.sql
-- Multi-device fan-out (per-device envelope). See docs/FANOUT_PROTOCOL.md.
--
-- E2EE gives each DEVICE its own session (vodozemac), so a single stored ciphertext
-- can only be decrypted by one device. To reach a recipient's second device (and the
-- sender's own linked devices), the client encrypts ONCE PER TARGET DEVICE and sends a
-- bundle; the server stores one opaque ciphertext per recipient device here. The
-- canonical `messages` row keeps the shared metadata (sender, ts, conversation);
-- the per-device ciphertext lives in this table. No plaintext, ever (Section 4.14).

create table if not exists message_ciphertexts (
    message_id          uuid not null references messages(id) on delete cascade,
    recipient_device_id uuid not null references devices(id) on delete cascade,
    -- ENCRYPTED payload for THIS device only — server can never decrypt.
    ciphertext          bytea not null,
    -- per-device delivery lifecycle (metadata only): stamped when the device fetches it.
    delivered_at        timestamptz,
    primary key (message_id, recipient_device_id)
);

-- "pending for a device": the receive path fetches every undelivered ciphertext
-- addressed to the caller's device. Partial index keeps it to the undelivered rows.
create index if not exists idx_message_ciphertexts_pending
    on message_ciphertexts (recipient_device_id) where delivered_at is null;

-- Fan-out messages carry NO single ciphertext on the canonical row — the per-device
-- blobs live in message_ciphertexts. Legacy single-ciphertext sends still populate it,
-- so relax the NOT NULL rather than drop the column (back-compat: both paths coexist).
alter table messages alter column ciphertext drop not null;
