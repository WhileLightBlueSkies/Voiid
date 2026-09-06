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

# Addendum: RPS 3D hands and cricket shot animations

Requested 6 September 2026. This section is the implementation specification for improving the two games' visuals. It supersedes their existing visual treatment where explicitly stated; the reliability and mobile-performance requirements above still apply. **Research and planning only: models have not been acquired, clips have not been produced, and native integration has not been implemented.**

## A. Decision and scope

**Default solution: author real, rigged 3D assets in Blender and render their animations into transparent, paged frame atlases. Play those atlases through small native renderers on iOS and Android.** This is a 3D-rendered visual treatment with fixed cameras, not interactive real-time 3D. It meets the request's allowance for a workaround and keeps both apps visually consistent.

The important upgrade is the quality of the model, poses, lighting, and motion. Adding a 3D engine alone will not improve poor anatomy or produce a convincing reverse sweep.

| Option | Suitable when | Tradeoff | Decision |
|---|---|---|---|
| Rigged 3D source → rendered animation atlases | Fixed-camera RPS and short cricket result animations | Requires careful texture-memory management; camera cannot rotate freely | **Implement this first** |
| Live RealityKit on iOS + Filament on Android | Camera rotation, continuous character customization, or interactive 3D becomes a product requirement | Two render integrations, asset conversion, lighting parity and device profiling | Documented alternative in section J; do not build both pipelines into the first release |
| Improve existing procedural Canvas rigs | Assets are temporarily unavailable | Lowest integration cost but limited depth and anatomical fidelity | Keep as a functional fallback; do not call it completion of the visual upgrade |

No WebView/remote model viewer, Unity/Unreal runtime embedding, AI-generated video sequence, or animated GIF is needed for the default solution. Do not change game rules, scores, difficulty, toss outcomes, or number-pick controls as part of this work. Shot names describe the result animation; players are not choosing a new batting mechanic.

### Verified current implementation

- RPS: `HandRig.swift`/`HandRig.kt` contain procedural 2D joint/pose data; `HandView.swift`/`HandView.kt` draw those shapes. There is no imported hand mesh in this path.
- Cricket batter: `CricketPitch.swift`/`CricketPitch.kt` and `CricketFigures.swift`/`CricketFigures.kt` create the depth effect through Canvas figures and transforms. The current batter is not an imported 3D character. The iOS toss coin, separately, uses SceneKit in `CoinSceneView.swift`.
- Cricket's `BallEvent` currently distinguishes runs, dot, caught, and bowled. The new shot type must be a separate presentation concept: a sweep must never become a new scoring rule.
- Both games have separate bot and multiplayer screens. Integrating only one mode or one platform is incomplete.

## B. Researched sources and acquisition route

