# Snake — known bugs

> **Status:** root causes identified, not yet fixed
> **Affects:** iOS and Android, identically in both cases

| | Bug | Severity | Root cause |
|---|---|---|---|
| **Part A** | Controls stop working after ~10 s; Respawn does nothing | **P0** | One stale constant in `backend/websocket` throttles game input to 2/s |
| **Part B** | The whole arena flickers and jerks sideways | **P1** | The render clock is re-anchored to network arrival time on every frame, injecting all jitter back into the picture |

They are independent. Fixing one does not fix the other.

---
---

# PART A — The controls stop working

> **Scope:** the primary cause is one constant in `backend/websocket`. Four secondary bugs make it worse and are worth fixing in the same pass.

## 1. The reported symptom, restated

> After some time you cannot turn the snake. It flies straight and dies. The Respawn button then does nothing. Leaving the screen and coming back in fixes it — and then the whole thing happens again.

Every clause of that is explained by a single number.

---

## 2. Root cause: the relay throttles game input to **2 frames per second**

`backend/websocket/src/index.ts:141`

```ts
const GAME_MAX_FRAMES_PER_WINDOW = Number(process.env.VOIID_GAME_WS_RATE) || 120;
const GAME_RATE_WINDOW_MS = 60_000;
```

**120 frames per 60 seconds = 2 per second**, applied to every `game_input` frame regardless of which game sent it, and enforced in [`index.ts:463-474`](../backend/websocket/src/index.ts#L463-L474) as a **silent drop** — no error frame, no log, nothing the client can observe.

That number was correct when it was written. The comment directly above it says so:

```
// Turn-based games send a handful of moves a minute; the arcade games planned later tick
// far faster, so this is set for the fastest credible client rather than for Tic Tac Toe,
// and the games service applies its own per-game limit on top.
```

Tic Tac Toe, RPS and Hand Cricket send perhaps 30 moves in a whole match. 2/s was enormous headroom. **Snake shipped and this constant was never revisited.**

### The limit that everyone actually designed against is on the *other* server

`backend/games/src/index.ts:42-48` derives its limit from the game's own tick rate:

```ts
const CONTINUOUS_HEADROOM = 2;
function limitFor(slug: string): number {
  const hz = factoryFor(slug)?.tickHz;
  return hz ? Math.ceil(hz * 60 * CONTINUOUS_HEADROOM) : INPUT_MAX_PER_WINDOW;
}
```

For Snake (`tickHz: 10`) that is **1200 per minute — 20/s**. Correct, game-aware, exactly right.

Both clients were then tuned against *that* number. The Android comment is explicit ([`GamesEngine.kt:34-37`](../apps/android/app/src/main/java/com/voiid/app/net/GamesEngine.kt#L34-L37)):

```
// 60 ms, not the tick period. The server's per-match input limit for a continuous
// game is tickHz x 120/min (20/s at 10 Hz), so ~16.7/s sits safely under it
```

**It does sit safely under it. But the relay sits in front of the games service, and the relay's limit is 10x tighter.** The frame never reaches the service whose limit the client was measured against. Two layers enforce a rate limit; the client was tuned to the looser one; the tighter one is invisible.

### Why the relay can't just be made game-aware

The relay is deliberately a dumb pipe with no database and no notion of what a payload means — that is the architectural rule the whole games design is built on ([`GAMES.md` §2](./GAMES.md), [`backend/games/src/index.ts:3-15`](../backend/games/src/index.ts#L3-L15)). It cannot look up the slug for a match id, so it cannot compute a per-game limit. The fix is not to make it smarter (§5).

---

## 3. Exact trace from the constant to the symptom

### 3.1 "Cursor doesn't work after some time"

Send rates, measured from the code:

| Platform | Pacer | Effective send rate | 120-frame budget exhausted after |
|---|---|---|---|
| iOS | 50 ms poll loop ([`SnakeArenaView.swift:78-83`](../apps/ios/Voiid/Voiid/Games/SnakeArenaView.swift#L78-L83)) against a 60 ms gate ([`GamesEngine.swift:596`](../apps/ios/Voiid/Voiid/Networking/GamesEngine.swift#L596)) → sends land every 100 ms | **10/s** | **12 s** |
| Android | `withFrameNanos` every frame at 60 fps ([`SnakeArenaScreen.kt:137-142`](../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt#L137-L142)) against a 60 ms gate → sends land every ~66.7 ms | **15/s** | **8 s** |

The window is **fixed, not sliding** — it opens on the first frame and does not reset until 60 s have elapsed. So the real shape of a match is:

```
0s ──────── 8-12s ─────────────────────────────── 60s ──────── 68-72s ────────
   CONTROLS WORK   |        48-52 s DEAF          |  WORK      |    DEAF
```

The player gets **8-12 seconds of control, then ~50 seconds of nothing**, then it briefly works again. That is precisely "it works, then it stops, and the cycle repeats."

### 3.2 "You cannot turn the snake and they die"

When steering frames stop arriving, the server does not stop the snake — it has no reason to. `applyInput` never ran, so `snake.th` keeps its last value and `moveAll` keeps steering toward it ([`snake/index.ts:314-315`](../backend/games/src/engine/snake/index.ts#L314-L315)). The snake completes its last commanded turn and then flies dead straight at `BASE_SPEED: 240` units/sec.

The arena is a circle of radius 1400 with a **lethal border** ([`snake/index.ts:363-376`](../backend/games/src/engine/snake/index.ts#L363-L376)). From anywhere in the arena, a straight line hits the wall in **under 12 seconds**. Death is not a possibility here — it is arithmetic.

### 3.3 "Then the Respawn button does nothing"

This is the part that makes the bug feel unfixable to a player, and it is the same bucket.

Respawn is not a special channel. It is an ordinary `game_input`:

```swift
// GamesEngine.swift:591-594
func requestRespawn() {
    guard let matchId else { return }
    WebSocketClient.shared.sendGameInput(matchId: matchId, payload: ["respawn": true])
}
```

```kotlin
// GamesEngine.kt:630-633
fun requestRespawn(context: Context) {
    val id = matchId ?: return
    WebSocketClient.get(context).sendGameInput(id, """{"respawn":true}""")
}
```

So it goes through the same exhausted 120-frame bucket and is **silently dropped**. The death panel stays up, the button is enabled (`canRespawn` comes from the server and is correctly `true`), and tapping it does nothing at all — no error, no spinner, no feedback.

**It gets worse.** The client keeps pumping steering frames *while the player is sitting on the death panel*. Nothing pauses the pacer on death — `desiredHeading` retains its last value and the flush loop keeps firing at 10-15/s at a snake that is not even in the arena. So by the time the 2.5 s respawn delay elapses and the button becomes tappable, the budget is **guaranteed** to be gone.

### 3.4 "Go out of the game and back in and it works again"

The bucket is keyed on **match id**:

```ts
const bucket = gameRate.get(msg.match_id);   // index.ts:467
```

Quitting to the Games home and starting a new practice match mints a **new match id**, which gets a **fresh 120-frame bucket**. Controls work again — for 8-12 seconds. Cycle repeats.

This also explains why the in-panel **Restart** feels different from quitting: on the *death* panel there is no Restart, only Respawn, and Respawn reuses the same match id and therefore the same dead bucket.

---

## 4. Secondary bugs (real, and they compound the above)

### 4.1 Steering frames are queued through a disconnect and replayed in a burst

`sendGameInput` passes `queueIfDown: true` on both platforms:

- [`WebSocketClient.swift:290-293`](../apps/ios/Voiid/Voiid/Networking/WebSocketClient.swift#L290-L293)
- [`WebSocketClient.kt:244-246`](../apps/android/app/src/main/java/com/voiid/app/net/WebSocketClient.kt#L244-L246)

The justification is written for **turn-based** games and is correct for them:

> a stale position is worthless, but a move is the player's actual intent, and silently dropping it looks like the tap never registered

A steering frame is not a move. It is a position — the *most* perishable kind of data in the app. Queuing it produces three problems at once:

1. The queue is bounded at **128 frames** ([`WebSocketClient.swift:38-41`](../apps/ios/Voiid/Voiid/Networking/WebSocketClient.swift#L38-L41)). At 10-15 frames/sec, **a ~9-second outage fills it completely.**
2. On reconnect the whole queue flushes at once — **128 frames in one burst**, instantly consuming the entire 120-frame relay budget and blacking out controls for the next minute. A brief network blip is therefore *guaranteed* to trigger the §3 freeze.
3. The queue is **shared with chat and call signalling**, and it drops from the front. A snake match with a flaky connection **evicts queued messages, call offers, ICE candidates and hangups** to make room for stale headings the player abandoned eight seconds ago.

Point 3 is a cross-feature bug: Snake can silently degrade calls and messaging.

### 4.2 The client steers a dead snake

Nothing pauses the pacer while `!mine.alive`. The death panel blocks touches ([`SnakeArenaScreen.kt:228`](../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt#L228), and the iOS panel is drawn over the joystick), but `desiredHeading` is still set, so the flush loop keeps sending. Every one of those frames is budget spent on a snake that cannot move — and the one frame that matters, `respawn`, is the one that gets dropped.

### 4.3 Both rate-limit maps leak

- Relay: `gameRate` is socket-local and never pruned — one entry per match id for the life of the socket.
- Games service: `inputRate` entries are deleted **only** in `endMatch` ([`index.ts:96`](../backend/games/src/index.ts#L96)). A match that expires via Redis TTL, is abandoned, or dies with the process leaves its entries behind forever.

Small, but unbounded, and in a long-lived process.

### 4.4 Every steering frame triggers a full-state Redis write

`handleInput` ([`index.ts:267-272`](../backend/games/src/index.ts#L267-L272)) does `m.state = engine.serialize(); await saveMatch(m)` on **every accepted input**. For Snake that serializes the entire world — ~260 food items plus every snake's full-precision body polyline — at 10-15 writes/sec **per player**. The tick loop deliberately persists only every 5th tick to avoid exactly this cost (`PERSIST_EVERY`, [`index.ts:145-146`](../backend/games/src/index.ts#L145-L146)), and then the input path does it 15x/sec anyway.

A continuous game's input records *intent* and changes nothing durable — the very next tick will overwrite it. It does not need to be persisted at all.

---

## 5. The fix

### 5.1 Primary — make the relay's ceiling a flood guard, not a game limit

`backend/websocket/src/index.ts:141`

```ts
// A COARSE flood guard only. The relay cannot know which game a match is, so it cannot
// apply a per-game limit — backend/games does that, derived from the game's own tick rate
// (see limitFor() there). This number must therefore clear the FASTEST continuous game
// with headroom, or it silently throttles a game it knows nothing about. It did exactly
// that to Snake: 120/min = 2/s against a client legitimately sending 15/s.
const GAME_MAX_FRAMES_PER_WINDOW = Number(process.env.VOIID_GAME_WS_RATE) || 1800;
```

1800/min = 30/s. That clears Snake's 15/s with 2x headroom, leaves room for the 20-30 Hz games the design doc plans (Air Hockey, Ping Pong, Pool — [`GAMES.md` §4](./GAMES.md)), and still bounds a hostile client to something trivial. **The precise limit stays where it belongs: in the games service, which knows the slug.**

> Set `VOIID_GAME_WS_RATE=1800` in the relay's environment on the Vultr box as an immediate hotfix — this needs no client release and fixes the bug on every device already installed.

### 5.2 Use a sliding window, not a fixed one

Both buckets reset only when a full 60 s has elapsed since the window opened, which turns "slightly over the limit" into "**52 seconds of total silence**". A player who over-sends by 20% should lose 20% of their frames, not everything for the rest of the minute. A 4-6 slot ring of 10-second sub-windows gives the same protection with a proportional failure mode. Apply to both `gameRate` (relay) and `inputRate` (games service).

### 5.3 Never drop a lifecycle input

`respawn` is not steering — it is a once-per-death intent, and dropping it strands the player behind a dead button. Either exempt non-steering payloads from the bucket, or give them their own small one. In the relay this is the only place it is acceptable to peek at the payload, and it should be justified in a comment if done there; the cleaner option is a distinct frame type (`game_action` vs `game_input`) so the relay stays rules-ignorant.

### 5.4 Do not queue steering frames

In `sendGameInput`, either pass `queueIfDown: false` for continuous games, or — better — **coalesce**: keep at most one pending steering frame per match id in the queue, replacing rather than appending. A stale heading has no value, which is exactly the argument `loc_update` already makes for itself in the same file. This also stops Snake evicting queued call/chat frames.

### 5.5 Pause the pacer while dead

Client-side, on both platforms: when the local snake is `!alive`, call `releaseSteering()` and stop flushing. Resume on respawn. Frames spent on a corpse are pure waste, and they are what starves the respawn frame.

### 5.6 Do not persist continuous-game input

In `handleInput`, skip `serialize()`/`saveMatch()` when the engine has a live tick loop. The tick's own `PERSIST_EVERY` cadence is the crash-recovery snapshot; the input path adds nothing but 15 full-world Redis writes a second per player.

### 5.7 Surface drops instead of hiding them

The silent-drop posture is right for a hostile client and actively harmful for debugging a real one — this bug was invisible from both ends. At minimum, log a counter per match when the relay first starts dropping a match's frames. It would have named this in one line of output.

---

## 6. Suggested order

| # | Change | Where | Risk | Fixes |
|---|---|---|---|---|
| 1 | `VOIID_GAME_WS_RATE=1800` in the relay env | Vultr box, no deploy | none | the whole reported bug, on installed devices |
| 2 | Raise the default constant to 1800 + comment | `backend/websocket/src/index.ts:141` | none | makes #1 permanent |
| 3 | Stop steering a dead snake | both clients | low | respawn starvation |
| 4 | Don't queue / coalesce steering frames | both `WebSocketClient`s | low | reconnect burst; call+chat eviction |
| 5 | Exempt `respawn` from the bucket | relay or new frame type | low | dead Respawn button |
| 6 | Sliding windows | relay + games service | medium | 52-second blackouts |
| 7 | Skip persistence on continuous input | `backend/games/src/index.ts` | low | Redis write amplification |
| 8 | Prune both rate maps | relay + games service | low | slow leak |

---

## 7. How to verify a fix

1. **Instrument first.** Add a temporary log in the relay's drop branch (`index.ts:470`) printing match id and frame count. Play one Snake match on each platform *before* changing anything — you should see drops begin at ~8 s (Android) / ~12 s (iOS) and continue to the 60 s boundary. This is the single clearest confirmation of the diagnosis.
2. **Reproduce the dead Respawn.** Die after the cutoff and tap Respawn repeatedly. Confirm no `game_input` reaches `backend/games` (log in `handleInput`).
3. **Reproduce the reconnect burst.** Enable airplane mode for ~10 s mid-match, then disable. Confirm ~128 frames flush at once and controls die immediately afterward.
4. **After the fix:** play a full 180-second match on both platforms without ever losing steering, and confirm Respawn works on the first tap every time.
5. **Regression:** confirm Tic Tac Toe, RPS and Hand Cricket still behave — they send ~30 frames per match and are nowhere near any of these limits, but the relay change touches their path too.

---

## 8. Note on `snake-play.md`

The 2,397-line design doc at the repo root specifies things the shipped build does not do, and one of them is relevant here: **§13 Controls** describes the intended control feel. Any retuning of the pacer should be checked against that section rather than chosen ad hoc. See [`GAMES_AUDIT.md`](./GAMES_AUDIT.md) §3 for the full spec-vs-build delta.

---
---

# PART B — The whole arena flickers and drifts sideways

> **Severity:** P1
> **Affects:** iOS and Android, from **identical** code — the two renderers were ported line-for-line, including the bug.
> **Independent of Part A.** This happens even when steering works perfectly.

## B1. The reported symptom, restated

> The whole game flickers and moves a little to the right.

Not the snake — **the whole scene**. Arena, food, other players, everything shifts together, repeatedly, along the direction you happen to be travelling. It reads as "right" when you are moving right.

That "everything moves together" detail is the diagnostic clue: it means the fault is in the **camera transform**, not in any individual thing being drawn.

## B2. Root cause: the render clock is re-anchored to arrival time on every frame

The architecture is right. There is an 8-frame jitter buffer, the pair bracketing the render instant is chosen on the **server's** clock, and the render instant sits 250 ms in the past. All correct, and all defeated by one line.

**iOS** ([`SnakeMetalView.swift:304-305`](../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift#L304-L305)):
```swift
let elapsed = CACurrentMediaTime() - newest.arrivedAt
let renderT = newest.state.time + elapsed - Self.interpDelay
```

**Android** ([`SnakeArenaScreen.kt:381-382`](../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt#L381-L382)):
```kotlin
val elapsed = (SystemClock.elapsedRealtime() - newest.arrivedAtMs) / 1000.0
val renderT = newest.state.time + elapsed - INTERP_DELAY
```

`renderT` — the instant the world is drawn at — is computed from **the newest frame's arrival time**. So every time a frame lands, the clock is thrown away and rebuilt around the new arrival. **All the network jitter the buffer exists to absorb is fed straight back into the render clock.**

### The discontinuity, exactly

Let frame *N* have server time `T` and arrival `Aₙ`, and let `J = Aₙ₊₁ − Aₙ` be the real inter-arrival gap. Server frames are exactly 0.1 s apart (`TICK_HZ: 10`).

```
just BEFORE frame N+1 lands:   renderT = T + J   − 0.25
just AFTER  frame N+1 lands:   renderT = T + 0.1 − 0.25
                               ─────────────────────────
                    jump  =  0.1 − J
```

| Frame arrives | `J` | `renderT` jumps | World snaps by (at 240 u/s) |
|---|---|---|---|
| exactly on time | 0.100 s | 0 | nothing |
| 20 ms late | 0.120 s | **−20 ms** (backward) | 4.8 units |
| 40 ms late | 0.140 s | **−40 ms** (backward) | 9.6 units |
| 30 ms early (burst) | 0.070 s | **+30 ms** (forward) | 7.2 units |

Head radius is 11 world units. **A routine 40 ms of network jitter snaps the entire world by most of a snake head — 10 times a second.**

And because the camera is locked rigidly to the head with **no smoothing whatsoever** (`focus` is the raw interpolated head position — [`SnakeMetalView.swift:335`](../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift#L335), [`SnakeArenaScreen.kt:439`](../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt#L439)), that snap is applied to the camera centre. Everything on screen moves. That is the flicker, and the axis of the snap is your direction of travel — hence "moves a little to the right."

### Why raising `interpDelay` did not fix it

The comment above `interpDelay` records a previous attempt:

> TWO AND A HALF ticks, not one and a half. At 1.5 ticks the buffer ran dry on any frame that arrived even slightly late … That hold-jump cycle IS the jitter.

That change fixed a *different* failure (buffer underrun, §B3.4) and made it rarer. It cannot fix this one: the re-anchoring happens on **every single frame**, on time or not, and `interpDelay` is a constant subtracted from both sides of the equation. It cancels out of the jump entirely.

## B3. Contributing faults

### B3.1 The camera has no smoothing on either platform
`focus` is the raw interpolated head. Any positional error — jitter, packet loss, a mispredicted lerp — becomes a full-screen movement at 1:1. A critically-damped follow spring would absorb most of the visible symptom **even without fixing the clock**, which makes it the cheapest partial mitigation available.

### B3.2 iOS stamps `arrivedAt` after a main-actor hop
The frame is posted through `NotificationCenter` ([`WebSocketClient.swift:410`](../apps/ios/Voiid/Voiid/Networking/WebSocketClient.swift#L410)) and timestamped inside `Task { @MainActor in self.ingest(…) }` ([`GamesEngine.swift:382-385`](../apps/ios/Voiid/Voiid/Networking/GamesEngine.swift#L382-L385)). So `arrivedAt` is not when the frame arrived — it is when the **main actor got around to it**. Every SwiftUI layout pass, HUD update and gesture callback adds jitter to the number the render clock is built from. Android stamps on the relay thread and is cleaner here, but is not immune.

### B3.3 Respawn teleports are interpolated instead of cut
`spawnSnake` relocates you to a point far from other heads ([`snake/index.ts:537-571`](../backend/games/src/engine/snake/index.ts#L537-L571)). The interpolator has no idea this is a teleport, so it **lerps** from your death position to your spawn position across one 100 ms frame pair — and the camera, locked to the head, **flies across the arena**. `TrailStore` already recognises this class of event (`resyncDistance: 60`); the camera and the head interpolator do not.

### B3.4 The buffer still holds-and-jumps when it runs dry
When `renderT` passes the newest buffered frame, the pair search falls through to the last pair and `t` clamps to `1.0` — so the render **freezes** on the newest frame until another arrives, then jumps. Rarer at 0.25 s delay than at 0.15 s, but any stall longer than the delay still produces a visible hitch.

### B3.5 iOS is missing Android's `CameraMemory` guard
Android holds the last known focus so a missing head cannot pin the camera to the arena origin, and documents why ([`SnakeArenaScreen.kt:408-440`](../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt#L408-L440)). iOS still has the raw fallback:

```swift
let focus = heads[me ?? ""] ?? .zero      // SnakeMetalView.swift:335
```

If `me` is nil — `TokenStore.shared.userId` not yet loaded when the arena opens — the camera pins to world (0,0) for those frames and the player's snake is somewhere off screen. A parity fix that was applied to Android and never back-ported.

### B3.6 `snakeFramesSnapshot` is a genuine data race on iOS
```swift
nonisolated(unsafe) private(set) var snakeFramesSnapshot: [SnakeFrame] = []
```
Written on the main actor in `ingest`, read from the Metal display-link thread in `buildFrame`. The comment argues this is safe because it is "a value-type copy of an array of structs" — **that is not what makes it safe.** Value semantics do not make the *assignment* atomic: `Array` is a struct wrapping a reference to a heap buffer, so a concurrent read can observe a torn reference or race the buffer's retain/release. This is undefined behaviour, and an occasional garbage or duplicated frame is exactly the kind of thing it produces. It should be an atomic swap, a lock, or a lock-free double buffer.

## B4. The fix

### B4.1 Primary — free-running render clock, rate-adjusted, never re-anchored

Keep a local clock that advances with real time and is *nudged* toward the target offset rather than snapped to it. This is the standard jitter-buffer clock and it is what makes the existing 8-frame buffer actually do its job.

```swift
// Persistent renderer state, not recomputed per frame.
private var renderClock: Double = 0        // in SERVER time
private var lastDrawAt: Double = 0

private func advanceClock() -> Double {
    let now = CACurrentMediaTime()
    guard let newest = frames.last else { return renderClock }

    let dt = lastDrawAt > 0 ? now - lastDrawAt : 0
    lastDrawAt = now

    // Where we would LIKE to be: interpDelay behind the newest frame.
    let target = newest.state.time - Self.interpDelay

    if renderClock == 0 || abs(target - renderClock) > 0.5 {
        renderClock = target            // first frame, or a real stall: hard resync
    } else {
        // Otherwise run our own clock and close the gap by adjusting its RATE, never
        // its position. +/-10% is imperceptible; a position snap is exactly the bug.
        let drift = target - renderClock
        let rate = 1.0 + max(-0.10, min(0.10, drift * 0.5))
        renderClock += dt * rate
    }
    return renderClock
}
```

Then `renderT = advanceClock()` and everything downstream is unchanged. Port the same function to Android. **Keep the constants identical on both platforms** — this is exactly the kind of number that silently diverges.

### B4.2 Add a camera follow spring

```
camera += (focus - camera) * (1 - exp(-dt / TAU))     // TAU ≈ 0.08 s
```

Frame-rate independent, critically damped, ~120 ms settle. Do this **even if B4.1 slips** — on its own it removes most of the visible flicker, and it is a prerequisite for the look-ahead and mass-zoom camera work in [`GAMES_AUDIT.md`](./GAMES_AUDIT.md) §9.3.

### B4.3 Detect teleports and cut instead of lerping

In the head interpolator, if `hypot(prev - cur) > TELEPORT_DIST` (≈ 300 world units — far beyond the ~24 units a snake can cover in one tick at boost speed), use the new position directly at `t = 1` and snap the camera to it in the same frame. Reuse `TrailStore`'s existing threshold concept so respawn resync is handled in one consistent place.

### B4.4 Stamp `arrivedAt` at the socket, not after the actor hop (iOS)

Capture `CACurrentMediaTime()` in the `WebSocketClient` handler where the frame is parsed, pass it through the notification's `userInfo`, and have `ingest` use that value instead of stamping its own. Removes main-actor scheduling noise from the render clock.

### B4.5 Fix the `snakeFramesSnapshot` race (iOS)

Replace `nonisolated(unsafe)` with either an `os_unfair_lock`-guarded accessor or a two-slot buffer with an atomic index. Cheap; the renderer reads it once per frame.

### B4.6 Soften the buffer-dry case

When `renderT` runs past the newest frame, extrapolate along the last known heading for up to ~100 ms before holding. Better than freezing, and bounded so it cannot invent a position the server would never confirm.

## B5. Suggested order

| # | Change | Where | Risk | Effect |
|---|---|---|---|---|
| 1 | Camera follow spring | both renderers | low | removes most of the visible flicker immediately |
| 2 | Free-running render clock | both renderers | medium | **fixes the actual cause** |
| 3 | Teleport detection on respawn | both renderers | low | stops the camera flying across the arena |
| 4 | Stamp `arrivedAt` at the socket | iOS | low | removes main-actor jitter |
| 5 | Fix `snakeFramesSnapshot` race | iOS | low | removes UB / stray garbage frames |
| 6 | `CameraMemory` guard | iOS | low | parity with Android |
| 7 | Bounded extrapolation on buffer-dry | both renderers | medium | smooths stalls |

## B6. How to verify

1. **Prove the diagnosis before changing anything.** Log `renderT` every frame and diff consecutive values. On a real network you will see the delta swing between roughly 0 and 2× the frame interval instead of holding steady at the frame time — that swing *is* the flicker.
2. **Reproduce deterministically.** Add ±40 ms of artificial jitter to frame delivery (delay the `ingest` call by a random 0-40 ms). The symptom should become severe and obvious, which also gives you a repeatable test.
3. **Confirm it is the camera, not the snake.** Temporarily pin `focus` to a constant world point. The snake will wander off screen, but if the *arena and food* stop flickering while the snake still jitters, the camera coupling is confirmed.
4. **After the fix:** the arena boundary and the food field should be rock steady at all times. They are static world geometry — if anything about them moves, the camera is still wrong.
5. **Check the respawn cut.** Die and respawn repeatedly. The view must cut to the new position, never sweep to it.
6. **Both platforms, side by side.** These two renderers were ported line-for-line; verify the fix was too.
