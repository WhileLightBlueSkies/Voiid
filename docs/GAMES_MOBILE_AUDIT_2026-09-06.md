# Games audit: iOS and Android

Date: 6 September 2026  
Scope: current working tree; native game screens, bot flows, shared rendering/audio, client game engines, and game-server lifecycle/rules.  
Deliverable: findings and implementation backlog. No game source code was changed.

## Executive assessment

All six registered games have iOS and Android implementations: **Tic Tac Toe, Rock Paper Scissors, Hand Cricket, Snake, Sea Battle, and Ludo**. The strongest immediate improvements are reliable match entry/recovery, less unnecessary rendering, adaptive layouts, and accessible board controls.

This is a source-code audit with an executed server regression suite, not a measured device performance certification. Frame rates, battery use, visual clipping, thermal behavior, and touch accuracy still require the device checks below. “All devices” should mean a defined supported OS/hardware matrix, with graceful quality reduction on slower devices.

Evidence labels:

- **Confirmed:** the stated behavior or omission is present in inspected source. User-visible severity may still need reproduction.
- **Risk:** code provides a plausible failure/performance path; reproduce or profile before prescribing a large rewrite.
- **Validation:** acceptance work needed to establish device quality; not a claim of an existing defect.

Priorities: **P1** fix before claiming mobile polish/reliability; **P2** next optimization/polish pass; **P3** maintenance. No production outage or device crash was reproduced.

## Coverage and existing strengths

| Game | iOS entry | Android entry | Shared rules | Existing strengths to preserve |
|---|---|---|---|---|
| Tic Tac Toe | `TicTacToeView.swift`, `TicTacToeBotView.swift` | `TicTacToeScreen.kt`, `TicTacToeBotScreen.kt` | `engine/tictactoe/index.ts` | Native cell accessibility labels; separate local bot mode |
| Rock Paper Scissors | `RpsMatchView.swift`, `RpsBotView.swift` | `RpsMatchScreen.kt`, `RpsBotScreen.kt` | `engine/rps/index.ts` | Pending opponent choices stay private; reveal presentation |
| Hand Cricket | `CricketMatchView.swift`, `CricketBotView.swift` | `CricketMatchScreen.kt`, `CricketBotScreen.kt` | `engine/cricket/index.ts` | Secret picks/toss; two rows of number controls |
| Snake | `SnakeArenaView.swift`, `SnakeMetalView.swift` | `SnakeArenaScreen.kt` | `engine/snake/index.ts` | Prediction, interpolation, food deltas, throttled HUD; iOS Metal and Android draw-only frame invalidation |
| Sea Battle | `SeaBattleView.swift`, `SeaBattleBotView.swift` | `SeaBattleScreen.kt`, `SeaBattleBotScreen.kt` | `engine/seabattle/index.ts` | Private fleet projection, placement validation, shared board art |
| Ludo | `Ludo/LudoGameView.swift` | `ludo/LudoScreen.kt` | `engine/ludo/index.ts` | Authoritative legal moves, sequence checks, bot rules, snapshot/cache paths and accessibility helpers |

Unless otherwise qualified, Swift game filenames resolve under `apps/ios/Voiid/Voiid/Games/`; Kotlin game filenames under `apps/android/app/src/main/java/com/voiid/app/main/games/`; server engine filenames under `backend/games/src/`.

Also inspected: home/setup/lobby inventory, shared settings/audio, networking entry/reset paths, queue/tick scheduling, and test registration. These shared surfaces need the end-to-end validation below; this report does not assert every supporting file was reviewed line by line. The web app includes games marketing content; it is not a third native game runtime. Its README still describes four games (`apps/web/README.md:49`); update documentation to match the six-game registry.

## Prioritized fixes

### F01 — P1 — Android performs Ludo recovery for every game (Confirmed)

