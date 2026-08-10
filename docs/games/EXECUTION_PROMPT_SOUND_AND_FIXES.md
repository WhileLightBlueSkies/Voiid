# Execution prompt — sound rework + existing-game fixes

> Paste this to an AI coding agent working in the Voiid repo.
>
> **Scope is deliberately narrow: fix and polish the four games that already exist, and replace the sound palette. Do not build new games, new screens, or new features.**

---

## What you are and are not doing

**IN SCOPE — only these two things:**

1. **Sound.** Replace the synthesised retro palette with realistic recorded audio, per [`docs/games/SOUND_DESIGN.md`](./SOUND_DESIGN.md).
2. **Fixes to the four shipped games** (Snake, Tic Tac Toe, Rock Paper Scissors, Hand Cricket) — the Snake frame stutter and the Tic Tac Toe win line, plus the small defects listed in §4.

**OUT OF SCOPE — do not start any of these, even if a doc recommends them:**

- Any new game (Ultimate TTT, Sea Battle, Word Duel, Ludo, Air Hockey, anything in [`NEW_GAME_IDEAS.md`](./NEW_GAME_IDEAS.md))
- Rematch, match history UI, post-match summary, progression, daily challenge, head-to-head stats ([`CROSS_CUTTING.md`](./CROSS_CUTTING.md) is **background only** for this task)
- The Games-tab flow rebuild, Continue strip, multi-opponent picker
- Backend hosting changes ([`BACKEND_HOSTING.md`](./BACKEND_HOSTING.md) — background only)
- Minimap, kill feed, boost meter, arena variety, bot skill scaling

If you finish everything in scope, **stop and report**. Do not pick up the next item from a priority list.

---

## Read before writing any code

1. [`docs/games/SOUND_DESIGN.md`](./SOUND_DESIGN.md) — the full sound spec. **This is the primary document for this task.**
2. [`docs/games/SNAKE.md`](./SNAKE.md) §2 — the frame stutter, root-caused, with drop-in code
3. [`docs/games/TICTACTOE_WIN_LINE.md`](./TICTACTOE_WIN_LINE.md) — the win line, geometry and timing
4. [`docs/games/README.md`](./README.md) — what has already been fixed, so you don't redo it
5. [`docs/GAMES_AUDIO.md`](../GAMES_AUDIO.md) — the **engine** design. Still accurate and still in force; `SOUND_DESIGN.md` changes only *what the sounds are*, not how they play.

Do not re-derive the diagnosis in these documents. They cite exact files and line numbers. Verify against current code (line numbers may have shifted), then build.

---

## Current state — verified, do not redo

The 2026-08-07 audit's P0/P1 list is largely **already fixed**. Confirmed in code:

| Item | State |
|---|---|
| Relay input throttle (P0) | Fixed — `GAME_MAX_FRAMES_PER_WINDOW` is 1800 |
| Camera follow spring, teleport cut, origin-pin guard | Fixed, **both** platforms, constants matched |
| Redis write amplification per steering frame | Fixed |
| Audio **engine** | **Fully built and wired on both platforms.** `GameAudio.swift` / `GameAudio.kt`, ~70 iOS and ~62 Android call sites |
| Android haptics | Fixed — `GameHaptics.kt` |
| Android Snake event parsing | Fixed |
| Snake online bots | Fixed — friend path passes `bots: 5` |

**Read that fourth row carefully.** The audio engine, preloading, voice pool, call-ducking, mute toggle and per-sound cooldowns all exist and work. **Your sound task is asset replacement plus a small number of new trigger call sites — it is not engine work.** Do not rewrite `GameAudio`.

---

## Ground rules

- **Small, buildable commits, one concern each.** A commit mixing an unrelated refactor with a fix is not acceptable — split it.
- **Verify before committing.**
  - iOS: `xcodebuild -project apps/ios/Voiid/Voiid.xcodeproj -scheme Voiid -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build`
  - Android: `./gradlew :app:compileDebugKotlin` minimum, `assembleDebug` if possible
  - Backend: `npx tsc --noEmit` in the touched package (backend work is unlikely in this task)
