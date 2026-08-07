-- 038_call_declined_state.sql — tell a conference roster the difference between
-- "they said no" and "they hung up".
--
-- ── THE BUG THIS FIXES ───────────────────────────────────────────────────────────
-- 031 gave call_participants three states: invited -> joined -> left. There is no way to
-- say DECLINED, so when an invitee refuses a conference invite the only honest thing the
-- server can write is 'left' — the same value it writes for someone who joined, talked for
-- ten minutes and hung up.
--
-- The roster therefore cannot answer the one question the inviter actually has. A person
-- who refused and a person who has not answered yet are both "not joined"; a person who
-- refused and a person who left mid-call are both 'left'. So the UI could either keep
-- showing "Ringing…" forever, or show "Left" for somebody who never arrived. Both are lies,
-- and the client had no way to tell which one it was telling.
--
-- ── WHY A STATE AND NOT A FLAG ───────────────────────────────────────────────────
-- A boolean `declined` alongside `state` would let the two disagree — declined=true with
-- state='joined' is representable and meaningless. The state machine is the single source
-- of truth for where a participant stands, so the new fact belongs in it.
--
-- ── TERMINAL, LIKE 'left' ────────────────────────────────────────────────────────
-- `isActiveParticipantState` (callConference.ts) treats only 'invited' and 'joined' as
-- entitled to a room token, and 'declined' is deliberately outside that set: refusing an
-- invite must revoke the entitlement immediately, not merely record an opinion. Re-inviting
-- the same person is an ordinary /escalate, which moves them back to 'invited'.

alter table call_participants
    drop constraint if exists call_participants_state_check;
alter table call_participants
    add constraint call_participants_state_check
    check (state in ('invited', 'joined', 'left', 'declined'));

comment on column call_participants.state is
  'invited -> joined -> left, plus the terminal ''declined''. A declined invitee is NOT an '
  'active participant and holds no claim on a room token; re-inviting them goes through '
  '/escalate and returns them to ''invited''.';
