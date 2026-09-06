# 15 — Scope, coverage and limitations

## Method

Repository-wide inventory; targeted first-party source reads; native material/motion/storage pattern searches; API route/middleware and trust-boundary tracing; selected deployment/migration/configuration reads; existing local test execution; backend typechecks; official platform-reference verification.

Approximately 902 first-party source files and 254,000 lines were inventoried across the principal roots. Large generated crypto bindings, SDK/vendor source, build outputs, caches, node_modules, research exports and playground outputs were excluded from deep review. The exact inventory is in part 17. Inventory coverage is not line-by-line manual coverage.

Two delegated reads supplied preliminary Android and web findings before their sessions stopped at usage limits. The primary audit independently read and verified the findings used in these plans, and completed the iOS review locally. No unverified agent assertion is treated as implementation evidence.

## Coverage by area

| Area | Inspected deeply or traced | Remaining verification |
|---|---|---|
| API/auth | Startup guards, auth middleware, account/device state, linking, recovery, receipt/message routes | All routes against adversarial integration fixtures; active deployment config |
| Message pipeline | Sender/recipient resolution, send persistence, fanout, pending/history reads and receipts | Network cut/crash tests; actual client durable acknowledgement migration |
| Database | Pool TLS/timeouts, migration runner, schema inventory, selected constraints and query shapes | Full clean/upgrade migration replay; actual query plans/index sizes/RLS/grant verification |
| Realtime | Connection lifecycle, buffer flush, typing/reset/location/game/call routing and presence | Multi-instance chaos/slow consumers; production proxy limits |
| Calls | API grant formats and admission flow; relay mismatch; existing conference tests | Native killed-state calls, conference rekey, network handover and real DB concurrency |
| Games | Worker scheduling/ownership/persistence architecture, engine registry and existing suites | Full game-rule audit, latency/cheating tests, all client render paths and tournaments |
| Android | Shared sheets/dialog/photo viewer, tab/profile materials, network client, secure prefs, backups, dates, local schema | Every screen/device/OS, release build, all lifecycle/resource ownership |
| iOS | Theme/fonts/material usage, root tabs, main-actor chat persistence, cache, local DB, API config | Every screen, notification extension concurrency, app lifecycle, Instruments and real accessibility |
| Media/stories/location | Backend routing boundaries, private/public distinction, cleanup, backup rules; relevant storage call sites | Upload caps, codec/export/playback, key lifecycle, map permission/expiry matrix |
| Communities/events/creators | Route inventory and integration seams; inherited throttle, payment settlement and report UI | All role/entitlement/inventory/moderation transitions, pagination and deletion cascades |
| Web/admin | Report cancellation, shared list hook, header disclosure, tokens/config and dependency state | Installed production build, browser accessibility, all admin role flows |
| Workers/operations | Job orchestration, health, cleanup claim lifetime, retries, deploy/migration scripts and CI inventory | Running environment, bucket lifecycle, backups/restores, alert delivery and failover |
| Rust/E2EE | Dependency/features, session/recovery/PQ gate, security notes and advisory exceptions | Fresh advisory audit, complete crate/FFI review, packaged-binary provenance, external review |

## Existing strengths and rejected findings

- API and websocket explicitly refuse production startup with the known default JWT secret or development auth bypass. The default string alone was **not** recorded as a production vulnerability.
- Message membership checks, block-aware notification fanout, bulk ciphertext insertion and content-free push already exist. Extend these; do not erase earlier fixes.
- Payment webhooks already use raw bytes and signature verification. The issue is retry state after receipt, not missing signature verification.
- Games preserve separate secret/player projections and have meaningful engine tests. Some worker paths already serialize locally or lease Ludo inputs; this is not equivalent to no concurrency controls at all.
- The old iOS `LudoColor` helper appears to mishandle alpha, but no usages were found. It was rejected as a user-visible Ludo defect; current Ludo uses a separate theme.
- Duplicate numeric migration prefixes are not, by themselves, a proven migration bug: the actual runner tracks full filenames.
- Android's current tinted glass is documented as an intentional performance compromise. The new renderer is a requested capability upgrade, not a claim that the old code secretly implemented blur.
- iOS native materials may automatically honor accessibility settings. Missing explicit environment reads alone does not prove that every system material ignores those settings.
- Missing local web dependencies explain compilation noise; no claim is made that every resulting JSX diagnostic is a source-code defect.

## What this audit does not certify

The entire product is not certified secure, fast, accessible or release-ready. No physical-device evidence or real load-capacity measurement exists from this run. The acceptance matrix deliberately includes residual coverage so another AI cannot use this document to declare untested areas complete. Historical docs/Excel parity lists are context, not trusted proof that a feature is implemented or missing today.
