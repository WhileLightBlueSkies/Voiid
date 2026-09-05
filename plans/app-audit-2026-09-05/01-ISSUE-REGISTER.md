# 01 — Issue register

Baseline: `a2e24e5` · 50 actionable findings/capability gaps · 4 DONE (Q01, S01, S02, S03), 1 IMPLEMENTED_UNVERIFIED (Q02), 45 TODO.

Each ID belongs to exactly one implementation part. Read its dependency and acceptance sections before editing. Priority includes source-confirmed defects, runtime risks, and requested capability gaps; see the evidence column and task text.

| ID | Priority | Issue / required improvement | Evidence | Part | Status |
|---|---|---|---|---|---|
| A01 | P0 | Exclude current private stores from Android backup/transfer | Confirmed rules gap | [06](06-ANDROID-DURABILITY.md) | TODO |
| A02 | P0 | Stop automatically deleting shared encryption keys | Confirmed failure path | [06](06-ANDROID-DURABILITY.md) | TODO |
| C01 | P0 | Resume failed payment webhook processing | Confirmed | [11](11-PAYMENTS-MEDIA-WORKERS.md) | TODO |
| I03 | P0 | Retain dirty state when local persistence fails | Confirmed failure path | [07](07-IOS-AND-STORAGE.md) | TODO |
| M01 | P0 | Make message acceptance atomic and retry-safe | Confirmed | [03](03-MESSAGE-RELIABILITY.md) | TODO |
| M02 | P0 | Acknowledge only after durable client persistence | Confirmed | [03](03-MESSAGE-RELIABILITY.md) | TODO |
| R02 | P0 | Authorize and bound typing, reset, and location frames | Confirmed | [05](05-REALTIME-CALLS-GAMES.md) | TODO |
| S01 | P0 | Authorize receipt reads and writes | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | DONE |
| S02 | P0 | Validate sender and recipient devices on all message paths | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | DONE |
| S03 | P0 | Make revocation persistent and device-bound | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | DONE |
| S04 | P0 | Replace the false recovery lockout security boundary | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | TODO |
| A03 | P1 | Support java.time on API 24/25 | Confirmed configuration gap | [06](06-ANDROID-DURABILITY.md) | TODO |
| A04 | P1 | Remove destructive Room upgrade fallback | Confirmed policy risk | [06](06-ANDROID-DURABILITY.md) | TODO |
| C02 | P1 | Make worker health reflect returned failures and staleness | Confirmed | [11](11-PAYMENTS-MEDIA-WORKERS.md) | TODO |
| C04 | P1 | Keep a durable record of story objects still requiring deletion | Confirmed dependency risk | [11](11-PAYMENTS-MEDIA-WORKERS.md) | TODO |
| E01 | P1 | Reconcile crypto assurances with current code and executable gates | Confirmed assurance gap; exploitability unverified | [12](12-CRYPTO-ASSURANCE.md) | TODO |
| G01 | P1 | Build a shared material contract and capability-based Android renderer | Requested capability gap | [08](08-LIQUID-GLASS.md) | TODO |
| I01 | P1 | Move chat persistence off the main actor and page history | Confirmed synchronous work; frame impact unmeasured | [07](07-IOS-AND-STORAGE.md) | TODO |
| M03 | P1 | Bound and authorize reconnect backlogs | Confirmed | [03](03-MESSAGE-RELIABILITY.md) | TODO |
| P01 | P1 | Stop unrelated routes sharing the host-thread throttle | Confirmed | [04](04-API-PERFORMANCE.md) | TODO |
| P03 | P1 | Handle every Express 4 async rejection and input error | Confirmed | [04](04-API-PERFORMANCE.md) | TODO |
| Q01 | P1 | Repair the test baseline without hiding regressions | Observed failures | [13](13-RELEASE-AND-OPERATIONS.md) | DONE |
| Q02 | P1 | Add quality gates before deployment | Confirmed gap | [13](13-RELEASE-AND-OPERATIONS.md) | IMPLEMENTED_UNVERIFIED |
| Q03 | P1 | Separate native development and release service configuration | Confirmed configuration gap | [13](13-RELEASE-AND-OPERATIONS.md) | TODO |
| Q04 | P1 | Deploy verified artifacts with readiness, draining and rollback | Confirmed gap | [13](13-RELEASE-AND-OPERATIONS.md) | TODO |
| R01 | P1 | Use the conference grant format in the actual relay | Confirmed | [05](05-REALTIME-CALLS-GAMES.md) | TODO |
| R03 | P1 | Authenticate before registering sockets; handle slow consumers | Confirmed sequence and resource gap | [05](05-REALTIME-CALLS-GAMES.md) | TODO |
| R05 | P1 | Serialize conference admission under the participant cap | Static concurrency risk | [05](05-REALTIME-CALLS-GAMES.md) | TODO |
| S05 | P1 | Verify database TLS identity | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | TODO |
| S06 | P1 | Make device linking claims atomic | Confirmed race risk | [02](02-SECURITY-AND-RECOVERY.md) | TODO |
| U01 | P1 | Await Android sheet dismissal before removing it | Confirmed | [09](09-MOTION-ACCESSIBILITY.md) | TODO |
| U02 | P1 | Correct sheet initial detents and entrance position | Confirmed | [09](09-MOTION-ACCESSIBILITY.md) | TODO |
| U03 | P1 | Restore system Back in custom dialogs | Confirmed | [09](09-MOTION-ACCESSIBILITY.md) | TODO |
| U04 | P1 | Finish the photo viewer's gesture lifecycle | Confirmed | [09](09-MOTION-ACCESSIBILITY.md) | TODO |
| W01 | P1 | Respect Cancel when resolving a report | Confirmed | [10](10-WEB-ADMIN.md) | TODO |
| W02 | P1 | Prevent stale admin list responses overwriting new filters | Confirmed race risk | [10](10-WEB-ADMIN.md) | TODO |
| W03 | P1 | Remove closed mobile navigation from the focus order | Confirmed markup/style gap | [10](10-WEB-ADMIN.md) | TODO |
| A05 | P2 | Cancel network work when its coroutine is cancelled | Confirmed cancellation gap | [06](06-ANDROID-DURABILITY.md) | TODO |
| C03 | P2 | Hold durable cleanup claims beyond the selection transaction | Confirmed multi-worker risk | [11](11-PAYMENTS-MEDIA-WORKERS.md) | TODO |
| G02 | P2 | Reconcile design tokens before generating more variants | Confirmed drift | [08](08-LIQUID-GLASS.md) | TODO |
| I02 | P2 | Bound avatar memory and avoid synchronous disk misses in UI | Confirmed | [07](07-IOS-AND-STORAGE.md) | TODO |
| M04 | P2 | Stabilize history pagination and measure receipt aggregation | Confirmed cursor limitation; performance unmeasured | [03](03-MESSAGE-RELIABILITY.md) | TODO |
| P02 | P2 | Make limiter windows atomic and rejection work cheap | Confirmed implementation risk | [04](04-API-PERFORMANCE.md) | TODO |
| P04 | P2 | Bound pool, cache, and request latency before scaling | Configuration gap; latency unmeasured | [04](04-API-PERFORMANCE.md) | TODO |
| Q05 | P2 | Serialize migrations and detect edited history | Confirmed gap | [13](13-RELEASE-AND-OPERATIONS.md) | TODO |
| Q06 | P2 | Optimize Android release builds with measured safeguards | Confirmed build gap; performance unmeasured | [13](13-RELEASE-AND-OPERATIONS.md) | TODO |
| R04 | P2 | Make presence correct across relay instances | Confirmed multi-instance risk | [05](05-REALTIME-CALLS-GAMES.md) | TODO |
| R06 | P2 | Establish authoritative game ownership before horizontal scaling | Confirmed architecture limitation; multi-instance failure untested | [05](05-REALTIME-CALLS-GAMES.md) | TODO |
| U05 | P2 | Remove stale iOS tab timers and honor reduced motion | Confirmed timer/policy gap | [09](09-MOTION-ACCESSIBILITY.md) | TODO |
| U06 | P2 | Make native typography scale and materials stay legible | Confirmed fixed-size tokens; screen impact requires device audit | [09](09-MOTION-ACCESSIBILITY.md) | TODO |

