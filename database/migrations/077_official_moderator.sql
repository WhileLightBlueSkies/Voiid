-- The Voiid Moderator account, an official badge, and scheduled posts.
--
-- ── WHY A REAL USER ROW AND NOT A SPECIAL CASE ──────────────────────────────────────
--
-- `community_posts.author_id` is an ordinary FK to `users`, resolved by a LEFT JOIN at read
-- time (routes/communities.ts AUTHOR_JOIN). Making the moderator a real account means:
--
--   * posts travel the EXISTING authorization path — no bypass to audit later,
--   * both apps render the name and avatar with zero client changes,
--   * deletion, reporting and moderation tooling all keep working on it unmodified.
--
-- The alternative — a null author plus a hardcoded display string in the read path — would
-- put "who wrote this" in two places and let them drift.
--
-- ── WHY THE BADGE IS NOT DECORATION ─────────────────────────────────────────────────
--
-- A display name alone is impersonable: anyone may call themselves "Voiid Moderator". The
-- badge is a server-owned column that public profile updates cannot write, so it is the
-- thing clients trust rather than the string beside it.

-- Reserved so a real signup can never claim it. Not a routable number: +99 is unassigned by
-- the ITU, so no OTP can ever be delivered to it and no person can hold it.
-- The auth path (routes/auth.ts) refuses it explicitly; this is the second lock.
alter table users add column if not exists is_official boolean not null default false;

-- Only ever set by this migration and the admin panel's controlled operations. Public
-- profile PATCH does not list it, the same way `communities.official_key` is closed to
-- public writes (066).
comment on column users.is_official is
    'Server-assigned. Marks a Voiid-operated account so clients can show an official badge. '
    'Never writable through public profile updates — the display name alone is impersonable.';

insert into users (id, phone_number, full_name, is_official)
values ('00000000-0000-4000-8000-000000000001'::uuid, '+990000000001', 'Voiid Moderator', true)
on conflict (phone_number) do update
    set full_name   = excluded.full_name,
        is_official  = true;

-- ── SCHEDULED POSTS ─────────────────────────────────────────────────────────────────
--
-- NULL means "publish immediately", which is every post written before this column existed
-- and every post the apps write today — so the read paths need no backfill and no special
-- case for old rows.
--
-- A post with a future `scheduled_at` is NOT visible: the feed query filters on it, so a
-- scheduled post is invisible to everyone (including its author's own feed) until due. The
-- workers service publishes by simply letting the clock pass it — there is no second write
-- that could fail and strand a post half-published.
alter table community_posts      add column if not exists scheduled_at timestamptz;
alter table community_announcements add column if not exists scheduled_at timestamptz;

-- The feed's hot query becomes "due posts in this community, newest first".
create index if not exists community_posts_due_idx
    on community_posts (community_id, scheduled_at, created_at desc);

-- ── THE MODERATOR MUST ACTUALLY BE A MEMBER ─────────────────────────────────────────
--
-- The posting routes check membership and role like every other writer, deliberately: an
-- account that could post without being a member would be a bypass, and a bypass is the
-- thing that quietly stops being audited. So the moderator joins the three official
-- communities as `admin`, and its posts are authorised by the ordinary rule.
--
-- Idempotent, and `where official_key is not null` rather than a list of ids: the three
-- communities are identified by the key the schema already constrains (066), so this is
-- correct on a database where they have been recreated with different ids.
insert into community_members (community_id, user_id, role, joined_at)
select c.id, '00000000-0000-4000-8000-000000000001'::uuid, 'admin', now()
  from communities c
 where c.official_key in ('jobs', 'feedback', 'updates')
on conflict (community_id, user_id) do update
    -- Rejoin a moderator that was removed: left_at set would otherwise leave the account
    -- looking present while every membership check treated it as gone.
    set role = 'admin', left_at = null;
