-- 005_conversations.sql
-- Conversations (1:1 and group). Group E2E uses Sender Keys (Phase 3); 1:1 uses Double Ratchet sessions.

create table if not exists conversations (
    id              uuid primary key default gen_random_uuid(),
    type            text not null default 'direct',   -- direct | group
    -- group-only metadata (null for direct):
    name            text,
    photo_url       text,                              -- R2 reference (group avatar; not E2E content)
    created_by      uuid references users(id) on delete set null,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

create index if not exists idx_conversations_type on conversations (type);

drop trigger if exists trg_conversations_updated_at on conversations;
create trigger trg_conversations_updated_at before update on conversations
    for each row execute function set_updated_at();

-- conversation_members (Section 0 schema). Roles for group admin vs member (Phase 3).
create table if not exists conversation_members (
    id              uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references conversations(id) on delete cascade,
    user_id         uuid not null references users(id) on delete cascade,
    role            text not null default 'member',   -- admin | member
    joined_at       timestamptz not null default now(),
    left_at         timestamptz,                       -- null = active member
    unique (conversation_id, user_id)
);

create index if not exists idx_members_conversation on conversation_members (conversation_id);
create index if not exists idx_members_user on conversation_members (user_id);
create index if not exists idx_members_active
    on conversation_members (conversation_id) where left_at is null;
