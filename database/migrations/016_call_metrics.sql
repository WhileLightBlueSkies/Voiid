-- 016_call_metrics.sql
-- ANONYMOUS call-quality / reliability metrics (Section 4.14).
--
-- WHY: "did the call connect, how fast, did it hold, did it need a relay" are the
-- only numbers that show whether calling actually works on real networks. Without
-- them call reliability is guesswork. This table exists to answer exactly that and
-- nothing else.
--
-- ============================== PRIVACY DECISION ==================================
-- This table deliberately has NO user_id, NO device_id, NO conversation_id and NO
-- call_id. It is NOT a call detail record and must never become one.
--
--  * NO user_id (not even a coarse bucket). A row of (user, when, duration) IS a
--    CDR — the metadata shape that reconstructs "who talked to whom, when, for how
--    long". A hashed/bucketed user id was considered and REJECTED: a bucket is a
--    stable pseudonym, and a stable pseudonym plus timestamps plus durations
--    re-identifies people by correlation. Rows here are genuinely anonymous samples.
--
--  * NO call_id. `calls.id` is the PK of a table holding caller_user_id and
--    conversation_id, so storing it would make this table joinable straight back
--    onto the identity we just removed. `dedupe_hash` instead holds an HMAC-SHA256
--    of the call id under a server-side secret (VOIID_METRICS_DEDUPE_SECRET). It
--    makes a client retry idempotent, is not reversible without the secret, and
--    ROTATING that secret permanently severs the linkage for every existing row.
--    With the secret unset the API uses a random per-process key: dedupe degrades
--    to per-process and linkage becomes impossible by construction (safe default).
--
--  * HOUR BUCKET, not a timestamp. An exact insert time correlates one-to-one with
--    `calls.ended_at` and would re-link an anonymous row to an identified one by
--    timing alone. `bucket_hour` is coarse enough to break that alignment and still
--    fine enough for reliability trends.
--
--  * NEVER STORED, at any point: SDP, ICE candidates, IP addresses, peer identity,
--    audio/video, or any call content. The API whitelists the columns below
--    key-by-key (backend/api/src/callMetrics.ts) and drops everything else, so a
--    new client field cannot silently become stored data.
-- ==================================================================================

create table if not exists call_metrics (
    id                   uuid primary key default gen_random_uuid(),

    -- HMAC-SHA256(server_secret, call_id). Idempotency key ONLY — see above.
    dedupe_hash          bytea not null unique,

    -- Coarse time bucket (hour), NOT an exact timestamp. Deliberate.
    bucket_hour          timestamptz not null,

    platform             text not null check (platform in ('ios','android')),

    -- Did the call reach a connected media state at all (setup success)?
    connected            boolean not null,
    -- Did media go through a TURN relay rather than peer-to-peer?
    relayed              boolean not null,

    -- Constrained vocabulary: free text would be both useless for aggregation and a
    -- channel through which a client could smuggle identifiers or content.
    end_reason           text not null check (end_reason in (
                             'hangup','declined','missed','busy','failed',
                             'timeout','network_lost','unanswered','unknown')),

    -- Time-to-connect. Null when the call never connected. Clamped by the API.
    setup_ms             integer check (setup_ms between 0 and 300000),
    -- Call length. Clamped to 24h.
    duration_ms          bigint  check (duration_ms between 0 and 86400000),
    ice_restarts         integer check (ice_restarts between 0 and 50),

    -- Aggregate quality signals, already averaged ON DEVICE over the whole call.
    -- No per-sample time series — a time series is a behavioural fingerprint.
    avg_rtt_ms           numeric(7,2) check (avg_rtt_ms between 0 and 10000),
    avg_packet_loss_pct  numeric(5,2) check (avg_packet_loss_pct between 0 and 100),
    jitter_ms            numeric(7,2) check (jitter_ms between 0 and 10000)
);

-- The summary endpoint always scans a trailing time window, optionally per platform.
create index if not exists idx_call_metrics_window
    on call_metrics (bucket_hour desc);
create index if not exists idx_call_metrics_platform_window
    on call_metrics (platform, bucket_hour desc);

-- RETENTION: these rows are for trend analysis, not history. Prune aggressively —
-- the longer an anonymous sample set is kept, the more surface it offers to
-- correlation attacks. Suggested ops cron (not enforced here so the window stays a
-- deployment decision):
--   delete from call_metrics where bucket_hour < now() - interval '90 days';
