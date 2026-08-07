# Execution prompt — Voiid Games remaining work

> Paste this to an AI coding agent (Claude Code or similar) working in this repo to continue the games work. It assumes the branch `games/audit-fixes` already exists with 7 commits on it — check `git log --oneline main..games/audit-fixes` first; if that branch or those commits are missing, read this prompt's "Already done" section as background only and start from §1.

---

## Context you need before touching anything

Four documents specify this work in full. **Read them before writing code, not after:**

1. [`docs/GAMES_AUDIT.md`](./GAMES_AUDIT.md) — what's built vs. planned, every missing screen, the flow rebuild, prioritised build order
2. [`docs/GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) — Part A (input freeze) and Part B (camera flicker), both root-caused
3. [`docs/GAMES_AUDIO.md`](./GAMES_AUDIO.md) — sound design + audio engine spec for both platforms
4. [`docs/GAMES_ANIMATION.md`](./GAMES_ANIMATION.md) — animation bible for both platforms, tiered for the Android API split

Do not re-derive any of the diagnosis in those documents. They cite exact files and line numbers. Trust them, verify against current code state (line numbers may have shifted if other work has landed since), and build.

## Already done (branch `games/audit-fixes`, 7 commits, do not redo)

| Commit | What |
|---|---|
| `ea50fdb` | The four docs above |
| `8ed3122` | **P0 fix**: relay `GAME_MAX_FRAMES_PER_WINDOW` raised 120→1800/min in `backend/websocket/src/index.ts`, plus a one-shot drop log |
| `83ff2f8` | Games service: stopped persisting the full Snake world to Redis on every steering input (`backend/games/src/index.ts`) |
| `22b8680` | iOS: camera follow spring + teleport-cut + origin-pin guard (`SnakeMetalView.swift`) |
| `7fe85f6` | iOS: pause steering while dead (respawn starvation) + coalesce queued `game_input` by match id (`GamesEngine.swift`, `WebSocketClient.swift`) |
| `4d95bff` | Android: same two fixes ported (`GamesEngine.kt`, `WebSocketClient.kt`) + `events` field now parsed (was silently dropped) — **NOT build-verified, no gradle available when written** |
| `c07fd50` | 43 synthesized sound files generated (`tools/gamesounds/synth.py` + output under both apps) — **files exist, nothing plays them yet** |

The iOS commits were verified with `xcodebuild -project apps/ios/Voiid/Voiid.xcodeproj -scheme Voiid -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build` — confirm it still passes before building on top. **The Android commit was written blind and must be built once before anything else lands on Android** — that is step 0 below, not optional.

**Not done yet:** the free-running render clock (`GAMES_SNAKE_BUGS.md` Part B §B4.1 — the camera spring mitigates but does not fix the root cause), the `GameAudio` engine on either platform (files exist, nothing plays them), any animation work beyond the camera spring, and everything in the audit's P1 through P5.

---

## Ground rules for this whole task

- **Work in small, buildable commits, one concern each**, exactly like the 7 already on the branch. A commit that mixes an unrelated refactor with a bug fix is not acceptable — split it.
- **Verify before committing.** iOS: `xcodebuild build` for the Voiid scheme. Android: `./gradlew :app:compileDebugKotlin` at minimum, a full `assembleDebug` if time allows. Backend: `npx tsc --noEmit` in the touched package, plus `npm test` in `backend/games` (the Snake engine has a real test suite — use it). **If a toolchain is unavailable in your environment, say so explicitly in the commit message**, the way `4d95bff` does — do not imply verification that didn't happen.
- **Never invent a fact about this codebase.** If you need to know something (a type, a call site, a build script), read the file. Don't guess at Compose/SwiftUI API shapes — check the version pinned in `libs.versions.toml` / the deployment target in `project.pbxproj` first (iOS 18.0, Android minSdk 24 / compileSdk 36 — already confirmed, see the animation doc §1).
- **Match the existing comment style.** This codebase writes WHY, not WHAT, in dense paragraph comments explaining the non-obvious reasoning and citing the specific incident or constraint that produced the code. Look at any file you're editing before adding to it and match that voice — a generic `// increments the counter` comment does not belong here.
- **Don't scope-creep.** Each doc has a "build order" section. Follow it. Resist the urge to also refactor something adjacent that looks messy — flag it in a commit message or a follow-up note instead.
- **Push in parts, not one giant branch dump.** After each logical group of commits (roughly: one numbered step from a doc's build order, or one phase), push the branch so progress is visible and recoverable: `git push -u origin games/audit-fixes` (first push), `git push` thereafter. Do not force-push. Do not merge to `main` — leave that decision to the human.
- **If you hit a decision the docs don't answer** (e.g., exact particle count tuning, exact colour values not already in the codebase), make the smallest reasonable choice, note it in the commit message as a `NOTE:` line, and move on. Do not block on it.

---

## Step 0 — verify the inherited state (do this first, before anything else)

1. `git log --oneline main..HEAD` — confirm the 7 commits above are present.
2. iOS: run the `xcodebuild` command above. Must succeed.
3. Android: run whatever Kotlin compile check is available. **This is the first real verification of `4d95bff` — if it fails, fix it in a new commit before proceeding; do not amend.**
4. Backend: `cd backend/games && npm test`, `cd backend/websocket && npx tsc --noEmit`. Both must pass.
5. Push what you have so far if the remote doesn't already have this branch: `git push -u origin games/audit-fixes`.

If any of the above fails, fixing it **is** step 1. Do not proceed to new feature work on a broken inherited state.

---

## Step 1 — finish Part B of the Snake bug (render clock)

`GAMES_SNAKE_BUGS.md` Part B §B4.1. The camera spring (already landed) treats the symptom; this fixes the cause. Implement the free-running, rate-adjusted render clock on **both** platforms — the doc gives working Swift and describes the Kotlin port; write both, keep the constants (`cameraTau`/`interpDelay` equivalents) identical between them.

Also from Part B, smaller and independent — do these as separate commits:
- §B4.4 — stamp `arrivedAt` at the socket layer on iOS, not after the main-actor hop
- §B4.5 — fix the `snakeFramesSnapshot` data race (`nonisolated(unsafe)` → an actual synchronization primitive)
- §B4.6 — bounded extrapolation when the jitter buffer runs dry

Verify per §B6 of the doc: log `renderT` deltas before/after, confirm the arena boundary is now visually static.

---

## Step 2 — `GameAudio` engine, both platforms (`GAMES_AUDIO.md` §3-5, §13 steps 3-6)

The 43 sound files exist and are bundled; nothing calls them. Build:

- iOS: `AVAudioEngine` + pooled `AVAudioPlayerNode`/`AVAudioUnitVarispeed`, `.ambient` category, **never active during a call** (query call state first — §2's hard rule, with the explicit test case at the end of that section)
- Android: `SoundPool` + `AudioAttributes(USAGE_GAME)`, ringer-mode check mirroring `CallTones.kt`, audio focus request/abandon

Wire the Snake set first (§13 step 5): `eat`, `boost_start`/`boost_loop`/`boost_end`, `kill`, `death`, `spawn`, `border_warn`. Use the existing `events` field (now parsed on both platforms) as the trigger source — the plumbing for this already exists in both `GamesEngine`s.

**Before moving past this step**, do the call-audio test by hand or describe exactly how you verified it: start a Snake match, receive/answer a call, confirm silence and no routing change. This is the one place in the whole task where "I wrote code that should do this" is not sufficient — say how it was checked.

Then: board-game sounds (§13 step 7), shared UI sounds (step 8), settings screen with sound/haptic toggles (step 9).

---

## Step 3 — Animation Phase 0 and Phase 1 (`GAMES_ANIMATION.md` §11)

Phase 0's steps 1-2 (camera spring, render clock) are step 1 of this prompt. Phase 0's remaining prerequisite:

- Step 3: confirm Android's `events` parsing (landed in `4d95bff`) is actually consumed — it's parsed, nothing renders from it yet.
- Step 4: Android render-tier detection (`Build.VERSION.SDK_INT` branch, §4) — do this before any shader/blur work so later steps can branch on it.

Then Phase 1, highest value per unit of work, in order:
5. Additive bloom pass, both platforms (§5.1)
6. Particle system + wire the four Snake events (§5.3) — pairs naturally with the audio wiring in Step 2 above; consider doing them together since both consume the same `events` array
7. Camera look-ahead + mass zoom + screen shake (§5.2) — extends the spring from Step 1
8. Hitstop + slow-mo on kill/death (§5.4)
9. Game haptics, both platforms (§8) — iOS: `CHHapticEngine`, Android: tiered `VibrationEffect`

---

## Step 4 — everything else, by priority (`GAMES_AUDIT.md` §10)

Once the above is solid, work down the audit's own prioritised list. It is already ordered; don't reorder it without a reason:

- **P1 remainder**: post-match summary + online rematch, match history screen (`GET /games/matches` exists, wire it), real-time invite delivery (replace the 20s poll), Snake online default bots
- **P2**: the flow rebuild — one-tap play, continue strip, combined setup sheet with multi-select opponents
- **P3 remainder**: minimap, kill feed, boost meter, danger vignette, AGSL shader tier for Android
- **P4/P5**: depth features and new games, in the audit's listed order

---

## Reporting back

After each pushed group of commits, or at natural stopping points, summarize in plain text: what was built, what was verified and how, what's still open, and anything you deviated from the docs on and why. Do not wait until everything is done to report — this is long enough work that periodic checkpoints matter more than a single final summary.
