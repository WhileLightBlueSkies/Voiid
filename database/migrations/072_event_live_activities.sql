-- Device-bound ActivityKit subscriptions. Tokens never grant ticket access.
create table if not exists event_live_activities (
  device_id uuid not null references devices(id) on delete cascade,
  ticket_id uuid not null references event_tickets(id) on delete cascade,
  token text not null check (length(token) between 64 and 512),
  sandbox boolean not null,
  expires_at timestamptz not null default now() + interval '8 hours',
  next_check_at timestamptz not null default now(),
  last_payload text,
  last_sent_at timestamptz,
  primary key (device_id, ticket_id)
);
create index if not exists event_live_activities_due on event_live_activities(next_check_at);
