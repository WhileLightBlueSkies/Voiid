# 02 — Security and recovery

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

Execute one issue per change. Test with synthetic accounts and disposable Postgres/Redis. Preserve ciphertext-only private payloads and the existing reachability model. Do not weaken checks for legacy clients; provide a compatible upgrade path.

## S01 — Authorize receipt reads and writes

**Priority:** P0 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `backend/api/src/routes/receipts.ts:31`, `:54`, `:68`, `:91`.

The authenticated caller can supply arbitrary message IDs to receipt insertion and the `is_pending = false` update. Receipt reads also filter only by message ID. There is no conversation-membership or recipient authorization in these handlers, and a supplied device ID is not checked for ownership. This permits receipt forgery, metadata disclosure, and interference with another conversation's pending state; it does not imply plaintext decryption.

**Fix:**
1. Resolve an active device owned by the caller, preferring a bound session claim over request fields.
2. Authorize each message using active conversation membership and the applicable per-device delivery entitlement. Reject an unauthorized batch atomically, without disclosing which foreign IDs exist.
3. Batch the receipt upsert using parameterized SQL. Keep status monotonic and exclude sender-owned receipts from recipient progress.
4. Remove the conversation-wide legacy pending mutation; coordinate per-recipient delivery state with M02.
5. Gate receipt-list reads by the caller's permitted access to that message.

**Done when:** outsider, former member, revoked device, and another user's device cannot read/write receipts; mixed batches have no partial side effects; duplicate/out-of-order receipt retries remain safe. Test the actual router and database, not a copied helper.

## S02 — Validate sender and recipient devices on all message paths

**Priority:** P0 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `backend/api/src/routes/messages.ts:212`, `:251`, `:275`, `:401`, `:442`, `:453`.

Send accepts a body-selected sender device and arbitrary target device IDs. Target ownership lookup checks revocation/blocking but not conversation membership. History joins ciphertext by caller-supplied device ID without the ownership check present in the pending endpoint, then marks that device's rows delivered. A conversation member can therefore fetch another device's opaque ciphertext and affect its queue; a modified sender can route outside the intended roster.

**Fix:** build one active-device resolver; validate sender ownership; resolve permitted target devices from active conversation members, including explicitly supported sender-linked devices. Reject invalid targets before any insert. Apply device ownership/revocation checks consistently to history and pending. Preserve legitimate empty Note-to-Self fanout. Keep authorization and write within a transaction or otherwise serialize membership changes that must take immediate effect.

**Done when:** three-account tests cover arbitrary sender/target IDs, foreign history device IDs, revoked targets, removed members, normal groups, and empty self fanout. No ciphertext or delivery mutation crosses a device boundary.

## S03 — Make revocation persistent and device-bound

**Priority:** P0 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `backend/api/src/auth.ts:95`; `routes/auth.ts:69`, `:72`; `routes/devices.ts:141`; `routes/prekeys.ts:28`, `:103`; `backend/websocket/src/index.ts:337`, `:353`.

Normal login issues a user-only token; logout does not revoke it. API auth verifies account state, not device revocation. Prekey ownership omits `revoked_at`, and upload explicitly executes `set revoked_at = null`. A previously revoked client holding its token can reactivate its device. The websocket also uses account identity without an active-device session check.

**Fix:** introduce explicit session records or an equivalent revocable session version, bind normal sessions to registered devices, and restrict user-only bootstrap credentials to registration. Separate superseded/reinstall recovery from explicit user revocation; prekey upload must not undo the latter. Revoke and disconnect the particular device on logout/revoke, with a durable authority and bounded cache invalidation. Migrate existing clients with a documented cutoff and reauthentication path. Retain existing production default-secret/bypass boot guards.

**Done when:** old JWTs cannot upload keys, send, fetch, or reconnect after device revoke/logout; a different valid linked device continues working; restart/cache loss does not resurrect a revoked session. Reinstall recovery must use explicit fresh authorization.

## S04 — Replace the false recovery lockout security boundary

**Priority:** P0 · **Evidence:** Confirmed · **Dependencies:** S03

**Location:** `backend/api/src/routes/recovery.ts:56`, `:78`, `:91`; `packages/e2e-core/src/recovery.rs:136`, `:169`, `:285`.

GET returns the complete PIN-wrapped secret. Attempts happen locally, while the server trusts the client's `success` boolean to clear lockout. A hostile client can fetch once, guess offline, omit failures, or claim success. The online lockout tests do not establish resistance to offline PIN guessing. A short PIN has limited entropy even with Argon2id.

**Fix:** explicitly document this threat model; remove claims that client-reported attempts enforce a security boundary. Select a reviewed recovery design: a high-entropy recovery secret/phrase, or a professionally reviewed server-assisted protocol that enforces attempts without exposing an offline short-PIN verifier. Do not add plaintext PIN verification or invent a cryptographic combiner. Keep the current phrase recovery usable during a versioned migration. Require stronger authorization before replacing recovery material, and make counters atomic where they remain useful for abuse telemetry.

**Done when:** the threat-model review explains stolen-token and stolen-database cases, false success reports cannot bypass the chosen boundary, old backups still restore through an explicit migration, and a cryptographic reviewer approves any new protocol. Until then this is a release gate, not a task an AI should claim to have cryptographically certified.

## S05 — Verify database TLS identity

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** Deployment CA configuration

**Location:** `backend/api/src/db.ts:12`; `backend/games/src/db.ts:14`; `backend/workers/src/db.ts:17`; `infrastructure/deployment/migrate.mjs:36`.

Remote pools use `rejectUnauthorized: false`; localhost is inferred by substring search over the full URL. Transport encryption is enabled without server certificate verification.

**Fix:** parse the connection URL's hostname; allow plaintext only for explicitly configured local development. Configure trusted CA roots and verified TLS for remote connections consistently across API, games, workers, and migration runner. Validate node-postgres connection-string SSL options so they cannot silently override the intended policy. Keep secrets out of logs.

**Done when:** trusted remote certificates connect; unknown CA, expired certificate, and hostname mismatch fail; a URL merely containing the word localhost does not disable verification. Rollout must first provision the correct CA, then enable enforcement.

## S06 — Make device linking claims atomic

**Priority:** P1 · **Evidence:** Confirmed race risk · **Dependencies:** S03

**Location:** `backend/api/src/routes/linking.ts:47`, `:53`, `:64`, `:77`.

Approval reads pending state, creates a device, then replaces Redis state. Polling reads a token and deletes it separately. Concurrent approvals/polls can both observe the same state; a crash can leave partially completed linking.

**Fix:** model pending → approving → approved → consumed with atomic compare-and-set and durable idempotency. Bind approval to one account/device and prevent another approval from taking ownership. Atomically consume approved tokens with an appropriate Redis transaction/script or durable database transaction. Define recovery for approval failing between DB and Redis steps; do not strand or duplicate a registered device.

**Done when:** concurrent approvals from two accounts yield one owner, concurrent polls yield one credential delivery, replay fails, and crash injection at each transition leaves a recoverable state.

**Rollback boundary for this part:** deploy additive schema and compatible clients first. Never restore an authorization hole as a rollback; disable the affected endpoint/feature if safe rollback is unavailable.
