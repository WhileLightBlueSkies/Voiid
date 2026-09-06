# 01 — Issue register

Baseline: `a2e24e5` · 50 findings · 21 DONE, 16 IMPLEMENTED_UNVERIFIED, 13 TODO. Statuses corrected 2026-09-06; DONE entries not changed this session retain their historical evidence.

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
| S04 | P0 | Replace the false recovery lockout security boundary | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | TODO (code-level half done; **release gate**, needs cryptographic reviewer) |
| A03 | P1 | Support java.time on API 24/25 | Confirmed configuration gap | [06](06-ANDROID-DURABILITY.md) | DONE |
| A04 | P1 | Remove destructive Room upgrade fallback | Confirmed policy risk | [06](06-ANDROID-DURABILITY.md) | DONE |
| C02 | P1 | Make worker health reflect returned failures and staleness | Confirmed | [11](11-PAYMENTS-MEDIA-WORKERS.md) | IMPLEMENTED_UNVERIFIED |
| C04 | P1 | Keep a durable record of story objects still requiring deletion | Confirmed dependency risk | [11](11-PAYMENTS-MEDIA-WORKERS.md) | IMPLEMENTED_UNVERIFIED |
| E01 | P1 | Reconcile crypto assurances with current code and executable gates | Confirmed assurance gap; exploitability unverified | [12](12-CRYPTO-ASSURANCE.md) | TODO (clauses 1-3 done; 4-5 need external reviewers) |
| G01 | P1 | Build a shared material contract and capability-based Android renderer | Requested capability gap | [08](08-LIQUID-GLASS.md) | TODO |
| I01 | P1 | Move chat persistence off the main actor and page history | Confirmed synchronous work; frame impact unmeasured | [07](07-IOS-AND-STORAGE.md) | TODO (main-actor IO + read path fixed; GRDB migration and device traces outstanding) |
| M03 | P1 | Bound and authorize reconnect backlogs | Confirmed | [03](03-MESSAGE-RELIABILITY.md) | DONE |
| P01 | P1 | Stop unrelated routes sharing the host-thread throttle | Confirmed | [04](04-API-PERFORMANCE.md) | DONE |
| P03 | P1 | Handle every Express 4 async rejection and input error | Confirmed | [04](04-API-PERFORMANCE.md) | DONE |
| Q01 | P1 | Repair the test baseline without hiding regressions | Observed failures | [13](13-RELEASE-AND-OPERATIONS.md) | DONE |
| Q02 | P1 | Add quality gates before deployment | Confirmed gap | [13](13-RELEASE-AND-OPERATIONS.md) | IMPLEMENTED_UNVERIFIED |
| Q03 | P1 | Separate native development and release service configuration | Confirmed configuration gap | [13](13-RELEASE-AND-OPERATIONS.md) | IMPLEMENTED_UNVERIFIED |
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
| I02 | P2 | Bound avatar memory and avoid synchronous disk misses in UI | Confirmed | [07](07-IOS-AND-STORAGE.md) | DONE |
| M04 | P2 | Stabilize history pagination and measure receipt aggregation | Confirmed cursor limitation; performance unmeasured | [03](03-MESSAGE-RELIABILITY.md) | DONE |
| P02 | P2 | Make limiter windows atomic and rejection work cheap | Confirmed implementation risk | [04](04-API-PERFORMANCE.md) | DONE |
| P04 | P2 | Bound pool, cache, and request latency before scaling | Configuration gap; latency unmeasured | [04](04-API-PERFORMANCE.md) | DONE |
| Q05 | P2 | Serialize migrations and detect edited history | Confirmed gap | [13](13-RELEASE-AND-OPERATIONS.md) | IMPLEMENTED_UNVERIFIED |
| Q06 | P2 | Optimize Android release builds with measured safeguards | Confirmed build gap; performance unmeasured | [13](13-RELEASE-AND-OPERATIONS.md) | TODO |
| R04 | P2 | Make presence correct across relay instances | Confirmed multi-instance risk | [05](05-REALTIME-CALLS-GAMES.md) | IMPLEMENTED_UNVERIFIED |
| R06 | P2 | Establish authoritative game ownership before horizontal scaling | Confirmed architecture limitation; multi-instance failure untested | [05](05-REALTIME-CALLS-GAMES.md) | TODO |
| U05 | P2 | Remove stale iOS tab timers and honor reduced motion | Confirmed timer/policy gap | [09](09-MOTION-ACCESSIBILITY.md) | DONE |
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
- **Source/fix commit:** `2e493ce`, parent `35934d7`.
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

## Q03 — a release cannot ship pointing at the dev backend (2026-09-06)

- **Status:** IMPLEMENTED_UNVERIFIED. The boundary exists and is enforced at build time on
  Android and at launch on iOS; **no release artifact was produced or inspected**, which is what
  Q03's acceptance actually asks for. See limitations.
