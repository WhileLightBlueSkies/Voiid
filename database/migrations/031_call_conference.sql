-- 031_call_conference.sql
--
-- AD-HOC CONFERENCE CALLS: adding a third person to a live 1:1 call.
--
-- ═══════════════════════════════════════════════════════════════════════════════════
-- THE RULE THIS MIGRATION EXISTS TO PROTECT
--
--   A SHARED CALL GRANTS NO MESSAGING RIGHTS.
--
-- If you can be added to a call by someone you know, the person on the other end of
-- that call — who may be a total stranger to you — still has to go through the 020
-- reachability gate (mutual contact, contact request, or @username + the 6-digit PIN)
-- before they can send you a single message. This is the same principle 029 states for
-- follows: "FOLLOWING ADDS NO FOURTH PATH".
--
-- That rule is why conference calls get their OWN tables instead of reusing the group
-- machinery. Today the only multi-party room in the product is `voiid-<conversation_id>`,
-- keyed on a group conversation's MLS state — so escalating a 1:1 that way would mean
-- CREATING A GROUP CONVERSATION containing the stranger, which hands them a permanent
-- messaging surface with both participants. Exactly what the product forbids.
--
-- So the structural rule, restated here where a future schema change will trip over it:
--
--   *** NOTHING IN THE CALL PATH MAY WRITE TO conversations OR conversation_members. ***
--
-- Call membership lives HERE, in call_participants, and it is read by the call path
-- ONLY. If a future change makes reachability, conversations, or messages consult
-- call_participants to decide whether someone may be messaged, the PIN gate is bypassed
-- and the product requirement is broken — that is a bug, not a feature. There are guard
-- tests that fail on both halves of this (backend/api/test/callConference.test.ts).
-- ═══════════════════════════════════════════════════════════════════════════════════
--
-- 014_calls.sql already shipped `call_participants` ("present so a group call can record
-- per-participant join/leave without another migration") and nothing has ever written to
-- it. This migration gives it the one thing it was missing — a LIFECYCLE — and a unique
-- index that can actually be used as an ON CONFLICT target.

-- ─────────────────────────────────────────────────────────────────────────────────
-- state: invited -> joined -> left
--
-- `joined_at` alone cannot express "rung but not yet in the room": 014 defaults it to
-- now() on insert, so an invitee who never answers would look like a participant who was
-- present the whole time. The escalation flow needs all three states — the inviter shows
-- "Ringing…" for `invited`, the SFU token is issued for `invited`/`joined` only, and the
-- per-call media key is re-derived on every transition into and out of `joined`.
--
-- Default 'joined' so any row written by code that predates this column (there is none
-- today, but that is the safe default for a lifecycle column) reads as a real participant.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table call_participants
    add column if not exists state text not null default 'joined',
    -- Who pulled this person into the call. NOT an authorization edge — it is history,
    -- read by nothing that decides permissions. ON DELETE SET NULL so deleting the
    -- inviter's account does not delete the other participants' call record.
    add column if not exists invited_by uuid references users(id) on delete set null,
    -- When `state` last changed, for "Ringing…" timeouts and for ordering the roster.
    add column if not exists state_changed_at timestamptz not null default now();

alter table call_participants
    drop constraint if exists call_participants_state_check;
alter table call_participants
    add constraint call_participants_state_check
    check (state in ('invited', 'joined', 'left'));

-- ─────────────────────────────────────────────────────────────────────────────────
-- ONE ROW PER (call, user) — and why this index has NO predicate.
--
-- 014 has `unique (call_id, user_id, device_id)`. That constraint CANNOT be used to
-- upsert an invite, because an invitee has no device_id yet (they have not answered, and
-- may answer on any of their devices) and Postgres treats NULLs in a unique index as
-- distinct: `on conflict (call_id, user_id, device_id)` with a NULL device_id never
-- matches an existing row, so every retry of an invite inserts a DUPLICATE. This repo has
-- already been bitten by exactly this — see 027_receipt_null_device.sql — so it gets a
-- key that does not involve device_id at all.
--
-- Deliberately TOTAL, not partial. A partial index (`where left_at is null`) would let a
-- user accumulate one historical row per join, but it can only be used as an ON CONFLICT
-- target by repeating the predicate verbatim at every call site — one omission and the
-- duplicate-row bug is back, silently. Instead, leaving is a STATE, not a row: a
-- participant who leaves and rejoins reuses their row. Per-device history is not
-- something any product surface asks for; a correct roster is.
--
-- Safe to create unconditionally: nothing has ever written to this table, so there are no
-- pre-existing duplicates to reconcile.
-- ─────────────────────────────────────────────────────────────────────────────────
create unique index if not exists uq_call_participants_call_user
    on call_participants (call_id, user_id);

-- device_id becomes "the device that most recently joined", so it must be updatable.
-- The old 3-column unique is now redundant (the 2-column one is strictly stronger) and
-- actively in the way: it would reject moving a participant from device A to device B
-- while the old NULL row still exists. Dropped by name AND by the pattern Postgres uses
-- for an inline `unique (...)` on a `create table`.
alter table call_participants
    drop constraint if exists call_participants_call_id_user_id_device_id_key;

-- "Which live call am I in?" — the invitee's push-woken client asks this, and the
-- adhoc-token gate asks it on every join. Partial: a left participant is never a hit.
create index if not exists idx_call_participants_user_active
    on call_participants (user_id, call_id)
    where state <> 'left';

-- Roster reads for one call, in join order. The 014 index on (call_id) covers the lookup;
-- this one keeps the ordering out of a sort for a room of any size.
create index if not exists idx_call_participants_call_state
    on call_participants (call_id, state, joined_at);

comment on column call_participants.state is
    'invited | joined | left. Call-scoped ONLY: this table must never be read to decide '
    'whether one user may MESSAGE another — that is the 020 reachability gate''s job, and '
    'a shared call grants no messaging rights (see the header of this migration).';