## Completion evidence template

Append one record per issue; update its status above only when the record supports it.

```text
Issue ID:
Status:
Source/fix commit:
Changed files:
Failure reproduced:
Implementation summary:
Tests and artifacts:
Device/staging checks:
Remaining limitations:
Rollback/migration notes:
Reviewer/date:
```

---

## Completion records

```text
Issue ID:            Q01
Status:              DONE
Source/fix commit:   a90e089
Changed files:       backend/api/test/callConference.test.ts
                     backend/games/src/engine/registry.test.ts
                     backend/games/package.json
                     tools/run-suites.mjs (new)
                     docs/GAMES.md
Failure reproduced:  Yes, both cited sites, before any edit.
                     - `npm test` exit 1.
                     - backend/api: 196 tests, 4 failing, all in test/callConference.test.ts
                       (lines 634/666/734/762), each a 409 participant-cap error where a 200
                       was expected.
                     - backend/games: registry.test.ts FAIL "snake is continuous (tickHz set,
                       10-15 Hz)"; the `&&` chain then stopped, so the five later suites never
                       ran and their status was unknown from the run output.

Implementation summary:
  1. Conference fake DB (the 4 API failures). test/callConference.test.ts returned `rows([])`
     from the `insert into call_participants (... invited_by ...)` handler, while production
     (src/routes/calls.ts:1029-1051) enforces the participant cap inside the INSERT's own
     WHERE and signals refusal by returning no row from `returning user_id`. The route reads
     an empty result as "room was full at write time" and answers 409 — so under the fake
     EVERY invite looked like a full room. The handler now models the real statement's three
     parts: the re-invite exemption (an existing non-left row is admitted regardless of the
     cap), the cap test against live seats using the cap passed as $4, and `returning
     user_id` on success. Production code was NOT changed; the defect was entirely in the
     fake's model of the query.
  2. Snake tick rate (the games failure). Verified the 20Hz value is intended and benchmarked,
     not drift: engine/snake/index.ts:70-83 documents the derivation (at 20Hz the residual
     interpolation error ~9 units is smaller than the 22-unit kill radius; measured 46.9 KB/s
     over six seeds), and docs/GAMES.md:81 already allows 20-30Hz for fast physics games. The
     stale artifact was the assertion's 10-15 band and the GAMES.md:80 sketch, so both were
     updated. The test still asserts the CONTRACT (tickHz present, within a sane continuous
     band) rather than pinning the tuning value, which is what its own comment intends.
  3. Suppressed reporting. backend/games' test script was an `&&` chain, so one early failure
     prevented five independent suites from running at all. Added tools/run-suites.mjs, which
     runs every suite, prints each one's output, names the failures, and exits non-zero if any
     failed. It resolves tsx from node_modules/.bin (a bare spawn does not inherit npm's PATH)
     and checks spawn error before exit status, since a spawn error leaves status null and
     would otherwise read as a pass.

Tests and artifacts:
  - `npm test` at repo root: exit 0. API 197 tests / 197 pass / 0 fail; games 6/6 suites;
    Ludo 45 pass; queue 4 pass; `node tools/check-ludo-assets.js` OK.
  - New regression test, backend/api/test/callConference.test.ts, "the cap refuses the seat
    past the last one, and only that seat": fills the room to MAX_CALL_PARTICIPANTS asserting
    each seat is admitted, asserts the next invite is 409 AND writes no roster row, asserts a
    re-invite into the full room still succeeds without adding a seat, and asserts a seat
    freed by a leave is reusable. This covers the cap path in both directions, which the suite
    previously could not: while the fake refused everything, any cap assertion would have
    passed vacuously.
  - Anti-vacuity check: reverting the fake to `rows([])` makes the new test fail (28 pass /
    5 fail), confirming it is load-bearing.
  - Runner check: injecting a real failure into registry.test.ts yields exit 1, "FAILED
    src/engine/registry.test.ts (exit 1)", and "5/6 suites passed" — the failure is reported
    and the five downstream suites still run.
  - Typechecks, all exit 0: backend/api, backend/websocket, backend/games, backend/workers,
    packages/common-utils, via
    `node node_modules/typescript/bin/tsc --noEmit --incremental false -p <project>`.
  - Environment: node v20+ per engines field, macOS darwin 25.6.0, workspace-installed tsx.

Device/staging checks: none required for this task.

Remaining limitations:
  - Web/admin typecheck is still exit 2 from missing React/Next dependencies in this checkout.
    That is a local dependency blocker, not source breakage, and is Q02's scope.
  - The conference cap is still verified only against the in-memory fake. The fake now matches
    the production statement's semantics, but a fake cannot prove Postgres evaluates the
    count and the write in one snapshot. The real concurrency guarantee remains UNVERIFIED and
    is R05's isolated-database race test; Q01 does not close it.
  - No assertion was weakened to obtain green: the conference tests were unchanged apart from
    the added cap test, and the snake band was widened only to the range the benchmark and
    GAMES.md already justify.

Rollback/migration notes: test/tooling/doc only; no production code, schema, or wire format
  touched. Revert the five files to restore prior behaviour. No migration.

Reviewer/date: implemented 2026-09-05; awaiting review.
```

