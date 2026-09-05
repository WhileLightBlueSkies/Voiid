# 11 — Payments, media and workers

Baseline: `a2e24e5` · 2026-09-06 · C01 completed locally; C02-C04 TODO. The issue register is the status authority.

## C01 — Resume failed payment webhook processing

**Priority:** P0 · **Evidence:** Confirmed · **Dependencies:** Disposable provider fixtures and database

**Location:** `backend/api/src/routes/payments.ts:131`, `:148`, `:156`, `:161`, `:187`.

The delivery event is inserted before settlement. If settlement fails after insertion, a retry finds the duplicate and returns success without retrying the unprocessed event. An unmatched event is marked processed immediately, even if order creation/reference persistence races webhook arrival.

**Fix:** distinguish received, processing, processed, retryable-failed and unmatched states. Atomically claim processing with a lease/transaction; return duplicate success only when already processed or durably queued for retry. Make settlement/ticket creation and the corresponding event transition transactional, or connect them through a durable inbox worker. Reconcile unmatched provider references. Preserve raw-body signature validation and monotonic order status, including refund ordering. Keep payment values as validated integer minor units.

**Done when:** process death/DB failure between event receipt and settlement recovers on retry; two concurrent deliveries issue one ticket set; a webhook preceding the stored order reference later reconciles; refund-before/after-paid ordering follows an explicit tested policy. Use provider test mode only.

## C02 — Make worker health reflect returned failures and staleness

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `backend/workers/src/index.ts:78`, `:120`, `:144`; `retention.ts:179`; `reapStories.ts:87`.

Jobs catch individual errors and return failure counts/lists. The supervisor treats any returned result as success and health primarily checks thrown errors plus stuck erasures. Retention/reaping can therefore fail while health remains green. An indefinitely running job also lacks a freshness failure gate.

**Fix:** define typed health outcomes for each job, classify partial failures/backlog/drift, and surface actionable degraded status. Add last-success age and in-flight duration thresholds derived from job interval/workload. Export backlog and error metrics without leaking private row details. Make deployment treat required-worker readiness as required, not a printed warning.

**Done when:** R2 failure, retention SQL failure, policy drift and a hung job produce the appropriate degraded/stale signal; empty successful sweeps remain healthy; recovery clears alerts without requiring restart.

## C03 — Hold durable cleanup claims beyond the selection transaction

**Priority:** P2 · **Evidence:** Confirmed multi-worker risk · **Dependencies:** C02

**Location:** `backend/workers/src/reapStories.ts:55`, `:65`, `:75`; `erasure.ts:185`, `:197`, `:204`.

`FOR UPDATE SKIP LOCKED` selects rows, then commits before processing them. Locks are released without a persistent claim marker, so another worker can select the same rows. This creates duplicate work and unreliable counts; idempotent object deletion reduces some effects but does not establish ownership.

**Fix:** add claim owner/lease expiry and bounded attempts, or use a durable cleanup queue. Claim atomically, perform external IO outside long-held SQL locks, complete using the claim token, and reclaim expired leases after crashes. Keep deletion idempotent and report actual row counts. Do not scale workers until ownership is defined.

**Done when:** two workers claim disjoint active work, one can recover the other's expired lease, an old owner cannot finalize a reassigned claim, and erasure remains retryable after R2/DB outages.

## C04 — Keep a durable record of story objects still requiring deletion

**Priority:** P1 · **Evidence:** Confirmed dependency risk · **Dependencies:** C02/C03

**Location:** `backend/workers/src/reapStories.ts:79`, `:100`, `:110`; existing retry pattern in `backend/workers/src/erasure.ts:108`.

The reaper can delete story metadata when R2 is unconfigured, or after repeated object-deletion failures, relying on an external bucket lifecycle rule. That rule was not verified in this audit. Removing the metadata can remove the application's record of remaining objects.

**Fix:** retain failed object keys in a durable deletion queue, extending the erasure retry pattern where appropriate. Make missing storage configuration explicit for deployments that have stored media. Verify lifecycle policy as a secondary safety net with prefix/retention evidence; do not use an unverified lifecycle claim as proof of deletion. Include thumbnails/renditions where relevant.

**Done when:** metadata expiration does not lose object cleanup intent; repeated outages leave a visible retry backlog; restored storage drains it; deletion and bucket lifecycle are demonstrated using synthetic objects.

**Media/commerce follow-through:** part 16 covers upload quotas, orphan objects, large-file memory, clip playback/export, event inventory, tournament concurrency and authorization. Those are mandatory verification work, not all confirmed defects from this source audit.
