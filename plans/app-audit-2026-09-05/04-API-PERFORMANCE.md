# 04 — API and database performance

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

## P01 — Stop unrelated routes sharing the host-thread throttle

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `backend/api/src/index.ts:192` (root host-thread mount; locate `bucket: 'community-host-thread'`), `:210` (root highlights mount); `backend/api/src/security.ts:67`.

Root-mounted middleware runs before checking whether the following router owns the path. The 30/minute host-thread limiter therefore charges later community/creator/report/event/game routes too. Many mount-level limiters also run before `requireAuth`, so they key by IP despite intended per-user behavior.

**Fix:** mount narrow limiters inside their actual route declarations, after authentication where user-scoped. Keep a separately sized global IP guard for unauthenticated floods. Inventory every root-mounted limiter, including highlights/events/tournaments. Do not raise the global ceiling to hide a routing bug.

**Done when:** 31 ordinary community reads do not spend host-thread-creation allowance; creating host threads still reaches its own limit; two users behind one NAT have independent authenticated buckets; anonymous traffic remains limited. Integration-test the real mount order.

## P02 — Make limiter windows atomic and rejection work cheap

**Priority:** P2 · **Evidence:** Confirmed implementation risk · **Dependencies:** P01

**Location:** `backend/api/src/security.ts:71`, `:77`, `:102`.

`INCR` then `EXPIRE` are separate commands; failure between them can leave a counter without expiry. Every rejected request awaits a database security-event insert. The implementation is fixed-window despite comments calling it sliding-window.

**Fix:** choose and document fixed-window/token-bucket/sliding-window semantics; implement atomic counting/expiry with a tested script. Add `Retry-After`. Aggregate/sample repetitive rejection logs and export counters instead of writing one DB row for every flood request. Specify outage behavior separately for general traffic and sensitive key/recovery/auth endpoints; honor the intended fail-open choice only with bounded latency and visible degradation.

**Done when:** fault injection cannot create immortal counters; a rejection flood does not flood Postgres; limits work across instances; retry timing is correct at window boundaries.

## P03 — Handle every Express 4 async rejection and input error

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `backend/api/package.json` uses Express 4; `routes/auth.ts:15`, `routes/prekeys.ts:136`, `routes/receipts.ts:31`, `routes/backup.ts:68` use bare async handlers; `src/index.ts:289`, `:298`.

Several route promises can reject without reaching the global error middleware. The process-level rejection logger does not complete the affected HTTP request. The error middleware also maps body-too-large errors to 500 rather than honoring 413.

**Fix:** consistently use existing `asyncHandler` (including admin and other bare async routes found by the route inventory). Preserve safe structured 4xx errors from parsers/validators; do not infer validation solely from error-message regex. Add request schemas for UUIDs, bounded arrays, positive limits, allowed enum values, and payload sizes. Return stable error codes and request IDs; keep SQL/provider internals out of responses. Preserve raw payment-webhook parsing order.

**Done when:** rejected DB/cache/provider promises finish with a sanitized response; invalid JSON → 400, oversized payload → 413, timeout → defined retryable response; no hung requests or unhandled rejections under injected failures. Express's official error-handling reference is linked in 18-SOURCES.

## P04 — Bound pool, cache, and request latency before scaling

**Priority:** P2 · **Evidence:** Configuration gap; latency unmeasured · **Dependencies:** S05

**Location:** `backend/api/src/db.ts:10`, `backend/games/src/db.ts:12`, `backend/workers/src/db.ts:15`, `backend/api/src/redis.ts:4`; sequential publish loop `routes/messages.ts:291`.

API/games pools rely on defaults; dependency-specific connection/statement deadlines and Redis command/offline-queue behavior are not explicitly bounded. Workers have a useful small pool (`max: 2`), which should remain intentional. Sequential fanout puts Redis RTT on the request path once per recipient.

**Fix:** define separate pool budgets within the database connection ceiling, bounded connection acquisition and transaction/statement deadlines, and short Redis command timeouts/offline-queue policy. Instrument queue wait, query duration, event-loop delay, request latency/error rate, and outbox lag with low-cardinality labels. Move durable fanout to M01's worker; use bounded pipelining, not unbounded `Promise.all`. Add graceful draining and cancellation for requests leaving the system.

**Done when:** DB/Redis outage tests complete within declared deadlines, recover without retry storms, and do not exhaust memory/connections; a staged concurrency ramp meets the budgets in part 16. Choose final pool sizes from measurements, not an arbitrary large maximum.
