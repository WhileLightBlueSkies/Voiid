-- 021_profile_keys.sql
--
-- ENCRYPTED PROFILE PHOTOS.
--
-- Avatars were the one media surface stored in the CLEAR: `uploadProfilePhoto` PUT a raw JPEG
-- to R2 and `users.photo_url` pointed at it, so anyone with bucket access — including us —
-- could open every user's face. Chat photos, videos, voice notes and Moments media have always
-- been encrypted on-device; avatars were the gap.
--
-- WHY AVATARS ARE HARDER, and why this needs its own table rather than reusing the per-message
-- media key: a chat photo has ONE known audience — the people in that conversation — so a
-- fresh key rides the ratchet alongside the message. An avatar has NO fixed audience. It is
-- shown to anyone who might contact you, including someone who found your @username and has
-- never had a session with you. There is no single message to attach a key to.
--
-- So the key is per-USER and long-lived (Signal's "profile key" model), wrapped once per
-- recipient DEVICE over that device's ratchet — the same shape `story_keys` already uses, so
-- the distribution pattern is proven rather than invented here.
--
-- THE SERVER NEVER SEES A PROFILE KEY. It stores per-device ciphertext it cannot open, exactly
-- as it does for story keys and message bodies.

-- ─────────────────────────────────────────────────────────────────────────────────
-- Key version on the user row.
--
-- Bumped on every rotation. A client that has cached version N and sees N+1 knows its copy is
-- stale and must re-fetch — without this there is no way to detect a rotation short of failing
-- to decrypt, which is indistinguishable from corruption.
--
-- NOT the key itself: only the client ever holds that.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table users
    add column if not exists profile_key_version int not null default 0,
    -- The avatar's R2 object is now CIPHERTEXT. Kept separate from `photo_url` so a rollback
    -- can fall back to the old plaintext object rather than showing every user a broken image,
    -- and so migration state is legible: photo_url set + encrypted_photo_url null = not yet
    -- migrated.
    add column if not exists encrypted_photo_url text,
    add column if not exists photo_encrypted_at timestamptz;

-- ─────────────────────────────────────────────────────────────────────────────────
-- One wrapped copy of the owner's profile key per recipient DEVICE.
--
-- Device-scoped, not user-scoped, because the ratchet is per-device: a peer with a phone and a
-- tablet needs two envelopes, and revoking one device must not require rotating for everyone.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists profile_keys (
    owner_user_id       uuid not null references users(id) on delete cascade,
    recipient_device_id uuid not null references devices(id) on delete cascade,
    -- Session.encrypt(profile_key envelope) for THIS device. Opaque to the server.
    ciphertext          bytea not null,
    -- Which key version this envelope carries. A recipient holding an older version knows to
    -- re-fetch rather than trying to decrypt an avatar with a superseded key.
    key_version         int not null,
    created_at          timestamptz not null default now(),
    delivered_at        timestamptz,
    primary key (owner_user_id, recipient_device_id)
);

-- The hot read: "give me every profile key addressed to my device that I have not fetched".
-- Partial, because delivered rows are the overwhelming majority once a user settles.
create index if not exists idx_profile_keys_pending
    on profile_keys (recipient_device_id) where delivered_at is null;

-- The hot write on rotation: replace every envelope belonging to one owner.
create index if not exists idx_profile_keys_owner
    on profile_keys (owner_user_id);
