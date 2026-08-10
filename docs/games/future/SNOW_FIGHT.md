# Snow Fight

> **Status:** design only, nothing built.
> **Kind:** event-driven, 2 players, simultaneous reveal. **No tick loop.**
> **Blocked on:** the deadline sweeper ([`README.md`](./README.md) §2.3). Nothing else.
> **Read [`ARCHERY.md`](./ARCHERY.md) first.** This game shares its engine shape, its input model, its secret handling, its `ballistics/` solver and most of its renderer.

---

## How to read this document

Snow Fight and Archery are the same machine with a different game on top. Duplicating Archery here would produce two documents that drift apart the moment either is edited, so **this doc states only what differs**, and defers explicitly everywhere it does not.

Each section says which of three things it is:

| | |
|---|---|
| **→ Same as Archery** | Read the linked section there. Nothing differs |
| **→ Archery, plus…** | Read there first; the additions are here |
| **Different** | Fully specified here |

---

# 1. What the game is

**Different.**

Two players behind cover, throwing snowballs over a barrier at each other. You each have three positions to occupy, three hits before you are out, and cover that breaks down under fire.

Each round, **both players secretly commit to a move and a throw at the same time.** Then both are revealed and both snowballs fly. You are not aiming at where your opponent *is* — you are aiming at where you think they will *be*.

## 1.1 What it adds to Archery, and why it is a different game

[`ARCHERY.md`](./ARCHERY.md) §1.1 calls Archery *"RPS's dramatic beat with a skill ceiling"* — the reveal, plus a continuous aim against a wind you can read.

**Snow Fight adds the thing Archery deliberately does not have: an opponent who is trying to not be where you aimed.**

Archery's target does not move. The skill is entirely calibration — read the wind, compensate, execute — and the opponent's shot is *parallel* to yours rather than *against* it. You are both solving the same problem next to each other, and the better solver wins.

Snow Fight makes the opponent part of the problem. Your throw is aimed at one of three positions; theirs is choosing which to occupy. That is a **simultaneous 3×3 prediction game with a ballistic skill test layered on it** — you must both guess right *and* execute — and it restores the thing RPS actually has that Archery gives up: an opponent whose mind you are reading.

Concretely, this makes the two games complementary rather than redundant:

| | Archery | Snow Fight |
|---|---|---|
| Skill | Calibration | Calibration **+** prediction |
| Opponent | Parallel — a benchmark | Adversarial — a variable |
| Interaction | You cannot affect their shot | You can be *behind cover* when theirs lands |
| Match arc | Five independent rounds | An attrition curve — health falls, cover breaks |
| Feel | Precise, calm, meditative | Tense, mean, escalating |

**Cover that stops stopping snowballs** is the mechanic that gives the match an arc. Every barrier has health; every hit on it takes a chunk out. By round eight the position you have been hiding behind is a stump, and the safe option is no longer safe. The game gets more dangerous the longer it lasts, which is what makes an attrition game end decisively rather than by attrition.

## 1.2 Why it belongs in Voiid

**→ Archery, plus one thing.** [`ARCHERY.md`](./ARCHERY.md) §1.1's arguments carry: fast, symmetric, legible, message-sized.

The addition: **it is a game about doing something to a specific person.** Archery is a contest of accuracy that happens to be scored against someone. Snow Fight is you, deliberately, hitting your friend in the face with a snowball. That is a better message.

## 1.3 Cost

**Archery, plus roughly 40%.** The additional surface is: the position/cover model, cover erosion, collision of a snowball against a barrier as well as against a player, health, and a second dimension of hidden state (§4).

**And it is only worth that 40% if Archery ships first.** Built alone, Snow Fight pays the full cost of `ballistics/`, the reveal machinery, the pull-back control and the camera work. Built second, it inherits all of it. [`README.md`](./README.md) §3 sequences them adjacently at step 5 for exactly this reason.

---

# 2. Rules as implemented

**Different**, though the shot model is shared.

## 2.1 The arena

Side-on, symmetric, 600 units across.

Each player has **three positions**, laid out at different depths and heights:

| Position | Distance from centre | Cover height | Character |
|---|---|---|---|
| **Forward** | 180 units | **Low** (14 units) | Short range, easy to hit *from*, easy to be hit *in* |
| **Centre** | 240 units | **Medium** (24 units) | The default |
| **Back** | 300 units | **High** (34 units) | Safe, and a long throw |

**Three, not more.** Three positions produce nine (attacker, defender) combinations, which is a matrix a player can hold in their head — the same reasoning that makes RPS work. Five positions is twenty-five combinations and becomes guesswork rather than prediction.

**Asymmetric positions, not three identical hiding spots.** If the three were equivalent, choosing between them would be a coin flip. Because Forward is dangerous-but-close and Back is safe-but-hard-to-throw-from, the choice has a shape and a good player has reasons.

## 2.2 Cover

**The mechanic the game is named around.**

- Each of the three positions has its own barrier with **100 health**.
- A snowball that hits a barrier does **25 damage** and is stopped.
- At **75, 50 and 25 health** the barrier visibly loses a chunk and its **effective height drops by 25%** each time.
- At **0** the barrier is gone. That position offers no protection at all.
- **Cover does not regenerate.** Damage is permanent for the match.

