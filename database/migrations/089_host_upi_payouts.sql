-- A host may be paid to a UPI ID instead of a bank account.
--
-- Cashfree Easy Split vendors accept either, and Secure ID verifies a UPI ID the same way it
-- verifies an account: a ₹1 penny drop that returns the holder's name at the bank. So the rule
-- from 087 carries over unchanged — Voiid keeps enough to recognise the payout destination and
-- nothing a leak could spend. For a UPI ID that is a masked form ("ra•••@okhdfcbank"): the
-- handle's provider stays readable for the reviewer, the personal part does not.
alter table host_verifications add column if not exists payout_method text not null default 'bank';
alter table host_verifications add column if not exists upi_masked text;
do $$ begin
    alter table host_verifications add constraint host_verifications_payout_method_ck
        check (payout_method in ('bank', 'upi'));
exception when duplicate_object then null; end $$;
