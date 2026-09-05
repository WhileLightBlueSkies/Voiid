# 13 — Release, CI and operations

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

## Q01 — Repair the test baseline without hiding regressions

**Priority:** P1 · **Evidence:** Observed failures · **Dependencies:** None

**Location:** `backend/api/test/callConference.test.ts:394` returns `rows([])` after invite insertion, while `routes/calls.ts:1040` expects `RETURNING user_id`; `backend/games/src/engine/registry.test.ts:77` expects 10–15Hz while `engine/snake/index.ts:83` sets 20Hz.

API tests: 192/196 passed, four conference failures. The games script stops at its registry mismatch; subsequent suites pass when run independently. The conference mock returning no inserted row explains the observed false full-room response; this does not prove live conference admission works correctly (R05 still needs a real DB race test).

**Fix:** update the fake DB to model the actual query result/cap semantics, then add a real isolated DB test for concurrency. Reconcile Snake's agreed simulation/broadcast-rate contract with current 20Hz behavior; change stale assertions/docs only if behavior is intended and benchmarked. Keep meaningful behavior assertions and remove tests that merely copy helpers. Ensure one early suite failure does not hide reporting from other independent suites.

**Done when:** root tests and independent relevant suites pass; R01/R05 production paths are covered; no assertion is weakened merely to get green. Record environment/tool versions and complete results.

## Q02 — Add quality gates before deployment

**Priority:** P1 · **Evidence:** Confirmed gap · **Dependencies:** Q01

**Location:** `.github/workflows/deploy-dev.yml:25`; `deploy-main.yml:33`; root `package.json`; absent claimed Rust audit workflow.

The workflows SSH directly to deployment without a test/typecheck/native quality gate. Mobile build, migration, accessibility and performance checks are not represented here.

**Fix:** add PR checks for backend/shared types, web/admin typecheck/build, relevant unit/integration tests, locked Rust tests/advisories, and isolated migration replay. Add Android lint/unit/release compile and iOS simulator build/tests using available signing-independent schemes. Run expensive device/soak/performance jobs on scheduled or release paths with preserved artifacts. Pin runtime/toolchain versions and ensure deployment uses the exact verified commit/artifact. Restore missing local web dependencies in an isolated environment; do not treat missing installed React/Next as thousands of source bugs.

**Done when:** a deliberate failing authorization test blocks deployment, a Rust advisory is reported, clean checkout builds are reproducible, and checks cannot be bypassed by a different deployed SHA. Keep secret values out of artifacts.

## Q03 — Separate native development and release service configuration

**Priority:** P1 · **Evidence:** Confirmed configuration gap · **Dependencies:** Environment endpoints supplied by project configuration

**Location:** iOS `Networking/APIClient.swift:16`; Android `net/ApiClient.kt:23`; Android `app/src/main/AndroidManifest.xml:92`.

Both native clients hardcode the development host, with no assignment overriding it found in app sources. Android also enables cleartext traffic globally. This is acceptable local-development plumbing but not a reliable release environment boundary.

**Fix:** introduce explicit debug/staging/release build configurations for HTTPS/WSS/API version. Do not guess the production hostname. Reject a release build that uses a dev/local host or missing required configuration. Disable release cleartext and allow local debugging only through debug-specific configuration. Review backup, deep-link, push, maps and bundle/application IDs as an environment set.

**Done when:** inspect release artifacts to verify the intended hosts, trust policies and identifiers; debug still supports local development; test sign-in, push registration, deep links and forced-update behavior against the correct environment.

## Q04 — Deploy verified artifacts with readiness, draining and rollback

**Priority:** P1 · **Evidence:** Confirmed gap · **Dependencies:** Q02, C02

**Location:** `infrastructure/deployment/deploy-dev.sh:28`, `:31`, `:41`, `:55`, `:82`, `:89`; `backend/games/src/index.ts:962`; API `src/index.ts:325`; websocket service lifecycle.

Deployment mutates the active checkout, builds and migrates on the host, then restarts services. API health is required; worker failure only warns, and games/websocket readiness is not checked. Games health always returns 200. API/websocket have no explicit coordinated drain protocol. There is no automatic verified artifact rollback in this script.

**Fix:** build immutable artifacts from a tested commit, stage beside the current release, and perform backward-compatible expand/contract migrations. Validate API DB/Redis readiness, websocket handshake/replay, games dependencies/loop health and worker freshness. Drain HTTP and sockets with a bounded deadline; stop claiming work and flush durable state before shutdown. Keep prior artifacts and a tested rollback procedure. Serialize deploys on the host as well as CI. Pin/verify SSH host identity instead of trusting a fresh unverified keyscan alone.

**Done when:** failed readiness never advertises successful deployment; rollback returns to the previous compatible artifact without data loss; active sends/calls/games recover from a staged restart; deploy logs identify the exact serving SHA for every service.

## Q05 — Serialize migrations and detect edited history

**Priority:** P2 · **Evidence:** Confirmed gap · **Dependencies:** Disposable database replay

**Location:** `infrastructure/deployment/migrate.mjs:42`, `:49`, `:58`.

Migration tracking stores filenames, not checksums, and no global migration lock is acquired. Concurrent runners can both select the same pending migration. A modified already-applied file is silently skipped. Repeated numeric prefixes are not inherently broken here because the runner uses complete filenames; do not rename historical migrations casually.

**Fix:** acquire a Postgres advisory lock for the runner, store/verifiably baseline checksums, and reject drift with an actionable error. Test full lexical replay and upgrade from a deployed-schema fixture. Add explicit handling for migrations that must run outside transactions. Reconcile README's Supabase CLI instructions with the actual `database/migrations` runner and tracked migration table.

**Done when:** concurrent runners apply each migration once; modified history is detected; clean and upgrade paths yield the same schema; failed migrations leave no false applied record. Never run destructive replay on production.

## Q06 — Optimize Android release builds with measured safeguards

**Priority:** P2 · **Evidence:** Confirmed build gap; performance unmeasured · **Dependencies:** Q02, A03

**Location:** `apps/android/app/build.gradle.kts:51` uses `isMinifyEnabled = false`; no benchmark/baseline-profile module was found in the surveyed Android project.

**Fix:** introduce a benchmarkable release variant and Baseline Profiles for startup/chat/navigation. Enable shrinking/optimization incrementally with precise keep rules for UniFFI/JNA, serialization, Firebase, WebRTC/LiveKit and reflection. Validate ABI outputs and packaged native symbols. Keep the existing app-bundle/ABI-split approach; do not remove libraries merely because they are large without proving call compatibility.

**Done when:** release startup/scroll and package-size measurements improve or remain within agreed budgets; native crypto, calls, maps, media export and background notifications work on each shipped ABI; mapping/symbol files are retained for crash diagnosis.