- **Source/fix commit:** `f1072b2`, parent `8f3467f`.
- **Files:** Android `app/build.gradle.kts`, `net/ApiClient.kt`, `src/main/AndroidManifest.xml`,
  `src/debug/AndroidManifest.xml` (new), `src/debug/res/xml/network_security_config.xml` (new),
  `src/test/java/com/voiid/app/EnvironmentBoundaryTest.kt` (new); iOS
  `Networking/APIClient.swift`, `Voiid/Info.plist`.
- **Failure reproduced:** by reading it. Both clients hardcoded `https://api-dev.voiid.app` and
  nothing anywhere assigned anything else, so there was no environment boundary of any kind — a
  release APK or IPA would have been built against the development backend, signed and shipped,
  and the only thing preventing that was somebody remembering to edit a constant. Android also
  set `usesCleartextTraffic="true"` on the whole application: plumbing for talking to a laptop,
  shipped to users, permitting plaintext for every connection the app ever makes.
- **Implementation:** endpoints move to build configuration. Android debug keeps the dev host as
  a working default (overridable by property or environment variable, so pointing at a laptop
  needs no source edit); **release has no default at all** and `requireReleaseEndpoint` throws at
  configuration time if the value is missing, names a development host, or is not TLS. iOS reads
  the endpoints from Info.plist keys fed by build settings, with a `#if DEBUG` fallback and a
  release `precondition` that refuses to start otherwise. Application-wide cleartext is gone;
  a debug-only manifest restores it, scoped to `localhost`, `127.0.0.1` and `10.0.2.2` rather
  than globally.
- **The production hostname is deliberately not written down.** The issue says not to guess it,
  and a guessed host would replace a visible misconfiguration with an invisible one.
- **Regression evidence:** the three release refusals were executed, not asserted from source —
  `assembleRelease` with no endpoints, with the dev host, and with `http://` each fail with their
  own message. Restoring `usesCleartextTraffic="true"` fails its guard. Replacing one endpoint
  with a hardcoded dev host fails the release guard — that check did NOT bite on first writing,
  because it looked for the helper's NAME anywhere in the file and the helper survived in the
  other endpoint; it now asserts that each setting is produced by it.
- **Two staleness traps hit again.** The unit tests read the manifest and `build.gradle.kts` off
  disk, which Gradle cannot see, so the task served byte-identical stale results after all three
  files had changed. Both are declared as test inputs now, as `res/xml` and `schemas` already
  were.
- **Validation:** 98 Android unit tests (6 new); `assembleDebug` exit 0; lint holds at its 90
  baseline; iOS debug simulator build exit 0.
- **Remaining limitations — WHY THIS IS NOT `DONE`:**
  - **No release artifact was built or inspected.** Q03's acceptance is "inspect release
    artifacts to verify the intended hosts, trust policies and identifiers". A release build
    cannot even be produced here without the real endpoints, and signing config was not
    exercised. What is proven is that a release WITHOUT them is refused — not what a correct one
    contains.
  - **iOS enforces at launch, not at build.** A misconfigured release IPA compiles and then
    crashes on first run with a precondition message. That is deliberate — silently talking to
    the dev backend from the App Store is the worse failure — but it is a weaker gate than
    Android's, and it needs the `VOIID_API_BASE_URL` / `VOIID_WS_URL` build settings adding to
    the Release configuration in Xcode, which this change does not do (editing `project.pbxproj`
    programmatically was judged too risky to do blind).
  - **Sign-in, push registration, deep links and forced-update were not tested against any
    environment.** All four are named in the acceptance and none was exercised.
  - **The wider environment set is unreviewed.** Q03 also asks for backup, deep-link, push, maps
    and bundle/application identifiers to be reviewed as a set. Only the API/WS hosts and
    cleartext policy are addressed here.

## M04 — history pagination, and the aggregation actually measured (2026-09-06)

- **Status:** DONE. The cursor defect is fixed, the roster semantics are decided and tested, and
  the query plans exist. There is still no p95 budget to hold the numbers against — see below.
- **Source/fix commit:** `441677f`, parent `980f418`.
- **Files:** `backend/api/src/routes/messages.ts`;
  `backend/api/test/historyPaginationPostgres.test.ts` (new); `.github/workflows/ci.yml`.
- **Failure reproduced, and it was worse than expected.** History paged with `before=<timestamp>`
  and strict less-than. `created_at` is not unique — a fan-out send writes its rows in one
  transaction — so a page boundary landing inside a tie skipped every remaining row sharing that
  timestamp: they are not "before the cursor", they ARE it. With 300 tied messages and a page
  size of 25, **295 of 320 messages were unreachable**, and permanently so: the client had
  already scrolled past them and would never ask again.
- **Cursor:** `(created_at, id)` ordering and a keyset cursor, with `before` kept working for
  clients that have not learned about cursors (M04's migration note asks for dual-compatible
  responses). Limits and cursors are validated rather than coerced.
