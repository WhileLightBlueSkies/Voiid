# 14 — Validation evidence

Date: 2026-09-05 · Source baseline: `a2e24e5` · Local working tree; no deployment or production data access.

## Checks performed

| Check | Result | Interpretation |
|---|---|---|
| `npm test` | Exit 1 | Baseline is not green |
| API tests | 196 total; 192 pass; 4 fail | Conference escalation test failures; details below |
| Games registry test | One failure | Expects Snake tickHz 10–15; source tuning is 20 |
| Snake engine tests, run independently | Exit 0 | Suite passes despite registry blocking the normal chain |
| Cricket engine tests, independently | Exit 0 | Pass |
| Sea Battle engine tests, independently | Exit 0 | Pass; lost-secret warning is from a tested failure case |
| Games queue test, independently | 4 pass; 0 fail | Pass |
| Ludo engine tests, independently | 45 pass; 0 fail | Pass |
| `node tools/check-ludo-assets.js` | Exit 0 | No Ludo raster assets referenced |
| API, websocket, games, workers, common-utils TypeScript | All exit 0 | Typechecks pass; does not prove runtime authorization/correctness |
| Web/admin TypeScript | Exit 2 | Missing React/Next/type dependencies in this checkout; cascading JSX/module errors |
| `npm ls react next @types/react --depth=0` | Empty, exit 1 | Supports local dependency blocker interpretation |
| Initial/final working-tree review | Existing user changes preserved | This audit adds Markdown under plans only |

Typecheck command for each of the five backend/shared projects and the two web projects:

```sh
node node_modules/typescript/bin/tsc --noEmit --incremental false -p <project>/tsconfig.json
```

Independent games commands were executed with the installed `tsx` from `backend/games`, one file at a time: `src/engine/snake/snake.test.ts`, `src/engine/cricket/cricket.test.ts`, `src/engine/seabattle/seabattle.test.ts`, `src/queue.test.ts`, `src/engine/ludo/ludo.test.ts`.

## API failure detail

All four failures are in `backend/api/test/callConference.test.ts`:

1. Line 634: stranger can be added to a live 1:1 call — expected 200, received 409 with participant-cap error.
2. Line 666: escalation rewrites grant — expected grant, received null.
3. Line 734: only a participant may escalate to a reachable person — expected 200, received 409.
4. Line 762: stranger still requires a PIN after escalation — prerequisite escalation expected 200, received 409.

The fake insertion handler at line 394 returns `rows([])` while production now expects `RETURNING user_id`. That explains the observed rejection in these mock-backed tests. Fixing the fake is necessary; it does not remove the independently identified live concurrency risk or the relay's participant-grant mismatch.

## Not performed

- No native build, signing, emulator interaction, physical-device UI review, screenshots, accessibility session, or frame/thermal measurement.
- No Postgres/Redis integration environment, migration execution, load test, production penetration test, live payment, push, call, or bucket lifecycle verification.
- No fresh npm/Cargo vulnerability database scan; no Rust rebuild or cryptographic certification.
- No production secrets were read; no messages were sent; no application source fixes were applied.

Every performance figure in part 16 is a proposed target. Every source finding must still receive its task-specific verification before being marked fixed.
