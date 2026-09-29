-- 097_call_metrics_early_timeline.sql
-- The first ~30 seconds of a call, point by point (see backend/api/src/callMetrics.ts,
-- normalizeTimeline). The per-call averages could not tell "bad for the first 20 seconds,
-- then fine" from "mediocre throughout", nor whether the delay was in the network or in the
-- phone's playout buffer. Each point is timings and loss only — the same anonymity rules
-- as the rest of this table (016): no user, device or call id, no addresses, no content.
--
-- Idempotent.

alter table call_metrics add column if not exists early_timeline jsonb;

do $$ begin
    alter table call_metrics add constraint call_metrics_early_timeline_ck check (
        early_timeline is null
        or (jsonb_typeof(early_timeline) = 'array' and jsonb_array_length(early_timeline) <= 12)
    );
exception when duplicate_object then null;
end $$;

comment on column call_metrics.early_timeline is
    'First ~30s after media connected: [{t, rtt, buf, loss, up}] — seconds, round-trip ms, '
    'playout-buffer ms, downlink loss %, uplink loss %. Measurements only; see callMetrics.ts.';