- **THE MEASUREMENT, which is the half the issue actually cared about.** `EXPLAIN (ANALYZE,
  BUFFERS)` on a representative fixture — 50-member group, 50,000 messages, 30,000 receipts:
  - Before: the receipt aggregation ran over the WHOLE conversation and the LIMIT was applied
    afterwards. **50,000 rows grouped, sequential scans on both tables, 51.6ms, spilling to temp
    files (687 blocks read, 689 written)** — to return fifty rows.
  - After: the page is selected in a CTE first, so the aggregate joins fifty ids instead of fifty
    thousand. **3.5ms, no spill, 431 shared buffers instead of 1197.**
- **NO INDEX WAS ADDED, and that was checked rather than assumed.** M04 says not to add one
  merely because a column occurs in SQL. `idx_messages_conversation (conversation_id,
  created_at DESC)` already serves the new ordering through an incremental sort (4 buffers,
  0.05ms for the first page), and `idx_receipts_message` already covers the receipt join —
  forcing it with `enable_seqscan=off` gives 0.39ms, so the planner will choose it on its own
  once a seq scan stops being the cheaper option at this size. Adding indexes here would have
  been cargo cult.
- **The roster semantics are now a decision, not an accident.** Read status counted "active
  members other than the sender" — a CURRENT-roster count — so someone joining a group
  **un-read every older message**: the sender's blue tick went back to grey for everybody, and
  could never return, because the fan-out addressed the devices that existed when it was sent.
  A person who was not sent a message cannot read it. The denominator is now the roster AT SEND
  TIME (`joined_at <= m.created_at`), with `left_at is null` retained: the two clauses answer
  different questions — who was ever owed this message, and who is still around to owe it.
- **Regression evidence:** removing the `id` tie-break fails both pagination scenarios;
  reverting to the current-roster count fails the semantics scenario.
- **A flaky test caught before it was committed.** The semantics subtest first picked `tied[0]`
  and asserted it appeared on a page — but 300 rows share a timestamp and the tie-break is a
  random uuid, so which of them lands on any page is luck. It failed on roughly two runs in
  three. It now picks a message with a distinctly later timestamp, and was run five times
  consecutively to confirm stability.
- **Validation:** 7 scenarios against real PostgreSQL; full `npm test` exit 0 (API 318/319,
  games 6/6, relay 28/28, workers 32/32, admin 10/10); typecheck clean.
- **Remaining limitations:**
  - **There is no acceptance budget.** M04 asks that "query plans and p95 results meet the
    acceptance budget". The plans exist and the numbers are recorded above, but no budget has
    ever been defined, so nothing here can be said to meet it. 3.5ms on this fixture is a
    measurement, not a pass.
  - **One fixture, one shape.** 50 members / 50k messages / 30k receipts on a laptop against
    a loopback Postgres. No concurrency, no cold cache, no Supabase, and no p95 over repeated
    runs — a single `EXPLAIN ANALYZE` is a sample.
  - **The clients do not use the cursor yet.** Both still page with `before`, so they keep the
    tie defect until they are updated. The server supports both; nothing forces the migration.
  - **`joined_at` is a proxy for "was sent this message".** It is the best signal available, but
    a member who left and rejoined has a `joined_at` later than messages they genuinely
    received, so those will not wait for them. That is the safe direction (the tick turns blue
    rather than never), and it is a real edge worth knowing.

## P04 — Bound pool, cache, and request latency before scaling

- **Status:** DONE for the bounding half. The measurement half is explicitly NOT done — see Remaining limitations, which is the more important part of this record.
- **Files:** `packages/common-utils/src/poolBudget.ts` (new), `backend/api/test/poolBudget.test.ts` (new), `backend/api/src/db.ts`, `backend/games/src/db.ts`, `backend/workers/src/db.ts`, `backend/websocket/src/session.ts`, `backend/api/src/messageOutbox.ts`.
- **Failure reproduced:**
  - *Unbounded pools.* The API and games pools took node-postgres defaults: `max: 10` per process, **no** `connectionTimeoutMillis` and **no** `statement_timeout`. So a slow query held a connection with no "until"; a request that could not get a connection waited forever rather than failing, growing an unbounded queue; and four processes each claimed an unstated share of Supabase's deployment-wide connection ceiling, which is how the fifth cannot connect at all.
  - *Per-recipient latency on the request path.* `publishOutbox` awaited each publish in turn. Measured: 50 recipients took **1070ms** of pure Redis round-trips added to the sender's response, one RTT per recipient.
- **Implementation:**
  - `poolBudget(service, env)` states a per-service budget — size, acquisition timeout, idle timeout, and a server-side `statement_timeout` — argued from the connection ceiling and the workload shape, overridable per deployment via `VOIID_{API,GAMES,WORKERS,WS}_POOL_MAX`, with invalid overrides ignored rather than accepted. All four services spread it into their `Pool`, and log it at boot so an operator sees the budget.
  - `publishOutbox` now uses fixed-size workers over a shared cursor (`VOIID_PUBLISH_CONCURRENCY`, default 8) — bounded parallelism. `Promise.all` over the whole set was rejected deliberately: it hands Redis an unbounded burst from every concurrent send at once, which is how a Redis recovery becomes the next outage. A chunked `Promise.all` was also rejected as it runs at the speed of each chunk's slowest member.
  - Failure semantics are unchanged: a publish that throws leaves that row `pending` for the sweep, does not abort the rest of the fan-out, and never turns a committed send into a 500.
