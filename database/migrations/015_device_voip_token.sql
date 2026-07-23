-- 015_device_voip_token.sql
-- iOS PushKit / VoIP push token (Section 4.14 — call ringing path).
--
-- A PushKit token is NOT the same value as the app's normal APNs device token:
-- iOS mints it from a separate PKPushRegistry registration, it is delivered on a
-- DIFFERENT APNs topic (`<bundle-id>.voip`), and it is signed with a separate
-- APNs key. So it needs its own column rather than overloading `push_token`.
--
-- Why VoIP push at all: a normal alert push cannot reliably wake a KILLED or
-- long-backgrounded iOS app in time to ring. A VoIP push is delivered at high
-- priority, wakes the process even when terminated, and is the only mechanism
-- that lets the app report an incoming call to CallKit (which iOS requires —
-- failing to report a received VoIP push terminates the app).
--
-- PRIVACY: the VoIP payload stays content-free, exactly like the wake push —
-- only opaque routing ids (call_id, call_kind, conversation_id, caller_id).
-- No SDP, no ICE candidates, no SRTP keys, no names, no message content.

alter table devices add column if not exists voip_token text;

-- Only iOS devices ever carry one; partial index keeps it cheap.
create index if not exists idx_devices_voip
    on devices (user_id) where voip_token is not null and revoked_at is null;
