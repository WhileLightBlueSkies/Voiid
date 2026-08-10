# Air Hockey

> **Status:** design only, nothing built.
> **Kind:** continuous, 2-player, server-authoritative physics. `tickHz: 30`.
> **Depends on:** nothing that does not exist. It inherits Snake's entire tick machinery. It *wants* [`README.md`](./README.md) §2.5 (`tick(dtMs)`) and works without it.
> **Reference implementation to read first:** [`snake/index.ts`](../../../backend/games/src/engine/snake/index.ts) — the tick loop, the wire split, the swept collision reasoning, and every bug already paid for.

---

# 1. What the game is

A puck on a frictionless table. Two paddles. Ninety seconds. Most goals wins.

That is the entire ruleset and it is the point. **Air Hockey is the only game in this folder that requires zero explanation**, which matters more than it sounds inside a chat app: the invite arrives, you tap it, and you are playing. Hand cricket needs a rules screen it does not have ([`CRICKET.md`](../CRICKET.md) §2.1). Sea Battle needs a placement phase. Ludo needs four people. Air Hockey needs a finger.

## 1.1 Why it belongs in Voiid

Two arguments, one social and one structural.

**Social:** it is the best possible answer to "are you free for ninety seconds?" Snake's 3-minute practice run is solitary and Sea Battle's async loop plays out over days. Air Hockey is the game for the case where two people are both looking at their phones *right now*, which is a case a messenger knows about and a standalone game app does not. The rematch button is the whole game — a 90-second match with a rematch is a fifteen-minute session, and the session is built out of decisions to keep going rather than out of one long commitment.

**Structural:** it is the cheapest continuous game we will ever build, because Snake already paid for the expensive parts. The per-match tick loop, the `running` overlap guard, the live-engine cache that took the Redis read off the hot path, the persist-every-Nth-tick cadence, the jitter buffer and camera work on both clients — all of it exists and none of it needs changing. [`GAMES.md`](../../GAMES.md) §8 puts continuous games last "highest infra cost — tick loops, interpolation, physics tuning"; that cost has already been paid.

**We therefore disagree with [`GAMES.md`](../../GAMES.md) §8's ordering and put Air Hockey second** ([`README.md`](./README.md) §4). It is the most immediately fun thing on the list and the infrastructure argument that put it last no longer holds.

## 1.2 What it costs

Moderate, and concentrated in one place: **the physics must be right, and "right" here means invariant under tick timing** (§4.6). Everything else — rendering two circles and a rectangle, a score, a clock — is trivial.

The new code that is genuinely new is `engine/physics2d/`: swept circle-circle collision, circle-vs-wall, and impulse resolution with velocity transfer. ~250 lines. It is deliberately built as a **shared module**, because Ping Pong and Pool are the same problem with different constants and [`GAMES.md`](../../GAMES.md) §5 already anticipates it ("shared simple 2D physics helper (velocity/friction/collision) + per-game config"). Building it inside `airhockey/` would mean building it twice.

---

# 2. Rules as implemented

## 2.1 The table

Portrait, because the phone is. 2:1, in world units:

| Quantity | Value | Reason |
|---|---|---|
| Table | 600 × 1200 units | 2:1 fits a phone with room for HUD at both ends |
| Goal mouth | 240 units, centred on each short edge | 40% of the width. Narrower makes defence trivial and matches end 0-0; wider makes it a coin flip |
| Puck radius | 22 | — |
| Paddle radius | 40 | Comfortably larger than the puck, so a square-on hit is forgiving |
| Half-line | y = 600 | Each paddle is confined to its own half (§2.3) |
| Goal depth | 60 units behind the mouth | The puck visibly enters rather than vanishing at a line |

Coordinates are table-space, origin at the centre. Each client renders its own goal at the **bottom**, which means one of the two clients renders the world flipped 180°. That flip is a client-side transform and the server knows nothing about it — both players believe they are shooting up the screen, which is the only orientation that feels natural on a phone.

## 2.2 The puck

| Quantity | Value | Reason |
|---|---|---|
| Linear damping | 0.15 /s | Air hockey is *nearly* frictionless. Zero damping makes a deflected puck rattle forever and the game never resets; 0.15 loses ~14% of speed per second, which is invisible in a rally and settles a stray puck in a few seconds |
| Wall restitution | 0.94 | Slightly lossy. A perfectly elastic wall makes bank shots feel weightless |
| Paddle restitution | 1.0 + velocity transfer (§2.4) | The paddle is how energy enters the system |
| Max speed | 1400 units/s | Hard clamp. Above this the puck crosses the table in under a second and the game stops being playable — and it is also the anti-cheat ceiling (§5) |
| Min speed for "in play" | 30 units/s | Below this for 3 s → anti-stall reset (§2.6) |

## 2.3 The paddles

- **Confined to their own half.** The half-line is a wall for paddles and transparent to the puck. Without it the game degenerates into whoever reaches the puck first, and there is no defence to play.
- **Confined to the table**, including behind the goal mouth — you can stand in your own goal.
- **Max paddle speed: 2000 units/s.** Server-side clamp on displacement per substep. This is the single most important anti-cheat value in the game (§5.1) and it is also a feel decision: a paddle that can cross its half in 150 ms is fast enough to intercept anything reachable and slow enough that positioning matters.
- Paddles **do not collide with each other**, because they cannot meet — they are confined to opposite halves.

## 2.4 Puck-paddle collision

The paddle is an infinitely heavy moving circle. On contact:

1. Resolve penetration by pushing the puck out along the centre-to-centre normal.
2. Reflect the puck's velocity about that normal with restitution 1.0.
3. **Add the paddle's velocity component along the normal**, scaled by 0.85.

Step 3 is where the game lives. Without it a paddle is a wall and every rally decays; with it you can *hit* the puck, and hitting is the verb. 0.85 rather than 1.0 so a player cannot trivially stack paddle speed onto an already-fast puck and blow through the max-speed clamp on every touch.

**A glancing hit adds spin to the direction, not to the rotation.** There is no angular velocity in this simulation — a spinning puck is invisible on a 22-unit circle and would double the state and the physics for nothing.

## 2.5 Scoring, and the match format

**A 90-second clock. Most goals wins.** Not first-to-7.

