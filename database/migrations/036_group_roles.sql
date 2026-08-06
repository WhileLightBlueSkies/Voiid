-- 036_group_roles.sql — one owner, up to 50 admins, up to 1000 members.
--
-- WHAT WAS THERE BEFORE: `conversation_members.role` was unconstrained text defaulting to
-- 'member' (005_conversations.sql:26), the group creator was inserted as 'admin', and there
-- was NO member limit anywhere in the schema or the routes. Nothing could change a role —
-- the "Make group admin" buttons in both apps were literal no-ops — and nothing stopped a
-- group growing until the MLS commit fan-out fell over.
--
-- ROLES ARE SERVER-SIDE PLAINTEXT METADATA AND ALWAYS HAVE BEEN. Who is an admin is not
-- message content; the server already stores membership in order to route fan-out. Nothing
-- here weakens E2EE — the messages themselves stay encrypted per recipient device, and this
-- file touches no ciphertext.

-- ─────────────────────────────────────────────────────────────────────────────────
-- The role vocabulary
--
-- A CHECK rather than an enum type: adding a value to a Postgres enum cannot run inside a
-- transaction on older servers, which would make a future 'moderator' role a deployment
-- event rather than a migration. A CHECK is altered like any other constraint.
-- ─────────────────────────────────────────────────────────────────────────────────

-- Existing rows first: the constraint below would reject anything already out of vocabulary.
-- 'admin' and 'member' are the only values the old code ever wrote, so this is a no-op in
-- practice and insurance against a hand-edited row.
update conversation_members
   set role = 'member'
 where role not in ('owner', 'admin', 'member');

-- THE CREATOR BECOMES THE OWNER. Groups created before this migration have an 'admin'
-- creator and no owner at all, so every one of them would be permanently unable to transfer
-- ownership or block a last-admin exit. Backfilled from conversations.created_by, and only
-- for members who are still present — promoting someone who left would create an owner who
-- cannot act.
update conversation_members m
   set role = 'owner'
  from conversations c
 where c.id = m.conversation_id
   and c.type = 'group'
   and c.created_by = m.user_id
   and m.left_at is null
   and m.role <> 'owner';

alter table conversation_members
    drop constraint if exists conversation_members_role_check;
alter table conversation_members
    add constraint conversation_members_role_check
    check (role in ('owner', 'admin', 'member'));

-- ─────────────────────────────────────────────────────────────────────────────────
-- Exactly one owner, structurally
--
-- PARTIAL on `left_at is null` for a reason that is easy to get wrong: an owner who leaves
-- keeps their row (membership is soft-deleted so history survives), and a total index would
-- then forbid the group from ever having an owner again. The index constrains who is owner
-- AMONG PRESENT MEMBERS, which is the question that actually matters.
--
-- THE REINSTATE HAZARD, stated here because the route cannot express it: the add-members
-- path upserts with `on conflict … do update set left_at = null`. A former OWNER who is
-- re-added would come back still carrying role='owner' and trip this index — the insert
-- fails and re-adding that person becomes impossible. routes/conversations.ts therefore
-- resets role to 'member' on reinstate. Anyone editing that upsert must keep doing so.
-- ─────────────────────────────────────────────────────────────────────────────────
create unique index if not exists idx_conversation_one_owner
    on conversation_members (conversation_id)
    where role = 'owner' and left_at is null;

-- The admin-count and member-count checks run on every add and every promotion, so they are
-- worth an index rather than a sequential scan of a 1000-row membership.
create index if not exists idx_conversation_members_active
    on conversation_members (conversation_id, role)
    where left_at is null;

-- ─────────────────────────────────────────────────────────────────────────────────
-- System events
--
-- Membership and role changes were SILENT. Both apps already render a centred pill for a
-- system message; nothing ever produced one outside dummy data, so a group could change
-- hands with no trace in the conversation it happened to.
--
-- STRUCTURED, NOT PRE-BAKED ENGLISH. The payload names the kind and the actors; the client
-- composes the sentence, which is the only way "You made Priyanshu an admin" can differ from
-- "Nehal made Priyanshu an admin" for the two people reading it — and the only way this
-- localizes. Signal's update-message producer works the same way and for the same reason.
--
-- On the message row itself rather than a side table: these events belong in the timeline,
-- ordered against the messages around them. A separate table would need merging at read time
-- in every client, and would drift out of order the first time a clock disagreed.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table messages
    add column if not exists system_event jsonb;

-- Only system rows carry a payload, and every system row must carry one. A 'system' message
-- with no event is a pill the client cannot render; a normal message with an event is a
-- payload nothing will read.
alter table messages
    drop constraint if exists messages_system_event_shape;
alter table messages
    add constraint messages_system_event_shape
    check (
      (content_type = 'system' and system_event is not null)
      or (content_type <> 'system' and system_event is null)
    );

-- The timeline query filters by conversation and orders by time; system rows ride along with
-- everything else, so no new index is needed for reads. This one supports the moderation and
-- audit question "what happened in this group", which scans by event kind.
create index if not exists idx_messages_system_event_kind
    on messages ((system_event ->> 'kind'))
    where content_type = 'system';
