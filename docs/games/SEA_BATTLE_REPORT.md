# Sea Battle — build report

**Date:** 2026-08-25 · **Scope:** ship art (two teams), rocket launch, blast, and everything that
turned up on the way.
**Platforms touched:** iOS + Android. **Backend:** not touched — the engine was already correct.
**Verified:** both clients built, installed and played through practice mode on device.

Related: [`future/SEA_BATTLE.md`](./future/SEA_BATTLE.md) (design), §6 of
[`VISUALS_AUDIO_AND_PARITY.md`](./VISUALS_AUDIO_AND_PARITY.md) (the art direction this implements).

---

## 1. What was asked for, and what it is now

### 1.1 Ships, in two team colours

Seat 0 is **blue**, seat 1 is **red** — the server stamps the seat on every frame, so both clients
paint the same fleet the same colour without negotiating anything. A screenshot pasted into the
chat means one thing to both players.

Each hull is now painted in four passes instead of one: gradient body → deck plate (the hull scaled
in about its own centre, so there is no second path to keep in sync) → **team bands** → outline →
superstructure. The bands are the strongest colour cue and are placed per ship type, because a band
across a Carrier's flight deck has to miss the aircraft and a Destroyer has almost nowhere to put
one. A submarine gets a keel stripe instead of a cross-band — a cross-band on a tube reads as a
seam.

Colour is a **second** channel, never the only one (§8.4): the five silhouettes still differ in
shape, and your fleet is always the board you are not firing at. The board still works in greyscale.

