-- 026_contact_pin_readable.sql
--
-- MAKE THE CONTACT PIN VIEWABLE AGAIN.
--
-- 020_reachability.sql stored only a bcrypt hash and showed the PIN exactly once, at
-- rotation. That is the correct design for a PASSWORD. It is the wrong design for this,
-- and shipping it revealed why: a PIN you cannot look up is one you must write down, and
-- forgetting it forces a rotation that locks out everyone already holding the old one.
--
-- The contact PIN is not a credential. Knowing it grants exactly one thing: permission to
-- open a REQUEST that the recipient still has to accept. It gates no account access, reads
-- no data, and sends no message on its own. It behaves like a Wi-Fi password on a fridge
-- door — a token you hand out and re-read, not a secret you prove knowledge of.
--
-- So it moves from HASHED to ENCRYPTED AT REST.
--
-- What that buys, precisely
-- -------------------------
-- A stolen database dump is the threat this defends. `select * from users` — a leaked
-- backup, a misconfigured read replica, SQL injection — now yields AES-256-GCM ciphertext
-- instead of a hash worth cracking. The attacker additionally needs VOIID_SECRETBOX_KEY,
-- which lives in the process environment and is not in the database at all.
--
-- What it does NOT buy: this is not E2E. The server holds the key, so the server can read
-- the PIN. Anyone with both the dump and the env has everything. That is a genuine
-- reduction from the hash, accepted knowingly because the asset is low-value (a request
-- permission, not access) and the usability cost of show-once was real.
--
-- NOTHING HERE TOUCHES MESSAGE ENCRYPTION. Messages, calls and media stay E2E; the server
-- cannot read them and this migration does not change that in any way.

-- The sealed PIN: `v1.<nonce>.<ciphertext+tag>`, base64url, produced by api/src/secretbox.ts.
-- Nullable, and null is meaningful: it marks a user whose PIN predates this migration and
-- therefore exists only as a hash that cannot be reversed.
alter table users
    add column if not exists contact_pin_enc text;

-- ─────────────────────────────────────────────────────────────────────────────────
-- The hash STAYS.
--
-- Deliberately not dropped. Every PIN issued before this migration exists only as a bcrypt
-- hash, and a hash cannot be turned back into six digits — dropping the column would
-- invalidate every PIN already in circulation and break the reachability of every user who
-- had set one.
--
-- So verification checks the encrypted column first and falls back to the hash, and those
-- users keep working exactly as before (show-once semantics included) until they next
-- rotate, at which point they gain a readable PIN. No forced reset, no flag day.
--
-- Once a deployment is confident no user still has a hash-only PIN, this column can be
-- dropped in a later migration. It is not urgent and it is not automatic.
-- ─────────────────────────────────────────────────────────────────────────────────
comment on column users.contact_pin_hash is
    'Legacy bcrypt PIN hash (pre-026). Verify-only fallback for PINs minted before the '
    'switch to encrypted-at-rest storage; cleared on next rotation. See contact_pin_enc.';

comment on column users.contact_pin_enc is
    'Contact PIN sealed with AES-256-GCM by api/src/secretbox.ts (VOIID_SECRETBOX_KEY). '
    'Reversible ON PURPOSE so the owner can view their own PIN; NOT end-to-end encrypted.';