**Evidence:** `apps/android/app/src/main/java/com/voiid/app/net/GamesEngine.kt:814`. Generic `open(matchId)` restores a Ludo cache and waits up to 700 ms for `_ludoV2`, then requests a Ludo snapshot, regardless of game type. iOS separates this into `openLudo`.

**Impact:** non-Ludo opens incur unnecessary waiting and a wrong-game recovery request. This does not prove the first board is delayed 700 ms: a live frame can render before `open` returns.

**Fix:** separate generic entry and Ludo entry, or route recovery by a known game slug. Stop recovery immediately after a failed join. Keep recovery bounded and cancelable.

**Accept:** each non-Ludo game opens without a Ludo snapshot request; Ludo cold entry, cached entry, and missing live-frame fallback still work.

### F02 — P1 — Prevent old async work from affecting a new match (Risk)

**Evidence:** generic `open` mutates a singleton match ID before awaiting the join (`GamesEngine.swift:843`, `GamesEngine.kt:814`). iOS bot tasks are untracked in `TicTacToeBotMatch.swift:79` and `SeaBattleBotMatch.swift:143`; their `restart` methods reset state without canceling these tasks. Cricket uses delayed closures (`CricketMatchView.swift:172,199,248`; `CricketBotView.swift:387,530,548`).

**Impact:** rapid exit/re-entry or restart during a bot delay can allow an old response, error, move, or announcement to affect the current session. Existing paused/finished checks help, but do not identify a new match generation.

**Fix:** give each opening/restart a generation token. Capture and validate it after every await/delay; own and cancel tasks on restart/disposal. Use cancellation-aware sleeps; do not continue work after a swallowed cancellation. Preserve deliberate thinking/reveal timing.

**Accept:** repeatedly restart during bot thinking and exit during join/announcements; no stale moves, sounds, errors, or score writes. Resume a paused bot turn exactly once.

### F03 — P1 — Add bounded recovery to non-Ludo multiplayer (Risk / confirmed local gap)

**Evidence:** iOS generic `open` joins without a snapshot fallback (`GamesEngine.swift:843`); the Android fallback above is Ludo-specific. Tic Tac Toe, RPS, and Cricket render loading/error/state through their match screens. Ludo already has dedicated recovery machinery.

**Fix:** trace the app-wide WebSocket reconnect contract and implement missing per-game resubscription/state retrieval. Expose loading, waiting for opponent, reconnecting, failed, and finished states distinctly. Add retry and exit to stalled entry. On retry, retain the existing match ID; do not create duplicate matches.

**Accept:** both platforms converge after connection loss, app suspension, and a missed final frame. Old sequence frames cannot roll the board back; retry never duplicates an accepted move. Test at 150–300 ms RTT and with packet loss.

### F04 — P1 — Sea Battle cannot expose individual Canvas cells to screen readers (Confirmed)

**Evidence:** `SeaBattleBoard.swift:259–299` and `SeaBattleBoard.kt:262–280` render a Canvas with pointer gestures; these board components do not supply individual cell accessibility actions/semantics.

**Fix:** add an accessible interaction layer with coordinate, known cell state, and valid action; never expose hidden opponent ships. Provide accessible placement/rotation and a selected-coordinate fire button. Keep screen-reader focus stable after state updates.

**Accept:** complete placement and a game with VoiceOver and TalkBack, including misses, hits, sunk ships, and repeated-shot prevention.

### F05 — P1 — Make dense boards accurately playable on small screens (Confirmed geometry; usability requires testing)

**Evidence:** Sea Battle divides its available board width by 10 (`SeaBattleBoard.swift:269`, `SeaBattleBoard.kt:280`). A 320-point-wide board yields at most 32-point cells before margins. Merely enlarging all hit regions causes overlap.

**Fix:** add precise selection feedback and a large confirm-fire action, a magnified selection mode, or accessible coordinate navigation. Keep firing at the intended coordinate; test iOS label offsets and Android tap-versus-drag arbitration. For Ludo, retain its existing expanded legal-pawn targets and test stacked pawns rather than assuming they are missing.

