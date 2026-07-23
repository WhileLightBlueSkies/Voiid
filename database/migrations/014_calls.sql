-- 014_calls.sql
-- Call history / missed-call records (voice + video). The signaling itself is
-- EPHEMERAL and never touches this table — SDP/ICE ride the WebSocket relay
-- (backend/websocket) over Redis, and call MEDIA + SRTP keys are E2E on the
-- devices (derived in e2e-core). The server never sees media or keys.
--
-- This table exists ONLY for user-visible call history and missed-call badges:
-- a lean lifecycle record (who called whom, when, how it ended). No media, no
-- SDP, no candidates, no keys are stored here (Section 4.14).

create table if not exists calls (
    id              uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references conversations(id) on delete cascade,
    caller_user_id  uuid not null references users(id) on delete cascade,
    call_kind       text not null check (call_kind in ('voice','video')),
    -- lifecycle: ringing -> connected -> ended, or a terminal missed/declined.
    status          text not null default 'ringing'
                        check (status in ('ringing','connected','ended','missed','declined')),
    started_at      timestamptz not null default now(),  -- ring started
    answered_at     timestamptz,                         -- callee answered (connected)
    ended_at        timestamptz,                         -- call torn down
    end_reason      text                                 -- e.g. hangup | missed | declined | busy | failed
);

-- History lookups are per-conversation, newest first (call log view).
create index if not exists idx_calls_conversation on calls (conversation_id, started_at desc);
-- Missed-call badges / "calls to me" filtering by the other party.
create index if not exists idx_calls_caller on calls (caller_user_id, started_at desc);

-- Group-call readiness (Phase later): who joined a call and from which device.
-- Unused by 1:1 calls (the calls row alone is enough) but present so a group
-- call can record per-participant join/leave without another migration.
create table if not exists call_participants (
    id          uuid primary key default gen_random_uuid(),
    call_id     uuid not null references calls(id) on delete cascade,
    user_id     uuid not null references users(id) on delete cascade,
    device_id   uuid references devices(id) on delete set null,
    joined_at   timestamptz not null default now(),
    left_at     timestamptz,
    unique (call_id, user_id, device_id)
);

create index if not exists idx_call_participants_call on call_participants (call_id);
create index if not exists idx_call_participants_active
    on call_participants (call_id) where left_at is null;