**Where the palette lives:** `SeaBattleTeam.palette` →
[`SeaBattleShipArt.swift`](../../apps/ios/Voiid/Voiid/Games/SeaBattleShipArt.swift) /
[`SeaBattleShipArt.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/SeaBattleShipArt.kt).
Seven colours per team, one struct, so a caller can never pick up half a palette. **This is the one
file to edit when the generated reference art lands** — the hull paths are in unit space (x = 0…1
bow-to-stern, y = 0…1 across the beam), so retracing a generated image means replacing control
points in one place and both platforms follow.

The **fleet strip** now draws the same five silhouettes in team colour instead of the digits
`5 4 3 3 2`. A struck-through "3" told you a number was gone; a greyed-out submarine tells you
*which ship* is gone, and the endgame is entirely about which ship.

### 1.2 Rocket launch

A rocket, not the tumbling bomb that was there. The difference is two details: it is **oriented
along its own velocity** (climbs nose-up, levels at apex, noses over into the target) and it leaves
an **exhaust trail** — which is what makes the arc read as a path rather than a position.

Four phases, and only one of them is in the latency budget:

| Phase | Duration | In the budget? |
|---|---|---|
| **Charge** — launcher swings onto the bearing, pulls back | 140 ms | **No.** Starts on the FIRE *tap*, so it overlaps the round trip |
| **Flight** — the rocket | 380 ms | **Yes.** This *is* the round-trip window, and it is unchanged |
| **Impact** — flash, fireball, shockwave, debris | ~140 ms | **No.** Runs after the result is on screen |
| **Aftermath** — smoke drifts and dissipates | ~380 ms | **No.** |

`charge()` fires on the tap and `fire()` on the frame; `fire()` *waits* for the charge rather than
launching a rocket out of a tube that has not aimed yet. On any real connection the charge is long
over by the time the frame lands, so it costs nothing. **Total added latency: the flight, and only
the flight** — unchanged from before this work.

The launcher is drawn at rest too, and **stows**: at rest the tube is a stub barely taller than its
base, and committing to a shot runs it out. A permanent full-length tube would cover the two
centre squares of row 10 for the whole match.

### 1.3 Blast

Driven off the server's own `lastResult`, never re-derived, so the explosion can never disagree
with the board.

- **Hit** — white flash (onset), fireball on a decelerating curve, a shockwave ring that outruns it
  and thins, **six** debris specks thrown clear and pulled down by gravity, then smoke rising and
  dissipating.
- **Miss** — a *water column*, deliberately the opposite shape: a spout that falls back, droplets,
  and three hollow rings spreading. §8.4 says hit and miss differ in shape before colour, and that
  rule has to survive into the animation or the board stops working in greyscale for the one second
  per turn when something is actually happening. The rings resolve *into* the permanent miss marker
  rather than being swapped for it.
- **Sunk** — the hit blast plus a **second detonation** a third of the way through, offset off the
  impact point. It is the only thing on the board that ever happens twice, which is what makes a
  sink feel different from a hit rather than just louder.

The blast is routed to **the board the shot landed on** — mine on theirs, theirs on mine. Incoming
shots previously had no animation at all: a square changed colour while you were reading something
else, which is why taking fire never registered as taking fire.

All of it is off under reduce-motion, as the shell travel already was.

---

## 2. Bugs found and fixed

Ordered by how badly they were breaking the game.

### P0 — visibly broken in the shipped build

| # | Where | What was wrong |
|---|---|---|
| 1 | `SeaBattleScreen.kt` (Android, **online**) | **Ships were never drawn in a real match.** `ships` and `sunkTypes` were never passed to either grid. `enemyShips()` and `myShips()` were written, tested and wired into *practice only* — so a bot match rendered hulls and a match against a human rendered flat squares. The whole of §6.3 was invisible to anyone playing another person. |
| 2 | `SeaBattleBoard.kt` (Android) | `fillFor` still returned `Ink` for `SHIP`/`SHIP_HIT`. iOS switched those to sea when hulls landed, because a filled square shows around the bow and stern wherever the silhouette narrows — every Android ship sat inside a visible dark rectangle, exactly the per-cell look hulls were meant to replace. |
| 3 | `SeaBattleBoard.kt` (Android) | **The two boards drew on top of each other.** `Box(modifier.fillMaxWidth().aspectRatio(1f))` made `minWidth == maxWidth`, so *both* of `aspectRatio`'s candidate sizes were unsatisfiable and the secondary board overflowed its `heightIn(max = 96.dp)` to full size — with the fleet strip and the FIRE button painted across the middle of it. Fixed by letting the caller own the width. |
| 4 | `SeaBattleBoard.kt` (Android) | **No coordinate labels at all.** iOS has had A–J / 1–10 since the start; §6.1 lists them among the three things that must survive any art change, because a player calling "D7" in chat has to read D7 off the screen. Added, along with the hit-test offset the gutter needs — without it every tap lands one cell up and left. |
| 5 | `SeaBattleBotView.swift` (iOS, **practice**) | **The projectile was never drawn.** The screen passed `shellProgress` but never `firing`, and the grid draws the projectile only when told which square it is heading for. The full 380 ms animation ran every shot, advanced a value nothing read, and drew nothing. |
| 6 | Both platforms, both screens | **The sunk-ship outline lit the wrong cells.** `sunkCells` is one flat append-ordered list per seat (`seabattle/index.ts:166` pushes a whole hull in at the moment of sinking), but every caller took `.suffix(5)` / `.takeLast(5)`. Sinking anything shorter than a Carrier outlined its own cells *plus* squares belonging to an earlier wreck — a Destroyer lit two of its own and three of someone else's. Now `lastSunkShip()`, which reads the just-sunk type and takes that many, using the frame's `fleetSpec` rather than the local constant. |
| 7 | Practice, both platforms | **The sunk-reveal owner was inverted.** The code asked `turn == humanSeat ? botSeat : humanSeat`, but when it is the human's turn the *bot* just fired, so the ship that sank was the human's. Every sunk outline in practice was drawn on the wrong board. |
| 8 | Online, both platforms | **The match-winning sink outlined the winner's own fleet.** On the last shot there is no `turn`, and the owner fell back to "me". Now derived from the shooter the same way `SeaBattleSound` does it: the winner is whoever fired last. |

### P1 — parity and polish

| # | Where | What was wrong |
|---|---|---|
| 9 | `SeaBattleBoard.kt` (Android) | Hit markers had no debris specks; water had no diagonal glint. Both are iOS-only details the port dropped, and the shimmer is what proves the screen is alive during the long pauses of an async match. Added. |
| 10 | `SeaBattleBoard.kt` (Android) | Sunk-reveal stroke inset was `-0.4` against iOS's `-1.0`. Aligned. |
| 11 | `SeaBattleBotScreen.kt` (Android) | `firing = reticle.takeIf { shellProgress > 0f }` drew nothing on the first *and* last frame of the flight (progress is 0 at both ends) and nothing once the reticle cleared. Replaced with real `firingCell` state. |
| 12 | Both platforms | The secondary 96 pt board is a square in a full-width column; on Android it hung off the left edge. Centred. Labels now follow which board is *primary* rather than which board it is — at 96 pt the gutter would eat a seventh of the strip to render type nobody can read. |

---

## 3. Open issues — NOT fixed, and why

### 3.1 Sea Battle has no sound. At all. — **P0, needs assets**

`SeaBattleSound` and both match screens ask for eleven files:

```
fire_launch  splash_1 splash_2 splash_3  hit_metal_1 hit_metal_2 hit_metal_3
sink_groan   your_turn  place_thud
```

**None of them exist** in `apps/ios/Voiid/Voiid/Resources/GameSounds/` or
`apps/android/app/src/main/res/raw/`. The preload manifest in `GameAudio` lists all eleven, so every
Sea Battle match preloads a set of files that are not there and plays silence for every shot, every
hit, every sink and every placement. The only sounds that reach the player are the four shared ones
that happen to exist: `catch_shared`, `error`, `rank_up`, `match_end`.

This is an asset gap, not a code gap — the wiring is correct and the gains and the +180 ms groan
delay are already tuned. Drop the eleven files in and it works. Given the rocket and the blast now
have real onsets to hit, this is the single highest-value remaining item.

### 3.2 No card art — **P1, needs assets**

Sea Battle and Ludo both fall back to a tinted `#` glyph on the games grid while every other game
has illustrated art ([`CARD_ART.md`](./CARD_ART.md) §1). Two 1448×1086 PNGs, spec in that doc,
drop-in with no client change.

### 3.3 The design doc now contradicts the code — **P2, docs**

[`future/SEA_BATTLE.md`](./future/SEA_BATTLE.md) §8.2 still specifies the **ink-on-paper naval
chart** aesthetic, and reasons about it at length ("it makes 'nothing moves' an aesthetic rather
than a limitation"). §6.4 of the visuals doc is entirely about making things move, and this work
took the cartoon direction. §6.1 of that doc explicitly asks for §8.2 to be updated *in the same
PR*, on the grounds that a doc left contradicting the code is how the next person reintroduces the
old look by accident. Not done here — worth a small follow-up.

### 3.4 Pre-existing test failure, unrelated

`:app:testDebugUnitTest` fails on `LudoGeometryFixtureTest > fixture holds 225 keyed cells matching
the generated model`. It comes from the uncommitted Ludo work already in the tree
(`ludo_board_v3.json` and the `games/ludo/*` files) and touches nothing in this change. Sea Battle's
own tests pass on all three layers.

---

## 4. What was verified, how

| Check | Result |
|---|---|
| `xcodebuild` (iOS, Debug, iPhone 17) | **BUILD SUCCEEDED** |
| `./gradlew :app:compileDebugKotlin` | **BUILD SUCCESSFUL**, no new warnings |
| `./gradlew testDebugUnitTest --tests "*SeaBattle*"` | pass |
| `npx tsx src/engine/seabattle/seabattle.test.ts` | **Sea Battle OK** (engine untouched) |
| iOS practice, played on simulator | placement, five silhouettes, blue/red fleet strip, launcher, rocket in flight, hit blast, miss splash, permanent markers — all correct |
| Android practice, played on emulator | same, plus labels legible, tap-to-aim lands on the square tapped, secondary board correctly a 96 dp strip |

---

## 5. Files

**New**

- `apps/ios/Voiid/Voiid/Games/SeaBattleCannon.swift`
- `apps/android/app/src/main/java/com/voiid/app/main/games/SeaBattleCannon.kt`

The launcher, the rocket and the blast. Separate from the board renderer because the board answers
"what does square 47 show" a hundred times while the ordnance is one object with continuous
position and four phases — mixed into the cell loop it was ninety lines of trigonometry inside a
`for` over 100 squares, and every change to a fireball risked the grid.

**Changed** — `SeaBattleShipArt`, `SeaBattleMotion`, `SeaBattleBoard`, `SeaBattleView` /
`SeaBattleScreen`, `SeaBattleBotView` / `SeaBattleBotScreen`, on both platforms.

Every constant in `SeaBattleCannon` and every colour in `SeaBattleShipArt` is a parity surface.
SNAKE.md §2.4 records two renderers that were ported "line-for-line including the bug"; divergent
constants are how two builds of one game end up feeling different, and items 1, 2, 4 and 9 above are
what that looks like when it is left to drift.