| Source | What was verified | How to use it |
|---|---|---|
| [Cricket Animations — voxel vision, Fab](https://www.fab.com/listings/f102b4cb-f89d-4f0f-9879-c4f70af3c073) | Listing includes left/right batting idles, numbered shots and running clips; explicitly says models are not included; lists Unity/Unreal formats | Candidate motion source only. Inspect actual files/exportability and identify each clip visually before relying on it. The listing does **not** establish sweep/reverse-sweep coverage. |
| [Right rock paper scissors — wondarstudios](https://sketchfab.com/3d-models/right-rock-paper-scissors-b0d3b1615702460f99d2b012531df919) | Search surfaced a matching creator listing; detailed page could not be fetched | Lead only, not an approved asset. Rig, topology, animation clips, current availability and license are unverified. Do not make this URL a runtime dependency. |
| [Adobe Mixamo FAQ](https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html) and [animation workflow](https://helpx.adobe.com/ae_en/creative-cloud/help/animate-characters-mixamo.html) | Adobe documents humanoid auto-rigging and animation workflows | Possible base humanoid/idle workflow. Do not assume its library supplies cricket-specific grip, bat contact, sweep, or reverse sweep; author/retarget and validate those separately. |
| [Blender output documentation](https://docs.blender.org/manual/id/5.0/render/output/properties/output.html) | Documentation describes numbered animation output and image channel selection | Export RGBA image sequences from one reproducible source scene, then pack them locally. |
| [ECB reverse-sweep example](https://www.ecb.co.uk/video/4068583/lucy-higham-plays-a-wonderful-reverse-sweep) | Official cricket footage identifies the movement | Motion reference for pose review, not an asset to ship or a texture source. |
| [Apple: Bring your SceneKit project to RealityKit](https://developer.apple.com/videos/play/wwdc2025/288/) | Apple documents SceneKit's soft deprecation and recommends RealityKit for significant new 3D work | Do not extend the toss coin's SceneKit implementation into a new game-wide 3D engine. Existing coin code does not need migration for this task. |
| [Filament introduction](https://google.github.io/filament/dup/intro.html) and [official Android samples](https://github.com/google/filament/blob/main/android/samples/README.md) | Native Android renderer and glTF-loading/sample path | Starting point only if the live-3D alternative is selected. Pin compatible library versions after checking the actual project. |

**Asset acquisition procedure:** first look for an already licensed project asset; otherwise use an original Blender model or a verified commercial asset. Record creator, source, acquisition date, permitted distribution and attribution in `assets/game-visuals/LICENSES.md`. Check that model AND animation rights cover the intended bundled output. Purchase, payment, and contacting a creator are not authorized by this research request. If the executor lacks a suitable asset, it must deliver the exact missing-asset list and a working fallback, and mark the visual task incomplete; do not substitute a static screenshot and report success.

## C. Art specification and required deliverables

### C1. RPS hand asset

Create one anatomically coherent, softly stylized hand with a short forearm: five fingers, a distinct opposable thumb, rounded knuckles, readable finger separation, smooth skin shading, and no glove unless the user subsequently requests one. Keep skin natural and the wrist/forearm continuous. Use a soft key light from screen upper-left, gentle fill, and a small contact shadow. No logos, jewelry, extra fingers, severed-wrist appearance, or photoreal skin detail that becomes noise at game size.

Source rig must support independent finger curls, thumb opposition, wrist bend, and forearm movement. Inspect rock, paper and scissors from the final camera, not only in the modeling viewport. A flat open hand must read as paper; scissors must clearly show two extended fingers and three folded digits including the thumb.

Required clips, **for each of `near` and `far` orientations**:

| Clip ID | Frames at 30 fps | Purpose |
|---|---:|---|
| `rps_idle` | 1 | Resting closed fist while waiting |
| `rps_pump` | 18 | Three complete up/down pumps over 600 ms; same closed-fist start/end pose |
| `rps_reveal_rock` | 6 | Fist settles into emphatic rock, not a scale-only pop |
| `rps_reveal_paper` | 6 | Fingers unfold into paper, including thumb opposition |
| `rps_reveal_scissors` | 6 | Index/middle extend and separate; remaining fingers stay curled |
| `rps_hold_rock`, `rps_hold_paper`, `rps_hold_scissors` | 1 each | Still result poses; last reveal frame must match corresponding hold |

Render the two orientations from the same source and lighting setup so the hands face one another. Do not blindly mirror a lit PNG: this also flips its baked lighting. Use warm neutral skin for both initially; player ownership comes from adjacent labels/accent panels, not arbitrary hand tinting. Preserve native accessible labels and throw buttons.

Deliver source `.blend`, all required clips, atlases, manifest, and a contact sheet showing both orientations and every result. A single still hand image or three disconnected stock images is not sufficient.

### C2. Cricket character and scene

Create one stylized, proportionate batter with helmet/grille, shirt/trousers, gloves, pads, shoes, and a correctly scaled cricket bat. Use a coordinated bowler in the same art style. No floating bat, stick limbs, distorted shoulders, foot sliding, or hands separating from the handle. A model without the required actions is not enough.

Use a humanoid rig with pelvis/spine/head, shoulder/elbow/wrist chains, hip/knee/ankle chains, and hand grips. Constrain both hands to the bat handle; use leg IK during planted/kneeling poses and bake the constraints into the delivered animation. Keep the head balanced over the movement and give each stroke a distinct preparation, contact and follow-through.

Keep a fixed three-quarter view that shows bat contact, both knees and the ball's departure. Start the authoring scene with Z up, batter at origin facing +Y toward the bowler, +X labeled off side for this right-handed rig, and camera near `(7, -11, 8)` looking at `(0, 4, 1)`. Tune framing in the source scene once, then lock it for the entire pack. Camera position is an authoring starting point; the final camera and projection must be recorded in the manifest. Do not reframe each clip independently.

Render batter/bat/contact shadow together as an RGBA layer. Render bowler separately with the same camera. Keep the ball, pitch, stumps, score, controls and announcements separate so the app can display the actual result and adapt the layout. Export projected contact/release/crease coordinates from the camera; do not guess new pixel positions independently in Swift and Kotlin.

### C3. Required cricket motion catalog

Every stroke below needs its own authored action. The descriptions are acceptance criteria for this visual pack, not a new cricket rules engine. Review the motion against reference footage; do not rename an existing generic swing.

| Clip ID | Required recognizable motion | Allowed presentation outcomes |
|---|---|---|
| `cricket_defence` | Compact step, near-vertical bat, soft block, minimal follow-through | Dot |
| `cricket_push` | Short controlled forward movement and restrained bat follow-through | 1, 2 |
| `cricket_cover_drive` | Front-foot stride, bent front knee, high leading elbow, full drive to off side | 1, 2, 3, 4, 5 |
| `cricket_square_cut` | Back-foot weight transfer and horizontal bat through the off side | 1, 2, 3, 4 |
| `cricket_pull` | Back-foot loading, torso rotation and horizontal bat through leg side | 1, 2, 3, 4 |
| `cricket_sweep` | Low body, rear knee close to/on ground, planted front foot and low horizontal sweep to leg side | 1, 2, 3, 4 |
| `cricket_reverse_sweep` | Deliberately different hand/arm action and low opposite-direction sweep to off side; preserve coherent batting stance | 1, 2, 3, 4 |
| `cricket_lofted_drive` | Front foot plants, full extension through contact, high follow-through | 6 |
| `cricket_slog_sweep` | Low powerful sweep with a clearly elevated bat/ball departure and leg-side follow-through | 6 |
| `cricket_lofted_pull` | Back-foot pull with elevated finish and airborne leg-side departure | 6 |
| `cricket_edge_caught` | Small visible edge/deflection and truncated finish; ball ends in a catch | Caught wicket |
| `cricket_miss_bowled` | Genuine attempted stroke that misses; ball reaches stumps, bails react | Bowled wicket |
| `cricket_idle` | Stable batting stance | Waiting; one frame |
| `cricket_bowler_delivery` | Readable gather, arm delivery and release; same release point as ball | Delivery prelude; 18 frames |

A reverse sweep is **not** a horizontally flipped sweep image: a flip also reverses the entire batter, stance and equipment. Author the opposite bat path and grip movement on the same rig. An ordinary sweep, reverse sweep and slog sweep must be distinguishable in silhouette before displaying their names.

## D. Presentation contracts: preserve truthful gameplay

### D1. RPS round state machine

Replace the duplicated pump/reveal timing in the four RPS screens with one coordinator per platform using the same constants and these inputs:

```text
RpsResolvedRound = { sessionId, roundOrdinal, myThrow, opponentThrow, winnerSeat }
roundOrdinal = 1-based index in authoritative resolved history
throw = rock | paper | scissors
state = idle | localChoicePending | pump | reveal | hold
```

1. A local choice immediately gives button/lock feedback and sends the existing input once. It must not reveal or guess the opponent's hand.
2. Begin choreography when a NEW resolved round exists. Do not depend on observing a transient `bothThrown` state: a server can resolve/reset that state within one update.
3. Play closed-fist `rps_pump` for 600 ms, the selected reveal clip for 200 ms, then the still result for 350 ms. Both hands share one monotonic start time. Publish the authoritative result to UI state immediately; only presentation is timed.
4. Pump sounds occur at 0, 200 and 400 ms; reveal sound at 600 ms. Outcome cue occurs once at 800 ms. Mute/Reduce Motion suppress the relevant effects. Remove old screen-owned triggers so sounds cannot fire twice.
5. Ties use the same sequence and both correct hold poses. Play the final round before its result overlay, with a maximum 1,150 ms presentation delay; never delay committing scores or the server's state.
6. On first snapshot/open, mark already resolved history as seen and show the latest still state without replay. On a live history increment, present only new rounds. On recovery that skips multiple rounds, jump to the latest resolved still state.
7. Give each open/restart a generation ID. Cancel playback and sounds on exit/restart; ignore completions belonging to previous generations. Finish/cancel callbacks must be delivered once.
8. Reduce Motion: skip pump and animated reveal; display labeled result poses immediately, optionally with a 100 ms opacity transition. App background: stop the clock; foreground: synchronize to current state without replaying stale pumps.
9. Bot mode creates the same resolved-round object from its existing bot result. Keep scoring exactly once in the model; never update wins in animation completion callbacks.

### D2. Cricket outcome and shot selection

Continue deriving `BallEvent` with the existing `BallEvent.of(runs, wicket, matchedPick)` behavior. Do not invent a dismissal or turn a five into a boundary. Introduce a presentation-only `CricketVisualEvent`:

```text
CricketVisualEvent = {
  sessionId: string,
  deliveryOrdinal: integer >= 1,
  innings: 1 | 2,
  battingSeat: 0 | 1,
  runs: integer in 0...6,
  outcome: dot | runs | caught | bowled,
  shotId: one required cricket clip ID,
  generation: integer
}
eventId = sessionId + ":" + deliveryOrdinal
```

For online play, `deliveryOrdinal` is the resolved ball's index in the FULL `history` plus one. Use that ball's `innings` and `battingSeat`, not the current state's values, because the last ball can also switch innings. Bot mode must assign a monotonically increasing ordinal over the whole match and reset it only for a new session. This avoids reusing an innings-local ball number as an event ID.

Use this exact version-1 selection algorithm on both platforms; put its tables and fixtures in shared JSON. No language-default hash and no random choice during rendering:

```text
if outcome == caught: return cricket_edge_caught
if outcome == bowled: return cricket_miss_bowled
if runs == 0: return cricket_defence
candidates[1] = [push, cover_drive, sweep, reverse_sweep, square_cut, pull]
candidates[2] = [cover_drive, sweep, reverse_sweep, square_cut, pull, push]
candidates[3] = [cover_drive, square_cut, pull, sweep, reverse_sweep]
candidates[4] = [cover_drive, square_cut, pull, sweep, reverse_sweep]
candidates[5] = [cover_drive]
candidates[6] = [lofted_drive, slog_sweep, lofted_pull]
k = (deliveryOrdinal - 1 + battingSeat + innings - 1) % candidates[runs].length
return "cricket_" + candidates[runs][k]
```

Required deterministic fixtures:

| Ordinal | Innings | Batter | Runs/outcome | Expected shot |
|---:|---:|---:|---|---|
| 1 | 1 | 0 | 1 | `cricket_push` |
| 3 | 1 | 0 | 1 | `cricket_sweep` |
| 4 | 1 | 0 | 1 | `cricket_reverse_sweep` |
| 4 | 1 | 0 | 4 | `cricket_sweep` |
| 5 | 1 | 0 | 4 | `cricket_reverse_sweep` |
| 1 | 1 | 0 | 6 | `cricket_lofted_drive` |
| 2 | 1 | 0 | 6 | `cricket_slog_sweep` |
| 3 | 1 | 0 | 6 | `cricket_lofted_pull` |
| 7 | 2 | 1 | 2 | `cricket_reverse_sweep` |
| 9 | 2 | 1 | 0/dot | `cricket_defence` |
| 10 | 2 | 1 | wicket/caught | `cricket_edge_caught` |
| 11 | 2 | 1 | wicket/bowled | `cricket_miss_bowled` |

This deterministic cycle is intentionally simple and reproducible. The server remains the authority for results; both clients merely select the same illustration of each result.

### D3. Cricket animation timeline and ball alignment

Each batting action has **48 frames at 30 fps**, total 1,600 ms. Author clips to these markers rather than applying arbitrary playback speeds independently:

- Frames 0–11: preparation/backlift/footwork.
- Frames 12–17: movement into contact.
- Frame 18 (600 ms): bat contact, or the marked closest approach for a miss.
- Frames 19–35: follow-through and result flight.
- Frames 36–47: settle into a readable finish; ball result completed by frame 47.

The bowler delivery runs during the same timeline's first 600 ms; its release marker is frame 9 (300 ms), leaving 300 ms for the delivery to reach contact. Bake the ball's release to the bowling hand at that marker. Do not add a separate full run-up before every ball. Bowled has no bat-hit sound; use a separate exported stump-hit marker. Caught has an edge cue then a catch cue. Every cue is keyed by `(eventId, markerName)` and fires once even if a frame is skipped.

Export an outcome-specific normalized ball trajectory for each allowed `(shotId, outcome/runs)` pair, using the same camera as the character. It must pass the exported bat contact point at frame 18 for successful shots. A bowled trajectory passes the bat and reaches the actual stumps. Interpolate trajectory samples by time; do not attach the ball to the wrist or jump it from the bowler to the bat.

- Ground fours travel visibly along the ground after contact; sixes remain airborne toward/over the boundary.
- Runs 1/2/3 and the existing five-run result use infield collection/off-screen continuation plus the exact score label; do not illustrate a four or six boundary for them.
- Sweep and reverse sweep depart to different sides of the field, consistent with the authored bat action. Small inset composition must preserve this distinction.
- Native scoreboard updates immediately. A cosmetic “Sweep”/“Reverse sweep” label appears after contact and must not cover controls.
- Replace hard-coded `ballSettleDelay` announcement assumptions with the active presentation's completion/cancellation event. If the player sends the next valid pick, allow input; finish/skip the old cosmetic presentation rather than delay the server interaction.
- No unbounded animation queue. Keep at most one playing event and one newest pending event. If more arrive, discard intermediate presentation, preserve every authoritative score, and settle on the newest state. Reconnect snapshots do not replay a whole innings.
- Final-result and innings announcements follow the last applicable clip or its deliberate skip. A finished match never waits for missing assets or a failed animation callback.

## E. Asset files, packing and bounded playback

### E1. Repository contract

Create these source-of-truth folders and files; these paths are proposed, not existing assets:

```text
assets/game-visuals/LICENSES.md
assets/game-visuals/source/rps_hands.blend
assets/game-visuals/source/cricket_players.blend
assets/game-visuals/spec/visuals_v1.json
assets/game-visuals/spec/cricket_shots_v1.json
assets/game-visuals/fixtures/visual_events_v1.json
assets/game-visuals/export/rps/manifest.json
assets/game-visuals/export/cricket/manifest.json
assets/game-visuals/export/{rps,cricket}/<tier>/<clip>/<orientation>/page_<n>.png
assets/game-visuals/qa/{rps,cricket}/<clip>_contact_sheet.png
tools/game-visuals/render.py
tools/game-visuals/pack.py
tools/game-visuals/validate.py
tools/game-visuals/sync.py
```

`orientation` is `near`/`far` for hands and `fixed` for cricket. Raw source/image sequences do not belong in app bundles. Bundle generated output under `apps/ios/Voiid/Voiid/Resources/GameVisuals/` and `apps/android/app/src/main/assets/game_visuals/`. Register iOS resources in the actual build configuration, preserving directory hierarchy; plain files in a folder are not proof they are bundled. Sync identical manifest versions/content hashes to both platforms.

Use RGBA PNG, sRGB, consistent alpha conversion and transparent backgrounds. Pack frames without rotation or per-frame trimming; fixed canvases and a fixed pivot prevent animation jitter. Allocate a two-pixel extruded border on all sides of each frame to prevent atlas bleeding. Every frame rectangle excludes that border.

### E2. Manifest schema

One manifest contains `schemaVersion=1`, `packId`, `contentHash`, and `clips[]`. Every clip entry has these required fields:

```text
id: string                       # e.g. cricket_reverse_sweep
orientation: near | far | fixed
tier: low | standard | high
fps: 30
frameCount: integer >= 1
loop: false                      # version 1 does not loop ambient motion
frameWidth, frameHeight: integers
pivot: [normalizedX, normalizedY] # fixed across the clip, measured from top-left
pages: [{file, width, height, sha256}]
frames: [{pageIndex, x, y, width, height}] # length == frameCount, zero-based order
markers: {name: frameIndex}       # e.g. contact: 18; indices within clip
anchors: {name: [[frameIndex, normalizedX, normalizedY], ...]}
trajectories: {outcomeKey: [[frameIndex, normalizedX, normalizedY], ...]}
```

Markers/anchors/trajectories are empty objects where unused, not absent. Cricket anchors include bat contact, stump base and bowler release; export normalized coordinates relative to the full scene, distinct from an actor sprite's pivot. Scene metadata must include camera transform/projection and actor placement rectangles in that same normalized scene space. Trajectory samples must cover their entire visible time range, be strictly time-ordered, and interpolate without discontinuities. Visual outcome keys are `dot`, `runs_1` through `runs_6`, `caught`, `bowled`, restricted by the catalog. The validator rejects missing required trajectories, out-of-bounds frame rectangles, incorrect dimensions, invalid markers, or missing files.

### E3. Resolution and memory policy

Starting raster targets, before the required 2-pixel border:

| Pack | Low frame size | Standard frame size | High frame size |
|---|---|---|---|
| RPS hand | 192×192 | 256×256 | 384×384 |
| Cricket actor | 192×256 | 256×384 | 384×512 |

Atlas pages are at most 2048×2048; use smaller final pages where packing permits. Compute capacity including borders. Never assume that PNG download size equals decoded memory: a full 2048×2048 RGBA page is **16 MiB** before any extra CPU/GPU copies. For example, standard cricket frames occupy 260×388 packed cells: 7×5 = 35 frames/page, so a 48-frame clip requires two pages. High frames occupy 388×516: 5×3 = 15/page, so they require four pages, not three.

Bound the atlas cache to **48 MiB of decoded page pixels**, including hands/actors/bowler currently resident. GPU copies and upload/decode staging are additional: measure them and set an initial **96 MiB incremental visual-memory acceptance budget**, then lower the tier if the target device cannot sustain it. These are initial project targets, not measured guarantees.

Keep only the current page and the imminent next page where possible; evict passed pages for non-looping clips. Do not preload every cricket action. Use lower-tier bowler or a single still while the batter consumes the budget. If the next page is unavailable, hold the last valid frame briefly while the authoritative UI continues; if it cannot be ready within 150 ms, settle the event to its fallback still and finish presentation. No infinite loading spinner or allocation retry loop.

Decode and validate off the UI thread. Upload/reuse images once per page, not once per frame. Drive frame choice from monotonic elapsed time:

```text
frameIndex = min(frameCount - 1, floor(elapsedSeconds * fps))
```

A clip completes at `frameCount / fps` seconds, not when its last frame first appears; keep its last frame through that final interval. Drop expired frames when behind; never replay all missed frames. Draw ticks invalidate only the animation layer. Stop ticking during still poses, background state and disposal. Do not use a SwiftUI array of animated UIImages or a whole-screen Compose state update per frame.

Choose standard first; low for memory/thermal pressure or small rendering size; high only after its larger pages pass memory/frame tests on the target class. Keep the pitch's responsive sizing from F06. A high-resolution pack must not cause oversized fixed UI.

## F. Native integration boundaries

Use these explicit paths. Each new type owns only the responsibility listed; do not place asset decoding or event scheduling inside existing thousand-line screens.

| Responsibility | Create on iOS under `apps/ios/Voiid/Voiid/Games/` | Create on Android under `apps/android/app/src/main/java/com/voiid/app/main/games/` |
|---|---|---|
| Manifest model, validation and bounded cache | `Visuals/GameVisualAssetStore.swift` | `visuals/GameVisualAssetStore.kt` |
| Atlas crop/draw and monotonic playback | `Visuals/GameSpriteView.swift` | `visuals/GameSpriteView.kt` |
| RPS presentation state/events | `RpsPresentationCoordinator.swift` | `RpsPresentationCoordinator.kt` |
| RPS hand adapter | `RpsHandVisual.swift` | `RpsHandVisual.kt` |
| Cricket deterministic shot lookup | `CricketShotCatalog.swift` | `CricketShotCatalog.kt` |
| Cricket presentation events/timeline | `CricketPresentationCoordinator.swift` | `CricketPresentationCoordinator.kt` |
| New cricket scene adapter | `CricketPlayerVisual.swift` | `CricketPlayerVisual.kt` |

Common conceptual interfaces, implemented with native language types:

```text
AssetStore.prepare(pack, tier, clipIds) -> async success/failure
AssetStore.frame(clipId, orientation, tier, index) -> cached image + sourceRect, or missing
AssetStore.releaseSession(sessionId)
Presentation.ingest(snapshot, source: initial|live|recovery, generation)
Presentation.skipToCurrentState()
Presentation.setActive(bool)
Presentation.cancel(generation)
CricketShotCatalog.select(outcome, runs, deliveryOrdinal, innings, battingSeat) -> shotId
```

`prepare` is bounded by the memory policy; it does not imply loading all listed clips at once. Missing/corrupt/unsupported-version assets choose the procedural/still fallback and record one diagnostic per pack/session. The fallback must still invoke completion once so result UI cannot hang.

Modify all of the following:

- iOS: `RpsMatchView.swift`, `RpsBotView.swift`, `CricketMatchView.swift`, `CricketBotView.swift`, `CricketPitch.swift`.
- Android: `RpsMatchScreen.kt`, `RpsBotScreen.kt`, `CricketMatchScreen.kt`, `CricketBotScreen.kt`, `CricketPitch.kt`.
- Keep `HandView`/`HandRig` and `CricketFigures` as explicit fallback implementations until the new assets pass acceptance. Keep their existing public behavior available to the fallback adapter.
- Update the old RPS timing constants/call sites so the new coordinator is the sole timing owner. Route CricketSound/GameAudio cues through event markers; remove replaced screen-level cues.
- Read resolved game data through the existing engines; backend rule changes are not required for this visual plan. If ingestion cannot distinguish snapshot/recovery from live events, add that metadata at the client event boundary without altering scoring.

## G. Ordered execution tasks

> For the future executor: read this addendum plus F02, F06, F15 and F16 before coding. Use the executing-plans skill for task-by-task implementation. The current request authorizes writing this plan; it does not claim the following work is already complete. Keep unrelated current working-tree changes intact.

### Task 1 — Lock assets and demonstrate the two difficult motions

- [ ] Locate or create the source hand and batter models; record exact provenance in `LICENSES.md`.
- [ ] Build one complete RPS paper reveal, one sweep and one reverse sweep in Blender using C1–C3. No app integration yet.
- [ ] Render contact sheets at standard target size, including preparation/contact/follow-through for both shots and every finger state for the hand.
- [ ] Compare against the old in-app visual at the same display size. Reject extra digits, weak silhouette, sliding feet, incorrect grip, invisible bat contact, or indistinguishable sweep/reverse sweep.
- [ ] Save source scenes and final camera/light settings. If quality cannot be achieved, report that asset production is incomplete instead of hiding it behind engine code.

### Task 2 — Deliver the complete asset pack and validators

- [ ] Produce every clip in C1/C3 and all required outcome trajectories; generate the tiered atlas pages and manifests from E.
- [ ] Implement `render.py`, `pack.py`, `validate.py`, and `sync.py` with these exact CLI contracts. The scripts below are to be created; these commands are not available until this task is implemented.

```sh
blender --background assets/game-visuals/source/rps_hands.blend --python tools/game-visuals/render.py -- --pack rps --tier all
blender --background assets/game-visuals/source/cricket_players.blend --python tools/game-visuals/render.py -- --pack cricket --tier all
python3 tools/game-visuals/pack.py --pack all --tier all
python3 tools/game-visuals/validate.py --all
python3 tools/game-visuals/sync.py --check
```

- [ ] `render.py` must support each tier and `--tier all`; write raw frames to an ignored local build directory. `pack.py` fails clearly when an expected tier/frame is absent; never fabricate missing frames by duplicating one still.
- [ ] `sync.py` without `--check` copies validated generated packs to both native resource directories. `--check` is read-only and fails if content hashes differ. Register iOS resources before claiming bundle parity.
- [ ] Add validator tests for missing reverse sweep, wrong frame count, duplicate clip identity, out-of-bounds crop, absent contact marker, bad hash and missing trajectory. Report actual decoded-memory estimates per clip/tier and generated bundle size.

### Task 3 — Implement deterministic event selection before animation integration

- [ ] Create the shot catalog and both presentation coordinators with injected clock/event inputs so tests do not require sleeping or a live server.
- [ ] Copy D2's exact fixtures into `assets/game-visuals/fixtures/visual_events_v1.json` and consume the same fixture on both platforms.
- [ ] Implement the catalog algorithm exactly; assert the expected shot for every row and every candidate/result compatibility pair.
- [ ] Add timeline tests: RPS pump at 0 ms, reveal at 600 ms, hold at 800 ms, complete at 1,150 ms; cricket contact at 600 ms and completion at 1,600 ms. On a time jump, each crossed audio marker fires no more than once.
- [ ] Add initial-snapshot/no-replay, duplicate-live-event, recovery-skip, generation-cancel, reduced-motion and missing-asset-completion tests. A coordinator cannot change scores.

### Task 4 — Integrate RPS on both platforms and modes

- [ ] Implement the asset cache/player with E's frame-index equation, page reuse, cancellation and fallback behavior.
- [ ] Replace main hand displays in both bot/multiplayer RPS screens through `RpsHandVisual`. Keep throw controls native and accessible.
- [ ] Delete or disconnect replaced per-screen pump loops and reveal sounds. Do not leave two timing owners active.
- [ ] Exercise all nine throw pairs, ties, winning final round, fast repeated taps, lost connection, resume, and restart during a pump.
- [ ] Capture both platforms playing the same resolved-round fixture: same hands, orientation, timing, labels and result; zero premature opponent reveal.

### Task 5 — Integrate cricket shots and scene timing

- [ ] Replace batter/bowler drawing through `CricketPlayerVisual` inside the existing pitch; retain responsive native background, score, controls, toss and announcements.
- [ ] Adapt live history and bot results to D2 events, preserving the ball's own innings/seat and whole-match ordinal.
- [ ] Render contact/release/ball path from common exported coordinates; route bat/edge/stump/catch sound to its marker.
- [ ] Replace hard-coded announcement settling delays with D3 completion/skip handling. Input remains responsive while a result is illustrated.
- [ ] Exercise sweep, reverse sweep and all other clips, consecutive identical outcomes, innings-ending wicket, final six, dot, caught, bowled, and existing five-run behavior.
- [ ] Verify restart/cancel produces no stale balls, sounds, banners or score writes. Verify recovery shows current state without replaying an innings.

### Task 6 — Validate mobile quality and ship only verified packs

- [ ] Add Android unit tests at `apps/android/app/src/test/java/com/voiid/app/GameVisualPresentationTest.kt`, using fixtures in `app/src/test/resources/visual_events_v1.json`.
- [ ] Establish a real iOS test target if one is not configured: the inspected shared scheme has no explicit testables. Add `apps/ios/Voiid/VoiidTests/GameVisualPresentationTests.swift`, include the same fixture, and wire the target into the shared scheme. Do not claim `xcodebuild test` succeeded without executing discovered tests.
- [ ] Run Android tests with `./gradlew :app:testDebugUnitTest` from `apps/android`; run `npm test -w @voiid/games` from repository root to check existing rule behavior.
- [ ] Use `xcodebuild -showdestinations -project apps/ios/Voiid/Voiid.xcodeproj -scheme Voiid` to select an available simulator, then execute the configured tests with that actual destination. Record command, test count and result; do not hard-code an unavailable device ID in this document.
- [ ] Build both apps and check actual bundled asset paths/hashes. Test offline with no dependency on a creator website or remote download.
- [ ] Run the physical-device matrix above: memory, page transitions, frame pacing, cold entry, short screens, large text, calls, background and 20-minute play. Record baseline and new measurements separately.
- [ ] Add side-by-side screenshots and short recordings to `assets/game-visuals/qa/`; mark every acceptance check in H. Do not mark a task complete solely because code compiles.

## H. Definition of done

| Area | Required pass condition |
|---|---|
| Hand quality | Correct five-finger anatomy; rock/paper/scissors immediately distinguishable; fingers articulate during reveal; no silhouette collapse at standard phone size |
| Cricket quality | Sweep and reverse sweep are visibly different authored motions; bat stays in both hands; feet stay grounded when planted; body follows the bat naturally |
| Ball synchronization | Successful shots contact the bat at the exported contact point; miss reaches stumps; edge ends in catch; no score/trajectory contradiction |
| Motion coverage | Every C1/C3 clip exists in validated manifests; every permitted result has a trajectory and a tested event mapping |
| Cross-platform parity | Identical pack hashes, shot selection and marker timing; all four bot/multiplayer integrations exercised |
| Responsiveness | Native choices respond within the audit's 100 ms feedback target; no texture decode in tap/draw callbacks; next input is not blocked by an old clip |
| Performance | Cache cap enforced; actual incremental CPU/GPU memory measured; stable target frame pacing on baseline phone; lower tier works without changing rules |
| Lifecycle | No animation clock/sound after disposal; duplicate/recovery frames do not replay; generation changes cancel old work |
| Accessibility | Choice/result/shot labels remain native; artwork is decorative where duplicate; reduced motion shows truthful still results with no pumping/shake |
| Failure behavior | Missing page, bad manifest, timeout and memory pressure lead to a usable fallback and a completed presentation; never an indefinite spinner |
| Evidence | Source scenes, asset provenance, contact sheets, builds, executed tests and device recordings delivered; remaining failures listed explicitly |

A Markdown specification can remove ambiguity, but cannot guarantee that an arbitrary AI produces good art. The contact-sheet and device review gates are therefore part of completion, not optional polish.

## I. Briefs an executor can hand to an asset artist or generation workflow

**RPS brief:** “Produce a softly stylized, anatomically correct five-finger hand and forearm for a premium mobile rock-paper-scissors game. Deliver a rigged Blender source, two inward-facing orientations with consistent upper-left soft lighting, a three-pump 600 ms fist clip, three distinct 200 ms reveals, and matching still poses. Bake to transparent 30 fps PNG frames and the exact manifests/tiers in sections C/E. No disconnected stock poses, gloves, text, logos, extra fingers, or baked UI. Check all poses at 128 logical pixels wide.”

**Cricket brief:** “Produce a coordinated stylized batter and bowler with proper helmet, pads, gloves, shoes and bat. Deliver the exact C3 action catalog, including separate orthodox sweep, reverse sweep and slog sweep. Both hands stay constrained to the bat; planted feet do not slide; export bat-contact and ball-release anchors from one locked three-quarter camera. Batting clips are 48 frames at 30 fps with contact at frame 18. Deliver rigged Blender source, transparent rendered actor layers, all outcome trajectories, manifests and contact sheets. This is presentation for an existing hand-cricket game: preserve its scored outcomes, including five runs; do not design new gameplay.”

These briefs start production; they do not replace the manifest, event, timing and acceptance contracts above. Generated meshes or motion must pass the same checks as hand-authored assets.

## J. If interactive real-time 3D is later required

Use the same authored source assets and event/shot coordinators. Replace only the visual player adapter:

- iOS: RealityKit with a non-AR scene; export and validate skinned USD assets and named animations. Confirm the chosen view/API supports the repository's deployment target; do not raise the minimum OS silently or assume glTF loads directly.
- Android: Filament plus its glTF loader; export GLB with baked skeletal animation and material textures. Pin compatible renderer/loader versions together and base lifecycle/render handling on official samples. Do not assume a Blender constraint survives GLB export without baking.
- Prove paper/scissors deformation and sweep/reverse-sweep contact on both runtimes before adding the full catalog. Match lighting, camera, event markers, bone scales and clip durations.
- Initial per-visible-character budgets: at most 20,000 triangles, 64 deform joints, two materials and 1024-pixel textures; reduce after profiling. These are project starting budgets, not engine limits.
- No continuous render loop for an idle RPS hand; pause when hidden/backgrounded. Keep the same low-memory still/procedural fallback.
- Keep the coin's current implementation out of this migration. Live 3D is a separate implementation choice with additional build/device checks, not an extra requirement for completing the recommended baked-animation solution.

## Addendum verification status

Inspected the current hand rigs, cricket figures, bot/multiplayer trigger paths and cricket history fields; researched the primary sources linked above. Asset listing details are distinguished from unverified leads. No assets were purchased/downloaded, no artist was contacted, and no models or gameplay source were changed for this addendum. Implementation commands, test files and new directories are future work, not executed results. The earlier six-suite result belongs to the original audit.
