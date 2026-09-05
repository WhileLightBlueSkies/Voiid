# 01 — Issue register

Baseline: `a2e24e5` · 50 actionable findings/capability gaps · 1 DONE (Q01), 49 TODO.

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
| S01 | P0 | Authorize receipt reads and writes | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | TODO |
| S02 | P0 | Validate sender and recipient devices on all message paths | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | TODO |
| S03 | P0 | Make revocation persistent and device-bound | Confirmed | [02](02-SECURITY-AND-RECOVERY.md) | TODO |
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
| Q02 | P1 | Add quality gates before deployment | Confirmed gap | [13](13-RELEASE-AND-OPERATIONS.md) | TODO |
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
Source/fix commit:   working tree on a2e24e5 (not yet committed)
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
