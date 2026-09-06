# 05 — Realtime, calls, and games

Baseline: `a2e24e5` · 2026-09-06 · R02 completed locally; R01/R03-R06 TODO. The issue register is the status authority.

## R01 — Use the conference grant format in the actual relay

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** Q01

**Location:** `backend/websocket/src/index.ts:91` destructures only `{a,b}`; `backend/api/src/callConference.ts:139`, `:179` writes/validates participant array `p`; `routes/calls.ts:900` publishes that grant.

The API supports multi-party grants, but the websocket authorization function accepts only the original pair. New participants cannot exchange relayed conference frames with other allowed participants through this check.

**Fix:** move the pure versioned grant decoder/pair predicate into a shared package used by both services. Support legacy pairs and validated v2 participants; reject malformed/version-incompatible grants and self/outsider combinations according to the existing helper contract. Recheck the live grant for each authorized frame.

**Done when:** exercise the real websocket with A/B/C grants: A↔B, A↔C, B↔C allowed; D denied; a departed member denied after grant refresh; legacy 1:1 remains functional. Existing helper tests alone are insufficient.

## R02 — Authorize and bound typing, reset, and location frames

**Priority:** P0 · **Evidence:** Confirmed · **Dependencies:** S03

**Location:** `backend/websocket/src/index.ts:407`, `:428`, `:452`, `:500`, `:807`.

Typing and session-reset trust client recipient lists without membership checks. Location relays trust share IDs/recipient lists without checking active share ownership/targets. Session reset and typing have no general per-user frame limit. Location's per-share limiter can be bypassed with new share IDs; `loc_stop` is not rate-limited and can delete buffered share entries.

**Fix:** derive allowed recipients from server-issued, expiring conversation/share grants or an authoritative lookup. Validate sender ownership, active membership, blocking, and share expiry/revocation. Apply aggregate user/device connection and frame/byte budgets before Redis work; retain appropriate type-specific limits. Cap/deduplicate recipients and bound/expire limiter maps. Do not log coordinates, ciphertext, or key material.

**Done when:** an outsider cannot generate typing/reset/stop events for another conversation/share; random share IDs and many sockets cannot bypass budgets; legitimate live updates and call/game traffic still work at measured rates.

## R03 — Authenticate before registering sockets; handle slow consumers

**Priority:** P1 · **Evidence:** Confirmed sequence and resource gap · **Dependencies:** S03, R02

**Location:** `backend/websocket/src/index.ts:329`, `:337`, `:353`, `:357`, `:368`, `:306`, `:394`.

Account revocation is checked asynchronously after the socket is admitted and before pending buffers are flushed without awaiting that verdict. Sends do not check `bufferedAmount`; no server ping/pong termination or active connection expiry policy exists. URL tokens also need access-log redaction.

**Fix:** finish validated claims/session/revocation checks before adding the socket, subscribing/flushing, or accepting frames; fail predictably when the authority cannot be consulted. Enforce token expiry for long-lived connections. Add heartbeat deadlines and a centralized bounded send function: coalesce disposable typing/location hints, disconnect slow consumers, and rely on M02 replay for durable messages. Redact URL credentials at the proxy and service; migrate to a supported authenticated handshake/token exchange when compatible.

**Done when:** revoked connects receive no buffered data; expired/stale connections close; throttled consumers have bounded memory; reconnect resumes durable messages without loss. Preserve the existing 256 KiB inbound payload cap.

## R04 — Make presence correct across relay instances

**Priority:** P2 · **Evidence:** Confirmed multi-instance risk · **Dependencies:** R03

**Location:** `backend/websocket/src/index.ts:291`, `:363`, `:819`.

Presence is one user key, but the close handler deletes it based only on the current process's socket set. Closing the last socket on one instance can mark a user offline while another instance still has a socket. Every instance also pattern-subscribes to every user channel.

**Fix:** represent live device/connection presence with expiring leases and derive user presence across instances. Avoid relying on decrement-only counters that leak after process death. Consider subscribing only to locally active user channels after benchmarking; maintain correct refcounts and reconnect resubscription.

**Done when:** two instances and multiple devices remain online until all leases expire; process kill converges correctly; hot-user reconnect churn does not leak subscriptions or flap status.

## R05 — Serialize conference admission under the participant cap

**Priority:** P1 · **Evidence:** Static concurrency risk · **Dependencies:** Q01

**Location:** `backend/api/src/routes/calls.ts:1001`, `:1028`.

The count is inside `INSERT … SELECT`, but two independent transactions can still observe the same roster snapshot and both insert different users. A single SQL statement does not serialize a cross-row capacity invariant under ordinary Read Committed isolation.

**Fix:** lock the parent call row in a transaction, then validate lifecycle, seed/join originals, count active/invited slots, and insert/update the invite. Use the same serialization discipline in every roster-changing endpoint. Publish refreshed grants after commit with retry/reconciliation. Keep joined users joined and preserve the rule that a shared call grants no messaging rights.

**Done when:** synchronize two independent DB connections adding the eighth/ninth users to seven slots; exactly one new slot is admitted. Race admission against leave/end/reinvite and assert bounded roster and correct grant. See PostgreSQL isolation reference in part 18.

## R06 — Establish authoritative game ownership before horizontal scaling

**Priority:** P2 · **Evidence:** Confirmed architecture limitation; multi-instance failure untested · **Dependencies:** Q01

**Location:** `backend/games/src/index.ts:312`, `:371`, `:437`, `:443`, `:902`, `:928`; `backend/games/src/matches.ts:64`.

Each service subscribes to the shared input channel and owns in-memory engines/timers. Per-match enqueue is process-local, and the lease shown is specific to Ludo input handling. Continuous Snake tick loops and other transitions are not a general distributed single-writer system. Starting another identical worker is not a safe scaling strategy.

**Fix:** first document/enforce a singleton while measuring load. Then implement partitioned ownership or renewable leases with fencing tokens covering input, tick, join/leave, deadline, and finalization paths. Bound input queues and drop/coalesce stale continuous steering; retain turn-command IDs. Separate authoritative simulation rate from rendering/interpolation and network broadcast rate. Define what state is recovered after a worker dies and how tournament results are finalized once.

**Done when:** a two-worker chaos test produces one monotonic authoritative sequence/outcome, no double tournament advancement, and controlled failover. Keep secret game state out of per-player projections. Do not lower Snake's current 20 Hz solely to satisfy a stale registry test.