```text
Issue ID:            Q02
Status:              IMPLEMENTED_UNVERIFIED
Source/fix commit:   f0e116a
Changed files:       .github/workflows/ci.yml (new)
                     .github/workflows/nightly.yml (new)
                     .github/workflows/deploy-dev.yml
                     .github/workflows/deploy-main.yml
                     infrastructure/deployment/deploy-dev.sh
                     tools/android-lint-ratchet.mjs (new)
                     tools/android-lint-baseline.json (new)
                     apps/admin-web/package.json
                     apps/ios/Voiid/Voiid/Main/ChatDetailView.swift
                     packages/e2e-core/tests/regress_fallback_restore.rs
                     packages/e2e-core/tests/pin_brute_force.rs
Failure reproduced:  Yes. deploy-dev.yml:25 and deploy-main.yml:33 opened an SSH session to
                     the box with no test, typecheck, or native check anywhere in the path —
                     a commit breaking authorization deployed as fast as one fixing it. The
                     deploy script also reset to origin/$BRANCH, so the deployed commit was
                     the branch tip at SSH time, not any verified commit.

Implementation summary:
  1. ci.yml — six jobs on every push/PR: node (typecheck all 5 backend/shared projects + web
     + admin, `npm test`, web/admin builds), rust (cargo test/clippy/fmt on the encryption
     core), advisories (cargo audit + npm audit high+), migrations (replay all 63 migrations
     against a disposable Postgres 16 service, twice, to prove idempotence), android (unit
     tests, lint, debug build), ios (unsigned simulator build). Toolchains pinned (node
     20.18.1, rust 1.96.0); `npm ci` not `npm install`, so the lockfile is the input.
  2. Deploy gating. Both deploy workflows now have a `verify` job that CALLS ci.yml
     (workflow_call) and a `deploy` job with `needs: verify`. The checks are re-run against
     the deploying SHA rather than looked up, because "did CI pass on this branch?" can be
     answered by a run against a different commit.
  3. Exact-artifact deploy. Workflows pass VOIID_DEPLOY_SHA=${{ github.sha }}; deploy-dev.sh
     checks out that exact commit after verifying it is an ancestor of the branch, and
     refuses otherwise. Hand-run deploys with no SHA keep the previous branch-tip behaviour.
  4. nightly.yml — the expensive work on a 02:00 UTC schedule: crypto soak tests (release,
     --ignored; these had NEVER run in CI), daily advisory re-check, unsigned Android release
     compile. Nothing here blocks a deploy.
  5. Android lint ratchet. lintDebug currently reports 116 errors, so gating on zero would
     make the job red forever and train people to ignore it. tools/android-lint-ratchet.mjs
     fails the build only when the count GROWS, and asks for the baseline to be lowered when
     it drops. 36 of the 116 are java.time NewApi errors — that is A03's API 24/25 crash risk,
     which lint has been reporting to nobody.
  6. Fixed what the new gates found (see below).

Tests and artifacts:
  - Locally verified, all exit 0: `npm test`; typecheck of backend/api, backend/websocket,
    backend/games, backend/workers, packages/common-utils, @voiid/web, @voiid/admin-web;
    `npm run build` for web and admin; `npm ci` against the committed lockfile.
  - Rust: `cargo test --locked` 100 passed / 0 failed / 4 ignored; `cargo clippy --locked
    --all-targets -- -D warnings` clean; `cargo fmt --check` clean. Soak suite verified with
    `cargo test --locked --release -- --ignored`: 4 passed.
  - Android: `./gradlew testDebugUnitTest` BUILD SUCCESSFUL. Ratchet verified on all four
    paths — at baseline (exit 0), count up (exit 1, names the regression), count down (exit 0
    + asks to lower), missing report (exit 2, so lint not running never reads as zero errors).
  - iOS: `xcodebuild build -scheme Voiid -destination 'generic/platform=iOS Simulator'`
    BUILD SUCCEEDED, exit 0, after the fix below.
  - ACCEPTANCE CHECK (Q02's stated criterion — a deliberate failing authorization test must
    block deployment): disabling the canReachForCall guard in routes/calls.ts made `npm test`
    exit 1 with 3 authorization failures. Since `deploy` needs `verify`, that blocks the
    deploy. Guard restored.
  - SHA-pinning logic tested against a purpose-built git repo: pinned SHA is deployed even
    when the branch tip has moved past it; no pin falls back to the tip; a SHA that is not an
    ancestor is refused before the working tree is touched.

Defects found BY these gates and fixed here:
  - iOS did not compile at all on main. ChatDetailView.swift:2595 "ambiguous use of operator
    '-'": `.opacity(1 - dismissProgress * 0.85)` mixes a CGFloat with Double literals. The
    file was unmodified and committed in 7102665 — it reached main precisely because no CI
    built it. Fixed with an explicit Double() conversion; dismissProgress is already clamped
    to 0...1 so values and appearance are unchanged.
  - packages/e2e-core clippy `bool_assert_comparison`: assert_ne!(x, true) rewritten as
    assert!(!x) preserving the invariant and its message. Two rustfmt diffs formatted.
  - apps/admin-web had no `typecheck` script (apps/web did); added `tsc --noEmit`.
  - CI initially used `cargo test --all-features`, which fails by design: `pq-1to1-activate`
    is behind a compile_error! because that 1:1 PQ handshake combiner is a bespoke
    construction no cryptographer has reviewed (src/pqxdh.rs, SPEC_NOTES.md). Removed — CI
    must not switch on the exact feature the crate refuses to ship.

Device/staging checks: none run. No deployment was performed and no workflow has executed on
  GitHub Actions.

Remaining limitations — WHY THIS IS NOT `DONE`:
  - No job in ci.yml or nightly.yml has ever executed on a GitHub runner. Every step was
    verified locally by running its command, but runner images differ: the `migrations` job
    (no Docker or Postgres available locally), `cargo audit` and `npm audit` (never run —
    they may fail immediately on an existing advisory), and the Android/iOS jobs on
    ubuntu/macos-15 images are all UNVERIFIED IN CI. Expect a first-run shakeout.
  - The iOS job clones firebase-ios-sdk at tag 12.15.0 because apps/ios/vendor/ is gitignored
    and the project references Firebase as an XCLocalSwiftPackageReference to that path. That
    tag is a second place the Firebase version is written down and will drift; a Firebase bump
    must update ci.yml too. A committed manifest or a submodule would be a better answer.
  - `npm audit --audit-level=high` and `cargo audit --deny warnings` can fail on an advisory
    published upstream with no commit of ours, which makes the gate non-deterministic across
    time. That is intended for a security gate but will need a triage path.
  - The Android lint ratchet accepts 116 existing errors. It stops regressions; it does not
    fix the debt. A03 and Q06 own burning it down.
  - Q02 also asks for accessibility and performance checks in CI. NOT implemented — those
    need the device/measurement work in parts 09 and 16 to define a pass/fail threshold first.
  - Migration replay proves migrations apply to an EMPTY database. Upgrade-from-deployed-schema
    replay is Q05.

Rollback/migration notes: delete ci.yml and nightly.yml and revert the two deploy workflows to
  restore the previous ungated behaviour. deploy-dev.sh is backward compatible — with no
  VOIID_DEPLOY_SHA it behaves exactly as before. No schema, wire format, or runtime code
  changed except the one-line iOS compile fix.

Reviewer/date: implemented 2026-09-05; awaiting review and a first CI run.
```


