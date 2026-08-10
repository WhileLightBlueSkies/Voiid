# Snake

> **Files:** [`SnakeMetalView.swift`](../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift) (1722), [`Snake.metal`](../../apps/ios/Voiid/Voiid/Games/Snake.metal), [`SnakeArenaView.swift`](../../apps/ios/Voiid/Voiid/Games/SnakeArenaView.swift) (607) · [`SnakeArenaScreen.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt) (1832) · [`backend/games/src/engine/snake/`](../../backend/games/src/engine/snake/) (1028 + geometry 212 + bot 244 + tests 396)
> **Design bible:** [`snake-play.md`](../../snake-play.md) · **Visuals:** [`../GAMES_SNAKE_VISUALS.md`](../GAMES_SNAKE_VISUALS.md) · **Bug history:** [`../GAMES_SNAKE_BUGS.md`](../GAMES_SNAKE_BUGS.md)

Server-authoritative, 10 Hz tick, up to 6 snakes in a radius-1400 circular arena with a lethal border. iOS renders on the GPU (Metal + SDF shader); Android on Compose `Canvas`. Both clients run a 60 fps clock and interpolate between server frames through an 8-frame jitter buffer.

This is the only game in the app with a real skill ceiling, and it is the one worth investing in.

---

# 1. What is good already

Worth stating, because the list below is long and it is not a rewrite.

- **The netcode architecture is correct.** Jitter buffer, pair selection on the *server's* clock, interpolation delay, teleport detection, camera spring with a hitstop-dilated `dt`. This is what a competent `.io` client looks like.
- **Camera work is done and done well.** Exponential follow (`tau = 0.08` on both platforms), teleport cut at 300 units, `CameraMemory`/`lastFocus` guard so a missing head cannot pin the camera to the arena origin. Constants match across platforms deliberately.
- **Audio and haptics ship on both platforms.** ~70 iOS and ~62 Android call sites.
- **Server events reach both clients.** `death` / `kill` / `eat` / `spawn` with world coordinates are parsed on iOS *and* Android now.
- **The engine is tested.** 396 lines of `snake.test.ts` — the only game with real coverage.

---

# 2. THE BUG — "it pauses between frames" (iOS and Android)

**This is the one you reported, it is real, it is unfixed, and it is the last structural defect in the renderer.**

## 2.1 The symptom

The world holds still for a beat and then catches up. Not the snake alone — the arena border and the food field stutter too, which is the diagnostic tell: **the fault is in the render clock and the camera transform, not in anything being drawn.**

## 2.2 Root cause: the render clock is rebuilt from arrival time on every frame

**iOS** — [`SnakeMetalView.swift:745-746`](../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift#L745-L746):

```swift
let elapsed = CACurrentMediaTime() - newest.arrivedAt
let renderT = newest.state.time + elapsed - Self.interpDelay
```

**Android** — [`SnakeArenaScreen.kt:506-507`](../../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt#L506-L507):

```kotlin
val elapsed = (android.os.SystemClock.elapsedRealtime() - newest.arrivedAtMs) / 1000.0
val renderT = newest.state.time + elapsed - INTERP_DELAY
```

`renderT` — the instant the world is drawn at — is anchored to **the newest frame's arrival time**. Every time a frame lands, the clock is discarded and rebuilt around the new arrival. All the network jitter the 8-frame buffer exists to absorb is fed straight back into the picture.

Server frames are exactly 0.1 s apart (`tickHz: 10`). Let `J` be the real inter-arrival gap:

```
just BEFORE frame N+1 lands:   renderT = T + J   − interpDelay
just AFTER  frame N+1 lands:   renderT = T + 0.1 − interpDelay
                               ─────────────────────────────
                    jump  =  0.1 − J          (10 times a second)
```

| Frame arrives | `J` | `renderT` jumps | World moves (240 u/s) |
|---|---|---|---|
| on time | 0.100 s | 0 | nothing |
| 20 ms late | 0.120 s | −20 ms backward | 4.8 units |
| 40 ms late | 0.140 s | −40 ms backward | 9.6 units |
| 30 ms early (burst) | 0.070 s | +30 ms forward | 7.2 units |

Head radius is 11 world units. Routine mobile jitter moves the whole world by most of a snake head, ten times a second.

## 2.3 Why it reads as a *pause* now, and not the *sideways drift* the old doc described

The camera spring (already shipped) absorbs the small high-frequency snaps — that is why the "moves a little to the right" symptom went away. What it cannot absorb is the **buffer running dry**, and that got substantially more likely:

```swift
private static let interpDelay: Double = 0.15      // SnakeMetalView.swift:732
```

```kotlin
private const val INTERP_DELAY = 0.15              // SnakeArenaScreen.kt:474
```

**`interpDelay` was reduced from 0.25 s to 0.15 s — 1.5 ticks instead of 2.5.** The doc comment sitting directly above the iOS constant still argues for the value it no longer holds:

> TWO AND A HALF ticks, not one and a half. At 1.5 ticks the buffer ran dry on any frame that arrived even slightly late — and on a mobile network that is most of them — so the render clock repeatedly caught up with the newest frame, held, and jumped. **That hold-jump cycle IS the jitter.**

The comment describes the current code's exact failure mode. At 0.15 s the render instant sits only 50 ms ahead of the newest frame's timestamp, so **any frame more than 50 ms late leaves nothing to interpolate toward**. The pair search falls through, `t` clamps to `1.0`, and the render **freezes on the newest frame until another arrives — then jumps**.

That freeze-then-jump is what you are seeing. Two independent faults compound into it:

1. Re-anchoring injects jitter into the clock (§2.2) — makes the dry condition happen more often than raw network conditions warrant.
2. A 0.15 s delay leaves no margin to survive it.

## 2.4 The fix

Three changes. Do them in this order; each is independently shippable.

### Fix 1 — free-running render clock, rate-adjusted, never re-anchored *(the actual cause)*

Keep a persistent clock in **server time** that advances with real time and is *nudged* toward the target by adjusting its **rate**, never its position. This is the standard jitter-buffer clock, and it is what makes the existing 8-frame buffer do its job.

**iOS** — replace the two lines at `SnakeMetalView.swift:745-746`:

```swift
// Persistent renderer state — NOT recomputed per frame.
private var renderClock: Double = 0        // in SERVER time
private var lastDrawAt: Double = 0

/// The instant to draw the world at.
///
/// Never anchored to a frame's ARRIVAL time. Arrival jitter is precisely what the frame
/// buffer exists to absorb; rebuilding the clock from it on every frame feeds that jitter
/// straight back into the picture — the world snaps by (0.1 - interArrivalGap) seconds of
/// travel, ten times a second. Instead the clock free-runs on the local display clock and
/// closes any drift by running slightly fast or slow. A +/-10% rate error is imperceptible;
/// a position snap is the bug.
private func advanceClock(newest: SnakeFrame) -> Double {
    let now = CACurrentMediaTime()
    let dt = lastDrawAt > 0 ? min(now - lastDrawAt, 0.25) : 0
    lastDrawAt = now

    let target = newest.state.time - Self.interpDelay

    // First frame, or a real stall (app backgrounded, socket reconnected): hard resync.
    // Springing across a gap this large would sweep the world instead of cutting.
    if renderClock == 0 || abs(target - renderClock) > 0.5 {
        renderClock = target
    } else {
        let drift = target - renderClock
        let rate = 1.0 + max(-0.10, min(0.10, drift * 0.5))
        renderClock += dt * rate
    }
    return renderClock
}
```

then:

```swift
let renderT = advanceClock(newest: frames[frames.count - 1])
```

**Android** — the identical function in `SnakeArenaScreen.kt`. The two renderers were ported line-for-line including the bug; port the fix line-for-line too, and **keep every constant identical** (`0.5` resync threshold, `0.10` rate clamp, `0.5` drift gain). Divergent constants here is how two builds of the same game end up feeling different.

Android's clock source needs care: `withFrameNanos` gives the frame deadline, `SystemClock.elapsedRealtime()` gives arrival. Use `withFrameNanos`'s value for `now` so the clock advances on the display's cadence rather than the network's.

### Fix 2 — put `interpDelay` back to 0.25 s

```swift
private static let interpDelay: Double = 0.25   // 2.5 ticks
```

Two and a half ticks of margin means a frame can be 150 ms late before the buffer runs dry, instead of 50 ms. The cost is 100 ms of extra input-to-screen latency, which at Snake's `BASE_SPEED: 240` u/s and a turn-rate-limited control scheme is not perceptible — the snake does not stop and start, it curves. **Both platforms, same value.**

The existing comment above the constant already makes this argument. Restore the value to match the comment, or delete the comment — right now the code contradicts its own documentation, which is how this regressed unnoticed.

### Fix 3 — bounded extrapolation instead of freezing when the buffer does run dry

Even at 0.25 s, a bad stall will outlast the margin. Freezing is the worst available response because it reads as a hang. When `renderT` passes the newest buffered frame, extrapolate each snake along its last known heading for up to **100 ms**, then hold:

```swift
// Buffer dry. Carry each head forward along its last heading rather than freezing —
// a frozen world reads as a hang, and 100 ms of a straight line is very likely correct
// (a snake's turn rate is capped, so it cannot have gone far off this path). Bounded
// so the client can never invent a position the server would not confirm.
let overshoot = min(renderT - newest.state.time, 0.10)
```

Apply the same bound on Android.

## 2.5 One more real defect in the same file (iOS only)

[`SnakeMetalView.swift`](../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift) reads `engine.snakeFramesSnapshot`, declared `nonisolated(unsafe)`, written on the main actor in `ingest` and read from the Metal display-link thread in `buildFrame`.

The comment defending this argues it is safe because it is "a value-type copy of an array of structs." **That is not what makes it safe.** Value semantics do not make the *assignment* atomic: `Array` is a struct wrapping a reference to a heap buffer, so a concurrent read can observe a torn reference or race the buffer's retain/release. This is undefined behaviour, and stray/duplicated frames are exactly what it produces — which would look like *more stutter*.

Fix with an `os_unfair_lock`-guarded accessor or a two-slot buffer with an atomic index. The renderer reads it once per frame; the cost is nothing.

## 2.6 How to verify

1. **Prove it first.** Log `renderT` every frame and diff consecutive values. Today the delta swings between ~0 and ~2× the frame interval; it should hold steady at the frame time.
2. **Make it deterministic.** Delay `ingest` by a random 0-40 ms. The stutter should become severe and obvious — that is your repeatable test.
3. **Confirm it is the camera, not the snake.** Pin `focus` to a constant world point. The snake wanders off screen, but if the *arena border and food* go rock steady, the camera coupling is confirmed.
4. **After the fix:** arena border and food field must be perfectly steady at all times. They are static world geometry — if anything about them moves, the clock is still wrong.
5. **Both platforms side by side.** Same match, same network.

---

# 3. What is missing

## 3.1 No minimap — the single biggest playability gap

A radius-1400 arena with a camera locked to your head means **you cannot see danger coming**. You die to things that were never on screen. Every successful `.io` game has a minimap for exactly this reason, and [`snake-play.md`](../../snake-play.md) §19 specifies one. Nothing in either client draws it (`grep minimap` → no matches).

Cheap: the server already broadcasts every snake's head position to every player. A corner-anchored circle with a dot per snake in its own colour, plus the food density as a faint heat blur, is one draw call.

## 3.2 No kill feed, no boost meter, no danger indicator

- **Kill feed** — `kill` events are already parsed on both platforms and rendered as nothing textual. "You ate Priya" is the moment worth showing.
- **Boost meter** — mass *is* the boost fuel (`MIN_BOOST_MASS: 12`) and the player cannot see how much is left. You run out mid-escape with no warning. This is an unfair-feeling mechanic purely because it is invisible.
- **Danger indicator** — the border is lethal and completely silent about it. A directional edge glow that brightens with proximity, plus a rising audio tone, converts the single most common death from "unfair" to "my fault."
- **Live rank badge** — "#3 of 6" near your own head.

## 3.3 One arena, one mode, forever

Radius 1400, circle, 260 food pellets, always. [`snake-play.md`](../../snake-play.md) §5 and §7 specify mode and arena variety and neither exists. Variety is the cheapest replayability there is — the engine already parameterises radius and food count.

## 3.4 Bots have no skill parameter

Difficulty maps to **bot count only** (3 / 5 / 8 — [`GamesHomeView.swift:230-234`](../../apps/ios/Voiid/Voiid/Games/GamesHomeView.swift#L230-L234)). `stepBot` takes no skill argument, so "hard" means *more* opponents of identical ability, not better ones. Every other game in the app has a continuous `skill` slider. More bad bots is a worse experience than fewer good ones — eight identical snakes make the arena chaotic rather than challenging.

## 3.5 No progression, no cosmetics beyond skins

`SnakeSkins` exists on both platforms and is the entire cosmetic system. [`snake-play.md`](../../snake-play.md) §23 specifies trails, death effects and unlocks. Nothing is *earned* — the skin picker is a preference, not a reward, so there is no reason to keep playing.

## 3.6 Max 6 players, and reaching 6 requires bots

`OpponentPickerSheet` returns exactly one conversation, so a friend match is always 1 human + 5 bots. Multi-select is specified in [`../GAMES_AUDIT.md`](../GAMES_AUDIT.md) §8 and still unbuilt. "Snake with three friends" is the mode people would actually organise around.

---

# 4. What makes it addictive

Ranked by (impact × cheapness). The top three are all HUD work on data already on the wire.

| # | Change | Why it hooks |
|---|---|---|
| 1 | **Minimap** | Turns deaths from "unfair" into "my fault." A game you can't blame is a game you replay. |
| 2 | **Boost meter + border danger glow** | Same argument. Every invisible mechanic is a reason to quit. |
| 3 | **Kill feed + post-match summary** (see [`CROSS_CUTTING.md`](./CROSS_CUTTING.md)) | Gives the match a story. "You ate Priya" is the shareable moment. |
| 4 | **Personal best, always on screen** | The strongest single-player hook there is. Show it in the HUD as a line you are chasing, and celebrate beating it. Data is already in `game_match_results`. |
| 5 | **Skill-scaled bots, not just more bots** | Makes "hard" mean hard, which makes winning mean something. |
| 6 | **Arena variety** — 3 sizes tied to player count, plus one hazard arena (moving obstacle / shrinking border) | Shrinking border in particular forces confrontation and ends matches decisively instead of by attrition. |
| 7 | **Daily challenge** — one seeded arena a day, everyone gets the same one, leaderboard resets at midnight | The single highest retention-per-line-of-code feature in casual gaming. Reuses the whole existing stack: one seed, one leaderboard query. |
| 8 | **Earned cosmetics** | Trails and death effects unlocked by length/kill/streak milestones. The skin picker exists; give it a reason. |
| 9 | **Multi-friend lobbies (3-6 humans)** | The mode that makes it a social game rather than a solo one, which is the whole point of shipping it inside a messenger. |
| 10 | **Spectate a friend's live match** | State is already broadcast to every player in `m.players`; a read-only seat is a small extension and it is how friends get pulled in. |

---

# 5. Suggested order

**P0 — fix the stutter (§2).** Free-running clock, `interpDelay` back to 0.25, bounded extrapolation, then the `snakeFramesSnapshot` race. Nothing below matters while the game hitches.

**P1 — the HUD that makes it fair.** Minimap, boost meter, border danger glow, kill feed, live rank badge, personal-best line.

**P2 — the loop that makes it repeat.** Post-match summary with rematch, personal bests, daily challenge.

**P3 — the depth.** Skill-scaled bots, arena/mode variety, earned cosmetics, multi-friend lobbies, spectate.
