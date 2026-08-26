# Snake — Fix & Rework Plan

**Status:** plan only. Nothing in here is implemented yet.
**Scope:** the two live bugs, the invisible hazards, the growth/levels rework, a full audit
of Snake across iOS, Android and the backend, and a bigger arena.

**Audit status: done.** Part 5 lists 4 P0s, 4 P1s and 3 P2s, plus what was checked and found
correct. Part 6 answers the arena question with measurements.

Everything below that states a number was measured, not estimated. Where I could not prove
something, it says so explicitly rather than guessing.

---

## Part 1 — Bug 1: dying with nothing nearby

### What it is

`spawnSnake` (`backend/games/src/engine/snake/index.ts`) picks a spawn point by scoring 20
random candidates on distance to **other snakes' heads only**. Its own docstring says it:
*"Place a snake at a point far from other heads."*

It never checks:

- other snakes' **bodies** — the path polyline, which is the thing that actually kills you
- **hazards** — rocks are lethal on contact, spikes cost 8 mass

So you can spawn on top of a long snake's tail, or inside a rock. Invulnerability (1.5 s)
hides it, expires, and you die with nothing visibly happening — because nothing visibly *did*
happen. You were already inside something.

### Measured

Simulated 8 seeds × 60 s with 5 bots, inspecting every `spawn` event:

```
spawns = 129
unsafe (within 40u of another snake's body) = 4     (~3%)
worst case = 13.4 units    <- inside the kill radius (headR + bodyR ≈ 21)
```

~3% of spawns are compromised. That matches "I died twice for no reason in one session".

### Fix

In `spawnSnake`, score each candidate against the real world instead of just heads:

1. **Bodies.** Walk each living snake's `path` polyline, take the nearest point. Reuse the
   same broad-phase bounding-radius reject `bodyHit` already uses so this stays cheap.
2. **Hazards.** Reject any candidate within `h.r + headR + margin` of a rock or spike.
   Slicks are survivable and can be ignored.
3. **Keep the existing "maximise distance" scoring**, now over the combined nearest-danger
   distance rather than nearest head.
4. **Hard floor.** If after 20 attempts the best candidate is still inside something, widen
   to a ring sweep rather than accepting it — a spawn is rare enough to afford the search.

**Cost:** none on the wire, none per tick. Spawns are rare; this runs only on spawn.
**Risk:** low. It strictly narrows which points are acceptable.

### Regression test

Re-run the probe above and assert `unsafe === 0` across a seed sweep, plus an explicit case:
place a long snake across the arena, force 50 spawns, assert none land within kill range of
its body or any rock.

---

## Part 2 — Bug 2: the prediction problem

### What it is

**Your snake is drawn at "now". Every other snake is drawn 250 ms in the past.**

`SnakeMetalView.interpDelay = 0.25` (2.5 ticks at 10 Hz). The local snake bypasses it — it is
predicted forward by `SnakePredictor`. Remote snakes are interpolated inside the buffer, so
they render a quarter-second stale.

### Measured

| | units |
|---|---|
| Other snakes drawn behind truth, cruising (300 u/s) | **75** |
| Same, boosting (510 u/s) | **128** |
| Head-on, both errors add | **150** |
| Kill radius (two start-mass heads) | **22** |

Other snakes are displayed **3–7× the kill radius** from where the server thinks they are. A
gap that looks safe on screen genuinely can be a collision on the server.

**This is not the same bug as the collision fixes already committed.** Those fixed the server
being *wrong*. This is the server being *right* and the screen disagreeing with it.

### Plan A (primary): extrapolate remote snakes

Draw remote snakes where they *will* be, not where they were. The machinery already exists —
`buildFrame` has an `overshoot` path — but it only engages when the jitter buffer runs dry, as
a stall guard. It never runs in normal play.

**Why this is the right first move:** snakes move in near-straight lines at a capped turn rate
(`TURN_RATE`, `TURN_RATE_BOOST`), so short-horizon extrapolation is accurate most of the time,
and the error it does make is self-correcting within a frame or two.

**Shape of it:**

1. Extrapolate every remote snake forward by up to `interpDelay` along its interpolated
   heading, using the same movement maths the server uses.