So the arena degrades over a match, asymmetrically, shaped by where each player has been throwing. **The endgame is played in a ruin**, and it is a ruin the two players built.

This is what makes an attrition game end. Without it, two cautious players sit at Back and lob at each other for twenty rounds. With it, Back stops being safe around round eight and someone has to move.

## 2.3 Health

- **3 hits.** A direct hit costs 1 health.
- **No healing, no regeneration.**
- **First to reduce the opponent to 0 wins.**
- **Round cap: 12.** If both players are alive at round 12, the one with more health wins; equal health is a draw (`winnerId: null`).

**3 hits, not 5.** Every round must feel dangerous. Five gives too much room to absorb a bad read, and a match that runs 12 rounds is 3 minutes, which is at the top of what this format should ask for.

## 2.4 The round

**Different — this is the structural change from Archery.**

```
1. Wind announced (same for both players)
2. BOTH players secretly commit:  { moveTo, angle, power }
3. Both revealed. Moves resolve FIRST, then both snowballs fly
4. Impacts resolved simultaneously
```

**Move and throw are one commit.** Not two phases. If moving were a separate, earlier phase, its result would be public before the throw was aimed — and then you would be aiming at a known position, which deletes the prediction game (§1.1) entirely.

**Moves resolve before throws.** Both players are in their new positions when the snowballs are computed. This is what makes it a prediction: you aimed at where you *guessed* they would be, and now they are wherever they chose.

**Moving is free and always available.** No cooldown, no cost. A cost would make the safe play "never move", which collapses the matrix.

## 2.5 The throw

**→ Archery, with different constants.** Same two continuous values, same clamping, same input model ([`ARCHERY.md`](./ARCHERY.md) §2.4).

| | Archery | Snow Fight |
|---|---|---|
| Angle range | −5° to +45° | **+10° to +70°** — you are lobbing *over* cover, not shooting flat |
| Power range | 0.30–1.00 → 90–300 u/s | 0.30–1.00 → **70–210 u/s** |
| Gravity | 90 u/s² | **120 u/s²** — snow is a lob, and a heavier arc is easier to read |
| Drag | 0.02 /s | **0.04 /s** — a snowball is not an arrow |
| Wind range | −12 to +12 | **−8 to +8** — with a higher arc, wind has longer to act, so the same displacement needs less wind |
| Flight time | 1.1–1.6 s | **1.4–2.0 s** |

**The higher arc is the point.** A flat shot would go into the barrier, so every throw must clear cover, which means every throw is a lob with a long hang time — and a long hang time is what makes the wind, and the opponent's move, matter.

## 2.6 Hit resolution

Evaluated in this order, per snowball:

1. **Does it hit the opponent's barrier?** If the trajectory crosses the barrier's silhouette at its *current* height (§2.2), the barrier takes 25 damage and the snowball stops. **A short throw at a tall barrier is the most common outcome early and the least common late.**
2. **Does it hit the opponent?** Within a 16-unit radius of their body centre → 1 health.
3. **Otherwise** it lands in the snow. Nothing happens.

**Two snowballs never collide.** Modelling it would be a rare, hard-to-see event that adds nothing but a physics edge case.

**A snowball aimed at a position the opponent left simply lands there**, harmlessly, and it should visibly do so — the miss is the information. Seeing your snowball land exactly where they *were* is the game's best teaching moment and its most infuriating one.

## 2.7 Winning

- Opponent at 0 health → win.
- Round 12 with both alive → more health wins; equal is a draw.

`GameOutcome.scores` is **health remaining**. Higher is better.

## 2.8 What is deliberately excluded

**→ Archery** ([`ARCHERY.md`](./ARCHERY.md) §2.6) for gusting wind, moving targets, equipment and aim assist. Plus:

| Feature | Excluded because |
|---|---|
| **Multiple throws per round** | Breaks the simultaneous reveal into a sequence, and the reveal is the game |
| **Ammo limits** | A resource to track in a game whose decisions are already position + aim |
| **Cover repair** | Removes the attrition arc, which is the whole reason cover has health (§2.2) |
| **A third player** | Nine (attacker, defender) combinations is a matrix; twenty-seven is not |
| **Snowball size / charge-up** | Power already covers it, with a physical meaning |

---

# 3. Network model — R2

**→ Same as Archery.** [`ARCHERY.md`](./ARCHERY.md) §3 applies without modification: event-driven, no tick loop, no netcode, one broadcast per resolved round, the client animating from parameters rather than a stream.

Three specifics that differ:

## 3.1 The commit is larger

The input frame carries `{ moveTo, angle, power }` instead of `{ angle, power }`. One extra small integer. Payload is unchanged in any meaningful sense.

## 3.2 The reveal is bigger

Both moves *and* both throws are revealed in one frame, and the client animates: moves first (~400 ms), then both snowballs (~1.7 s), then impacts. **A round's animation is ~2.5 seconds** against Archery's ~2.0.

The rule from [`ARCHERY.md`](./ARCHERY.md) §3.3 is unchanged and is the load-bearing one: **one broadcast, not two.** Broadcasting the first player's commit on arrival would leak their chosen position, which is exactly the information the whole game is about.

## 3.3 More rounds, so the deadline matters more