**Accept:** edge/corner coordinates select accurately; dragging ships does not fire; controls work one-handed at the smallest supported size.

### F06 — P1 — Adapt full game layouts to available height and text size (Risk)

**Evidence:** iOS Cricket uses a 210-point pitch (`CricketPitch.swift:191`) inside a non-scrolling match VStack with score, pick faces, status, and number controls. Android Cricket/RPS use Columns and weighted spacers. iOS Ludo chooses compact layout from `UIScreen.main.bounds.height < 700` (`LudoGameView.swift:423`) rather than the actual container.

**Fix:** size boards/pitch using available width AND height after safe areas and controls. Switch short windows to compact or side-by-side layouts; scroll secondary details where necessary. Use container dimensions for Ludo. Keep score, active player and primary action visible; let longer names/status text wrap. Apply to bot and multiplayer screens.

**Accept:** no clipped controls or overlapping labels at 320/360 logical-width phones, short landscape windows, tablet split view, foldables, and enlarged text. Do not solve overflow by shrinking all text or touch targets.

### F07 — P1 — Stop unnecessary Snake work when inactive (Risk)

**Evidence:** iOS continuously redraws its Metal view at 60 fps until dismantled (`SnakeMetalView.swift:137–159`) and flushes steering in a 50 ms task (`SnakeArenaView.swift:145`). Android has HUD polling and a display-frame loop (`SnakeArenaScreen.kt:124,200`). These local loops have no explicit foreground/finished gating. Platform suspension may suppress some work; background drain was not measured.

**Fix:** explicitly gate rendering, steering, audio and HUD collection on lifecycle and match state. Clear held boost/steering on interruption. Distinguish local pause from server match time: backgrounding must not silently forfeit a turn-based match. Resume with fresh state before accepting gameplay input.

**Accept:** lock/unlock, task switch, call interruption, end screen, and navigation produce no stuck boost, steering resend, or unnecessary game rendering. Verify through traces, not only appearance callbacks.

### F08 — P1 — Server match queue retains every key (Confirmed)

**Evidence:** `backend/games/src/queue.ts` inserts entries into `queues`; production completion does not delete them. Only the test helper clears the map.

**Fix:** delete a settled tail only if it is still the current tail for that key. Preserve strict ordering while new jobs arrive. Instrument active queue count, pending work, and age; bound abuse without discarding valid accepted commands.

**Accept:** thousands of completed match keys return to baseline; overlapping jobs stay serialized; rejection does not poison later work.

### F09 — P1 — Lease contention can silently lose a Ludo command (Confirmed path)

**Evidence:** `backend/games/src/index.ts:440–456`: `withMatchLease` retries 25 times then returns without a rejection or a failure result. The Redis lease expires after 10 seconds without renewal.

**Fix:** propagate acquisition failure and issue a retryable command rejection with its command ID. Validate multi-worker deployment behavior, lease duration, and durable compare-and-swap semantics before changing lock design. Ensure an expired holder cannot commit stale state.

**Accept:** forced contention either commits once or explicitly rejects; no silent lost tap. A delayed worker cannot overwrite a newer state.

### F10 — P2 — Cache Sea Battle static art and isolate animation (Confirmed work; cost unmeasured)

**Evidence:** iOS `SeaBattleBoard.swift:259` drives the whole board at 20 Hz, and `draw` calls `GameSurface.paper` at line 333. Paper regenerates procedural speckles (`GameSurface.swift:79`). Android similarly paints paper inside Canvas (`SeaBattleBoard.kt:285`) with a clock from `SeaBattleScreen.kt:102`.

**Fix:** cache paper/grid/static art by size, density, theme, and seed. Render water shimmer, reticle, fire, and impact separately. Disable ambient motion under Reduce Motion and offer a lower-cost mode. Invalidate cached art on real visual changes.

