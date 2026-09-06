# Continuation evidence — 6 September 2026

This records reviewed local work, including patches recovered after agents stopped at their usage limit. No production changes were made.

## Messaging

M01: a forced simultaneous insertion reproduced two HTTP 200 responses for the same client ID with different ciphertext. The losing request now compares the committed winner's fingerprint and returns 409 for different bytes. All 11 send integration tests pass. M01 remains implemented/unverified as a whole: persistent prepared envelopes and native crash/retry acceptance still need work.

## Worker cleanup and health

C02/C03/C04: enqueue and story/erasure metadata deletion now commit together. An enqueue failure rolls back metadata. External object deletions have durable claim tokens, leases, bounded batches and retry backoff. A stale owner cannot finalize a newer claim. Erasure holds SQL selection locks through SQL-only cleanup, with per-account savepoints; external I/O is handled separately.

Health recognizes failure arrays and policy drift, tracks startup staleness, updates last-success only for successful results, and redacts errors. Routine queue production is no longer mistaken for a failed pass; the drain reports pending objects.

32 worker tests passed with both PostgreSQL suites enabled. Tests include ordinary and abandoned-story enqueue failures, disjoint claims, expiry/reclaim/fencing, storage failure and recovery, erasure rollback/retry, retention SQL failure and drift. Object storage is injected in these tests; no actual R2 bucket/lifecycle test was performed. Required-worker deployment readiness remains open. These three issue statuses remain implemented/unverified pending full acceptance.

## Android

A02: corrupted encrypted preferences now preserve originals and report unavailability. Old quarantine evidence prevents silently bootstrapping replacement identity stores. Recovery UI/device fault scenarios remain open.

A05: coroutine cancellation now cancels the underlying HTTP call during both header wait and body consumption, closes responses and propagates cancellation. Added explicit whole-call deadlines and disabled implicit connection retries for ambiguous sends. Two real local-socket cancellation tests pass.

I03 follow-up: shard writes use separate temporary files and sync bytes before replacement; a failed quarantine rename no longer copies/deletes the original. Full durable ACK retry and iOS acceptance remain open.

U01/U02/U03: sheets await exit completion, retain detent identity, start offscreen and retarget measurement changes; dialogs use their configured native Back policy. Android debug build and 87 unit tests passed. No controlled-clock Compose, predictive Back, TalkBack or frame recording was performed, so these issues remain implemented/unverified.

Unfinished photo/typography test drafts are preserved under `pending/`, outside executable test discovery. Their proposed production changes were not made.

## Relay

R01: API and relay share the conference grant parser; malformed/unknown versioned grants fail closed without falling back to a legacy pair. R03/R04 follow-ups add bounded outbound buffers, authentication deadlines, expiry/revocation heartbeats, per-connection presence leases and a shared frame budget. Buffered call/location delivery rechecks current audience.

28 relay tests passed, including actual PostgreSQL session and recipient checks; shared/API/websocket types pass. These do not yet prove two live relay instances, connection races or slow-network behavior. R01/R03/R04 remain implemented/unverified; R05 admission serialization was not implemented by the interrupted agent.

## Web/admin

W01/W02/W03: useList now invalidates at filter commit, survives StrictMode cleanup/setup, associates responses with their current request and prevents an obsolete append from unlocking a new one. Report Cancel/Escape resets the selector and sends no mutation; a synchronous busy guard prevents concurrent writes. Mobile nav is hidden from focus/accessibility when collapsed and restores visible focus after Escape, route changes and resize.

8 real Chrome browser scenarios passed with actual hook/report/header components. Next navigation is mocked at the routing boundary, HTTP responses are controllable and deliberately ignore abort to test late responses. 10 helper tests and admin/web typechecks pass. The browser harness uses external Playwright through AUDIT_TEST_TOOLS and optional AUDIT_BROWSER_EXECUTABLE; it is not yet a CI job.

## Migrations

Q05: one session advisory lock serializes runners. SHA-256 checksums detect edited/missing history. Old ledgers require a reviewed baseline from the previous deployed artifact. Failed ordinary SQL leaves no applied entry; nontransactional SQL records intent and refuses blind rerun after interruption.

The PostgreSQL migration test passed for concurrency, rollback, drift, explicit baseline and nontransactional failure. All 69 repository migrations applied successfully to a new disposable database; a second run verified and skipped them. Actual deployed-schema baseline and CI wiring remain unverified. See infrastructure/deployment/MIGRATIONS.md before rollout.