2. **Scale confidence by turn rate.** A snake going straight extrapolates fully; one at its
   turn cap extrapolates barely at all. Use the per-snake turn rate already computed for the
   gaze work (`turnRates` in `buildFrame`).
3. **Blend, do not snap.** When the next frame contradicts the extrapolation, fold the
   correction in over ~100 ms exactly as `SnakePredictor.reconcile` does for the local snake.
   Never teleport a remote head.
4. **Cap it.** Extrapolation is bounded by the same `maxExtrapolation` ceiling, so a stalled
   connection cannot invent a snake across the arena.
5. Mirror on Android.

**Tradeoff:** on a sharp turn you will have drawn a snake slightly wrong and it will visibly
correct. You are trading a *rare unfair death* for an *occasional visible correction*. That is
the right trade — a correction costs a frame of ugliness, a death costs the run.

**Expected result:** residual error drops from ~75 units to roughly the turn-induced error,
which for a snake going straight is near zero and for a hard-turning snake is a fraction of
the current 75. Target: below the 22-unit kill radius in the common case.

### Plan B (fallback, if A is not enough after testing)

Run these in order. Each is independently useful.

**B1 — Cut `interpDelay` 0.25 → 0.15 s.**
Halves the residual error directly. One constant, plus the Android mirror.
*Tradeoff, and it is a real one:* this value was raised to 0.25 deliberately. At 0.15 the
buffer ran dry on any late frame, and the render clock caught up, held, and jumped — that
hold-jump cycle IS the jitter that SNAKE.md §2 documents. On mobile you would trade unfair
deaths for a stuttering world. **Only do this if A left meaningful error AND the jitter does
not return** — measure buffer-dry frequency before and after, do not judge it by eye.

**B2 — Server-side lag compensation.**
The server rewinds each snake to what *that client* actually saw when judging its collisions.
This is what shooters do, and it makes your screen authoritative.
*Tradeoff:* significant work — per-client latency tracking on the wire, a rewind buffer of
recent world states, and a rule for how far back it will honour. It also makes the *other*
player's experience worse: they get killed by someone who, on their screen, had not arrived
yet. For a casual game this is a lot of machinery and a genuine fairness transfer, not a
free win.

**B3 — Raise `TICK_HZ` 10 → 20.**
Halves the tick component of the error and improves interpolation everywhere.
*Tradeoff:* roughly doubles bandwidth. **We are at 29 KB/s against a 30 KB/s budget**, so
this cannot happen without that budget moving. That is a product decision, not an engineering
one. If the budget can move, this is the single highest-quality fix on the list and it
compounds with A.

### Decision rule after playtesting

- A alone feels right → stop.
- Still occasionally unfair, world is smooth → **B1**, and measure buffer-dry frequency.
- Still unfair after B1, or B1 brings jitter back → **B3** if the budget can move, else **B2**.
- Never do B1 and B3 together without re-measuring; they interact.

### Honest caveat

Extrapolation reduces the error, it does not eliminate it. Every authoritative-server game has
some version of this. The goal is to push it below the kill radius so it stops deciding
fights — not to zero.

---

## Part 3 — The invisible rocks and water

### What I verified

Hazards **are** generated and **are** reaching the client. Measured on seed 7:

```
n=12   rock=6  slick=3  spike=3
radii = 55, 91, 25, 29, 44, 56, 111, 39, 70, 23, 40, 34
arena coverage = 2.03%
```

The wire path is also correct. Hazards ride **full frames only** (every 120 ticks ≈ 12 s), and
iOS carries them forward between full frames:

```swift
} ?? previous?.hazards ?? []      // GamesEngine.swift:439
```

So they are not being dropped by the parser, and they are not absent from the world.

Estimated on-screen count at start mass is **~3.3 hazards** — they should be plainly visible.

### Most likely cause

**The black-screen bug was live during your testing.** The bloom target could not be written,
Metal asserted inside `draw(in:)`, and the whole arena — hazards included — never rendered.
That is fixed (commit `91a4942`).

### What to do, in order

1. **Re-test first.** With the bloom fix in, check whether rocks and slicks are now visible.
   This costs one match and may close the item entirely.
