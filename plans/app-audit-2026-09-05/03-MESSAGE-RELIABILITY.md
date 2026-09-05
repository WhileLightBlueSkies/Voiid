# 03 — Durable messaging and synchronization

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

## M01 — Make message acceptance atomic and retry-safe

**Priority:** P0 · **Evidence:** Confirmed · **Dependencies:** S02

**Location:** `backend/api/src/routes/messages.ts:215`, `:251`, `:291`, `:331`; Android `net/ChatEngine.kt:1454` and iOS `Networking/ChatEngine.swift` under their respective app source roots.

Message metadata, device ciphertext rows, and Redis notification are separate operations. The send contract has no stable client request ID. A DB or Redis failure after the first insert can leave partial data or make a retry create another message.

**Fix:**
1. Add a client-generated stable message ID/idempotency key, scoped to sender/device; add a database uniqueness constraint and store a payload fingerprint.
2. In one Postgres transaction validate membership, insert canonical message, bulk ciphertexts, and a durable notification outbox row. Return the committed canonical result for an identical retry; reject different payload reuse.
3. Clients persist the prepared encrypted envelope and key before transmission. Retrying must reuse that envelope; do not advance a ratchet again merely to retry an HTTP request.
4. A worker publishes outbox events with bounded parallelism/retries. Consumers deduplicate by canonical message/event ID. Push is a wake hint, not proof of delivery.
5. Support older clients during an explicit version migration; do not advertise exactly-once transport. The target is at-least-once delivery with idempotent effects.

**Done when:** crash before commit leaves nothing; crash after commit/before reply returns the same message on retry; Redis outage does not corrupt acceptance; duplicate retries produce one bubble; invalid ciphertext rows cannot leave orphan metadata. Load-test a 1,000-member/2-device group without per-device SQL round trips.

## M02 — Acknowledge only after durable client persistence

**Priority:** P0 · **Evidence:** Confirmed · **Dependencies:** M01, S01

**Location:** `backend/api/src/routes/messages.ts:453`, `:492`; `backend/api/src/routes/receipts.ts:68`.

Fetching pending ciphertext sets `delivered_at` before the response reaches the device. If the connection breaks, the next pending fetch omits it. History fetch also marks delivery, and legacy read status clears a shared pending bit for everyone.

**Fix:** make fetch non-destructive. Add an idempotent acknowledgement scoped to device/message, sent only after ciphertext or decrypted content and required session state are durably stored. Persist incoming envelopes before advancing decryption state when atomic storage across stores is unavailable; retain retry/quarantine state for decrypt failures. Track legacy delivery per recipient. Distinguish server-accepted, client-stored, and user-read status. Set retention rules for acknowledged and unacknowledged data explicitly.

**Done when:** cut the socket mid-response, kill the app before/after persistence, fail a disk write, and replay a batch. The message eventually appears once, is never prematurely acknowledged, and unread messages for other devices remain pending.

## M03 — Bound and authorize reconnect backlogs

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** S02, M02

**Location:** `backend/api/src/routes/messages.ts:480`, `:495`, `:512`, `:524`.

Pending fetch has no page/byte limit. Per-device selection checks device ownership but not current revocation, membership, or blocking. Blocking filters wake notifications yet does not exclude stored fanout from this read path. Both branches can load and sort an entire backlog in application memory.

**Fix:** apply the agreed recipient/block/removal policy at read time; enforce active devices. Use stable keyset pagination by `(created_at, id)` with row and total-byte caps. Return a continuation cursor and fetch additional pages under bounded concurrency. Specify whether pre-removal history remains readable; implement that policy consistently rather than guessing from one endpoint. Preserve unread backlog across interrupted pagination.

**Done when:** a large synthetic offline backlog drains with bounded memory, no duplicate/omitted boundary messages, no delivery to revoked devices, and blocking semantics match the UI and push behavior.

## M04 — Stabilize history pagination and measure receipt aggregation

**Priority:** P2 · **Evidence:** Confirmed cursor limitation; performance unmeasured · **Dependencies:** S01/S02

**Location:** `backend/api/src/routes/messages.ts:399`, `:429`, `:447`, `:449`.

History uses timestamp-only `before` and ordering. Equal timestamps at a page boundary can skip rows. Receipt counts and roster subqueries are computed during history retrieval, which needs query-plan evidence at group scale.

**Fix:** add `(created_at,id)` ordering/cursors and appropriate composite indexes after `EXPLAIN (ANALYZE, BUFFERS)` on representative fixtures. Select the bounded message page before expensive receipt aggregation where equivalent. Decide sent-time versus current roster semantics for group read status, then test it. Validate finite positive limits and cursor structure.

**Done when:** several hundred identical timestamps paginate without gaps; group membership changes produce documented receipt status; query plans and p95 results meet the acceptance budget. Do not add indexes solely because a column occurs in SQL.

**Migration/rollback:** use additive columns/tables and dual-compatible responses; keep ciphertext and acknowledgement state intact across a rollback. A repair procedure must preserve canonical IDs and must never require deleting all message history.
