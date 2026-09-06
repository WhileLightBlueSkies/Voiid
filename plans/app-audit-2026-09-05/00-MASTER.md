# Voiid — whole-app audit and execution plan

**Audit date:** 2026-09-05 · **Source baseline:** `a2e24e5` · **Status:** execution underway; see the issue register for current implementation and validation status.

## Outcome

Voiid has substantial working foundations: native Compose and SwiftUI clients, a shared Rust encryption core, Postgres persistence, realtime relaying, background cleanup, and dedicated game engines. The highest priorities are delivery correctness, authorization, recovery safety, and release verification. Visual polish should build on those foundations.

Android currently approximates glass using translucent fills and borders. The iOS app itself has only one explicit custom `glassEffect` call; its tab bar uses `.bar` material. The plan therefore establishes a consistent iOS reference and an Android implementation that gets close perceptually while meeting frame budgets. Pixel-identical behavior across Apple's proprietary renderer and every Android GPU is not a credible guarantee.

This is a repository-wide, risk-based source audit: approximately **902 first-party source files / 254,000 lines were inventoried**, with targeted inspection of critical paths and broad pattern searches. It is **not a claim that every line or every screen was manually verified**. Production configuration, physical-device behavior, load capacity, and cryptographic exploitability remain unverified. See [coverage](15-COVERAGE.md).

## Start here

1. Read [the issue register](01-ISSUE-REGISTER.md), then [baseline results](14-VALIDATION.md).
2. Execute a single issue ID at a time, following its linked part. Keep dependent API/client migrations coordinated.
3. Preserve existing behavior and user work unless the task explicitly changes it. Do not rewrite the application wholesale.
4. Record a fix only after its acceptance checks pass. A plan, a passing compilation, or a mocked test alone is not proof of a production fix.

## Parts and recommended order

| Wave | Part | Outcome | Dependencies |
|---|---|---|---|
| 0 | [13 — Release, CI, and operations](13-RELEASE-AND-OPERATIONS.md) | Reliable baseline and regression gates; execute Q01/Q02 first | None |
| 1 | [02 — Security and recovery](02-SECURITY-AND-RECOVERY.md) | Enforce device, message, session, and recovery boundaries | Baseline capture |
| 1 | [06 — Android durability](06-ANDROID-DURABILITY.md) | Prevent backup leaks, key destruction, and unsupported-device failures | Baseline capture |
| 2 | [03 — Message reliability](03-MESSAGE-RELIABILITY.md) | Durable sends, replay-safe retries, explicit acknowledgements | S01/S02/S03 |
| 2 | [05 — Realtime, calls, and games](05-REALTIME-CALLS-GAMES.md) | Correct conference grants and bounded relay behavior | S03; Q01 |
| 2 | [11 — Payments, media, and workers](11-PAYMENTS-MEDIA-WORKERS.md) | Retry-safe settlement and truthful cleanup status | S05; Q01 |
| 3 | [04 — API and database performance](04-API-PERFORMANCE.md) | Remove accidental throttles and bound dependency latency | Security contracts |
| 3 | [07 — iOS and shared storage](07-IOS-AND-STORAGE.md) | Keep disk work off rendering paths; preserve failed writes | M01/M02 for acknowledgement integration |
| 4 | [08 — Liquid Glass](08-LIQUID-GLASS.md) | One material system with tested Android capability tiers | G02 tokens before G01 rollout; A03; baseline traces |
| 4 | [09 — Motion and accessibility](09-MOTION-ACCESSIBILITY.md) | Correct sheets, gestures, dismissal, text scaling, and reduced motion | Can fix existing behavior before glass |
| 4 | [10 — Web and admin](10-WEB-ADMIN.md) | Correct cancellation, list state, and keyboard navigation | Web dependencies available |
| 5 | [12 — Encryption assurance](12-CRYPTO-ASSURANCE.md) | Reviewed protocol boundaries and maintained dependency evidence | S04; device persistence fixes |
| 5 | [16 — Product acceptance and performance](16-PRODUCT-ACCEPTANCE.md) | Physical-device, cross-platform, failure, and load evidence | Relevant fixes complete |

Supporting files: [coverage](15-COVERAGE.md), [source inventory](17-SOURCE-INVENTORY.md), [official references](18-SOURCES.md).

