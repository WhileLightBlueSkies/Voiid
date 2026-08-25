-- 053_community_moderation.sql — reportable community content, and the admin dashboard's
-- numbers.
--
-- Two things ship together here because they are one feature: a community's moderation queue
-- is meaningless without a way to report into it, and a report on a post has nowhere to land
-- without a queue to land in.
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- Nothing in this file weakens anything, and it is worth saying exactly why rather than
-- gesturing at the previous exceptions:
--
--   Reports on posts / communities .. SERVER-READABLE, and they were always going to be:
--                                     035_reports.sql already holds every report the product
--                                     files, for the reason its header gives — a report is an
--                                     accusation addressed TO US, and there is no second party
--                                     to encrypt it to. This file adds two TARGET KINDS to
--                                     that table. It adds no column, no evidence path and no
--                                     new plaintext.
--   The reported content itself ..... ALREADY server-readable, and this is the load-bearing
--                                     point. A community post is a broadcast (047's header)
--                                     and a community's card is shown to strangers (030's).
--                                     A moderator looking at a reported post is looking at
--                                     something the server could already read. NOTHING NEW IS
--                                     DISCLOSED BY MAKING IT REPORTABLE.
--   Dashboard aggregates ............ SERVER-READABLE counts over server-readable tables.
--                                     Every number the dashboard shows is a count of rows the
--                                     server already stores in plaintext.
--
-- STILL END-TO-END ENCRYPTED and untouched: channel messages (MLS, 011), the member↔host DM
-- (Double Ratchet, 006), calls, locations, moments. In particular there is STILL no 'message'
-- target type and still no message_id column anywhere — 035's central refusal stands, and
-- this file deliberately does not go near it.
-- =================================================================================
--
-- ── WHY NOT A NEW community_reports TABLE ────────────────────────────────────────
-- 035's header makes the argument already and it applies unchanged: a table per target kind
-- means the moderator's queue is a UNION that has to be re-sorted and re-paginated every time
-- something new becomes reportable, and it means the disclosure gate gets re-implemented (or
-- forgotten) per table. Two new values in a CHECK constraint is the whole change.

-- ─────────────────────────────────────────────────────────────────────────────────
-- Two new reportable things
--
-- 'community_post' → target_id is community_posts.id
-- 'community'      → target_id is communities.id
--
-- NOTE WHAT THESE ARE NOT: 'community_post' targets the POST, not its author. Reporting a
-- person is what 'creator' and 'message_sender' are for, and they behave differently — they
-- accumulate against an account. A post report is about one piece of content, and resolving
-- it removes that content. Collapsing the two would mean one bad post and a pattern of abuse
-- produced the same row, which is not the same fact and must not sort into the same queue.
--
-- Rebuilding the constraint rather than adding one: a second CHECK on the same column would
-- pass only values satisfying BOTH, so a bare `add constraint` here would forbid every
-- existing value. Dropped and recreated with the full vocabulary.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table content_reports
    drop constraint if exists content_reports_target_type_check;

alter table content_reports
    add constraint content_reports_target_type_check
    check (target_type in (
        'clip',
        'creator',
        'message_sender',
        -- 047: community_posts.id. Server-readable content, already.
        'community_post',
        -- 030: communities.id. The container, reported as a whole — "this entire community is
        -- a scam", which is a different report from any one post inside it.
        'community'
    ));

-- ─────────────────────────────────────────────────────────────────────────────────
-- The evidence and context constraints, restated for the new kinds
--
-- 035 wrote these as `target_type = 'message_sender'` / `target_type <> 'message_sender'`,
-- which happens to give the right answer for both new kinds without being touched:
--
--   content_reports_evidence_scope ...... evidence only on message_sender. A community post
--                                         report needs none — the server holds the post. This
--                                         is 035's "collecting a second copy would be pure
--                                         surplus data" applied to a new kind, and it is
--                                         already what the constraint says.
--   content_reports_context_scope ....... a conversation id only on message_sender. A post
--                                         report carrying one would be a quiet claim about
--                                         where somebody saw something.
--   content_reports_context_required .... message_sender must carry one; the new kinds must
--                                         not, and `<>` already exempts them.
--
-- They are LEFT ALONE ON PURPOSE and this comment exists so the next reader does not have to
-- re-derive that they still hold. If a future target kind needs evidence, it needs its own
-- argument, made here, in this shape.
-- ─────────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────────
-- Finding a community's open reports
--
-- The moderation queue asks one question the existing indexes cannot answer: "which OPEN
-- reports are about content belonging to THIS community". `idx_content_reports_target` is
-- keyed on (target_type, target_id) and answers "reports about this one post"; the queue
-- needs the set, which is a join from community_posts.
--
-- WHY NO community_id COLUMN ON content_reports. It would denormalise a fact that already
-- exists on the post, and it would have to be filled in by the report route — which means a
-- report filed against a post id the route resolved differently from how the queue resolves
-- it becomes a report that is invisible to the community it belongs to. The join is one
-- index probe per report and it cannot disagree with itself.
--
-- This partial index is what makes that join cheap from the reports side: the planner can
-- take the small set of open community_post reports and probe community_posts, rather than
-- scanning a community's posts and probing reports for each.
-- ─────────────────────────────────────────────────────────────────────────────────
create index if not exists idx_content_reports_open_community_posts
    on content_reports (target_id, created_at desc)
    where status = 'open' and target_type = 'community_post';

