-- Member-specific preferences; controls message alerts, never ciphertext delivery.
alter table community_members add column if not exists notification_mode text not null default 'important'
  check (notification_mode in ('all', 'important', 'none'));

-- A retryable server backstop for Android devices that never received the ring push.
alter table calls add column if not exists missed_push_sent_at timestamptz;
alter table calls add column if not exists missed_push_lease_until timestamptz;
-- Existing call history must not generate a flood of old missed-call alerts on deployment.
update calls set missed_push_sent_at = now() where missed_push_sent_at is null;