This is open question O8 in [`README.md`](./README.md) §5 and the recommendation is the clock, for a reason specific to this app: **the match is happening inside a chat.** A bounded 90 seconds is a thing you can say yes to. First-to-7 is a match that might take two minutes or might take six, and a player who does not know how long they are committing to is a player who says "later". Snake already made this choice with `MATCH_SECONDS: 180` ([`snake/index.ts:84`](../../../backend/games/src/engine/snake/index.ts#L84)) and it is right there too.

Secondary reason: a clock produces *endgames*. Down one with fifteen seconds left is a different game — you push forward, you leave your goal, and either it works or it does not. First-to-7 has no such structure; every point is identical.

- **Tie:** if the score is level at 0:00, **90 seconds of sudden death**, next goal wins. If still level, the match is a **draw** — `winnerId: null`, which per [`GameEngine.ts:22-23`](../../../backend/games/src/engine/GameEngine.ts#L22-L23) is exactly what null means ("finished" and "has a winner" are separate facts).
- `scores` in the [`GameOutcome`](../../../backend/games/src/engine/GameEngine.ts#L21) is goals. Higher is better, so unlike Sea Battle it drops straight onto the existing leaderboard.

## 2.6 Restarts and stalls

- **After a goal:** 1.4 s pause. The puck resets to the **conceding player's** third, stationary, and a 3-2-1 countdown does *not* run — a countdown after every goal in a 90-second match is 12 seconds of dead time. Play resumes when the pause ends; the puck sitting in your own third is the compensation for conceding.
- **The clock stops during the goal pause** and during sudden-death setup. A match is 90 seconds of *play*.
- **Anti-stall:** if the puck's speed stays under 30 units/s for 3 continuous seconds, it resets to the centre with zero velocity. Air hockey's failure mode is a puck parked against a wall behind a paddle where neither player can reach it; without this rule that is a permanent stalemate the clock has to run out on.
- **Anti-camp:** none. Sitting in your own goal is legal and it is bad play — it concedes the whole table. Rules against camping solve a problem the geometry already solves.

---

# 3. Network model — R2

This is the section that decides whether the game is good, so it is the longest one.

## 3.1 Pattern

Second row of [`GAMES.md`](../../GAMES.md) §4: *"Server tick ~20-30/sec for ball physics, client-side interpolation between ticks for smoothness. Fast but only 2 players, physics must be authoritative to prevent phasing/cheating."*

Correct, and adopted. **Server-authoritative physics is non-negotiable here** and the reason is sharper than "cheating": with two clients each simulating a shared puck, any disagreement is *unresolvable*, because both players' inputs are continuously changing the thing they disagree about. Snake can tolerate a client predicting its own head because the head's future depends only on that client's own input ([`SnakePredictor.swift:16-19`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L16-L19)). A puck's future depends on both players. There is no correct client-authoritative answer, so the server holds it.

## 3.2 Server tick rate: 30 Hz

Broadcast at 30 Hz. Three inputs to that number:

**Bandwidth.** The full state is small — one puck, two paddles, two scores, a clock (§4.3). Serialized flat and short-keyed in Snake's style it is ~180 bytes, ~240 with events. At 30 Hz that is **~7 KB/s per player**. Snake measured 26 KB/s per player at 10 Hz ([`snake/index.ts:47-52`](../../../backend/games/src/engine/snake/index.ts#L47-L52)) because Snake sends 260 pellets and six body polylines. Air Hockey is a quarter of the cost at three times the rate, and the whole reason is that **its state is tiny and does not grow**. That is the property that lets a fast game be cheap.

**Responsiveness.** A 30 Hz tick means the server samples your paddle every 33 ms. At the 2000 u/s paddle cap that is 66 units of unsampled travel — larger than the puck. Sampling faster is what makes fast intercepts register (§3.6).

**Why not higher.** 60 Hz doubles the cost for a rate the client cannot use: the client renders at 60 fps and interpolates, so a 60 Hz server frame buys precision inside an interpolation the player cannot see. Snake's tuning note makes exactly this argument in reverse — raising its tick rate "only decides how often prediction is corrected — and those corrections were already invisible" ([`snake/index.ts:53-55`](../../../backend/games/src/engine/snake/index.ts#L53-L55)).

**Why not lower.** 20 Hz is 50 ms per frame. The interpolation delay must be a multiple of the frame interval to be useful, so a 20 Hz tick pushes the delay to 150 ms, and 150 ms of puck latency on a game about intercepting a puck is the difference between a save and a goal.

### Flagging a disagreement

[`GAMES.md`](../../GAMES.md) §4 gives "server tick ~20-30/sec" for this game. That table is right, and it is describing the **broadcast** rate. It says nothing about integration rate, and **integrating at 30 Hz would be a serious bug** — see §4.6. [`README.md`](./README.md) §4 records this disagreement; it is a clarification rather than a contradiction.

## 3.3 Interpolation delay: 100 ms — and the number is in milliseconds, not ticks

[`SNAKE.md`](../SNAKE.md) §2.4 fixes Snake's delay at 0.25 s and describes it as "2.5 ticks". **Copying "2.5 ticks" into Air Hockey would reintroduce the exact bug that doc exists to fix**, and this is the most important sentence in this section.

At Snake's 10 Hz, 2.5 ticks is 250 ms, and the margin before the buffer runs dry is 250 − 100 = **150 ms of tolerable lateness**. At Air Hockey's 30 Hz, 2.5 ticks is 83 ms and the margin is 83 − 33 = **50 ms**. Fifty milliseconds is precisely the figure [`SNAKE.md`](../SNAKE.md) §2.3 identifies as the shipped failure: *"any frame more than 50 ms late leaves nothing to interpolate toward. The pair search falls through, `t` clamps to 1.0, and the render freezes on the newest frame until another arrives — then jumps."*

**The buffer margin is a property of the network, not of the tick rate.** Mobile jitter does not get smaller because the server ticks faster. So the delay is chosen in absolute time and the tick count is whatever falls out.

**Air Hockey: 100 ms interpolation delay (3 ticks at 30 Hz), giving 67 ms of lateness tolerance**, plus bounded extrapolation to 120 ms beyond that (§3.5) for a total tolerance of ~187 ms.

The tradeoff, stated honestly: 100 ms of visual latency on the puck. At a typical rally speed of 700 u/s that is 70 units — three puck radii. It is a real offset. It is also *consistent*, and a consistent offset is something a player calibrates to within about four rallies, whereas a buffer underrun is a freeze-and-jump that nobody calibrates to. Snake's fix comment makes the identical trade: 100 ms of extra latency "is not perceptible — the snake does not stop and start, it curves."

**Why 100 and not 150.** Because the puck is predicted rather than interpolated (§3.4), the delay only governs the *opponent's paddle*, and the opponent's paddle is the one object whose exact position never determines your action. 100 ms is enough margin for the object that can afford it.

## 3.4 What the client predicts, and how a misprediction is reconciled

Three objects, three different treatments, and this split is the design.

### Your own paddle — drawn at your finger, zero latency

The paddle is under the player's thumb. Any latency at all reads as the screen being broken, in a way that is qualitatively worse than a laggy character, because a finger-following object has no fiction to hide behind. [`SnakePredictor.swift:7-11`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L7-L11) makes this argument for the snake head: *"no amount of smoothing fixes a control that lags — it just makes a laggy control smooth."* It is more true here.

So: **the local paddle is drawn at the clamped finger position, immediately.** The client applies the same clamps the server does — own half, inside the table, max speed 2000 u/s — so what is drawn is always something the server will agree with. Reconciliation is then almost never needed, and when it is (the client's clamp disagreed, or a frame was lost) the correction blends over **100 ms**, matching [`SnakePredictor.swift:66`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L66)'s `correctionTime` of 0.15 s scaled for a faster game. A correction beyond **150 units** hard-snaps rather than blending, the same structure as [`SnakePredictor.swift:62`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L62)'s `hardSnapDistance`, and for the same reason: a correction that large means something prediction cannot model happened, and easing toward it draws a long wrong line.

### The puck — predicted, not interpolated

**This is the non-obvious decision and it is the one that makes the game feel good.**

The instinct is to interpolate the puck between server frames like everything else. Do not. **A puck is ballistic and deterministic between collisions** — its entire future is `position + velocity × dt` with known wall reflections — so a client running the same integrator produces the *same answer the server will*, not a guess. Interpolating it would deliberately render 100 ms in the past an object whose present position is exactly computable.

So the client runs `physics2d` locally, at the same fixed 240 Hz substep, seeded from each server frame:

- **Between collisions:** the client is exactly right, to floating-point.
- **On a collision with your own paddle:** the client is right, because it knows your paddle's position with zero latency. **The hit you see is the hit that happens.**
- **On a collision with the opponent's paddle:** the client is wrong, because the opponent's paddle is only known 100 ms in the past. This is the one case that mispredicts.

That last case is where the design pays off, because **an opponent paddle collision happens in the opponent's half — the far end of the table, hundreds of units away from where the player is looking.** A correction there is both rare (a few times a match) and distant. Contrast the alternative: interpolating the puck makes it wrong *all the time, everywhere, including in your own hand*.

Reconciliation on every server frame: compare predicted puck state at the server's timestamp against the authoritative one.

| Error | Response |
|---|---|
| < 8 units | Ignore. Below the resolution of a 22-unit puck on a phone |
| 8–120 units | Blend position over **80 ms**, and adopt the server's velocity **immediately** |
| > 120 units | Hard snap, and flash the puck's trail for 100 ms so the jump reads as an event rather than a glitch |

Velocity is adopted immediately even during a position blend, because velocity is what the next 300 ms of the simulation depends on. Blending velocity would keep the client integrating a wrong future while it corrects a stale past — the error would regenerate faster than the blend removed it.

### The opponent's paddle — interpolated at 100 ms

The one object that is genuinely unknowable. Standard interpolation through the jitter buffer, exactly as Snake does for remote snakes.

## 3.5 Free-running render clock — a requirement, not an optimisation

**Stated as a hard requirement**, because [`SNAKE.md`](../SNAKE.md) §2.2 documents this bug shipping on both platforms simultaneously and both renderers were "ported line-for-line including the bug."

> The render clock must **never** be re-anchored to frame arrival time.

The failing pattern, which must not appear anywhere in this game's client code:

```swift
let elapsed = CACurrentMediaTime() - newest.arrivedAt      // ← the bug
let renderT = newest.state.time + elapsed - interpDelay
```

The required pattern is [`SNAKE.md`](../SNAKE.md) §2.4's `advanceClock`: a persistent clock in **server time** that advances on the local display clock and closes drift by adjusting its **rate**, never its position. Same constants on both platforms — 0.5 s resync threshold, ±10% rate clamp, 0.5 drift gain.

**Air Hockey is more sensitive to this than Snake, not less.** Snake's world is a camera-followed field where a 20 ms clock snap moves everything a few units and the camera spring absorbs most of it. Air Hockey's table is *static geometry filling the screen*: the walls, the goals and the centre line do not move, so any clock error appears as the puck jittering against a fixed reference the eye is locked onto. The diagnostic [`SNAKE.md`](../SNAKE.md) §2.6 gives applies directly — **if the table edges are steady and the puck is not, the clock is wrong.**

If the clock is correct, Air Hockey should be the *easiest* game in the app to verify, precisely because it has a fixed frame of reference.

## 3.6 Uplink latency and the intercept problem

Downlink is handled (§3.4). Uplink is the other half and it is a real problem worth naming: **your paddle position reaches the server one uplink latency late.** At 60 ms one-way and 2000 u/s that is 120 units of paddle travel the server has not seen yet. A fast intercept — thumb flicking across to meet the puck — can be a save on your screen and a goal on the server's.

The two standard fixes and why we pick the second:

| Fix | Verdict |
|---|---|
| **Rewind** — server keeps a ring buffer of puck states, rewinds to the client's stamped render time to resolve the hit | **No.** Produces the "hit around a corner" artifact: the opponent watches the puck reverse direction from a position it had already left. In a 2-player game where both players watch the same puck continuously, this is far more visible than in an FPS |
| **Paddle dead reckoning** — server integrates each remote paddle forward along its last known velocity between input frames, bounded | **Yes** |

**Dead reckoning, concretely:** each paddle carries `(x, y, vx, vy)` server-side. Between input frames the server advances it by `v · dt` during physics substeps, capped at **60 ms of extrapolation** and clamped to the half and the table. When the next input frame arrives, position is set from it and velocity is recomputed from the delta.

Why this is the right side of the trade: the paddle is under continuous, smooth control — a thumb travelling at 2000 u/s does not reverse in 60 ms — so extrapolating it forward is usually right. And when it is wrong, the error is **a paddle in slightly the wrong place**, which produces a slightly different deflection angle. Nobody can detect a wrong deflection angle. A rewound puck reversing mid-flight is detectable by everyone.

**Input rate: 60 Hz**, which is exactly what the runtime already allows. [`limitFor`](../../../backend/games/src/index.ts#L45-L48) computes `tickHz × 60 × CONTINUOUS_HEADROOM` = 30 × 60 × 2 = 3600/minute = 60/s. Sending paddle position at twice the tick rate halves the dead-reckoning window and needs no change to the rate limiter — the headroom constant was already chosen for this ([`index.ts:32-42`](../../../backend/games/src/index.ts#L32-L42)).

## 3.7 What happens on a 3-second network stall

Concretely, in order:

1. **0–100 ms.** Nothing visible. The interpolation delay is absorbing it, which is its job.
2. **100–220 ms.** Buffer dry. The client extrapolates: the puck continues under local physics (which is *right*, since it is deterministic), the opponent's paddle continues along its last velocity for up to **120 ms** and then holds. Snake's equivalent bound is 100 ms ([`SNAKE.md`](../SNAKE.md) §2.4 fix 3); slightly longer here because the puck extrapolation is genuinely accurate rather than a guess.
3. **220 ms–1.2 s.** The opponent's paddle is held still. The puck keeps moving under local physics and **stays believable** — it bounces off walls correctly, because walls are not networked. A short stall in Air Hockey is nearly invisible, which is a direct dividend of predicting the puck.
4. **> 1.2 s.** A "Reconnecting…" chip appears in the HUD ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §7). The puck **stops** rather than continuing indefinitely — after a second the local simulation has almost certainly diverged, and continuing to draw a confident wrong world is worse than admitting the gap. The table dims to 70%.
5. **On recovery.** The clock's 0.5 s resync threshold ([`SNAKE.md`](../SNAKE.md) §2.4) triggers a hard cut rather than a spring, because "springing across a gap this large would sweep the world instead of cutting". The puck hard-snaps with its trail flash (§3.4). Score and clock come from the frame and are simply correct.
6. **Meanwhile, on the server.** The stalled player's paddle stops receiving input. Dead reckoning bounds at 60 ms, then the paddle is stationary. **The match keeps running and the puck keeps moving** — the same posture as [`handleLeave`](../../../backend/games/src/index.ts#L427), which deliberately leaves multiplayer matches running because "ending a multiplayer match the instant one player backs out would penalize whoever is still playing." A stalled player concedes goals. That is harsh and it is correct: the alternative is that stalling is a defensive tactic.
7. **> 20 s with no input**, in a 90-second match: forfeit (§13.2).

## 3.8 Summary table

| Property | Value | Where the number comes from |
|---|---|---|
| Server broadcast | 30 Hz | §3.2 |
| Physics integration | 240 Hz fixed step | §4.6 |
| Client input | 60 Hz | Existing rate limit headroom, §3.6 |
| Interpolation delay | **100 ms** (3 ticks) | Chosen in ms, not ticks. §3.3 |
| Extrapolation bound | 120 ms | §3.7 |
| Puck | Client-predicted | §3.4 |
| Local paddle | Zero-latency, clamped locally | §3.4 |
| Remote paddle | Interpolated, dead-reckoned server-side | §3.4, §3.6 |
| Render clock | Free-running, rate-adjusted, never re-anchored | §3.5 — hard requirement |
| Bandwidth | ~7 KB/s per player | §3.2 |

---

# 4. Engine design — R1

Folder: `backend/games/src/engine/airhockey/`, plus the new shared `backend/games/src/engine/physics2d/`.

## 4.1 Interface surface

| Method | Present | Why |
|---|---|---|
| `applyInput` | yes | Paddle target. Returns `silent: true` |
| `tick` | **yes**, `tickHz: 30` | Its presence is what starts the loop ([`index.ts:107-108`](../../../backend/games/src/index.ts#L107-L108)) |
| `serialize` | yes | Complete, restart-exact |
| `serializeForWire` | **no** | §4.4 |
| `serializeForPlayer` | **no** | Nothing is hidden. Both players see the same table |
| `serializeSecret` | **no** | Nothing to hide |
| `deadlineAt` / `onTimeout` | **no** | Continuous game with its own clock; AFK is handled in `tick` (§13.2) |
| `isFinished` | yes | — |

Three "no"s in a row is worth noting: **Air Hockey needs none of the new infrastructure.** It is the one game in this folder that could be built today.

## 4.2 `applyInput`

```ts
{ px: number, py: number }   // desired paddle position, table coordinates
```

That is the entire input vocabulary. Not a velocity, not an impulse, not "I hit the puck" — a **desired position**, which the server clamps.

Position rather than velocity because position is self-correcting: a dropped input frame costs one frame of staleness and the next frame is absolutely right. A dropped velocity frame produces an error that never goes away. This is the same reasoning that makes Snake send a desired *heading* rather than a turn command ([`snake/index.ts:273-279`](../../../backend/games/src/engine/snake/index.ts#L273-L279)).

Like Snake's steering, **out-of-range values are clamped and accepted, not rejected**:

> *"Rejecting would be wrong here: unlike a chess move, a steering frame arriving during a lag spike is not an attempt to cheat, and dropping it would freeze the player's snake at its last heading. Clamping is both safer and kinder."* — [`snake/index.ts:275-279`](../../../backend/games/src/engine/snake/index.ts#L275-L279)

Clamps applied, in order: finite numbers; inside the table; inside the player's own half; and **displacement from the current position limited to `2000 × dt`** — the max-speed clamp, which is the anti-cheat (§5.1).

Returns `{ accepted: true, silent: true }`. Per [`GameEngine.ts:41-45`](../../../backend/games/src/engine/GameEngine.ts#L41-L45), a continuous game's input records intent and the tick is what makes it visible; broadcasting per input "would trigger a full state fan-out on every input frame ON TOP OF the tick broadcast". At 60 Hz input against a 30 Hz tick this would exactly triple fan-out for nothing.

## 4.3 `serialize()` — field by field

```ts
{
  players: string[],
  puck: { x, y, vx, vy },
  paddles: [{ x, y, vx, vy, tx, ty, lastInputAt }, ...],
  score: [number, number],
  clock: number,             // seconds of PLAY elapsed
  duration: number,
  phase: 'serve' | 'play' | 'goal' | 'sudden' | 'done',
  phaseUntil: number,
  accum: number,             // fixed-step remainder, SECONDS
  stallFor: number,
  seed: number,
  finished: boolean,
  winnerUserId: string | null,
  events: { k, x, y, ... }[],
}
```

Why each field must survive a restart:

- **`players`** — seat order, seat 0 defends `-y`. Lose it and both players defend the same goal.
- **`puck.x/y`** — obvious, and stored at **full precision**. Rounding is applied on the wire only. The reasoning is [`snake/index.ts:776-782`](../../../backend/games/src/engine/snake/index.ts#L776-L782)'s: a value fed back into itself accumulates rounding error rather than being merely slightly wrong once. The puck's position is integrated from its own previous value 240 times a second, so a 2-decimal round would drift it visibly within a rally.
- **`puck.vx/vy`** — the puck's entire future. Lose it and a restored puck sits dead on the table mid-rally.
- **`paddles[].x/y`** — current position.
- **`paddles[].vx/vy`** — **the field a naive design loses, and losing it changes the physics.** Paddle velocity is what transfers into the puck (§2.4) and what dead reckoning integrates (§3.6). If it resets to zero on restore, then for the first frames after any restart every paddle is a dead wall: the puck bounces off it with no energy added. The `serialize()`/`restore()` round-trip happens **on every input** ([`index.ts:279`](../../../backend/games/src/index.ts#L279)), so this is not a rare restart case — it would be *every single frame*, and the game would silently have no hitting in it at all. This is precisely the failure [`GameEngine.ts:62-63`](../../../backend/games/src/engine/GameEngine.ts#L62-L63) warns about: "Omitting a field here silently resets it on the next tick."
- **`paddles[].tx/ty`** — the last requested target, so a restore does not discard a request that arrived between frames.
- **`paddles[].lastInputAt`** — simulation time of last input, for dead reckoning bounds and AFK detection. Simulation time, **never wall time**, for the reason [`README.md`](./README.md) §2.5 gives: a wall-clock timestamp survives a restart into a world where real time has passed but simulation time has not, and the paddle would jump forward through the gap.
- **`score`** — the result. The one field whose loss a player would actually report.
- **`clock`** — elapsed play seconds. Full precision, same argument as Snake's `t`.
- **`duration`** — from match options, clamped. Serialized so it survives and so the client never hardcodes it.
- **`phase`** / **`phaseUntil`** — a restore during the 1.4 s goal pause must resume the pause, not resume play with a puck sitting still in someone's third while the opponent walks it in.
- **`accum`** — **the field this game exists to demonstrate.** The fixed-step accumulator's remainder, in seconds (§4.6). Lose it and every restore silently discards up to one substep of time; at one restore per input, 60 times a second, that is a simulation that runs measurably slow. This is the "tick proof" requirement made concrete.
- **`stallFor`** — seconds the puck has been under the stall threshold. Lose it and the anti-stall reset never fires, because the counter restarts before it can reach 3.
- **`seed`** — RNG state (§4.5).
- **`finished`** / **`winnerUserId`** — terminal state, recovered from the user id on restore, per [`cricket/index.ts:276-278`](../../../backend/games/src/engine/cricket/index.ts#L276-L278).
- **`events`** — goal, wall hit, paddle hit, with positions and impact speeds, for client VFX. Cleared at the top of every `tick()` exactly as Snake does ([`snake/index.ts:317`](../../../backend/games/src/engine/snake/index.ts#L317)).

**Not serialized:** anything derivable (puck speed, required goals), and anything wall-clock.

## 4.4 No `serializeForWire()`, and why that is the right call

[`README.md`](./README.md) §1.4 and [`GameEngine.ts:67-80`](../../../backend/games/src/engine/GameEngine.ts#L67-L80) say the split is "required for any game whose full state is bigger than what changes per frame." Air Hockey fails that test in the useful direction: **its full state is ~180 bytes and essentially all of it changes every frame.** The puck moves, both paddles move, the clock advances. There is no Snake-style bulk (260 pellets that never move, 59% of the payload) to factor out.

Adding the split anyway would cost a second serialization path that must be kept in agreement with the first — which is exactly where Snake's subtlest bug lived ([`snake/index.ts:697-701`](../../../backend/games/src/engine/snake/index.ts#L697-L701): the wire method incremented a counter that `serialize()` was supposed to reset, so "every single frame sent a full snapshot, and the delta encoding silently did nothing at all"). Two shapes with an invariant between them is a real ongoing cost, and it buys nothing here.

**What we do instead** is the cheap half of Snake's approach with none of the complexity: short keys, flat arrays, and rounding applied at the boundary. Positions to 1 decimal, velocities to 1 decimal, `clock` and `accum` unrounded because they feed back into themselves. That is a `round()` helper in the serializer, not a second state shape.

Worth noting for a future Pool: **Pool will need the split**, because 16 balls at rest is exactly Snake's food problem.

## 4.5 RNG and determinism

`Rng` (mulberry32) from [`geometry.ts:113`](../../../backend/games/src/engine/snake/geometry.ts#L113), promoted to `engine/rng.ts`.

Air Hockey barely uses randomness, and that is a feature — a physics game where the same inputs produce different results is a physics game nobody can learn. Two draws:

1. **The opening serve direction**, ±20° from straight, so the first rally is not identical every match.
2. **A ±0.5° jitter on wall reflections.** Deliberate, small, and worth defending: a perfectly elastic rectangular table has *periodic orbits* — a puck struck at certain angles bounces forever in a closed loop without approaching either goal. A half-degree of jitter destroys the periodicity and is far below perceptual threshold. It is the same instinct as Snake's bot jitter.

**Seed is public in `serialize()`**, alongside Sea Battle and against the other six games ([`README.md`](./README.md) §1.3). The test is whether a future draw is information a player would pay for. Here the draws are a serve angle already visible the instant it happens and a half-degree wall jitter. Nothing to buy.

Everything else is deterministic: same state, same inputs, same result, on any machine, at any tick timing. That is what makes the headless test possible and it is what makes §4.6 verifiable.

## 4.6 Tick-rate independence — the fixed-step accumulator

**This is R1's central requirement for this game and the reason it is worth building second.**

### The problem

`tick()` takes no arguments, so Snake hardcodes `const dt = 1 / TUNING.TICK_HZ` ([`snake/index.ts:315`](../../../backend/games/src/engine/snake/index.ts#L315)). And when a tick runs long, the `running` guard **drops the next one entirely** ([`index.ts:231-237`](../../../backend/games/src/index.ts#L231-L237)):

```ts
let running = false;
const timer = setInterval(() => {
  if (running) return;      // ← the dropped tick
  ...
```

So the simulation does not run *late*, it runs **slow**. A 180-second Snake match is 1800 ticks and takes however long 1800 ticks take.

Snake survives this because nothing outside its simulation measures its clock. **Air Hockey does not survive it**, for two independent reasons:

1. **A 90-second clock is a promise to the player.** If dropped ticks make the match take 96 seconds of wall time, the countdown is a lie and the endgame — the whole point of the clock format (§2.5) — is unbounded.
2. **The two clients keep interpolating in real time while the server's simulation slows.** The server's timestamps fall behind wall time, the render clock's drift-closing loop (§3.5) runs permanently at its −10% rate clamp trying to catch a target that never arrives, and the puck plays in slow motion.

Also, integrating at 30 Hz *at all* would be wrong even with perfect timing: a 1400 u/s puck moves **47 units per tick** against a 22-unit radius and a 40-unit paddle. A discrete position test would let the puck pass clean through a paddle between samples. This is the same tunnelling problem [`geometry.ts:8-13`](../../../backend/games/src/engine/snake/geometry.ts#L8-L13) already documents for Snake — *"at 12 Hz a head covers ~35 units per tick against an 11-unit radius, so tunnelling would be the common case, not the edge case"* — and [`snake/index.ts:410-417`](../../../backend/games/src/engine/snake/index.ts#L410-L417) records the speed increase that turned it from theory into a shipped bug.

### The answer

**Integrate physics at a fixed 240 Hz, independently of the broadcast tick.**

```ts
const FIXED_DT = 1 / 240;
const MAX_CATCHUP = 0.25;    // seconds of debt we will ever pay in one tick

tick(dtMs?: number): { changed: boolean; outcome?: GameOutcome } {
  // dtMs when the runtime supplies it (README §2.5), else the nominal interval.
  const elapsed = Math.min((dtMs ?? 1000 / TICK_HZ) / 1000, MAX_CATCHUP);
  this.s.accum += elapsed;

  while (this.s.accum >= FIXED_DT) {
    this.step(FIXED_DT);           // the ONLY place physics advances
    this.s.accum -= FIXED_DT;
  }
  ...
}
```

Properties, each of which is the point:

- **A late tick produces more substeps, not different physics.** This is what "tick proof" means concretely for a physics game. The simulation is a pure function of elapsed time.
- **`accum` is in `serialize()`** (§4.3). The remainder is up to 4.2 ms of real simulation time; discarding it on every restore — which is every input, 60 times a second — is a simulation that loses ~2 ms per input and runs perceptibly slow.
- **`MAX_CATCHUP = 0.25`** bounds the spiral of death: if the process is starved for two seconds, we do not then run 480 substeps in one tick (which would starve it further). We drop the excess and accept that the simulation lost time. A bounded, visible loss beats an unbounded feedback loop, and it is the same instinct as [`SnakePredictor.swift:123`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L123)'s `min(now - lastStep, 0.05)` clamp — "a stall must not teleport the snake."
- **240 Hz means 5.8 units of puck travel per substep at max speed**, comfortably under the 22-unit radius. Combined with swept collision (§4.7), tunnelling is impossible rather than merely unlikely.
- **Cost:** 8 substeps per tick × 30 ticks = 240 substeps/second, each resolving one circle against four walls and two circles. That is a few thousand floating-point operations per second per match — roughly nothing, and orders of magnitude below Snake's per-tick cost of walking six body polylines.

### On `tick(dtMs)`

[`README.md`](./README.md) §2.5 proposes widening the signature and having the runtime pass true elapsed time. It is backwards-compatible — every existing engine ignores the argument.

**Air Hockey works either way**, and this is deliberate: with the argument, the accumulator is fed true elapsed time and the simulation tracks wall time exactly; without it, the accumulator is fed the nominal 33.3 ms and the simulation runs slow under sustained tick drops in exactly the way Snake does — but it is still *internally correct*, and it never produces wrong physics, only slow physics.

**Recommend shipping `tick(dtMs)` with this game.** It is a one-line runtime change and it converts the remaining failure mode from "the match is silently 6% long" to nothing. The fallback of an engine measuring its own wall clock is available but worse: the clamp and the last-tick timestamp then live in every engine that needs them, and `lastTickAt` must **not** be serialized — after a restart wall time has passed but the simulation must not jump forward through it.

## 4.7 `physics2d/` — the shared module

New: `backend/games/src/engine/physics2d/`. Built shared from day one because Ping Pong and Pool are the same module with different constants ([`GAMES.md`](../../GAMES.md) §5).

```
physics2d/
  index.ts      — step(bodies, walls, dt): integrate, sweep, resolve
  sweep.ts      — swept circle-vs-circle, swept circle-vs-segment, time of impact
  resolve.ts    — impulse resolution with restitution + velocity transfer
```

**It knows nothing about air hockey.** No goals, no halves, no scores. It takes circles, segments and constants, and returns collisions. Goal detection, half-line confinement and scoring live in `airhockey/` — the same separation [`geometry.ts:1-6`](../../../backend/games/src/engine/snake/geometry.ts#L1-L6) draws for Snake ("this is the only part of Snake that is pure maths with no knowledge of matches, players or Redis... the part a future Air Hockey / Pool module will want to borrow").

**Reuse from [`geometry.ts`](../../../backend/games/src/engine/snake/geometry.ts) rather than reimplementing:**

- [`segmentSegmentDist2`](../../../backend/games/src/engine/snake/geometry.ts#L66) — the clamped-parametric closest-approach test, already chosen over the analytic form because "for near-parallel segments the analytic form is numerically unstable." Swept circle-vs-circle is exactly this test against the sum of radii.
- [`clamp`](../../../backend/games/src/engine/snake/geometry.ts#L23), [`dist2`](../../../backend/games/src/engine/snake/geometry.ts#L36), [`Rng`](../../../backend/games/src/engine/snake/geometry.ts#L113)

**Recommendation:** promote `geometry.ts` to `engine/geom.ts` (pure maths, no game knowledge) and leave the Snake-specific path helpers — `samplePath`, `trimPath`, `pathLength` — in `snake/`. That split is already implicit in the file's own header comment; Air Hockey is the second consumer that makes it worth doing.

**Wall collisions are swept, not discrete**, for the reason in §4.6. Each substep: compute time of impact along the motion, advance to it, reflect, and continue with the remaining substep time. Up to 4 iterations per substep, then give up and clamp — a puck genuinely wedged in a corner is the anti-stall rule's problem (§2.6), not the solver's.

---

# 5. Anti-cheat

Enumerate what a modified client can express, per [`snake/index.ts:8-13`](../../../backend/games/src/engine/snake/index.ts#L8-L13).

**A client sends one thing: a desired paddle position.** It does not send the puck, its velocity, whether it scored, or the clock. All of those are decided server-side.

## 5.1 The one attack that matters: paddle teleportation

A modified client claiming `px, py` far from its current position would, without a clamp, produce an infinite-velocity paddle — and since paddle velocity transfers into the puck (§2.4), an infinite-velocity puck. **This is the only cheat in the game with real leverage**, and it is defeated by one line in `applyInput`:

```ts
// Displacement clamped to what a paddle can physically travel since the last input.
// This is the entire anti-cheat surface of the game: a lying client just gets a paddle
// that moves as fast as it legally can, which it would do anyway.
const maxStep = PADDLE_MAX_SPEED * dtSinceLastInput;
```

Structurally identical to Snake's turn-rate clamp, which the file describes as *"the ONLY filter on requested heading, and it is what makes a lying client harmless: no matter what angle it asks for, it turns at the legal rate"* ([`snake/index.ts:350-352`](../../../backend/games/src/engine/snake/index.ts#L350-L352)).

Two implementation notes that matter:

- **`dtSinceLastInput` is simulation time, clamped to 100 ms.** Unclamped, a client that sends nothing for 5 seconds and then one frame would be granted 10,000 units of legal displacement — a teleport with extra steps. The clamp means idling buys nothing.
- **The clamp is applied to the position the server holds, not the one the client claims.** Otherwise a client can walk itself anywhere in a few frames.

## 5.2 Everything else

| Attempt | Result |
|---|---|
| Paddle outside its half | Clamped to the half line |
| Paddle outside the table | Clamped to bounds |
| Claim a goal | No input frame expresses it. Goals are detected in `step()` |
| Claim a puck position | No input frame expresses it |
| Slow the clock | Clock advances in `tick()` on the server |
| Flood inputs | Rate limiter: 3600/min, silent drop ([`index.ts:29-61`](../../../backend/games/src/index.ts#L29-L61)) |
| Send input to someone else's match | Rejected — membership is checked in the live record ([`index.ts:262-264`](../../../backend/games/src/index.ts#L262-L264)) |
| Send input after the match ends | `applyInput` returns `accepted: false` when finished, and `stopLoop` has dropped the engine |

## 5.3 What is *not* defended, honestly

**An aimbot.** A modified client that computes the optimal intercept and drives the paddle there perfectly is sending only legal inputs, at legal speeds. Nothing in the protocol distinguishes it from a very good player.

This is unfixable in a server-authoritative design, because the cheat is *good play*, and it is worth saying plainly rather than implying the design is airtight. What bounds the damage is context: matches are invite-only between people who already talk to each other ([`GAMES.md`](../../GAMES.md) §3), there is no ranked ladder and no reward, and there is no matchmaking with strangers ([`GAMES.md`](../../GAMES.md) §7 recommends against it). **Cheating at Air Hockey against your friend is a social problem, not a technical one**, and the correct amount of engineering to spend on it is zero.

If public matchmaking ever ships, revisit: the detectable signal is superhuman *consistency* of intercept timing, not any single input.

---

# 6. Client rendering

## 6.1 What it reuses

| Piece | Source | Notes |
|---|---|---|
| **Jitter buffer** | [`SnakeMetalView.swift`](../../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift) / [`SnakeArenaScreen.kt`](../../../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt) | 8-frame ring, pair selection on the server's clock. **Lift as-is** |
| **Render clock** | [`SNAKE.md`](../SNAKE.md) §2.4's `advanceClock` | Lift the *fixed* version, with identical constants |
| **Predictor structure** | [`SnakePredictor.swift`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift) / [`SnakePredictor.kt`](../../../apps/android/app/src/main/java/com/voiid/app/main/games/SnakePredictor.kt) | The reconcile/blend/hard-snap shape carries over exactly; the motion model is replaced |
| **`GamesEngine`** | existing | Unchanged |
| **`GameAudio` / `GameHaptics`** | [`GameAudio.swift`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift) | One new entry in `soundNames(for:)` |
| **Lobby / invite** | [`GameLobbyView.swift`](../../../apps/ios/Voiid/Voiid/Games/GameLobbyView.swift) | Unchanged, 2 seats |

**Extract the first three into a shared client module rather than copy-pasting them.** Copy-paste is how [`SNAKE.md`](../SNAKE.md) §2.2 describes the stutter bug reaching both platforms, and a second copy per platform is a second place for it to come back. Proposed: `Games/Netcode/JitterBuffer.swift` + `RenderClock.swift` on iOS and the Kotlin twins, with Snake migrated onto them as part of this work.

That migration is genuinely worth the cost: it means the stutter fix has **one** home per platform instead of four.

## 6.2 What it adds

**Not Metal.** [`SnakeMetalView.swift`](../../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift) is 1722 lines because Snake draws six SDF-shaded, continuously-lengthening polylines at 60 fps with a custom shader. Air Hockey draws **three circles, four lines and two rectangles**. SwiftUI `Canvas` inside `TimelineView(.animation)` renders that with room to spare, and it is what [`GAMES.md`](../../GAMES.md) §4 specifies.

Arguing this explicitly because "reuse before invention" cuts both ways: the Metal path *exists*, so reaching for it looks like reuse. It is not — it is inheriting a shader pipeline, a display link, and the `nonisolated(unsafe)` snapshot race [`SNAKE.md`](../SNAKE.md) §2.5 documents, for a scene with nine primitives.

**iOS:** `Canvas` + `TimelineView(.animation)`. One `Canvas` for the table (static, drawn every frame but trivially), one for the puck/paddles/trail.

**Android:** Compose `Canvas` + `withFrameNanos`. Use `withFrameNanos`'s value as the clock source, per [`SNAKE.md`](../SNAKE.md) §2.4: *"so the clock advances on the display's cadence rather than the network's."*

**No camera.** The table fits the screen. This removes the entire camera-spring layer that Snake needs and is a large simplification — and it is why the "static geometry is a perfect jitter detector" property of §3.5 holds.

## 6.3 The one genuinely new piece: the puck trail

A motion trail behind the puck, ~10 positions from the local prediction history, fading and narrowing. It does three jobs:

1. Makes a fast puck **legible**. At 1400 u/s across a 60 Hz display the puck moves ~23 units between frames — more than its own radius — and a bare circle at that speed reads as a strobe.
2. Communicates speed without a number.
3. Makes a hard correction (§3.4) legible as an event rather than a glitch: the trail flashes and the eye follows it.

Drawn from the **predicted** history, not the server's, so it is smooth at display rate rather than stepped at 30 Hz.

---

# 7. Controls

## 7.1 Direct touch, always

**The paddle is under your finger.** No joystick, no relative dragging, no acceleration curve.

Air Hockey is the one game in the catalog with a real-world control that is already perfect, and every deviation from it is a downgrade. Snake needs a joystick because the snake is elsewhere on a scrolling arena; Air Hockey's table is entirely on screen at 1:1, so the mapping is trivially direct.

- **Touch down anywhere in your half:** the paddle moves to the finger at max speed (it does not teleport — teleporting is what §5.1 forbids, and the same clamp is applied client-side so what you see is what the server does).
- **Drag:** the paddle follows 1:1.
- **Release:** the paddle stays where it was, keeping its velocity for one dead-reckoning window and then stopping.
- **Touch in the opponent's half:** ignored, and the paddle clamps to the half-line if the finger crosses it. The paddle visibly *presses against* the line rather than freezing, so it reads as a wall rather than as lost input.

## 7.2 The occlusion problem, and the honest answer

**Your finger covers the paddle and some of the table around it.** This is inherent to direct touch on a small screen and it cannot be designed away — only mitigated:

- **The paddle is drawn larger than the contact patch** (40-unit radius ≈ 26 pt on a phone against a ~30 pt fingertip), so its edge is visible around the finger.
- **A bright rim on the paddle**, so the part that peeks out is the part that matters — the edge is what strikes the puck.
- **The puck's trail** (§6.3) means an approaching puck is visible before it reaches the occluded region.
- **The action is mostly at the far end.** You defend near your goal at the bottom; the puck spends most of a rally elsewhere.

An offset control — paddle rendered 40 pt above the finger — was considered and **rejected**. It solves occlusion and breaks the 1:1 mapping that makes the control feel like a real paddle, and it puts the paddle *off* the table when the finger is near the bottom edge, which is exactly where you defend.

## 7.3 One-handed and small screens

Direct touch is inherently one-handed: your half is the bottom half of the screen, which is thumb territory. This is the only game in the folder with no reachability problem.

**Handedness is a non-issue** (the table is symmetric), which is worth noting because [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §12 flags left/right-handed layout as missing app-wide.

**On a small screen the table shrinks, not the play area.** The full 600×1200 table is always fully visible; on a 4.7" phone that is a smaller table in points, and both players' tables are scaled by their own screen. Two players on different phones play the *same* game in world units and see it at different physical sizes. That is correct and must not be "fixed" by cropping — cropping would give a large-screen player more visible table, which is a real advantage.

---

# 8. Visual design

## 8.1 Art direction

**Neon on dark, and it is the one place in this folder where Snake's palette should be inherited directly.** [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.2 argues Snake's abstraction is a feature — *"it is an abstract neon arcade game, not a physical one... there is no real-world referent for 'a glowing snake eats a pellet,' and chasing one produces worse sound, not better."* Air Hockey **does** have a real-world referent, and we are still choosing abstraction over it, so the reasoning has to be different.

The reason: a photoreal air hockey table on a phone is a picture of a piece of furniture, most of which is bezel. The interesting parts — where the puck is, how fast, where it will bounce — are geometry, and geometry reads better as light than as laminate. It also makes the puck trail (§6.3) native to the look rather than an effect stuck on top.

- **Table:** near-black, a subtle radial vignette, a faint grid at low opacity for parallax and speed reference.
- **Walls:** thin bright rules that **flash on impact**, brightness scaled by impact speed and decaying over 180 ms. Free feedback from data already in `events`, and it teaches wall physics without a tutorial.
- **Goal mouths:** a bright gradient bar, each player's own goal in their colour. **The mouth pulses when the puck is inside 200 units and closing** — the danger indicator [`SNAKE.md`](../SNAKE.md) §3.2 says the border should have had.
- **Puck:** a bright disc with a soft bloom, trail behind.
- **Paddles:** rings, not discs, so the puck is visible when overlapping. Player colours from the existing palette.
- **Centre line:** dim, dashed. Enough to make the half-rule visible without dividing the composition.

## 8.2 Colour is not the only channel

[`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13: Snake identifies players by colour alone. Do not repeat it.

- **Your paddle is a solid ring; theirs is dashed.** Distinguishable in greyscale.
- **Your goal is at the bottom, always.** Position, not colour, is the primary channel for the most important fact on the screen.
- Score labels are `YOU` and the opponent's name, never two coloured numbers.

## 8.3 The HUD

Minimal — this is a 90-second game and the player has no attention to spare.

1. **Score**, large, top centre: `2 – 1`. Yours on the left, always.
2. **Clock**, under the score. Turns amber inside 15 s, red inside 5 s, with a 1 Hz pulse.
3. **Opponent name**, small, at the top.
4. **Nothing else.** No power meter, no combo counter, no stat overlay. Everything else is communicated by the table itself.

**A goal is a full-screen event**, not a HUD update: the scoring player's colour washes the table at 25% for 400 ms, the score digit scale-pops, the conceding goal mouth flares white. In a 90-second match with maybe 6 goals, each one gets to be an event.

---

# 9. Motion and feel

All of this is behind the reduce-motion switch that does not exist yet ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13, open question O13). Under reduce-motion: no screen shake, no hitstop, no colour wash — the goal becomes a 200 ms border flash and a score change. **The game must remain fully playable with every effect below disabled**, which is the test that separates feel from information.

| Moment | Motion | Duration | Curve |
|---|---|---|---|
| Paddle follows finger | 1:1, clamped to max speed | — | None. Any smoothing here is latency |
| Puck-paddle hit | Paddle ring scale 1.0 → 1.12 → 1.0; puck stretches 1.25× along velocity for 2 frames | 120 ms | `spring(response: 0.14, damping: 0.5)` |
| **Hitstop on a hard hit** | Global time scale 0.12× for **50 ms**, only when impact speed > 900 u/s | 50 ms | Step |
| Wall bounce | Wall segment brightness → 1.0, decays; puck squashes 1.15× perpendicular for 2 frames | 180 ms | `easeOut` |
| Goal | Table colour wash 25%, goal mouth flare, score pop 1.0 → 1.3 → 1.0, **6 px screen shake decaying over 240 ms** | 400 ms | wash `easeOut`, pop `spring(0.3, 0.55)` |
| Goal reset | Puck fades in at the serve point, one pulse ring | 1.4 s total, puck visible at 400 ms | `easeInOut` |
| Clock < 15 s | Clock scale pulse 1.0 → 1.06 at 1 Hz | 300 ms per pulse | `easeInOut` |
| Sudden death start | Table edges pulse, "NEXT GOAL WINS" fades in and out | 1.2 s | `easeOut` |
| Match end | Puck freezes, table dims to 40%, result card rises | 500 ms | `spring(0.4, 0.85)` |
| Puck hard correction | Trail flashes to full brightness, decays | 100 ms | `easeOut` |

**On hitstop.** Snake already ships a hitstop-dilated `dt` in the camera spring ([`SNAKE.md`](../SNAKE.md) §1) and it is the single cheapest way to make an impact feel heavy. 50 ms at 0.12× is the standard fighting-game value. **It must dilate only the render clock's presentation, never the simulation** — the server has no idea hitstop happened, and a client that paused its own physics would immediately need a correction.

**On the 900 u/s threshold.** Hitstop on every touch would make a rally feel like a stutter, which is precisely the symptom [`SNAKE.md`](../SNAKE.md) §2 exists to eliminate. Reserving it for genuinely hard hits — perhaps a quarter of touches — is what keeps it meaning "that was a big hit" rather than becoming the texture of the game.

---

# 10. Sound

Inherits [`SOUND_DESIGN.md`](../SOUND_DESIGN.md). New entry in `soundNames(for:)` ([`GameAudio.swift:282`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L282)) and its Android twin.

## 10.1 The shared catch sound

> **The catch moment in Air Hockey is: your shot is stopped by their paddle while travelling toward their goal.**

Precise, because the rule is precise — `catch` means "a player's attempt is intercepted or ended by the opponent" ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §3). Not every paddle touch. An attempt is a puck you struck that is heading for their goal; intercepting it is the catch.

The condition, testable server-side and sent as an event flag: the puck was last struck by you, its velocity had a component toward their goal, its trajectory would have entered the goal mouth, and their paddle stopped it. That last clause is what makes it a save rather than a random deflection, and computing it is a ray-vs-goal-mouth test the engine is already doing for the danger indicator (§8.1).

Layered, never replacing: `catch.wav` **+** the normal `puck_paddle` impact, gain-matched. Unmodified, no pitch offset.

**A save should be as loud as a goal.** In a 90-second match with six goals there might be four saves, and each is the emotional peer of a goal — the shared sound is what makes the app say so.

## 10.2 The palette

Physical. Air hockey has a famously specific sound — hard plastic on laminate in a resonant cabinet — and it is trivially recordable.

| Event | Sound | Notes |
|---|---|---|
| Puck hits wall | `puck_wall_1..3.wav` | ~90 ms. **Gain and pitch scale with impact speed**: gain 0.3→1.0 over 200–1400 u/s, pitch ±8% via existing varispeed. The most-triggered sound in the game — 20-40× a match — so 3 variants minimum, per the chalk argument ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.3) |
| Puck hits paddle | `puck_paddle_1..3.wav` | Deeper, softer than a wall — the paddle absorbs. ~120 ms |
| **Save** | **`catch.wav`** + `puck_paddle` | §10.1 |
| Hard hit (> 900 u/s) | `puck_smack.wav` | Layered over `puck_paddle`. The sound of the hitstop |
| **Goal** | `goal_horn.wav` + `crowd_cheer` (own) / `crowd_groan` (conceded) | Reuses cricket's crowd one-shots. The horn is short and bright, ~600 ms, and must not outlast the 400 ms wash by much |
| Puck reset | `puck_drop.wav` | Puck settling onto the table |
| Clock < 15 s | `tick_urgent.wav` | 1 Hz, quiet, rising slightly in gain to 0:00. **Silent in sudden death** — sudden death has no clock and a tick would be a lie |
| Sudden death | `sudden_death.wav` | One rising tone |
| Match end | Existing stingers | — |

**No table ambience.** Cricket's crowd bed works because cricket is *about* atmosphere and has long pauses. Air Hockey is 90 seconds of near-continuous impacts; a bed underneath would compete with the sounds that carry information. The silence between hits is what makes the hits land.

**Mono, always.** [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §6.6 — a stereo asset on the mono-wired bus is a hard AVAudioEngine crash.

## 10.3 Haptics

The highest-value platform in this game, because you are already touching the screen where the action is.

| Event | Pattern |
|---|---|
| Puck hits your paddle | Sharp transient, intensity scaled by impact speed. The core feedback — you *feel* the hit through the glass |
| Puck hits a wall near you (< 300 units) | Light tick, 40% intensity |
| Goal scored by you | The existing `kill()` shape ([`GameHaptics.swift:73`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameHaptics.swift#L73)) |
| Goal conceded | The existing `death()` shape ([`GameHaptics.swift:89`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameHaptics.swift#L89)) |
| Paddle hits the half-line | Very light continuous buzz while pressing — communicates the wall without a visual |

**Haptics fire on the client's prediction, not on the server frame.** They must be synchronous with the visual or they read as an echo, and the prediction is right for your own paddle by construction (§3.4). This is safe precisely because the local hit is the one case prediction cannot get wrong.

---

# 11. Bots

Practice mode, client-side, like [`RpsBot.swift`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift) and [`CricketBot.swift`](../../../apps/ios/Voiid/Voiid/Games/CricketBot.swift).

The standard is [`RpsBot.swift:7-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L7-L21), which refuses to fake a scale. The anti-pattern is Snake's "difficulty = more bots of identical ability" ([`SNAKE.md`](../SNAKE.md) §3.4).

## 11.1 What difficulty actually varies

Four axes, all continuous in `skill` (0.0–1.0). Crucially **the bot is subject to the same physics and the same 2000 u/s paddle cap as the player** — it cannot teleport, and it plays through the same `applyInput` clamps.

| Axis | skill 0.0 | skill 1.0 | Why this axis |
|---|---|---|---|
| **Reaction latency** | 420 ms | 90 ms | The most human axis. A slow bot is late to everything and it *reads* as slow rather than as bad |
| **Prediction depth** | Aims at the puck's current position | Simulates the puck forward through **2 wall bounces** to an intercept point | The difference between chasing and anticipating, and it is exactly what a good human does |
| **Aim precision** | Clears in a random forward direction | Aims at the far goal corner, weighted away from the player's paddle | Turns defence into offence |
| **Positioning** | Sits at the goal | Holds a defensive arc, steps forward on a slow puck to attack | Where the game's actual strategy lives |

Between levels the bot plays the higher behaviour with probability `skill` and the lower otherwise — the construction [`RpsBot.chooseThrow`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L50) uses. This makes a mid-skill bot *inconsistent* rather than *uniformly mediocre*, which is much closer to a human and much more satisfying to beat.

**Difficulty does not vary paddle speed, paddle size, or puck behaviour.** Every one of those is a cheat dressed as difficulty, and each is instantly detectable: a player who loses to a paddle that moved faster than theirs knows they were cheated even if they cannot articulate it.

## 11.2 What the top of the scale can and cannot do

**It can:** intercept nearly anything reachable from a defensive position, and place shots at goal corners. It will beat a first-time player comfortably and a casual player most of the time.

**It cannot:** predict beyond 2 bounces, so a deliberate 3-bank shot beats it. React inside 90 ms, so a rebound off its own paddle at close range beats it. Change its mind once committed to an intercept — **it is beatable by feinting**, because it commits to the intercept point ~200 ms out and a puck struck late into the space it left goes in.

That last property is deliberate and is the design's best feature: **the top bot has a specific, learnable weakness that maps onto a real skill.** A player who learns to feint has learned something that also works against humans. Compare a bot that is beaten by "playing better", which teaches nothing.

**It is not unbeatable, and Air Hockey's top bot could trivially be made unbeatable** — a paddle that always sits exactly on the puck's intercept point concedes nothing, ever. We do not do that, for the reason [`RpsBot.swift:19-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L19-L21) gives about its own honesty: an unbeatable opponent is not a difficulty level, it is a wall, and the top of a difficulty slider should be *a very good player*, not *a solved game*.

## 11.3 Presentation

- The bot's paddle moves with **acceleration**, not at instant max speed. A paddle that jerks to top speed instantly reads as a machine even when its play is human.
- **It overshoots slightly and corrects** on fast intercepts, ±15 units, scaled inversely with skill.
- Plausible names, from a pool like [`snake/index.ts:95-101`](../../../backend/games/src/engine/snake/index.ts#L95-L101)'s — "a bot labelled as a bot changes how players treat it."

---

# 12. Progression and retention — R3

## 12.1 The floor

All four from [`README.md`](./README.md) §1.6 ship with the game: rematch with the opponent's name, post-match summary, head-to-head record, share-to-chat.

**For Air Hockey the rematch button is not a retention feature, it is the product.** A 90-second match is not a session. Five of them is. The post-match screen has one obvious primary action and it is REMATCH — sized, coloured and positioned accordingly, with `Exit` secondary.

Concretely: **rematch must be one tap and must not re-enter the lobby.** The current flow requires "a whole new invite, then they have to accept it again" ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §1). For this game that is fatal — the six-tap round trip is longer than the match. Both players tapping REMATCH within 10 s should start the next match immediately, in place, with a 3-second countdown and no lobby screen.

## 12.2 The specific hook

**The score is always close, and it is always your fault.**

Unpacking that, because "it's fun" is not an answer. Air Hockey has three properties that compound:

1. **No luck to blame.** Deterministic physics, symmetric table, identical paddles. Every goal traces to a specific decision — you left your goal, you mistimed the intercept. [`SNAKE.md`](../SNAKE.md) §4 identifies exactly this as the top retention lever: *"Turns deaths from 'unfair' into 'my fault.' A game you can't blame is a game you replay."* Air Hockey has that property by construction rather than by HUD work.
2. **Matches are close by construction.** Skill differences show up as 5-3, not 5-0, because a 90-second clock bounds the damage and every goal resets to a neutral-ish state. A close loss is the single most replay-inducing outcome in games.
3. **The rematch cost is 90 seconds.** Low enough that "one more" is always rational.

## 12.3 How it uses the fact that this is a messenger

The weakest of the eight on this axis, and it should be admitted rather than dressed up. Air Hockey needs both players present, which is the one thing a messenger cannot manufacture.

What it does have:

- **"Are you free for 90 seconds?" is a message someone will actually answer.** The invite's *shortness* is the pitch. A chess invite asks for an evening.
- **A live match makes a chat thread synchronous**, which is what people already want from a messenger and rarely get.
- **The result is a one-line message.** `5–3` needs no card renderer and no explanation.
- **The running score across a session** is the real artifact: "we played 8, I won 5" is a thing to say in the thread, and it maps exactly onto the head-to-head record.

What it does not have: any async mode. **Do not invent one.** An async air hockey would be a different, worse game.

## 12.4 What the first 30 seconds feel like

- **0–2 s.** Accept. The table is on screen. No rules, no setup, no options.
- **2–5 s.** A 3-second countdown, opponent's name at the top. Puck at centre.
- **5–8 s.** The player's thumb touches the screen and the paddle is *there*, exactly, immediately. **This is the moment the game is won or lost as a product** — direct, zero-latency touch is the entire first impression, and it is why §3.4 spends so much of its length on the local paddle.
- **8–15 s.** First rally. The puck hits a wall, the wall flashes and clicks. They hit the puck, it feels like hitting something. Nobody explained anything.
- **15–30 s.** Probably a goal, in either direction. Colour wash, horn, shake. They now know the whole game and there are 60 seconds left.

**Zero words of instruction.** No other game in this folder can say that, and it is the reason to build it early.

## 12.5 What someone with 50 matches is chasing

- **The head-to-head record.** Same as everywhere ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §4), and stronger here because 50 matches against one person is a genuine rivalry with 50 data points.
- **Bank shots.** The skill ceiling is entirely in the physics: two- and three-bank shots that arrive from an angle the opponent is not covering. This emerges from correct physics rather than from a feature, which is why §4.6's rigour matters — a simulation with tunnelling or inconsistent restitution makes bank shots unlearnable, and the ceiling collapses.
- **Defending the feint.** Reading whether an opponent will strike or hold.
- **The session score.** "First to 5 matches" is the format people invent for themselves, and the app should notice: if two players play three matches inside ten minutes, the post-match screen starts showing the session tally. Cheap, and it converts a series of matches into one narrative.
- **Longest win streak against each opponent.** One query on `game_match_results`.

Explicitly **not**: cosmetics, XP, unlocks. Air Hockey's replay value is the opponent and the physics. A progression bar would be a second, worse game bolted to a good one.

---

# 13. Failure and edge cases

## 13.1 Disconnect

Covered in §3.7 from the client's side. Server-side:

- The tick loop keeps running. A disconnected player's paddle dead-reckons for 60 ms, then holds. **The match continues.** Matching [`handleLeave`](../../../backend/games/src/index.ts#L427)'s posture for multiplayer matches.
- **Grace period: 20 seconds.** If no input arrives for 20 s in a 90-second match, the match ends with the present player as winner and honest scores. 20 s is a quarter of the match — long enough to survive a tunnel, short enough that the other player is not standing there for the whole match.
- **The remaining player is told.** "Priya disconnected — 12s" as a HUD chip, counting down. Ending a match with no explanation is [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §7's complaint restated.
- **Reconnect inside the grace period resumes seamlessly.** State comes from the next tick's broadcast; there is nothing to reconcile beyond a hard puck snap.

## 13.2 AFK

Indistinguishable from disconnect at the engine level and handled identically — no input for 20 s ends the match. There is no separate AFK detection and there should not be: a player who is present but not moving is losing anyway, at approximately the rate the rules intend.

**No deadline sweeper needed.** The game has a tick loop and its own clock; `deadlineAt`/`onTimeout` exist for games with no clock at all.

## 13.3 Both players disconnect

The loop keeps ticking to a natural end, then `endMatch` runs, then `finishMatch` clears the Redis key. Wasteful for at most 90 seconds. Not worth special-casing — the fix would be a presence check on the hot path, which is exactly the kind of per-tick network round trip [`index.ts:158-167`](../../../backend/games/src/index.ts#L158-L167) documents removing as "the periodic freeze."

## 13.4 The games process restarts mid-match

**This is the honest weak point of every continuous game and it applies here unchanged.**

[`index.ts:110-114`](../../../backend/games/src/index.ts#L110-L114): *"if the service restarts, in-flight arcade matches stop ticking and expire via the state TTL. GAMES.md §107 accepts exactly this."*

Air Hockey inherits that. A 90-second match interrupted by a deploy is lost. Acceptable, for the reason given there — "the alternative is a great deal of machinery for a 3-minute match", and Air Hockey's match is a third as long. **State is still persisted every 5 ticks** (`PERSIST_EVERY`, [`index.ts:155`](../../../backend/games/src/index.ts#L155)), so a match that *is* resumed loses at most 167 ms of simulation, and `accum` (§4.3) means even that resumes at the exact substep boundary.

What Air Hockey should add, cheaply: **on a lost match, both clients show "Match interrupted" rather than freezing**, and offer rematch. A 90-second match dying is annoying; a screen that hangs is a bug report.

## 13.5 Rejoin mid-match

Supported by `handleJoin`'s existing resync branch ([`index.ts:355-359`](../../../backend/games/src/index.ts#L355-L359)). The rejoining client gets a full state frame, initialises its jitter buffer and predictor from it, and plays. There is no delta state and no hidden state, so rejoin is genuinely trivial — the one benefit of having no `serializeForWire` and no `serializeSecret`.

**The predictor must be reset, not blended, on the first frame after rejoin** — [`SnakePredictor.swift:74-81`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L74-L81)'s `reset` exists for exactly this: "a stale prediction surviving into a new life would draw the snake at its previous corpse."

## 13.6 Ties

Handled in the rules (§2.5): 90 s sudden death, then a genuine draw with `winnerId: null`. Both players' `scores` are their goals.

The post-match screen must have a **real draw state** — not a win screen with different text. [`TICTACTOE.md`](../TICTACTOE.md) §2.2 flags that the draw there has no identity of its own; do not repeat it.

## 13.7 The puck escapes the table

Should be impossible with swept collision (§4.7), but "should be impossible" is what [`snake/index.ts:410-414`](../../../backend/games/src/engine/snake/index.ts#L410-L414) says about a head stepping over the wall, and it happened when the speed increased.

**Defence in depth:** at the end of every substep, if the puck is outside the table bounds by more than its radius and not inside a goal, it is teleported to the centre with zero velocity and an event is logged. A visible, recoverable glitch beats a puck that has left the universe and a match that can never end.

Log it loudly. If it ever fires in production, the collision solver has a bug and the log is how anyone finds out.

---

# 14. Build plan

## Phase 1 — `physics2d/`, headless

The shared module and its tests, with **no game around it**. Deliberately first: it is the only genuinely new code, it is pure maths, and it is fully testable in isolation.

Tests that matter:
- **Energy conservation** — a puck with damping 0 and restitution 1 in a closed box keeps its speed for 10,000 substeps.
- **No tunnelling** — a 1400 u/s puck fired at a paddle from every angle in 1° increments never passes through.
- **Tick independence** — the same 5 seconds simulated as 150 ticks of 33 ms, 300 ticks of 16.7 ms, and 50 ticks of 100 ms produce puck positions agreeing to within 0.01 units. **This is the R1 acceptance test for the whole game** and it should be the first test written.
- **Determinism** — same seed, same inputs, byte-identical results across runs.

## Phase 2 — `airhockey/` engine, headless

Rules on top of physics: goals, halves, clock, phases, scoring, anti-stall. Registry entry. Serialize round-trip test asserting byte equality — the test that catches [`GameEngine.ts:62-63`](../../../backend/games/src/engine/GameEngine.ts#L62-L63)'s silent-reset class, and specifically that `paddles[].vx/vy` and `accum` survive (§4.3).

Also here: **`tick(dtMs)`** in the runtime ([`README.md`](./README.md) §2.5). One line, backwards-compatible.

## Phase 3 — the shared client netcode module

Extract `JitterBuffer` and `RenderClock` per platform (§6.1), **and migrate Snake onto them**, including [`SNAKE.md`](../SNAKE.md) §2.4's fixes if they have not shipped by then.

Sequenced here deliberately: doing it before Air Hockey's renderer means the renderer is built on the shared thing rather than retrofitted. Doing it after means three more copies of a known bug.

## Phase 4 — iOS, practice mode

Renderer, direct-touch control, local physics, the bot at all four skill bands, sound, haptics, motion. **No networking** — the client runs `physics2d` ported to Swift.

This phase answers "is it fun" and it is where the tuning happens. Every constant in §2 will change here, which is why it precedes networking: tuning a physics game through a network is miserable.

**The Swift/Kotlin ports of `physics2d` must mirror the TypeScript exactly.** [`SnakePredictor.swift:21-23`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L21-L23) states the rule: "MUST MIRROR the server's `moveAll`. If the two drift apart, the correction blend grows and the snake starts to feel rubbery." Air Hockey has three copies of the physics; the tick-independence test from Phase 1 should be ported to both clients so drift is caught by CI rather than by feel.

## Phase 5 — iOS online

Wire to `GamesEngine`. Prediction, reconciliation, dead reckoning, stall handling, reconnect chip.

**Test with an artificial 0–40 ms ingest delay from day one**, per [`SNAKE.md`](../SNAKE.md) §2.6's repeatable test. Add 200 ms and 3 s stalls to the same harness. Netcode bugs found on a good office network are found by users.

## Phase 6 — Android parity

Both phases 4 and 5. iOS is the reference. **Identical constants**, per [`SNAKE.md`](../SNAKE.md) §2.4.

## Phase 7 — retention

In-place rematch (§12.1), post-match summary, head-to-head, session tally, share-to-chat.

## Phase 8 — polish

Puck trail tuning, hitstop, wall flash, goal wash, danger pulse, greyscale pass, reduce-motion.

---

# 15. Open questions

1. **90-second clock or first-to-7?** *(O8 in [`README.md`](./README.md) §5)* Recommend **the clock** (§2.5) — it bounds the match, which matters when the match is inside a chat, and it produces endgames. Cheap to make a match option either way; the default is the decision.

2. **Ship `tick(dtMs)` with this game?** Recommend **yes** (§4.6). One-line runtime change, backwards-compatible, and it removes the last way tick timing can affect the outcome. The alternative works but leaves the match running measurably long under load.

3. **Extract the shared client netcode module, and migrate Snake onto it?** Recommend **yes** (§6.1, Phase 3). It is real work with no visible feature, and the payoff is that [`SNAKE.md`](../SNAKE.md) §2's stutter has one home per platform instead of four. Needs a decision because it touches shipped Snake code.

4. **Is 100 ms the right interpolation delay?** (§3.3) Reasoned but not measured. The measurement is [`SNAKE.md`](../SNAKE.md) §2.6's: log `renderT` deltas under artificial jitter and find where the buffer runs dry. Should be re-derived from real data before launch, and the number lives in one place per platform so it can be.

5. **Does the practice bot count for anything?** Cross-cutting (O10). Recommend no, as today with `BotScoreStore`.

6. **Sudden death, or accept draws at 90 s?** Recommend sudden death (§2.5) — a draw is an unsatisfying end to a game this short. But sudden death has no time bound, which is a real cost in a format chosen for being bounded. Alternative: 90 s of sudden death then an accepted draw, which is what §2.5 specifies. Worth a decision.

7. **Reduce-motion.** §9 specifies hitstop, shake and a full-screen wash. [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13 flags the switch as missing and calls it urgent. Air Hockey has the most motion of any game in this folder and **should not ship without the opt-out**.