- **If a toolchain is unavailable in your environment, say so explicitly in the commit message.** Never imply verification that did not happen.
- **Never invent a fact about this codebase.** Read the file. Don't guess at SwiftUI/Compose API shapes — iOS 18.0 deployment target, Android minSdk 24 / compileSdk 36.
- **Keep constants identical across platforms.** The two Snake renderers were ported line-for-line including their bugs; port fixes line-for-line too. Divergent constants are how two builds of one game come to feel different.
- **Ask before sourcing any third-party audio asset.** See §2.0 — licensing is a real liability and is the user's decision, not yours.

---

# §1 — Snake frame stutter (do this first)

**Spec:** [`SNAKE.md`](./SNAKE.md) §2. The whole section, including §2.6's verification steps.

The reported symptom is "the game pauses between frames" on both iOS and Android. Root cause is identified: the render clock is rebuilt from the newest frame's **arrival time** every frame, feeding all network jitter back into the picture — and `interpDelay` was cut from 0.25 to 0.15, leaving no margin to survive it.

**Note the contradiction and resolve it:** the doc comment directly above the iOS `interpDelay` constant argues for 2.5 ticks and explains this exact failure mode ("that hold-jump cycle IS the jitter") while the code holds 1.5. Restore the value; do not delete the comment.

Four commits, in this order:

1. **Free-running render clock**, iOS — `advanceClock` per [`SNAKE.md`](./SNAKE.md) §2.4 Fix 1. Drop-in code is in the doc.
2. **Same, Android** — line-for-line port. Use `withFrameNanos`'s value as the clock source, not `elapsedRealtime()`. **All constants identical to iOS** (0.5 resync threshold, 0.10 rate clamp, 0.5 drift gain).
3. **`interpDelay` back to 0.25** on both platforms, same commit.
4. **Bounded 100 ms extrapolation** when the buffer runs dry, both platforms (Fix 3).

Then separately:

5. **Fix the `snakeFramesSnapshot` data race** (iOS, [`SNAKE.md`](./SNAKE.md) §2.5). It is `nonisolated(unsafe)`, written on the main actor, read from the display-link thread. The comment defending it is **wrong about why it is safe** — value semantics do not make the assignment atomic. Use an `os_unfair_lock`-guarded accessor or a two-slot buffer with an atomic index, and replace that comment with an accurate one.

**Verification is not optional here.** Follow [`SNAKE.md`](./SNAKE.md) §2.6: log `renderT` deltas before and after (they should stop swinging), and confirm the arena border and food field are rock steady — they are static world geometry, so if anything about them moves, the clock is still wrong.

---

# §2 — Sound rework

**Spec:** [`SOUND_DESIGN.md`](./SOUND_DESIGN.md), in full.

## §2.0 Licensing — blocks everything else

**Stop and ask the user** which route they want before sourcing a single file: CC0 from Freesound, a commercial library licence, or recording the assets themselves. Do not download anything until they answer.

Whatever the answer, create and maintain `tools/gamesounds/LICENSES.md` with source URL, licence, author and retrieval date **per file, as files are added.** Reconstructing provenance for 40 clips afterwards is how projects ship audio they cannot defend.

## §2.1 The hard constraints — read twice

- **Every asset must be MONO.** [`GameAudio.swift`](../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift) documents that a stereo buffer scheduled onto the mono-wired bus is a **hard AVAudioEngine crash** — an ObjC exception that `try?` cannot catch, so the process dies. This was the Snake-screen crash. **A stereo asset will crash the app.** Check every file's channel count before committing it.
- **Do not delete `synth.py`.** It stays as the source for UI sounds (`tap`, `sheet_open/close`, `error`, `match_found`, `invite_arrive`, `countdown_*`) and all of Snake's abstract palette. Update its docstring so the split is explicit.
- **Do not make Snake realistic** ([`SOUND_DESIGN.md`](./SOUND_DESIGN.md) §4.2). There is no real-world referent for a neon snake eating a pellet. Snake changes in exactly one way: layer the shared `catch` under `kill`.
- Keep the existing `GameAudio` API. New sounds are new files plus new call sites, nothing more.

## §2.2 Order of work

