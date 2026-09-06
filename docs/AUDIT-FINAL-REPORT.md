# Voiid audit report — 6 September 2026

**The full audit is not complete. Current register: 18 done, 15 implemented but awaiting complete verification, 17 open, out of 50.**

This is the single current report. It supersedes previous conversational totals, which incorrectly added up to 52. Existing changes from the other AI were inspected and preserved; interrupted agent patches were reviewed, corrected and tested before committing. Four earlier DONE claims—A02, M01, C02 and C04—were changed to implemented/unverified because acceptance requirements remain. This is a correction to the record, not a rollback of fixes.

## What changed in this continuation

| Area | Result | Commit |
|---|---|---|
| API throttles | Community reads no longer exhaust host-thread creation limits. Authenticated limits follow the account. Counts and expiry update atomically; rejected requests have retry timing and do not flood SQL logs. | `c213d34` |
| Message retries | Simultaneous reuse of one message ID with different ciphertext returns one success and one conflict, rather than two successes. | `c213d34` |
| Cleanup workers | Object keys and metadata deletion commit together. Failed queue writes preserve source records. Durable leases and claim tokens prevent stale workers finalizing newer claims. Health reflects failed work, drift and staleness. | `0d23c80` |
| Relay | Shared conference-grant parsing, bounded outbound buffers, authentication deadlines, expiry/revocation checks and shared presence/frame budgets. Full live multi-instance acceptance remains outstanding. | `b2c2680` |
| Android | Corrupt encrypted stores are preserved; old quarantine evidence blocks silent replacement. HTTP cancellation reaches sockets during headers/body reads. Shard writes use separate synced temporary files. Sheets await exit and keep detent identity; dialogs respect Back policy. | `1d20ac1` |
| Web/admin | Fixed stale responses and StrictMode lifecycle handling, duplicate report writes, Cancel/Escape selector reset, and mobile navigation focus across closing/resizing. | `cbb8170` |
| Migrations | Serialized runners, checksum drift detection, explicit reviewed legacy baselines and nontransactional failure tracking. | `14682f7` |

All commits are local on `codex/audit-completion-2026-09-06`. No push or deployment was performed. Unrelated iOS dependency changes, the parity spreadsheet and Sea Battle files remain untouched.

## Verification

| Check | Result |
|---|---|
| API, with all configured PostgreSQL integration suites and real Redis limiter test | **306 passed, 0 skipped** |
| Workers, including queue failure/rollback, claims, fencing, recovery and outbox | **32 passed, 0 skipped** |
| Relay, including PostgreSQL session and recipient tests | **28 passed, 0 skipped** |
| Android unit tests | **87 passed** |
| Android debug build | **Passed** |
| Actual browser hook/report/navigation scenarios | **8 passed** |
| Admin helper tests | **10 passed** |
| Admin and public web production builds | **Passed** |
| API, workers, relay, shared, admin and public web typechecks | **Passed** |
| Migration locking/drift/baseline/rollback test | **Passed** |
| Full clean migration replay and second verified no-op run | **69 migrations passed** |
| iOS build or device testing this continuation | **Not run; no iOS source changed** |

Environment: macOS, Node 24.15.0, disposable local PostgreSQL 16, local Redis test process and Chrome. CI's pinned runtime and hosted jobs still need their own verification. Browser tests use the actual components with mocked navigation and controlled responses, not a deployed backend. Storage deletion failures/recovery use injected object operations; actual R2 lifecycle behavior was not tested.

## Remaining work that matters most

- **Recovery security (S04/E01):** short-PIN recovery exposes an offline guessing surface. Independent cryptographic review remains a release gate; passing tests cannot certify this design.
- **Native durability (A04/I01/I03/M01/M02):** destructive Room fallback still needs removal with migration/recovery acceptance; iOS persistence work, prepared-send durability and durable ACK retry need completion.
- **Calls and operations (R05/Q03/Q04):** conference seat admission still needs real concurrency serialization; native release environment separation and verified-artifact deployment/readiness/rollback remain open.
- **UI:** Liquid Glass, photo-viewer gesture completion, iOS tab timer ownership and broader accessibility work remain open. Sheet/dialog patches compile, but device/controlled-clock acceptance is still missing.
- **Performance/scaling:** history pagination, bounded dependency/resource measurements, Android release optimization and game ownership remain open.

The 15 implemented/unverified entries are not release sign-offs. Historical DONE entries not changed in this continuation retain their earlier evidence; they were not independently recertified here.

## Complete issue status

