-- 096_recovery_vpin.sql
-- The V PIN: a PIN whose guesses the SERVER counts. See backend/api/src/vpin.ts for the
-- design and its honest threat model; this file only makes room for it.
--
-- ── ONE ROW, TWO SCHEMES ────────────────────────────────────────────────────────────
-- recovery_keys already holds the legacy PIN envelope (012, metered in 063). The V PIN
-- lives in the same row — a person has at most one PIN — distinguished by `pin_version`:
--
--   1  legacy   wrapped_key is the envelope, handed to the client, guessed client-side.
--   2  V PIN    sealed_envelope is the envelope, sealed with the server key and released
--               only after `pin_verifier` matches; wrapped_key is NULL.
--
-- The CHECK makes a half-written row impossible. A version-2 row missing its verifier or
-- sealed envelope would be a PIN that can never unlock, and a version-2 row with a legacy
-- wrapped_key would be an envelope the old GET /key route could hand out unchecked.
--
-- ── THE LOCK COLUMNS ARE SHARED, AND WHAT THAT MEANS ────────────────────────────────
-- failed_attempts / locked_until already exist. For a version-1 row they are client-
-- reported telemetry (063's column comment). For a version-2 row they are SERVER-
-- ENFORCED, and the legacy routes that let a client write them (attempt-result) refuse
-- version-2 rows — otherwise a client could report "success" and clear a real lock.
--
-- Idempotent: every statement is safe to re-run (see migrate.mjs).

alter table recovery_keys
    add column if not exists pin_version     smallint not null default 1,
    add column if not exists pin_auth_salt   text,
    add column if not exists pin_verifier    text,
    add column if not exists sealed_envelope text;

-- A version-2 row carries no client-readable envelope at all.
alter table recovery_keys alter column wrapped_key drop not null;

do $$ begin
    alter table recovery_keys add constraint recovery_keys_pin_scheme_ck check (
        (pin_version = 1 and wrapped_key is not null
             and pin_verifier is null and sealed_envelope is null)
     or (pin_version = 2 and wrapped_key is null
             and pin_auth_salt is not null and pin_verifier is not null
             and sealed_envelope is not null)
    );
exception when duplicate_object then null;
end $$;

comment on column recovery_keys.pin_verifier is
    'V PIN: HMAC(k, proof) where proof = PBKDF2(pin) computed on the phone and k is derived '
    'from VOIID_SECRETBOX_KEY. Useless to a database-only thief. Never the PIN or the proof.';
comment on column recovery_keys.sealed_envelope is
    'V PIN: the phone-locked backup-key envelope, sealed again with the server key and bound '
    'to user_id. Released only after pin_verifier matches.';
comment on column recovery_keys.pin_version is
    '1 = legacy client-reported envelope (wrapped_key). 2 = V PIN, server-counted (vpin.ts).';