## S01 — receipt authorization completed (2026-09-05)

- **Status:** DONE for the receipt authorization contract. Device-bound sessions and durable acknowledgement remain S03/M02.
- **Source/fix commit:** `8629003`; continues the supplied uncommitted receipt patch.
- **Files:** API `deviceAuthorization.ts`, `routes/receipts.ts`, legacy pending selection in `routes/messages.ts`; `test/receiptAuthorization.test.ts` and `test/receiptPostgres.test.ts`; Android/iOS `ChatEngine` receipt batching; PostgreSQL CI step.
- **Fix:** verify active owned devices even for signed claims; reject unknown/malformed claims without falling back to NULL. Require active membership and the exact addressed envelope for fanout receipt writes. Sender access to receipt rosters remains supported. Device-less legacy ciphertext remains supported. Lock device/membership rows, validate the whole batch, and bulk-upsert in a transaction using 027's actual partial indexes. Preserve receipt timestamps and read status; publish only committed changes and exclude sender-owned progress. Database failures reach Express error middleware.
- **Pending compatibility:** receipts no longer change the shared `messages.is_pending` flag. Legacy pending fetch excludes only the caller's read receipt for the selected device, so another device/member is not suppressed. This is not the durable-storage ACK required by M02 and does not repair previously cleared flags.
- **Native compatibility:** both E2E managers store the ID returned by `/devices/register` (iOS `register`, Android `register`). Both bootstrap paths register before uploading prekeys. Persisted IDs can be used before bootstrap completes and can be stale after revocation/restoration; those claims correctly fail 403. There is no provable ownership of an unknown row. Do not silently map it to NULL. S03 must supply the explicit session/registration recovery UX. Both clients now split receipt requests into at most 500 IDs.
- **Failure reproduction:** real PostgreSQL tests against the original committed receipt route failed authorization, fanout entitlement, pending isolation, transaction failure, and revocation scenarios. The old async handler also left the test process alive after an injected failure; the comparison run was terminated after 8 seconds and the fixed source restored.
- **Validation:** PostgreSQL 16.15 on a dedicated loopback cluster, synthetic accounts and unique disposable schemas; seven real-router subtests plus parent pass (8/8), including concurrent retries, injected insert failure/rollback, and revocation while waiting on a row lock. The fake-router suite passes 17/17. Full `npm test` with the PostgreSQL test enabled: API 222/222, games 6/6 suites, Ludo asset guard pass. API typecheck passes. Android `:app:compileDebugKotlin` and unsigned iOS simulator build both succeed. No live accounts/database used. PostgreSQL tooling was installed locally; no login/background service was enabled.
- **CI:** the real database suite is wired into the existing disposable migration job. GitHub execution remains unverified under Q02.
- **Limits:** no physical-device network run, production load measurement, or distributed notification ordering proof. Redis failure preserves committed receipts and polling can recover; durable realtime notifications are part of M01. User-only legacy JWTs cannot establish which physical device sent a request when no device claim is provided; S03 remains mandatory. M02 still owns premature fanout fetch acknowledgement and disk durability.
- **Rollback:** no schema migration. Preserve authorization if rolling back; disable the endpoint rather than restoring the hole. Keep the legacy pending filter with removal of the shared pending mutation. Reverting client batching requires preserving compatible server request limits.


