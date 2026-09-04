-- =================================================================================
-- 056 — an event is a reportable thing, and a report can take it off sale
--
-- Two changes, and the second is the one that matters.
--
-- ── 1. 'event' JOINS THE TARGET VOCABULARY ───────────────────────────────────────
--
-- 053's argument for not making a new table applies here unchanged: a table per target kind
-- turns the moderator's queue into a UNION that has to be re-sorted and re-paginated every
-- time something new becomes reportable. One more value in a CHECK constraint is the whole
-- change. The constraint is dropped and recreated rather than added to, for 053's reason —
-- a second CHECK on the same column passes only values satisfying BOTH, which would forbid
-- every existing value.
--
-- WHAT 'event' IS NOT. It targets the EVENT, not its host. Reporting a person is what
-- 'creator' and 'message_sender' are for and they accumulate against an account. An event
-- report is about one listing — "this event is a scam, it does not exist" — and resolving it
-- takes that listing down. Collapsing the two would file one bad listing and a pattern of
-- fraud as the same fact.
--
-- The evidence/context constraints from 035 are LEFT ALONE and still give the right answer:
-- they are written as `= 'message_sender'` / `<> 'message_sender'`, so an event report
-- carries no evidence blob (the server holds the listing) and no conversation id (which
-- would be a quiet claim about where somebody saw it).
--
-- ── 2. AN EVENT CAN BE SUSPENDED, WHICH IS NOT CANCELLED ─────────────────────────
--
-- community_events.status already has 'cancelled', and reusing it here would be wrong in a
-- way that costs money. 'cancelled' is the HOST's decision and it is final — the event is
-- off, tell the attendees. A moderator acting on a report is making a different and
-- reversible statement: this listing is off sale WHILE WE LOOK AT IT. A false report that
-- 'cancelled' an event would be indistinguishable from the host cancelling it, and there
-- would be nothing to restore.
--
-- So suspension is its own nullable timestamp beside the status, not a status value:
--
--   * status stays whatever the host set. A suspended-then-cleared event returns to exactly
--     the state it was in, with no guess about what it used to be.
--   * `suspended_at is not null` is one predicate for every read path that must stop selling.
--   * It is reversible by definition — clearing a column, not reconstructing a status.
--
-- WHY NO suspended_by / suspended_reason COLUMNS. The admin_audit_log already records who
-- did what to which entity, and that is the record that has to survive. Duplicating the
-- actor here means two places that can disagree about who suspended something, and the
-- audit log is the one that is written on every admin action whether or not this table
-- happens to have a column for it.
-- =================================================================================

alter table content_reports
    drop constraint if exists content_reports_target_type_check;

alter table content_reports
    add constraint content_reports_target_type_check
    check (target_type in (
        'clip',
        'creator',
        'message_sender',
        -- 047: community_posts.id.
        'community_post',
        -- 030: communities.id.
        'community',
        -- 032: community_events.id. The listing, reported as a whole.
        'event'
    ));

-- Reports filed against an event. Separate partial index for 053's reason: these are read by
-- a different surface from post and community reports and are never scanned together.
create index if not exists idx_content_reports_open_events
    on content_reports (target_id, created_at desc)
    where status = 'open' and target_type = 'event';

-- ─────────────────────────────────────────────────────────────────────────────────
-- The suspension itself
-- ─────────────────────────────────────────────────────────────────────────────────
alter table community_events
    add column if not exists suspended_at timestamptz;

-- Finding what is currently suspended, for the admin surface that has to review and clear
-- these. Partial because a suspended event is by design a rare row and a full index over a
-- mostly-null column would be paid for on every event write.
create index if not exists idx_community_events_suspended
    on community_events (suspended_at desc)
    where suspended_at is not null;