2. **If still invisible**, the fault is in the draw path, and these are the candidates in
   order of likelihood:
   - `hazardTris` is built (`buildHazards`) but its draw is gated on
     `ribbonPipeline != nil` — confirm that pipeline exists at that point.
   - Terrain is drawn **before** the bodies by design. Confirm it is not being drawn
     underneath the arena floor sprite, which is drawn immediately before it.
   - Confirm `state.hazards` is non-empty at the `buildHazards` call site, by instrumenting
     the renderer rather than the parser — the parser is already proven correct.
3. **Independently: they are too sparse to teach.** 2% coverage means a player can go a whole
   match without meeting one, which makes them feel absent even when they render. Once
   visible, consider raising density — but note the measured coupling: hazards make bots
   survive longer, longer bots have longer bodies, and bodies are the payload. The existing
   comment records 8/10/12/14 hazards all landing between 27 and 28.5 KB/s, so there is some
   headroom, but it must be re-measured over **six seeds**, not one — single-seed readings
   swung 27→34 KB/s and sent two rounds of tuning chasing noise.
4. **Android:** confirm the same, separately. Do not assume parity here.

---

## Part 4 — Growth rework: levels instead of endless beads

### The problem, measured

`1 pellet = +1 mass = +14 units of body`, linearly, forever.

| mass | head radius | body length | vs arena |
|---|---|---|---|
| 10 (start) | 11.0 | 140 | — |
| 100 | 22.9 | 1,400 | half the arena diameter |
| 200 | 24.2 | 2,800 | **the whole arena diameter** |
| 600 (max) | 24.2 | 8,400 | **3× the arena** |

Two separate faults:

1. **Body length is unbounded and linear.** At 200 mass you span the arena. This is why it
   feels like it explodes.
2. **The head radius silently stops growing at ~146 mass** (the `2.2` clamp in `radiusFor`).
   So past that point you get all of the downside — a longer body to trip over — and none of
   the visible reward. The growth the player *sees* stops long before the growth they *feel*.

### The design

Replace "mass is everything" with **levels**, where mass still exists as the physical body but
progression is expressed as a level with a visible bar.

**Progression curve.** Each level needs 100% of a bar. A pellet is worth a shrinking
percentage as levels rise, so later levels take more eating:

| Level | % per pellet | pellets to clear | cumulative |
|---|---|---|---|
| 1 | 10% | 10 | 10 |
| 2 | 8% | 13 | 23 |
| 3 | 6% | 17 | 40 |
| 4 | 5% | 20 | 60 |
| 5 | 4% | 25 | 85 |
| 6+ | 3% (floor) | 34 | +34 each |

Formula: `pelletPercent(level) = max(3, 12 - 2 * level)`, tuned by feel. The floor matters —
without one, high levels become unreachable rather than merely hard.

**Growth per level, not per pellet.** Body length and head radius step at level-up, not on
every bead. This is the fix for "it grows way too fast": within a level your size is stable
and legible, and the change is an event you can feel.

Suggested: body length `140 + 90 × (level − 1)` units, so level 10 is ~950 units — a third of
the arena, not three times it. Head radius keeps its existing curve but is driven by level so
it never silently stops.

**Mass keeps its jobs.** Head-to-head still compares mass (longer survives), boost still burns
it, corpses still return it. Levels are the *presentation and pacing* layer over mass, not a
replacement — this keeps every existing rule intact.

**Kills contribute.** A kill should be worth meaningful progress (suggest 25–40% of a bar) so
aggression is a route to levelling, not just eating.

### HUD changes

- **Leaderboard shows LVL, not bead count.** Replace the `mass` column with level.
- **Add a kills column.** `kills` is *already on the wire* (`k:` in the snake payload,
  parsed into `SnakeState.Snake.kills`) — it is simply not surfaced. This is cheap.
- **Progress bar** for the local player: current level, bar to next, and the bar should
  visibly tick on every pellet so the reward is immediate.
- Row becomes: `rank · name · LVL · kills`.

### Where the work lands

- **Backend** (`snake/index.ts`): level derived from mass, or tracked explicitly — prefer
  **derived**, so it survives serialize/restore with no new source of truth, exactly as
  `spikeExtended` derives from `t`. Add `lvl` and progress to the wire only if it cannot be
  derived client-side from mass; if it can, spend no bytes.
