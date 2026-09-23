-- Aadhaar for hosts, through DigiLocker (Cashfree Secure ID).
--
-- ── WHAT VOIID NEVER SEES ───────────────────────────────────────────────────────────
--
-- The host types their Aadhaar number and OTP into DigiLocker's own page, not into Voiid.
-- DigiLocker returns the Aadhaar already MASKED ("xxxxxxxx5647"), and the Aadhaar Act limits
-- storing anything more. So this keeps the last four digits, the name on the Aadhaar, whether
-- that name matches the PAN, and when it was verified. The photo, address and e-Aadhaar XML
-- Cashfree also returns are never written anywhere.
alter table host_verifications add column if not exists aadhaar_last4 text;
alter table host_verifications add column if not exists aadhaar_name text;
alter table host_verifications add column if not exists aadhaar_name_match boolean;
alter table host_verifications add column if not exists aadhaar_verified_at timestamptz;
-- The DigiLocker request in flight, so the completion step asks Cashfree about THIS host's
-- request and nobody else's.
alter table host_verifications add column if not exists digilocker_verification_id text;
do $$ begin
    alter table host_verifications add constraint host_verifications_aadhaar_last4_ck
        check (aadhaar_last4 is null or aadhaar_last4 ~ '^[0-9]{4}$');
exception when duplicate_object then null; end $$;
