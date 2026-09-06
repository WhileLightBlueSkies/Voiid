# 01 — Issue register

Baseline: `a2e24e5` · 50 findings · 20 DONE, 15 IMPLEMENTED_UNVERIFIED, 15 TODO. Statuses corrected 2026-09-06; DONE entries not changed this session retain their historical evidence.

Each ID belongs to exactly one implementation part. Read its dependency and acceptance sections before editing. Priority includes source-confirmed defects, runtime risks, and requested capability gaps; see the evidence column and task text.

| ID | Priority | Issue / required improvement | Evidence | Part | Status |
|---|---|---|---|---|---|
| A01 | P0 | Exclude current private stores from Android backup/transfer | Confirmed rules gap | [06](06-ANDROID-DURABILITY.md) | IMPLEMENTED_UNVERIFIED |
| A02 | P0 | Stop automatically deleting shared encryption keys | Confirmed failure path | [06](06-ANDROID-DURABILITY.md) | IMPLEMENTED_UNVERIFIED |
| C01 | P0 | Resume failed payment webhook processing | Confirmed | [11](11-PAYMENTS-MEDIA-WORKERS.md) | DONE |
| I03 | P0 | Retain dirty state when local persistence fails | Confirmed failure path | [07](07-IOS-AND-STORAGE.md) | IMPLEMENTED_UNVERIFIED |
| M01 | P0 | Make message acceptance atomic and retry-safe | Confirmed | [03](03-MESSAGE-RELIABILITY.md) | IMPLEMENTED_UNVERIFIED |
| M02 | P0 | Acknowledge only after durable client persistence | Confirmed | [03](03-MESSAGE-RELIABILITY.md) | DONE |
| R02 | P0 | Authorize and bound typing, reset, and location frames | Confirmed | [05](05-REALTIME-CALLS-GAMES.md) | DONE |
| S01 | P0 | Authorize receipt reads and writes | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | DONE |
| S02 | P0 | Validate sender and recipient devices on all message paths | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | DONE |
| S03 | P0 | Make revocation persistent and device-bound | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | DONE |
| S04 | P0 | Replace the false recovery lockout security boundary | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | TODO |
| A03 | P1 | Support java.time on API 24/25 | Confirmed configuration gap | [06](06-ANDROID-DURABILITY.md) | DONE |
| A04 | P1 | Remove destructive Room upgrade fallback | Confirmed policy risk | [06](06-ANDROID-DURABILITY.md) | DONE |
| C02 | P1 | Make worker health reflect returned failures and staleness | Confirmed | [11](11-PAYMENTS-MEDIA-WORKERS.md) | IMPLEMENTED_UNVERIFIED |
| C04 | P1 | Keep a durable record of story objects still requiring deletion | Confirmed dependency risk | [11](11-PAYMENTS-MEDIA-WORKERS.md) | IMPLEMENTED_UNVERIFIED |
| E01 | P1 | Reconcile crypto assurances with current code and executable gates | Confirmed assurance gap; exploitability unverified | [12](12-CRYPTO-ASSURANCE.md) | TODO |
| G01 | P1 | Build a shared material contract and capability-based Android renderer | Requested capability gap | [08](08-LIQUID-GLASS.md) | TODO |
| I01 | P1 | Move chat persistence off the main actor and page history | Confirmed synchronous work; frame impact unmeasured | [07](07-IOS-AND-STORAGE.md) | TODO |
| M03 | P1 | Bound and authorize reconnect backlogs | Confirmed | [03](03-MESSAGE-RELIABILITY.md) | DONE |
| P01 | P1 | Stop unrelated routes sharing the host-thread throttle | Confirmed | [04](04-API-PERFORMANCE.md) | DONE |
| P03 | P1 | Handle every Express 4 async rejection and input error | Confirmed | [04](04-API-PERFORMANCE.md) | DONE |
| Q01 | P1 | Repair the test baseline without hiding regressions | Observed failures | [13](13-RELEASE-AND-OPERATIONS.md) | DONE |
| Q02 | P1 | Add quality gates before deployment | Confirmed gap | [13](13-RELEASE-AND-OPERATIONS.md) | IMPLEMENTED_UNVERIFIED |
| Q03 | P1 | Separate native development and release service configuration | Confirmed configuration gap | [13](13-RELEASE-AND-OPERATIONS.md) | TODO |
| Q04 | P1 | Deploy verified artifacts with readiness, draining and rollback | Confirmed gap | [13](13-RELEASE-AND-OPERATIONS.md) | TODO |
| R01 | P1 | Use the conference grant format in the actual relay | Confirmed | [05](05-REALTIME-CALLS-GAMES.md) | IMPLEMENTED_UNVERIFIED |
| R03 | P1 | Authenticate before registering sockets; handle slow consumers | Confirmed sequence and resource gap | [05](05-REALTIME-CALLS-GAMES.md) | IMPLEMENTED_UNVERIFIED |
| R05 | P1 | Serialize conference admission under the participant cap | Static concurrency risk | [05](05-REALTIME-CALLS-GAMES.md) | DONE |
| S05 | P1 | Verify database TLS identity | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | DONE |
| S06 | P1 | Make device linking claims atomic | Confirmed race risk | [02](02-SECURITY-AND-RECOVERY.md) | DONE |
| U01 | P1 | Await Android sheet dismissal before removing it | Confirmed | [09](09-MOTION-ACCESSIBILITY.md) | IMPLEMENTED_UNVERIFIED |
| U02 | P1 | Correct sheet initial detents and entrance position | Confirmed | [09](09-MOTION-ACCESSIBILITY.md) | IMPLEMENTED_UNVERIFIED |
| U03 | P1 | Restore system Back in custom dialogs | Confirmed | [09](09-MOTION-ACCESSIBILITY.md) | IMPLEMENTED_UNVERIFIED |
| U04 | P1 | Finish the photo viewer's gesture lifecycle | Confirmed | [09](09-MOTION-ACCESSIBILITY.md) | TODO |
| W01 | P1 | Respect Cancel when resolving a report | Confirmed | [10](10-WEB-ADMIN.md) | DONE |
| W02 | P1 | Prevent stale admin list responses overwriting new filters | Confirmed race risk | [10](10-WEB-ADMIN.md) | DONE |
| W03 | P1 | Remove closed mobile navigation from the focus order | Confirmed markup/style gap | [10](10-WEB-ADMIN.md) | DONE |
| A05 | P2 | Cancel network work when its coroutine is cancelled | Confirmed cancellation gap | [06](06-ANDROID-DURABILITY.md) | DONE |
| C03 | P2 | Hold durable cleanup claims beyond the selection transaction | Confirmed multi-worker risk | [11](11-PAYMENTS-MEDIA-WORKERS.md) | IMPLEMENTED_UNVERIFIED |
| G02 | P2 | Reconcile design tokens before generating more variants | Confirmed drift | [08](08-LIQUID-GLASS.md) | TODO |
| I02 | P2 | Bound avatar memory and avoid synchronous disk misses in UI | Confirmed | [07](07-IOS-AND-STORAGE.md) | TODO |
| M04 | P2 | Stabilize history pagination and measure receipt aggregation | Confirmed cursor limitation; performance unmeasured | [03](03-MESSAGE-RELIABILITY.md) | TODO |
| P02 | P2 | Make limiter windows atomic and rejection work cheap | Confirmed implementation risk | [04](04-API-PERFORMANCE.md) | DONE |
| P04 | P2 | Bound pool, cache, and request latency before scaling | Configuration gap; latency unmeasured | [04](04-API-PERFORMANCE.md) | TODO |
| Q05 | P2 | Serialize migrations and detect edited history | Confirmed gap | [13](13-RELEASE-AND-OPERATIONS.md) | IMPLEMENTED_UNVERIFIED |
| Q06 | P2 | Optimize Android release builds with measured safeguards | Confirmed build gap; performance unmeasured | [13](13-RELEASE-AND-OPERATIONS.md) | TODO |
| R04 | P2 | Make presence correct across relay instances | Confirmed multi-instance risk | [05](05-REALTIME-CALLS-GAMES.md) | IMPLEMENTED_UNVERIFIED |
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
- **Source/fix commit:** `a99cc2f`, parent `fb058cf`.
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


## C01 — payment webhook inbox completed (2026-09-06)

- **Status:** DONE for delivery recovery, concurrency, unmatched reconciliation and refund
  ordering. No recovery sweep worker ships with it — recovery relies on provider retries, which
  is what the issue's acceptance asks for; a sweep belongs with C02/C03 and the index it needs
  is in place.
