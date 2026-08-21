-- 045: a lifecycle for host threads, so a host can tell "nobody has looked at this" from
-- "someone is handling it" from "done".
--
-- WHY NOT A BOOLEAN. An is_read flag collapses the middle state, and the middle state is
-- exactly where a message gets forgotten: a host opens a thread, means to come back to it,
-- and it now looks identical to every thread already dealt with. Three states cost one
-- column and make the queue readable.
--
-- WHY NOT DERIVED FROM UNREAD COUNTS. A conversation's unread count answers "have the bytes
-- been delivered to this device", which is a different question and a per-device one. A
-- moderation queue is shared: a host on their iPad must see what they resolved on their
-- phone, and a co-host must see what the owner already handled. That is server state.
--
-- The status belongs on the THREAD, not the conversation: the conversation is an ordinary
-- E2EE direct chat that happens to be reachable from a community, and nothing else in the
-- app should learn a moderation vocabulary.

alter table community_host_threads
    add column if not exists status text not null default 'unread'
        check (status in ('unread', 'open', 'resolved')),
    -- Who last moved it, and when. Not an audit log — just enough for a co-host to see that
    -- someone else is already on it, which is the whole point of the 'open' state.
    add column if not exists status_changed_at timestamptz,
    add column if not exists status_changed_by uuid references users(id) on delete set null;

-- The inbox lists by (community, status) and orders by recency. Partial on the two states a
-- host actually queries: 'resolved' is the archive, and paging it is rare enough that the
-- planner can scan.
create index if not exists community_host_threads_open_idx
    on community_host_threads (community_id, created_at desc)
 where status in ('unread', 'open');