- **Regression evidence (anti-vacuity, all four reverts run):**
  - Sequential loop restored → fails: *"fan-out took 1070ms for 50 recipients — that is one Redis round-trip per recipient on the sender's request path"*.
  - Unbounded `Promise.all` → fails: *"50 publishes were in flight at once — an unbounded burst per send is how a Redis recovery becomes the next outage"*.
  - `...budget` spread deleted from each of the four services in turn → the guard fails for **each** one.
- **A guard that was decoration, and the second time this exact mistake was made.** The first version of the pool guard asserted that `poolBudget(` appeared in each file. When the anti-vacuity check deleted the `...budget` spread from the relay — leaving the now-useless call above it — **the test still passed.** This is precisely the Q03 defect returning: matching a helper's *name* rather than the *property* the helper exists to produce. It is now rewritten to parse each `new Pool({ ... })` to its matching brace and require the budget be spread into that specific construction, so a second Pool later in a file cannot satisfy the first. Recording it because the check only caught it by being run — the meta-lesson stands: *a guard that has not been run against the broken code is not evidence yet.*
- **Validation:** typecheck clean across api, games, workers, websocket, common-utils. API 329/329 (0 skipped), workers 32/32, websocket 28/28. Note: an earlier run reported "319 pass, 2 skipped" because two suites' env vars are named `PAYMENTS_TEST_DATABASE_URL` and `REDIS_TEST_SERVER` and I had passed the wrong names — a skipped test is not a passing one, so the suite was re-run with all of them supplied.
- **Remaining limitations — the half that is NOT done:** P04 asks that *"a staged concurrency ramp meets the budgets in part 16"* and that *"final pool sizes are chosen from measurements, not an arbitrary large maximum."* **No load test has been run and no latency budget exists.** The numbers here are argued from Supabase's connection ceiling and the shape of each workload; they are stated so they *can* be measured against, which is a prerequisite for that work, not a substitute for it. The 8-way publish concurrency is likewise a defensible default, not a measured optimum. Redis was separately bounded (`connectTimeout`/`commandTimeout` 1500ms, `enableOfflineQueue: false`, `maxRetriesPerRequest: 1`); no cache-hit-rate or eviction work was done. Treat the pool sizes as provisional until part 16's ramp is actually run.

## S04 — Replace the false recovery lockout security boundary

- **Status: STILL TODO. This is a release gate and it is not closed.** S04's "Done when" requires that *"a cryptographic reviewer approves any new protocol"*, and no reviewer has. What is recorded below is the code-level half only — the half S04 explicitly asks for alongside the protocol work: *"explicitly document this threat model; remove claims that client-reported attempts enforce a security boundary … make counters atomic where they remain useful for abuse telemetry."* **No new cryptographic protocol was designed, and none should be read into this entry.**
- **Files:** `backend/api/src/routes/recovery.ts`, `backend/api/src/recoveryLockout.ts`, `backend/api/test/recoveryLockout.test.ts`, `backend/api/test/recoveryMeteringPostgres.test.ts` (new), `database/migrations/063_recovery_fetch_metering.sql` (new), `packages/e2e-core/src/recovery.rs` (docs only).
- **Failure reproduced:**
  - *The false claim.* `routes/recovery.ts` described `failed_attempts`/`locked_until` as "SERVER-SIDE guess limiting", and `recoveryLockout.ts` called itself "the control that stands between an attacker with a stolen JWT and an ONLINE brute-force of a 6-digit PIN". Both false: every transition is driven by the client's own `POST /recovery/attempt-result`, and in this threat model the client is the attacker. It can withhold failures, or send `success:true` to reset the counter and clear an active lock. **The comment was the most dangerous artifact here**, because it invited reliance on a boundary that does not exist.
  - *Lost updates, in the attacker's favour.* The failure counter was `select` then `update` across two statements. Measured under READ COMMITTED: **8 concurrent failure reports advanced the counter to 4.** Half the failures vanished, so even the telemetry under-reported abuse — the worst direction for it to be wrong.
  - *Unmetered envelope fetch.* `GET /recovery/key` returned the wrap with no server-side record or bound, so a stolen token could harvest envelopes freely and invisibly.
- **Implementation (code-level only):**
  - The threat model is now written at the top of `routes/recovery.ts`, covering the stolen-token and stolen-database cases S04 names, and stating plainly that the client-reported counter is abuse telemetry about *honest* clients, not a security boundary. The false claims in `recoveryLockout.ts` and its test header are replaced with what those tests do and do not establish. `packages/e2e-core/src/recovery.rs` gains the entropy arithmetic: BIP39 is 256 bits, a 6-digit PIN is ~20, and Argon2id raises the cost of an offline search without making one infeasible.
  - The failure counter increments inside a single `update … returning`, so the row lock serializes it.
  - `fetch_count`/`last_fetched_at` record the one signal the client **cannot** forge — an offline attacker must fetch the envelope at least once and cannot un-fetch it. Fetches are counted in the same statement that reads the row (so a race cannot lose one), counted even when the request is then refused, bounded by `VOIID_RECOVERY_FETCH_LIMIT` (default 25, generous so a legitimate retry across a flaky network is never locked out), and reset by storing a new wrap.
