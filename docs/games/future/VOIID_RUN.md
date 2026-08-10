# Voiid Run

> **Status:** design only, nothing built.
> **Kind:** single-player, real-time, 60 fps, procedurally generated. **Client-simulated** — the one deliberate exception to server authority in this app.
> **Depends on:** nothing architectural. It uses almost none of the multiplayer stack, which is both its cost and its risk.
> **Read first:** [`GAMES.md`](../../GAMES.md) §1 (the rule this game breaks), [`SNAKE.md`](../SNAKE.md) §2 (the render-clock failure it must not repeat), [`snake/index.ts`](../../../backend/games/src/engine/snake/index.ts) (seeded RNG, wire discipline).

---

# 1. What the game is

You run forward. The world comes at you. You swipe left and right between three lanes, swipe up to jump, swipe down to slide. You collect coins. Eventually you hit something and it ends. Your distance is your score.

Temple Run and Subway Surfers, in Voiid's palette, with **one seed a day that everyone in your contacts runs**.

## 1.1 The pitch

The genre is a solved problem with excellent free implementations and a decade of polish behind them. Building another one is a bad idea in isolation, and this doc says so more than once.

**The thing that is not solved is the last clause.** Subway Surfers has a global leaderboard, which is a list of strangers and is therefore noise. It has no idea who your friends are, because it is not a messenger and it never will be. Voiid does.

> **Today's seed. The same course for everyone. Your contacts, ranked, and a ghost you can race.**

That is a real product that does not exist, and it exists *only* inside an app that already knows your social graph. Every other feature of this game is table stakes the genre solved in 2012.

## 1.2 The honest position, stated up front

**Voiid Run is worth building only if the daily challenge and share-to-chat ship with it.** Without those it is a worse Subway Surfers that the player already has installed, and it is the most expensive thing in this folder by a wide margin.

That is not a hedge. It is a specific, checkable condition, and it should be treated as a gate on starting rather than a nice-to-have at the end. If the daily challenge is going to be cut for scope, cut the game instead.

## 1.3 Is it affordable at all? — the honest cost

The execution prompt asks this directly, so here it is directly, measured against Air Hockey.

| | Air Hockey | Voiid Run |
|---|---|---|
| **Server engine** | ~400 lines + shared `physics2d` | ~200 lines (seed issue + score validation) |
| **Client simulation** | Physics port, ~250 lines/platform | **Full game, ~1500 lines/platform** — generator, simulation, collision, camera, spawning, pooling |
| **Renderer** | 9 primitives, static camera | **60–100 depth-sorted sprites, scrolling, 60 fps sustained** |
| **Art** | 6 shapes, procedural | **A character with 5 animation states, 12+ obstacle types, environment tiles, pickups** |
| **Tuning surface** | ~15 constants | **~60 constants** plus a difficulty curve plus a generator grammar |
| **Reuses from Snake** | Tick loop, jitter buffer, render clock, predictor, `geometry.ts` | **The RNG. That is all** |
| **Platform risk** | Low — trivially within budget | **High — the only game needing sustained 60 fps procedural rendering on both platforms** |
| **Rough scale** | 1× | **4–6×** |

Three things that table understates:

