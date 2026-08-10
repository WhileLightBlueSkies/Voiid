# Archery

> **Status:** design only, nothing built.
> **Kind:** event-driven, 2 players, simultaneous reveal. **No tick loop.**
> **Blocked on:** the deadline sweeper ([`README.md`](./README.md) §2.3). Nothing else.
> **Reference implementation to read first:** [`cricket/index.ts`](../../../backend/games/src/engine/cricket/index.ts) — Archery is structurally hand cricket with a trajectory solver in place of a comparison, and its `serializeSecret` reasoning applies here verbatim.
> **Companion:** [`SNOW_FIGHT.md`](./SNOW_FIGHT.md) shares this engine shape. Read this one first; that one states only its differences.

---

# 1. What the game is

Both archers draw. Both loose. Both find out together.

Five rounds. Each round has a wind, announced before the draw. You set an angle and a draw weight, release, and your arrow flies. So does theirs, at the same moment, and the two arrows land together on the same target. Closer to the centre wins the round.

## 1.1 Why it belongs in Voiid

**It is RPS's dramatic beat with a skill ceiling.**

[`RPS.md`](../RPS.md) §2.3 identifies the shape: the game is one moment — both commit, both reveal, both find out simultaneously. That structure is genuinely good and it is why RPS survives as a game at all. Its problem is that there is nothing to be good at ([`RpsBot.swift:7-9`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L7-L9): *"against a truly random opponent, RPS has no skill — every strategy wins exactly a third of the time"*).

Archery keeps the beat and adds a skill: a continuous aim against a wind you can read. **Every round is an RPS reveal where the reveal is earned.**

Three supporting properties:

- **Fast.** A round is 15 seconds. A match is 90.
- **Symmetric.** Both players face the same wind on the same target. There is no first-mover advantage to compensate for and no turn order to argue about.
- **Legible.** Two arrows in a target is a complete explanation of what happened. Nobody has to be told who won.

## 1.2 Cost

**The lowest engineering cost in this folder after Sea Battle**, and lower on the server: no tick loop, no physics stepping, no netcode, ~250 lines of engine. The trajectory is a closed-form-ish integration run once per shot, server-side, in microseconds.

The renderer is a side-on scene with a bow, an arrow, an arc and a target. Real animation work (§9) but no sustained frame budget — the arrow flies for 1.4 seconds and then everything is still.

**Archery and Snow Fight together are cheaper than either Ludo or Voiid Cards alone**, because the second one reuses the first one's engine shape, its input model, its secret handling and most of its renderer.

---

# 2. Rules as implemented

## 2.1 The match

- **5 rounds**, best score wins. Not first-to-3 — five rounds of the same length means both players always get five shots, which matters when the wind varies (§2.3): a shortened match could end on a round where one player got an easier wind.
- **Match option:** 3, 5 or 7 rounds. Default 5.
- **Tie after 5 rounds → one sudden-death round** at maximum wind. If still tied, a genuine draw (`winnerId: null`).

## 2.2 The target and scoring

Standard 10-ring target, 40 units wide, at 300 units range.

| Ring | Radius (units) | Score |
|---|---|---|
| 10 (gold centre) | 2 | 10 |
| 9 | 4 | 9 |
| 8 | 6 | 8 |
| … | +2 each | … |
| 1 | 20 | 1 |
| Miss | > 20 | 0 |

**Round scoring:** higher ring wins the round, 1 point. **Equal rings: no point to either.** Not a shared point and not a tiebreak on exact distance — a tie should feel like a tie, and resolving it on a sub-ring distance the player cannot see would be a decision made by a number nobody was shown.

**Match score is rounds won.** Total ring score is displayed as a secondary stat and is the tiebreak for a leaderboard entry, never for a round.

`GameOutcome.scores` is **rounds won**. Higher is better.

## 2.3 Wind

The variable that makes the game a skill.

- **One wind per round**, drawn from the match RNG, **announced before the draw** as a direction and strength: `← 6` or `→ 2`.
- Range: **−12 to +12 units/s** lateral, quantised to integers so the readout is exact.
- Constant during flight. **Not gusting.**

**Announced before, not revealed after.** This is the central design decision and it is what separates the game from a lottery. A hidden wind would make the shot a guess; an announced wind makes it a calculation you can get right or wrong, which is the only thing in the game worth being good at.

**Constant, not gusting**, for the same reason. A gusting wind adds variance without adding a decision — [`GAMES_HAND_CRICKET.md`](../../GAMES_HAND_CRICKET.md) §2 rejects a powerplay on exactly this ground, that it "multiplies variance without adding a decision." A player who compensated correctly and lost to a gust learns nothing.

**The wind is the same for both players in a round.** Symmetry (§1.1).

## 2.4 The shot

Two continuous values:

| Value | Range | Effect |
|---|---|---|
| **Angle** | −5° to +45° from horizontal | Launch elevation |
| **Power** | 0.30 to 1.00 | Draw weight → initial speed, 90 to 300 units/s |

**Both are continuous**, not snapped. The skill is in fine control, and quantising the input would put a ceiling on precision that the target's 2-unit gold ring would then punish arbitrarily.

**Aim is hidden until both players have committed** (§4.4). Your opponent sees that you are drawing, and for how long, and nothing else.

## 2.5 The flight

Server-computed, deterministic, and the same solver on client and server (§4.6).

```
ax = wind × drag
ay = −gravity
```

| Constant | Value |
|---|---|
| Gravity | 90 units/s² |
| Drag coefficient | 0.02 /s (linear, on velocity relative to air) |
| Wind effect | Applied as a lateral acceleration proportional to drag |
| Integration | Fixed step, **1/240 s**, until the arrow crosses the target plane |
| Typical flight | 1.1–1.6 s |

**Linear drag, not quadratic.** Quadratic is more physical and makes the relationship between draw weight and range non-obvious in a way that is not fun to learn — a player should be able to build an intuition in five shots. Linear drag keeps the mapping learnable while still making a weak shot drop.

