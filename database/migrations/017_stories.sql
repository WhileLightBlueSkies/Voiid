-- 017_stories.sql
-- Stories: 24h ephemeral media, E2EE. The server stores CIPHERTEXT ONLY.
-- The media blob is encrypted ON-DEVICE with a fresh random AES-256-GCM key and
-- PUT straight to R2; this DB holds only the opaque object key plus one opaque
-- per-recipient-DEVICE blob carrying that key (same shape as message_ciphertexts).
-- The server necessarily learns WHICH DEVICES received key material — that is the
-- audience, and it is metadata we do not claim to hide. It never learns the media
-- key, the real mime, the caption, the dimensions, or the bytes.
--
-- WHY one blob + N tiny key envelopes (and not N encrypted blobs): encrypt_media in
-- e2e-core takes and returns a whole Vec<u8>, so re-encrypting per recipient would
-- copy the entire media through the FFI once per viewer. Encrypting the ~400-byte
-- key envelope per device instead keeps fan-out cost proportional to the audience,
-- not to the media size.
--
-- WHY there is no audience/ACL table here: the audience is an author-side local
-- concept only. The server has no endpoint that accepts an audience list; the
-- story_keys rows ARE the routing set. See docs/STORIES_PROTOCOL.md.

create table if not exists stories (
    id                  uuid primary key,                 -- CLIENT-supplied (cf. calls.id): the
                                                          -- envelope must bind the id, and it is
                                                          -- encrypted BEFORE the row is created.
    author_id           uuid not null references users(id) on delete cascade,
    author_device_id    uuid references devices(id) on delete set null,
    r2_key              text not null,                    -- media/stories/<uid>/<uuid>, CIPHERTEXT
    -- WRAPPER type only (application/octet-stream). The REAL media type travels
    -- encrypted inside the per-device envelope; NEVER store the real one here.
    media_mime          text not null default 'application/octet-stream',
    byte_size           bigint,                           -- ciphertext length; drives progress UI
    created_at          timestamptz not null default now(),
    -- SERVER-computed (created_at + 24h). The envelope also carries the author's
    -- claimed expiry, but that is only an offline fallback for a cached story —
    -- this column is what every server read path filters on.
    expires_at          timestamptz not null,
    -- Worker backoff. 5 failed R2 deletes = give up on the object and drop the row
    -- anyway; the bucket lifecycle rule on prefix `media/stories/` is the net. A
    -- stuck row must never block the reaper queue.
    reap_attempts       int not null default 0
);

-- Reaper scan (expires_at < now() - grace). NOT a partial index on now() — now()
-- is not immutable and Postgres rejects it in an index predicate.
create index if not exists idx_stories_expires on stories (expires_at);
-- "my live stories" + the rolling-24h post-rate check.
create index if not exists idx_stories_author  on stories (author_id, created_at desc);

-- One opaque envelope per TARGET DEVICE, carrying the media key for THIS device
-- only. Structurally identical to message_ciphertexts, for the same reason: each
-- device holds its own Double Ratchet session, so a single stored ciphertext can
-- only ever be opened by one device. The server can NEVER decrypt these.
create table if not exists story_keys (
    story_id            uuid not null references stories(id) on delete cascade,
    recipient_device_id uuid not null references devices(id) on delete cascade,
    ciphertext          bytea not null,                   -- Session.encrypt(envelope) for THIS device
    delivered_at        timestamptz,                      -- metadata only; stamped when the device fetches
    primary key (story_id, recipient_device_id)
);
-- "pending for a device": the feed path fetches every undelivered envelope addressed
-- to the caller's device. Partial index keeps it to the undelivered rows.
create index if not exists idx_story_keys_pending
    on story_keys (recipient_device_id) where delivered_at is null;

-- View receipts. DELIBERATELY has NO viewer_user_id column: the viewer identity
-- lives inside the encrypted payload, which only the AUTHOR's devices can open.
-- HONEST CAVEAT: the API still authenticates whoever POSTs the receipt, so this is
-- a statement that we do not STORE the viewer identity — NOT a claim that the
-- server cannot observe it. There is no sealed sender in Voiid and one cannot be
-- added (the e2e-core surface is frozen). This is why view receipts default to OFF.
create table if not exists story_receipts (
    id                  uuid primary key default gen_random_uuid(),
    story_id            uuid not null references stories(id) on delete cascade,
    -- Always an AUTHOR device — enforced in routes/stories.ts, not by the schema
    -- (a FK cannot express "belongs to the author of THAT story").
    recipient_device_id uuid not null references devices(id) on delete cascade,
    ciphertext          bytea not null,
    created_at          timestamptz not null default now(),
    delivered_at        timestamptz
);
create index if not exists idx_story_receipts_pending
    on story_receipts (recipient_device_id) where delivered_at is null;