Wave numbers express sequencing, not duration estimates. Security, storage, and accessibility fixes should ship in small verified increments. Introduce glass through a reversible feature flag after the existing UI has a measured baseline.

## Priority and evidence vocabulary

- **P0:** release-blocking authorization, privacy, recovery, or data-integrity exposure.
- **P1:** major reliability, supported-device, operational, or user-flow defect.
- **P2:** scalability, maintainability, or polish improvement requiring measured validation.
- **Confirmed:** executable source shows the behavior; not necessarily reproduced on a deployed system.
- **Observed:** reproduced by a local check in this audit.
- **Risk:** a failure path or scaling limitation is visible, but its runtime impact needs testing.
- **Gap:** a requested capability or assurance mechanism is absent; not a measured defect.

Priorities describe remediation urgency, not CVSS scores. No production penetration testing was performed.

## Executor contract

Use repository root `/Users/baskcreative/Voiid` in this checkout. Paths inside tasks are repository-relative; relocate the root when executing elsewhere. Line numbers refer to `a2e24e5` plus the working tree observed on the audit date. Read the surrounding function and all callers before editing. If the source has moved, revalidate the issue and update the evidence rather than applying a stale patch.

For every task:

1. Set its register status to `IN_PROGRESS`; write down the current commit and the regression being reproduced.
2. Inspect relevant `AGENTS.md` and existing architectural conventions. Use an isolated branch/worktree when appropriate; preserve unrelated changes.
3. Add a meaningful regression test around actual production logic. Avoid tests that copy the implementation into a separate helper and therefore pass while production remains broken.
4. Implement the smallest coherent fix, including migrations and compatible client/server behavior where needed.
5. Run focused tests, the affected typecheck/build, and the stated failure-path or device checks. Do not run destructive tests against a live account/database.
6. Update this register with changed files, commit, test evidence, remaining limitations, and rollback notes. Use `DONE` only when required checks passed; use `IMPLEMENTED_UNVERIFIED` if physical-device or infrastructure evidence is still missing.

Allowed states: `TODO`, `IN_PROGRESS`, `IMPLEMENTED_UNVERIFIED`, `DONE`, `BLOCKED`, `SUPERSEDED`. For `BLOCKED`, record the specific missing prerequisite and the work already completed. Never label all tasks done because a parent part is done.

## Copyable AI execution prompt

```text
Work in the Voiid repository. Read plans/app-audit-2026-09-05/00-MASTER.md,
01-ISSUE-REGISTER.md, and 14-VALIDATION.md. Select the highest-priority TODO
issue whose dependencies are satisfied, unless I name an issue explicitly.
Read its entire implementation part and verify the cited source against the
current checkout. Reproduce the actual failure, implement the smallest complete
fix, and run the task's acceptance checks. Preserve existing user changes.
Keep crypto protocols and deployed wire formats compatible; do not invent a
cryptographic construction or weaken authorization to make tests pass.
Record implementation and validation evidence in the register. If a task needs
device or staging checks you cannot run, mark IMPLEMENTED_UNVERIFIED and state
exactly what remains. Continue with independent authorized work where possible.
Do not deploy, rewrite history, delete user data, or claim measured performance
without the corresponding authorization and evidence. End with what changed,
why, tests run, and material limitations.
```

## What must remain true

- Private messages, private media keys, private location fixes, and private stories remain encrypted end to end. Public Clips and public community metadata are explicitly separate product surfaces.
- A community membership, a creator follow, a shared game, or a shared conference must not silently grant private messaging access.
- Retries must not duplicate user-visible messages, payments, tickets, or game outcomes.
- No successful delivery acknowledgement before the client has durably persisted the required state.
- No destructive database fallback or silent key reset as an automatic response to a transient error.
- Android system Back, TalkBack, large text, and lower-end hardware remain first-class supported cases.
- Glass never blurs text or controls, blocks input, captures protected media, or forces an expensive rendering path on every device.

## Existing user changes to preserve

The audit began with changes to iOS `Package.resolved` and untracked Android/iOS `SeaBattleCannon` files, `Android_iOS_Parity_Gaps.xlsx`, and `docs/games/SEA_BATTLE_REPORT.md`. They were not modified. Recheck the working tree before execution because user work can continue after this audit.