- **iOS** (`SnakeMetalView` HUD, `SnakeHudModel.Row`): add level + kills, add the bar.
- **Android**: mirror both.
- **Growth curve**: one function, shared shape across all three, like `radiusFor`.

### Tradeoffs

- **Bandwidth:** ideally zero — if level is a pure function of mass, the client derives it and
  nothing new goes on the wire. If kills need surfacing they are already there.
- **Balance:** this changes the whole feel of a match. Bot tuning assumes the current curve,
  so `bots grow by eating` and `bots are mostly alive after 25s` must be re-checked.
- **Existing tests:** `a grown snake is thicker than it started` and `thickness is capped`
  both assert against the current curve and will need updating deliberately, not silently.

---

## Part 5 — Full audit

Worked through `backend/games/src/engine/snake/` (1,900 lines), the iOS client (~3,900) and
the Android mirror (~3,200). Every claim below was verified by reading the code and, where a
number appears, by running it.

Ranked by severity. **P0** = wrong behaviour players will hit; **P1** = real but bounded;
**P2** = correctness debt that has not bitten yet.

### P0-1 — Slicks do nothing at all. A third of the hazard field is inert.

`index.ts:525` sets `sn.slickUntil`, `index.ts:428` reads it to apply `SLICK_SPEED` (0.62).
But `slickUntil` is **never serialized and never restored** — it does not appear in
`serialize()`, `serializeForWire()` or `restoreState()`.

The engine rebuilds itself from the payload on every tick, so the field is wiped every tick
before it can ever be read. Measured directly:

```
snake parked inside a slick, one tick:
moved = 30.0 units        <- full speed
expected in slick = 18.6 units
sl (on the wire) = undefined
```

3 of 12 hazards are slicks. They render, they are documented, they cost bandwidth, and they
have no effect on the game.

**Fix:** add `sl: sn.slickUntil` to the serialized snake and read it back in `restoreState`.
One field each way. Then re-check the bandwidth budget (it is one small number per snake).

**Also:** once slicks work, the client predictor must know about them — see P0-2.

### P0-2 — The predictor does not model slicks, so prediction will desync inside one

`SnakePredictor` (iOS `SnakePredictor.swift:137`, Android `SnakePredictor.kt`) computes
`speed = boosting ? boostSpeed : baseSpeed`. There is no slick term on either platform, and
`slickUntil` is not on the wire for it to read (P0-1).

Today this is masked *because* slicks are inert. The moment P0-1 is fixed, the local snake
will predict at full speed while the server moves it at 62%, and the player will fight a
constant correction for as long as they are in the slick — the exact "rubber-banding" that
prediction exists to prevent.

**Fix:** P0-1 and P0-2 must ship together. Put `sl` on the wire, have the predictor apply
`SLICK_SPEED` while `now < sl`, on both platforms.

### P0-3 — You cannot eat during spawn invulnerability

`resolveEating` (`index.ts:672`) skips any snake with `t < invulnUntil`, the same guard
`resolveCollisions` uses. Collisions should be skipped; eating should not.

For the first **1.5 seconds** of every life, pellets you drive over are ignored. They stay on
the board, they do not feed you, and nothing explains why. It reads as the game not
registering input.

**Fix:** drop the invulnerability check from `resolveEating`. Invulnerability is protection
from harm, not from food.

### P0-4 — Bot body avoidance samples too coarsely to see a body

`bot.ts:175` and `bot.ts:207` walk another snake's path with `i += 8` over a flat
`[x,y,x,y,…]` array — every **4th point**. Points are laid down one per tick, ~30 units apart
at cruise, so the bot samples the body every **~120 units** while testing against a **40-unit**
radius.

A body crossing the bot's path between two samples is invisible to it. This is the same class
of tunnelling bug the collision code documents at length and fixes with swept tests — the bot
never got the same treatment.

**Fix:** either sample at `i += 2` with the existing radius, or keep the stride and test
against the **segment** between sampled points rather than the points themselves (cheaper, and
correct at any stride). The second is preferable: `segmentSegmentDist2` already exists.

### P1-1 — Bot avoidance always assumes base speed, including while boosting