- **Regression evidence (anti-vacuity, three reverts):** restoring select-then-update → *"8 failures were reported but the counter reached 4 — concurrent reports overwrote each other"*; removing the fetch bound → *"unbounded fetches let a stolen token harvest freely"*; not counting fetches → *"the fetch is the only signal the client cannot forge; it must not be missed"*. A further test asserts the threat model is present and the retired claim has not returned, because the false documentation is what made this dangerous.
- **Validation:** `backend/api` 337/337, 0 skipped. Typecheck clean. `cargo build` clean (doc-comment change only).
- **Remaining limitations — why this is still a gate:**
  - **Offline PIN guessing is not addressed and cannot be from this file.** Anyone holding a fetched envelope can try every PIN at their own pace, unobserved. Metering bounds *harvesting*; it does nothing for an envelope already handed out.
  - `POST /recovery/attempt-result` with `success:true` **still clears the counter**, by design — it is left because removing it would not create a boundary, only break honest clients' backoff. The asymmetry is now documented at the call site rather than hidden.
  - A stolen database gets every envelope at once, with no fetch metering whatsoever.
  - **Not done:** selecting a reviewed recovery design (high-entropy secret, or a server-assisted OPRF/SVR that never exposes an offline verifier); the versioned migration keeping old backups restorable through it; stronger authorization before replacing recovery material. Per S04, *"this is a release gate, not a task an AI should claim to have cryptographically certified"* — and this entry makes no such claim.

## E01 — Reconcile crypto assurances with current code and executable gates

- **Status: clauses 1–3 DONE. Clauses 4–5 remain TODO and cannot be done here** — they require an independent protocol/integration review and a reviewed migration, and E01 says explicitly that *"existing test success does not replace this review."* Nothing below is a cryptographic assurance.
- **Files:** `packages/e2e-core/.cargo/audit.toml`, `packages/e2e-core/SECURITY.md`, `README.md`, `.github/workflows/ci.yml`, `.github/workflows/nightly.yml`, `packages/e2e-core/tests/assurance_claims.rs` (new), `packages/e2e-core/Cargo.toml` (dev-dep), `plans/app-audit-2026-09-05/evidence/cargo-audit-2026-09-06*.json` (new).
- **Failure reproduced — every defect here was a false CLAIM, not a crypto flaw:**
  - **The audit in CI was scanning nothing.** Both workflows pinned `cargo-audit ^0.21`. That version cannot parse the CVSS 4.0 severity strings the advisory database now uses, and it fails to load the **entire** database rather than skipping the affected entries: `error loading advisory database … unsupported CVSS version: 4.0`, exit 1, zero crates examined. Reproduced directly on 0.21.2 against `RUSTSEC-2026-0073`.
  - **`SECURITY.md` named a workflow that does not exist** (`.github/workflows/e2e-core-audit.yml`). The audit is real and does run — only the filename was wrong — but a named-but-absent workflow reads as an assurance that is running.
  - **The README's "non-negotiable golden rule" named the wrong library**: *"All crypto via libsignal (wired in Phase 2, after AGPL licensing is cleared)."* The crate is built on vodozemac + OpenMLS; choosing them is what removed the AGPL blocker. The rule described a plan that was abandoned.
  - **The ignore list's justification had expired.** It read: fixes are *"only reachable via openmls_libcrux_crypto 0.4.0-rc … we do not ship release-candidate crypto."* As of this scan the whole stack is stable: openmls **0.9.0**, openmls_traits **0.6.0**, openmls_libcrux_crypto **0.4.0**. The stated trigger for dropping the suppressions had fired and nobody had noticed.
