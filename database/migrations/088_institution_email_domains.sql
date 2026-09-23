-- College-email joining for institution communities.
--
-- ── THE RULE ────────────────────────────────────────────────────────────────────────
--
-- A community with `institution_domains` set admits only people who have PROVEN they hold an
-- address at one of those domains (or a subdomain: `student.iitb.ac.in` counts for
-- `iitb.ac.in`). Proof is a 6-digit code emailed to that address and typed back. The join
-- route enforces it; the apps only walk people through it.
--
-- The domains are set only from the admin panel (like institution_name, 087): a host cannot
-- restrict their club to a university's email and so imply the university runs it.
--
-- Existing members are not removed when a restriction is added. It governs who can JOIN.
alter table communities add column if not exists institution_domains text[] not null default '{}';
do $$ begin
    alter table communities add constraint communities_institution_domains_ck
        check (cardinality(institution_domains) <= 20);
exception when duplicate_object then null; end $$;

-- An address a user has proven they receive mail at. Kept per user, not per community: one
-- proof of name@iitb.ac.in serves every community that accepts that domain, and re-proving it
-- for each would teach people to click codes without reading them.
create table if not exists user_verified_emails (
    user_id     uuid not null references users(id) on delete cascade,
    email       text not null,
    verified_at timestamptz not null default now(),
    primary key (user_id, email),
    constraint user_verified_emails_lower_ck check (email = lower(email))
);

-- One outstanding code per (user, email). The CODE is stored hashed: a database read must not
-- be a way to join a community as someone else.
create table if not exists email_verification_codes (
    user_id      uuid not null references users(id) on delete cascade,
    email        text not null,
    code_hash    text not null,
    expires_at   timestamptz not null,
    attempts     int not null default 0,
    created_at   timestamptz not null default now(),
    primary key (user_id, email),
    constraint email_verification_codes_lower_ck check (email = lower(email))
);
