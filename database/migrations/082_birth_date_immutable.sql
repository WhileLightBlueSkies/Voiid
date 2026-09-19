-- 082_birth_date_immutable.sql — a date of birth is set once and never changed.
--
-- WHY THIS IS A DATABASE RULE AND NOT A ROUTE CHECK
--
-- `birth_date` is not a profile field like a bio. It is the INPUT TO AN AGE GATE: it decides
-- whether a person is under 13 (blocked), 13-17 (Teen Safe — no behavioural personalisation,
-- no targeted ads, per DPDP s.9) or 18+ (personalisation offered). An editable age gate is not
-- a gate at all — a 14-year-old who can set 1999 has simply switched the protections off.
--
-- `PATCH /creators/me` accepted `birth_date` on every call and overwrote it unconditionally, so
-- the restriction could be lifted by the same client that was restricted. Enforcing it in the
-- route would fix that one caller; enforcing it here fixes every caller that will ever exist,
-- including an admin tool or a migration written in a hurry.
--
-- WHAT IS ALLOWED
--   null -> a date     setting it for the first time (the setup flow, and backfilling the
--                      profiles created before the field was collected)
--   date -> same date  a no-op update, so a PATCH that resends the whole profile still works
--   date -> different  REJECTED
--   date -> null       REJECTED — clearing it would be the obvious way around the above
--
-- A genuine correction (someone mistyped their year) is a support action: it needs a human to
-- decide, and it should leave a trail. That path is a deliberate `alter table ... disable
-- trigger` by an operator, not an endpoint.

create or replace function assert_birth_date_immutable() returns trigger as $$
begin
    if old.birth_date is null then
        return new;                      -- first write, including backfill
    end if;

    if new.birth_date is distinct from old.birth_date then
        raise exception 'birth_date cannot be changed once set'
            using errcode = 'check_violation',
                  hint = 'A date of birth drives age-based safety protections. Corrections go through support.';
    end if;

    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_birth_date_immutable on social_profiles;
create trigger trg_birth_date_immutable
    before update on social_profiles
    for each row
    execute function assert_birth_date_immutable();

comment on function assert_birth_date_immutable() is
    'Blocks changes to social_profiles.birth_date once set. It is an age-gate input, not a profile field — see 082.';
