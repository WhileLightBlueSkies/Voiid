-- Daily authenticated API usage, not foreground sessions or message content.
create table if not exists admin_usage_collection (
  id boolean primary key default true check (id),
  started_at timestamptz not null default now()
);
insert into admin_usage_collection(id) values(true) on conflict (id) do nothing;
create table if not exists user_daily_activity (
  day date not null,
  user_id uuid not null references users(id) on delete cascade,
  platform text not null check(platform in ('ios','android','web','unknown')),
  primary key(day,user_id,platform)
);
create index if not exists user_daily_activity_user on user_daily_activity(user_id);