## S02 — message device boundaries completed (2026-09-05)

- **Status:** DONE for device/membership authorization. Session binding, idempotency/outbox, durable ACK, pagination, and production performance remain separate open tasks.
- **Source/fix commit:** commit containing this record, parent `8629003`.
- **Files:** `backend/api/src/db.ts`, `routes/messages.ts`, `test/receiptPostgres.test.ts`, CI database-test label, register and security part.
- **Implementation:** reuse S01's active-device resolver for send/history/pending, checking signed claims against the database and preferring them to supplied IDs. Validate every fanout target against active conversation membership and active devices before inserting metadata. Normalize and deduplicate UUIDs. Preserve valid sender-linked targets, device-less legacy sends, and empty self fanout. Share locks hold sender/recipient device and membership authorization through database writes. Message metadata and ciphertext writes now share a transaction. Relay/push work starts only after commit and release of the transaction connection. History cannot fetch/acknowledge another device's envelope. Pending fetch checks membership/revocation and filters blocked senders in both fanout and legacy paths.
- **Regression evidence:** replacing only `messages.ts` with the pre-S02 committed version makes all seven new S02 database scenarios fail (exit 1), while the seven S01 scenarios continue passing. Restoring the fixed route passes all 14 scenarios plus the parent (15/15).
- **Real PostgreSQL checks:** synthetic three-account fixtures; forged sender IDs; outside/revoked/removed target devices; mixed valid/invalid fanout with no writes; token-over-body precedence; normal groups; sender-linked devices; empty Note-to-Self; legacy null-device path; foreign/revoked history/pending claims; blocked/removed pending recipients; recipient removal committed while send waits on its membership lock; injected ciphertext insert failure with no orphan metadata or notifications. Fixtures now replay all 63 repository migrations into a unique schema, rather than using a schema stand-in.
- **Validation:** API typecheck passes. Full repository `npm test` with real database suite enabled passes: API 229/229, games 6/6 suites, Ludo asset guard. Native source was unchanged after the successful S01 Android/iOS builds. No production or real-account tests performed.
- **Remaining limitations:** pending/history still mark fanout delivery before durable client persistence (M02); no stable send idempotency key/outbox (M01), so a publish failure after commit remains an ambiguous send response. User-only credentials are still legacy-compatible (S03). The pending query is still unbounded and locks active membership rows during its transaction; bounded paging and latency budgets remain M03/P04. No production throughput or physical-device messaging measurement claimed.
- **Rollback:** no schema/wire migration. Never restore unchecked device IDs as a rollback; disable affected paths if necessary. Keep transaction boundaries with the authorization locks.