- **Source/fix commit:** `e568dfc`, parent `6c2ab92`.
- **Files:** `database/migrations/058_payment_webhook_inbox.sql` (new);
  `backend/api/src/payments/inbox.ts` (new); `backend/api/src/routes/payments.ts`,
  `backend/api/src/routes/events.ts`; `backend/api/test/paymentInboxPostgres.test.ts` (new);
  `.github/workflows/ci.yml`.
- **Failure reproduced:** yes, before any edit. Four of eight new scenarios failed against the
  committed source: a delivery that died mid-settlement was answered `duplicate: true` on retry
  and the order stayed pending forever; concurrent deliveries left no usable ledger state; an
  early webhook was marked processed and lost; a refund arriving before its payment did nothing
  and the later payment then minted live tickets for returned money. The other four scenarios
  passed and were kept as regression guards.
- **Implementation:**
  1. `payment_webhook_events` becomes an inbox: `status` (received/processing/processed/failed/
     unmatched), `attempts`, `lease_until`, `last_error`, plus the normalised verdict
     (`provider_ref`, `outcome`, `amount_minor`, `currency`, `outcome_reason`) so a held
     delivery can be replayed later without re-running provider-specific parsing.
  2. The effect and the record of the effect now commit in ONE transaction (`applyDelivery`),
     with the order row locked `for update`. That is the whole fix: a failure leaves the
     delivery `failed` and therefore re-claimable, instead of leaving a committed claim that
     made every retry a no-op.
  3. Claims carry a lease. A concurrent delivery gets 409 (come back) rather than 200, because
     a 2xx would tell the provider never to send it again while the holder might still fail.
  4. An event naming an unknown order reference is held as `unmatched`, not processed.
     `reconcileUnmatched` replays held deliveries in arrival order the moment the matching order
     is committed — closing the window `routes/events.ts` opens by creating the checkout at the
     provider before inserting the order row. It never throws, so a held delivery cannot fail an
     order that was just created.
  5. **Refund ordering policy, explicit:** a refund is terminal whenever it lands. 032's state
     machine allowed only `paid -> refunded`; `pending -> refunded` is now legal too. This does
     not weaken what that trigger protects — `refunded` stays terminal and a late `paid` still
     cannot move an order out of it — it adds one forward edge. `failed` and `cancelled` are
     untouched.
- **Regression evidence:** restoring the old ordering (mark processed, then settle) fails
  precisely the mid-settlement recovery scenario; restoring `refund only from paid` fails
  precisely the refund-ordering scenario. Both return to green when reverted.
- **Validation:** PostgreSQL 16.15 on a disposable loopback cluster, replaying all 65 migrations
  into unique schemas. Full `npm test` with all three database suites enabled: exit 0, API
  247/247, games 6/6 suites, websocket 8/8. Typecheck clean across api, websocket, games,
  workers, common-utils. Migration runner applied all 65 to an empty database and reported the
  second run a no-op. Backfill verified on a deployed-shaped schema carrying a finished delivery
  and an abandoned one: the finished row stays `processed`, the abandoned one becomes `failed`
  and therefore retryable — which is the previously-lost payment becoming recoverable. No
  Supabase database, live account, or real provider account was touched.
- **Remaining limitations:**
  - **Not exercised against a real provider sandbox.** The end-to-end scenarios run against a
    fake provider; `razorpayWebhook.test.ts` covers real signature verification separately. The
    issue asks for provider test mode, and that has NOT been done — it needs provider test
    credentials this checkout does not have.
  - No sweep. A delivery left `failed`, or `processing` with an expired lease, is recovered by
    the provider's own retries. If a provider exhausts its retry schedule first, the row waits
    for a human. `idx_payment_webhook_retryable` exists for the worker that should claim them.
  - An `unmatched` delivery whose order is never created stays `unmatched` indefinitely. That is
    deliberate — it is the operator-visible record of money that arrived for nothing we know
    about — but nothing alerts on it yet.
  - The 409 on a leased delivery assumes the provider retries non-2xx. Every major processor
    does, but a provider that treats 409 as terminal would need that response changed to 5xx.
  - Whether any of this path is live in production depends on `VOIID_PAYMENT_PROVIDER`; with it
    unset, paid events are refused at creation and no webhook is accepted.
- **Rollback:** revert the code; leave migration 058 in place (additive columns, indexes, and a
  transition function that only widens what is legal). Do NOT roll back by restoring the
  claim-then-settle ordering. If 058's transition function must be reverted, revert the refund
  handler with it, or a refund arriving before its payment will raise instead of being lost —
  louder, but still not applied.


## R02 — relay frame authorization completed (2026-09-06)

- **Status:** DONE for recipient authorization, aggregate budgets and bounded limiter maps.
  Dependent on S03, which supplied the relay's database handle — without it none of this was
  expressible. Connection/frame budgets are enforced per INSTANCE, not per cluster; see limits.
- **Source/fix commit:** `2c27dd9`, parent `88f5449`.
- **Files:** `backend/websocket/src/recipients.ts` (new), `src/budget.ts` (new), `src/index.ts`;
  `backend/websocket/test/recipients.test.ts` and `test/budget.test.ts` (both new);
  `.github/workflows/ci.yml`; `.env.example`.
- **Failure reproduced:** yes. Against the committed source, `conversationRecipients` and
  `shareRecipients` did not exist — the relay published to whatever `recipient_ids` named. The
  new suites fail on the pre-fix behaviour by construction, and both anti-vacuity reverts below
  confirm they bite.