**Fixed 1/240 s step, and the reasoning is [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §4.6's**: the solver must produce the same answer regardless of when or how often it is called. Here it is easier — the whole flight is integrated in one synchronous call, so there is no accumulator to carry and no `serialize()` field for it. **The flight is computed once, atomically, and its result is stored.**

## 2.6 What is deliberately excluded

| Feature | Excluded because |
|---|---|
| **Gusting / changing wind** | §2.3 — variance without a decision |
| **Moving targets** | Turns a precision game into a timing game and breaks the simultaneous-reveal structure |
| **Equipment upgrades** | A progression system that changes the physics makes two players' shots incomparable, which destroys the symmetry that makes the reveal fair |
| **Distance variation between rounds** | Considered and rejected — it doubles the tuning surface and the wind already provides round-to-round variety |
| **Aim assist** | A skill game with assist is two games sharing a leaderboard |

---

# 3. Network model — R2

## 3.1 Pattern

Third row of [`GAMES.md`](../../GAMES.md) §4:

> *"Archery, Snow Fight — Event-driven (send a 'shot fired' with angle/power, server resolves trajectory and broadcasts result) rather than continuous streaming. These are aim-and-release actions, not continuous motion — no need to stream every frame of a bow draw."*

Adopted exactly. **The bow draw is not networked.** A player pulls back over two seconds and none of it leaves the phone until they release; what travels is one frame with two numbers in it.

That is the whole design and it has a consequence worth naming: **Archery has no netcode.** No tick loop, no jitter buffer, no interpolation, no prediction, no render clock. **The [`SNAKE.md`](../SNAKE.md) §2 stutter class is structurally impossible** — there is no continuously advancing clock, and the one animated thing in the game (the arrow) is animated from a *result the client already holds in full* rather than from a stream of positions.

That last point is the elegant part: the server sends the complete trajectory, or the parameters to reproduce it, and the client animates it locally at 60 fps. **The arrow's flight is perfectly smooth on any network**, because it is not being streamed.

## 3.2 Rate and payload

Turn-based default, 60 inputs/minute ([`index.ts:29`](../../../backend/games/src/index.ts#L29), via [`limitFor`](../../../backend/games/src/index.ts#L45-L48)). A round is one input per player. A whole match is 10 inputs.

State is ~350 bytes including the round history. Two broadcasts per round.

**This is the cheapest game in the app to run**, and by a wide margin: no loop, no per-tick broadcast, ten inputs per match.

## 3.3 The simultaneous reveal

The structure Archery inherits from RPS and hand cricket:

```
both players commit (hidden)  →  server resolves both flights  →  ONE broadcast with both results
```

- A shot arrives, is validated, and is **stored in the secret** (§4.4). The public state says only that this player has shot.
- When the second shot arrives, the server integrates **both** trajectories and broadcasts **one frame containing both**.
- Both clients animate both arrows simultaneously.

**One broadcast, not two.** If the first shot were broadcast on arrival, the second player would see the first arrow land before committing — which is complete information about the wind's real effect, and it would make going second a decisive advantage. The whole game rests on this not happening, exactly as hand cricket's rests on `pending` never entering `serialize()` ([`cricket/index.ts:13-16`](../../../backend/games/src/engine/cricket/index.ts#L13-L16)).

## 3.4 What a player sees while waiting

The one design problem the event-driven model creates: after you release, you wait for someone you cannot see.

- **A "drawing" indicator** on the opponent's side, animated — their archer visibly draws the bow, and the draw deepens over time. It carries no aim information (§4.3) and it makes the wait feel occupied.
- **Your own arrow is nocked and held**, not fired. The release is deferred to the reveal, so both arrows leave together and the moment is shared.
- **If you shot first**, a small "waiting for Priya" line after 2 seconds.
- **The turn deadline** (§13.2) is visible from 8 seconds remaining.

**Your arrow does not fly on your own screen when you release.** This is worth stating because it is counter-intuitive and it is right: firing locally and then re-firing at the reveal would show the shot twice, and holding the release is what makes the simultaneous landing the event it should be.

## 3.5 What happens on a 3-second network stall

- **Before you commit:** nothing. Static screen, and the clock you are on is 30 seconds.
- **You committed during the stall:** the bow releases into the held state with a spinner after 800 ms. When the frame arrives, both arrows fly. **A stall is invisible if the opponent had not yet shot** — which is most of the time.
- **Your opponent shot and you did not:** you were the one being waited for, and the deadline may have expired (§13.2).
- **Socket down:** the "Reconnecting…" state ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §7).
- **On reconnect:** a full frame. If a round resolved while you were away, the client **skips the flight animation and shows the result** — replaying a 1.4-second flight for a round that finished two minutes ago is worse than a summary.

## 3.6 Is it async?

**Technically yes, practically no.** A round is one commit from each player, so 24-hour deadlines would work mechanically.

But the simultaneous reveal is the game (§1.1), and a reveal you experience alone eight hours after your opponent committed is not a reveal — it is a notification. **Archery is designed live**, 30-second commits, ~90 seconds a match.

The deadline sweeper is still required, for AFK handling (§13.2), not for async play.

---

# 4. Engine design — R1

Folder: `backend/games/src/engine/archery/`, with the trajectory solver in a shared `engine/ballistics/` that [`SNOW_FIGHT.md`](./SNOW_FIGHT.md) reuses.

## 4.1 Interface surface

| Method | Present | Why |
|---|---|---|
| `applyInput` | yes | One frame: the shot |
| `tick` | **no** | Nothing advances on its own. **The flight is resolved synchronously inside `applyInput`** |
| `serialize` | yes | Public state |
| `serializeForWire` | **no** | ~350 bytes, everything matters |
| `serializeForPlayer` | **no** | Nothing is hidden *between* players once revealed, and what is hidden is hidden from both |
| `serializeSecret` | **yes** | The committed shot before reveal. **The game's one secret** |
| `deadlineAt` / `onTimeout` | **yes** | 30 s commit deadline, §13.2 |
| `isFinished` | yes | — |

**No `serializeForPlayer`, and this is worth contrasting with Sea Battle.** There, each player has private state *of their own* that they must be shown. Here, the hidden state is hidden from **both** players — your own committed aim is not shown back to you either, because there is nothing to show: you already know what you aimed at, and re-displaying it would be the client telling itself something it told the server.

So the split is `serialize()` (public, both) + `serializeSecret()` (server-only, neither). The exact shape hand cricket uses.

## 4.2 `applyInput`

```ts
{ shoot: { angle: number, power: number } }   // radians, 0..1
```

One frame shape for the whole game.

Validation:

1. Not finished; `phase === 'aiming'`
2. `angle` finite, clamped to [−5°, +45°]
3. `power` finite, clamped to [0.30, 1.00]
4. **This seat has not already shot this round** — re-shooting would let a player change their mind after the opponent commits, which is the same information leak as seeing their choice. Exactly [`cricket/index.ts:95-97`](../../../backend/games/src/engine/cricket/index.ts#L95-L97): *"One pick per ball. Re-picking would let a player change their mind after the opponent commits."*

**Out-of-range values are clamped and accepted, not rejected**, following [`snake/index.ts:275-279`](../../../backend/games/src/engine/snake/index.ts#L275-L279)'s reasoning: a value arriving slightly out of range is a client bug or a rounding artefact, not an attempt to cheat, and rejecting it would leave the player unable to shoot at all. Clamping is safer and kinder — and here the clamp is also the anti-cheat (§5).

Returns `{ accepted: true }` when the round is still open, and `{ accepted: true, outcome? }` when the second shot resolves the round.

**Never `silent: true`.** The first shot changes the public state (`hasShot` flips) and the opponent should see it immediately — that is what drives the "drawing" indicator (§3.4).

## 4.3 `serialize()` — field by field

```ts
{
  players: string[],
  round: number,             // 1-based
  totalRounds: number,
  wind: number,              // units/s, signed. Current round
  windHistory: number[],
  roundsWon: [number, number],
  ringTotal: [number, number],
  hasShot: [boolean, boolean],
  phase: 'aiming' | 'revealing' | 'done',
  lastResult: {
    shots: [Shot, Shot],     // angle, power, impact x/y, ring — BOTH, after reveal
    winner: 0 | 1 | null,
  } | null,
  history: RoundLog[],
  moveCount: number,
  deadlineAt: number | null,
  finished: boolean,
  winnerUserId: string | null,
}
```

Why each must survive a restart — which happens **on every input** ([`index.ts:279`](../../../backend/games/src/index.ts#L279)):

- **`players`** — seat order. Lose it and no shot maps to a seat.
- **`round` / `totalRounds`** — where we are. Lose `round` and the match restarts from 1 at every restore, and it never ends.
- **`wind`** — the current round's wind. **The field a naive design loses, and it is decisive.** Drawing it lazily from the RNG at resolve time rather than at round start means the wind changes between announcement and resolution — the player aims for `← 6` and is scored against `→ 3`. Because the round-trip happens on every input, the wind would be redrawn between the two players' shots, so **the two archers would be shot in different winds.** The wind is drawn once, at round start, and serialized.
- **`windHistory`** — every round's wind, for the summary and for the "you always lose in a left wind" stat.
- **`roundsWon` / `ringTotal`** — the score. The one field a player would report losing.
- **`hasShot`** — **booleans, never the shots themselves.** This is the line the game's anti-cheat rests on, exactly as [`cricket/index.ts:194-196`](../../../backend/games/src/engine/cricket/index.ts#L194-L196) says of its own: *"CRITICAL: booleans, never the picks themselves. The whole anti-cheat property of this game rests on this line not leaking `pending`."*
- **`phase`** — `aiming` while shots are open, `revealing` during the animation window. Lose it and a client could commit a shot for a round that has already resolved.
- **`lastResult`** — both shots in full, **only after the reveal**. Safe to send: the round is resolved, and this is what the client animates. Same posture as cricket's `history`, which is "safe to send in full — every ball in it is already resolved" ([`cricket/index.ts:197-198`](../../../backend/games/src/engine/cricket/index.ts#L197-L198)).
- **`history`** — per round: both shots, both rings, the wind, the winner. The post-match summary and the commentary strip. [`CRICKET.md`](../CRICKET.md) §2.3 notes cricket's equivalent is "serialized and largely unused"; do not repeat that — this is the data the summary is made of.
- **`moveCount`** — monotonic; the idempotency key for deadline frames (§13.2).
- **`deadlineAt`** — absolute epoch ms, serialized rather than recomputed, or an AFK player gets a fresh 30 seconds at every restore and the timer never fires.
- **`finished` / `winnerUserId`** — terminal, recovered from the user id on restore per [`cricket/index.ts:276-278`](../../../backend/games/src/engine/cricket/index.ts#L276-L278).

**Absent, deliberately: the committed shots before reveal, and the RNG state.**

## 4.4 `serializeSecret()` — aim before release

```ts
serializeSecret(): GameStatePayload {
  return {
    pending: this.s.pending,   // [Shot | null, Shot | null]
    rng: this.rng.seed,
  };
}
```

**Two secrets, for two different reasons.**

**`pending` — the committed aim.** [`GameEngine.ts:83-96`](../../../backend/games/src/engine/GameEngine.ts#L83-L96) documents exactly this case and the bug it caused: a secret omitted from `serialize()` was *"silently dropped a millisecond after being made: the ball could never resolve, and hand cricket looped between the two players forever."*

Archery's failure would be identical in shape: the first archer shoots, the state round-trips, the shot is gone, `hasShot` resets, and the round never resolves. Two players shooting at each other forever.

**And it must not be in `serialize()`**, because a client that could see the opponent's committed angle and power before committing its own would know the exact result before shooting. That is not an edge — it is the entire game.

**`rng` — the wind sequence.** Less obvious and equally necessary. `Rng` is mulberry32 ([`geometry.ts:113-131`](../../../backend/games/src/engine/snake/geometry.ts#L113-L131)) and its state *is* its seed, so a client holding it can compute every future round's wind.

Knowing next round's wind is not fatal the way knowing the opponent's aim is — you cannot use it this round — but it is real: it lets a player plan a five-round strategy against a wind sequence the opponent is discovering one round at a time. Under [`README.md`](./README.md) §1.3's rule — *the seed goes in the secret whenever a future draw is information a player would pay for* — it belongs in the secret, and Archery is listed there among the games that carry it.

**A restore without the secret:** re-open the round. Both `pending` slots become `null`, both players re-shoot. That costs one replayed shot and leaks nothing — the same trade cricket makes ([`cricket/index.ts:267-272`](../../../backend/games/src/engine/cricket/index.ts#L267-L272)) for the same reason. The RNG reseeds, which changes future winds; log it, because a reseeded match is one whose wind sequence silently restarted.

**`restore` rebuilds field by field, never by casting** — the mistake [`cricket/index.ts:254-257`](../../../backend/games/src/engine/cricket/index.ts#L254-L257) documents, where a blanket cast produced an engine "whose pending is undefined, and the very next serialize() throws — taking the games service down with any match that outlived a process restart."

## 4.5 RNG and determinism

`Rng` (mulberry32) from [`geometry.ts:113`](../../../backend/games/src/engine/snake/geometry.ts#L113), promoted to `engine/rng.ts`.

**Exactly one draw per match round: the wind.** Drawn at round start, immediately serialized (§4.3), never redrawn.

**No randomness in the flight.** No spread, no wobble, no "arrow imperfection". A shot is a pure function of `(angle, power, wind)`, which means:

- The same shot in the same wind always lands in the same place. **A player can learn the game.**
- The client can show the true result the instant it has the parameters (§4.6).
- A disputed round is reproducible from `history`.

Adding a random spread would be the single most damaging change available: it converts a precision game into a lottery and makes the difficulty scale dishonest, because a bot's "error" and the game's own noise become indistinguishable.

**Not `Math.random()`** — [`geometry.ts:105-111`](../../../backend/games/src/engine/snake/geometry.ts#L105-L111): the engine is rebuilt on every input, so global randomness "would produce a different world each time it was restored."

## 4.6 Tick-rate independence

**No `tick()`, and the flight is not ticked either** — it is integrated to completion inside `applyInput`, synchronously, at a fixed 1/240 s step (§2.5).

This is the strongest form of the R1 requirement available to any game in this folder: **the simulation's result cannot depend on tick timing, because there is no tick.** A flight computed on a loaded server and a flight computed on an idle one are bit-identical.

The only time-dependent value is `deadlineAt`, an **absolute epoch timestamp** rather than a countdown, correct whenever read.

**The client runs the same solver**, ported to Swift and Kotlin, so it can animate the arrow at 60 fps from the parameters rather than from a stream of positions (§3.1). The ports must agree with the server's, and the discipline is the one [`VOIID_RUN.md`](./VOIID_RUN.md) §4.4 sets out: `Double` everywhere, never `Float`; the same fixed step; and **a golden-shot fixture** — a fixed `(angle, power, wind)` with the expected impact point checked into the repo and asserted in CI on all three platforms.

If they drift, the arrow lands somewhere other than where the score says. That is a bug players will notice immediately and be unable to describe.

**The alternative is to send the impact point and let the client fake the arc.** Cheaper, and rejected: a faked arc that ends at the right place still curves wrongly against the announced wind, and reading the wind's effect on the arc is how a player learns to compensate. The arc *is* the feedback.

---

# 5. Anti-cheat

**An Archery client can express exactly one thing: an angle and a power.**

Both are clamped (§4.2), so **there is no invalid shot** — only shots at the edge of the legal range. This is the [`snake/index.ts:8-13`](../../../backend/games/src/engine/snake/index.ts#L8-L13) property in its purest form: *"the two lies a modified client can tell... neither is a lie worth telling."*

| Attempt | Defence |
|---|---|
| **See the opponent's aim before committing** | `pending` is in `serializeSecret` and never broadcast (§4.4). `serialize()` sends `hasShot` booleans only |
| **Predict the wind** | RNG state in the secret (§4.4) |
| Claim an impact point | No input frame expresses it. The flight is server-computed |
| Claim a ring score | Server-computed from the impact point |
| Shoot twice in a round | `pending[seat] !== null` check (§4.2) |
| Shoot out of phase | `phase` check |
| Angle or power out of range | Clamped, not rejected |
| Skip a deadline | Server state in a Redis sorted set |
| Flood inputs | 60/min, silent drop ([`index.ts:29-61`](../../../backend/games/src/index.ts#L29-L61)) |
| Input into another match | Membership checked ([`index.ts:262-264`](../../../backend/games/src/index.ts#L262-L264)) |

## 5.1 The one real attack: a perfect-aim client

**A modified client can solve for the exact angle and power that hits the gold ring in the announced wind.** The wind is public, the physics are deterministic (§4.5) and the solver is on the client anyway (§4.6). Inverting it is a few lines of bisection.

**This is undefeatable in this design**, and it is worth being blunt about rather than implying otherwise. The shot is legal; only the aiming was automated.

What bounds it is the same thing that bounds an Air Hockey aimbot ([`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §5.3) and a Voiid Run bot ([`VOIID_RUN.md`](./VOIID_RUN.md) §5.2): matches are invite-only between people who already talk ([`GAMES.md`](../../GAMES.md) §3), there is no ranked ladder, no matchmaking with strangers and no prize.

**But there is one thing that makes it worse here than elsewhere, and it should be understood:** a perfect archer is *visibly* perfect. Ten golds in a row is a result nobody produces, so unlike an aimbot it is self-announcing. That is not detection, but it is the social equivalent, and in a game played against a friend it is enough.

**What would change the calculus:** a global leaderboard of ring scores would be trivially farmed and should not exist. Head-to-head only, or a leaderboard that is friends-scoped and understood as such.

---

# 6. Client rendering

## 6.1 What it reuses

| Piece | Source | Notes |
|---|---|---|
| Simultaneous-reveal screen structure | [`RpsMatchView.swift`](../../../apps/ios/Voiid/Voiid/Games/RpsMatchView.swift) / [`RpsMatchScreen.kt`](../../../apps/android/app/src/main/java/com/voiid/app/main/games/RpsMatchScreen.kt) | Commit → wait → reveal. Same shape, same states |
| Round-based scoring HUD | [`CricketMatchView.swift`](../../../apps/ios/Voiid/Voiid/Games/CricketMatchView.swift) | Round counter, running score, history strip |
| `GamesEngine` | existing | Unchanged |
| `GameAudio` / `GameHaptics` | [`GameAudio.swift`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift) | One new `soundNames(for:)` entry |
| Lobby | [`GameLobbyView.swift`](../../../apps/ios/Voiid/Voiid/Games/GameLobbyView.swift) | Unchanged, 2 seats |
| Ballistics solver | **New, shared with Snow Fight** | §4.6 |

## 6.2 What it adds

**iOS:** SwiftUI `Canvas` for the scene — ground, target, two archers, arrows, arc — inside `TimelineView(.animation)` during the flight only, and static otherwise. **Not Metal.** The scene is ~20 primitives, animated for 1.4 seconds at a time.

**Android:** Compose `Canvas` + `withFrameNanos`, mirroring iOS.

**Key rendering property: the client animates from parameters, not from a stream** (§3.1). On receiving the reveal frame it holds `(angle, power, wind)` for both shots and integrates them locally at display rate. **The flight is perfectly smooth on any network**, which is a genuinely nice property and a direct consequence of the event-driven model.

## 6.3 The camera

Three states, and this is the main rendering design decision:

| Phase | Camera |
|---|---|
| **Aiming** | Wide-ish on the archer, target visible small at the right edge. You must be able to see what you are aiming at |
| **Flight** | **Tracks the arrow**, easing from the archer to the target over the flight duration, zooming in over the last 30% |
| **Impact** | Tight on the target, both arrows visible |

**The camera must not be a spring.** Snake's camera spring exists because Snake's focus point moves unpredictably; here the arrow's whole path is known before the animation starts, so the camera is a **precomputed keyframed path** — smooth by construction, and immune to the class of jitter [`SNAKE.md`](../SNAKE.md) §2 documents.

---

# 7. Controls

## 7.1 The scheme: pull back and release

**Touch anywhere and drag away from the target. Release to loose.**

- **Drag distance → power**, from a 40 pt dead zone up to 220 pt for full draw.
- **Drag angle → launch angle**, inverted: pulling down-and-back raises the shot, exactly like drawing a real bow.
- **Release fires.** Dragging back into the dead zone and releasing **cancels** — a committed shot is irreversible, so an escape hatch is mandatory.

The idiom everyone already knows from a decade of physics games. Direct, one-handed, no on-screen controls, and it maps physically onto what an archer does.

## 7.2 The precision problem, and the answer

A 2-unit gold ring at 300 units means the useful angle range is **fractions of a degree**. A 220 pt drag mapped linearly across 50° gives ~0.23° per point — so one pixel of finger jitter is most of the gold ring.

**This would make the game a lottery**, so the input is non-linear:

- **Coarse near the origin, fine at full draw.** The angle mapping's derivative falls as drag distance grows: at 60 pt of drag, 1 pt ≈ 0.4°; at 200 pt, 1 pt ≈ 0.08°. A player pulls further back both to add power *and* to gain precision, which is a satisfying coupling and happens to be physically suggestive.
- **A fine-adjust arc** appears once the drag exceeds 120 pt: a small arc near the thumb where lateral movement adjusts angle at **0.02° per point**, roughly a tenth of the main sensitivity. This is where a good shot is actually made.
- **Haptic detents every 0.5°**, so the player can feel the adjustment without watching the number.
- **A numeric readout** — `24.3° · 78%` — always visible. Precision games need exact feedback; the readout is what lets a player repeat a shot that worked, which is the core learning loop.

## 7.3 The aim preview — a deliberate limit

**The first 25% of the trajectory is drawn as a faint arc. No further.**

A full trajectory preview would remove the entire game — the player would drag until the arc hits the gold and release, and there would be no skill left. No preview at all makes the first three shots pure guesswork and loses players before they learn.

25% shows launch direction and initial speed, which is what a real archer perceives, and leaves the wind and the drop to be judged. **This is the single most important tuning number in the game** and it should be playtested: too little and the game is opaque, too much and it is solved.

## 7.4 One-handed and small screens

- **Drag from anywhere.** No fixed control surface, so no reachability problem.
- The fine-adjust arc appears **relative to the thumb**, wherever it is.
- The readout renders **above** the touch point with a 70 pt offset, so the finger never covers it.
- The target is drawn at a minimum on-screen size regardless of screen width, so a small phone is not aiming at a smaller target. **A large screen must not confer more precision** — the input mapping is in points, and the point-to-degree curve is identical on every device.

---

# 8. Visual design

## 8.1 Art direction

**Side-on, clean, high contrast, minimal.** The scene has one job: make the arc readable.

- **Silhouettes on a graded sky.** Archers, ground and target as flat shapes; the arrow and its arc are the only bright elements.
- **The wind is visible in the world**, not only in the readout: a pennant on the target, drifting particles, grass leaning. A player should be able to feel the wind's direction without reading the number — and the number is there for the exact value.
- **The arc trail** persists for ~600 ms after impact, fading. **Persistent ghost trails from previous rounds**, very faint, are the game's real teaching tool: five rounds in, a player can see their own scatter and how the wind bent each shot.
- **The target grows** as the camera closes (§6.3), so the rings are readable at impact.

## 8.2 What the player must see

1. **The wind**, direction and strength, unmissably, before drawing.
2. **The round number** and the running score.
3. **Angle and power** as numbers while drawing (§7.2).
4. **The 25% arc preview** (§7.3).
5. **The previous round's result**, briefly — both arrows and both rings.
6. **The opponent's draw state** (§3.4).
7. **The commit deadline** from 8 s.

## 8.3 Accessibility

- **Ring scores are printed on the target**, not conveyed by ring colour alone ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13).
- **The two players' arrows differ in shape**, not only colour — different fletching silhouettes, visible at impact scale.
- **Wind direction is an arrow glyph plus a number**, never colour.
- **Reduce-motion:** the camera cut goes straight to the target, the arrow appears at its impact point, no shake. **The score is unaffected**, which is the test — motion here is presentation, never information.

---

# 9. Motion and feel

Behind reduce-motion ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13, open question O13).

| Moment | Motion | Duration | Curve |
|---|---|---|---|
| Round starts | Wind readout slides in, pennant animates to the new direction | 400 ms | `easeOut` |
| Draw begins | Bow flexes with drag; string tension visible; archer leans | Tracks input | None — 1:1 |
| Full draw | Bow trembles slightly, ~1.5 px at 8 Hz | Continuous | Sine |
| Fine-adjust engages | Arc widget fades in near the thumb | 180 ms | `easeOut` |
| **Release (local)** | Bow snaps forward, arrow **held nocked** (§3.4) | 120 ms | `spring(0.14, 0.5)` |
| **Reveal** | Both arrows release on the same frame | — | — |
| **Flight** | Arrow travels the integrated path, rotating to its velocity vector; camera keyframed | 1.1–1.6 s | Physics |
| Arrow trail | Fades over 600 ms behind the arrow | 600 ms | Linear |
| **Impact** | Arrow buries with a 3-frame shake on the shaft, target ripples outward | 160 ms shaft, 400 ms ripple | shaft `spring(0.1, 0.4)`, ripple `easeOut` |
| Gold (10) | Ring flashes, small burst, camera punches in 6% | 500 ms | `easeOut` |
| Ring scores appear | Both numbers scale-pop, 120 ms apart, **winner second** | 260 ms each | `spring(0.2, 0.6)` |
| Round won | Winner's score pips advance | 300 ms | `spring(0.24, 0.65)` |
| Match end | Camera pulls back, both archers, result card | 800 ms | `easeOut` |

Two notes.

**Both arrows fly on the same frame, and land within a few frames of each other.** This is the moment the game is built around (§1.1) and it must not be staggered for legibility. If the two arrows land 300 ms apart because their flight times differ, that difference is *real* — a weaker shot takes longer — and it is information, not a defect. Do not normalise it.

**The winner's ring score appears second, 120 ms after the loser's.** The same delayed-reaction trick as cricket's crowd landing 120 ms behind the wicket ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.1): *"a real crowd reacts after the event — simultaneous playback reads as one mushy noise."* Two numbers appearing together is a data update; one and then the other is a result.

---

# 10. Sound

Inherits [`SOUND_DESIGN.md`](../SOUND_DESIGN.md). New `soundNames(for:)` entry ([`GameAudio.swift:282`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L282)).

## 10.1 The shared catch sound

> **The catch moment in Archery is: you lose the round — their arrow beat yours.**

Per [`README.md`](./README.md) §1.5, and it maps cleanly onto [`RPS.md`](../RPS.md)'s use: RPS plays `catch` on a round loss because "your throw is countered" ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.4). Archery is the same beat — your shot was beaten by theirs.

**On the round loss, not on a bad shot.** A 3-ring shot that still wins the round is not a catch. The sound means *the opponent beat you*, which is exactly why it is shared across games.

Played **unmodified**, layered: `catch.wav` **+** the muted thud of your own arrow. Timed to the **losing** ring score's appearance, which is 120 ms *before* the winner's (§9) — so the sound lands on the moment the player realises, not on the moment the game finishes telling them.

**Not on a tied round.** A tie is nobody being beaten.

## 10.2 The palette

**Physical, recorded.** Archery has crisp, specific referents.

| Event | Sound | Notes |
|---|---|---|
| Nock | `nock.wav` | Arrow onto the string, ~80 ms |
| Draw | `draw_creak.wav` | Bow flexing, **gain and pitch rising with draw weight**. Loops while held |
| Full draw | `draw_strain.wav` | A held tension bed, very quiet |
| Fine-adjust detent | `tick` (existing UI) | Extremely quiet. Fires often |
| **Release** | `bow_release_1..3.wav` | The string snap. ~180 ms. The most satisfying sound in the game — **3 variants** even though it fires only 5 times a match, because it is the one everyone will remember |
| Flight | `arrow_whoosh.wav` | Doppler, quiet, tracking the arrow's screen position |
| **Impact — target** | `arrow_thud_1..3.wav` | Straw and wood, ~300 ms |
| **Impact — gold** | `arrow_thud` + `gold_chime.wav` | Bright, brief. The reward |
| **Impact — miss** | `arrow_miss.wav` | Into the ground. Dull, deliberately deflating, like cricket's dot ball |
| **Round loss** | **`catch.wav`** + your own thud | §10.1 |
| Round win | `round_win.wav` | Bright confirm |
| Round tie | Flat, neutral, deliberately unsatisfying | Reuse RPS's tie sound |
| Wind change | `wind_gust.wav` | On the round-start readout. Pitched by strength |
| Match end | Existing stingers | — |

**A wind ambience bed** on `loopVoice` (the path built for Snake's `boost_loop`), gain tracking wind strength. **This is the one game where a bed genuinely earns its cost**: the wind is the game's central variable and hearing it get stronger is the most direct possible communication of that. Cap at 20 s, AAC mono 64 kbps ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §7), released on match exit via `release(for:)`.

**Mono, always** ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §6.6 — a stereo asset is a hard AVAudioEngine crash).

## 10.3 Haptics

The best haptic game in the folder, because the whole input is a sustained physical gesture.

| Event | Pattern |
|---|---|
| **Draw** | **Continuous, intensity rising with draw weight.** The player *feels* the bow load up. This is the single best haptic in the app and it is nearly free — a sustained CHHapticEvent with a ramped parameter |
| Full draw | Intensity plateaus with a subtle 8 Hz tremble |
| Fine-adjust detent | Very light tick every 0.5° |
| **Release** | Sharp transient, the loading buzz cutting instantly to silence. The contrast *is* the release |
| Impact | Medium transient, intensity by ring — a gold is felt harder |
| Round loss | The existing `death()` shape ([`GameHaptics.swift:89`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameHaptics.swift#L89)) |

---

# 11. Bots

Client-side, like every other bot in the app.

## 11.1 What difficulty varies

**Aim error, wind compensation, and consistency. Never the physics.**

A bot whose arrow flies differently is a cheat and it is undetectable, which makes it the tempting shortcut. It must be stated in the code, exactly as [`RpsBot.swift`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift) states its own honesty.

The bot computes the **perfect shot** by inverting the solver — the same inversion a cheating client would do (§5.1) — and then **degrades it deliberately**:

| Band | Angle error (σ) | Power error (σ) | Wind compensation | Expected ring |
|---|---|---|---|---|
| 0.0–0.25 | 3.0° | 12% | **None** — aims as if still | ~2.5 |
| 0.25–0.5 | 1.4° | 6% | 40% of true | ~5.0 |
| 0.5–0.75 | 0.7° | 3% | 80% of true | ~7.2 |
| 0.75–1.0 | **0.35°** | 1.5% | 100% | **~9.1** |

**Gaussian error, not uniform**, because that is how human aim actually distributes: most shots near the intention, a few well off. Uniform error produces a bot that is evenly mediocre, which reads as a machine.

**Partial wind compensation is the most human axis** and it is the one that makes the scale meaningful rather than cosmetic. A weak bot does not merely shoot inaccurately — it shoots *accurately at the wrong place*, consistently drifting downwind, which is exactly the mistake a new player makes. A player watching a weak bot can see *why* it is losing, and that is instructive.

## 11.2 What the top of the scale can and cannot do

In the register [`RpsBot.swift:17-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L17-L21) sets:

> **The top bot averages about 9.1 and will beat most players most of the time. It is deliberately not perfect, and it could trivially be made perfect — 10 every round, forever — which is why the 0.35° error exists.**

**It can:** compensate fully for any wind, hit the gold roughly 40% of the time, and win a 5-round match against a good player more often than not.

**It cannot:** be beaten by luck alone over five rounds, and it cannot be relied on to miss.

**It is deliberately beatable**, and the mechanism is worth naming: `0.35°` of angle error at 300 units is roughly 1.8 units of lateral scatter — a little under one ring. So the top bot's shots land in the 8–10 band, and a player who hits three golds in five rounds beats it. **That is a real, achievable target**, which is what a difficulty ceiling should be.

**Why a perfect bot is refused.** The reason is stronger here than in RPS. In RPS perfection is impossible ([`RpsBot.swift:19-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L19-L21): "still cannot beat a truly random human — which is correct, because nothing can"). In Archery perfection is *trivial* — invert the solver and shoot. **A perfect archer is not a difficulty level, it is a wall**, and it would make the top of the scale a game that cannot be played rather than one that is hard.

That should be a comment in the file: **the 0.35° is not a limitation of the implementation, it is the product.**

## 11.3 Presentation

- **The draw takes 1.2–2.6 s**, randomised, longer at high skill. An instant shot destroys the fiction. And in a simultaneous-reveal game the wait is the moment (§3.4), so the bot must occupy it.
- **The bot's draw animation is real** — the archer visibly draws.
- **Occasional deliberation:** at high skill, ~15% of shots take an extra second, as if reconsidering the wind.
- **Plausible names**, per [`snake/index.ts:95-101`](../../../backend/games/src/engine/snake/index.ts#L95-L101).

---

# 12. Progression and retention — R3

## 12.1 The floor

[`README.md`](./README.md) §1.6's four:

1. **Rematch**, opponent's name on it, one tap
2. **Post-match summary** — rounds, both scores, total rings, best shot, the wind each round, head-to-head change
3. **Head-to-head record**, before and after
4. **Share result into the chat** — the final target with both players' five arrows in it

That last one is unusually good and worth calling out: **the target at the end of a match is a genuinely interesting image.** Ten arrows, two colours, a visible scatter pattern. It is the single best shareable artifact any game in this folder produces, and it costs one render pass.

## 12.2 The specific hook

**A skill you can visibly acquire in ten minutes.**

Named precisely: most casual games are luck (Ludo, Cards), reflex (Snake, Air Hockey, Voiid Run) or knowledge (Chess). Archery is *calibration* — and calibration improves fast and visibly. Your first-round shots scatter across the target; by round twelve they cluster. **The scatter pattern is a picture of you getting better**, and the ghost trails (§8.1) make it literal.

That is a strong, uncommon hook and it is available in ten minutes rather than ten hours.

Supporting:

- **Every round is a self-contained story** with a clear cause. You misjudged the wind, or you did not.
- **The reveal.** RPS's best property ([`RPS.md`](../RPS.md) §2.3), preserved.
- **Losing is instructive.** You can see exactly where your arrow went and exactly where theirs did.

## 12.3 How it uses the fact that this is a messenger

- **A 90-second match is a message-sized commitment.** Like Air Hockey, "are you free for 90 seconds?" is a question people answer.
- **The target image is the message.** §12.1.
- **Round-by-round trash talk.** A five-round match has four natural gaps, and each one is a moment where a message lands well. This is the rare game where the pacing *invites* chat rather than competing with it.
- **A "beat this shot" challenge:** share a round — the wind and your ring — and let a friend attempt the same wind. Free from `history`, and it is a complete asynchronous social loop built out of a live game.

## 12.4 What the first 30 seconds feel like

- **0–3 s.** Accept. Side-on scene, archer, target, wind readout: `← 4`.
- **3–8 s.** Touch and drag back. The bow flexes, the haptic loads, the arc preview appears. **The control explains itself in one gesture** — everyone who has played a physics game knows this input.
- **8–12 s.** Release. The arrow does *not* fly — it is held (§3.4) — and the opponent's archer is drawing. A two-second wait that is visibly occupied.
- **12–16 s.** Both arrows fly. The camera tracks. Both land. Two ring numbers, theirs 120 ms after yours.
- **16–30 s.** Round 2, new wind: `→ 7`. **This is the moment the game is learned** — the wind changed, and the player now understands that the number matters.

**Zero words of instruction**, and the one non-obvious rule (the wind) is taught by making it change between rounds one and two.

A `?` sheet should still exist for the scoring rings and the round format.

## 12.5 What someone with 50 matches is chasing

- **The head-to-head record.** As everywhere ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §4).
- **Their gold percentage.** A single honest number that improves with skill and is directly comparable between people.
- **A perfect round — 10 in a strong wind.** The hardest achievable thing in the game, and unambiguously an achievement.
- **The scatter pattern**, over time. A cumulative target across all matches is a real, personal artifact and it is one query plus one render.
- **Wind mastery**, per direction and strength. "You average 8.4 in still air and 5.9 in a strong left wind" is a genuinely useful stat that tells a player exactly what to practise.

Explicitly **not**: equipment, upgrades, unlocks (§2.6). Any of them would make two players' shots incomparable and destroy the symmetry that makes the reveal fair.

---

# 13. Failure and edge cases

## 13.1 Disconnect

- **Before committing:** the deadline expires and the server shoots for you (§13.2).
- **After committing:** the round resolves normally. **You do not need to be present for your own arrow to fly**, which is a pleasant property of committing up front.
- **The match continues.** Rounds resolve, deadlines expire, and a fully absent player loses on auto-shots.
- **Reconnect resumes seamlessly** — full frame, and resolved rounds are shown as results rather than replayed (§3.5).
- **After 3 consecutive auto-shots**, the match is forfeited to the present player. Three rounds is over half a match, and continuing to shoot at an empty seat is worse for the remaining player than a clean result.

## 13.2 The commit deadline

Needs the sweeper ([`README.md`](./README.md) §2.3).

| Situation | Deadline | On expiry |
|---|---|---|
| Commit a shot | **30 s** | **Auto-shoot:** the weakest bot's shot (§11.1) — perfect angle degraded by 3° and no wind compensation |
| Absent player (3+ autos) | — | Forfeit |
| Whole match | 5 min of no input | Abandon, `winnerId: null` |

**Auto-shoot, not forfeit-the-round**, and the choice is deliberate: a forfeited round would be a 0 and a guaranteed loss, whereas a bad auto-shot might still win against a worse one. It keeps the match alive for the player who *is* there, which is who the rule is protecting.

**30 seconds** is generous for one gesture and it accounts for a player being interrupted. **A visible countdown from 8 s**, not from 30.

**Idempotency:** timeout frames carry `moveCount` (§4.3) and are dropped on mismatch — without it a duplicate delivery fires two arrows for one round.

## 13.3 Both shots arrive at the same moment

Cannot conflict — frames are processed serially off one Redis subscription ([`index.ts:479`](../../../backend/games/src/index.ts#L479)). The first is stored in the secret, the second resolves the round.

## 13.4 The engine restarts mid-round

- No tick loop.
- State from Redis; a 90-second match fits comfortably inside the 1-hour TTL ([`redis.ts:27`](../../../backend/games/src/redis.ts#L27)), **so Archery needs no durable table.**
- **If the secret survives:** the round continues exactly.
- **If it does not:** the round re-opens, both players re-shoot (§4.4). One replayed shot, nothing leaked. **The RNG reseeds and the remaining winds change** — log it.

## 13.5 Ties

- **A round tie** (equal rings): no point to either (§2.2).
- **A match tie:** one sudden-death round at maximum wind, then a genuine draw with `winnerId: null` — exactly what [`GameEngine.ts:22-23`](../../../backend/games/src/engine/GameEngine.ts#L22-L23) means by "finished and has a winner are separate facts."

The post-match screen needs a **real draw state**, not a win screen with different words. [`TICTACTOE.md`](../TICTACTOE.md) §2.2 flags that the draw there has no identity of its own; do not repeat it.

## 13.6 An arrow that never reaches the target

Possible with minimum power at a downward angle — the arrow hits the ground short. Handled: the integrator terminates on ground contact as well as on the target plane, and a short shot scores **0**, animated properly with a ground impact. **It must not be a special case that renders nothing** — a shot that vanishes reads as a bug, and a player who mis-set their power needs to see why.

**A hard iteration cap** on the integrator (10 seconds of simulated flight) guarantees termination regardless of parameters.

---

# 14. Build plan

Archery and Snow Fight are one project in two shippable halves. This plan builds the shared parts once.

## Phase 1 — `ballistics/`, headless

The shared solver: fixed-step integration, wind, drag, ground and target termination, the iteration cap. TypeScript, then Swift and Kotlin.

**The golden-shot fixture and its CI job are part of this phase** (§4.6): fixed `(angle, power, wind)` triples with expected impact points, asserted on all three platforms. Without it the three ports drift and arrows land where the score says they did not.

## Phase 2 — `engine/archery/`, headless

Rules on top of the solver: rounds, wind draw, scoring, the simultaneous reveal, deadlines. Registry entry.

Tests: **serialize → restore → serialize byte equality**, specifically that `wind` does not get redrawn (§4.3); the secret round-trip preserving `pending` (§4.4); a restore without the secret re-opening the round; and one that asserts **`serialize()` never contains an un-revealed shot** — the cricket invariant, restated for this game and worth its own test.

## Phase 3 — iOS practice mode

Scene, pull-back control with the non-linear mapping and fine-adjust (§7.2), the arc preview, camera, the bot at all four bands, sound, haptics, motion. No networking.

**Where §7.2 and §7.3 are tuned**, and they are the two numbers the game lives or dies on.

## Phase 4 — iOS online

Wire to `GamesEngine`. Simultaneous reveal, waiting state, deadlines, reconnect.

## Phase 5 — Android parity

Phases 3–4. iOS is the reference; constants identical ([`SNAKE.md`](../SNAKE.md) §2.4), and the ballistics port already verified by Phase 1's CI.

## Phase 6 — retention

Post-match summary, rematch, head-to-head, the shareable target image (§12.1), the cumulative scatter pattern, wind stats.

## Phase 7 — Snow Fight

See [`SNOW_FIGHT.md`](./SNOW_FIGHT.md) §14. It reuses phases 1, 2's shape, and most of 3.

---

# 15. Open questions

1. **How much trajectory preview?** (§7.3) Recommendation: **25%.** This is the single most important tuning number in the game — too little and it is opaque, too much and it is solved. It needs playtesting rather than a decision, but the default must be chosen before Phase 3 has something to tune.

2. **5 rounds, or best-of-3?** Recommendation: **5** (§2.1). Equal shots for both players matters when the wind varies.

3. **Does the wind vary within a round?** Recommendation: **no** (§2.3). Gusting adds variance without a decision, which [`GAMES_HAND_CRICKET.md`](../../GAMES_HAND_CRICKET.md) §2 already rejects as a design principle in this app.

4. **Is there a global ring-score leaderboard?** Recommendation: **no** (§5.1). A perfect-aim client is undefeatable and would trivially farm it. Head-to-head and friends-scoped only.

5. **Do bot matches count?** Cross-cutting (O10). Recommendation: no.

6. **Is the fine-adjust arc discoverable?** (§7.2) It appears only past 120 pt of drag, so a player who never pulls back far will never see it — and it is where good shots are made. Either surface it in the first match with a one-line hint, or accept that it is a depth mechanic for players who explore. **Recommend the hint**, once, on the second round of a player's first match.

7. **Reduce-motion.** §9 specifies camera tracking, punch-in and shake. The switch does not exist ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13). The reduced version must still show the impact point clearly — the score must never depend on an animation the player has turned off.
