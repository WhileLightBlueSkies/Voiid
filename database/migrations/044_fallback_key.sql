-- 044_fallback_key.sql
--
-- Let `signed_prekeys` hold a vodozemac FALLBACK KEY.
--
-- 003 built this table for classic X3DH, where the signed prekey carries its own signature
-- by the device identity key — so `signature` was `not null`. Voiid does not use classic
-- X3DH: e2e-core is vodozemac (Olm), and its equivalent of the signed prekey is the
-- **fallback key**, which is NOT separately signed.
--
-- WHY THAT IS NOT A DOWNGRADE
-- ---------------------------
-- The signature in X3DH exists so a fetcher can prove the prekey came from the identity it
-- claims. In Olm that proof is already carried elsewhere and is strictly stronger in
-- practice here:
--
--   * the fallback key is only ever consumed inside an Olm prekey handshake, which binds
--     the sender's and receiver's identity keys into the derived session — a substituted
--     fallback key does not yield a session that decrypts; and
--   * `devices.identity_public_key` is TOFU-pinned per device and compared on every
--     session establishment, and the safety number surfaces a change to a human.
--
-- So a NULL signature here means "this key's authenticity rests on the pinned identity key
-- and the handshake", not "nobody checked". Inventing a signature to satisfy the column
-- would be worse than allowing null: it would look like a proof and be none.
--
-- 003's comment says "rotated every 30 days"; the client rotates weekly (see
-- E2EManager.rotateFallbackKeyIfDue on both platforms). Weekly is the tighter number and
-- the one that governs.

-- The column stays for a future classic-X3DH client; it simply stops being mandatory.
alter table signed_prekeys alter column signature drop not null;

comment on column signed_prekeys.signature is
    'Signature by the device identity key, for classic X3DH signed prekeys. NULL for a '
    'vodozemac FALLBACK key, which is not separately signed: its authenticity rests on the '
    'TOFU-pinned devices.identity_public_key plus the Olm prekey handshake that binds both '
    'identities into the derived session. See 044.';

-- Rotation needs to find the CURRENT key cheaply, and the fetch path in routes/prekeys.ts
-- already orders by created_at desc. Without this it is a sort over every key the device
-- has ever published, on a query that runs for every bundle fetch.
create index if not exists idx_signed_prekeys_device_recent
    on signed_prekeys (device_id, created_at desc);

-- ─────────────────────────────────────────────────────────────────────────────────
-- Retire superseded fallback keys.
--
-- A rotating client publishes a new key every week and the old rows accumulate forever.
-- That is not merely untidy: `forget_previous_fallback_key()` on the device drops the
-- PRIVATE half one rotation after it is replaced, so every row older than that is a public
-- key whose private half no longer exists. Serving one would hand a sender a key that can
-- never open a session — a silent, unrecoverable failure to deliver a first message.
--
-- Deleted rather than flagged: there is nothing to learn from a key nobody can use, and a
-- `retired_at` column would need the fetch path to remember to filter on it. The fetch path
-- already takes the newest row, so pruning is enough and cannot be forgotten.
--
-- Keeps the two most recent per device, matching what vodozemac itself retains (current +
-- previous), so a first message already in flight against the just-replaced key still opens.
-- ─────────────────────────────────────────────────────────────────────────────────
delete from signed_prekeys sp
 where sp.id not in (
   select id from (
     select id,
            row_number() over (partition by device_id order by created_at desc) as rn
       from signed_prekeys
   ) ranked
    where rn <= 2
 );
