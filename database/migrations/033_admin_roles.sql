-- 033_admin_roles.sql — two roles on the admin plane, so that "can review a clip" and
-- "can destroy data" stop being the same privilege (repair plan 3.30).
--
-- ======================== METADATA ONLY — NO CONTENT, EVER ========================
-- This file adds one text column to the admin table. It gives nobody any ability to read
-- a message, a call, a location share or a moment: those are end-to-end encrypted and the
-- server holds ciphertext and no key. It only ever REMOVES power from an admin row, never
-- adds any — see the backfill note below for the one case where that would have been
-- true by accident.
-- =================================================================================
--
-- WHAT IS WRONG TODAY. `admin_users` (028_admin_users.sql) has no role column, so every
-- row that can sign in has identical, complete power over the plane — including
-- `DELETE /admin/clips/:id`, which deletes the row and every R2 object and which
-- admin.ts's own comment describes as the thing that "cannot be undone". A contractor
-- hired to review reported clips gets the irreversible purge as a side effect of being
-- able to log in at all. That is not a hypothetical: the panel's only mutation surface
-- until now WAS moderation, so the account you would hand a moderator is the same account
-- that can purge.
--
-- Adding the data-principal console (repair plan 3.27) makes it urgent rather than untidy.
-- That console can read one named person's device history and security events, and it can
-- start an irreversible erasure. Shipping it onto a plane where every login has every
-- power would mean every future moderator hire also gets the ability to erase accounts.
--
-- TWO ROLES, NOT FIVE. A role system with a permission matrix invites a per-endpoint
-- checkbox screen, and a checkbox screen is a place where somebody eventually ticks the
-- wrong box. The division here is the one the endpoints actually have: reversible content
-- moderation versus everything that touches a PERSON or destroys data.
--
--   moderator  clips queue, playback, remove/restore (all reversible), read the audit log
--   admin      the above, plus the irreversible clip purge, the users list and the
--              per-user device/security view, device revocation, and the whole DPDP
--              request console including starting an erasure
--
-- WHERE THE GATE LIVES. In backend/api/src/routes/admin.ts, as one `requireRole('admin')`
-- middleware applied per route — not as a check inside each handler. The failure mode of
-- a role system is a new privileged endpoint that nobody remembers to gate, and a
-- middleware that is visibly absent from a route definition is easier to spot in review
-- than a missing `if` twelve lines into a handler.


alter table admin_users
    add column if not exists role text not null default 'moderator'
        check (role in ('moderator', 'admin'));

-- ─────────────────────────────────────────────────────────────────────────────────
-- THE BACKFILL, AND WHY IT IS NOT 'moderator'
--
-- Every row that exists when this migration runs was created BEFORE roles existed, and
-- therefore already has full power — including the founder's own account. Letting the
-- column default apply to them would silently demote everyone, and there is no way back:
-- there is deliberately no endpoint that edits `role` (see below), so a fully demoted
-- table means nobody can purge, nobody can work the DPDP queue, and the only repair is a
-- hand-written UPDATE against production.
--
-- A migration that can lock the operator out of their own admin plane is a worse outcome
-- than a migration that grants nothing new — so existing rows keep exactly the power they
-- already had, and the least-privilege default applies from here on, to accounts created
-- after roles exist. `where role = 'moderator'` rather than an unconditional update so a
-- re-run of this file cannot promote an account that was deliberately demoted later.
-- ─────────────────────────────────────────────────────────────────────────────────
do $$
begin
    if not exists (select 1 from admin_users where role = 'admin') then
        update admin_users set role = 'admin' where role = 'moderator';
    end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────────
-- NO ENDPOINT WRITES THIS COLUMN, ON PURPOSE.
--
-- Roles are changed with SQL by someone with database access. The alternative is a
-- "promote to admin" button in the panel, which turns a stolen moderator SESSION into a
-- full privilege escalation with one click — and the whole reason the admin plane keeps
-- server-side revocable sessions (028_admin_users.sql) is that it assumes a session can
-- be stolen. Privilege escalation should require a credential the panel does not hold.
--
-- The cost is real and is accepted: onboarding a new admin is a manual step. That is the
-- correct amount of friction for handing someone the ability to erase an account.
--
-- There is no constraint enforcing "at least one row must be an admin", because a table
-- with zero admins is recoverable by the same SQL that would have to grant the first one
-- anyway, and a constraint that can block a legitimate `disabled_at` on a compromised
-- account is worse than the state it prevents.
-- ─────────────────────────────────────────────────────────────────────────────────
