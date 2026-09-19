-- 084_message_sender_erasable.sql — make DPDP erasure actually possible.
--
-- THE BUG, in one line of 006:
--
--     sender_id uuid not null references users(id) on delete set null
--
-- The foreign key says "when the sender is deleted, null this out". The column says "this
-- can never be null". Postgres honours both, in that order: it tries the SET NULL, hits the
-- NOT NULL, and aborts the delete.
--
-- So `delete from users` fails for anyone who has ever sent a message — which is everyone.
-- That is the exact statement `eraseUser()` runs (backend/workers/src/erasure.ts:283), so
-- EVERY DPDP erasure request has been failing for any real account. The worker rolls back to
-- its savepoint and counts the account as "stuck", which is why this never surfaced as an
-- outage: it fails quietly, in a background job, on a path nobody exercises until someone
-- asks to be erased. Found by running the delete by hand on the dev box.
--
-- ── WHY NULLABLE AND NOT CASCADE ────────────────────────────────────────────────
-- Two ways to reconcile the contradiction, and they mean opposite things:
--
--   on delete cascade  — erasing a sender DELETES THEIR MESSAGES OUT OF OTHER PEOPLE'S
--                        CONVERSATIONS. One person's erasure would silently rewrite
--                        everyone else's history, and the recipients never consented to
--                        losing what they received.
--
--   nullable sender_id — the message stays where it was delivered, attributed to nobody.
--                        The ciphertext is already unreadable by the server, so an
--                        anonymised row leaks nothing about the erased person.
--
-- 006 already chose the second: `on delete set null` was the stated intent and the NOT NULL
-- was the mistake. This migration makes the column agree with the constraint that was there
-- all along, rather than changing the behaviour to match a typo.
--
-- Readers must treat a null sender as "account erased" and render accordingly — the same way
-- a deleted account reads elsewhere in the product.

alter table messages alter column sender_id drop not null;

comment on column messages.sender_id is
    'Null means the sender erased their account (DPDP s.8(7)). The message stays for its recipients, attributed to nobody — see 084.';