- **Fresh scan (clause 1), retained:** cargo-audit **0.22.2**, **1239** advisories, **254** crates. With the ignore list: **0 vulnerabilities, 0 warnings.** With `ignore = []`: **exactly the ten known advisories, no more and no fewer** — so nothing is stale suppression and nothing new is hidden. Both reports are committed under `plans/app-audit-2026-09-05/evidence/`. Every ignore is now annotated with its crate, the version we hold, and the fixed version if one exists (six have fixes: libcrux-chacha20poly1305 ≥0.0.8, ed25519 ≥0.0.7, poly1305 ≥0.0.5, secrets ≥0.0.6, sha3 ≥0.0.10 ×2; four have none: the three libcrux-aesgcm advisories and proc-macro-error2, which is build-time only).
- **The upgrade was attempted and deliberately NOT taken.** Moving to openmls 0.9 / openmls_libcrux_crypto 0.4 resolves six of the ten. It also breaks the build in ways that are not mechanical — `StorageProvider` generic arity, the `Signer` trait bound, tls_codec 0.5 — and, decisively, **removes `MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519`**, which is the ciphersuite `src/group.rs` uses for every group. Taking it changes the group protocol's cryptography and its post-quantum posture. E01 clause 5 requires mixed-version compatibility fixtures and a documented upgrade boundary for exactly this, so it is left for review rather than landed. The attempt is recorded in `audit.toml` so the next person does not have to rediscover why. **The suppressions are no longer blocked on upstream; they are blocked on a reviewed migration** — a scheduled piece of work, not a waiting game.
- **Implementation:** CI pinned to `cargo-audit ^0.22` in both workflows with a comment saying why the older pin was worse than useless; the JSON report is written and uploaded as a build artifact `if: always()`, since the report of a *failing* scan is the one worth keeping. Documentation corrected in README and SECURITY.md, each noting what the retired claim said so the correction is auditable. Five executable gates added in `tests/assurance_claims.rs`.
- **Regression evidence (anti-vacuity, four reverts, each fails with its reason):** restoring the libsignal rule → *"README still presents libsignal as the crypto in use"*; renaming the workflow back → *"SECURITY.md points at .github/workflows/e2e-core-audit.yml, which does not exist"*; restoring `^0.21` → *"pins cargo-audit ^0.21, which cannot parse the current advisory database (CVSS 4.0) and therefore scans nothing"*; stripping a status comment from an ignore → *"suppressed advisory without a status comment"*.
- **A gate that was decoration, caught by the revert.** The workflow-existence check first split SECURITY.md on whitespace and trimmed a fixed character set, which left the trailing comma on ``` `.github/workflows/ci.yml`, ``` — so the path never matched the `.yml` suffix test and **the gate passed against a document deliberately pointing at a non-existent workflow.** Rewritten to regex over the text. This is the third time this session a guard has needed the revert to prove it was real; the rule stands: *a guard that has not been run against the broken code is not evidence yet.*
- **Validation:** `cargo test --locked` — all suites pass (5/5 new). `cargo clippy --locked --all-targets -- -D warnings` clean. `cargo fmt --check` clean.
- **Remaining limitations:** **Clause 4 (independent protocol/integration review covering identity verification, malicious key directory, fallback rotation, MLS credential binding/member removal, nonce generation, pickle/backup storage, crash consistency, FFI panic handling, call-media encryption) has NOT been commissioned, and clause 5's reviewed migration has not been performed.** The ten advisories remain suppressed and are still live. The Olm `SessionConfig::version_1` 64-bit MAC truncation noted in SECURITY.md is unchanged. Generated Swift/Kotlin bindings and packaged native binaries were not verified against a reviewed Rust commit. No independent cryptographic review was obtained, and none of the gates added here substitutes for one.

## I02 — Bound avatar memory and avoid synchronous disk misses in UI

- **Status:** DONE, with measurements rather than a claim that a refactor helped.
- **Files:** `apps/ios/Voiid/Voiid/Networking/AvatarCache.swift`, `apps/ios/checks/AvatarBoundsCheck.swift` (new), `apps/ios/checks/README.md` (new).
- **Failure reproduced (measured on an iPhone 16 Pro simulator, not argued):**
  - **A single 4000x3000 photo occupied 411 MB resident.** `UIImage(data:)` decoded at full size *and* at the screen scale, yielding a 12000x9000-point image — to be drawn in a 40pt circle.
  - **600 avatars retained ~12,150 MB.** The store was a `[String: UIImage]` that never evicted anything. This is not a slow scroll; it is a jetsam kill.
  - **A blocking disk read in the SwiftUI body path.** `cached(_:)` fell through to `Data(contentsOf:)` plus a full-size decode on a miss, and it is called from `.onAppear` and body in `ChatsHomeView`, `MapAvatarPin`, `DraggableChatGrid`, `SettingsSheet`.
  - No coalescing (N cells appearing at once started N downloads of the same bytes), main-actor JPEG encoding in `store`, and no HTTP status or size validation before decode.
