-- 028_admin_users.sql — the admin panel's own accounts, and clip moderation.
--
-- ADMINS ARE NOT USERS. A separate table, not an `is_admin` flag on `users`, for one
-- concrete reason: a Voiid account is reached by SMS OTP against a phone number, and a
-- phone number is a credential someone else's carrier controls. A SIM swap that takes over
-- a phone number should never also hand over the ability to read every clip on the platform
-- and delete accounts. The admin plane has its own credential (email + password), its own
-- table, and no path from one to the other.
--
-- It also means an admin does not need to be a Voiid user at all — a moderator or a
-- contractor can have an admin login without a phone number in the system.

create table if not exists admin_users (
    id            uuid primary key default gen_random_uuid(),
    email         text not null,
    -- bcrypt, like every other secret in this system. NEVER a reversible encryption:
    -- unlike the contact PIN (see 026), nothing ever needs to READ this back — the only
    -- operation is "does this input match", which is exactly what a hash is for.
    password_hash text not null,
    -- Display name for the audit trail, so a takedown reads "removed by Priyanshu" rather
    -- than by a uuid.
    name          text,
    -- Soft disable. Deleting the row would orphan every audit entry that points at it,
    -- which is the opposite of what an audit trail is for.
    disabled_at   timestamptz,
    last_login_at timestamptz,
    created_at    timestamptz not null default now()
);

-- CITEXT would be better but is an extension; lower() on a unique index gets the same
-- guarantee without one. Case-insensitive because "Nehal@..." and "nehal@..." are the same
-- mailbox everywhere in practice, and two admin rows for one person is a security bug.
create unique index if not exists idx_admin_users_email on admin_users (lower(email));

-- ─────────────────────────────────────────────────────────────────────────────────
-- Sessions
--
-- Server-side rather than a stateless JWT, deliberately. A JWT cannot be revoked before it
-- expires: if an admin laptop is lost, the only options are waiting it out or rotating the
-- signing secret for everyone. A row can be deleted. For a plane that can take down content
-- and read every clip, instant revocation is worth the lookup.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists admin_sessions (
    -- The token is HASHED, not stored raw. A leaked database dump must not be a set of
    -- working admin sessions — the same reasoning as password_hash above.
    token_hash text primary key,
    admin_id   uuid not null references admin_users(id) on delete cascade,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null,
    -- For "you are signed in on these devices" and for spotting a stolen session.
    user_agent text,
    ip         inet
);

create index if not exists idx_admin_sessions_admin on admin_sessions (admin_id);
create index if not exists idx_admin_sessions_expiry on admin_sessions (expires_at);

-- ─────────────────────────────────────────────────────────────────────────────────
-- Clip moderation
--
-- SOFT DELETE, so a mistaken takedown is recoverable and a disputed one has a record. A
-- hard DELETE also destroys the evidence of why something was removed, which is exactly
-- what you need when the author asks.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table clips
    add column if not exists removed_at    timestamptz,
    add column if not exists removed_by    uuid references admin_users(id) on delete set null,
    add column if not exists removed_reason text;

-- The feed reads WHERE removed_at is null on every request, so it is worth an index.
create index if not exists idx_clips_visible
    on clips (created_at desc)
    where removed_at is null;

-- ─────────────────────────────────────────────────────────────────────────────────
-- Audit log
--
-- Every admin action, kept even after the admin row is disabled. Without this, "who
-- deleted this clip and why" has no answer, and moderation becomes something that happens
-- to users rather than something anyone is accountable for.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists admin_audit_log (
    id          bigserial primary key,
    admin_id    uuid references admin_users(id) on delete set null,
    action      text not null,         -- clip.remove | clip.restore | admin.login | ...
    target_type text,                  -- clip | user | admin
    target_id   text,
    -- Free-form context: the reason given, the previous value, whatever the action needs.
    detail      jsonb,
    created_at  timestamptz not null default now()
);

create index if not exists idx_admin_audit_created on admin_audit_log (created_at desc);
create index if not exists idx_admin_audit_target on admin_audit_log (target_type, target_id);