**Accept:** unchanged board art does not regenerate on each animation frame; resize/theme changes remain correct. Compare CPU/GPU traces before and after on a slower phone.

### F11 — P2 — Introduce measured Snake quality tiers (Validation)

**Evidence:** Metal fixes a 60 fps target; Android follows display cadence, potentially above 60 Hz. Existing prediction and HUD separation should be preserved. The server test fixture reports average 2.2 KB / peak 14.3 KB wire frames, approximately 44 KB/s per player at 20 Hz. This is a synthetic fixture result, not production telemetry.

**Fix:** profile dense arenas, death bursts, long snakes and extended play. Bound particle counts; cache geometry and reuse buffers where profiles identify churn. Choose stable frame targets and lower decorative effects/render resolution under thermal pressure. Investigate bandwidth reduction only after measuring actual traffic, reconnect keyframes, and latency.

**Accept:** a stable 60 fps target on the agreed baseline, or a deliberate stable 30 fps fallback on lower-tier hardware; no change to authoritative movement/rules. A 20-minute soak does not progressively degrade or leak memory.

### F12 — P2 — Separate server simulation timing from slow publishing (Risk)

**Evidence:** `backend/games/src/index.ts:348–380` performs one engine tick, serialization, awaited broadcast, and periodic save under a `running` flag. Interval firings while running are skipped. This prevents overlap but gives slow dependencies influence over tick cadence.

**Fix:** measure event-loop delay, tick duration, publication latency and save time under concurrency. Keep an explicit simulation clock with bounded catch-up if needed. Serialize lifecycle and terminal transitions consistently; avoid stale in-flight saves after a match ends. Do not simply remove the running guard or broadcast unbounded promises.

**Accept:** injected Redis latency and many simultaneous arenas do not cause unbounded queues, duplicated outcomes, or unexplained simulation slowdown. Report p95/p99 tick time against the 20 Hz budget.

### F13 — P2 — Define abandonment behavior for Tic Tac Toe, RPS, and Cricket (Confirmed missing engine deadlines; product decision)

**Evidence:** these engines have no deadline/timeout handlers; `engine/registry.test.ts` explicitly checks their absence. Sea Battle and Ludo have deadline contracts.

**Fix:** decide whether these games are asynchronous or timed. For asynchronous games, provide clear waiting/resume/leave behavior and durable recovery. If timed, add server-owned deadlines and visible rules; do not infer a win from a client timer or reveal a pending secret pick.

**Accept:** an opponent disappearing during a turn, throw, toss, or ball never leaves the player without a clear next action. Both platforms show the same outcome after recovery.

### F14 — P2 — Complete client state cleanup (Confirmed)

**Evidence:** `GamesEngine.swift:1233` and Android `GamesEngine.kt`'s `leave()` clear Tic Tac Toe/RPS/Cricket/Snake but omit Sea Battle and Ludo state; `open` clears more state than `leave`.

**Fix:** centralize session cleanup and explicitly separate active UI state from intentional resume cache. Clear per-match pending actions, presence, errors, prediction and rendered state. Preserve a durable Ludo resume record only according to its defined policy.

**Accept:** leaving Sea Battle/Ludo does not retain active board state or expose it during another game; supported resume still retrieves the correct match.

### F15 — P2 — Profile audio startup and cancel obsolete cues (Risk)

**Evidence:** iOS `DesignSystem/GameAudio.swift:190` synchronously loads missing buffers and starts the audio engine; screens call preload on appearance. Android `GameAudio.kt:143` registers SoundPool loads and skips playback until loaded. Shared mute/call suppression already exists.

**Fix:** measure first-entry cost; prewarm or decode off the UI thread if it causes hitches, while serializing ownership safely. Cancel delayed cues from old sessions. Verify shared sound release ownership when switching games and handling overlays.