**The art is not optional and it is not ours.** Every other game in this folder renders shapes: a grid, a puck, a board, cards. This one needs a *character* who runs, jumps, slides, stumbles and dies, plus an environment with enough variety that ninety seconds of it is not visually boring. That is an art commission, not a rendering task, and it is the only game here with that dependency. [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §8 makes the equivalent point about audio licensing being "the one item here that is a real liability rather than a quality issue" — the same is true of character art.

**It reuses nothing.** The multiplayer architecture that makes the other seven games cheap — transport, seats, tick loop, netcode, invites, results — is almost entirely unused. This game shares the RNG and the results table. Every line of the interesting part is new.

**Android low-end is a genuine risk, not a rounding error.** Compose `Canvas` at a sustained 60 fps with ~80 depth-sorted sprites is fine on current hardware and is not guaranteed on a 4-year-old midrange device, which is a large share of the real user base. Snake found its ceiling on *bandwidth* and worked around it; this game's ceiling is *frame time*, and there is no delta encoding for frame time. §6.4 gives the mitigation and it involves a quality setting the app does not have ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §12).

**Recommendation: build it, but last, and only with the daily challenge.** [`README.md`](./README.md) §3 puts it at step 7 of 8, and that is right. It is the highest-ceiling game in the folder — a genuinely good runner with a friends-only daily leaderboard is a thing people would open the app for daily, which nothing else here can claim — and it is also the one most likely to consume three months and disappoint. Both are true.

---

# 2. Rules as implemented

## 2.1 Three lanes, not free movement

**Decided: three discrete lanes.** This is the biggest design decision in the game and the argument is not close.

| | Three lanes | Free lateral movement |
|---|---|---|
| Input | Swipe = one unambiguous lane change | Continuous, needs a joystick or tilt |
| One-handed | Yes — a swipe anywhere on screen | No — needs a control surface |
| Collision | Discrete: you are in a lane or between two | Continuous swept tests, every frame, every obstacle |
| Generation | A grammar over 3 slots. Solvability is **provable** | Solvability is a search problem |
| Replay validation | ~40 discrete events per run | Continuous input stream, orders of magnitude larger |
| Fairness on a shared seed | Identical for everyone | Sensitive to touch precision and screen size |
| Genre precedent | Subway Surfers, Temple Run | Alto's Odyssey (a different, slower game) |

The decisive rows are **generation** and **replay validation**.

With three lanes, "is this obstacle pattern survivable?" is a question with a *provable* answer: for each pattern, enumerate the reachable lane at each depth given the lane-change duration and the current speed, and check that a non-empty set survives. That check runs at generation time, in the generator, on ~12 patterns. With free movement it is a continuous-space pathfinding problem, and the failure mode is an unwinnable arrangement shipping to every player on the daily seed simultaneously.

And replay validation (§3.4) is what makes the leaderboard defensible. Three lanes means a run is ~40 timestamped discrete events — a few hundred bytes, cheap to store and trivial to re-simulate. Free movement means a continuous input stream, which is both large and much harder to verify against.

Free movement is *slightly* more expressive. It is not worth any of the above.

## 2.2 Motion and the difficulty ramp

The runner accelerates forever. Everything about the difficulty curve is this one function, so it is specified exactly.

| Quantity | Value |
|---|---|
| Lane width | 200 units. Lanes at x = −200, 0, +200 |
| Start speed | 700 units/s |
| Speed at distance `d` | `min(1600, 700 + 900 × (1 − e^(−d / 4500)))` |
| Time to 90% of max | ~65 seconds |
| Lane change | 180 ms, `easeInOut`. **Constant** — it does not scale with speed |
| Jump | 620 ms airborne, apex at 310 ms, peak height 150 units |
| Slide | 520 ms, hitbox height halved |
| Coyote time | 90 ms after leaving a ledge |
| Input buffer | 140 ms before landing |

Three notes.

**The exponential ramp, not a linear one.** A linear ramp is either too slow at the start (boring first 30 seconds) or unplayable at 3 minutes. The exponential front-loads the *sense* of acceleration — most of the speed increase is felt in the first minute, when the player is learning that the game gets harder — and then asymptotes, so a 5-minute run is hard but not impossible. The asymptote is what makes long runs a test of concentration rather than of reaction time beyond human limits.

**Lane change duration is constant, and this is what actually creates difficulty.** At 700 u/s a 180 ms lane change covers 126 units of track. At 1600 u/s it covers 288 units. The *move* stays the same and the *world* moves further during it, so obstacle patterns that were comfortably dodgeable become tight. Difficulty emerges from geometry rather than from a difficulty parameter, which means it is consistent, learnable and provably fair — the generator can compute exactly which patterns are survivable at a given speed (§2.4).

**Coyote time and input buffering are not polish.** They are the difference between "I mistimed that" and "the game didn't register my input", and at 1600 u/s the window for a jump is small enough that without them the game feels broken. Both are standard and both must be in the first playable build, not added later — they change the tuning of everything else.

## 2.3 The obstacle and pickup vocabulary

Deliberately small. A runner's difficulty comes from *combinations*, not from a large catalogue, and every additional obstacle type is art, animation, a collision shape, and a generator rule.

**Obstacles — 7 types.**

| Type | Occupies | Answer | Introduced at |
|---|---|---|---|
| **Barrier** | 1 lane, full height | Change lane | 0 m |
| **Low barrier** | 1 lane, low | Jump or change lane | 400 m |
| **Overhead** | 1 lane, high | Slide or change lane | 900 m |
| **Wide barrier** | 2 adjacent lanes, full height | Change to the free lane | 1400 m |
| **Pit** | 1–2 lanes, a gap in the floor | Jump | 2200 m |
| **Mover** | 1 lane, drifts across lanes over 1.5 s | Read and commit | 3200 m |
| **Ramp** | 1 lane, launches you | Ride it — a reward, not a threat | 4000 m |

**Introduced at** is a hard rule, not a suggestion: the first 400 m contains exactly one obstacle type and one verb. A runner that shows a new player four mechanics in ten seconds has taught them none. This is the same instinct as [`CRICKET.md`](../CRICKET.md) §2.1's complaint that hand cricket never explains itself — except here the teaching can be structural rather than a rules screen, which is strictly better.

**Pickups — 4 types.**

| Type | Effect | Frequency |
|---|---|---|
| **Coin** | +1 coin. Arranged in trails that trace the *safe* line | Constant |
| **Magnet** | 8 s, coins within 400 units curve toward you | ~1 per 1200 m |
| **Shield** | Absorbs one collision, then breaks | ~1 per 1800 m |
| **Boost** | 4 s at 1.6× speed, invulnerable, coins doubled | ~1 per 2500 m |

**Coin trails trace the safe line.** This is the most important thing in this section. Coins are not a currency — nothing is purchasable (§2.6) — they are **the game's tutorial, running continuously and invisibly.** A trail of coins arcing left into the empty lane teaches the correct move before the obstacle is readable, and a trail rising over a low barrier teaches jump timing. The player thinks they are being greedy; they are being taught.

This also means coins must be placed **by the generator alongside obstacles, from the solvability solution** (§2.4), never scattered independently. Coins that lead into a wall are actively hostile.

## 2.4 Generation: chunks, and the property that matters

The track is built from **chunks of 300 units**, generated on demand ahead of the runner and destroyed behind.

```
chunkSeed(runSeed, chunkIndex) = hash32(runSeed ^ (chunkIndex × 0x9E3779B1))
```

**Each chunk is a pure function of `(runSeed, chunkIndex)` and nothing else.** This is the single most important invariant in the game, and it has four consequences that are each individually load-bearing:

1. **The same seed produces the same run, always.** Which is what makes a daily challenge fair, a leaderboard comparable, and a ghost replayable.
2. **The server can compute any chunk without simulating the run.** Score validation (§3.4) needs to know how many coins exist in the first N metres of seed S. With chunk generation depending only on the index, that is a direct computation over `N/300` chunks, not a replay.
3. **Generation cannot drift with play.** If a chunk depended on the player's state — speed, coins, a running RNG — then two players on the same seed would get different courses, and the daily challenge would silently be a different game for each of them. **This is the bug that would quietly destroy the game's entire reason to exist**, it would not show up in testing (both runs look fine individually), and it is exactly the class of bug [`geometry.ts:105-111`](../../../backend/games/src/engine/snake/geometry.ts#L105-L111) documents for `Math.random()`. Chunk generation must take no arguments other than the seed and the index, enforced by the function signature.
4. **Chunks can be generated out of order**, which the server needs and a look-ahead prefetch wants.

**Difficulty is a function of `chunkIndex`, not of a running counter.** Chunk `n` is generated at difficulty `f(n)` — obstacle density, allowed types, pattern complexity all derived from the index. Same reason as above.

**Solvability is proven at generation time.** For each candidate pattern, the generator walks the reachable-lane set forward through the chunk given the speed at that distance and the constant 180 ms lane change, and rejects any pattern with an empty surviving set. This runs on both the client and the server from **the same source of truth** (§4.4), so a pattern that the server believes is survivable is the one the player faces.

The generator also enforces **a breathing rhythm**: at most 5 consecutive chunks with obstacles, then at least one chunk that is a pure coin run. Continuous pressure is exhausting and, more practically, it is what makes a runner feel like a treadmill rather than a course.

## 2.5 Death, and the revive

**One collision ends the run.** Not a health bar. A runner with health is a runner where the tense moments are cheap, and the tension is the product.

- Hitting a full obstacle, falling in a pit, or hitting an overhead while not sliding: **death.**
- A shield absorbs one collision and breaks, with 800 ms of invulnerability and a hard visual/audio tell.

**Revive: one per run, free.**

- Restart 120 units back from the collision point, in the centre lane, with 2 s invulnerability.
- Distance and coins carry over. The run continues.
- **Second death ends the run.** No exceptions, no second revive at any price.
- **No revive at all in the daily challenge.** The daily is a fairness surface and a leaderboard: one seed, one life, one score. Reviving there would make the leaderboard a measure of patience.

The genre's economics assume monetisation — revives are where runners make money — and this app has none (open question O9 in [`README.md`](./README.md) §5). **One free revive and nothing purchasable** is the recommendation: it keeps the "one more run" psychology that revives exist for, without building a store, a currency, or a reason for anyone to distrust the leaderboard.

## 2.6 Scoring, and what coins are for

- **Score = distance in metres**, integer, 1 unit = 1 metre.
- **Coins are counted and displayed separately** and do not add to the score.

Coins buy nothing. There is no shop, no character unlock, no upgrade tree.

This is a real decision and it costs something — coins-as-currency is a strong retention loop and the genre relies on it. It is rejected because a currency needs a store, a store needs content, and content needs the art budget §1.3 already flags as the largest dependency. A half-built store with three characters in it is worse than no store: it promises progression and delivers a stub.

**What coins are for instead:** they are the tutorial (§2.3), they are a second axis on the daily leaderboard ("furthest" and "most coins" are different achievements, won by different play), and they are the reason to take a risky line. If a store is ever built, coins are already there and already earned.

`GameOutcome.scores` carries **distance**, so it drops straight onto the existing leaderboard with the correct sort direction (higher is better) — unlike Sea Battle (see [`SEA_BATTLE.md`](./SEA_BATTLE.md) §2.5).

---

# 3. Network model — R2

**This section is the deliberate architectural exception, and it is argued rather than assumed.**

## 3.1 The rule this game breaks

[`GAMES.md`](../../GAMES.md) §1 is unambiguous:

> *"All ten games are online multiplayer, and the server is always the referee... the server holds the one true copy of game state, applies every rule, and pushes the result to both players. Phones become 'controllers with a screen'."*

**Voiid Run does not do this.** The client simulates the entire game and the server validates the result.

That doc's reasoning is sound and it is worth restating, because the exception is only defensible if the original argument is understood: server authority exists because (a) two phones simulating a shared world drift apart within seconds, and (b) a trusted client can claim anything. Both are real. Neither applies here, and the reason is structural rather than convenient.

## 3.2 Why server authority buys nothing here

**There is no second player.** Voiid Run is single-player. There is no shared world to keep in sync, no opponent whose experience depends on this client telling the truth, and no state anyone else's client reads. The drift argument (a) has no content — there is exactly one simulation, so it cannot disagree with anything.

**And the cost is not small.** Consider what server-authoritative Voiid Run would actually mean:

- **Tick rate.** The game's atoms are 180 ms lane changes and 620 ms jumps at 1600 u/s. A 30 Hz tick samples input every 33 ms — 53 units of travel — which is enough to turn a correct dodge into a collision. It needs 60 Hz, doubling every cost below.
- **Input latency added to a game made of frame-perfect reactions.** Even with prediction, the *authoritative* answer to "did I clear that barrier" arrives an RTT late. When the server disagrees, the correction is not a smooth blend — the player is either alive or dead. There is no way to gracefully reconcile "you thought you dodged and you did not." Snake's predictor can blend a position error ([`SnakePredictor.swift:87-117`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L87-L117)); nothing can blend a death.
- **Server cost.** A per-match 60 Hz interval loop, per concurrent player, generating and collision-testing a procedural world. Compare the current design, where the games service does **zero work** while a run is in progress. At any real scale this is the difference between runs being free and runs being the dominant cost of the games service.
- **It fails offline.** A single-player game that requires a live socket is a game you cannot play on the underground, which is exactly where this genre is played.

**And it does not even solve the problem it exists for.** A server-authoritative runner still has to trust the client's *input*, and a bot that plays perfectly — trivial to write, since the client knows the whole course from the seed — sends only legal inputs. Server authority would buy an enormous amount of latency and cost in exchange for stopping a cheat nobody would bother with, while leaving the cheat that actually matters wide open.

## 3.3 What we do instead

```
POST /games/matches  { slug: 'voiidrun' }   → match_id, run seed        (server issues)
                     ... client simulates the entire run offline ...
game_input           { submit: { distance, coins, duration, trace } }   (client submits)
                     → server validates, writes game_match_results
```

**The server issues the seed and validates the submission. It does not simulate the run in real time.**

The seed is **server-issued and non-negotiable**, which is what makes the daily challenge meaningful — a client cannot pick an easy course. It travels in the opening `game_state` frame like any other match state.

Reusing the match machinery rather than inventing REST endpoints is deliberate: a run is a match with one player. `min_players = 1` already works — [`games.ts`](../../../backend/api/src/routes/games.ts) explicitly removed a blanket opponent check for exactly this reason ("Snake's practice mode (one human, server-side bots) 400'd on every attempt even though its catalog row sets min_players = 1"). So a run gets a `game_matches` row, a `game_match_results` row, and leaderboard/head-to-head integration for free.

## 3.4 Score validation — bounding the cheat honestly

**A determined cheater can forge a score. That is a fact of client-simulated games and no amount of validation eliminates it.** What validation does is raise the cost from "edit a number" to "write a bot", and make the top of the leaderboard defensible. Both are worth having; neither is security.

Three layers, in increasing cost and decreasing frequency.

### Layer 1 — arithmetic bounds. Every submission, ~0 cost.

The submission is `{ distance, coins, duration, deaths, trace }`. Checks:

- **`distance ≤ maxDistance(duration)`** — the speed curve (§2.2) is a known function, so the furthest anyone can travel in `duration` seconds is a closed-form integral of it. Claiming 8 km in 40 s is impossible arithmetic.
- **`duration ≥ minDuration(distance)`** — the same bound the other way.
- **`coins ≤ coinsInFirst(seed, distance)`** — the strong one. Because chunks are a pure function of `(seed, index)` (§2.4), the server computes exactly how many coins exist in the first `distance` units and rejects anything above it. This is the check that makes coins hard to forge, and it is only possible because of §2.4's purity invariant.
- **`deaths ≤ 1`** (or 0 in the daily), and revive rules.
- **Wall-clock sanity:** the match row has `started_at`; `duration` must not exceed wall time since then plus slack.

This rejects casual tampering — the "edit the number in the payload" attack — at essentially zero cost.

### Layer 2 — replay validation. Top entries only.

The client submits the **input trace**: `[(distanceAtInput, action)]` where action ∈ {left, right, jump, slide}. At ~40 events per run that is a few hundred bytes, stored in the results row.

The server re-simulates: generate chunks from the seed, apply the inputs at the stated distances, run the same collision logic, and check that the resulting distance and coin count match the claim.

**This is the real check**, and it is only tractable because of §2.1's three-lane decision — discrete events, deterministic simulation, no continuous input to interpolate.

**Run it on the top 20 of each daily leaderboard, not on every submission.** Re-simulating a 5-minute run is maybe 20 ms of CPU; doing it for every run of every player is real cost for no benefit, since nobody cares whether someone forged 47th place. Validate what matters: podium entries, personal bests that enter a leaderboard, and a random 1% sample as a deterrent.

**The requirement this places on the codebase:** the generator and the simulation must be **one source of truth, ported identically to TypeScript, Swift and Kotlin.** Three implementations that disagree by one unit will fail valid runs, which is far worse than accepting invalid ones — a player whose legitimate best is rejected will not play again. §4.4 and §14 treat this as the central engineering risk of the project.

### Layer 3 — behavioural, later and optional

A perfect-play bot produces a *statistically impossible* trace: inputs at exactly the last viable frame, every time, with zero variance. Human traces have a reaction-time distribution. Flagging that is a real technique and it is **explicitly out of scope for v1** — it is a arms race, it produces false positives against genuinely excellent players, and the stakes (a friends-only leaderboard with no prizes) do not justify it.

### Stating the residual honestly

**A determined cheater can write a client that plays the seed perfectly and submits a valid trace.** Layers 1 and 2 cannot detect it, because it is not lying — it played the run.

What bounds the damage is the same thing that bounds it in Air Hockey (see [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §5.3): **the leaderboard is your contacts.** There are no strangers, no prizes and no ranked ladder. Cheating to beat your friend at a running game is a social act with a social cost, and the correct engineering response is to make honest play verifiable, not to make cheating impossible.

**What must never happen** is a cheated score appearing on a *global* leaderboard alongside honest ones. Recommendation: **Voiid Run's daily leaderboard is friends-only, full stop.** That is also the better product (§12).

## 3.5 The render clock — R2's mandatory clause

There is no network in the loop, so there is no jitter buffer and no interpolation delay. **The [`SNAKE.md`](../SNAKE.md) §2 failure mode cannot occur, because there are no arriving frames to anchor to.**

But the *lesson* generalises, and this game is more exposed to the general version than any other in the folder:

> **The simulation clock must be free-running and frame-rate independent, and must never be derived from anything but elapsed display time, clamped.**

The concrete requirements:

- **Fixed-step simulation**, exactly as [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §4.6: accumulate real elapsed time, step at a fixed **120 Hz**, carry the remainder. A dropped display frame produces *more substeps*, not a longer step — and here the stakes are unusually high, because a variable step would make **collision outcomes depend on frame rate**. A player on a device that stutters would die to obstacles a smooth device clears. On a shared daily seed, with a replay validator running at a fixed step, that is not a feel problem — it is a *correctness* problem that makes valid runs fail validation.
- **Clamp elapsed time to 100 ms per frame.** A GC pause or a backgrounded app must not teleport the runner through a wall. Same instinct as [`SnakePredictor.swift:123`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L123)'s `min(now - lastStep, 0.05)`.
- **Pause on background, immediately and unambiguously.** iOS `scenePhase`, Android `onPause`. Resume with a 3-2-1 countdown, never instantly.
- **Never derive the step from a frame counter.** `distance += speed / 60` assumes 60 fps and produces a different run on a 120 Hz ProMotion display and on a device dropping to 45. It would also silently break replay validation.

## 3.6 What happens on a 3-second network stall

**Nothing. The run is unaffected.**

This is the single best property of the client-simulated design and it deserves stating plainly: **Voiid Run is fully playable with no network at all.** The genre's natural habitat is a commute, and a commute is where connectivity dies.

- **During the run:** no network is used.
- **At submission, if offline:** the submission is queued locally and retried, reusing the existing outbound queue in `WebSocketClient` ([`GAMES.md`](../../GAMES.md) §9 — "same reconnect/backoff/outbound-queue already built"). The player sees their score immediately; the leaderboard updates when connectivity returns.
- **Starting a run offline:** requires a seed, which requires the server. **The client prefetches the next run's seed** while the previous run is being played, and caches the daily seed for the current day. So the common case works offline; a cold start with no network and no cached seed shows "connect to start a run", which is honest and rare.
- **Submission failure must never lose a score.** The queue is durable, and a run whose submission is pending shows as pending rather than as lost.

---

# 4. Engine design — R1

The server engine is small. The interesting design work is in the **shared simulation**, which is not a `GameEngine` at all — but every R1 requirement still applies to it, and §4.4 is where they land.

## 4.1 The server engine

Folder: `backend/games/src/engine/voiidrun/`. One registry line.

| Method | Present | Why |
|---|---|---|
| `applyInput` | yes | Exactly one frame: the submission |
| `tick` | **no** | The server does no simulation. **This is what makes the game cheap to host** |
| `serialize` | yes | Seed, status, result |
| `serializeForWire` | **no** | State is ~120 bytes |
| `serializeForPlayer` | **no** | One player, nothing hidden |
| `serializeSecret` | **no** | §4.3 |
| `isFinished` | yes | — |

No `tickHz` means no loop, per [`index.ts:106-108`](../../../backend/games/src/index.ts#L106-L108). **A live run costs the games service nothing** — no timer, no memory, no broadcast. A thousand concurrent runs cost a thousand Redis keys and no CPU. Contrast a server-authoritative version at 60 Hz per player (§3.2).

## 4.2 `serialize()` — field by field

```ts
{
  players: string[],
  seed: number,
  mode: 'free' | 'daily',
  dayKey: string | null,      // 'YYYY-MM-DD' for a daily run
  issuedAt: number,           // server epoch ms
  status: 'running' | 'submitted' | 'rejected',
  distance: number,
  coins: number,
  duration: number,
  deaths: number,
  verdict: 'ok' | 'bounds' | 'replay' | 'pending' | null,
  finished: boolean,
  winnerUserId: string | null,
}
```

- **`players`** — one entry. Kept for shape consistency with every other engine; the runtime's membership check reads it ([`index.ts:264`](../../../backend/games/src/index.ts#L264)).
- **`seed`** — **the whole game.** Lose it and the run has no course, the submission cannot be validated, and a replay is meaningless. Issued once at `create`, never regenerated.
- **`mode`** / **`dayKey`** — a daily run is a different validation regime (no revive) and a different leaderboard. Lose it and a daily result silently becomes a free-play result.
- **`issuedAt`** — server clock at issue. **Wall time deliberately, unlike everywhere else in this folder**, because it is used for exactly one thing: bounding the submitted `duration` against real elapsed time (§3.4). It is never used to advance a simulation, which is the case where wall time is wrong.
- **`status`** — `running` → `submitted` | `rejected`. **This is the double-submission guard**, and it is the field a naive design loses. Without it a client can submit repeatedly until a favourable validation, or simply submit its best of five attempts on one seed. `applyInput` rejects any submission when `status !== 'running'`.
- **`distance` / `coins` / `duration` / `deaths`** — the accepted result, held so the terminal broadcast and the results row agree.
- **`verdict`** — why a submission was rejected, so the client can say something true. A rejected run that silently shows zero is a bug report.
- **`finished` / `winnerUserId`** — terminal state. `winnerUserId` is the player on a valid submission and `null` on rejection or abandonment, matching [`handleLeave`](../../../backend/games/src/index.ts#L442)'s honest shape. Recovered from the user id on restore, per [`cricket/index.ts:276-278`](../../../backend/games/src/engine/cricket/index.ts#L276-L278).

**The input trace is not in `serialize()`.** It can be a few hundred bytes to a few KB and it is needed exactly once, at validation. It goes straight into the `game_match_results` row (or a sibling table) and never into the live state that round-trips through Redis on every input.

## 4.3 No `serializeSecret()` — and why the seed is public

**The seed is public, by necessity and by design.** The client must have it to generate the course.

This inverts [`README.md`](./README.md) §1.3's rule — *"the seed goes in `serializeSecret()` whenever a future draw from it is information a player would pay for"* — and the inversion is worth being explicit about, because at first glance the client knowing the entire course looks like the ultimate cheat.

It is not, for a reason specific to this game: **the course is not secret information, it is the shared premise.** The daily challenge's whole value is that everyone runs the same known course; a player who studies it is doing what the game wants. Knowing where the obstacles are does not help you dodge them at 1600 u/s — that is the skill, and it is why the genre's players replay the same levels.

Contrast Ludo, where the next draw is the dice and knowing it is decisive, or Voiid Cards, where the sequence is the shuffle.

**What is protected is the score, and it is protected by validation (§3.4), not by secrecy.** That is the correct place for it: secrecy would be impossible to maintain in a client-simulated game anyway, and a design that depended on it would be lying to itself.

## 4.4 The shared simulation — where R1 actually lands

The `GameEngine` is trivial. The R1 requirements land on `sim/`, which is **shared, deterministic code that must exist identically in TypeScript, Swift and Kotlin.**

```
sim/
  generator.ts   — chunkAt(seed, index) → Chunk. PURE. No player state, no clock, no globals
  motion.ts      — speedAt(distance), lane change, jump and slide curves
  collide.ts     — runner hitbox vs chunk obstacles, at a fixed step
  replay.ts      — (seed, trace) → { distance, coins, deaths }. Server-side validation
```

**Rules for this module, each of which is a real failure mode:**

1. **`chunkAt` takes exactly two arguments** and reads nothing else. Not the player's speed, not a running RNG, not the wall clock. §2.4 explains what breaks otherwise, and the point of putting it in the signature is that the failure becomes impossible rather than merely discouraged.
2. **Fixed 120 Hz step everywhere**, including in the replay validator. A validator stepping at a different rate than the client would reject valid runs.
3. **No floating-point drift across platforms.** JavaScript numbers are IEEE 754 doubles; Swift `Double` and Kotlin `Double` match. **Use `Double` everywhere, never `Float`**, and avoid transcendentals in the hot path where implementations may differ in the last bit — the speed curve's `e^x` is evaluated once per frame and its result is *compared* against thresholds, so replace it with a lookup table sampled every 50 units and linearly interpolated. That removes the last cross-platform divergence risk from the code path that decides whether a run is valid.
4. **`Rng` is mulberry32** ([`geometry.ts:113`](../../../backend/games/src/engine/snake/geometry.ts#L113)), promoted to `engine/rng.ts`. Integer operations only, so it is bit-identical across the three languages — which is the property the whole validation scheme rests on.
5. **A golden-run test fixture, shared across all three.** A fixed seed and a fixed trace, with the expected distance and coin count checked into the repo, run in CI on all three platforms. **This is the single most important test in the project** — it is what turns "the three implementations agree" from a hope into a build failure.

## 4.5 Tick-rate independence

Covered in §3.5 for the client and §4.4 for the shared sim. The server engine has no tick, so the question does not arise for it — which is worth noting as a positive: **there is no server-side timing that can affect a run's outcome at all.**

## 4.6 `applyInput`

```ts
{ submit: { distance, coins, duration, deaths, trace } }
```

One frame shape. Validation, in order:

1. `status === 'running'` — else reject (double-submit guard, §4.2)
2. All numeric fields finite, non-negative integers within sane absolute caps
3. Layer 1 arithmetic bounds (§3.4)
4. `trace` well-formed: monotonically increasing distances, known actions, length under a cap (~500 events)
5. Mode rules: `deaths === 0` for a daily run

Returns `{ accepted: true, outcome }` on success — a valid submission ends the match immediately, so the runtime persists the result and stops it in one step ([`index.ts:286-289`](../../../backend/games/src/index.ts#L286-L289)).

**A rejected submission returns `accepted: false` and leaves `status: 'running'`.** It costs the server one Redis read and produces no broadcast ([`GameEngine.ts:29-33`](../../../backend/games/src/engine/GameEngine.ts#L29-L33)). The client may retry with a corrected payload — which matters because the common cause of a rejection is not cheating, it is a bug in one of the three simulation ports. Retrying a genuinely invalid claim fails identically every time.

**Rejection must be visible in logs with the verdict.** If layer-1 rejections start appearing at any rate above ~0, the three implementations have drifted and the golden-run test (§4.4) missed it.

---

# 5. Anti-cheat

Mostly §3.4. What is left is the honest summary.

## 5.1 What a modified client can express

**Everything about its own run**, because it runs the simulation. This is the exception's cost, stated plainly rather than buried:

| Claim | Defence | Effective? |
|---|---|---|
| Impossible distance for the duration | Layer 1 arithmetic | **Yes**, absolutely |
| More coins than exist on this seed | Layer 1, computed from the generator | **Yes**, absolutely |
| A distance its trace does not produce | Layer 2 replay | **Yes**, where run |
| Best of 10 attempts on one seed | `status` guard (§4.2): one submission per match | **Yes** |
| An easier seed | Server-issued | **Yes** |
| A perfectly-played legitimate run by a bot | — | **No** |
| Immunity to collisions, submitting a *consistent* trace | Layer 2 replay would catch an inconsistent trace, but a bot that genuinely plays perfectly produces a consistent one | **No** |

## 5.2 What that means

**The bottom line: the leaderboard is defensible against tampering and not against automation.**

The mitigation is not technical. It is that the leaderboard is **friends-only** (§3.4, §12), there are no prizes, and the social cost of botting a running game to beat your friend is the deterrent. This is the same conclusion [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §5.3 reaches about aimbots, and it is the honest one.

**What must not happen:** Voiid Run scores on a global leaderboard alongside games where cheating is structurally impossible. That would devalue every honest score in the app. If a global leaderboard is ever wanted, it needs replay validation on 100% of entries and an explicit acceptance that automation is undetectable — recommendation is not to.

## 5.3 The one thing to get right

**Seed issuance must be server-side and per-match**, and the daily seed must not be predictable far in advance. Derive it as `hash(serverSecret, dayKey)` and publish it only on the day. Otherwise a player could study tomorrow's course, which is a different and much cheaper cheat than any above.

---

# 6. Client rendering

**The expensive section, and the one with real platform risk.**

## 6.1 What it reuses

Honestly: **very little.** This is §1.3's point restated concretely.

| Piece | Source | Notes |
|---|---|---|
| `Rng` | [`geometry.ts:113`](../../../backend/games/src/engine/snake/geometry.ts#L113) | Ported. The only meaningful shared code |
| `GameAudio` / `GameHaptics` | [`GameAudio.swift`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift) | One new entry in `soundNames(for:)` |
| Fixed-step accumulator | [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §4.6 | Same pattern, no shared code |
| `BotScoreStore` shape | [`BotScoreStore.swift`](../../../apps/ios/Voiid/Voiid/Games/BotScoreStore.swift) | Local bests before a submission lands |
| Match creation / results | existing `GamesEngine` | Seed issue and submission |

No jitter buffer, no render clock, no predictor, no camera spring, no `physics2d`. **Everything visible is new.**

## 6.2 The perspective decision — 2.5D, not 3D

**Fixed-camera 2.5D: three lanes converging to a vanishing point, sprites scaled and positioned by depth, painter's algorithm.** No 3D meshes, no z-buffer, no perspective matrix.

This is the decision that makes the game affordable, so it is argued.

- **A true 3D runner needs a 3D renderer.** On iOS that means SceneKit or Metal with a real pipeline; on Android, a second one. [`GAMES.md`](../../GAMES.md) §4 rejects a game engine dependency for reasons that all still hold — binary size, a second toolchain, and "an escape hatch out of SwiftUI/Compose that breaks the iOS-is-the-reference parity workflow."
- **2.5D is a sorted sprite list.** Each object has a depth `z`; screen position and scale are `f(z)`; draw far-to-near. That is a `Canvas` draw loop with a sort, and it is what Subway Surfers looks like anyway — the genre's camera is fixed behind the runner and the perspective is largely fake in the originals too.
- **The whole scene is ~60–100 quads:** the runner, 3 lane strips, ~15 visible obstacles, ~40 coins, ~10 environment props, HUD.

**Projection:** `screenY = horizon + k / (z + c)`, `scale = k' / (z + c)`. Two constants, tuned once. Draw distance ~2400 units (1.5 s at max speed), which is what sets how much time the player has to read a pattern — a genuine gameplay constant, not a rendering one.

## 6.3 iOS

**Start with SwiftUI `Canvas` + `TimelineView(.animation)`**, per [`GAMES.md`](../../GAMES.md) §4. ~80 `context.draw` calls per frame with pre-rasterised sprite atlases.

**Be prepared to move to Metal**, and design for it: keep the simulation and the draw-list construction separate from the drawing, so the back end is swappable. The Metal path already exists in the app — [`SnakeMetalView.swift`](../../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift) and [`Snake.metal`](../../../apps/ios/Voiid/Voiid/Games/Snake.metal) — and a textured-quad batch renderer is *simpler* than Snake's SDF shader, so this is a genuine fallback rather than a rewrite.

Two things to inherit from that file and one to avoid:
- **Inherit:** the display-link structure and the frame-pacing discipline.
- **Inherit:** [`SNAKE.md`](../SNAKE.md) §2.6's verification method — "if the *arena border and food* go rock steady, the camera coupling is confirmed." Here: the lane lines and the horizon must be perfectly steady while the world scrolls.
- **Avoid:** the `nonisolated(unsafe)` snapshot pattern [`SNAKE.md`](../SNAKE.md) §2.5 documents as undefined behaviour. Voiid Run has no cross-thread state to share — the simulation runs on the render thread — so this must simply never be introduced.

## 6.4 Android — the real risk

Compose `Canvas` + `withFrameNanos`, mirroring iOS. **This is where the game is most likely to fail**, and the mitigation must be designed in rather than discovered.

- **Frame budget: 16.6 ms.** Sustained, not average — one dropped frame per second is visible in a runner in a way it is not in a board game.
- **Pre-rasterise everything.** All sprites are `ImageBitmap`s drawn with `drawImage`. **No vector path construction in the frame loop, no `Path` allocation, no text layout.** Compose `Canvas` is fast at blitting and slow at building geometry.
- **Object pooling.** Chunks, obstacles and coins are pooled and reused. A runner allocating per frame is a runner that stutters on GC, and a GC pause at 1600 u/s is a death the player did not cause.
- **A quality setting.** Reduced draw distance (2400 → 1600), fewer environment props, no particles. [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §12 lists "graphics quality on low-end Android" as a missing setting; **Voiid Run is the game that forces it to exist.**
- **A hard gate before committing to the game:** build a throwaway prototype that draws 100 depth-sorted sprites at 60 fps in Compose `Canvas` on the oldest device worth supporting. **Do this in week one, before any design work is validated.** If it cannot hit 60 fps, the game needs a different Android renderer and the cost estimate in §1.3 goes up again — and that is a decision to make before three months are spent, not after.

## 6.5 Art

The dependency §1.3 flags. Minimum viable set:

- **Runner:** run cycle (8 frames), jump (3), slide (2), stumble (2), death (4). One character.
- **Obstacles:** 7 types (§2.3), one sprite each plus a damaged variant.
- **Pickups:** 4 types, coin with an 8-frame spin.
- **Environment:** 3 ground tiles, ~8 background props, 2 parallax layers.
- **Effects:** dust, coin sparkle, shield break, boost trail.

**One art style, one palette, and it should be Voiid's** — abstract neon on dark, the same register as Snake ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.2's argument that Snake's abstraction is a feature). This is not only aesthetic: an abstract style is dramatically cheaper to produce and to keep consistent than a representational one, and it degrades gracefully at low resolution and small size. A stylised runner made of light needs no facial animation, no cloth, and no texture work.

---

# 7. Controls

## 7.1 The scheme

Four gestures. Nothing else.

| Gesture | Action | Threshold |
|---|---|---|
| Swipe left | Move one lane left | 40 pt, within 300 ms |
| Swipe right | Move one lane right | 40 pt, within 300 ms |
| Swipe up | Jump | 40 pt, within 300 ms |
| Swipe down | Slide | 40 pt, within 300 ms |

**Anywhere on the screen.** No control surface, no fixed zone. The entire screen is the input area, which is what makes it truly one-handed and what keeps the player's thumb away from the action.

## 7.2 The details that decide whether it feels good

These are not polish. A runner with 90% of these is a runner people say "feels floaty" about without knowing why.

- **Recognise on threshold, not on release.** The action fires the instant 40 pt is crossed. Waiting for the finger to lift adds ~80 ms of latency to every input, which at 1600 u/s is 128 units.
- **Dominant axis wins.** A diagonal swipe resolves to whichever axis moved further; ties go to horizontal (lane changes are ~4× more frequent).
- **Input buffering, 140 ms.** A swipe during a lane change queues and executes on completion. Without it, fast double-lane changes — a core skill — are impossible.
- **Coyote time, 90 ms.** A jump input up to 90 ms after running off a ledge still jumps.
- **One queued input maximum.** Queueing two makes the character run a script the player has lost track of.
- **Lane changes are not cancellable** once started. Mid-move reversal makes collisions unpredictable and makes replay validation harder.
- **Jump and slide are cancellable by each other**: sliding out of a jump lands early (a real technique), jumping out of a slide is buffered to the slide's end.

## 7.3 One-handed and small screens

The best of the eight by a distance, and it is inherent rather than designed: **swipe-anywhere with no on-screen control is the most accessible input scheme available on a phone.** No reachability problem, no handedness problem, no minimum touch target.

- **All HUD is non-interactive during a run.** The only interactive element is the pause button, top-left, 44 pt, deliberately away from the natural swipe area.
- **Large screens do not get more draw distance.** Draw distance is in world units and fixed. Otherwise a tablet player sees obstacles sooner — a real competitive advantage on a shared daily seed.
- **A settings-level swipe sensitivity** (30/40/55 pt) for players with limited mobility or large thumbs. Cheap, and it lands in the same settings screen §6.4's quality setting needs.

---

# 8. Visual design

## 8.1 Art direction

**Neon on dark, geometric, abstract** — Snake's register, for the reasons in §6.5 and one more: it is the only style that makes a 100-sprite scene readable at speed. Representational art at 1600 u/s is visual noise; a world made of light, edges and silhouettes reads instantly.

- **The track** is a dark surface with bright lane lines converging to a horizon. Lane lines are the primary spatial reference and must be perfectly steady (§6.3).
- **Obstacles are silhouettes with a bright rim.** Read by shape, at distance, in a quarter second. Every obstacle type has a distinct silhouette; two obstacles must never be confusable at draw distance, which is a design constraint on the art rather than a note.
- **The runner is the brightest thing on screen**, always, including through effects.
- **Environment is parallax and dim.** It exists for a sense of speed and must never compete with obstacles for attention. Anything that might be mistaken for an obstacle is a bug.
- **Speed is communicated by the world**, not by a number: parallax rate, motion blur on the ground, a subtle FOV widening (projection constant `k` by up to 8%) as speed rises.

## 8.2 Readability is the whole visual brief

An obstacle must be identifiable **1.2 seconds before impact**, which at max speed is 1900 units and beyond the 2400-unit draw distance's far end. That is the actual requirement and everything else serves it:

- Colour is never the only distinguishing channel (§8.4).
- The lane an obstacle occupies must be unambiguous at distance — obstacles are inset from lane edges so the gap is visible.
- **No visual effect may obscure the lane ahead.** Boost, magnet and shield effects render *behind* the runner or as screen-edge treatments, never in the track ahead. This kills a lot of otherwise attractive effect ideas and it is non-negotiable.

## 8.3 The HUD

Minimal. The player is reading the track.

1. **Distance**, top centre, large. The score, always visible.
2. **Coins**, top right, smaller.
3. **Personal best marker** — a ghost line and a subtle chime when passed. [`SNAKE.md`](../SNAKE.md) §4 ranks "personal best, always on screen" as the strongest single-player hook there is, and Snake still does not have it. Voiid Run should ship with it.
4. **Active pickup timers** as thin arcs at the screen edge, not as icons with numbers.
5. **Pause**, top left.

**In daily mode, one addition:** the position of the next friend above you on today's leaderboard, as a marker on the distance readout. *"Priya — 2,340 m"* approaching. That single element is most of the daily challenge's value, and it costs one leaderboard query at run start.

## 8.4 Accessibility

- **Obstacles differ in silhouette before colour.** Greyscale test, as in [`SEA_BATTLE.md`](./SEA_BATTLE.md) §8.4.
- **Reduce-motion:** no camera shake, no motion blur, no FOV change, reduced particles. The game remains fully playable — the test that separates feel from information.
- **A high-contrast mode** that drops environment brightness and raises obstacle rim intensity. Cheap, and it also happens to be the low-end-device quality setting (§6.4).
- **No flashing above 3 Hz**, ever. A runner with a photosensitivity trigger is a real risk given the neon direction, and it must be checked rather than assumed.

---

# 9. Motion and feel

Behind the reduce-motion switch ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13, open question O13).

| Moment | Motion | Duration | Curve |
|---|---|---|---|
| Lane change | Lateral move + 8° bank into the turn, recovering | 180 ms | `easeInOut` — position; bank `spring(0.2, 0.7)` |
| Jump | Ballistic arc; squash 0.85 on takeoff, stretch 1.1 at apex | 620 ms | Gravity, not a curve |
| Landing | Squash 0.8 for 90 ms, dust puff, 2 px camera dip | 140 ms | `spring(0.16, 0.5)` |
| Slide | Character compresses to 50% height over 80 ms, holds, restores over 100 ms | 520 ms | `easeOut` / `easeIn` |
| Coin collected | Coin scales to 1.4 and fades toward the HUD counter; counter ticks | 220 ms | `easeOut` |
| Magnet pull | Coins curve in on a quadratic bezier, arriving over 300 ms | 300 ms | `easeIn` |
| Boost start | FOV widens 8%, speed lines, chromatic edge | 260 ms in, 400 ms out | `easeOut` |
| Shield break | Radial flash, 3 px shake, 800 ms invuln flicker at 8 Hz | 400 ms | `easeOut` |
| **Near miss** | 60 ms hitstop at 0.35×, faint whoosh, 1 px shake | 60 ms | Step |
| **Death** | 250 ms hitstop at 0.05×, camera pushes in 15%, desaturate to 30%, character tumbles | 250 ms then 900 ms | hitstop step; push `easeOut` |
| Revive | Character reassembles from particles, 2 s invuln pulse at 4 Hz | 700 ms | `easeOut` |
| Speed increase (per 500 m) | One-frame white flash on lane lines, subtle rise in pitch | 120 ms | Step |

Three notes.

**Near-miss hitstop is the best 60 milliseconds in the game.** A 0.35× time dilation when an obstacle passes within 30 units converts a moment the player barely noticed into the moment they remember. It is the single highest feel-per-line item here, and it is also *information*: it tells the player they are running at the edge, which is exactly the feedback a runner needs and rarely gives. Snake already ships a hitstop-dilated `dt` in its camera spring ([`SNAKE.md`](../SNAKE.md) §1), so the pattern exists.

**Death gets 250 ms of near-freeze** because the player must *see* what killed them. A death that scrolls past at 1600 u/s reads as random, and a game that feels random is a game the player blames rather than themselves — [`SNAKE.md`](../SNAKE.md) §4's "a game you can't blame is a game you replay", inverted.

**Everything above must be pure presentation.** No animation may affect the simulation: hitstop dilates the render clock and not the fixed step, or a client that stutters differently produces a different run and replay validation fails (§3.5). This is the single most important constraint in this section.

---

# 10. Sound

Inherits [`SOUND_DESIGN.md`](../SOUND_DESIGN.md). New entry in `soundNames(for:)` ([`GameAudio.swift:282`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L282)).

## 10.1 The catch sound: deliberately absent

> **Voiid Run has no `catch` moment, and that is correct.**

[`README.md`](./README.md) §1.5 states it and the reasoning bears repeating because this is the only exception in the folder.

`catch.wav` means "a player's attempt is intercepted or ended by **the opponent**" ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §3). **There is no opponent in a single-player runner.** Nothing intercepts you — you crash.

This is precisely the exception Snake already makes: death by border gets no `catch` because *"You were not caught, you crashed"* ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.2). Every Voiid Run death is that death.

Playing `catch` on an obstacle collision would be the first thing to teach a player that the sound means nothing in particular — which is exactly what the shared-vocabulary rule exists to prevent. A vocabulary with one wrong entry is not a vocabulary.

**Not even in the daily challenge, where there is arguably an opponent.** Being beaten on a leaderboard is not being intercepted; it happens after the run, to a number.

## 10.2 The palette

Snake's register (abstract, synthesised) rather than cricket's (recorded, physical), per [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.2 — this is an abstract neon world and chasing realism "produces worse sound, not better." Most of it can come from [`synth.py`](../../../tools/gamesounds/synth.py), which §5.5 of the sound doc keeps alive for exactly this.

| Event | Sound | Notes |
|---|---|---|
| Footsteps | `run_step.wav` ×4 | Rate follows speed. The bed the whole mix sits on |
| Lane change | `swish.wav` | Very short, ~80 ms. Fires 100+ times a run — anything with a tail becomes a rattle |
| Jump | `jump.wav` | Rising, short |
| Land | `land.wav` | Impact + dust |
| Slide | `slide.wav` | Friction, looped for the slide's 520 ms |
| Coin | `coin_1..4.wav` | **Ascending pitch on a streak, resetting on a miss.** The single most satisfying mechanic in the genre, and free — it turns coin collection into a melody you are performing |
| **Near miss** | `near_miss.wav` | Doppler whoosh. Paired with the hitstop (§9) |
| Magnet | `magnet_loop.wav` | On `loopVoice`, the path built for Snake's `boost_loop` |
| Boost | `boost_start` + `boost_loop` + `boost_end` | **Reuse Snake's existing files verbatim.** Same meaning, same feel, already mastered |
| Shield break | `shield_break.wav` | Glass-ish, bright |
| **Death** | `crash.wav` + sub drop | Snake's border-death shape: "a low physical impact plus a sub drop" ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.2). **No `catch`** |
| Revive | `revive.wav` | Rising, hopeful, ~900 ms |
| Personal best passed | `pb_chime.wav` | Bright, unmistakable. Fires mid-run |
| Speed up (per 500 m) | `speed_up.wav` | Subtle, rising |

**Music.** The one game here that genuinely wants a track: a driving loop whose **intensity layers in with speed**, using the same technique as cricket's crowd bed ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.1) — one file, gain and layer changes driven by state, no new assets per intensity level.

But it is a **real budget item**: §7 of the sound doc caps total game audio at 4 MB per platform, and a 2-minute music loop at 64 kbps mono AAC is ~1 MB on its own. Recommendation: **ship without music, add it if the game proves out.** The coin melody and the speed-tracking footstep rate carry a surprising amount of rhythm on their own, and shipping a runner with a mediocre track is worse than shipping one with none.

**Mono, always** ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §6.6 — a stereo asset is a hard AVAudioEngine crash). Worth flagging that music is the asset most likely to arrive as a stereo file, and this is the game that would introduce it.

## 10.3 Haptics

- **Lane change:** very light tick.
- **Land:** medium transient, scaled by fall height.
- **Coin:** nothing. At 3–5 coins/second this would be a continuous buzz that drains the battery and means nothing.
- **Near miss:** sharp, short — the tactile half of the hitstop.
- **Death:** the existing `death()` pattern ([`GameHaptics.swift:89`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameHaptics.swift#L89)).
- **Shield break:** two quick transients.

---

# 11. Bots

**There is no opponent, so there is no bot.** Stating this rather than leaving the section empty, because the interesting thing is what takes its place.

## 11.1 The ghost is the opponent

A ghost is a **replay of another run on the same seed** — which is free, because the input trace already exists for validation (§3.4) and the simulation is deterministic. Feed a trace into the sim and you have a second runner, exactly reproducing what that player did.

That is a large feature for almost no cost, and it only exists because of the determinism §4.4 demands for other reasons.

**Ghosts available:**

| Ghost | Source |
|---|---|
| **Your best** on this seed | Local |
| **A friend's run** on today's daily | Their stored trace |
| **The friend directly above you** on the daily leaderboard | Their trace |

Rendered as a translucent runner in its lane, slightly desaturated, that disappears at its death point with a small marker. **Ghosts do not collide and cannot be interacted with** — a ghost that blocks you is a different, worse game.

## 11.2 Difficulty, honestly

**There is no difficulty setting, and there should not be.** Difficulty is the speed ramp (§2.2), it is identical for everyone, and that identity is what makes the daily leaderboard mean anything. A difficulty slider would fork the leaderboard into incomparable populations, which is the same mistake as Snake mapping difficulty to bot count ([`SNAKE.md`](../SNAKE.md) §3.4) — a knob that changes the game without changing the challenge.

The honest statement in the register [`RpsBot.swift:17-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L17-L21) sets: **the game is not beatable.** There is no end and no win state — every run ends in death, by design. What varies is how far, and the ceiling is human reaction time against a speed curve that asymptotes at 1600 u/s. A very good player will run 6–8 km. Nobody will run forever, and the asymptote is chosen so that the limit is *concentration*, not reflex — a long run should end because attention lapsed, not because the game became physically impossible.

---

# 12. Progression and retention — R3

## 12.1 The floor

[`README.md`](./README.md) §1.6's four requirements, adapted — this is the one game where "rematch" and "head-to-head" need translation:

1. **Rematch → "Run again", one tap**, on the death screen, same mode. The primary action.
2. **Post-run summary** — distance, coins, personal best, today's rank among friends, what changed.
3. **Head-to-head → today's friends leaderboard**, shown before and after.
4. **Share result into the chat**, with the ghost attached so it is a challenge rather than a boast.

## 12.2 The specific hook: the daily seed

> **One seed a day. Everyone runs the same course. The leaderboard is your contacts.**

Named, and it is the only reason to build this game (§1.2).

Why it works, mechanically:

- **A shared seed makes scores comparable.** In free play, "I ran 4,200 m" is a number about a course nobody else ran. On a shared seed it is a claim about a course your friend also ran, and they know exactly which bit is hard. That is the difference between a statistic and a conversation.
- **It creates a deadline.** The seed rolls at midnight. Retention research is unanimous that a resetting daily is the highest retention-per-line-of-code feature in casual gaming, and [`SNAKE.md`](../SNAKE.md) §4 item 7 and [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §5 both already identify it as the cheapest high-value thing this app could build.
- **It makes one run matter.** No revive in the daily (§2.5), one submission per seed (§4.2). A single 90-second run with a real stake.
- **It is asymmetric in Voiid's favour.** Subway Surfers cannot do this. It does not know your friends, and it never will.

**Both leaderboards, ranked among contacts only:** furthest, and most coins. Different play styles win each, which doubles the number of people who can be first at something.

## 12.3 How it uses the fact that this is a messenger

The strongest of the eight, which is surprising for a single-player game and is the reason it survives the cost objection.

- **A challenge is a message.** *"I got 3,400 on today's run. Beat it."* with the ghost attached. The recipient taps it, runs the same course, races the ghost. **That is a complete social loop built entirely out of single-player runs**, and it requires nothing except the determinism §4.4 already demands.
- **The daily leaderboard is a contact list with numbers on it.** Every entry is someone you can message from the same screen.
- **A friend beating your score is a notification worth sending**, and unlike a "your turn" push it is unambiguously welcome — it is the entire reason the player opted in.
- **Overtaking mid-run** (§8.3's approaching marker) is the moment: passing a friend's distance *while running*, with a chime, and knowing they will find out. Nothing else in the app has that.

## 12.4 What the first 30 seconds feel like

- **0–2 s.** Tap. The runner is already running. **No menu, no mode select, no character screen.** [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §9's principle applied to a single-player game: *"A player who opens the Games tab should be in a match within two taps, without making a single decision they don't care about yet."*
- **2–8 s.** Empty track. Coins in a straight line. The player collects them and learns that coins are good. Speed 700 u/s, which is slow. Nothing can kill them yet.
- **8–12 s.** The first barrier, in one lane, telegraphed by a coin trail arcing into a clear lane. They swipe. It works. **They have learned the core verb without being told.**
- **12–20 s.** Two more barriers, then a low barrier at 400 m — the first jump, again pre-taught by a rising coin trail.
- **20–30 s.** Speed has risen noticeably. They probably die around 600–1000 m. The death screen shows distance, personal best (their first, so everything is a best), and **RUN AGAIN** as the largest thing on screen.

**Zero words of instruction, and every mechanic taught by coin placement.** This is only possible because of §2.3's rule that coins trace the safe line, and it is the strongest argument for that rule.

## 12.5 What someone with 50 runs is chasing

- **Today's daily, and their friends' scores on it.** The whole loop. Nothing below matters as much.
- **A distance milestone.** 5 km is a real wall. Runners chase round numbers.
- **The coin leaderboard**, which rewards a completely different, riskier line and is a second thing to be best at.
- **Beating a specific friend's ghost**, which is much more concrete than beating a number — you watch where they went wrong.
- **Mastering the generator's vocabulary.** After 50 runs a player recognises patterns and knows the answer before reading it. That is a real skill ceiling and it is a direct product of §2.4's small, fixed pattern set — a generator with unbounded variety would never become learnable.
- **The near-miss.** Genre players chase the feeling of threading a gap at full speed, and §9's hitstop is what tells them they did.

Explicitly **not**: a shop, characters, upgrades, XP (§2.6). If those are ever wanted, they are a separate decision with an art budget attached.

---

# 13. Failure and edge cases

## 13.1 Disconnect

**No effect.** The run is local (§3.6). Submission queues and retries.

## 13.2 The app is backgrounded mid-run

**Pause immediately**, on `scenePhase`/`onPause`, before any frame can advance. Resume with a 3-2-1 countdown.

The failure to get right: on resume, the accumulated wall time must be **discarded, not applied**. Clamping elapsed time to 100 ms/frame (§3.5) handles it, but the pause must be explicit as well — relying on the clamp alone means a backgrounded app advances one 100 ms step on resume, which at 1600 u/s is 160 units of track the player never saw.

**A backgrounded run is not a cheat vector**, because `duration` is checked against wall time with slack (§3.4). A player who pauses for an hour still has the same in-game duration.

## 13.3 The app is killed mid-run

**The run is lost.** No resume.

Deliberate, and worth defending: resuming would require persisting the full simulation state, and — more importantly — it would let a player kill the app to avoid a bad run on a daily seed, which is exactly the "best of N attempts" cheat §4.2's `status` guard exists to stop. **A run started is a run spent**, which is what makes one submission per seed meaningful.

The `game_matches` row is left `active` and reaped by the existing TTL. The client shows nothing — a lost run is simply gone.

**A short grace exists in practice:** the seed is issued at match creation and the submission arrives at death, so a player who kills the app at 3,000 m has no submission and no score, the same as never running. There is no partial credit and there should not be.

## 13.4 Submission rejected

The client shows the run's distance locally with an honest badge — *"Not counted"* plus the verdict — never a silent zero.

**If layer-1 rejections appear at any measurable rate, the three simulation ports have drifted (§4.4) and it is a bug, not cheating.** This is the single most important operational metric for this game: a rejection rate above ~0.1% means the golden-run test is not covering something and legitimate players are being told their best run does not count.

## 13.5 Two runs on the same daily seed

Prevented at creation: one daily match per user per `dayKey`. A second attempt returns the existing match, which is already `submitted` and therefore closed.

**Free-play runs are unlimited** and have their own (non-shared) seed each time.

## 13.6 Clock skew and the day boundary

The `dayKey` is computed **server-side**, in a fixed timezone. Not the device's — otherwise changing the device clock yields a fresh daily attempt, which is the cheapest cheat in the game.

**Recommendation: UTC**, with the client displaying the local reset time. A per-user local-midnight reset is friendlier and creates 24 different leaderboards that cannot be compared, which destroys the shared-seed property. UTC is slightly worse for some users and correct for the feature.

## 13.7 A generated pattern is unsurvivable

**Prevented at generation** by the solvability proof (§2.4), which runs identically on client and server.

Because it is a shared seed, a failure here hits *everyone at once* and is unrecoverable for that day. So:

- The solvability check runs at generation, always, not only in debug.
- **A fuzz test in CI:** 10,000 random seeds × the first 200 chunks each, asserting every chunk is survivable at the speed for its distance. Cheap, and it runs on every change to the generator.
- **A server-side pre-check of tomorrow's daily seed**, nightly, over the first 300 chunks. If it fails, pick another seed and alert. It costs one job and it is the difference between a bad day and a bad day nobody noticed until users reported it.

## 13.8 Ties on the leaderboard

Distance is an integer, so ties happen. Break by: fewer coins missed, then earlier submission time. Displayed as a genuine tie with both names.

---

# 14. Build plan

**Phase 0 is a gate, not a phase.** If it fails, the game does not get built.

## Phase 0 — the feasibility spike *(one week, throwaway code)*

Two prototypes, no design work, no art.

1. **Android render spike.** 100 depth-sorted pre-rasterised sprites at 60 fps in Compose `Canvas`, on the oldest device worth supporting. Measure sustained frame time over 3 minutes, not average over 10 seconds.
2. **iOS render spike.** Same, in SwiftUI `Canvas`.

**Exit criteria:** sustained 60 fps with 30% headroom on both. If Android fails, the decision is a different Android renderer or no game — and it is made here, before three months are spent (§1.3, §6.4).

## Phase 1 — the shared simulation, headless, three languages

`sim/` (§4.4) in TypeScript first, then Swift and Kotlin. Generator, motion, collision, replay.

**The golden-run fixture and its CI job are part of this phase, not a follow-up.** A fixed seed, a fixed trace, expected outputs checked into the repo, asserted on all three platforms. Nothing after this phase is trustworthy without it.

Also here: the solvability fuzz test (§13.7).

## Phase 2 — iOS playable, free play only

Renderer, controls, obstacles, pickups, death, revive, sound, motion. **No server, no submission, no daily.**

This is where the game is tuned and where the "is it fun" question is answered. Every constant in §2 will change. Budget real time for it — a runner that is 90% tuned is a runner that feels wrong, and the difference is not visible in a spec.

## Phase 3 — server engine and submission

`engine/voiidrun/`, seed issue, layer-1 validation, results. Wire iOS to it. Free-play leaderboard among friends.

Layer-2 replay validation lands here too, running on the top 20 — it shares almost all of its code with `sim/replay.ts` from Phase 1.

## Phase 4 — the daily challenge

Server-side `dayKey` seeds, one match per user per day, friends leaderboard, the in-run approaching-friend marker, the nightly seed pre-check.

**This phase is the reason the game exists** (§1.2, §12.2). It should be planned as a headline feature, not as a post-launch addition — and if it is going to slip, that is the signal to reconsider the whole project.

## Phase 5 — Android parity

Phases 2–4. iOS is the reference, constants identical ([`SNAKE.md`](../SNAKE.md) §2.4), plus the quality setting from §6.4.

## Phase 6 — ghosts and sharing

Ghost playback, share-a-challenge into a chat, the overtake notification. Cheap by this point — the traces already exist — and this is what converts a single-player game into a social one.

## Phase 7 — polish

Near-miss hitstop tuning, coin melody, personal-best marker, music (if it survives the budget in §10.2), accessibility pass, high-contrast mode.

---

# 15. Open questions

1. **Build it at all?** *(O4 in [`README.md`](./README.md) §5, blocking)* Recommendation: **yes, conditionally and last** — conditional on the daily challenge and share-to-chat shipping with it (§1.2), and on Phase 0 passing on Android (§6.4). It is 4–6× Air Hockey and reuses almost nothing. If either condition fails, cut it.

2. **Three lanes or free movement?** Recommendation: **three lanes**, decisively (§2.1). Provable solvability and cheap replay validation are not close calls.

3. **Is there a revive, and does anything cost money?** *(O9)* Recommendation: **one free revive per run, none in the daily, nothing purchasable** (§2.5). The genre's economics assume monetisation and this app has none; half-building a store is worse than not.

4. **Rendering budget on Android?** (§6.4) Needs a decision on the oldest supported device before Phase 0 can have an exit criterion. Also forces the graphics-quality setting [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §12 lists as missing.

5. **Who makes the art?** (§6.5, §1.3) The only game here with a hard external dependency. A character with five animation states plus 7 obstacles plus environment is a commission, and it has a lead time that should start before Phase 2, not after.

6. **Does Voiid Run appear on the global leaderboard?** Recommendation: **no** (§5.2). Its scores are client-simulated and automation is undetectable; mixing them with games where cheating is structurally impossible devalues the honest ones. Friends-only daily leaderboards, full stop.

7. **Does the daily reset at UTC midnight or local midnight?** Recommendation: **UTC** (§13.6). Local is friendlier and creates 24 incomparable leaderboards, which destroys the shared-seed property that is the whole point.

8. **Music, or no music?** Recommendation: **ship without** (§10.2). It is ~25% of the entire 4 MB audio budget and a mediocre loop is worse than none. Revisit if the game proves out.

9. **Reduce-motion.** §9 is the most motion-heavy section in this folder — hitstop, shake, camera push, FOV change. The switch does not exist ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13). **Do not ship this game without it.**

10. **Options-bag typing.** *(O11)* `mode: 'free' | 'daily'` is a string, and the options bag is `[String: Int]` on both clients ([`GamesAPI.swift:37`](../../../apps/ios/Voiid/Voiid/Networking/GamesAPI.swift#L37)). Snake already smuggled its skin alongside as a sibling field. This is the third game wanting a string option; widen the type once or keep adding siblings.