## Q02 — additional local migration evidence (2026-09-05)

The actual migration runner applied all 63 migrations to an empty, dedicated loopback PostgreSQL 16.15 database. A second run reported all 63 already applied and performed no work. The security integration suite also replays the complete migration set into disposable schemas. Q02 remains IMPLEMENTED_UNVERIFIED: these are local results, not GitHub-runner results; advisory gates and GitHub native jobs still need their required evidence. S01's native builds passed locally. The temporary test database server was stopped after validation; no system service was enabled.


## S03 — device-bound sessions completed (2026-09-06)

- **Status:** DONE for persistent, device-bound revocation. The compatibility window is open by
  default and closes only when an operator sets `VOIID_SESSION_CUTOFF`; until then an unbound
  legacy credential still bypasses device binding. That is the migration cost the issue asks for,
  not an unfinished part of it. S04 (recovery lockout) is now unblocked.
- **Source/fix commit:** commit containing this record, parent `fb058cf`.
- **Files:** `database/migrations/057_device_sessions.sql` (new); API `auth.ts`, `security.ts`,
  `routes/auth.ts`, `routes/devices.ts`, `routes/prekeys.ts`, `routes/linking.ts`; websocket
  `src/session.ts` (new), `src/index.ts`, `package.json`; tests
  `backend/api/test/sessionPostgres.test.ts` and `backend/websocket/test/session.test.ts` (both new);
  `.github/workflows/ci.yml`; `.env.example`; iOS `APIClient.swift`, `AuthService.swift`,
  `E2EManager.swift`; Android `ApiClient.kt`, `AuthService.kt`, `E2EManager.kt`.