**Accept:** first interaction stays responsive, no prior-game sound plays after exit, muted games remain quiet, calls/headphones/speaker changes recover correctly.

### F16 — P2 — Extend consistent accessibility and motion settings (Validation)

**Evidence:** Tic Tac Toe already labels cells on both platforms; Ludo has dedicated accessibility helpers. Snake reads Android Reduce Motion once at entry (`SnakeArenaScreen.kt:184`); Sea Battle has an independent ambient clock.

**Fix:** validate all settings against actual game effects: haptics, sound, screen shake, flashes, ambient motion, reveals, and result overlays. Observe accessibility setting changes where supported. Use readable scalable labels and explicit turn/selection feedback beyond color; prevent redundant screen-reader announcements on animation ticks.

**Accept:** every game has reachable back/settings/restart controls; core play does not require sound or color discrimination. Test motion reduction while entering and resuming the game.

### F17 — P2 — Close test coverage gaps (Confirmed registration; validation backlog)

**Evidence:** `backend/games/package.json` registers six suites: registry, Snake, Cricket, Sea Battle, queue, Ludo. The inspected registry suite checks limited Tic Tac Toe/RPS behavior; there are no separately registered dedicated suites for their full rules.

**Fix:** add focused rules tests for all Tic Tac Toe wins/draws and illegal moves, RPS ties/target progression/duplicate throws, private-state preservation, restoration, and cross-platform fixtures. Add client tests for stale opening responses, bot restart cancellation, recovery, and coordinate selection. Add screenshots and device traces for the layout/performance acceptance matrix.

**Accept:** tests cover failure paths and observable contracts, not just mirrored implementation details. Server unit tests must not be treated as proof of native UI quality.

## Per-game implementation checklist

| Game | First fixes | Polish and regression checks |
|---|---|---|
| Tic Tac Toe | F01–03, F13 | Cancel bot work on restart; retain cell labels; immediate pending-tap feedback without committing an unconfirmed move; compact/tablet boards; win/draw/rematch tests |
| RPS | F01–03, F06, F13 | Distinguish selected/waiting/revealing; reveal once per round; reduced-motion reveal; long names and large text; tie streaks and recovery between rounds |
| Hand Cricket | F01–03, F06, F13 | Responsive pitch; cancel old ball/announcement work; keep all seven controls reachable; toss and innings transitions, tie results, bot exit/restart |
| Snake | F07, F11–12 | Two-thumb steering/boost, safe areas, touch interruption, balanced frame pacing, dense-arena bandwidth/thermal soak, death/respawn/restart |
| Sea Battle | F02–06, F10 | Accessible precise targeting; cache board art; placement rotation/drag; preserve hidden fleets; 100-cell coordinate checks; final-hit recovery |
| Ludo | F01–03, F06, F09 | Contention feedback; cached/live snapshot convergence; stacked pawn selection; actual-window sizing; 2/3/4-player tables, takeover, chat and timer interruption |

## Shared home, setup, lobby and result acceptance

- Catalog: all six games route to the correct mode; supported bot difficulties/player counts are consistent across platforms. Do not list an unavailable mode as playable.
- Entry: prevent double-create from repeated taps; show progress immediately; failed invite/join provides retry/exit; a missing opponent is distinguished from a network failure.
- Lobby: long names, avatars, invite status, group/seat capacity and changing roster remain readable; expired invitations explain the next step.
- Results: final score is authoritative; share/restart/rematch actions are reachable with large text; replay does not reuse stale animations or write scores twice.
- Visual finish: align board margins, hierarchy, contrast, disabled states, safe-area spacing and control sizes across both platforms while retaining each game's existing style.
- Persistence: rotate, resize, background, receive a call, lose network, and kill/relaunch from entry/play/results. Confirm intentional behavior for local bot games versus server matches.

## Device and network release matrix