| ID | Priority | Issue | Status |
|---|---|---|---|
| A01 | P0 | Exclude current private stores from Android backup/transfer | Implemented; verification incomplete |
| A02 | P0 | Stop automatically deleting shared encryption keys | Implemented; verification incomplete |
| C01 | P0 | Resume failed payment webhook processing | Done |
| I03 | P0 | Retain dirty state when local persistence fails | Implemented; verification incomplete |
| M01 | P0 | Make message acceptance atomic and retry-safe | Implemented; verification incomplete |
| M02 | P0 | Acknowledge only after durable client persistence | Done |
| R02 | P0 | Authorize and bound typing, reset, and location frames | Done |
| S01 | P0 | Authorize receipt reads and writes | Done |
| S02 | P0 | Validate sender and recipient devices on all message paths | Done |
| S03 | P0 | Make revocation persistent and device-bound | Done |
| S04 | P0 | Replace the false recovery lockout security boundary | Open |
| A03 | P1 | Support java.time on API 24/25 | Done |
| A04 | P1 | Remove destructive Room upgrade fallback | Open |
| C02 | P1 | Make worker health reflect returned failures and staleness | Implemented; verification incomplete |
| C04 | P1 | Keep a durable record of story objects still requiring deletion | Implemented; verification incomplete |
| E01 | P1 | Reconcile crypto assurances with current code and executable gates | Open |
| G01 | P1 | Build a shared material contract and capability-based Android renderer | Open |
| I01 | P1 | Move chat persistence off the main actor and page history | Open |
| M03 | P1 | Bound and authorize reconnect backlogs | Done |
| P01 | P1 | Stop unrelated routes sharing the host-thread throttle | Done |
| P03 | P1 | Handle every Express 4 async rejection and input error | Done |
| Q01 | P1 | Repair the test baseline without hiding regressions | Done |
| Q02 | P1 | Add quality gates before deployment | Implemented; verification incomplete |
| Q03 | P1 | Separate native development and release service configuration | Open |
| Q04 | P1 | Deploy verified artifacts with readiness, draining and rollback | Open |
| R01 | P1 | Use the conference grant format in the actual relay | Implemented; verification incomplete |
| R03 | P1 | Authenticate before registering sockets; handle slow consumers | Implemented; verification incomplete |
| R05 | P1 | Serialize conference admission under the participant cap | Open |
| S05 | P1 | Verify database TLS identity | Done |
| S06 | P1 | Make device linking claims atomic | Done |
| U01 | P1 | Await Android sheet dismissal before removing it | Implemented; verification incomplete |
| U02 | P1 | Correct sheet initial detents and entrance position | Implemented; verification incomplete |
| U03 | P1 | Restore system Back in custom dialogs | Implemented; verification incomplete |
| U04 | P1 | Finish the photo viewer's gesture lifecycle | Open |
| W01 | P1 | Respect Cancel when resolving a report | Done |
| W02 | P1 | Prevent stale admin list responses overwriting new filters | Done |
| W03 | P1 | Remove closed mobile navigation from the focus order | Done |
| A05 | P2 | Cancel network work when its coroutine is cancelled | Done |
| C03 | P2 | Hold durable cleanup claims beyond the selection transaction | Implemented; verification incomplete |
| G02 | P2 | Reconcile design tokens before generating more variants | Open |
| I02 | P2 | Bound avatar memory and avoid synchronous disk misses in UI | Open |
| M04 | P2 | Stabilize history pagination and measure receipt aggregation | Open |
| P02 | P2 | Make limiter windows atomic and rejection work cheap | Done |
| P04 | P2 | Bound pool, cache, and request latency before scaling | Open |
| Q05 | P2 | Serialize migrations and detect edited history | Implemented; verification incomplete |
| Q06 | P2 | Optimize Android release builds with measured safeguards | Open |
| R04 | P2 | Make presence correct across relay instances | Implemented; verification incomplete |
| R06 | P2 | Establish authoritative game ownership before horizontal scaling | Open |
| U05 | P2 | Remove stale iOS tab timers and honor reduced motion | Open |
| U06 | P2 | Make native typography scale and materials stay legible | Open |

## Supporting evidence

Detailed reproduction, tests and limitations: [continuation evidence](audit-evidence/continuation-2026-09-06.md), [API throttle evidence](audit-evidence/api-throttles.md). The [issue register](../plans/app-audit-2026-09-05/01-ISSUE-REGISTER.md) remains the per-issue ledger. Follow [migration rollout instructions](../infrastructure/deployment/MIGRATIONS.md) before using the new runner against an old deployment.