- **Failure reproduced:** yes, before any edit. Seven new database scenarios failed against the
  committed source: login returned no scope, registration returned no session token, there was no
  `revoked_reason` column, and a legacy token was accepted with the cutoff in the past. The relay
  module did not exist.
- **Implementation:**
  1. `device_sessions` is the durable authority — one row per device sign-in, carried in the JWT as
     `sid`. Authorization is a row lookup a revoke can invalidate, not a signature check nothing can.
     Redis is a 10-second cache in front of it, so cache loss costs a round-trip, never a resurrected
     session.
  2. `POST /auth/firebase` now issues a short-lived **bootstrap** credential (scope `bootstrap`,
     1h). `POST /devices/register` is the only route that spends it, and it returns the device-bound
     session token in the same response, minted in the same transaction as the device row.
  3. `POST /auth/logout` stopped being a no-op: it revokes the session, marks the device
     `user_revoked`, and closes that device's socket.
  4. `devices.revoked_reason` separates 'superseded' from 'user_revoked'. Prekey upload still
     reinstates a superseded device (the raced-upload recovery) but can no longer un-revoke a device
     the user revoked — that was a self-service reactivation of an explicitly signed-out device.
  5. The relay verifies the session at connect against Postgres, awaited **before** the socket joins
     `socketMap`. The previous check was a floating promise, so every connect granted a window of
     live relay access before the close landed. `force_signout` is now device-targeted, so logging
     out of one device no longer signs out a sibling.
  6. Both clients store the token registration returns, revoke server-side on logout using the
     credential captured by value, and no longer discard a bootstrap token on a
     `device_session_required` 401 — which would have destroyed the only credential able to finish
     registration.