Use physical devices for frame pacing, memory, touch, audio, battery and thermal acceptance. Simulators/emulators are useful for additional layout and automation coverage.

| Dimension | Required coverage |
|---|---|
| iOS | Smallest supported iPhone/window; regular and large iPhone; 60 Hz and high-refresh hardware; iPad portrait/landscape and split view if supported |
| Android | Lower-tier 3–4 GB RAM phone where supported; mainstream phone; high-refresh phone; tablet and foldable/resizable window |
| OS | Minimum supported OS and current supported release on each platform; record exact versions |
| Layout | 320/360 logical-width layouts; short height; landscape; cutout/home indicator/gesture navigation; large text and long localized names |
| Accessibility | VoiceOver, TalkBack, larger text, reduced motion, contrast and sound/haptic settings |
| Network | Offline entry; 150–300 ms RTT; 1–5% packet loss; Wi-Fi/mobile handover; socket reconnect; delayed REST responses |
| Lifecycle | 30-second background; lock/unlock; call interruption; repeated navigation; force-quit/resume; fast restart |
| Load | Dense Snake arena; concurrent server matches; 20-minute game soak; 30 enter/exit cycles |

## Proposed measurable quality gates

These are project targets to validate and tune, **not measurements of this build**.

- At 60 fps, budget approximately 16.7 ms per frame; record p50/p95/p99 and missed-frame rate. At an explicit 30 fps fallback, use 33.3 ms. Report sustained performance, not only average fps.
- Visible local button/selection feedback within 100 ms even when the network is slow. Feedback must not falsely confirm an authoritative move.
- Record tap-to-entry-feedback, join latency, first usable state and reconnect latency separately. Show retry/exit after a bounded failed entry instead of an indefinite spinner.
- No persistent rise in retained memory after 30 open/close cycles; no active game animation/steering after disposal. Record native/GPU/audio memory where available.
- Every primary control reachable without clipping or ambiguous overlap. Aim for 44×44-point iOS actions; use a 48×48-dp project target for Android actions. Dense grids require an alternative precise interaction, not overlapping enlarged cells.
- Server: track queue size/age, tick p95/p99, lease contention, command rejection rates and state-delivery bytes. Establish concurrency targets using production-like load.

Apple recommends 44-point targets for iPhone/iPad games: [Design advanced games for Apple platforms](https://developer.apple.com/videos/play/wwdc2024/10085/). Android guidance emphasizes rendering performance and power/thermal profiling: [Slow rendering](https://developer.android.com/topic/performance/vitals/render), [Optimize power efficiency](https://developer.android.com/games/optimize/power). Native OpenGL/Vulkan frame-pacing libraries are not a drop-in replacement for this app's Compose Canvas renderer.

## Suggested implementation order

1. **Reliability:** F01–03, F08–09, F14. Establish correct entry, cleanup and command feedback before visual work.
2. **Playable on every supported screen:** F04–06 and the shared-flow matrix. Fix inaccessible or unreachable actions first.
3. **Performance:** profile and implement F07, F10–12, F15. Capture before/after results on the same devices.
4. **Polish and release evidence:** F13, F16–17, visual consistency, long sessions and cross-platform matches. Record each acceptance result with device/OS/build.

## Verification performed for this audit

- Ran `npm test -w @voiid/games`; exit code **0**, **6/6 suites passed**.
- Snake's fixture reported average **2.2 KB**, peak **14.3 KB**, approximately **44 KB/s per player at 20 Hz**; its existing under-60-KB/s assertion passed.
- Ludo suite reported **45 passed, 0 failed**.
- Inspected current source paths and existing working-tree changes. Untracked Sea Battle cannon files were already present; their release integration was not established by this audit.
- Did not build or run native apps, connect to production services, measure device fps/thermal/battery use, or execute full API/WebSocket integration tests.
- Existing unrelated working-tree changes were preserved. Completing this document does not mean the listed fixes have been implemented.
