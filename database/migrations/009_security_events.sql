-- 009_security_events.sql
-- Security monitoring (Section 4.9): track failed logins, OTP abuse, API abuse, device-linking events,
-- suspicious sessions, anomalous traffic. Stored separately from app data.

create table if not exists security_events (
    id              uuid primary key default gen_random_uuid(),
    event_type      text not null,                     -- failed_login | otp_abuse | api_abuse | device_link | suspicious_session | anomalous_traffic
    user_id         uuid references users(id) on delete set null,
    device_id       uuid references devices(id) on delete set null,
    phone_number    text,                              -- for pre-auth events
    ip_address      inet,
    metadata        jsonb,                             -- structured event detail
    created_at      timestamptz not null default now()
);

create index if not exists idx_sec_events_type on security_events (event_type, created_at desc);
create index if not exists idx_sec_events_user on security_events (user_id);