- **Regression evidence:** disabling the session check in `requireAuth` fails 12 assertions across
  the API suite; removing the `user_revoked` guard in `ownsDevice` fails precisely the
  DELETE-then-upload scenario; disabling it in the relay fails 5 of its 7 scenarios. Restoring each
  returns the suites to green.
- **Validation:** PostgreSQL 16.15 on a disposable loopback cluster (TCP only, no login service,
  stopped afterwards), every suite replaying all 64 migrations into unique schemas. Full `npm test`
  with both database suites enabled: exit 0, API 238/238, games 6/6 suites, websocket 8/8. Typecheck
  clean for api, websocket, games, workers, common-utils. Migration runner applied all 64 to an empty
  database and reported the second run a no-op. Backfill verified separately on a
  deployed-shaped schema (001–056 + a pre-revoked device): the revoked row becomes 'superseded', the
  active row is untouched. Android `:app:compileDebugKotlin` and an unsigned iOS simulator build both
  exit 0. No Supabase database, live account, or deployment was touched.
- **Behaviour changes to expect:**
  - The relay now needs `DATABASE_URL` and refuses to boot in production without it. Its pool is
    capped at `WS_DB_POOL_MAX` (default 2) and read only at connect, to stay light on Supabase's
    pooler. This gives up the relay's DB-free property deliberately: a cache-only deny-list fails
    OPEN on a flush, which is the exact failure S03 exists to remove.
  - Registering a device now ends the superseded same-platform device's session, so that device is
    signed out and recovers only through a fresh registration. That is the issue's "reinstall
    recovery must use explicit fresh authorization", and it is stricter than the previous silent
    un-revoke.
- **Remaining limitations:**
  - `VOIID_SESSION_CUTOFF` is unset, so the boundary is not yet enforced for unbound credentials.
    Set it at least one `JWT_EXPIRY` after the release carrying the session-aware clients, or the
    hole stays open indefinitely. Nothing enforces that an operator does this.
  - Neither client handles the `force_signout` frame explicitly; a revoked device signs out on its
    next 401 rather than immediately on the socket frame. The socket is closed server-side either way.
  - A legacy unbound credential has no device, so a device-targeted sign-out cannot single it out —
    one more reason the window should be short.
  - Native verification is compile-only. No physical-device run, no production load measurement, and
    no GitHub-runner execution (Q02's caveat is unchanged).
  - The admin web app authenticates through its own `requireAdmin` session and is untouched;
    `apps/web` is the marketing site and holds no credential.
- **Rollback:** revert the code; leave migration 057 in place (additive — a new table and a nullable
  column, both harmless to unused code). Do NOT roll back by restoring the un-revoke in
  `routes/prekeys.ts` or the unbound `requireAuth`; disable the affected routes instead. If the relay
  must go back to being DB-free, revert it together with the API or revoked devices keep their sockets.
