# Snake — Fix & Rework Plan

**Status:** plan only. Nothing in here is implemented yet.
**Scope:** the two live bugs, the invisible hazards, the growth/levels rework, and a
line-by-line audit of Snake across iOS, Android and the backend.

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

> **Status of this section: NOT YET DONE.** You asked for a line-by-line audit of Snake
> across iOS, Android and the backend. That is a large piece of work and it deserves to be
> done properly rather than sketched. Doing it honestly means reading:
>
> - `backend/games/src/engine/snake/` — `index.ts` (~1200 lines), `bot.ts`, `hazards.ts`,
>   `geometry.ts`
> - `apps/ios/.../Games/Snake*.swift` + `Snake.metal` — ~3,900 lines
> - `apps/android/.../games/snake/` — the mirror
>
> and cross-checking every shared constant and rule for parity in three places.
>
> **What I will do:** work through it file by file and append findings here, each with a
> concrete cause and fix, ranked by severity. I have not done it yet, so this section is
> empty rather than padded with things I have not actually checked.

### Already found (from the work so far, carried forward)

| # | Severity | Where | Issue | Fix |
|---|---|---|---|---|
| 1 | **High** | `snake/index.ts` `spawnSnake` | Spawn checks heads only; ignores bodies and hazards. ~3% of spawns unsafe, worst 13.4u. | Part 1 |
| 2 | **High** | `SnakeMetalView` netcode | Remote snakes 250 ms / 75–128 units stale vs local prediction. | Part 2 |
| 3 | **High** | `snake/index.ts` growth | Body length linear and unbounded (3× arena at max); head radius silently caps at ~146 mass. | Part 4 |
| 4 | Medium | `snake/hazards.ts` | 2% arena coverage — hazards can go a whole match unmet even when rendering correctly. | Part 3.3 |
| 5 | Medium | `snake/index.ts` `kill()` | Death event carries no killer id, so no client can attribute a kill or show "X ate Y" reliably from the event alone. | Add `killer` to the death event; it is one field and the kill feed already wants it. |
| 6 | Low | `SnakeMetalView` | `interpDelay` and `maxExtrapolation` are duplicated as constants on both platforms with a comment asserting they match. Nothing enforces it. | Move to a shared fixture like Ludo's `ludo_board_v3.json`, or add a parity test. |

*(Items 5 and 6 were observed in passing while working on 1–4; both are real but neither is
urgent.)*

---

## Suggested order of execution

1. **Part 1** — spawn safety. Small, no tradeoff, removes pure-frustration deaths.
2. **Part 3.1** — re-test hazards now the bloom fix is in. One match, may close the item.
3. **Part 2 Plan A** — extrapolate remote snakes. The big one.
4. **Part 5** — the full audit, so Part 4 is built on top of known-good code rather than
   on top of unknowns.
5. **Part 4** — the levels rework. Last, because it changes balance and wants a clean base.

Parts 1–3 are corrections. Part 4 is a design change. Doing the corrections first means the
rework is tested against a game that is behaving, which is the only way to tell whether the
new curve actually feels right.