- **Implementation:** `NSCache` bounded by **bytes** (48 MB, 512 entries) — cost in bytes because avatars differ in size by orders of magnitude, so an entry count bounds nothing that matters, and `NSCache` additionally evicts under system memory pressure, which a Dictionary cannot. A new `AvatarStorage` actor owns every slow operation — disk reads, decoding, downsampling, JPEG encoding — off the main actor, with an `inFlight` map so concurrent requests for one ref share a single download. Decoding goes through `CGImageSourceCreateThumbnailAtIndex` capped at 768px, which downsamples *during* decode so the full bitmap never exists. HTTP status is checked and bodies over 20 MB are refused before decode. `cached(_:)` is now **memory-only**: a miss returns nil and the caller awaits `resolve`, so nothing blocks the rendering thread. `clear()` empties memory synchronously (so no decoded face survives sign-out) and wipes disk asynchronously.
- **Regression evidence:** the harness runs 9 checks; against the old implementation (`UIImage(data:)` into a `[String: UIImage]`) **4 fail** — "a 4000x3000 photo is downsampled" (got 12000x9000), "downsampling cuts resident memory by >10x" (432000000 vs 432000000), and both cache-bound checks (600/600 retained, ~12150 MB). Against the current code all 9 pass: 411 MB → **1 MB** for one photo, 600 avatars → **21 retained, ~47 MB** against the stated 48 MB limit.
- **A real bug the measurement caught.** The first fix used `kCGImageSourceCreateThumbnailFromImageAlways`, which synthesises a thumbnail even when the source is already smaller than the cap and returns it at the renderer's scale — **upscaling a 120x120 avatar to 360x360, nine times the memory to show fewer pixels than it started with.** The code read as obviously correct. Now `...IfAbsent`, with `UIImage(cgImage:scale:orientation:)` at scale 1 so size and cost are not misreported.
- **Two bugs in the harness itself, both recorded in the file.** It first inserted the *same* `UIImage` instance under all 600 keys, so `NSCache` saw one live object, evicted nothing, and the eviction check "failed" against correct code — the test's bug, not the cache's. It then compared an image's *pixel* dimensions against a *point* value and reported a phantom upscale. Both are noted at the assertions so the next reader does not re-derive them. The lesson is the session's recurring one from the other direction: a check that has not been run against the *fixed* code can be as misleading as one never run against the broken code.
- **Validation:** `xcodebuild … -scheme Voiid` **BUILD SUCCEEDED**; harness 9/9 in the simulator.
- **Remaining limitations:** no Instruments trace and no on-device run — the numbers are from a simulator harness exercising the same code paths, which is measurement of the bounding logic, not of real scroll performance. `UIApplication.didReceiveMemoryWarningNotification` is not explicitly observed; the fix relies on `NSCache`'s own pressure eviction. The 48 MB and 768px figures are argued from call-site sizes, not tuned against a device profile. Disk cache growth is still unbounded — files are only removed on `clear()` — so a very large address book can accumulate JPEGs on disk indefinitely; that is bounded storage, not bounded memory, and is not what I02 asked for, but it remains true.

## U05 — Remove stale iOS tab timers and honor reduced motion

- **Status:** DONE for the timer and reduced-motion logic. The visual inspection clause is not claimed — see Remaining limitations.
- **Files:** `apps/ios/Voiid/Voiid/Main/RootTabView.swift`, `apps/ios/checks/TabTransitionCheck.swift` (new).
- **Failure reproduced (modelled and measured, not argued):** the stretch release was a bare `DispatchQueue.main.asyncAfter`, which cannot be cancelled and whose closure set `isSliding = false` **unconditionally** — it had no idea which tap it belonged to. Running U05's own acceptance sequence (A→B→C→A, 30ms apart, so every earlier callback is still pending when the next tap lands): **90ms after the final tap the old bar reports `isSliding = false`** — the first tap's 120ms timer fired during the last tap's transition and snapped its indicator back. The new bar reports `true` at the same instant and releases on its own schedule.
- **Implementation:**
  - The release is now a `Task` owned in `@State` and cancelled before a new one is created, so only the newest transition can end its own stretch. A cancelled `Task.sleep` throws rather than running its body, so a superseded release simply never happens — the generation is the task identity itself, with no counter to keep in sync.
  - `.onDisappear` cancels any pending release and clears `isSliding`, so no delayed work outlives the bar.
  - **Reduce Motion** is honoured across all four spatial effects: selection changes immediately on a 140ms `.easeOut`, with no indicator stretch, no 1.10 icon overshoot, and the press feedback swapped from a 0.92 scale to a 0.7 opacity — the press must still be *felt*, so it is replaced rather than deleted. On the reduced-motion path **no delayed work is scheduled at all**, so the stale-callback class of bug cannot occur there.
  - The 0.32s/0.9 selection spring, the restrained underline indicator and the distance-proportional stretch are unchanged on the normal path, as U05 requires.
- **Regression evidence:** the harness's first assertion is that the **old** implementation still reproduces the defect; if that stops failing, the harness has stopped modelling the bug and the rest proves nothing. 5/5 checks pass, covering: the old bar breaking a newer transition, the new bar not doing so, the new bar still releasing (not hanging), disappearance cancelling pending work, and no state change after disappearance.
- **Validation:** `xcodebuild … -scheme Voiid` **BUILD SUCCEEDED**; harness 5/5.
- **Remaining limitations:** U05 asks to *"inspect at 10% playback speed"* and to confirm *"VoiceOver activation and Reduce Motion show correct state"* on a device. **Neither was done** — there is no screen recording and no VoiceOver run here. What is verified is the timer's cancellation semantics (by execution) and that the reduced-motion branches exist and compile; that the resulting motion *looks* right, and that VoiceOver announces selection correctly, still needs a human with a device. Tab scroll-to-visible behaviour was not modified and not re-verified.

## I01 — Move chat persistence off the main actor and page history