`bot.ts:88`: `const speed = TUNING.BASE_SPEED;` — used to derive `turnRadius`, `awareness`,
the one-second lookahead, and the hunt lead.

A boosting bot travels at 510 u/s, 1.7× the assumed speed, so every one of those margins is
40% short exactly when it is moving fastest. The file's own comment warns about this precise
failure ("calibrated for the old, slower game … they began braking far too late").

**Fix:** `const speed = sn.boost && sn.mass > TUNING.MIN_BOOST_MASS ? TUNING.BOOST_SPEED :
TUNING.BASE_SPEED;`

### P1-2 — The death event carries no killer id

`index.ts:639` emits `{ k: 'death', x, y, id, c }`. `id` is the victim. There is no killer.

`kill()` receives `killerId` and uses it to award score, then discards it. The separate
`'kill'` event does carry both, but it is only emitted on some paths, so a client cannot
reliably attribute a death, and no test can assert "X killed Y" from the death event alone —
which is exactly what blocked a regression test during the collision work.

**Fix:** add the killer to the death event. One field; the kill feed already wants it.

### P1-3 — S3/S4 shipped on iOS only

The gaze-lead and tail-falloff work (commit `2efdd53`) landed in `SnakeMetalView.swift` and
was never mirrored into `SnakeArenaScreen.kt`. Confirmed: Android has no `TAIL_FALLOFF` and no
`GAZE_LEAD`.

Snake is supposed to be pixel-parity across platforms. **This one is mine** — I should have
mirrored it in the same commit.

**Fix:** port both to Android.

### P1-4 — Netcode constants are duplicated with nothing enforcing the match

`INTERP_DELAY` (0.25) and `MAX_EXTRAPOLATION` (0.10) exist independently on both platforms,
each with a comment asserting it matches the other. They currently do. Nothing stops the next
edit from changing one.

Same shape for `SnakeMotion` (iOS) / the Android equivalent: `baseSpeed`, `boostSpeed`,
`turnRate`, `turnRateBoost`, `minBoostMass` are hand-copied from `TUNING`. They match today.
The engine's own history records the last time these drifted, in `bot.ts`: *"These were
literals … calibrated for the old, slower game."*

**Fix:** publish the shared numbers as a fixture the way Ludo does with
`ludo_board_v3.json`, and add a parity test on each platform. Failing that, at minimum add a
test that reads the values and compares them to a checked-in expected set.

### P2-1 — `finish()` comment contradicts the code

`index.ts:782` says *"Highest mass wins"*; the loop compares `sn.score`. The code is almost
certainly right (score rewards kills and eating; mass alone would reward turtling), so the
comment is stale. **Fix:** correct the comment.

### P2-2 — Head-to-head invulnerability check is asymmetric in an unexpected way

`index.ts:539` skips the pair if **the other** snake is invulnerable, and `index.ts:451`
already skipped if **this** snake is. Combined that is correct — neither can die — but it is
expressed as two unrelated guards in two places, and the pairing is not obvious to a reader.

Not a bug. Worth a comment saying the two together mean "invulnerable snakes are inert to each
other in both directions", so a future edit does not remove one half.

### P2-3 — `_d.ts` and `_x.ts`

Two files, 12 and 9 lines, single-letter names, in the engine directory. `_d.ts` is a
bandwidth-debug harness. Neither is imported by the engine.

**Fix:** move to a `tools/` or `scripts/` location, or delete. A single-letter file in an
engine folder is an invitation to accidental import.

### Verified correct (checked, no action)

Recording these so the audit is not just a list of complaints, and so nobody re-checks them:

- **Delta path encoding** (`encodePath`) — quantises the delta then advances the reference by
  the *quantised* amount, so rounding cannot accumulate along a body. Correct, and the comment
  explains why.
- **`t` is deliberately unrounded** while every other float is rounded, because it is fed back
  into itself on every restore. The reasoning is sound and the drift maths in the comment is
  right.
- **Spike state is derived from `t`**, never stored, so it cannot desync across restore. This
  is the pattern P0-1 should have followed.
- **Hazards are generated from a derived seed** (`seed ^ 0x51ed270b`) so adding them does not
  shift the food layout of an existing seed. Careful and correct.