- **Implementation:**
  1. **Recipients are derived, not supplied.** `typing`, `session_reset`, `loc_update` and
     `loc_stop` now resolve their audience from the database: active conversation membership
     (with the SENDER's membership checked in the same statement), or a location share's live
     targets resolved for its OWNER only. A client's `recipient_ids` is still honoured, but only
     to NARROW that audience — it can address fewer people than it is entitled to, never more.
     Existing clients send peer user ids, so the intersection is unchanged and no client edit
     was needed.
  2. Blocking moved into the same query, in both directions, replacing the `block:a:b` Redis
     mirror on these paths — membership and blocking are now answered by one authority.
  3. **An aggregate socket budget**, in frames AND bytes, checked before the JSON parse and
     before any Redis call. `typing`, `session_reset`, `loc_stop` and `heartbeat` previously had
     no limit at all, so a client could spend indefinitely across them while staying under every
     per-type ceiling.
  4. **Bounded limiter maps.** The location and game limiters were plain Maps keyed by
     client-supplied ids, never capped or pruned: a client got a fresh allowance per invented key
     AND grew the map for the life of the socket. `BoundedRateMap` prunes only EXPIRED buckets
     and refuses new keys when full — never evicting a live bucket, because that would hand the
     evicted key a fresh allowance and reopen the bypass in a new shape.
  5. **Per-user connection cap**, closing the OLDEST socket rather than refusing the newest, so a
     reconnecting client always gets in.
  6. `loc_stop` for an unowned or invented share now resolves to an empty audience, so the
     buffered-fix deletion it used to perform against other users' buffers does nothing.
- **Regression evidence:** removing the sender-membership clause fails 4 of 7 recipient
  scenarios; removing the share-ownership clause fails 2. Both return to green when restored.
- **Validation:** PostgreSQL 16.15 on a disposable loopback cluster, replaying all 65 migrations
  into a unique schema. Full `npm test` with all four database suites enabled: exit 0, API
  247/247, games 6/6 suites, websocket 27/27. Typecheck clean across all five projects. No
  Supabase database or live account touched.
- **Logging:** audited. The only two log sites on these paths carry ids and limits — no
  coordinates, no ciphertext, no key material.
- **Remaining limitations:**
  - **The audience cache is 10 seconds.** For up to that long after leaving a conversation or
    blocking someone, a typing indicator or session-reset hint may still arrive. Neither carries
    content, and every path that moves a message reads the database uncached. Resolving typing
    against Postgres per keystroke was not an acceptable alternative.
  - **Budgets are per relay instance.** A client that opens sockets against several instances
    multiplies its allowance; the connection cap has the same limit. A cluster-wide budget needs
    shared counters and belongs with R04's multi-instance work.
  - `callRate` is still a plain Map, deliberately — it is keyed by the socket's own user id, so
    it holds exactly one entry and cannot grow.
  - The relay's frame handler is now `async`, so two location fixes for one share can in
    principle be published out of order. Each frame carries its own `ts` and the buffer is
    latest-only; the pre-existing typing path was already async for its block check.
  - No load measurement. The budgets are sized by argument from the existing per-type limits,
    not from production traffic — R02 asks that legitimate traffic "still work at measured
    rates" and the measurement has NOT been done.
- **Rollback:** revert the code. No schema change. Do NOT roll back by restoring
  client-supplied `recipient_ids` — disable the affected frame types instead.


## M01 — retry-safe message acceptance completed (2026-09-06)

- **Status:** DONE for idempotent acceptance, atomicity and durable notification. Point 3 of the
  fix — clients persisting the prepared ENVELOPE so a retry does not re-encrypt — is NOT done;
  see limitations. M02 (acknowledge only after durable client persistence) remains open and is
  the other half of delivery.
- **Source/fix commit:** `deacbd8`, parent `78270df`.
- **Files:** `database/migrations/059_message_idempotency_outbox.sql` (new); API
  `src/messageIdempotency.ts` and `src/messageOutbox.ts` (new), `src/routes/messages.ts`;
  workers `src/outbox.ts` (new), `src/index.ts`, `package.json`; tests
  `backend/api/test/sendIdempotencyPostgres.test.ts` and `backend/workers/test/outbox.test.ts`
  (both new); iOS `APIClient.swift`, `ChatEngine.swift`, `CommunityJoinSheet.swift`; Android
  `ApiClient.kt`, `ChatEngine.kt`; `.github/workflows/ci.yml`; `.env.example`.
- **Failure reproduced:** yes. All 10 scenarios failed against the committed source — there was
  no `client_message_id`, no fingerprint, no `message_outbox`, and a retry produced a second
  message.
- **Implementation:**
  1. `client_message_id` + `payload_fingerprint` on `messages`, with a NULL-FREE partial unique
     index on (sender, coalesced device, client id). The coalesce matters: `sender_device_id` is
     nullable, and a NULL in a unique key makes it never match — the 027 bug with a worse blast
     radius, since it would turn every retry back into a new message while looking correct.
  2. An identical retry is answered with the original message (`duplicate: true`). The fast path
     is a probe before the work; the unique index is what makes two SIMULTANEOUS retries safe,
     with the loser reading the winner outside its aborted transaction.
  3. Same key, DIFFERENT bytes returns 409 — and carries the message the key already produced.
     This case is not hypothetical: a client re-encrypts when it retries (Olm advances its
     ratchet), so a legitimate retry has different bytes. Without the id in the conflict body a
     client would be stuck retrying forever and showing a failure for a delivered message.
  4. `message_outbox` rows are written in the SAME transaction as the message, so a committed
     message always carries its unsent announcements. The route still publishes inline right
     after commit (the latency path) and settles them; anything left `pending` is a debt.
  5. A sweep in @voiid/workers pays those debts, on its OWN 5-second clock rather than the
     reapers' 5-minute tick — an outbox row is a notification somebody is already waiting on.
     Lease + `for update skip locked`, bounded batch and concurrency, and a retry ceiling after
     which a row is left `failed` and visible rather than retried forever.
  6. Both clients now send the local message's own id as `client_message_id` and reconcile the
     conflict via a dedicated `alreadySent` / `AlreadySent` error rather than string-matching.
- **Regression evidence:** dropping the client id fails 3 of the acceptance scenarios; publishing
  directly instead of through the outbox fails the 2 durability scenarios; making the sweep stop
  releasing failed rows fails its 2 retry scenarios. All return to green when restored.
- **Validation:** PostgreSQL 16.15 on a disposable loopback cluster, replaying all 66 migrations
  into unique schemas. Full `npm test` with all six database suites enabled: exit 0, API 257/257,
  games 6/6 suites, websocket 27/27, workers 8/8. Typecheck clean across all five projects.
  Migration runner applied all 66 to an empty database and reported the second run a no-op.
  Android `:app:compileDebugKotlin` and an unsigned iOS simulator build both exit 0. No Supabase
  database, live account or real device was touched.
- **Fan-out cost:** asserted rather than assumed. Statements are counted on the send's OWN
  connection and compared between a 5-device and a 40-device send: identical, and the ciphertext
  bundle is a single insert. That is the "no per-device SQL round trips" half of M01's load
  requirement.
- **Remaining limitations:**
  - **Clients still re-encrypt on retry** (fix point 3). The envelope is not persisted, so every
    retry advances the Olm ratchet and produces different bytes — which is why the 409 path
    exists and is exercised. It is wasteful rather than incorrect, but a client that retries
    many times burns skipped-key window on the recipient. Persisting the prepared envelope needs
    a durable outgoing-envelope store on both platforms and is its own piece of work.
  - **No load test.** M01 asks for a 1,000-member/2-device group. The per-device round trip is
    disproven by statement counting, but no throughput or latency measurement was taken at that
    size, and none is claimed.
  - The inline publish and the sweep can both deliver the same wake, and a publish that succeeds
    while its "mark published" fails will be re-published. That is at-least-once by design;
    clients dedupe by message id. Exactly-once is NOT provided and must not be advertised.
  - Only the text-send path carries a client id so far. The media, reaction, reply, forward,
    delete-for-everyone and location send paths still send none, so they keep the old
    duplicate-on-retry behaviour. The server supports them the moment they pass one.
  - No client-side migration gate: an older client simply sends no id and behaves as before.
- **Rollback:** revert the code; leave migration 059 in place (additive columns, a partial index
  and a new table). Do NOT roll back by dropping the client id while keeping the fingerprint
  check. If the outbox is reverted, revert the worker with it or it will sweep a table nothing
  writes to.


## M02 — delivery acknowledgement completed (2026-09-06)

- **Status:** DONE for non-destructive fetch, device-scoped acknowledgement, per-recipient legacy
  delivery and declared retention. Fix point "persist incoming envelopes before advancing
  decryption state" is NOT implemented as an atomic guarantee; see limitations.
- **Source/fix commit:** `9f02a7d`, parent `f15086d`.
- **Files:** `database/migrations/060_delivery_acknowledgement.sql` (new);
  `backend/api/src/routes/messages.ts`; `backend/api/test/deliveryAckPostgres.test.ts` (new) and
  `test/receiptPostgres.test.ts` (updated to the new contract); iOS `ChatEngine.swift`; Android
  `ChatEngine.kt`; `.github/workflows/ci.yml`.
- **Failure reproduced:** yes. All 10 scenarios failed against the committed source — there was no
  `message_deliveries` table, no ack route, and both fetch paths stamped `delivered_at` as they read.
- **Implementation:**
  1. `GET /messages/pending` was an `update ... returning`: serving the ciphertext marked it
     delivered and committed before the response left the process. It is now a plain select.
  2. `GET /messages/conversation` marked every row it served, so SCROLLING acknowledged messages
     the device had not stored. It marks nothing.
  3. `POST /messages/ack` is the only writer of delivery. Scoped to the authenticated device,
     idempotent (`delivered_at is null`, `on conflict do nothing`), whole-batch validation so a
     malformed list cannot be partly applied, and a body naming a different device than the token
     is refused rather than quietly resolved — a client told "acknowledged" for a device it did
     not name would stop retrying.
  4. `message_deliveries` gives legacy single-ciphertext messages a per-recipient dimension they
     never had. Their delivery state was `messages.is_pending` — ONE bit shared by every
     recipient, so one device clearing it emptied every other device's queue. The unique index
     coalesces the nullable device id rather than including a NULL, which would never match.
  5. Both clients acknowledge AFTER their durable write (`persist()`), never before, and
     acknowledge tombstoned messages as well as decrypted ones: a client never retries a failed
     Olm decrypt, so leaving those unacknowledged would make the server hold them forever.
  6. Retention for `message_ciphertexts` and `message_deliveries` declared in
     `data_retention_policy`, with the argument for why a time sweep would be wrong written down.
- **Regression evidence:** restoring the destructive read fails 3 scenarios; removing the device
  scoping from the legacy anti-join fails precisely the per-recipient one. Both return to green.
- **Contract change to an existing test:** `receiptPostgres.test.ts`'s "one reader cannot suppress
  another device or recipient legacy queue" asserted that a READ RECEIPT drops a message from that
  device's queue — the interim behaviour S01 recorded and explicitly deferred to M02. It now
  asserts the stronger fact: a read receipt does NOT settle delivery, and only the ack does. The
  property the test protects is unchanged and is still asserted for both the sibling device and
  the other recipient. No assertion was weakened to obtain green.
- **Validation:** PostgreSQL 16.15 on a disposable loopback cluster, replaying all 67 migrations
  into unique schemas. Full `npm test` with all seven database suites enabled: exit 0, API
  267/267, games 6/6 suites, websocket 27/27, workers 8/8. Typecheck clean across all five
  projects. Migration runner applied all 67 to an empty database and reported the second run a
  no-op. Android `:app:compileDebugKotlin` and an unsigned iOS simulator build both exit 0. No
  Supabase database, live account or real device was touched.
- **Remaining limitations:**
  - **The clients pull history, not `/messages/pending`.** Removing the history-fetch marking is
    therefore what makes the ack load-bearing, and an OLD client that never acks would keep every
    message pending forever and see it on every sync. There is no version gate: this pairs a
    server change with a client change and they must ship together.
  - **Storage and decryption are not atomic.** M02 asks for the envelope to be persisted before
    the decryption state advances where atomic storage is unavailable. The clients still decrypt
    and then persist, so a crash in that window loses the Olm ratchet step for a message that is
    still queued server-side — it will be re-fetched and will fail to decrypt, landing as a
    tombstone. That is a bounded, visible failure rather than silent loss, but it is not the
    guarantee the issue asks for; it needs an inbound-envelope store on both platforms.
  - **The acceptance scenarios were exercised against the API, not against a device.** Cutting a
    real socket mid-response, killing the app between fetch and persist, and failing a real disk
    write are all simulated at the boundary the server can see. No physical-device run was done.
  - `is_pending` is still a shared bit, now unused for per-device queueing but still read as the
    sender's "never picked up" flag. Retiring it belongs with M04.
  - Retention is DECLARED, not enforced: both policies say `account_lifetime` / erasure worker,
    and no time sweep exists or should.
- **Rollback:** revert the code; leave migration 060 in place (a new table and two policy rows).
  Do NOT roll back the server alone once session-aware clients are shipping — a client that acks
  against a server that also marks on fetch is harmless, but a server that marks on fetch with
  clients that rely on the queue is the original data-loss bug.


## A01 — Android backup policy (2026-09-06)

- **Status:** IMPLEMENTED_UNVERIFIED, and the gap is exactly the one A01 warns about. The rules
  are correct and enforced by a test against the SHIPPED files; NO backup archive was inspected
  and no restore was performed on a device. A01's own acceptance says not to infer safety from
  the presence of backup XML, and this record does not.
- **Source/fix commit:** `537dcf5`, parent `86dda65`.
- **Files:** `res/xml/backup_rules.xml`, `res/xml/data_extraction_rules.xml`,
  `app/build.gradle.kts`; `app/src/test/java/com/voiid/app/BackupRulesTest.kt` (new).
- **Failure reproduced:** yes. The shipped rules named 3 encrypted preference files plus one
  JSON file. The inventory below found 20 stores, of which 16 were being copied — including
  `voiid_recovery`, which holds the base64 master secret for the encrypted account backup, and
  `voiid_e2e`, which holds the Olm identity. The Room database (`voiid.db`), the current message
  shards (`files/messages/`), decrypted media (`files/media/`) and `voiid_messages.json.tmp`
  were all uncovered too.
- **Implementation:** both rule files switched from denylist to ALLOWLIST. Only four cosmetic
  preference files may leave the device (theme, chat layout, game settings, game audio);
  everything else — every EncryptedSharedPreferences store, the Room database, every file
  domain — is excluded by construction. `<device-transfer>` is allowlisted separately, which it
  was not before: it moves the same bytes to the same place, just over a cable.
- **The durable part.** The bug was never a wrong rule, it was a store added without anyone
  thinking about the rules — invisible in the diff that adds the store. `BackupRulesTest` scans
  the actual sources for every `SecurePrefs.open` / `getSharedPreferences` name and fails the
  build when one is not classified as portable or private, and asserts no private store and no
  non-sharedpref domain is ever allowlisted. `app/build.gradle.kts` declares `res/xml` as a test
  input, because without it Gradle kept the task UP-TO-DATE when a rule changed and the guard
  would have rotted silently — found by changing a rule and watching the test not run.
- **Validation:** 64 Android unit tests pass; `assembleDebug` succeeds; lint holds at its 116
  baseline. Anti-vacuity: allowlisting `voiid_recovery` fails two assertions by name, and adding
  an unclassified store to the source fails the guard.
- **Remaining limitations — WHY THIS IS NOT `DONE`:**
  - **No archive was inspected and no device restore was performed.** `adb backup` is
    non-functional for apps on current Android, and device transfer needs two physical handsets.
    A01 asks for synthetic content in a real archive and a clean sign-in on a fresh device; that
    evidence does not exist and nothing here substitutes for it.
  - Allowlist semantics are taken from Android's documented behaviour (an `<include>` makes the
    rule set exclusive) and are NOT confirmed observationally on any API level.
  - The four portable files are asserted to be cosmetic by reading their writers. If any of them
    later carries something personal, this test will not notice — it checks the classification,
    not the contents.
  - `allowBackup` remains `true` so the cosmetic transfer still works. Whether the product wants
    even that is a decision nobody has made.