-- The same, for reports filed against a community as a whole. Separate rather than one index
-- over both kinds: these are read by different surfaces — a community's own queue never shows
-- reports ABOUT that community (a host is not the right person to adjudicate an accusation
-- against their own community; those belong to the platform admin queue), so the two are
-- never scanned together.
create index if not exists idx_content_reports_open_communities
    on content_reports (target_id, created_at desc)
    where status = 'open' and target_type = 'community';

-- ─────────────────────────────────────────────────────────────────────────────────
-- WHAT THE DASHBOARD NEEDS, AND WHY THAT IS NO NEW TABLE
--
-- The admin dashboard shows four numbers. Three of them are already computable and the fourth
-- one, honestly, is NOT — and it is not being invented here.
--
--   Members (total) ....... communities.member_count. Already denormalised and
--                           trigger-maintained (030, bump_community_member_count). No work.
--   Posts ................. count(*) over community_posts where removed_at is null. Indexed
--                           by community_posts_feed_idx.
--   Open reports .......... count(*) over the join described above, plus pending join
--                           requests. Indexed by the two partial indexes above and by
--                           idx_community_members_pending (030).
--
--   ACTIVE MEMBERS ........ NOT COMPUTABLE, AND DELIBERATELY NOT INVENTED.
--
-- That last one is the whole reason this section is a comment and not a table. "Active today"
-- requires a per-user last-seen timestamp scoped to a community, and NOTHING IN THIS SCHEMA
-- RECORDS ONE. `community_members.joined_at` is when they arrived, not when they were last
-- here. There is no read receipt, no presence row, no per-community session log.
--
-- The three ways this could be faked, and why each is refused:
--
--   * Count members who posted recently. That is a count of AUTHORS, which in every community
--     is a small fraction of the people who read it. Labelling it "active" would tell a host
--     their community is a tenth as alive as it is.
--   * Count members who joined recently. That is a growth number wearing an engagement
--     number's label.
--   * Take a percentage of member_count. That is a made-up number with a real number's
--     precision, which is the worst of the three.
--
-- So `GET /communities/:id/stats` OMITS the field entirely rather than returning a guess, and
-- the dashboard renders three cards instead of four. A dashboard with three true numbers is
-- more useful to a host than one with four numbers of which one is a lie they cannot identify.
--
-- BUILDING IT PROPERLY would mean a `community_member_activity (community_id, user_id,
-- last_seen_at)` table written on feed reads — which is a per-read write on the hottest path
-- in the tab, a new piece of per-user behavioural telemetry that nobody has consented to, and
-- a retention policy decision under DPDP (030_dpdp.sql). All three of those are decisions,
-- not implementation details, and none of them get made as a side effect of filling in a
-- dashboard card. When someone decides to build it, it gets its own migration and its own
-- argument about what is being recorded and for how long.
-- ─────────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────────
-- Retention: unchanged, and deliberately so.
--
-- 035 already declared `content_reports` in data_retention_policy, and its declaration covers
-- these rows without amendment — the personal data in a community_post report is the same
-- shape it described (a reporter id, their note, the id of what was reported). No new row is
-- inserted here because there is no new table, and rewriting 035's row would restate a policy
-- nobody has changed.
--
-- [COUNSEL] Both open questions 035 recorded are INHERITED here unchanged and are not resolved
-- by this file: (1) whether a resolved report that justified a takedown must outlive the
-- reporter's erasure, and (2) whether IT Rules 2021 grievance obligations impose a retention
-- floor. Adding two target kinds does not answer either, and nothing here asserts that Voiid
-- meets any grievance timeline for community content.
-- ─────────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────────
-- WHAT THIS FILE DELIBERATELY DOES NOT ADD
--
-- No auto-removal threshold for reported posts. 035 refused one for clips and the refusal is
-- the same here, only sharper: a community post can be reported by members of that community,
-- so "hide anything with N reports" hands a takedown button to any N members who agree with
-- each other. Every removal goes through a named moderator setting `removed_at`.
--
-- No notification to the reported post's author. Same reasoning as 035: in a community, a
-- report comes from someone the author is in a room with, and telling them they were reported
-- is a retaliation vector.
--
-- No per-community moderator audit table. Removals already write `community_posts.removed_by`
-- (047) and platform-level actions already write admin_audit_log (028). A third log would be a
-- third place to look and a third place to forget to write.
-- ─────────────────────────────────────────────────────────────────────────────────
