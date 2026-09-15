-- Staff grants never modify community roles or messaging permissions.
create table event_staff (
 event_id uuid not null references community_events(id) on delete cascade,
 user_id uuid not null references users(id) on delete cascade,
 role text not null check(role in ('manager','volunteer')),
 state text not null default 'pending' check(state in ('pending','active','revoked')),
 invited_by uuid not null references users(id),
 invited_at timestamptz not null default now(),
 expires_at timestamptz not null,
 accepted_at timestamptz,
 primary key(event_id,user_id)
);
create index event_staff_user on event_staff(user_id,expires_at);
