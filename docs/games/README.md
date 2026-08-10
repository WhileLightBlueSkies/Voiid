# Voiid Games — per-game docs

> **Date:** 2026-08-10
> **Supersedes the per-game sections of** [`../GAMES_AUDIT.md`](../GAMES_AUDIT.md) (2026-08-07). That audit is still the best system-wide read; a lot of its P0/P1 list has since shipped and this folder records what is actually true today.

One file per game. Each answers the same three questions: **what exists**, **what is missing**, **what would make people replay it**.

| Doc | Game | State today |
|---|---|---|
| [`SNAKE.md`](./SNAKE.md) | Snake | The flagship. One real bug left (frame stutter, §2), thin meta-game |
| [`TICTACTOE.md`](./TICTACTOE.md) | Tic Tac Toe | Complete and correct, zero reason to play twice |
| [`RPS.md`](./RPS.md) | Rock Paper Scissors | Complete, needs a read-your-opponent layer to be a game |
| [`CRICKET.md`](./CRICKET.md) | Hand Cricket | Best-designed of the three turn-based games, unexplained to new players |
| [`TICTACTOE_WIN_LINE.md`](./TICTACTOE_WIN_LINE.md) | Tic Tac Toe | Drawing a line through the winning three — `line` is on the wire, no stroke is drawn |
| [`SOUND_DESIGN.md`](./SOUND_DESIGN.md) | All | Replacing the synthesised retro palette with realistic audio: crowd, wicket, chalk, one shared catch |
| [`CROSS_CUTTING.md`](./CROSS_CUTTING.md) | All | Rematch, history, progression, AFK — the gaps that are not any one game's fault |
| [`NEW_GAME_IDEAS.md`](./NEW_GAME_IDEAS.md) | — | Ranked ideas for what to build next, with why each one is sticky |
| [`BACKEND_HOSTING.md`](./BACKEND_HOSTING.md) | — | Answer to "should games get its own server?" |
| [`EXECUTION_PROMPT_SOUND_AND_FIXES.md`](./EXECUTION_PROMPT_SOUND_AND_FIXES.md) | — | **Hand-off prompt** — scoped to sound rework + fixing the four existing games, nothing new |
| [`EXECUTION_PROMPT_NEW_GAME_DOCS.md`](./EXECUTION_PROMPT_NEW_GAME_DOCS.md) | — | **Hand-off prompt** — write full design docs for the eight future games (docs only, no code) |

---

## What changed since the 2026-08-07 audit

Verified in the code today, so the audit's P0/P1 list should not be re-read as a to-do:

| Audit item | Status |
|---|---|
| P0 — relay throttles game input to 2/s | **Fixed.** `GAME_MAX_FRAMES_PER_WINDOW` is 1800 ([`backend/websocket/src/index.ts:154`](../../backend/websocket/src/index.ts#L154)) |
| P1 — camera rigidly locked to head | **Fixed both platforms.** Exponential follow spring, `tau = 0.08` on both |
| P1 — respawn teleport lerped | **Fixed.** Cut at 300 world units on both |
| P1 — iOS missing `CameraMemory` guard | **Fixed.** `lastFocus` in `stepCamera` |
| P1 — Redis write amplification per steering frame | **Fixed.** `handleInput` skips persist when `live` |
| P1 — no audio anywhere | **Fixed.** `GameAudio` on both platforms, ~70 iOS / ~62 Android call sites |
| P1 — Android has no haptics | **Fixed.** `GameHaptics.kt` |
| P1 — Android drops Snake events | **Fixed.** `parseSnake` builds `SnakeEvent` list |
| P1 — Snake online passes no bots | **Fixed.** friend path passes `bots: 5` |

**Still open, and the reason this folder exists:**

- **The render clock is still re-anchored to frame arrival time on every frame** — the actual root cause of the stutter, still unfixed on both platforms, and now *worse* because `interpDelay` was cut from 0.25 s to 0.15 s. Full fix in [`SNAKE.md`](./SNAKE.md) §2.
- No rematch, no match history UI, no post-match summary, no progression, no AFK handling. See [`CROSS_CUTTING.md`](./CROSS_CUTTING.md).
- Six of the ten planned games unbuilt.