- **`resolveCollisions` decides all deaths against one pre-move world**, so outcomes do not
  depend on array order. Correct, and load-bearing.
- **`hr` and `br` are both sent** rather than derived client-side. The comment records a real
  past bug where only `hr` went out and the lethal zone was twice the drawn body.
- **Food deltas** — `added`/`removed` with a periodic full snapshot, and the client reconciles.
  The `delta-applied food matches the server exactly` test covers it.

---

## Part 6 — A bigger arena

You asked for this, and it is the cheapest item in the document.

### Measured

Same six-seed methodology the bandwidth test uses (2 humans, 4 bots, 30 s each), one config
per process so nothing leaks between runs:

| Arena radius | Food target | Bandwidth |
|---|---|---|
| **1400 (today)** | 260 | **28.7 KB/s** |
| 2000 | 530 | 24.4 KB/s |
| 2400 | 764 | 24.8 KB/s |
| **2800 (2× today)** | 1040 | **25.1 KB/s** |

**A doubled arena is cheaper than the arena we ship.** That is not a rounding artifact, and
the mechanism is clear:

1. **Body points are delta-encoded.** `encodePath` sends the head absolutely and every
   subsequent point as a small delta in `PATH_STEP` units. Arena size does not change the size
   of a delta, so a bigger world costs nothing per body point.
2. **More space means fewer collisions**, so snakes die less, but they also *grow* less
   aggressively into each other's paths — and bodies are the payload. The 1400 arena is
   crowded enough that bots tangle, die, respawn, and churn food.

The `FOOD_TARGET` must scale with **area** (radius²) or a bigger arena is a barren one. The
numbers above scale it that way: 260 × (r/1400)².

### The catch

Bandwidth is not the constraint. These are:

- **Match length.** A 2× arena at the same 180 s means players may never meet. Either raise
  `MATCH_SECONDS` or keep the arena moderate. **2000 is probably the sweet spot** — 2× the
  area, not 4×.
- **Hazard count** scales with area already (`generateHazards` uses `(arenaRadius/1400)²`), so
  that is handled.
- **Bot count.** 5 bots in a 2800 arena is empty. Bot count should scale with area too, and
  more bots *does* cost bandwidth — that is the coupling `TICK_HZ`'s comment documents.
- **The camera** zooms with mass, not with arena size, so a bigger arena does not change what
  is on screen. It only changes how long it takes to cross. This is fine, but it means the
  arena rim stops being a visible landmark, and the minimap (if any) matters more.

### Recommendation

Go to **`ARENA_RADIUS = 2000`** with `FOOD_TARGET = 530` and bot count scaled to ~8.
That is 2× the play area, measured *cheaper* than today on bandwidth, and leaves headroom to
go further after playtesting. Re-measure with the new bot count before committing — bots, not
arena, are what actually moves the number.

---

## Suggested order of execution

**Round 1 — correctness. Cheap, no design risk.**

1. **P0-3** — let snakes eat during invulnerability. One line.
2. **Part 1** — spawn safety (bodies + hazards). Removes pure-frustration deaths.
3. **P0-1 + P0-2 together** — put `slickUntil` on the wire, restore it, teach both
   predictors about it. These MUST ship together: fixing the first without the second turns
   a dead feature into a rubber-banding one.
4. **P1-1, P1-2, P2-1** — bot boost speed, killer id on the death event, stale comment.
5. **P0-4** — bot body sampling, via a segment test rather than a finer stride.

**Round 2 — the feel work.**

6. **Part 3.1** — re-test hazards now the bloom fix is in. One match, may close the item.
7. **Part 2 Plan A** — extrapolate remote snakes. The big one, and the one you are feeling.
8. **P1-3** — mirror S3/S4 to Android, so the platforms match before more is layered on.

**Round 3 — scope changes. Only on a game that is behaving.**

9. **Part 6** — the bigger arena. Cheap on bandwidth; re-measure with the new bot count.
10. **Part 4** — the levels rework.
11. **P1-4** — shared constants fixture, so the parity all of this depends on stops being a
    promise in a comment.

Rounds 1 and 2 are corrections. Round 3 changes the game. Doing the corrections first means
the rework is tested against a game that is behaving, which is the only way to tell whether
the new curve actually feels right.
