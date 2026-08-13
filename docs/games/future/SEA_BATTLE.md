# Sea Battle

> **Status:** **phases 0, 1, 3 and 4 built** — infrastructure, engine, and both renderers online. Phase 2 (practice mode + bot), 5 (retention) and 6 (polish) are still design only. See §16 for what shipped and where it departed from this doc.
> **Kind:** turn-based, hidden state, 2 players. No `tickHz`.
> **Was blocked on:** per-recipient wire frames ([`README.md`](./README.md) §2.1), durable turn-based state (§2.2), deadline sweeper (§2.3). **All three now exist** — see §16.1.
> **Reference implementations to read first:** [`cricket/index.ts`](../../../backend/games/src/engine/cricket/index.ts) for the hidden-state pattern, [`tictactoe/index.ts`](../../../backend/games/src/engine/tictactoe/index.ts) for the grid and turn pattern.

---

# 1. What the game is

Two players each hide a fleet on a private 10×10 grid. They take turns naming one square on the opponent's grid. The server answers hit, miss, or sunk. First to sink the opponent's entire fleet wins.

[`GAMES.md`](../../GAMES.md) §8 named it the best first game and it is still unbuilt. That judgement was about *plumbing* — no physics, no tick loop, a state small enough to send whole. It is right, but it undersells the game, because the interesting argument for Sea Battle is not that it is easy.

**It is the only game in this catalog that fits how people actually use a messenger.**