1. **`catch.wav`** ([`SOUND_DESIGN.md`](./SOUND_DESIGN.md) §3) — the shared sound, one file, played unmodified in all four games. Every other sound is designed around its character, so it comes first. Wire it at the four moments in the §3 table.
2. **Chalk set for Tic Tac Toe** (§4.3) — `chalk_x_1..3`, `chalk_o_1..3`, `chalk_line`, `chalk_stub`, `chalk_erase`. X sounds like **two strokes**, O like **one continuous sweep** — this distinction is the point, not a detail. Replaces the existing `mark_x` / `mark_o` call sites.
3. **Win-line sound + animation together** — see §3 below. They are one feature and must be timed against each other.
4. **Crowd bed + intensity curve** (§4.1) — the biggest single upgrade in the app. Ship the looping bed and its gain curve *before* the reaction one-shots; the bed alone transforms the game. Drive intensity from `target` / `ballsBowled` / `overs` / `wickets`, all already serialized. Use the existing dedicated `loopVoice` (built for Snake's `boost_loop`), and register the bed with `release(for:)` so it frees on match exit.
5. **Wicket stack** (§4.1) — `catch` + `wicket_timber`, then `crowd_roar` **delayed 120 ms**. The delay is what sells it; simultaneous playback reads as one mushy noise.
6. **Remaining cricket** — bat contacts, dot ball, innings break, match end.
7. **Snake `catch` layer** (§4.2) — one line, plus keeping border-death distinct (no `catch` — you crashed, you weren't caught).
8. **RPS hand sounds** (§4.4).
9. **Mastering pass over the complete set** (§6) — **last, over everything at once**, never per-file as you go. Consistency can only be judged against the full palette. §6 lists all six requirements; the mono one is repeated in §2.1 above because it crashes the app.

**Steps 1-3 are a complete shippable slice.** If the chalk lands, the approach is proven. Consider pausing there for the user to hear it before continuing to the crowd work.

## §2.3 Audition properly

Test on a **phone speaker, at low volume, in a noisy room** — that is where this app is used. Sounds chosen on headphones consistently fail there: sub-bass vanishes and anything above ~4 kHz turns harsh.

---

# §3 — Tic Tac Toe winning line

**Spec:** [`TICTACTOE_WIN_LINE.md`](./TICTACTOE_WIN_LINE.md), in full.

The engine already serializes `line` (the winning triple) specifically so the client need not re-derive the win — and both clients currently use it **only to swell the three cells**. No stroke is drawn through them.

Build the drawn stroke: centre-to-centre with 35% overshoot, `.trim` / `PathMeasure` animation at **340 ms** ease-out, winner's colour, ~1.4× the mark stroke width.

**The 120 ms hold matters most.** Firing the line on the same frame as the winning mark makes the two read as one blurred event and the player never registers which move won. Follow the sequencing table in §2.2 exactly.

Also in scope from that doc: the draw treatment (§2.3), success haptic on stroke **completion** not start (§2.4), and reduce-motion support (§2.5).

Pure client-side presentation — **no engine change, no new frame, no serialization change.**

---

# §4 — Small fixes to existing games

Each is small and self-contained. Do them after §1-§3.

1. **Reduce-motion support for shipped motion.** Hitstop and screen shake shipped without an opt-out ([`CROSS_CUTTING.md`](./CROSS_CUTTING.md) §13). For a motion-sensitive player that is a game they cannot play. Swap slow-mo and shake for a flash; keep the information, drop the vestibular load. Both platforms.
2. **Sound and haptics toggles in game settings** ([`CROSS_CUTTING.md`](./CROSS_CUTTING.md) §12). `GameAudio.isMuted` already exists and persists — it just has no UI. Now that realistic audio ships, this is genuinely necessary.
3. **Extract Android's Tic Tac Toe board** into its own composable, mirroring iOS's `TicTacToeBoard.swift`. Needed anyway because the win line is used by both the online and bot screens. Do this **as part of §3**, not separately.
4. **Draw-specific copy and sound in Tic Tac Toe** ([`TICTACTOE.md`](./TICTACTOE.md) §2.2). A draw is the expected outcome between competent players and currently shares the loss treatment. Pairs with `chalk_erase` from §2.

---

## Reporting

When you finish, report:

- What was built and verified, per platform, with the actual build command output
- Anything you could **not** verify because a toolchain was unavailable — explicitly
- Any place the docs disagreed with the code, and which you trusted
- Anything in scope you did not complete, and why

Do not report work as done that you could not build. If tests fail, say so and show the output.