## A02 — SecurePrefs no longer destroys what it cannot read (2026-09-06)

- **Status:** DONE. No code path deletes the shared master key or a preference file any more.
- **Source/fix commit:** `537dcf5`, parent `86dda65`.
- **Files:** `net/SecurePrefs.kt` (rewritten), `net/SecurePrefsPolicy.kt` (new);
  `app/src/test/java/com/voiid/app/SecurePrefsRecoveryTest.kt` (new).
- **Failure reproduced:** yes, by reading the shipped handler. ANY exception deleted the
  preference file; if the rebuild then failed it deleted `MasterKey.DEFAULT_MASTER_KEY_ALIAS`,
  the Keystore key shared by every encrypted store in the app. So one unreadable file could
  destroy the E2E identity, the session token, the message history and the account-backup master
  secret together, on launch. Its own comment explained why deleting that key causes a reset
  cascade across sibling stores, and then did it as a fallback.
- **Implementation:** failures are classified (device locked / key invalidated / corrupted /
  unknown) and answered from a pure, unit-tested decision table. Locked is retried and then
  REPORTED. Invalidated is reported — regenerating an identity is the user's decision. Corrupted
  moves that ONE file aside into a quarantine directory (a rename, never a delete: unreadable is
  not worthless, and it is the evidence). Unknown is reported, because the old code guessed and
  its guess was to delete everything. `SecurePrefsUnavailableException` is the typed state A02
  asks for, and `discardQuarantined` is the only destructive call, reachable only from an
  explicit user-initiated reset.
- **Regression evidence:** reintroducing the master-key deletion fails the guard test by name.
  The guard is a source scan for `deleteEntry` and `deleteSharedPreferences` in SecurePrefs.kt,
  which is the cheapest way to keep a future edit from quietly restoring the behaviour.
- **Validation:** 64 Android unit tests pass, `:app:compileDebugKotlin` and `assembleDebug`
  succeed, lint holds at baseline. No device run.
- **Behaviour change to expect:** `SecurePrefs.open` can now THROW where it previously wiped and
  returned. Callers propagate it. That is deliberate — an app that says "not right now" is
  recoverable and one that has deleted the master secret is not — and the exposure is small in
  practice: the master key is not auth-bound (no `setUserAuthenticationRequired`) and no
  component is `directBootAware`, so the locked-device path is close to unreachable. It is still
  a real change in failure mode and should be watched after release.