Every shipped game requires both players to be looking at their phones at the same time. Tic Tac Toe, RPS and Hand Cricket all die the moment one player puts the phone down — the match sits in Redis for an hour and evaporates ([`redis.ts:27`](../../../backend/games/src/redis.ts#L27)). That is a real constraint on when a game can happen: both people, free, now.

Sea Battle has no such requirement. A turn is one tap. The interval between turns can be nine seconds or nine hours and the game is unchanged, because there is nothing to react to — you are not dodging, you are deducing. A match played across a working day, one shot at a time, between messages, is not a degraded version of Sea Battle. It is the normal version.

That is worth stating plainly because it changes what "shipping this game" means. The engine here is a weekend. The thing that makes it worth building is the durable state and the turn notification, which are infrastructure, not rules.

## 1.1 Why it belongs in Voiid specifically

The app already has the two things this game needs and a standalone Battleship app does not: a list of people you actually talk to, and a place to put the result. A shot fired into a chat thread is a message. "Sunk your carrier" is a message. The game does not have to invent a social layer — it is already inside one.

## 1.2 Honest cost

Low, and the lowest in the folder. The engine is ~350 lines, comparable to [`cricket/index.ts`](../../../backend/games/src/engine/cricket/index.ts) at 281. Both renderers are grids of tappable cells and neither needs `Canvas` for anything except the water and the shot animations. There is no netcode to get wrong.

The cost is entirely in step 0 of the build order, and step 0 is shared with Chess and with every turn timer in the app.

---

# 2. Rules as implemented

Normative. Every house rule below is a decision with a reason, in the style of [`GAMES_HAND_CRICKET.md`](../../GAMES_HAND_CRICKET.md) §2 — the alternative is folklore, and folklore produces two players who each believe the other cheated.

## 2.1 The board and the fleet

10×10 grid, columns `A`–`J`, rows `1`–`10`. Coordinates travel on the wire as a packed integer `y * 10 + x` (0–99), not as a string — it is one number, it indexes an array directly, and it cannot be misparsed.

Five ships, the classic Milton Bradley set:

| Ship | Length | Count |
|---|---|---|
| Carrier | 5 | 1 |
| Battleship | 4 | 1 |
| Cruiser | 3 | 1 |
| Submarine | 3 | 1 |
| Destroyer | 2 | 1 |

17 occupied squares of 100. **Not** the Russian variant (one 4, two 3s, three 2s, four 1s), and not a house set. Reason: 17/100 is the ratio the entire genre's intuition is calibrated to. A player who has played Battleship anywhere else must not have to relearn the density, and single-square ships are miserable to hunt — they turn the endgame into a coin flip over the remaining squares rather than deduction.

## 2.2 Placement

- Ships are placed **horizontally or vertically only.** No diagonals. Diagonal placement roughly doubles the search space in a way that makes the hunt/target heuristic — the thing that makes the game feel like reasoning — stop working.
- Ships **may not overlap.**
- Ships **may touch.** Adjacency is legal, including corner contact.

That last one is the real decision and it goes against the Russian rules, which forbid touching. Forbidding contact is a better *game* by one measure: it means a sunk ship's neighbours are provably empty, which gives the endgame more structure. It is a worse game inside a messenger, for two reasons. It makes placement fiddly on a phone — a player drags a ship, gets a red cell, and has to work out that the problem is a diagonal neighbour they cannot see. And it leaks: "these eight squares are now known-empty" is a large free gift, and it shortens matches. We want matches to last long enough to be worth coming back to.

**Both players place simultaneously.** Neither placement is revealed. There is no first-placer advantage to compensate for, and forcing one player to wait for the other before they can even start would put a dead screen at the front of the game.

A **Random** button is mandatory and is the default path. A player who has to place five ships before the first shot is a player who may not get to the first shot. The button uses the match RNG (§4.5) and places a legal fleet in one tap; a player who wants to place by hand still can, and most will after their first match, because placement is where the personality is.

## 2.3 Turns

- The player who did **not** get the first shot in the previous match against this opponent goes first. On a first-ever match it is decided by the match RNG and announced in the opening frame, exactly as hand cricket announces the toss ([`cricket/index.ts:237`](../../../backend/games/src/engine/cricket/index.ts#L237)).
- **One shot per turn. A hit does not grant another shot.**

The second rule is the one people will argue about, so here is the argument.

Extra-shot-on-hit is the more common house rule and it is better in a living-room game: a streak is exciting and the other player is sitting right there watching it. It is actively bad in an async game. In async, "you keep shooting while you keep hitting" means one player takes six turns in ninety seconds while the other gets six notifications for a game they cannot act in — and then waits. It converts a game with a predictable rhythm (your turn, their turn, your turn) into one where the notification cadence tells you you are losing before you open the app.

Fixed alternation also makes the deadline sweeper trivial: there is always exactly one player on the clock and exactly one deadline outstanding.

- A square may only be fired at **once.** Re-firing a known square is rejected (`accepted: false`), which per [`GameEngine.ts:34`](../../../backend/games/src/engine/GameEngine.ts#L34) costs the server one rejected input and produces no broadcast. The client greys out fired cells, so this only fires on a stale or modified client.

## 2.4 Hit, miss, sunk

- **Miss** — the square is marked, the turn passes.
- **Hit** — the square is marked, the turn passes.
- **Sunk** — the shot took the last remaining square of a ship. The ship's **full outline is revealed** on both players' boards, and the ship is **named**: "You sank their Cruiser."

Announcing sinks is a real decision and we recommend it on (open question O5 in [`README.md`](./README.md) §5). Without announcements a player who has scored three hits in a line does not know whether they are looking at a sunk Cruiser or a wounded Battleship, and the endgame degrades into re-shooting around every hit cluster to be sure. With announcements, the remaining fleet is *derivable* — you know exactly what is left and how long it is, and the last ten squares are a deduction rather than a grind.

It also makes the game legible to a newcomer. "Sank their Destroyer" tells you the rules of the game in four words.

## 2.5 Winning

Match ends the instant all 17 squares of one fleet are hit. `winnerId` is that player.

**There are no draws in Sea Battle.** `winnerId: null` is reserved for an abandoned match, matching the shape [`handleLeave`](../../../backend/games/src/index.ts#L427) already writes (`{ winnerId: null, scores: {} }` — "the honest record of a match that did not finish").

`scores` in the [`GameOutcome`](../../../backend/games/src/engine/GameEngine.ts#L21) is **shots fired**, lower being better. That is the number this game is about, it is what a personal best is measured in, and it is the only number that makes two matches comparable. The theoretical floor is 17; a strong human is high 30s to mid 40s; random shooting is ~95.

Because lower is better here and higher is better in every other game, the post-match screen and any leaderboard query must know the sort direction per game. Flagging it now: `game_match_results.score` has no "direction" column and the global leaderboard sorts descending. **Sea Battle must not be added to that leaderboard until the direction is representable**, or the worst player in the app will be top of the table.

## 2.6 Surrender

A player may resign at any time. Immediate loss, recorded honestly — resignation is a result, not an abandonment, and the head-to-head must show it as a loss. Confirmation dialog, because the button lives next to the board.

---

# 3. Network model — R2

## 3.1 Pattern

**Pure turn-based**, the fourth row of [`GAMES.md`](../../GAMES.md) §4: one `game_input` per move, one `game_state` broadcast in response. No `tickHz`, therefore no tick loop, therefore no per-match CPU cost when nobody is playing ([`GameEngine.ts:8-13`](../../../backend/games/src/engine/GameEngine.ts#L8-L13)).

There is no interpolation, no prediction, no jitter buffer and no render clock. **The Snake stutter class of bug ([`SNAKE.md`](../SNAKE.md) §2) cannot occur here**, and the reason is worth stating precisely rather than waving at: that bug is caused by a *continuously advancing render clock* being re-anchored to frame arrival time. Sea Battle has no render clock. Nothing on screen moves except in response to a discrete event, and every animation is triggered by an arriving frame rather than sampled from a timeline. There is nothing to anchor.

## 3.2 Rate

Input rate limiting falls to the turn-based default, 60 per minute ([`index.ts:29`](../../../backend/games/src/index.ts#L29)), because `limitFor` returns `INPUT_MAX_PER_WINDOW` for any slug without a `tickHz` ([`index.ts:45-48`](../../../backend/games/src/index.ts#L45-L48)). A legal Sea Battle match contains at most ~100 inputs *per player for the whole match*. 60/minute is three orders of magnitude of headroom and needs no change.

Broadcast payload is ~600 bytes of JSON per frame (§4.2), a few times a minute in a live match and a few times a day in an async one. Bandwidth is not a consideration for this game and no `serializeForWire()` split is needed — per [`GameEngine.ts:70-72`](../../../backend/games/src/engine/GameEngine.ts#L70-L72), "their state is small and every field matters to the client, so the persistence shape and the wire shape are the same object."

The **information** shape does differ per recipient, which is a different problem and is solved by `serializeForPlayer()` (§4.3), not by the wire split.

## 3.3 Latency

Move-to-confirmation is one round trip through the relay: phone → `channel:games:input` → games service → `channel:user:<id>` → phone. On the dev box that is tens of milliseconds; on a bad mobile network it is a few hundred.

**The client must not wait for it to acknowledge the tap.** The moment a player commits a shot, the target cell enters a local `firing` state — the reticle locks, the cell dims, and a shell-travel animation starts (§9). The server's answer arrives during that animation and decides what it resolves into. This gives the player instant feedback on a game that is round-tripping every action, and it costs nothing in correctness because the client is not predicting the *outcome*, only the fact that the shot was taken. If the input is rejected the cell simply returns to normal.

This is the same posture Snake's predictor takes and for the same reason ([`SnakePredictor.swift:7-19`](../../../apps/ios/Voiid/Voiid/Games/SnakePredictor.swift#L7-L19)): predict what you can derive, never predict authority.

## 3.4 What happens on a 3-second network stall

Concretely, and this is the pleasant answer:

- **If it is not your turn:** nothing. The board is a still image. You do not notice.
- **If it is your turn and you have not fired:** nothing. You are looking at a still image and the clock you are on is measured in hours.
- **If you fired during the stall:** the shell animation completes and lands on a "waiting" state — the reticle stays lit and a subtle spinner appears on the target cell after 800 ms. No error, no dialog. When the socket recovers, the frame arrives and the cell resolves.
- **If the socket is genuinely down** (the client's existing reconnect/backoff has given up and is retrying), the screen shows the "Reconnecting…" state that [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §7 says every game needs and none has. **Sea Battle must ship with it**, because an async game gets cold-started on a bad network far more often than a live one does.
- **On reconnect:** the client re-joins via the existing path and receives a full state frame. There is no delta to reconcile — every frame is complete — so resync is free.

The 3-second stall is not an interesting case for this game. The interesting case is the **3-day gap**, which is §13.

---

# 4. Engine design — R1

Folder: `backend/games/src/engine/seabattle/`. One line in [`registry.ts`](../../../backend/games/src/engine/registry.ts) adds it.

## 4.1 Interface surface

| Method | Present | Why |
|---|---|---|
| `applyInput` | yes | Placement frames and shot frames |
| `tick` | **no** | Nothing advances on its own. Omitting it is what keeps the match free when idle |
| `serialize` | yes | Public, restart-complete state |
| `serializeForWire` | **no** | State is ~600 bytes and every field matters to the client |
| `serializeForPlayer` | **yes** | Your own fleet. This is the method the game is blocked on |
| `serializeSecret` | **yes** | Both fleets, in full. The server's copy of the truth |
| `deadlineAt` / `onTimeout` | **yes** | Turn deadline, §13.2 |
| `isFinished` | yes | — |

## 4.2 `serialize()` — the public shape, field by field

This is the **persistence** shape ([`GameEngine.ts:60-64`](../../../backend/games/src/engine/GameEngine.ts#L60-L64)): the runtime hands it straight back to `restore`, so anything missing here is silently reset. It is also what a spectator or any seatless caller sees, which is why nothing in it is private.

```ts
{
  players: string[],          // seat order; index is the seat
  phase: 'placing' | 'firing' | 'done',
  turn: 0 | 1 | null,
  shots: [number[], number[]],   // packed 0-99, in fire order, per FIRING seat
  results: [number[], number[]], // 0 miss, 1 hit, 2 hit-and-sunk. Parallel to shots
  sunk: [number[], number[]],    // ship type ids sunk, per seat whose fleet lost them
  sunkCells: [number[], number[]],
  placed: [boolean, boolean],
  fleetSpec: number[],        // [5,4,3,3,2]
  moveCount: number,
  seed: number,
  deadlineAt: number | null,
  finished: boolean,
  winnerUserId: string | null,
  lastShot: number | null,
  lastResult: 0 | 1 | 2 | null,
}
```

Field by field, and the sentence per field is *why it must survive a restart* — the exercise [`README.md`](./README.md) §1.4 requires, which found two fields here that a naive shape would have lost.

- **`players`** — seat order, and the index into it is the seat. Every existing engine does this ([`cricket/index.ts:82`](../../../backend/games/src/engine/cricket/index.ts#L82)). Lose it and no input can be attributed to a seat, so the match is unrecoverable.
- **`phase`** — `placing` until both fleets are committed, then `firing`. Lose it and a restored match would accept shots during placement, or worse, re-enter placement mid-game and let a losing player re-place their fleet.
- **`turn`** — seat to move; `null` during `placing`, where both may act. Lose it and the restored match hands the turn to seat 0, which is a free extra shot for one player at every process restart.
- **`shots`** — packed coordinates in fire order, per firing seat. This is the whole record of the match and the only thing that makes "already fired here" checkable. Lose it and every square becomes legal again.
- **`results`** — parallel array, one entry per shot. Deliberately **stored, not derived.** It is derivable from `shots` plus the secret fleets, and deriving it would be the "nothing derivable is stored" instinct [`snake/index.ts:15-19`](../../../backend/games/src/engine/snake/index.ts#L15-L19) argues for — but that instinct is about a payload sent 12×/sec, and it is wrong here. Deriving results would make the **public** state depend on the **secret** state, so a restore that lost the secret (§4.4) would silently turn every past hit into a miss. Storing results keeps the public board true on its own.
- **`sunk`** — ship type ids sunk from each seat's fleet, so the HUD can show a remaining-fleet strip without consulting the secret. Same argument as `results`.
- **`sunkCells`** — the revealed outline of each sunk ship. Once a ship is sunk its squares are public information (§2.4), so they are promoted out of the secret into the public state at the moment of sinking. This is the field a naive design loses: without it, a client that reconnects mid-match sees hit markers but no ship outlines, and the endgame deduction is gone.
- **`placed`** — whether each seat has committed a fleet. Lose it and a restored match forgets that one player is already waiting.
- **`fleetSpec`** — the ship lengths, sent so the renderer never hardcodes them and an older client cannot disagree with the server about how much fleet is left. Same argument as cricket serializing `ballsTotal` rather than making the renderer know `BALLS_PER_OVER` ([`cricket/index.ts:190-191`](../../../backend/games/src/engine/cricket/index.ts#L190-L191)).
- **`moveCount`** — monotonic, used as the idempotency key for the deadline sweeper (§13.2). A timeout frame carries the `moveCount` it was scheduled for; if it does not match, the deadline is stale and is dropped. Without this a duplicate sweeper frame can forfeit a player who already moved.
- **`seed`** — the RNG state. Public here, deliberately, and §4.5 explains why this game is allowed what Ludo is not.
- **`deadlineAt`** — epoch ms. Serialized rather than recomputed, because recomputing it from "now" on every restore would silently give an AFK player a fresh 24 hours on every process restart. This is the second field a naive design loses, and it loses it in the direction of never forfeiting anyone.
- **`finished`** / **`winnerUserId`** — terminal state. Cricket recovers `winnerIdx` from the user id on restore rather than storing an index ([`cricket/index.ts:276-278`](../../../backend/games/src/engine/cricket/index.ts#L276-L278)) precisely because storing a field `serialize()` does not emit "would silently un-win a finished match". Same shape here.
- **`lastShot`** / **`lastResult`** — the shot to animate on arrival. The client could diff `shots` against its previous copy, but a client that just cold-started has no previous copy and would animate nothing or everything. One explicit field is cheaper than a diff and correct on the first frame.

## 4.3 `serializeForPlayer(playerId)` — the information projection

**This is the method the game does not exist without**, and it is the change described in [`README.md`](./README.md) §2.1. Today [`broadcast()`](../../../backend/games/src/index.ts#L69) builds one frame and publishes the same bytes to every player, so there is no way to send you your own fleet without sending it to your opponent too.

```ts
serializeForPlayer(playerId: string): GameStatePayload {
  const seat = this.s.players.indexOf(playerId);
  const base = this.serialize();
  if (seat !== 0 && seat !== 1) return base;   // spectator: public state only
  return { ...base, seat, myFleet: this.s.fleets[seat] };
}
```

Three properties this shape has, all of them deliberate:

1. **It is additive.** It returns `serialize()` plus exactly one private field. It never *removes* anything, so a spectator's view is a strict subset of a player's and there is no path where a player is shown less than the public truth.
2. **It is pure.** No delta buffers, no counters, no mutation. It is called once per recipient. `serializeForWire()` is explicitly allowed to clear per-frame buffers ([`GameEngine.ts:79`](../../../backend/games/src/engine/GameEngine.ts#L79)) and Snake relies on that ([`snake/index.ts:721-722`](../../../backend/games/src/engine/snake/index.ts#L721-L722)) — which is exactly why this must be a separate method rather than an overload.
3. **The default is safe.** A caller with no seat falls through to `serialize()`. A leak to a spectator is therefore structurally impossible rather than merely unwritten — you would have to add a leak, not forget to prevent one.

The opponent's fleet is **never** in any payload sent to a client, at any phase, until the individual ship is sunk (at which point its cells move into public `sunkCells`). There is no "reveal at end" frame either — the post-match screen shows the final board including the loser's unhit ships, and that comes from the terminal broadcast, which is sent *before* `finishMatch` clears the Redis key ([`index.ts:93-97`](../../../backend/games/src/index.ts#L93-L97)). The terminal frame is the one place both fleets go out in full, and only because the match is over.

## 4.4 `serializeSecret()` — the server's copy

```ts
serializeSecret(): GameStatePayload {
  return { fleets: this.s.fleets };   // [Ship[], Ship[]], Ship = { type, cells: number[], hits: number }
}
```

The comment on [`GameEngine.ts:83-96`](../../../backend/games/src/engine/GameEngine.ts#L83-L96) describes the hand-cricket bug this exists for: a secret omitted from `serialize()` was "silently dropped a millisecond after being made" because the runtime round-trips serialize/restore on every input ([`index.ts:279`](../../../backend/games/src/index.ts#L279)).

Sea Battle's version of that bug is worse than cricket's, and it is worth being explicit about why. Cricket's secret is one ball old — a restore without a secret "reopens that ball. Costs one replayed pick and leaks nothing" ([`cricket/index.ts:267-273`](../../../backend/games/src/engine/cricket/index.ts#L267-L273)). Sea Battle's secret is **the entire match**. A restore that loses the fleets does not cost a replayed turn; it destroys the game state irrecoverably, because there is no longer any fact about where the ships are. Every subsequent shot would have to be a miss.

So: `restore` must treat a missing secret in the `firing` phase as **fatal**, not as a soft default. It cannot invent fleets — inventing them would produce a match whose past results contradict its present ones — and it must not silently continue. The correct behaviour is to abandon the match with `winnerId: null`, the same honest shape [`handleLeave`](../../../backend/games/src/index.ts#L442) uses. This should be effectively unreachable once §2.2's durable table stores `state` and `secret` in the same row, written in the same statement; the point of naming it is that the failure must be loud rather than quietly wrong.

Note also that fleets are rebuilt **field by field** in `restore`, never by casting the payload — the mistake [`cricket/index.ts:254-257`](../../../backend/games/src/engine/cricket/index.ts#L254-L257) documents, where a blanket cast produced an engine "whose pending is undefined, and the very next serialize() throws — taking the games service down with any match that outlived a process restart."

## 4.5 RNG and determinism

`Rng` (mulberry32) from [`geometry.ts:113`](../../../backend/games/src/engine/snake/geometry.ts#L113), promoted to `engine/rng.ts` when this becomes the second consumer. `Math.random()` is unusable for the reason that file states: the engine is rebuilt from serialized state on every input, so global randomness "would produce a different world each time it was restored."

Two draws in the whole game:

1. **Who fires first**, on a first-ever pairing. One draw at `create`.
2. **The Random placement button**, when a player uses it — and bot placement in a practice match.

**The seed lives in `serialize()`, publicly**, and Sea Battle is one of only two games in this folder allowed to do that ([`README.md`](./README.md) §1.3). The rule is that the seed goes in the secret whenever a future draw is information a player would pay for. Here it is not: the first-move draw has already happened by the time any client sees a frame, and the placement draw only ever produces *your own* fleet, which you are about to be told anyway. A client holding this seed learns nothing about the opponent.

Contrast Ludo, where the next draw is the dice, and Voiid Cards, where the sequence *is* the shuffle. Those carry the seed on the secret channel. **Do not copy Snake's public seed placement into a new game without re-running this check** — Snake gets away with it because its draws are pellet positions and bot jitter ([`snake/index.ts:786`](../../../backend/games/src/engine/snake/index.ts#L786)).

The one caveat: the *bot's* placement is drawn from the same public sequence in a practice match. A modified client could in principle re-derive the bot's fleet. That is acceptable — cheating against a bot to win a bot match is self-defeating, and [`BotScoreStore`](../../../apps/ios/Voiid/Voiid/Games/BotScoreStore.swift) already keeps bot scores client-side and out of anything that matters. If bot results are ever promoted into head-to-head or a global leaderboard (open question O10), this must be revisited and the seed moved to the secret.

## 4.6 Tick-rate independence

Not applicable, and it is worth saying so rather than leaving the section blank. There is no `tick()`, no `dt`, and nothing integrated over time. The only time-dependent value in the engine is `deadlineAt`, which is an **absolute epoch timestamp** rather than a countdown — so it is correct regardless of when it is read, how long the process was down, or how many restarts happened in between. A countdown would be wrong at every one of those.

## 4.7 `applyInput`

Two frame shapes, one method, gated on `phase`:

```ts
// phase 'placing'
{ place: [{ type: number, cells: number[] }, ...] }   // all five ships, one frame
// phase 'firing'
{ fire: number }                                       // packed 0-99
```

Placement arrives as **one frame containing the whole fleet**, not five frames. Per-ship frames would leave a half-placed fleet as a legal intermediate state that has to be validated, persisted and rendered, and would let a client commit four ships and stall forever. One frame is atomic: the fleet is legal in full or it is rejected in full.

Validation on the placement frame, all of which returns `accepted: false` on failure:

- Exactly five ships, types matching `fleetSpec` exactly, one of each
- Each ship's `cells` length matches its type's length
- Each ship's cells are contiguous and collinear on one row or one column (this is what enforces "no diagonals" — it is not a separate check)
- All cells in 0–99, and no row wrap (a horizontal ship must not cross from `J` to `A`: `Math.floor(c / 10)` must be identical across the ship)
- No cell appears twice across the whole fleet
- The seat has not already placed

**Nothing is trusted about ship identity.** The engine recomputes each ship's length from its own `cells` and checks it against `fleetSpec[type]`; a client claiming a 2-cell Carrier is rejected rather than believed.

Validation on the fire frame:

- `phase === 'firing'`
- `turn === seat`
- integer, 0–99
- not already in `shots[seat]`

Neither input sets `silent: true`. Per [`GameEngine.ts:38-40`](../../../backend/games/src/engine/GameEngine.ts#L38-L40), turn-based games leave it unset because "a move IS the state change, so it must go out immediately." A shot is exactly that.

---

# 5. Anti-cheat

The useful way to state this is the way [`snake/index.ts:8-13`](../../../backend/games/src/engine/snake/index.ts#L8-L13) does: **enumerate what a modified client can express in an input frame, and show that none of it is worth expressing.**

A Sea Battle client can send exactly two things.

**"Here is my fleet."** Constrained by §4.7's validation to a legal fleet. The only freedom is *which* legal fleet, which is a legal choice — it is the game. A client cannot place ships off-grid, overlapping, diagonal, wrapped, or of the wrong length, and it cannot re-place after committing (`placed[seat]` gates it). It cannot move a ship out from under an incoming shot, because there is no input frame that expresses "move a ship" and the fleet is only writable once.

**"I fire at square N."** Constrained to an integer 0–99, on your turn, not previously fired. There is no lie available: the outcome is computed server-side against the secret fleet and the client is told the answer.

What a modified client **cannot** do, structurally rather than by validation:

- **See the opponent's fleet.** It is never in any frame sent to that player. This is a property of `serializeForPlayer` being additive over `serialize()` (§4.3), not of any check.
- **Predict the opponent's fleet.** It was placed by the opponent's client, not drawn from the match RNG. Even holding the public seed, there is nothing to derive.
- **Deny a hit.** Hit resolution is server-side and the result is recorded in public `results`.
- **Fire twice.** `turn` advances inside `applyInput` before it returns.
- **Skip a forfeit.** The deadline is server state on a server clock, in a Redis sorted set the client cannot see or write.

The one genuine attack surface is **the practice-mode bot's placement being derivable from the public seed** (§4.5). Scoped, accepted, and revisited only if bot results ever count for anything.

Rate limiting is the runtime's existing per-match token bucket at 60/minute ([`index.ts:29`](../../../backend/games/src/index.ts#L29)). A flooding client is silently dropped with no error frame back — "answering it with traffic is how you turn one bad client into a fan-out amplifier" ([`index.ts:24-28`](../../../backend/games/src/index.ts#L24-L28)).

---

# 6. Client rendering

**Reuse before invention**, per [`README.md`](./README.md) and [`GAMES.md`](../../GAMES.md) §4. The honest summary for this game: *it needs almost nothing new.*

## 6.1 What it reuses

| Piece | Source | Used for |
|---|---|---|
| Grid of tappable cells | [`TicTacToeBoard.swift`](../../../apps/ios/Voiid/Voiid/Games/TicTacToeBoard.swift) / [`TicTacToeScreen.kt`](../../../apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeScreen.kt) | Both boards. Same hit-testing, same cell-state rendering, 10×10 instead of 3×3 |
| `GamesEngine` state subscription | existing per-platform module | `game_state` → observable, unchanged |
| Lobby / invite flow | [`GameLobbyView.swift`](../../../apps/ios/Voiid/Voiid/Games/GameLobbyView.swift) / `GameLobbyScreen.kt` | Unchanged — 2 seats, existing single-select picker works |
| `GameAudio` | [`GameAudio.swift`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift) | One new entry in `soundNames(for:)` ([`GameAudio.swift:282`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L282)) |
| `GameHaptics` | [`GameHaptics.swift`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameHaptics.swift) | Two new patterns; the existing `kill()`/`death()` shapes are close |
| `BotScoreStore` | [`BotScoreStore.swift`](../../../apps/ios/Voiid/Voiid/Games/BotScoreStore.swift) | Practice-mode bests, client-side |

## 6.2 What it adds

**iOS:** plain SwiftUI. Two `LazyVGrid`s of 100 cells each, one `Canvas` layer per board for the water shimmer and shot animations. **No Metal.** [`SnakeMetalView.swift`](../../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift) exists because Snake draws six SDF-shaded polylines at 60 fps; Sea Battle draws 200 static rounded rects and at most one animating shell. `Canvas` + `TimelineView(.animation)` is the right tool and [`GAMES.md`](../../GAMES.md) §4 already specifies exactly this split ("plain SwiftUI views for static/turn-based boards").

**Android:** Compose. `LazyVerticalGrid` for cells, one `Canvas` overlay with `withFrameNanos` for the shot animation, mirroring the iOS structure view-for-view per [`ANDROID_IOS_PARITY.md`](../../ANDROID_IOS_PARITY.md).

**A doc proposing a new rendering approach must argue why the existing one is insufficient**, and this one does not propose any. The one thing worth building carefully is the **two-board layout**, which is a layout problem rather than a rendering one (§8.1).

---

# 7. Controls

## 7.1 The hard constraint

A 10×10 grid on a 390 pt-wide phone gives cells of ~33 pt after margins. Apple's minimum touch target is 44 pt and Material's is 48 dp. **The grid is below the minimum on every phone.** Any design that ignores this ships a game where the most common action is mis-tapping, in a game where a mis-tap is irreversible and costs you the match.

There are three ways out and only one of them is right.

| Approach | Verdict |
|---|---|
| Bigger cells, scroll/pan the board | **No.** You cannot deduce on a board you cannot see whole. Seeing the full pattern of hits and misses is the entire game |
| Tap-to-fire, accept the mis-taps | **No.** Irreversible action on a sub-minimum target |
| **Two-step commit: tap to aim, tap FIRE to commit** | **Yes** |

## 7.2 The scheme

1. **Tap a cell on the opponent's board.** A reticle snaps to it. Nothing is sent.
2. **The reticle is draggable.** Dragging moves it cell by cell with a light haptic tick per cell crossed, and the cell under the finger is drawn magnified in a callout *above* the touch point — the standard iOS text-loupe idiom. This is what makes a 33 pt target usable: you do not have to hit it, you have to *arrive* at it, and you can see where you are while your finger covers it.
3. **A FIRE button, thumb-height at the bottom**, commits. It shows the coordinate: `FIRE — D7`. It is disabled until a cell is selected and while it is not your turn.
4. **Double-tapping a cell** fires immediately, for players who have learned the board and want speed.

The FIRE button is not friction, it is the confirmation step the irreversibility demands. It also gives the game its beat: aim, hesitate, commit. That hesitation is the most Battleship thing about Battleship, and a one-tap scheme deletes it.

## 7.3 One-handed and small screens

- FIRE sits in the bottom third, reachable by a right or left thumb. **Its horizontal position is mirrored by a left/right-handed setting** — which does not exist yet ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §12) and is listed there as needed for Snake's controls too. Ship the default (right) and the setting together if the setting lands first; otherwise centre it.
- The aiming loupe renders **above** the touch point with a 60 pt offset, so the finger never covers the thing being aimed at.
- On a compact screen the two boards stack with the inactive one collapsed to a strip (§8.1), so the active board always gets the full width.

## 7.4 Placement controls

- **Random** is the primary button and the default path (§2.2).
- Manual: drag a ship from a tray onto the grid. **Tap while dragging rotates it** — a separate rotate button means a two-handed operation, and a long-press-to-rotate conflicts with the drag. Snap to the nearest legal cell; illegal positions render the ship red and translucent and refuse the drop rather than silently correcting it. Silent correction is worse: the player learns nothing about why.
- **Undo last placement** and **Clear all**. No confirmation on either — they are reversible.
- The commit button reads `READY` and is disabled until all five are legally placed.

---

# 8. Visual design

## 8.1 The layout problem, which is the whole design

Sea Battle has two boards and a phone has one screen. Every implementation of this game is really a decision about that, so it is decided here.

**Primary: the opponent's board, full width, upper two-thirds.** This is where you act and where the deduction happens. It gets the space.

**Secondary: your own board, a strip below**, ~28% scale, showing your fleet and their hits. Tapping it swaps the two with a 320 ms shared-element transition; tapping again swaps back. It is not interactive at strip scale — it is a status readout, and its job is to answer "how much trouble am I in" at a glance without a tap.

**On your turn** the opponent's board is bright and the strip dims to 60%. **On their turn** the emphasis inverts and the strip lifts to full opacity — because on their turn the only thing that will happen is a shot landing on *your* board, and it should be the thing you are looking at when it does. The layout follows the action rather than making the player follow it.

## 8.2 Art direction

Not naval-realistic, and not the retro-neon of Snake. **A chart.** Paper, ink, and a plotted grid — the fiction is that you are working a problem on a naval chart, which is what the player is actually doing, and it justifies the game's one honest weakness (nothing moves) as a deliberate aesthetic rather than a limitation.

- **Water:** a very slow gradient wash with a barely-perceptible caustic shimmer, ~0.04 amplitude, 8-second period. Just enough to prove the screen is alive during the long pauses of an async match.
- **Grid:** thin ink rules, heavier every 5 cells. Column letters and row numbers in a mono face, always visible on both boards — a player calling out "D7" in the chat needs to be able to read D7 off the screen.
- **Miss:** a small hollow ink ring. Recedes.
- **Hit:** a filled mark with a short radial scorch. Advances.
- **Sunk:** the ship's outline drawn in as a solid silhouette across its cells, with its name set beside it.
- **Your fleet:** drawn as clean ship silhouettes on your own board, damaged cells scorched through.

## 8.3 What the player must be able to see, without a tap

This list is the acceptance criterion for the HUD, and it is written as a list because [`SNAKE.md`](../SNAKE.md) §3.2 documents what happens when a game hides its own mechanics — "every invisible mechanic is a reason to quit."

1. **Whose turn it is.** Unambiguously, from across a room. The FIRE button's state alone is not enough.
2. **The remaining enemy fleet** — five ship pips, sunk ones struck through. This is the deduction aid and it is the difference between the endgame being reasoning and being a grind.
3. **Your own remaining fleet**, same strip on your board.
4. **Shots fired.** Your running count, because that is the score (§2.5) and a player who does not know the score cannot chase a personal best.
5. **The last shot**, marked distinctly for one turn on both boards. Coming back to an async match after four hours, "what happened while I was gone" is the first question, and it must be answerable without reading a log.
6. **The turn deadline**, when it is inside 6 hours. Not before — a countdown from 24 hours is noise.

## 8.4 Colour is never the only channel

[`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13 flags that Snake identifies players by colour alone, "a problem for ~8% of men". Sea Battle's hit/miss distinction is the same trap and it is the most important read in the game.

**Hit and miss differ in shape and fill before they differ in colour**: miss is a small hollow ring, hit is a large filled mark with a scorch. Rendered in greyscale the board must still be readable. That is the test, and it should be run as an actual screenshot in greyscale before the game ships.

---

# 9. Motion and feel

Durations and curves, per the "be specific" rule. All of it must be behind the reduce-motion switch that does not exist yet ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13, open question O13) — with reduce-motion on, every animation below collapses to a 120 ms cross-fade and the shell travel is skipped entirely.

| Moment | Motion | Duration | Curve |
|---|---|---|---|
| Reticle snaps to cell | Scale 1.15 → 1.0, opacity 0 → 1 | 140 ms | `spring(response: 0.22, damping: 0.7)` |
| Reticle drags | Follows finger, snaps to cell centres | — | Position spring, `response: 0.12` |
| FIRE pressed | Button scale 0.94, reticle flashes | 90 ms | `easeOut` |
| Shell travel | Reticle contracts to a point, brief hold | 380 ms | `easeIn` — accelerating reads as falling |
| **Miss** | Ring draws in, small ripple expands and fades | 260 ms | ring `easeOut`, ripple `easeOut` over 420 ms |
| **Hit** | Scorch punches in at scale 1.4 → 1.0, 2 px screen shake | 200 ms | `spring(response: 0.18, damping: 0.55)` |
| **Sunk** | 120 ms hold, then outline draws cell to cell, then name fades in | 120 + 380 + 200 ms | outline `easeInOut`, staggered 60 ms per cell |
| Turn passes | Board emphasis cross-fades, strip lifts | 320 ms | `easeInOut` |
| Board swap (tap strip) | Shared-element scale and position | 320 ms | `spring(response: 0.34, damping: 0.82)` |
| Match end | Loser's remaining ships fade in over their board | 600 ms, staggered 80 ms | `easeOut` |

Three notes on the choices.

**The 380 ms shell travel is load-bearing, not decoration.** It is the window the server's answer arrives in (§3.3), which is what lets the game feel instant while being fully round-tripped. It is also the suspense — the beat between committing and knowing is the emotional content of a turn. If the frame arrives in 40 ms, the animation still runs its full 380 ms; the result is *revealed* at the end of it either way, so the game feels identical on a fast and a slow connection. That is a deliberate choice to trade 340 ms of latency for consistency, and it is the opposite of the choice Snake makes, correctly, for a game where reaction time is the skill.

**The 120 ms hold before a sunk reveal** is the same trick as the crowd reaction being delayed 120 ms behind the wicket in [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.1: "a real crowd reacts *after* the event — simultaneous playback reads as one mushy noise". A sink is a hit plus a consequence, and the consequence must land second or it reads as one event.

**Screen shake is 2 px and only on a hit.** [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13 notes hitstop and shake shipped in Snake with no opt-out. Do not repeat it: 2 px, hit only, and off under reduce-motion.

---

# 10. Sound

Inherits [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) entirely. New entry in [`GameAudio.swift:282`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L282)'s `soundNames(for:)` and its Android twin.

## 10.1 The shared catch sound

> **The catch moment in Sea Battle is: one of *your* ships is sunk.**

Not a hit on your ship — a hit is damage, and the vocabulary rule is that `catch` means "your attempt was intercepted or ended by the opponent" ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §3). A ship is an attempt that is now over.

Played **unmodified**, per the rule. No pitch offset. Layered, never replacing: your ship sinking is `catch.wav` **+** a low hull groan and water rush, exactly as cricket's wicket is `catch` + `wicket_timber` + a delayed roar.

## 10.2 The palette

Physical, not synthesised — the same reasoning as cricket and chalk. Sea Battle has real-world referents for everything.

| Event | Sound | Notes |
|---|---|---|
| Reticle moves a cell | `tick` (existing synth UI tick) | Very quiet. Fires up to 20× in one drag, so anything with a tail becomes a rattle |
| FIRE committed | `fire_launch.wav` | A short compressed thump. Dry, no tail — the tail is the travel silence |
| Shell travel | *silence* | Deliberate. 380 ms of nothing is the suspense, and a whistle would be cartoonish |
| **Miss** | `splash.wav` | Water, ~340 ms, soft. Anticlimactic on purpose — a miss should deflate, like cricket's dot ball |
| **Hit** | `hit_metal.wav` | Metal impact + a short debris tail, ~420 ms |
| **You sink theirs** | `hit_metal` + `sink_groan.wav` at +180 ms | Groan is long (~1.2 s) and low. The one triumphant sound in the game |
| **They sink yours** | **`catch.wav`** + `sink_groan.wav` at +180 ms | §10.1 |
| Turn arrives (app open) | `your_turn.wav` | Soft, single, non-urgent. It will be heard hundreds of times |
| Placement: ship snaps | `place_thud.wav` | Short, woody |
| Placement: illegal | `error` (existing) | — |
| Match win / loss | Existing stingers | — |

**Three variants of `splash` and `hit_metal`**, chosen at random with the existing ±4% varispeed. A match contains 40–90 of these and [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.3 makes exactly this argument for chalk: without variation "it becomes machine-like by move four."

**Mono, always.** [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §6.6: a stereo asset on the mono-wired bus is a hard AVAudioEngine crash. Highest-risk line in that document and it applies here unchanged.

## 10.3 Ambience

A very low harbour bed — distant water, faint wind, ~−30 LUFS — on `loopVoice`, the dedicated path built for Snake's `boost_loop`. Optional and last; the crowd bed in cricket earns its cost because cricket is *about* atmosphere. Sea Battle is about silence between shots, and the bed exists only so the silence does not read as the audio being broken. **Cap it at 20 s, AAC mono 64 kbps**, per §7 of the sound doc, and register it with `release(for:)` on match exit.

---

# 11. Bots

The standard to match is [`RpsBot.swift`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift), which refuses to fake a scale: "against a truly random opponent, RPS has no skill... a difficulty slider over it would be a lie" ([`RpsBot.swift:7-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L7-L21)). The anti-pattern is Snake, where difficulty maps to **bot count only** ([`SNAKE.md`](../SNAKE.md) §3.4) so "hard" means more opponents of identical ability.

Sea Battle is the happy case: **it has a genuine, well-understood skill gradient, and every level of it is a different algorithm rather than the same algorithm with a knob.**

## 11.1 What difficulty varies

Two independent axes, both moving with `skill` (0.0–1.0), matching the continuous-slider convention the other bots use.

**Axis 1 — targeting.**

| Band | Algorithm | Expected shots to win |
|---|---|---|
| 0.0–0.25 | Uniform random over unfired cells. No hunt at all — a hit is not followed up | ~95 |
| 0.25–0.5 | Random search, then **hunt**: on a hit, queue the four orthogonal neighbours | ~65 |
| 0.5–0.75 | **Parity** search (only cells where `(x+y) % 2 === 0`, since the smallest ship is 2 long and cannot hide in one parity class) + hunt + **line-lock**: after two collinear hits, extend along that line and stop probing perpendicular | ~52 |
| 0.75–1.0 | **Probability density.** For every remaining ship, count every legal placement consistent with all known hits, misses and sinks; fire at the cell appearing in the most placements | ~42 |

Between bands the bot plays the higher algorithm with probability `skill`, the lower otherwise — the same construction `RpsBot.chooseThrow` uses ("at `skill` probability, plays the counter... otherwise it throws at random", [`RpsBot.swift:50-51`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L50-L51)). This makes the scale continuous instead of four steps, and it makes a mid-skill bot feel *inconsistent* rather than *uniformly mediocre*, which is much closer to how a human plays.

**Axis 2 — its own placement.** Weak bots place uniformly at random, which clusters and touches edges. Strong bots reject placements that are statistically easy to find: no ship wholly on an edge row, at most two ships adjacent, and a bias away from the centre 4×4 (which is where the density algorithm — and most humans — look first). This matters more than it sounds. Half of losing to a good Battleship player is that their fleet was hard to find.

## 11.2 What the top of the scale can and cannot do

Stated honestly, in the register [`RpsBot.swift`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift) sets.

**It can:** finish in ~42 shots against an average human placement, which is close to the practical optimum for a solver that sees only hits and misses. It will reliably beat a casual player and will beat most experienced ones.

**It cannot see your ships.** The density solver is computed from public information only — the same `shots`, `results` and `sunk` arrays any player has. It is not consulting the fleet.

**It is not unbeatable, and it cannot be made unbeatable.** Sea Battle has irreducible variance: against a genuinely awkward placement even a perfect solver needs ~40 shots, and a lucky human can win in the mid-20s. A player who beats it should be told they beat a strong opponent, not congratulated on beating a cheat. This is the same honesty [`RpsBot.swift:19-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L19-L21) insists on: "skill 1.0 → punishes any pattern in your play, but still cannot beat a truly random human — which is correct, because nothing can."

**It never re-rolls its fleet.** The temptation with a hidden-state bot is to leave the fleet undetermined and materialise ships away from incoming fire. That is cheating, it is undetectable, and it would poison the one thing this game has: the belief that the board is fixed and you are finding it. The bot commits a fleet at match start and lives with it.

## 11.3 Where the bot runs

Client-side, like [`CricketBot.swift`](../../../apps/ios/Voiid/Voiid/Games/CricketBot.swift) and [`RpsBot.swift`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift), for practice mode. Two consequences worth stating: the density solver runs on the phone (it is ~100 board evaluations per turn — trivial), and practice results go to [`BotScoreStore`](../../../apps/ios/Voiid/Voiid/Games/BotScoreStore.swift), not to `game_match_results`.

The bot must also be **thinking-time delayed**: 600–1400 ms, randomised. An instant answer reads as a lookup table and destroys the fiction. This is presentation, not fairness, and it should be stated in the code so nobody later "optimises" it away.

---

# 12. Progression and retention — R3

## 12.1 The floor

All four requirements from [`README.md`](./README.md) §1.6 ship with the game, not after it. [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) documents four shipped games with none of them; that is the mistake this folder exists to not repeat.

1. **Rematch**, opponent's name on the button
2. **Post-match summary** — shots fired, best ship, personal best if it was one, head-to-head change
3. **Head-to-head record**, shown before the first shot and after the last
4. **Share result into the chat it was arranged in**

## 12.2 The specific hook

**Async play, and the notification is the hook.**

Not "it's fun". The concrete mechanism: a Sea Battle match creates a *legitimate, welcome reason to send someone a notification several times a day, for days.* That is normally a thing an app has to earn and usually abuses. Here the player asked for it, it carries real information, and the response is one tap.

That is the whole argument, and it is why this game is first. **A game inside a messenger that does not create a reason to message someone is wasting its only structural advantage** ([`README.md`](./README.md) §1.6). Sea Battle does not merely permit that — it *is* that.

The second-order effect is the one that matters: a match in progress is a standing appointment. You open the app to fire a shot and you are in a conversation. Snake gives you a three-minute session and no reason to return; a Sea Battle match gives you eight small reasons over two days.

## 12.3 How it uses the fact that this is a messenger

- **Turn notifications** are the core loop. They need a carrier that does not exist yet (open question O2): the invite rides the E2EE message pipe and gets wake and push for free ([`GAMES.md`](../../GAMES.md) §3), but a turn is not a message. **Recommendation: a system message in the arranging thread**, which reuses the entire existing pipe, puts the game where the conversation is, and makes the match visible in the chat list — which is where a returning user actually looks. A silent new push type would be architecturally cleaner and socially worse.
- **Share a shot, not just a result.** "D7. Sunk your Cruiser." dropped into the thread as a rich preview. This is the trash talk, and trash talk is the retention mechanism in every game like this. It is one card renderer over data already on the wire.
- **The board is a conversation piece.** A finished board — 100 cells of scorch and rings — is a genuinely good image to share. Render it as a shareable card at match end.

## 12.4 What the first 30 seconds feel like

Someone who has never played this and does not know the rules:

- **0–3 s.** Accept the invite. Their board is already on screen with a fleet on it, placed at random. **You are never shown an empty board and asked to fill it** — that is a decision before the player has committed, which [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §9 names as the flow mistake the whole games surface makes.
- **3–8 s.** A one-line hint: *"Your ships are placed. Drag to move them, or tap READY."* Most people tap READY. Some discover placement is a thing they care about, which is exactly the right order.
- **8–12 s.** The opponent's board fills the screen. The reticle is already sitting on a cell. FIRE is lit.
- **12–15 s.** Fire. Splash. "Miss." No explanation needed — everyone in the world knows this game, and the ones who do not just learned it.
- **15–30 s.** They fire back. Maybe it hits your ship, and your ship visibly scorches. Now the stakes are legible.

The game explains itself, which is the property [`CRICKET.md`](../CRICKET.md) §2.1 identifies as the single biggest thing hand cricket lacks — "a player who has never played hand cricket picks a number, sees WICKET, and has no idea why."

Still ship a `?` rules sheet, one screen, for adjacency and no-extra-turn-on-hit. Those are the two house rules a returning Battleship player will assume differently.

## 12.5 What someone with 50 matches is chasing

Honest answer: **the head-to-head record against one specific person**, and nothing else on this list comes close.

Supporting it:

- **Shots-to-win personal best.** A real, hard, improvable number with a known floor of 17. Sub-40 is a genuine achievement.
- **The rivalry, per opponent.** "You 7 — Priya 5" over months. [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §4: "a global leaderboard is abstract; a running score against a specific friend is a rivalry, and rivalries are what make people open the tab."
- **Placement metagame.** After 50 matches against the same person you are placing ships to defeat *their* habits, and they are hunting yours. Nothing in the code enables this — it emerges — but the game must not flatten it. This is the strongest reason not to force the Random button and not to forbid adjacency.
- **Fleet-hunt stats:** average shots per sink, best opening, longest hit streak. Cheap, all derivable from `shots`/`results` at match end.

What is deliberately **not** here: XP, levels, unlocks, cosmetics. Sea Battle's depth is the opponent. Bolting a progress bar onto it would be the kind of retention that works for a month and then reads as a slot machine.

---

# 13. Failure and edge cases

## 13.1 Disconnect

Nothing happens, and that is the design. There is no live connection requirement. A player can close the app between every single shot and the match is unaffected — which is precisely why this game is the right first async game.

The only requirement is that the match **survives**, and today it does not: [`redis.ts:27`](../../../backend/games/src/redis.ts#L27) gives live state a one-hour TTL. **Sea Battle is not buildable as designed until [`README.md`](./README.md) §2.2's `game_match_state` table exists.** Redis stays the hot path; Postgres is the fallback `loadMatch` reads on a miss.

## 13.2 AFK and the turn deadline

Needs the deadline sweeper ([`README.md`](./README.md) §2.3), the Redis sorted set `games:deadlines` plus the two optional interface methods.

**Sea Battle's values:**

| Situation | Deadline | On expiry |
|---|---|---|
| Placement | **24 h** | Both unplaced → abandon, no winner. One placed → the placed player wins by walkover |
| A turn, normal | **24 h** | Auto-forfeit. Opponent wins |
| A turn, after a warning | 24 h + **6 h grace** | — |
| Both players active in the last 2 min | **90 s** soft timer | Visual only. **Never forfeits** |

Two decisions in that table.

**24 hours, not 60 seconds.** [`GAMES.md`](../../GAMES.md) §7 and [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §6 both propose "60 s to move or forfeit". That number is right for a live turn-based game and **catastrophic** for this one — it would forfeit every async match on the first turn, which is every match this game is designed for. The 60 s figure should be understood as per-game, not global, and Sea Battle's is 24 h.

**A warning at 18 h**, delivered as a notification, then 6 hours of grace. Forfeiting someone who has not been told is a bug in the social contract even when it is correct in the rules.

**The soft 90 s timer** is presentation only. When both players have acted inside 2 minutes the match is effectively live, and a visible timer adds pressure that is good for a live game — but it must never forfeit, because "both were live and then one got a phone call" is not abandonment. Two clocks with different consequences would be confusing; one clock with one consequence, plus an advisory indicator, is not.

Idempotency: the timeout frame carries the `moveCount` it was scheduled against and is dropped if it does not match (§4.2). Without it, a duplicated sweeper delivery can forfeit a player who has already moved.

## 13.3 Rejoin

The normal case, not the exception — every turn in an async match begins with a cold start.

- `handleJoin` already handles rejoin: "a rejoin after that is a genuine resync and still gets a frame" ([`index.ts:355-359`](../../../backend/games/src/index.ts#L355-L359)).
- The rejoining player must get **their own** frame via `serializeForPlayer` (§4.3). This is exactly where the "the client remembers what it placed" workaround collapses: after a reinstall, a second device, or a cold start from a push, the client remembers nothing. **The fleet must come from the server or the game is broken for its primary use case.**
- No delta reconciliation. Every frame is complete.

## 13.4 Forfeit and resignation

Distinct outcomes, recorded distinctly:

| Outcome | `winnerId` | `scores` | Head-to-head |
|---|---|---|---|
| Normal win | winner | shots fired, both | W/L |
| Resignation | opponent | shots so far | W/L, flagged as a resignation |
| Timeout forfeit | opponent | shots so far | W/L, flagged as a timeout |
| Both AFK in placement | `null` | `{}` | Not counted |
| Abandoned | `null` | `{}` | Not counted |

A resignation is a loss and must count as one; a match nobody played is not a loss and must not. Conflating them makes the head-to-head record — the game's main retention mechanism (§12.5) — untrustworthy, and a record nobody trusts is worse than no record.

## 13.5 Ties

Impossible. The match ends on the shot that sinks the last ship, and only one player can fire it. `winnerId: null` means abandonment here, never a draw.

## 13.6 Both players fire simultaneously

Cannot happen — `turn` is checked inside `applyInput` and the runtime processes frames serially off one Redis subscription ([`index.ts:479`](../../../backend/games/src/index.ts#L479)). The second frame arrives after the first has already advanced `turn`, and is rejected. No locking needed.

## 13.7 The engine restarts mid-match

- **Turn-based, so no tick loop** is lost — nothing to restart.
- State reloads from Redis, or from the durable table on a TTL miss (§13.1).
- **The secret must reload with it.** §4.4: a lost secret in the `firing` phase is fatal and must abandon loudly rather than continue wrongly. Store `state` and `secret` in the same row, written in the same statement.
- Deadlines survive: `games:deadlines` is a Redis sorted set, and `deadlineAt` is also in `serialize()` so it is reconstructible if the set is lost.

---

# 14. Build plan

Each phase independently shippable, in the sense that stopping after any of them leaves something coherent.

## Phase 0 — shared infrastructure *(not Sea Battle work; blocks it entirely)*

Build step 0 from [`README.md`](./README.md) §3. Three changes, one PR:

1. `serializeForPlayer` + `broadcast()` taking the engine instead of a payload
2. `game_match_state` table + `loadMatch` fallback, turn-based games only
3. `games:deadlines` sorted set + the 1 s sweeper + `deadlineAt`/`onTimeout`

**Ship it against an existing game to prove it.** Tic Tac Toe with a 24 h deadline exercises the sweeper and the durable table with no new rules code. Do this before writing a line of Sea Battle, so the infrastructure is debugged separately from the game.

## Phase 1 — engine, headless

`engine/seabattle/` + registry entry + tests. No client.

[`snake.test.ts`](../../../backend/games/src/engine/snake/snake.test.ts) is 396 lines and, per [`SNAKE.md`](../SNAKE.md) §1, Snake is "the only game with real coverage". Sea Battle should be the second, and it is the easiest game in the app to test properly because every rule is discrete. Minimum: placement validation (each rejection reason separately), turn alternation, no-refire, hit/sunk/win detection, **a full serialize → restore → serialize round-trip asserting byte equality** (the test that catches the class of bug [`GameEngine.ts:60-64`](../../../backend/games/src/engine/GameEngine.ts#L60-L64) documents), and a restore-without-secret abandoning rather than continuing.

Shippable in the sense that it is verifiable and reviewable alone.

## Phase 2 — iOS practice mode

Board renderer, placement, firing, the bot at all four bands, sound, motion. **No networking.** This is the fastest path to knowing whether the game is any good, and it is a real shippable feature on its own — practice mode is how Snake and cricket are most-played today.

## Phase 3 — iOS online

Wire to `GamesEngine`. Invite, join, `serializeForPlayer`, reconnect state, deadlines. First real async match.

## Phase 4 — Android parity

Both phases 2 and 3, ported. Per [`ANDROID_IOS_PARITY.md`](../../ANDROID_IOS_PARITY.md), iOS is the reference. **Port the constants literally** — [`SNAKE.md`](../SNAKE.md) §2.4 records that the two Snake renderers "were ported line-for-line including the bug", and warns that "divergent constants here is how two builds of the same game end up feeling different."

## Phase 5 — retention

Post-match summary, rematch, head-to-head, share-to-chat, turn notifications. **Not optional and not "later"** (§12.1) — but sequenced last because it is the phase that is genuinely shared with every other game and should be built as shared surface rather than as Sea Battle screens.

## Phase 6 — polish

Shareable board image, fleet stats, harbour ambience, greyscale accessibility pass, `?` rules sheet.

---

# 15. Open questions

Things needing the user's decision. Honest about which are real.

1. **Is async play in scope at all?** *(blocking, and it is question 1 in [`README.md`](./README.md) §5)* If matches are expected to be single-sitting, Sea Battle loses most of its argument and should be re-evaluated against Air Hockey. Everything here assumes yes.

2. **What carries a "your turn" notification?** *(blocking)* Recommendation: a system message in the arranging thread — reuses the E2EE pipe, gets wake and push for free, and puts the match in the chat list. The alternative is a new push type, which is cleaner architecturally and worse socially.

3. **Sunk-ship announcements on or off?** Recommendation: **on** (§2.4). It is what makes the endgame deduction rather than grind, and it makes the game legible to a newcomer.

4. **Extra shot on a hit?** Recommendation: **no** (§2.3), because of what a hit streak does to async notification cadence. This is the house rule most likely to be argued with, and the one most likely to be wrong if the game turns out to be played mostly live. **Revisit after the first 100 real matches** — the data to decide is whether matches are actually async.

5. **Is Sea Battle on the global leaderboard?** It cannot be until score direction is representable (§2.5), because its score is lower-is-better and the leaderboard sorts descending. Options: add a direction column, store `100 - shots`, or keep Sea Battle off the global board and only in head-to-head. Recommendation: **the last one** — the global leaderboard is the weakest retention surface in the app anyway (§12.5).

6. **Do bot matches count for anything?** Cross-cutting (question 10 in [`README.md`](./README.md) §5). If they feed head-to-head or the global leaderboard, the public seed in §4.5 has to move to the secret channel. Recommendation: they do not count, as today.

7. **Board size — is 10×10 right for a phone?** 8×8 with a 4-ship fleet would give 41 pt cells, above the Android minimum and near Apple's. It is a materially better fit for the hardware and a materially worse fit for everyone's expectations of the game. Recommendation: **10×10 with the loupe** (§7.2), and treat this as revisitable if playtesting shows mis-taps are still happening.

8. **Reduce-motion.** Every §9 duration assumes a switch that does not exist ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13). Not Sea Battle's to build, but Sea Battle should not ship without it.

---

# 16. What was built

Phases 0 and 1 of §14. The infrastructure and the headless engine exist; no client does. Recorded here rather than left implicit, so the next person reads what is true rather than what was planned.

## 16.1 Phase 0 — the three blockers, built against the shipped games first

All three are shared surface, and none of them mentions Sea Battle.

| Change | Where | Note |
|---|---|---|
| `serializeForPlayer()` | [`GameEngine.ts`](../../../backend/games/src/engine/GameEngine.ts), [`broadcast()`](../../../backend/games/src/index.ts) | `broadcast()` now takes the engine and builds one frame per recipient **only** when the method exists. Every shipped game takes the old shared-frame path byte for byte |
| Durable turn-based state | [`040_games_durable_turn_state.sql`](../../../database/migrations/040_games_durable_turn_state.sql), [`matches.ts`](../../../backend/games/src/matches.ts) | `state` and `secret` in one row written in one statement, per §4.4. Redis stays the hot path and is rehydrated from the row on a miss |
| Deadline sweeper | [`games:deadlines`](../../../backend/games/src/redis.ts), [`matches.ts`](../../../backend/games/src/matches.ts), [`index.ts`](../../../backend/games/src/index.ts) | One sorted set, one 1s interval for the whole process, and the two optional interface methods |

The engine-facing half of all three is optional, and [`registry.test.ts`](../../../backend/games/src/engine/registry.test.ts) now asserts that Tic Tac Toe, RPS, Cricket and Snake acquire **none** of them — a `serializeForPlayer` appearing on a shipped game would silently switch it to per-recipient frames, and a `deadlineAt` would put it on the sweeper's clock.

`Rng` moved from [`snake/geometry.ts`](../../../backend/games/src/engine/snake/geometry.ts) to [`engine/rng.ts`](../../../backend/games/src/engine/rng.ts) on its second consumer, as §4.5 anticipated. geometry.ts re-exports it, so no shipped Snake code changed.

## 16.2 Phase 1 — the engine

[`engine/seabattle/`](../../../backend/games/src/engine/seabattle/): `fleet.ts` for the pure board rules, `index.ts` for the engine, and a test suite covering every placement rejection reason separately, turn alternation, no-refire, hit/sunk/win, resignation, all four deadline outcomes, the serialize→restore→serialize byte-equality round trip, and restore-without-secret abandoning rather than continuing.

Rules are as specified: 10×10, the Milton Bradley fleet, ships may touch, one shot per turn with no extra shot on a hit, sinks announced, score is shots fired, 24-hour deadlines.

## 16.3 Three departures from this doc

Stated rather than quietly absorbed.

1. **§14 says "ship phase 0 against Tic Tac Toe with a 24h deadline to prove it".** It was not. Tic Tac Toe acquiring a deadline is a visible behaviour change to a shipped game — a match that hangs today would start forfeiting people — and that is a product decision, not a debugging convenience. The infrastructure is instead proven by the regression test asserting the shipped games are untouched, plus Sea Battle exercising all three paths. **The proving step is still worth doing before real async traffic**, and it needs the call on whether Tic Tac Toe should forfeit at all.

2. **`loadMatch`'s Postgres fallback is gated on a Redis marker key**, which this doc does not describe. Several callers invoke `loadMatch` speculatively for matches that may legitimately not exist — an input for an expired arcade match, a tick after a match finished elsewhere — and each of those cost one null Redis read before. Falling through to the durable table unconditionally would turn every one of them into a three-table join on paths that run at tick rate. A durable save now also writes a small marker key that outlives the state key, and only its presence admits the query.

3. **`endedBy` is in `serialize()`**, which §4.2's field list does not have. §13.4 requires resignation, timeout forfeit and abandonment to be recorded *distinctly* — the head-to-head has to show a resignation as a loss and an unplayed match as nothing — and `winnerId` alone cannot express the difference between "won by walkover" and "won by playing". Without it the distinction §13.4 calls load-bearing is not representable in the state at all.

## 16.4 Phases 3 and 4 — both renderers, online

`SeaBattleView.swift` + `SeaBattleBoard.swift` + `SeaBattleSound.swift`, and their Kotlin twins. Both are dumb views over the games engine: no rules, no outcomes, and no computing whether a shot hit — the frame says, and the renderer draws.

The client's copy of the fleet rules exists only so placement can show a ship red before the drop. It is a mirror, not an authority, and it is tested as one: 14 cases in the Android JVM test target, the same table `seabattle.test.ts` asserts, plus a one-off differential run of the Swift copy against the TypeScript. Three implementations of one rule set is three chances to drift.

Built as specified: the two-board layout with emphasis following the turn, two-step FIRE commit (a 10x10 grid is ~33pt cells, below both platform minimums, and a mis-tap costs the match), Random-first placement, hit and miss differing in shape before colour, the fleet strip, the deadline shown only inside 6 hours, and `catch.wav` on your own ship sinking.

**Not built from §9:** the 380 ms shell travel, the sunk-ship outline draw-in, the board-swap shared-element transition, and screen shake. The motion table assumes a reduce-motion switch that still does not exist (§15 Q8), and shipping the animations before the opt-out would repeat exactly what CROSS_CUTTING.md §13 flags about Snake.

## 16.5 What is still open before this is playable

Nothing in §15 was decided by building this; those questions are unchanged. Concretely blocking a real match: **both renderers (phases 2-4), the "your turn" notification carrier (§15 Q2), and the retention floor (§12.1)**. The engine and its infrastructure are verifiable on their own, which is what phase 1 was for, but a game nobody can see is not a shipped game.

Also unverified:

- **Migrations 040 and 041 have not been applied to any database.** They are additive-only and follow the existing patterns, but Docker was not running locally, and applying them to the shared dev database is a deploy rather than a local step — the games catalog is server-side, so **Sea Battle does not appear in either app's game list until they run.** A push to `main` applies them via `deploy-dev.sh` and restarts the services.
- **The Android UI has not been seen.** It compiles and its rules tests pass; no emulator was running to render it.
- **The sound assets do not exist.** `fire_launch`, `splash_1..3`, `hit_metal_1..3`, `sink_groan`, `your_turn` and `place_thud` are registered in both `GameAudio` tables and referenced by `SeaBattleSound`. A missing buffer is a silent no-op on both platforms, so the game plays correctly and quietly until they are recorded.
