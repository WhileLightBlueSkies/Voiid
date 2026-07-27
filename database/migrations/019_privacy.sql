-- 019_privacy.sql — WhatsApp-style "who can see" visibility for profile fields.
--
-- Each is one of: 'everyone' | 'contacts' | 'nobody'. Enforced server-side in
-- GET /users/:id (photo_url, bio) and in the presence/last-seen path (last_seen).
-- 'contacts' means: visible only to a viewer the OWNER has saved as a contact
-- (a contact_sync row with owner_user_id = this user, contact_user_id = viewer).
--
-- Default 'everyone' preserves today's behaviour for existing rows.

alter table users add column if not exists photo_privacy      text not null default 'everyone';
alter table users add column if not exists about_privacy      text not null default 'everyone';
alter table users add column if not exists last_seen_privacy  text not null default 'everyone';