- **Remaining limitations:**
  - **The failure scenarios were exercised against the CLASSIFIER, not against a device.** A
    genuinely locked device, a real disk failure, a real corrupted preference file and a real
    missing-key restore were not produced on hardware. The exception shapes the classifier
    matches on are taken from androidx/Keystore documentation and naming, not from captured
    stack traces, so a vendor that throws something differently worded lands in UNKNOWN — which
    reports rather than destroys, so the failure is safe, but it is not the intended branch.
  - No UI offers the explicit reset yet. `quarantined()` and `discardQuarantined()` exist and
    nothing calls them, so a quarantined store currently stays on disk until the app is
    reinstalled. That is the safe direction, but the recovery journey A02 describes is not
    finished until something surfaces it.
  - Key-alias isolation per store (A02's "isolate future key aliases where justified") is NOT
    done. All stores still share one master key; the fix here is that nothing deletes it.


## I03 — persistence that reports whether it persisted (2026-09-06)

- **Status:** IMPLEMENTED_UNVERIFIED. The Android half is unit-tested against real files; the
  iOS half is the same design verified only by compilation, because the project has NO test
  target. The database-wrapper half of the fix is partial — see limitations. With M02 in place
  this was actively producing false acknowledgements, so it is fixed rather than deferred.
- **Source/fix commit:** `d39a9e9`, parent `553e581`.
- **Files:** Android `net/ShardStore.kt` (new), `net/ChatEngine.kt`,
  `app/src/test/java/com/voiid/app/ShardStoreTest.kt` (new); iOS `Networking/ChatEngine.swift`,
  `Storage/VoiidDatabase.swift`.
- **Failure reproduced:** yes, by reading both shipped paths, and three distinct bugs were found
  rather than the one the issue describes:
  1. `persist()` cleared the dirty set BEFORE writing and `persistShard` swallowed every failure
     into a log line, so a disk-full or permission error meant the conversation was never written
     and never retried — the app carried an in-memory copy that vanished at exit.
  2. The Android atomic write fell back to overwriting the LIVE FILE in place when the rename
     failed, which is the opposite of atomic: an interruption there destroys the good copy it was
     replacing.
  3. **Not in the issue text.** An undecodable shard was skipped on load, so the conversation came
     back EMPTY — and the next persist wrote that emptiness over the file. One unreadable shard
     silently replaced a whole conversation's history, with nothing left to recover from.
- **Implementation:** `persist()` returns whether every claimed shard committed, and dirty
  markers are removed only for those that did. `DirtyConversations` versions each marker, so a
  conversation touched WHILE its write was in flight stays dirty — the bytes that landed are
  already stale. `ShardStore.write` has no fallback: either the rename lands or the previous
  shard is untouched and the failure is returned. An unreadable shard is quarantined (moved
  aside, preserved) instead of skipped. Both clients now withhold the M02 acknowledgement when
  persistence did not commit, which is the link the issue asks for: the device must not tell the
  server it stored something it did not store.
- **Regression evidence:** restoring the truncating fallback fails the replacement test; clearing
  dirty markers at claim time fails three marker tests. Both return to green when restored.
  NOTE: the first version of the fallback test did not bite — a read-only directory makes the
  TEMP write fail, so the fallback never ran. `ShardStore.write` therefore takes an injectable
  rename step, used only by that test, because POSIX rename needs directory permission rather
  than file permission and the failure cannot otherwise be forced.
- **Validation:** 76 Android unit tests pass, `:app:assembleDebug` succeeds, lint holds at its 116
  baseline, unsigned iOS simulator build exits 0. Backend unchanged and still green (API 267/267,
  relay 27/27, workers 8/8, games 6/6).
- **Remaining limitations — WHY THIS IS NOT `DONE`:**
  - **The iOS half has no tests at all.** `Voiid.xcodeproj` contains no test target, so the iOS
    persistence path is verified by compilation and by being the same design as the tested
    Android one. Adding an XCTest target is the honest next step and was not done here.
  - **The acceptance scenarios were not produced.** Disk full, a permission error, an interrupted
    replacement and process death were exercised through injected failures and a read-only
    directory in unit tests — not on a device with a genuinely full disk or a killed process.
  - **The database wrapper is only partly addressed.** iOS `VoiidDatabase.write` still returns
    `T?`, where `nil` means either "failed" or "the block returned nil". A `writeCommitted`
    variant with an unambiguous Bool was added and documented, but the EXISTING call sites were
    not audited or migrated. They are cache updates re-synced from the server, so the exposure is
    a stale screen rather than lost data — but that claim was reasoned about, not verified call
    site by call site.
  - Nothing surfaces quarantined shards to the user, so a corrupted conversation comes back empty
    with its history preserved only on disk. Safe, but the recoverable UI state the issue asks
    for does not exist.
- **Rollback:** revert the code. No schema or wire change. Do NOT roll back the ack gating alone —
  without it a failed write again tells the server the message is stored.


## S05 — database TLS is verified, not merely enabled (2026-09-06)

- **Status:** DONE in code. **The rollout is an operator step and has not been performed** —
  the enforcement this ships is only real once `VOIID_DB_TLS_INSECURE` is absent on the box.
- **Source/fix commit:** `3f5416a`, parent `fd6b4a1`.
- **Files:** `packages/common-utils/src/databaseTls.ts` (new), `src/index.ts`; `backend/api/src/db.ts`,
  `backend/games/src/db.ts`, `backend/workers/src/db.ts`, `infrastructure/deployment/migrate.mjs`;
  `backend/games/package.json`, `backend/workers/package.json`;
  `backend/api/test/databaseTls.test.ts` (new); `.github/workflows/ci.yml`; `.env.example`.
- **Failure reproduced:** yes, by reading all four sites. Each carried the same two lines:
  `rejectUnauthorized: false` for every remote host, and a local exemption decided by
  `url.includes('localhost') || url.includes('127.0.0.1')` over the WHOLE connection string.
  `rejectUnauthorized: false` is not weaker verification, it is none: the traffic is encrypted
  to whoever answers, so anyone positioned between the box and Supabase could present any
  certificate and read or rewrite the entire database. The substring test additionally
  disabled TLS for a remote host when the PASSWORD, the database name, or a hostname such as
  `localhost.attacker.example` contained the word.
- **Implementation:** one shared, tested policy. The hostname is parsed (not searched) and only
  true loopback hosts skip TLS; everything else verifies, with an optional CA from
  `VOIID_DB_CA_CERT` / `VOIID_DB_CA_CERT_PATH`. A connection string that would weaken the policy
  (`sslmode=disable|allow|prefer|no-verify`, `ssl=false`) is REFUSED rather than silently
  honoured, since node-postgres does read those. `VOIID_DB_TLS_INSECURE` must be exactly `1` — a
  stray `false` in a deploy env must not read as consent — and every service prints the policy in
  force at boot, so it is visible without reading the env file.
- **Why one module instead of four copies:** the bug WAS four copies. games and workers now depend
  on `@voiid/common-utils` (no transitive deps, already built first by the deploy script), and
  migrate.mjs requires the same built module. CI's migrations job gained the build step to match.
- **Regression evidence:** restoring the substring check in one db.ts fails the guard by file
  name. The guard scans all four files for `rejectUnauthorized: false`, for the substring test,
  and for use of the shared resolver.
- **Validation:** 9 policy tests including every mis-parse case; full `npm test` exit 0 with all
  seven database suites (API 276/276, games 6/6, relay 27/27, workers 8/8); typecheck clean across
  all five projects; `npm ci` accepts the lockfile; the migration runner replays all 67 migrations
  against loopback and logs `database TLS: off (loopback)`.
- **Remaining limitations:**
  - **Nothing was verified against a real remote database.** The acceptance asks that a trusted
    certificate connects and that unknown-CA, expired and hostname-mismatch cases fail. Those were
    NOT exercised — no connection to Supabase or any TLS server was made, and the correct CA has
    not been provisioned. The policy is proven; its effect against a live server is not.
  - **This will break the deployed box unless step 1 is done first.** Verification is the default,
    so a trust store lacking the database's CA now fails to connect. `.env.example` documents the
    three-step rollout (set `VOIID_DB_TLS_INSECURE=1`, provision the CA, remove the flag). Nothing
    enforces that an operator completes step 3, and until they do, the hole is open — explicitly
    and loudly now, rather than silently.
  - Supabase's pooler and direct connections may need different CA material. Which one this
    deployment uses was not determined.
  - The websocket relay's own pool (added in S03) carried the same unverified form and IS
    migrated here; the guard test covers all five sites. It was found by writing this record,
    which is an argument for writing them.

## P03 — every rejection reaches the handler (2026-09-06)

- **Status:** DONE for rejection handling and error mapping. The request-schema half of the fix
  (bounded arrays, enums, limits per route) is NOT done — see limitations.
- **Source/fix commit:** `bd03787`, parent `d73c04f`.
- **Files:** `backend/api/src/errors.ts` (new), `src/index.ts`, and 12 routers under `src/routes/`;
  `backend/api/test/errorHandling.test.ts` (new).
- **Failure reproduced:** yes. The audit named four bare handlers; a route inventory found **67
  across 12 files**, admin.ts alone holding 33. Express 4 does not catch a rejected promise from
  a route handler, so each of those sent NO response at all: the client waited until it timed
  out, the socket stayed open, and the only trace was a process-level unhandledRejection that
  cannot finish the request it belongs to.
- **Implementation:** every handler wrapped in the existing `asyncHandler`, done by a
  paren-aware transformer rather than a regex (one site still needed a manual fix, found by
  typecheck). The error middleware no longer guesses: it believes an error that carries its own
  status, maps body-parser's `type` values to real codes, and treats everything else as 500.
  Every error response now carries a stable `code` and a `request_id` echoed in `x-request-id`.
- **What the old middleware got wrong, specifically:** it ran `/base64|invalid input/i` over the
  error MESSAGE. A body-too-large arrives from body-parser carrying `status: 413` and was
  answered 500 — telling a client to retry something that can never succeed. And Postgres says
  "invalid input syntax for type uuid" for a bad cast, which is our bug and was being reported to
  the caller as theirs.
- **Regression evidence:** unwrapping a single handler fails the guard by file name. The guard
  scans every router for an async function passed straight to Express, so this cannot come back
  one route at a time.
- **Validation:** 8 error-handling tests; full `npm test` exit 0 (API 284/284, games 6/6, relay
  27/27, workers 8/8); typecheck clean.
- **Remaining limitations:**
  - **No request schemas.** P03 also asks for UUID/enum/bounded-array/positive-limit validation
    per route. Not done — that is per-endpoint work across ~90 routes and is not covered here.
    Routes still validate ad hoc, and several do it well (messages, receipts, ack), but there is
    no shared schema layer.
  - **No timeout policy.** "timeout → defined retryable response" is not implemented; a slow
    upstream still holds the request until the client gives up.
  - The transformer was mechanical. Typecheck and the full suite pass, but the 67 rewrites were
    not each read individually; a handler whose behaviour depended on Express seeing a raw async
    function would not be caught by either.
  - The raw payment-webhook body ordering was preserved (that router mounts before
    `express.json()` and was not touched), but no test asserts the ordering survives a future edit.

## A03 — java.time works on API 24, and a bad date stops looking like a good one (2026-09-06)

- **Status:** DONE for the configuration and the silent-substitution bug. NOT run on an API 24/25
  device or emulator — see limitations.
- **Source/fix commit:** `f18d8f9`, parent `77de85a`.
- **Files:** `apps/android/app/build.gradle.kts`, `gradle/libs.versions.toml`;
  `app/src/main/java/com/voiid/app/util/IsoTime.kt` (new); `net/ChatEngine.kt`,
  `net/LocationShareEngine.kt`, `net/GroupEngine.kt`;
  `app/src/test/java/com/voiid/app/IsoTimeTest.kt` (new); `tools/android-lint-baseline.json`.
- **Failure reproduced:** yes, and it is worse than a crash. Lint reported 26 `java.time` NewApi
  errors against minSdk 24 with no desugaring configured. Every call site was
  `runCatching { Instant.parse(s) }.getOrDefault(System.currentTimeMillis())` — and `runCatching`
  catches Throwable, so on API 24/25 the NoClassDefFoundError was SWALLOWED and every timestamp
  became the current time. Not a crash, not a log line: messages silently out of order, story and
  location expiry silently wrong, on every device running Android 7. The same substitution turned
  a malformed server date into a plausible current one on every API level.
- **Implementation:** core-library desugaring enabled with a pinned `desugar_jdk_libs` in the
  version catalog, which is what makes `java.time` real on API 24. `IsoTime.parseOrNull` returns
  null for anything unreadable and handles the shapes the backend actually sends (ISO-8601 with
  Z or a numeric offset, and Postgres's space-separated `timestamptz` including its `+00`
  whole-hour offset). The three parsers now fall back to **0**, not to now: 0 sorts to 1970 where
  somebody will see it, and for an expiry it means "already expired", which is the safe
  direction. Each logs the unreadable value.
- **A third copy was found by the guard.** The audit named ChatEngine and LocationShareEngine;
  `GroupEngine.kt` had the same line and was only caught because the test scans the whole source
  tree rather than the two files the issue mentions.
- **Regression evidence:** the guard fails on any file that substitutes `System.currentTimeMillis()`
  for an unreadable date, and a separate test fails if desugaring is turned off — that one matters
  because the JVM the unit tests run on HAS java.time, so every parsing test would keep passing on
  a build that crashes on a real API 24 device.
- **Validation:** 84 Android unit tests pass; `assembleDebug` exit 0; lint dropped 116 → 90 errors
  and the ratchet baseline is lowered to lock it in.
- **Remaining limitations:**
  - **Nothing ran on API 24 or 25.** A03 asks for fixtures executed on those levels and again on
    API 36. The unit tests run on the host JVM, which has `java.time` regardless — so they prove
    the parsing rules and prove nothing about desugaring actually working on an old device. The
    config test is a proxy for that, not a substitute. An instrumented test on an API 24 emulator
    is the missing evidence.
  - **The fallback is still a fallback.** 0 is visible rather than plausible, which is the point,
    but a message with an unreadable date still renders at 1970 rather than being surfaced as an
    error to the user.
  - 11 NewApi errors remain and are NOT java.time: `Vibrator`/`VibrationEffect` (API 26/30) and
    `java.lang.ref.Cleaner` (API 33). Those are unguarded-platform-API questions of their own,
    no issue tracks them, and the Cleaner one would throw on anything below API 33. Recorded in
    the lint baseline note so they are not lost.

## M03 — the reconnect backlog drains in pages (2026-09-06)

- **Status:** DONE for bounding, keyset pagination and read-time authorization. No memory or
  latency measurement was taken — see limitations.
- **Source/fix commit:** `4d02fd9`, parent `e255b14`.
- **Files:** `backend/api/src/routes/messages.ts`;
  `backend/api/test/pendingPaginationPostgres.test.ts` (new); `.github/workflows/ci.yml`.
- **Failure reproduced:** yes, and **M02 made it worse rather than revealing it**. Fetching used
  to stamp delivery, so a second fetch returned nothing and the missing page limit rarely
  showed. Once M02 made the fetch non-destructive, every pending message came back on EVERY
  poll until the device acknowledged — so a phone returning after a fortnight asked this process
  to load, sort and serialise its whole backlog in application memory, repeatedly. That
  interaction was introduced by my own earlier change in this sequence.
- **Implementation:** the two branches (fan-out and legacy) became ONE statement with
  `union all`, keyset-paginated by `(created_at, id)` with a `limit` and a continuation cursor,
  replacing two unbounded queries merged and sorted in JS. A row cap (500, default 200) and a
  total-byte cap (~4 MB) both apply, because 500 media envelopes and 500 short texts are not the
  same response. An unusable `limit` or a cursor this endpoint did not issue is a 400 rather
  than a guess.
- **The transaction and row lock are gone,** deliberately. Both existed to hold membership stable
  while this endpoint stamped delivery; since M02 it stamps nothing, so a share lock over every
  conversation the caller belongs to was contention bought for a mutation that no longer happens.
- **Authorization was already correct** from S02/M02 — active device, membership, revocation and
  two-directional blocking — and those four scenarios passed before this change. They are kept in
  the suite as regression cover rather than presented as new work.
- **Regression evidence:** removing the page limit fails three scenarios. Ordering by
  `created_at` alone — without the `id` tie-break — fails four, including a purpose-built case
  where ten messages share a timestamp and the page boundary falls inside them. That second check
  did NOT bite at first: the original fixture used timestamps one second apart, so it never
  exercised the tie-break the cursor exists for. The clustered case was added for it.
- **Validation:** 9 scenarios against real PostgreSQL over a 310-message backlog; full `npm test`
  exit 0 (API 292/292, games 6/6, relay 27/27, workers 8/8); typecheck clean.
- **Remaining limitations:**
  - **No measurement.** M03 asks that a large backlog drain "with bounded memory". The bound is
    now structural — a page is at most 500 rows or ~4 MB — but no memory or latency figure was
    recorded at any backlog size, and 310 messages is not a large backlog.
  - **The pre-removal history policy is still implicit.** The issue asks whether a removed member
    may read history from before their removal, and for that answer to be applied consistently.
    Pending fetch excludes them (`left_at is null`), history does not gate on it at all, and that
    inconsistency is unchanged here — it needs a product decision, not a patch.
  - **No client uses this endpoint yet.** Both apps sync via `/messages/conversation`, so the
    cursor contract is unexercised outside tests, and `/messages/conversation` still has only its
    own `limit`/`before` and no byte cap.
  - `is_pending` remains the legacy branch's selector, so a legacy message is offered to a device
    until that device acknowledges it — correct, but it means the legacy backlog is bounded by
    acknowledgement rather than by the flag.

## W01/W02/W03 — the admin console and the site header (2026-09-06)

- **Status:** W01 and W02 DONE. W03 IMPLEMENTED_UNVERIFIED — its acceptance requires browser
  accessibility inspection and an automated navigation interaction test, and neither exists here.
- **Source/fix commit:** `2803a92`, parent `7b0a5c6`.
- **Files:** `apps/admin-web/lib/latestOnly.ts` (new), `components/useList.ts`,
  `app/reports/page.tsx`, `package.json`, `test/list.test.ts` (new);
  `apps/web/components/SiteHeader.tsx`, `SiteHeader.module.css`.
- **W01 — Cancel resolved the report anyway.** `window.prompt(...)?.trim() ?? ''` collapsed
  Cancel and an empty note into the same empty string, and the caller then posted the
  resolution: an irreversible moderation action taken after the operator declined to take it.
  `null` now means do nothing, `''` means a deliberate empty note, the prompt happens BEFORE any
  state is touched, and a second resolution cannot start while one is in flight.
- **W02 — the debounce cleared a timer, not a request.** A fetch already in flight when the
  filter changed still completed, and finishing last it won: the table showed rows for a filter
  the operator had moved away from, with that query's cursor, so "load more" appended pages of
  the wrong list. Fixed with BOTH an AbortController and a generation check before every state
  write — the abort is not instantaneous and a response can already be queued when the next
  filter arrives. `finally` is guarded too, or an obsolete response clears the spinner while the
  current request is still running. Appends dedupe by id, load-more is serialised, and an abort
  is no longer shown as a failure.
- **W03 — the collapsed menu was invisible, not hidden.** `grid-template-rows: 0fr` plus
  overflow clipping hides it from sight and from nothing else: the links stayed in the focus
  order, so a keyboard user tabbing the header fell into a menu they could not see. The
  checkbox-and-label control also cannot carry `aria-expanded` — a checkbox announces "checked".
  It is a real button now, with `aria-expanded`, Escape-to-close and focus restoration, close on
  route change, and `inert` on the collapsed menu. `inert` is applied ONLY at the mobile
  breakpoint, read from the same media query the stylesheet uses, because at desktop that
  element IS the navigation and marking it inert from stale mobile state would disable the
  header. `isMobile` starts false and is corrected in an effect, so the server does not render
  an inert nav and hydrate a mismatch. The 180ms entrance, its easing token and the
  reduced-motion handling are untouched.
- **Validation:** 10 new tests for the pure ordering rules, wired into the root suite (both web
  apps are workspaces, so `npm test` now covers admin-web). Typecheck clean for both apps; both
  `next build`s exit 0. Full `npm test` exit 0 across every workspace.
- **Remaining limitations:**
  - **Nothing was exercised in a browser.** The tested parts of W02 are the ordering rules
    extracted into `latestOnly.ts`; the hook that uses them, the abort wiring and every part of
    W03 are verified by typecheck and build only. There is no DOM test runner in either app.
  - W03 specifically asks for keyboard traversal, screen-reader announcement, focus preservation
    across resize, and no hydration warnings to be VERIFIED. None of that was done. `inert` is
    also not supported by older browsers; no fallback was added and no browser matrix was checked.
  - W01's acceptance says "test through the actual event handler". The decision `promptNote`
    makes is tested; the handler that calls it is not.
  - The other four console lists (clips, users, events, dpdp) get W02's fix for free through the
    shared hook, but none of their pages was exercised.

## S06 — device linking is atomic and durable (2026-09-06)

- **Status:** DONE. The handshake moved from Redis to Postgres, which the issue explicitly
  permits ("or durable database transaction") and which is what made it testable here.
- **Source/fix commit:** `4eafc6d`, parent `a0cf3ea`.
- **Files:** `database/migrations/061_device_link_requests.sql` (new);
  `backend/api/src/routes/linking.ts` (rewritten);
  `backend/api/test/linkingPostgres.test.ts` (new); `.github/workflows/ci.yml`.
- **Failure reproduced:** yes, by reading the flow. Every transition was read-modify-write over
  three round trips against a cache, and both endpoints are reachable concurrently by design —
  the QR is on a screen, and the approving phone and the waiting browser are different clients.
  Two approvals from different accounts both read "pending" and both registered a device, so one
  account kept a device row nobody would use and which account the browser got came down to
  whichever write landed last. Two polls both read "approved" before either deleted the key, so
  the session credential could be handed out twice. A crash between the device insert and the
  cache write left a registered device and a token stuck on "pending" forever. And a Redis
  restart lost every link in flight.
- **Implementation:** a `device_link_requests` row, `select ... for update`, and one transaction
  that does the device upsert, the session and the state change together. That collapses the
  pending → approving → approved → consumed machine the issue describes into two states: with
  everything in one transaction there IS no half-way to be stuck in, so the intermediate state
  was not implemented rather than being implemented and unused. Poll locks and DELETES in the
  same transaction that reads the credential out, so exactly one caller can collect it. A
  CHECK constraint makes "approved but missing its device or token" unrepresentable.
- **Regression evidence, and a test that had to be rewritten:** the poll check bit immediately.
  The approval-race check did NOT — the first version fired four concurrent requests and hoped
  they would interleave, and it passed against a build with `for update` deleted. It now holds
  the row from a blocker transaction, waits on `pg_stat_activity` until an approval is provably
  blocked, and only then releases; removing the lock now fails it by name. A concurrency test
  that has not been run against the broken code is decoration.
- **Validation:** 9 scenarios against real PostgreSQL; full `npm test` exit 0 (API 302/302,
  games 6/6, relay 27/27, workers 8/8, admin 10/10); typecheck clean; all 68 migrations apply.
- **Remaining limitations:**
  - **`session_token` is a live credential at rest** for the minutes between approval and
    collection. That is not new — it sat in Redis for the same window — but it is now in a
    database with backups, so it is written down in the retention policy rather than implicit.
    The row is deleted on collection and bounded by `expires_at`.
  - **No sweep deletes uncollected rows.** The policy says the retention worker owns them and
    nothing implements it yet, so an abandoned QR leaves a row until someone adds that job.
    `expires_at` makes them unusable, not absent.
  - **No client exercises this.** There is no web companion app in the repo, so the flow is
    verified end to end only by the test.
  - Approval binds to whichever account approves first, which is the intended rule, but there is
    no rate limit on `/linking/request` — an unauthenticated caller can still mint tokens.

## C02/C04 — workers that report what they actually did (2026-09-06)

- **Status:** both DONE. C03 (durable claim ownership) remains TODO and is P2; see limitations.
- **Source/fix commit:** `0a70755`, parent `bb6af0e`.
- **Files:** `backend/workers/src/health.ts` (new), `src/index.ts`, `src/reapStories.ts`;
  `backend/workers/test/reapHealth.test.ts` (new); `.github/workflows/ci.yml`.
- **C02 — failures were returned, and nobody was reading them.** Every job catches its own
  errors and reports counts (`failed`, `abandoned`, `stuck`, `objectsPending`). The supervisor
  recorded `lastError` only when a job THREW, so retention could fail its SQL every pass, or the
  reaper abandon rows every pass, and /health stayed green: the process was up, nothing escaped,
  and the numbers describing the failure sat unread in `lastResult`. There was also no freshness
  gate — a hung job and an idle one looked identical. Health is now derived from the returned
  counts, from last-success age against each job's OWN interval (the outbox runs on a
  five-second clock; measuring it against the reaper's five minutes would hide a stall), and
  from in-flight duration. The service takes its worst job's status, never an average, and
  anything other than ok is a 503.
- **C04 — the reaper deleted the only record of what it had not deleted.** In two paths — R2
  not configured, and a row past `MAX_REAP_ATTEMPTS` — the story row was deleted while the
  object remained in the bucket. The row is the only thing that knows the key, so the file
  became unnameable by anything in the system. The comment justifying it pointed at a bucket
  lifecycle rule the audit could not verify, and an unverified lifecycle rule is a hope rather
  than a mechanism. Both paths now write the key into `erasure_pending_objects` first — the
  table that already exists for "an object still needing deletion", is already drained by the
  erasure pass, and is already reported on /health. A second queue would have meant a second
  drain and a second thing to forget.
- **Regression evidence:** emptying the failure-count list fails four health scenarios; making
  the reaper drop keys again fails three reaper scenarios. Both return to green.
- **Validation:** 15 tests — 11 pure health classifications and 4 against real PostgreSQL rows;
  typecheck clean.
- **Remaining limitations:**
  - **C03 is not done** (P2): `for update skip locked` still selects rows and commits before the
    slow I/O, so two workers can claim the same rows in successive transactions. Deletion is
    idempotent so the effect is duplicate work and inaccurate counts rather than damage, but
    ownership is still undefined and the issue's "do not scale workers until ownership is
    defined" stands.
  - **The lifecycle rule is still unverified.** C04 asks for prefix/retention evidence for the
    bucket policy as a secondary net. No bucket was inspected; the fix removes the DEPENDENCE on
    that rule rather than confirming it.
  - **Nothing was demonstrated against real object storage.** No synthetic object was uploaded,
    failed to delete, and drained. R2 behaviour is simulated by "not configured" in the tests.
  - **Deployment readiness is unchanged.** C02 also asks that deployment treat required-worker
    readiness as required rather than a printed warning; the health endpoint now tells the truth,
    but `deploy-dev.sh` still only prints. That is Q04's territory and is not done here.
  - Thumbnails and renditions are not enumerated — only the story's single `r2_key` is queued.

## P01/P02 follow-up — 6 September 2026

See [API throttle evidence](../../docs/audit-evidence/api-throttles.md) for reproduction, implementation, tests and remaining operational limitations.

## Continuation review — 6 September 2026

The table above supersedes historical completion records below it. A02/M01/C02/C04 have been reclassified as implemented/unverified because their complete acceptance is still outstanding; source fixes were retained. See [continuation evidence](../../docs/audit-evidence/continuation-2026-09-06.md) and the [single current report](../../docs/AUDIT-FINAL-REPORT.md).

## R05 — the conference cap is serialized, and now proven (2026-09-06)

- **Status:** DONE. This closes the guarantee Q01's record explicitly left open.
- **Source/fix commit:** `c17feb8`, parent `1a09ad1`.
- **Files:** `backend/api/src/routes/calls.ts`;
  `backend/api/test/conferenceCapPostgres.test.ts` (new);
  `backend/api/test/callConference.test.ts` (fake updated to the new shape);
  `.github/workflows/ci.yml`.
- **Failure reproduced — this is the point of the issue.** The cap lived inside the INSERT's own
  WHERE, justified in a comment as "Postgres evaluates it against the same snapshot that
  performs the write". That is true and it is not sufficient: under READ COMMITTED the count
  subquery reads the snapshot taken when the STATEMENT began, so two transactions that both
  begin before either commits both see seven, both pass the count, and both insert DIFFERENT
  users. Two connections on a call with one seat left produced a **nine-person roster on an
  eight-person cap**. Q01 predicted exactly this: "a fake cannot prove Postgres evaluates the
  count and the write in one snapshot... the real concurrency guarantee remains UNVERIFIED and
  is R05's isolated-database race test."
- **Implementation:** admission is a transaction that takes `select ... for update` on the
  parent `calls` row, re-checks the lifecycle inside the lock, seeds the original pair on the
  same connection, then counts and inserts. The lock is on `calls` rather than
  `call_participants` because the invariant is about the SET of participants — there is no
  single row to lock for "how many are there", and a gap-free count needs something outside the
  set to serialize on. A re-invite is explicitly exempt: someone already on the roster takes no
  new seat, so re-inviting the eighth person after a dropped connection still works.
- **`admitParticipant` is exported so the test drives production code.** A concurrency test that
  re-implements the statement it is checking proves only that the copy is correct.
- **Regression evidence, and a test that needed rewriting twice.** The first version fired two
  admissions with `Promise.all` and hoped they would interleave — it passed against a build with
  the lock removed, because each admission awaits several statements and Node ran them almost
  sequentially. It now holds the call row from a blocker transaction and waits on
  `pg_stat_activity` until an admission is provably blocked before releasing; removing
  `for update` then fails it by name. This is the second time in this audit a concurrency test
  has been decoration on first writing (S06 was the first), which is worth stating as a pattern
  rather than an anecdote.
- **The fake had to change with it.** `callConference.test.ts` modelled the cap as part of the
  INSERT's WHERE, which is no longer where the decision lives. It now models the write
  unconditionally and answers the lock/count statements separately. Q01's rewrite of that fake
  is not weakened — the refusal it asserts still happens, from the count.
- **Validation:** 6 scenarios against real PostgreSQL (two-way race, six-way race, re-invite
  exemption, freed-seat reuse raced, ordinary admission); 33 fake-DB conference tests still
  pass; full `npm test` exit 0 (API 311/312, games 6/6, relay 28/28, workers 32/32, admin
  10/10); typecheck clean.
- **Remaining limitations:**
  - **Not every roster-changing endpoint takes the lock.** R05 asks for "the same serialization
    discipline in every roster-changing endpoint". Admission does; join and leave still update
    `call_participants` directly without locking the call. Those transitions move an existing
    participant rather than adding a seat, so they cannot breach the cap — but a leave racing an
    admission is not serialized, and the roster the admission counts may be one row stale in the
    permissive direction. Worth closing when join/leave are next touched.
  - **Grant publication is unchanged.** The fix ends at the roster; `refreshCallGrant` still runs
    after the transaction with no retry or reconciliation, so a publish failure leaves a correct
    roster and a stale grant. R05 mentions this and it is not addressed here.
  - No load or latency measurement: the lock serializes admissions to one call, and no figure was
    taken for how that behaves under a busy conference.

## A04 — a forgotten migration can no longer erase local history (2026-09-06)

- **Status:** DONE for the policy: the destructive fallback is gone, schemas are exported and
  committed, and the build fails on a missing migration. The historical-fixture upgrade test
  A04 asks for is NOT written — see limitations.
- **Source/fix commit:** commit containing this record, parent `35934d7`.
- **Files:** `apps/android/app/src/main/java/com/voiid/app/store/VoiidDatabase.kt`,
  `app/build.gradle.kts`, `app/schemas/com.voiid.app.store.VoiidDatabase/4.json` (new, generated
  and committed); `app/src/test/java/com/voiid/app/RoomMigrationPolicyTest.kt` (new).
- **Failure reproduced:** by reading it. `fallbackToDestructiveMigration()` sat alongside three
  explicit migrations, under a comment that already described the danger correctly: it drops and
  recreates EVERY table on any version bump lacking a Migration, including `call_history` and the
  address-book `saved_name`/`phone_e164` columns on `users`, which exist on the device and
  nowhere else. The failure it produces is not a crash — it is an upgrade that SUCCEEDS while the
  user's call history quietly disappears. This is a policy risk rather than a live defect:
  versions 1→4 all have migrations today, and it becomes a defect the first time somebody bumps
  the version and forgets, which is exactly the mistake a destructive fallback exists to hide.
- **Implementation:** the fallback is removed, so a missing migration now throws on open — loud,
  at development time, impossible to ship past. `exportSchema = true` with a
  `room.schemaLocation` KSP argument, and `4.json` committed, so an upgrade path finally has a
  record of what shipped to migrate FROM rather than only the current code's idea of the old
  schema. `RoomMigrationPolicyTest` fails the build if the fallback returns, if export is turned
  off, if any version in 1..current lacks a migration, if the exported schema for the current
  version is missing, or if the irrecoverable columns disappear from it. `schemas/` is declared
  as a test input so Gradle re-runs the guard when a schema changes — the same staleness trap
  that would have silently disabled the backup-rules guard.
- **Regression evidence:** restoring `fallbackToDestructiveMigration()` fails that guard by name;
  bumping the version to 5 without adding `MIGRATION_4_5` fails the migration-coverage guard.
- **Validation:** 92 Android unit tests pass (7 new); `assembleDebug` exit 0; lint holds at its
  90 baseline.
- **Remaining limitations:**
  - **No upgrade was executed against a real historical database.** A04's acceptance asks that
    versions 1/2/3 upgrade to current "without losing conversations, calls, locations, or
    stories", tested from real fixtures. That needs `MigrationTestHelper`, an instrumented test
    and an emulator; none of it exists here. What is proven is that the destructive path is gone
    and that every version is covered — not that each migration is CORRECT.
  - **Only schema 4 is exported.** Versions 1–3 shipped without export, so there is no recorded
    schema to migrate from for those, and the fixtures the acceptance wants cannot be
    reconstructed from this repository. Export helps from here forward only.
  - **A corrupt database file now has no handler.** The fallback was also covering that case.
    Removing it means a genuinely corrupt file throws on open instead of being silently
    recreated. That is the safer failure but it is not a recovery path: the file should be
    quarantined and reported, as SecurePrefs now does for preferences (A02). Not implemented.
  - **Downgrade policy is still unstated.** A04 asks for an explicit supported-or-blocked
    decision; Room's default is to throw, which is a policy by accident rather than by choice.