12 rounds against Archery's 5, so a match is ~3 minutes and there are 12 opportunities for someone to go AFK. The deadline (§13.2) is load-bearing here in a way it is not in a 90-second game.

---

# 4. Engine design — R1

Folder: `backend/games/src/engine/snowfight/`, sharing `engine/ballistics/` with Archery.

## 4.1 Interface surface

**→ Same as Archery** ([`ARCHERY.md`](./ARCHERY.md) §4.1). No `tick`, no `serializeForWire`, no `serializeForPlayer`, yes `serializeSecret`, yes `deadlineAt`/`onTimeout`.

## 4.2 `applyInput`

**Archery, plus one field.**

```ts
{ throw: { moveTo: 0 | 1 | 2, angle: number, power: number } }
```

Validation is [`ARCHERY.md`](./ARCHERY.md) §4.2's, plus:

- `moveTo` is an integer 0–2. **Anything else clamps to the current position** rather than rejecting — same posture as the angle clamp, and for the same reason ([`snake/index.ts:275-279`](../../../backend/games/src/engine/snake/index.ts#L275-L279)): a malformed value during a lag spike should not leave the player unable to act.
- `moveTo` equal to the current position is **legal and is a real choice** — staying put is a decision, and forcing a move every round would remove a third of the matrix.

Angle range differs (§2.5). Power range differs. Everything else is identical.

## 4.3 `serialize()` — the differences

**Archery's shape** ([`ARCHERY.md`](./ARCHERY.md) §4.3), with these changes:

**Removed:** `roundsWon`, `ringTotal` — there are no rings and no per-round points.

**Added:**

```ts
health: [number, number],           // 0..3
position: [0|1|2, 0|1|2],           // current, AFTER the last resolved move
coverHealth: [number[], number[]],  // [seat][position] → 0..100
hasThrown: [boolean, boolean],      // renamed from hasShot
lastResult: {
  moves: [0|1|2, 0|1|2],
  throws: [Throw, Throw],           // angle, power, impact x/y, what it hit
  hits: [boolean, boolean],
  coverDamage: [{ seat, pos, amount }, ...],
} | null,
```

Why each must survive a restart — which happens **on every input** ([`index.ts:279`](../../../backend/games/src/index.ts#L279)):

- **`health`** — the match. Lose it and both players are restored to full, forever.
- **`position`** — where each player currently is. **The field a naive design loses and the loss is silent:** if position reset to Centre on every restore, then every player would be at Centre whenever a round resolved, regardless of where they moved. Since restores happen on every input, that is *always*, and the entire movement mechanic would do nothing while appearing to work — the animation would play and the collision would ignore it. **This is the single most important field in this engine** and it deserves an explicit test.
- **`coverHealth`** — six numbers. Lose them and cover silently repairs itself every restore, deleting the attrition arc (§2.2) — and again it would be invisible, because the barrier would simply never appear to break.
- **`hasThrown`** — **booleans, never the commits themselves.** The anti-cheat line, exactly as [`cricket/index.ts:194-196`](../../../backend/games/src/engine/cricket/index.ts#L194-L196) states for hand cricket.
- **`lastResult`** — both moves, both throws, both hits, cover damage. Safe to send: fully resolved. This is what the client animates.

Everything else — `players`, `round`, `wind`, `windHistory`, `phase`, `history`, `moveCount`, `deadlineAt`, `finished`, `winnerUserId` — is [`ARCHERY.md`](./ARCHERY.md) §4.3 verbatim, including the argument that **`wind` must be drawn at round start and serialized**, or the two players are shot in different winds.

## 4.4 `serializeSecret()`

**→ Archery** ([`ARCHERY.md`](./ARCHERY.md) §4.4), with a bigger secret:

```ts
serializeSecret(): GameStatePayload {
  return {
    pending: this.s.pending,   // [Commit | null, Commit | null] — moveTo AND aim
    rng: this.rng.seed,
  };
}
```

**The secret now hides two things, and the position is the more valuable of them.**

Knowing an opponent's aim (Archery's secret) tells you where their snowball will land, which is useful. Knowing their *chosen position* tells you exactly where to throw, which is decisive — it converts a 1-in-3 guess into a certainty, and the guess is the game.

So [`GameEngine.ts:83-96`](../../../backend/games/src/engine/GameEngine.ts#L83-L96)'s warning applies with more force here than anywhere else in this folder except Voiid Cards: a `pending` that leaked into `serialize()` would not degrade Snow Fight, it would end it.

**A restore without the secret re-opens the round**, both players re-commit. One replayed round, nothing leaked — the same trade [`cricket/index.ts:267-272`](../../../backend/games/src/engine/cricket/index.ts#L267-L272) makes. The RNG reseeds and remaining winds change; log it.

## 4.5 RNG and determinism

**→ Same as Archery** ([`ARCHERY.md`](./ARCHERY.md) §4.5). One draw per round (the wind), seed in the secret, **no randomness in the flight at all**.

Worth restating because the temptation is stronger here: **no random scatter on a snowball.** A snowball is intuitively less precise than an arrow and adding scatter would feel physically right. It would also make a correct prediction lose to a wrong one at random, which destroys the only thing the game is about. **The snowball is exactly as precise as the arrow.**

## 4.6 Tick-rate independence

**→ Same as Archery** ([`ARCHERY.md`](./ARCHERY.md) §4.6). No tick; flights integrated to completion synchronously at a fixed 1/240 s step; the only time-dependent value is an absolute `deadlineAt`.

Additions to the solver, both shared into `ballistics/`:

- **Segment intersection against a barrier silhouette**, evaluated per integration step. The barrier is a vertical segment at a known x with a height that changes with damage (§2.2), so this is a swept point-vs-segment test — the same shape as [`geometry.ts:66`](../../../backend/games/src/engine/snake/geometry.ts#L66)'s `segmentSegmentDist2`, which should be reused rather than rewritten.
- **Point-vs-circle against the player**, radius 16.

**Both must be swept, not sampled at step ends.** At 210 u/s and a 1/240 s step a snowball moves 0.9 units per step against a 16-unit body radius, so tunnelling is not a practical risk here — but the barrier is a *thin* segment, and a thin obstacle is exactly what discrete sampling misses. [`geometry.ts:8-13`](../../../backend/games/src/engine/snake/geometry.ts#L8-L13) documents the general form of this bug and [`snake/index.ts:410-417`](../../../backend/games/src/engine/snake/index.ts#L410-L417) records it actually shipping when speeds increased. Sweep it.

**The golden-shot fixture** ([`ARCHERY.md`](./ARCHERY.md) §4.6) extends here with barrier-hit and player-hit cases, asserted on all three platforms in CI.

---

# 5. Anti-cheat

**→ Archery** ([`ARCHERY.md`](./ARCHERY.md) §5), with one addition and one amplification.

**The addition:** `moveTo` is validated to 0–2 and clamped. A client cannot occupy a position that does not exist, cannot be in two positions, and cannot change position after committing (`pending[seat] !== null`).

**The amplification:** [`ARCHERY.md`](./ARCHERY.md) §5.1's perfect-aim client is **strictly weaker here**, and this is a genuinely interesting property.

In Archery, a solver-inverting client hits the gold every time, because the target does not move. In Snow Fight, a perfect solver still has to **guess which of three positions to aim at**. A perfect aimbot with a random guess hits 1 round in 3; a human with decent aim and a good read hits more often than that.

**Snow Fight is meaningfully more cheat-resistant than Archery, for free, because prediction cannot be automated.** A cheating client would need to model its opponent's *mind*, not the physics.

That does not make it cheat-proof — perfect aim still converts every correct guess into a hit, which is a real edge. But it caps the advantage at roughly "always executes correctly", rather than "always wins", and it is worth noting as an argument for this game over Archery if only one ships.

---

# 6. Client rendering

**→ Archery, plus.** [`ARCHERY.md`](./ARCHERY.md) §6.1's reuse table applies, plus Archery's own scene renderer, camera and ballistics port.

**What differs:**

## 6.1 The scene is symmetric and shows both sides

Archery's camera is anchored on one archer and one target. Snow Fight's arena has two mirrored halves, both of which matter, and **both must be visible during the aiming phase** — you cannot choose a position or a target without seeing the state of all six barriers.

- **Aiming:** the full arena, both sides, all barriers, both players. Wide.
- **Move resolution:** stays wide. Both players slide to their new positions and you need to see both.
- **Flight:** [`ARCHERY.md`](./ARCHERY.md) §6.3's keyframed camera, but it must cover **two snowballs travelling in opposite directions.** Rather than tracking one, the camera holds a framing that contains both, tightening slightly as they converge. Precomputed from both trajectories before the animation starts — still keyframed, still immune to the jitter class [`SNAKE.md`](../SNAKE.md) §2 documents.
- **Impact:** brief punch-in on whichever side took a hit; if both, hold wide.

## 6.2 The barriers are the most important thing to render

Six barriers, each at one of five damage states, each visibly different in **height and silhouette**. This is game state a player consults before every decision, so it must be readable at arena scale without a tap — a barrier at 40 health must be obviously shorter and more broken than one at 90.

**Damage is cumulative and visible in the shape**, not in a health bar. A bar would be legible and would also make the game read as a stats screen; a barrier that is visibly a stump communicates the same thing and is the game's whole aesthetic.

## 6.3 Platform

**→ Same as Archery.** `Canvas` + `TimelineView(.animation)` on iOS, Compose `Canvas` + `withFrameNanos` on Android, animated only during the ~2.5 s resolution and static otherwise. **No Metal.**

---

# 7. Controls

**→ Archery, plus a position picker.** [`ARCHERY.md`](./ARCHERY.md) §7 applies in full: pull-back-and-release, the non-linear angle mapping, the fine-adjust arc, the numeric readout, the 25% arc preview, one-handed drag-from-anywhere.

**What is added:**

## 7.1 Choosing a position

**Three tap targets on your own side**, one per position, shown as ghosted outlines of your character. Tap to select; the ghost solidifies.

- **Selecting a position does not commit anything.** It is part of the same commit as the throw.
- **You can change it freely until you release the throw.**
- **The aim preview updates with the selected position**, because your throw originates from wherever you will be. This coupling is the interesting part of the control: moving Back makes the throw longer, so the same aim now falls short, and the player sees it immediately.
- **Default: stay where you are.** No decision required to keep playing.

## 7.2 The commit order

**Position first, then aim, then release.** The UI does not enforce it — the position targets stay live during the drag — but the natural order falls out of the preview coupling in §7.1, and the tutorial hint (§12.4) should teach it in that order.

## 7.3 One-handed

**→ Archery.** Drag from anywhere, readout offset above the thumb, no fixed control surface.

**One addition:** the three position targets are on **your own side of the arena**, which on a portrait phone is the bottom third — thumb territory. They are 56 pt targets.

---

# 8. Visual design

**→ Archery's art direction** ([`ARCHERY.md`](./ARCHERY.md) §8.1): side-on, clean, high contrast, minimal, wind visible in the world, persistent faint ghost trails from previous rounds.

**What differs:**

## 8.1 The arena tells the story

Archery's scene is the same in round 5 as in round 1. **Snow Fight's scene is a record of the match**: broken barriers, craters where snowballs landed, snow displaced. By round 10 the arena looks like something happened in it, and the ghost trails from previous rounds are a visible map of where each player has been throwing.

This is the game's best free feature. The state is already in `coverHealth` and `history`, and rendering it accumulates a narrative at no cost.

## 8.2 What the player must see

**→ Archery's list** ([`ARCHERY.md`](./ARCHERY.md) §8.2), plus:

1. **Both healths**, as three discrete pips each — not a bar. Three is a countable number and pips make "one hit from losing" unmissable.
2. **All six barriers' damage states**, from their shape (§6.2).
3. **Your currently selected position**, before commit.
4. **Where the opponent was last round**, marked faintly — the only public information you have about their habits, and the raw material of prediction.

That last item is the most important addition and it should not be subtle. **The prediction game is only playable if the player can see the opponent's history**, and a player who cannot remember where someone stood three rounds ago is playing a coin flip. A small three-column strip showing the opponent's last five positions is the single highest-value HUD element in this game.

## 8.3 Accessibility

**→ Archery** ([`ARCHERY.md`](./ARCHERY.md) §8.3), plus:

- **Positions are labelled** (Forward / Centre / Back), not identified by colour or by memory of layout.
- **Barrier damage reads in silhouette**, not colour — already required for legibility (§6.2), and it means the state survives greyscale.
- **Health pips are shape-distinct** when spent (filled vs hollow outline), not colour-distinct.

---

# 9. Motion and feel

**→ Archery's table** ([`ARCHERY.md`](./ARCHERY.md) §9) for the draw, release, flight, trail and impact. Behind reduce-motion ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13).

**What is added or changed:**

| Moment | Motion | Duration | Curve |
|---|---|---|---|
| Position selected | Ghost solidifies, character leans toward it | 200 ms | `spring(0.22, 0.7)` |
| **Move resolution** | Both characters slide to their new positions, ducking behind cover on arrival | **400 ms**, both simultaneously | `easeInOut` |
| **The pause after moves** | 250 ms of stillness before both throws release | 250 ms | — |
| Both throws | Two snowballs, opposite directions, camera framing both | 1.4–2.0 s | Physics |
| **Snowball hits a barrier** | Impact burst, barrier chunk breaks away and falls, barrier settles to its new height | 500 ms | chunk: gravity; settle `spring(0.2, 0.8)` |
| **Snowball hits a player** | Splat, character knocked back 8 units and recovers, 4 px screen shake, health pip extinguishes | 400 ms | knockback `spring(0.16, 0.45)` |
| Snowball lands in snow | Small puff, a crater persists for the match | 300 ms | `easeOut` |
| **Both players hit** | Both animate simultaneously, shake doubled to 6 px | 400 ms | — |
| Health at 1 | Persistent slow pulse on the last pip | 1.2 s loop | `easeInOut` |
| Barrier destroyed | Full collapse, dust, a beat of stillness | 700 ms | gravity + `easeOut` |
| Match end | Camera pulls back over the ruined arena, result card | 900 ms | `easeOut` |

**The 250 ms pause between moves resolving and throws releasing is the best quarter-second in the game.**

Both players have just seen where the other went. Their snowballs are already committed and already wrong or right, and nobody can do anything about it. That pause is the moment the prediction pays off or does not, and it must be long enough to read and short enough not to drag. It is the direct analogue of RPS's beat before the reveal ([`RPS.md`](../RPS.md) §2.3) and it should be tuned as carefully.

**The barrier chunk that breaks away must fall and stay.** A barrier that shrinks by a step reads as a value changing; a barrier that loses a piece which lands in the snow and remains there reads as damage. The debris is also what makes §8.1's accumulated arena work.

---

# 10. Sound

**→ Archery's structure** ([`ARCHERY.md`](./ARCHERY.md) §10) — physical, recorded, mono, one new `soundNames(for:)` entry ([`GameAudio.swift:282`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L282)).

## 10.1 The shared catch sound

> **The catch moment in Snow Fight is: a snowball hits you.**

Per [`README.md`](./README.md) §1.5, and note it is **different in kind from Archery's**, which fires on losing the round ([`ARCHERY.md`](./ARCHERY.md) §10.1). Here it fires on the *hit*, because in Snow Fight the hit **is** the interception: your attempt to hide was ended by the opponent finding you.

That is the vocabulary rule applied correctly rather than copied: `catch` means "a player's attempt is intercepted or ended by the opponent" ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §3), and the two games have that moment in different places because they are different games.

- **You are hit:** `catch.wav` + `snow_splat.wav`. Unmodified, layered.
- **You hit them:** `snow_splat.wav` only, brighter. **No `catch`** — same asymmetry as Ludo ([`LUDO.md`](./LUDO.md) §10.1) and Chess.
- **Both hit in one round:** both sounds fire for the local player in the right roles — `catch` + splat for the incoming, splat for the outgoing, 80 ms apart so they read as two events.
- **A snowball stopped by your barrier:** **no `catch`.** Your attempt was not ended — your cover worked, which is the opposite. `thud_snow_on_wood.wav` and a small satisfaction.

## 10.2 The palette — differences from Archery

| Event | Sound | Notes |
|---|---|---|
| Position selected | `step_snow.wav` | Crunch |
| **Move resolution** | `move_snow.wav` | Both characters, ~400 ms of scrambling. Fires every round, so keep it short and vary it — **3 variants** |
| Wind-up | `windup.wav` | Replaces Archery's `draw_creak`. Cloth and effort, gain rising with power |
| **Throw** | `throw_1..3.wav` | A grunt and a whoosh. Replaces `bow_release` |
| Flight | `snowball_whoosh.wav` | Softer and slower than Archery's arrow — a lob, not a shot |
| **Hit barrier** | `thud_snow_on_wood.wav` | Dull, heavy. The most common outcome early |
| **Barrier chunk breaks** | `wood_crack.wav` | Layered over the thud at the 25/50/75 thresholds. **This is the escalation sound** — the arena getting more dangerous is audible |
| **Barrier destroyed** | `barrier_collapse.wav` | Larger, with debris |
| **You are hit** | **`catch.wav`** + `snow_splat.wav` | §10.1 |
| You hit them | `snow_splat.wav` | Brighter mix |
| Land in snow | `snow_land.wav` | Soft, anticlimactic. The miss |
| Health at 1 | `heartbeat_loop.wav` | Very quiet, on `loopVoice`. **The tension bed** |
| Match end | Existing stingers | — |

**A wind bed**, as in [`ARCHERY.md`](./ARCHERY.md) §10.2, on `loopVoice`, gain tracking strength. **Snow Fight has two loop candidates** — the wind bed and the low-health heartbeat — and `GameAudio` has one dedicated `loopVoice` outside the round-robin pool. **Do not add a second loop voice for this.** Cross-fade: when a player drops to 1 health, the wind bed ducks 6 dB and the heartbeat takes the loop slot; on match end both stop. One decision, made here rather than discovered as a bug.

**Mono, always** ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §6.6 — a stereo asset is a hard AVAudioEngine crash).

## 10.3 Haptics

**→ Archery** ([`ARCHERY.md`](./ARCHERY.md) §10.3) — the ramped wind-up, the sharp release, the impact. Plus:

- **Move resolution:** two light taps, 120 ms apart, as both players land.
- **Your barrier is hit:** medium transient. You feel your cover take it.
- **A barrier chunk breaks:** sharper, layered.
- **You are hit:** the existing `death()` shape ([`GameHaptics.swift:89`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameHaptics.swift#L89)).
- **At 1 health:** a very light pulse each round start, matching the heartbeat.

---

# 11. Bots

**→ Archery's aim model** ([`ARCHERY.md`](./ARCHERY.md) §11.1) for the ballistic half — Gaussian angle and power error, partial wind compensation, the four bands, and the rule that **difficulty never touches the physics**.

**What is added is the interesting part**, and it is a genuinely different problem from Archery's.

## 11.1 The second axis: prediction

The bot must decide **which position to throw at** and **which position to occupy.** Both are guesses about a human.

This is [`RpsBot.swift`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift)'s exact problem, and the solution is the same one, for the same stated reason — *"difficulty here is EXPLOITATION OF HUMAN NON-RANDOMNESS, which is how the game is actually played well"* ([`RpsBot.swift:11-15`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L11-L15)).

| Band | Where it throws | Where it moves |
|---|---|---|
| 0.0–0.25 | Uniformly random position | Random |
| 0.25–0.5 | The opponent's **current** position — assumes they stay | Random |
| 0.5–0.75 | **Frequency model** over the opponent's position history, weighted toward recent rounds | Away from wherever the opponent threw last |
| 0.75–1.0 | Frequency model **+ cover awareness**: prefers targeting positions whose barrier is already broken. Moves to whichever of its own positions has the most cover left, biased away from its own recent choices | Same, plus it *deliberately varies* its own pattern |

**The frequency model is [`RpsBot.chooseThrow`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L50)'s, structurally.** Weights over the opponent's last N positions with recent choices counting double — the same construction, applied to three positions instead of three throws, and it should reuse that code rather than reimplement it. That file's comment applies verbatim: *"With no history there is nothing to exploit, so it falls through to random — a bot that 'reads' you on move one would be inventing a pattern that cannot exist yet."*

**The top band varying its own pattern is the honest addition.** A bot that always moves to the best-covered position is itself predictable, and a good human will exploit it in four rounds. Deliberate variance in its own choices is not noise — it is correct play, and it is the same reasoning that makes a good RPS player randomise.

## 11.2 What the top of the scale can and cannot do

In the register [`RpsBot.swift:17-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L17-L21) sets:

> **The top bot executes almost perfectly and guesses about as well as a good human. Against a player who is genuinely random it hits one round in three, and there is nothing it can do about that — which is correct, because nothing can.**

**It can:** hit whatever it aims at, compensate fully for wind, exploit any pattern in your movement, and target your broken cover.

**It cannot:** beat a player who moves unpredictably. **This is the same honest ceiling as RPS**, and it is worth being explicit that Snow Fight inherits RPS's fundamental limit exactly where it inherits RPS's structure.

**But unlike RPS, a player who guesses randomly still has to aim** — so the bot's execution advantage is real even against an unpredictable opponent. The top bot beats a random-but-inaccurate player and loses to a random-but-accurate one, which is a much more satisfying skill test than either game alone.

**Presentation: →** [`ARCHERY.md`](./ARCHERY.md) §11.3, plus a visible hesitation before choosing a position at high skill.

---

# 12. Progression and retention — R3

## 12.1 The floor

**→ Archery** ([`ARCHERY.md`](./ARCHERY.md) §12.1): rematch, post-match summary, head-to-head, share-to-chat.

**The shareable artifact differs and is better:** Archery shares a target with ten arrows in it. **Snow Fight shares the ruined arena** — six barriers in whatever state the match left them, craters, and both players' final health. It is a picture of a fight, and it is unique to every match.

## 12.2 The specific hook

**Different from Archery, and this is the reason to build both.**

Archery's hook is *calibration you can visibly acquire* ([`ARCHERY.md`](./ARCHERY.md) §12.2) — a solo skill, measured against an opponent.

**Snow Fight's hook is reading one specific person.**

Named precisely: after four rounds you know that Priya goes Back when she is losing and Forward when she is winning, and she knows you always move after being hit. **The game becomes about a particular opponent's habits**, which is a form of depth that only exists between two people who play each other repeatedly — and it is the exact thing a messenger's contact graph is for.

It is also, structurally, the strongest possible argument for playing inside a chat app rather than against strangers. **Reading a stranger is a coin flip. Reading your friend is a skill you have been building for a month.** [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §4 makes this point about head-to-head records generally; Snow Fight is the game where the record is not just a score but *knowledge*.

Supporting:

- **The attrition arc.** Cover breaking makes the late rounds tense in a way the early ones are not (§2.2).
- **Being one hit from losing** is a state the game spends real time in, with its own audio and visual treatment (§10.2).
- **Every round has a villain.** Archery's losses are your own fault. Snow Fight's are somebody's doing.

## 12.3 How it uses the fact that this is a messenger

**→ Archery** ([`ARCHERY.md`](./ARCHERY.md) §12.3), plus:

- **The read is the trash talk.** "I knew you'd go back" is the most natural message any game in this folder generates, and it is the actual content of the game rather than a comment on it.
- **The pattern is personal.** A stats line — "Priya goes Back 60% of the time when behind" — is a thing to send, and it is also a thing that changes her behaviour once sent, which is a second-order game played in the chat rather than in the app.
- **The ruined arena image** (§12.1) as the share card.

## 12.4 What the first 30 seconds feel like

- **0–3 s.** Accept. The arena, both sides, six intact barriers, wind: `← 3`.
- **3–6 s.** A one-line hint: *"Pick where to stand, then throw."* Three ghosted positions on your side. **The hint is necessary** — the position mechanic is the one thing here that is not self-evident, and unlike Archery this game does not fully explain itself.
- **6–12 s.** Tap Centre. Drag back. The bow-equivalent wind-up, the haptic loading, the arc preview. Release.
- **12–15 s.** Both characters slide to their positions. **250 ms of stillness** (§9). You see they went Back and you threw at Centre.
- **15–18 s.** Both snowballs fly. Yours lands harmlessly in the snow exactly where they used to be. Theirs hits your barrier with a thud and a chunk falls off.
- **18–30 s.** Round 2. **You now understand the entire game**, including the part nobody told you: that you were aiming at a guess.

**That first miss is the tutorial**, and the design should make sure it happens: the opening hint should nudge toward throwing at their current position, precisely so the player experiences the lesson rather than reading it.

## 12.5 What someone with 50 matches is chasing

- **The read, per opponent.** §12.2. Nothing else comes close.
- **Head-to-head**, as everywhere.
- **A shutout — 3 health remaining.** Concrete, hard, unambiguous.
- **Hit rate**, and the split between "guessed right" and "executed well". Two separate numbers that improve independently, which is unusual and genuinely useful: a player can find out which half of the game they are bad at.
- **Position stats**, per player. Where you stand, where you throw, how often each works. The material for the metagame.

Explicitly **not**: unlocks, cosmetics, equipment (§2.8).

---

# 13. Failure and edge cases

**→ Archery** ([`ARCHERY.md`](./ARCHERY.md) §13) for disconnect, simultaneous arrival, restart, and the integrator's termination guarantees.

**What differs:**

## 13.1 The auto-throw on timeout

| Situation | Deadline | On expiry |
|---|---|---|
| Commit | **30 s** | **Auto-commit:** stay in the current position, weakest-bot throw at the opponent's current position |
| Absent (3+ autos) | — | Forfeit |
| Whole match | 5 min of no input | Abandon, `winnerId: null` |

**The auto-commit stays put rather than moving randomly.** A random move would be a decision the player did not make, in a game where position is half the strategy — and it could move them *out* of danger by luck, which is worse than leaving them where they chose to be. Staying is the honest default: it is what they last chose.

## 13.2 A match that cannot end

Both players at Back, both barriers intact, both missing. Round 12 caps it (§2.3), and health decides.

**But the cover erosion (§2.2) makes it self-solving in practice:** a Back barrier absorbing four hits is gone by round 8, and after that Back is the most exposed position on the board because it is the longest throw with no protection. **The attrition mechanic is also the anti-stall mechanic**, which is a pleasing property and worth not breaking with a cover-repair feature.

## 13.3 Both players reach 0 health in the same round

Possible — both snowballs resolve simultaneously (§2.4). **It is a draw**, `winnerId: null`, and the post-match screen must have a real draw state rather than a win screen with different text ([`TICTACTOE.md`](../TICTACTOE.md) §2.2's complaint).

Rare, dramatic, and genuinely the right outcome. It should get its own treatment: both characters knocked back at once, both health bars emptying together.

## 13.4 The restart case that would silently break the game

**→ §4.3.** `position` and `coverHealth` are the two fields whose loss produces a game that *appears* to work and is quietly not being played. Both need explicit tests: serialize → restore → serialize byte equality, and a full-match simulation asserting that a player who moves to Back is at Back when the next round resolves.

This is the concrete form of [`GameEngine.ts:62-63`](../../../backend/games/src/engine/GameEngine.ts#L62-L63)'s warning for this game, and it is worth stating that Snow Fight's version is the most insidious in the folder: nothing crashes, nothing looks wrong, and the movement mechanic simply does nothing.

---

# 14. Build plan

**Snow Fight is Archery's phase 7.** It should not be started before Archery ships, for the reason in §1.3: built alone it pays for `ballistics/`, the reveal machinery, the pull-back control and the camera; built second it inherits all of them.

## Phase 1 — extend `ballistics/`

Barrier segment intersection and player circle intersection, both swept (§4.6). Extend the golden-shot fixture with barrier-hit and player-hit cases, on all three platforms in CI.

## Phase 2 — `engine/snowfight/`, headless

Positions, cover health and erosion, health, the move-then-throw resolution order, round cap. Registry entry.

Tests: **the `position` and `coverHealth` round-trip** (§13.4) first and most carefully; the secret round-trip preserving both `moveTo` and aim (§4.4); `serialize()` never containing an un-revealed commit; cover erosion thresholds and the height reduction at each; simultaneous double-KO producing a draw.

## Phase 3 — iOS practice mode

Arena, six barriers with five damage states each, position picker, the coupled aim preview (§7.1), move resolution, the 250 ms pause, impacts, the bot at all four bands with both axes, sound, haptics, motion.

**Reuses Archery's control implementation wholesale.** The genuinely new client work is the position picker, the barrier states and the two-snowball camera.

## Phase 4 — iOS online

**→ Archery's phase 4.** Mostly wiring; the reveal machinery already exists.

## Phase 5 — Android parity

iOS is the reference; constants identical ([`SNAKE.md`](../SNAKE.md) §2.4).

## Phase 6 — retention

Post-match summary with the guessed-right / executed-well split (§12.5), rematch, head-to-head, the ruined-arena share card, position stats.

---

# 15. Open questions

1. **Build Snow Fight at all, given Archery?** Recommendation: **yes, and only after Archery.** §1.1 argues they are genuinely different games — calibration versus calibration-plus-prediction — and §1.3 argues the second costs 40% of the first. If only one ships, **ship Archery** (simpler, self-explanatory); if the pair ships, this one has the deeper hook (§12.2) and is the more cheat-resistant of the two (§5).

2. **Three positions, or more?** Recommendation: **three** (§2.1). Nine combinations is a matrix a player can hold in their head; twenty-five is guesswork.

3. **3 health, or 5?** Recommendation: **3** (§2.3). Every round must feel dangerous, and 12 rounds at 3 minutes is already at the top of what this format should ask for.

4. **Does cover repair?** Recommendation: **no** (§2.2). The erosion is the match's arc and also its anti-stall mechanism (§13.2). Repair would remove both.

5. **Is the position mechanic discoverable without a hint?** (§12.4) Honest answer: **no** — unlike Archery, this game does not fully explain itself, and the one-line hint is required rather than optional. Worth deciding whether that is acceptable or whether the mechanic should be simplified.

6. **Wind bed or heartbeat on the single `loopVoice`?** (§10.2) Recommendation: **cross-fade, wind ducking under the heartbeat at 1 health.** `GameAudio` has one dedicated loop voice outside the round-robin pool and adding a second for this game is not worth it. Decided here rather than discovered as a bug.

7. **Do bot matches count?** Cross-cutting (O10). Recommendation: no.

8. **Reduce-motion.** §9 specifies knockback, screen shake, falling debris and collapse. The switch does not exist ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13). The reduced version must still show **which barrier took damage and how much** — the damage state is game information, not decoration, so the barrier must still change shape even if nothing falls.