- **Status: PARTIAL, and deliberately not marked DONE.** The main-actor IO is moved and the read path's correctness bugs are fixed. The storage migration I01 ultimately asks for (message persistence moving to GRDB with a versioned import, counts/checksums and rollback retention) is **not** done, and the acceptance clause *"attach Instruments and Android traces"* is **not** satisfied — this was taken on explicitly that basis.
- **Files:** `apps/ios/Voiid/Voiid/Networking/ChatShardStore.swift` (new), `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift`, `apps/ios/Voiid/Voiid/Storage/LocalStore.swift`, `apps/ios/Voiid/Voiid.xcodeproj/project.pbxproj`, `apps/ios/checks/ChatHistoryCostCheck.swift` + `PersistWindowCheck.swift` (new).
- **Failure reproduced — measured with the real record shape, on a development Mac (a phone is slower, so these are floors):**

  | history | encode whole conversation | frames @60fps | bytes |
  |---|---|---|---|
  | 1,000 | 5.1 ms | 0.3 | 0.3 MB |
  | 10,000 | 33.7 ms | 2.0 | 3.4 MB |
  | 50,000 | **147.3 ms** | **8.8** | 17.2 MB |

  `persist()` JSON-encoded the **whole** conversation, synchronously, on the `@MainActor` — once per sent message, per received message, per receipt, per delete. So the cost of sending one message grew with everything ever said in the thread: ~9 dropped frames per message in a long chat, with the keyboard up. Cold launch decoded every shard the same way (130.7 ms for one 50k conversation before anything rendered).
  - **A correctness bug, not a speed one:** `LocalStore.messages` was `ORDER BY created_at ASC LIMIT 500` — the **oldest** 500. Opening a 10,000-message chat showed "Message 0", never the recent conversation. (This path currently has no callers — `ChatMediaItem` documents that the GRDB mirror is unwritten — but it is the store I01 points the migration at, so it had to be right before anything switched to it.)
  - **A cursor that stalls:** paging on `created_at` alone across a block of tied timestamps reached **25 of 320** messages. The `(created_at, id)` keyset reaches all 320 — the same defect M04 fixed server-side.
- **Implementation:** a new `ChatShardStore` **actor** owns encoding and file IO off the main actor; being an actor keeps writes to one conversation serialized, which `@MainActor` had been providing for free. `persist()` is now `async`, snapshots the dirty set on the main actor, and hands it over in one hop; `persistSoon()` covers the paths where nothing is acknowledged on the strength of the write. `LocalStore` gains `latestMessages` (newest page, reversed for display) and `messagesBefore` (a `(created_at, id)` keyset cursor); the existing index on `(conversation_id, created_at)` supports both.
- **A message-loss bug that this change INTRODUCED, caught before commit.** `persist()` being synchronous had made "a message arrives mid-write" impossible on the main actor. Making it async opened that window, and the obvious `dirtyConversations.subtract(committed)` is wrong there: `committed` names a *conversation*, not the version of it that was written, so a message arriving during the await had its fresh dirty mark eaten. Reproduced: **on disk `["m1"]`, in memory `["m1","m2"]`, dirty set empty** — m2 lost at exit, silently. Now the marks are cleared *before* suspending and only failures are re-marked. I had written a comment asserting the old subtraction was still safe; it was not, and only running the case showed it.
- **Regression evidence:** `ChatHistoryCostCheck` (9 checks) asserts the old costs and both old read-path defects still reproduce, so it cannot quietly stop measuring; `PersistWindowCheck` fails with an empty dirty set if the subtraction is restored. Both committed under `apps/ios/checks/`.
- **Validation:** `xcodebuild … -scheme Voiid` **BUILD SUCCEEDED** (both the app and the `VoiidNSE` target, which compiles `ChatEngine.swift` from an explicit source list and needed the new file added to it). All four iOS checks pass.
- **Remaining limitations — substantial, and the reason this stays open:**
  - **No Instruments trace, no device run, no Android trace.** I01 requires them and they are not here. Scrolling, typing, incoming-message bursts and cold launch with large histories have **not** been observed on hardware. What is measured is the cost of the encode/decode work itself, not the resulting frame rate.
  - **`loadStore()` is still synchronous on the main actor** — 130 ms for a 50k conversation at cold launch. Left deliberately: `ensureLoaded()` is called from a dozen synchronous paths whose invariant is that they never touch an unloaded store, and making it async would let them observe `storeLoaded == false` mid-flight, which is exactly the clobber-on-disk bug that flag prevents. Fixing this properly is part of the GRDB migration, not a change to make in isolation.
  - **The whole conversation is still encoded per persist, and still held in memory.** This moved *where* that happens, not *that* it happens. A 50k conversation still costs 147 ms of CPU per write and ~17 MB per encode — it simply no longer blocks the UI.
  - **The GRDB migration is not started:** no versioned import of shards with counts/checksums, no rollback retention, no switch of UI consumers to the paged read model, and the new `latestMessages`/`messagesBefore` have **no callers yet**. Cross-process app/NSE coordination is unchanged (atomic writes plus per-conversation reload); both writers now route through one actor *within* a process, which is not the same as coordinating between them.
