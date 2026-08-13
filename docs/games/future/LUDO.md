# Ludo

> **Status:** **phases 0, 1, 3, 4 and 5 built** — multi-seat lobbies, the engine, and both renderers online. Phase 2 (practice mode + bot), 6 (retention) and 7 (polish) are still design only. See §16.
> **Kind:** turn-based, 2–4 players. No `tickHz`.
> **Was blocked on:** multi-seat lobbies ([`README.md`](./README.md) §2.4) and the deadline sweeper (§2.3). **Both now exist** — the sweeper shipped with Sea Battle, the lobby work shipped here.
> **Reference implementations to read first:** [`tictactoe/index.ts`](../../../backend/games/src/engine/tictactoe/index.ts) for the turn model, [`cricket/index.ts`](../../../backend/games/src/engine/cricket/index.ts) for secret state and per-match options.

---

# 1. What the game is

Four tokens per player, a track around a cross-shaped board, a die. Roll a six to bring a token out of your yard, race around the board, land on an opponent to send them home, and get all your tokens up your home column. First player home wins.

## 1.1 Why it belongs in Voiid

Two arguments, and the first one is the whole reason this is on the list.

**It is the only game in the catalog with more than two seats, and the only one with a built-in audience.** Every shipped game is 1:1. Ludo is the game a group of four plays, and a messenger is where groups of four already are. The app has group conversations, a contact graph, and a notification pipe; what it does not have is any reason for four people to open it at the same time. Ludo is that reason.

**And it needs no explanation in this market.** Ludo is the most-played board game in India by a large margin, it is generational, and Ludo King is one of the most-downloaded games in the country. The rules are common knowledge. Nobody needs a tutorial, which is a property only Air Hockey otherwise has in this folder — and unlike Air Hockey, Ludo comes with an existing emotional relationship. People have opinions about Ludo.

## 1.2 The honest problem: length

**A classic four-player Ludo game runs 30–45 minutes.** That is a bad fit for a game played inside a chat app, and it is the single biggest design risk here — bigger than the lobby work, bigger than the rules.

It is not a fixable property of the rules; it is inherent to needing 4 tokens × ~57 squares of movement each with a 1/6 chance of even starting. Every implementation of Ludo has this problem and most ignore it.

We do not ignore it. **§2.7 makes the token count a match option and defaults four-player games to 2 tokens**, which brings a match to 12–18 minutes. That is a real change to a game people think they know, it is stated up front, and it is defended there.

## 1.3 Cost

Moderate. The engine is genuinely fiddly — Ludo has more edge cases than its reputation suggests (blocks, exact-entry, three-sixes, capture-on-safe, simultaneous home-column occupancy) and every one of them is a rule someone remembers differently. Budget the rules table in §2 being argued about.

The renderer is a board and 8–16 tokens with hop animations: comparable to [`CricketPitch`](../../../apps/ios/Voiid/Voiid/Games/CricketPitch.swift) (321 iOS / 394 Android), which [`CRICKET.md`](../CRICKET.md) §1 calls "the most produced visual in the turn-based set."

The real cost is **multi-seat lobbies**, and that cost is shared with two other games.

---

# 2. Rules as implemented

Ludo has more folk variants than any game in this folder. Every one below is decided with a reason, in the style of [`GAMES_HAND_CRICKET.md`](../../GAMES_HAND_CRICKET.md) §2 — the alternative is four players who each believe a different rule and one who believes they were cheated.

## 2.1 The board

Standard cross. Encoded as a **flat 52-square main track** plus per-player extensions, which is what makes the movement maths trivial and the state small.

| Element | Encoding |
|---|---|
| Main track | 52 squares, indices 0–51, shared by all players |
| Player `p`'s entry square | `p × 13` (0, 13, 26, 39) |
| Player `p`'s home-column entrance | `(p × 13 + 51) mod 52` — the square before their entry |
| Home column | 5 squares, private to `p` |
| Home | The final position |

A token's position is **one integer**:

| Value | Meaning |
|---|---|
| `-1` | In the yard |
| `0–51` | On the main track, absolute index |
| `100–104` | In the home column, `100 + step` |
| `200` | Home |

**Absolute track indices, not per-player relative ones.** Relative encoding makes "am I on the same square as an opponent?" a conversion at every comparison, and capture checks run against every opponent token on every move. One conversion at move time (`relative = (absolute - entry + 52) mod 52`) is cheaper and much harder to get wrong.

**Safe squares — the 8 starred squares:** the four entry squares (0, 13, 26, 39) and the four squares 8 ahead of each (8, 21, 34, 47). **No capture may occur on a safe square.**

## 2.2 Movement

- Roll a die, 1–6. Move one token by that many squares.
- **A 6 is required to move a token out of the yard**, and it places the token on your entry square.
- **Exact roll required to reach home.** A token 3 from home cannot move on a 5 — that move is illegal, and if no legal move exists the turn passes.
- **A token may not land on a square occupied by two or more of its own colour** (see blocks, §2.4).
- **If no legal move exists, the turn passes automatically.** The server detects this and advances without asking the client — a "you have no moves, tap to continue" prompt is a tap that changes nothing.

## 2.3 Extra turns

- **Roll a 6 → roll again.**
- **Capture an opponent → roll again.**
- **Get a token home → roll again.**
- **Three consecutive 6s → the turn is forfeited and the third 6 is not used.**

The three-sixes rule is not decoration. Without it a lucky streak is unbounded, and more practically it is the only thing preventing a modified or malfunctioning client from being handed an endless sequence of turns. It is a rule that also happens to be a safety property.

**Note that extra turns compose:** capturing with a 6 grants one extra turn, not two. The flag is boolean, not a counter — otherwise a good turn spirals.

## 2.4 Blocks — decided ON

**Two or more tokens of the same colour on one square form a block. Opponent tokens can neither land on nor pass it.**

This is the most-argued Ludo rule and the argument for including it is strategic depth: a block is the only *defensive* action in the game, and without it Ludo is pure racing with capture as a random tax. Blocks are what make position a decision.

The cost is real and must be bounded: a block parked on a chokepoint can stall an opponent indefinitely. Three things bound it:

1. **Blocks cannot form on safe squares.** Tokens may stack there (they are already safe) but such a stack does **not** block passage. This prevents the worst case — a permanent block on an entry square, which would lock a player out of the game entirely.
2. **The turn timer** (§13.2) means a stalled game still progresses.
3. **A blocking player must still move.** If their only legal move breaks the block, they must make it. There is no passing to preserve a block.

**Rejected alternative:** blocks off entirely. Simpler, faster, and it removes the only decision in the game that is not "which token do I advance". Ludo without blocks is a dice-rolling race, and the game is already close enough to that.

## 2.5 Capture

- Landing on a square containing **exactly one opponent token** sends that token to its yard (`-1`) and grants an extra turn.
- **No capture on a safe square** (§2.1).
- **No capture in a home column** — it is private.
- Landing on a square with **two or more** opponent tokens is illegal (that is a block, §2.4).
- **Capturing multiple tokens at once is impossible**, by construction: any square with 2+ opponent tokens is a block you cannot land on.

## 2.6 Winning

- A player finishes when **all their tokens are home**.
- **The match ends when the first player finishes.** Remaining players are ranked by tokens home, then by total distance travelled.

**Not "play on for second place."** Playing out a 4-player game after the winner is decided means two players continuing a game they cannot win, which is exactly the kind of dead time §1.2 is trying to remove. Placement is recorded honestly for everyone from the state at the moment of the win.

`GameOutcome.scores` is **tokens home** (0–4), so higher is better and it drops onto the existing leaderboard. `winnerId` is the finisher. `winnerId: null` is abandonment only — Ludo cannot draw.

## 2.7 Token count — the length decision

**A match option, `tokens ∈ {2, 3, 4}`**, validated and clamped by the engine exactly as cricket clamps its over count ([`cricket/index.ts:226-229`](../../../backend/games/src/engine/cricket/index.ts#L226-L229)). Options are untrusted ([`GameEngine.ts:110-115`](../../../backend/games/src/engine/GameEngine.ts#L110-L115)).

**Defaults: 4 tokens for 2 players, 2 tokens for 3–4 players.**

| Players | Tokens | Typical length |
|---|---|---|
| 2 | 4 | 15–22 min |
| 2 | 2 | 7–10 min |
| 3 | 2 | 10–15 min |
| 4 | 2 | 12–18 min |
| 4 | 4 | **30–45 min** |

The defaults are chosen so that **no default configuration exceeds ~20 minutes.** Four-token four-player Ludo remains available for people who want the full game and know what they are asking for; it is simply not what a player gets by tapping through.

This will be controversial with players who consider 4 tokens to be *the* rule. The counter-argument is the one [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §9 makes about the whole games surface: adjustments belong after the default, not before it, and the default should be the version most people will finish. **An unfinished 45-minute Ludo game is worth less than a finished 15-minute one**, and abandonment mid-match is the failure mode this game is most exposed to.

## 2.8 Rules deliberately excluded

| Variant rule | Excluded because |
|---|---|
| Roll 1 or 6 to enter | Doubles entry rate and makes the opening chaotic rather than tense |
| Capture on any square (no safes) | Removes all safety; a token can be sent home one square from its column, which is the most-quit-inducing moment in any Ludo implementation |
| Doubling / stacking movement (a stack moves as one) | Two tokens moving as one halves the decisions and makes blocks strictly dominant |
| Bonus 20 for capture / 10 for home | A points layer on a race game. The race is the score |
| Must capture if able | Removes the only interesting choice capture creates |

---

# 3. Network model — R2

## 3.1 Pattern

Fourth row of [`GAMES.md`](../../GAMES.md) §4: pure turn-based, one `game_input` per action, one `game_state` broadcast in response. No `tickHz`, no loop, no per-match cost while idle ([`GameEngine.ts:8-13`](../../../backend/games/src/engine/GameEngine.ts#L8-L13)).

**No render clock, no interpolation, no prediction. The [`SNAKE.md`](../SNAKE.md) §2 stutter class cannot occur** — there is no continuously advancing clock to re-anchor. Every animation is triggered by an arriving frame, not sampled from a timeline.

## 3.2 Rate and payload

Turn-based default: 60 inputs/minute ([`index.ts:29`](../../../backend/games/src/index.ts#L29), via [`limitFor`](../../../backend/games/src/index.ts#L45-L48)). A Ludo turn is at most 2 inputs (roll, move) and a fast player takes maybe 6 turns a minute. Generous headroom.

State is ~400 bytes for 4 players (§4.3). **Broadcast is `N` publishes, one per player** ([`index.ts:79-81`](../../../backend/games/src/index.ts#L79-L81)) — Ludo is the first game to make that loop run four times instead of two, which is worth noting and is not worth worrying about at these sizes.

No `serializeForWire` (§4.4), no `serializeForPlayer` (§4.5).

## 3.3 The two-step turn, and why it is two steps

```
{ roll: true }        → server rolls, broadcasts the die face
{ move: tokenIndex }  → server validates and applies
```

Not one frame. The die face must be **broadcast and visible before the move is chosen**, for three reasons:

1. **It is the drama.** The die is the moment. Collapsing roll-and-move into one input means the other players see a token move and a number appear simultaneously, which reads as a result rather than as a roll.
2. **It bounds the client's knowledge.** A client that sent "move token 2" and received the roll as part of the response would learn the die and the outcome at once, and the server would have to decide the legality of a move against a roll the client had not seen. Two steps means the die is public before any move is legal.
3. **Auto-move needs it.** With 0 or 1 legal moves the server acts immediately (§3.4), which is only expressible if rolling is its own step.

**Both steps are non-silent** — `silent` is left unset, per [`GameEngine.ts:38-40`](../../../backend/games/src/engine/GameEngine.ts#L38-L40): "a move IS the state change, so it must go out immediately."

## 3.4 Auto-actions

The server acts without asking whenever there is nothing to ask:

- **Zero legal moves** → the turn passes automatically, in the same frame as the roll. The other players see the roll and the pass together.
- **Exactly one legal move** → it is played automatically, after the roll frame. **Two frames, ~700 ms apart**, so the roll is seen before its consequence.
- **Three consecutive 6s** → turn forfeited in the roll frame.

This removes the single most common source of dead time in Ludo implementations: a prompt to confirm the only thing that can happen.

## 3.5 What happens on a 3-second network stall

- **Not your turn:** nothing. The board is static.
- **Your turn, before rolling:** nothing. You are looking at a static board and the clock you are on is 45 seconds (§13.2).
- **You rolled during the stall:** the die animation completes and lands on a "waiting" state with a spinner after 800 ms. No error. The frame arrives and resolves.
- **The stall outlasts your turn timer:** the server auto-plays for you (§13.2) and the resulting frame arrives on reconnect. You see what happened. This is strictly better than a forfeit and it is why the timeout auto-plays rather than skipping.
- **Socket genuinely down:** the "Reconnecting…" state ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §7). **Ludo needs it visibly** — with four players, a frozen board is ambiguous between "my connection died" and "Priya is thinking", and those need to look different.
- **On reconnect:** full state frame, nothing to reconcile.

## 3.6 Is Ludo async?

**No, and this is a deliberate scoping decision.**

Sea Battle and Chess are naturally async because a turn is one decision and there are two players. Ludo has 2–4 players and a turn that is often two interactions, so a fully async four-player Ludo means each player waits for three others; a game of 60 turns becomes a game of days, with three people blocked on whoever is slowest.

**Ludo is designed as a live game**: everyone present, 45-second turns, ~15 minutes. The lobby waits for all seats, and the match is expected to be played in one sitting.

**Exception: 2-player Ludo may be played async**, on the same 24-hour deadline as Sea Battle, because with two players it has the same shape. Worth having — it is free once the deadline sweeper exists — but it is not the primary mode and the UI should not lead with it.

---

# 4. Engine design — R1

Folder: `backend/games/src/engine/ludo/`.

## 4.1 Interface surface

| Method | Present | Why |
|---|---|---|
| `applyInput` | yes | `roll` and `move` |
| `tick` | **no** | Turn-based |
| `serialize` | yes | Complete public state |
| `serializeForWire` | **no** | §4.4 |
| `serializeForPlayer` | **no** | §4.5 |
| `serializeSecret` | **yes** | **The RNG state. This is the game's one critical secret** |
| `deadlineAt` / `onTimeout` | **yes** | 45 s turn timer, §13.2 |
| `isFinished` | yes | — |

## 4.2 `applyInput`

```ts
{ roll: true }
{ move: number }   // token index, 0..tokens-1
```

**Roll validation:** it is your turn; `phase === 'awaitingRoll'`; not finished.

**Move validation:** it is your turn; `phase === 'awaitingMove'`; `move` is an integer in range; **and the move is in the set of legal moves the server itself computed.** The server does not re-derive legality from the client's claim — it computes `legalMoves()` when the roll lands, stores it, and checks membership. That is one code path for "what can this player do", used by validation, by auto-move, by timeout auto-play, and by the bot. Four consumers of one function cannot disagree about the rules.

Anything else: `accepted: false`, one Redis read, no broadcast ([`GameEngine.ts:29-33`](../../../backend/games/src/engine/GameEngine.ts#L29-L33)).

## 4.3 `serialize()` — field by field

```ts
{
  players: string[],
  tokensPerPlayer: number,
  tokens: number[][],        // [seat][token] → position encoding (§2.1)
  turn: number,              // seat to act
  phase: 'awaitingRoll' | 'awaitingMove' | 'done',
  die: number | null,        // the rolled face, once rolled
  legal: number[],           // token indices legally movable with `die`
  sixStreak: number,
  extraTurn: boolean,
  rollsThisTurn: number,
  finishedOrder: number[],   // seats in finishing order
  moveCount: number,
  deadlineAt: number | null,
  lastMove: { seat, token, from, to, captured: [seat, token] | null } | null,
  finished: boolean,
  winnerUserId: string | null,
}
```

- **`players`** — seat order; index is the seat and also the colour and the entry square (§2.1). Lose it and every token's home column is wrong.
- **`tokensPerPlayer`** — from options, clamped (§2.7). Serialized so the renderer never assumes 4 and so a restore does not silently resurrect two tokens.
- **`tokens`** — the board. The entire game.
- **`turn`** — seat to act. Lose it and the restored match hands the turn to seat 0, which in a 4-player game is a free turn for one player at every restart.
- **`phase`** — `awaitingRoll` vs `awaitingMove`. **The field a naive design loses**, and losing it is a real exploit: a restore that defaults to `awaitingRoll` lets a player who has already rolled a 2 roll again for a better number. The serialize/restore round-trip happens **on every input** ([`index.ts:279`](../../../backend/games/src/index.ts#L279)), so this is not a rare restart case.
- **`die`** — the rolled face. Public once rolled, and it must be, or the client cannot show it. Lose it and the pending move has no number behind it.
- **`legal`** — the precomputed legal token set (§4.2). Stored rather than derived so validation, auto-move, timeout and the client's highlight all read the same answer. Deriving it in three places is how three subtly different rule sets appear.
- **`sixStreak`** — consecutive 6s this turn. Lose it and the three-sixes rule never fires, which removes the only bound on turn length (§2.3).
- **`extraTurn`** — whether the current player rolls again. Lose it and every extra turn is silently forfeited, which changes the game's balance completely and would be nearly invisible in testing.
- **`rollsThisTurn`** — diagnostic and a hard safety bound; a turn is force-ended past 8 rolls regardless.
- **`finishedOrder`** — placement. Lose it and the results row cannot rank anyone.
- **`moveCount`** — monotonic; the idempotency key for the deadline sweeper (§13.2). A stale timeout frame carrying an old `moveCount` is dropped, so a duplicate delivery cannot auto-play twice.
- **`deadlineAt`** — epoch ms, serialized rather than recomputed. Recomputing from "now" on restore would hand an AFK player a fresh 45 seconds on every process restart, and with restarts happening on every input that means the timer would never fire.
- **`lastMove`** — what to animate, including the captured token. The client could diff the previous state, but a client that just cold-started has no previous state. One explicit field is cheaper and correct on the first frame.
- **`finished` / `winnerUserId`** — terminal, recovered from the user id on restore per [`cricket/index.ts:276-278`](../../../backend/games/src/engine/cricket/index.ts#L276-L278).

**Not present, deliberately: the RNG state.** §4.6.

## 4.4 No `serializeForWire()`

~400 bytes, everything matters to the client, broadcast a few times a minute. [`GameEngine.ts:70-72`](../../../backend/games/src/engine/GameEngine.ts#L70-L72): turn-based games omit it because "the persistence shape and the wire shape are the same object."

## 4.5 No `serializeForPlayer()`

**Ludo has no hidden information.** Every token position, every roll, every capture is public to all seats. That is unusual for a 4-player game and it is worth stating explicitly, because the instinct after Sea Battle is that multi-seat implies per-seat views.

The only hidden thing is **the future**, and that is protected by the secret channel (§4.6), not by a per-player projection.

A consequence worth noting: **spectating Ludo is free.** A seatless viewer receives `serialize()` and sees the correct, complete game. When a spectator seat exists (open question O12), Ludo is the game to prove it on.

## 4.6 `serializeSecret()` — the RNG, and why it is not public

```ts
serializeSecret(): GameStatePayload {
  return { rng: this.rng.seed };   // mulberry32 internal state
}
```

**This is the most important line in the engine, and it is where Ludo departs from Snake.**

[`snake/index.ts:786`](../../../backend/games/src/engine/snake/index.ts#L786) puts its seed straight into `serialize()`, on the wire, and that is fine there: the sequence drives pellet positions and bot jitter, and knowing where a pellet will appear a frame early is worth nothing.

**In Ludo the next draw is the dice.** `Rng` is mulberry32 ([`geometry.ts:113-131`](../../../backend/games/src/engine/snake/geometry.ts#L113-L131)) and its state *is* its seed — `next()` advances it deterministically. A client holding that number can compute every future roll of the match with twenty lines of code.

That is not a minor leak. It is total: knowing you will roll 6, 6, 2 next completely determines which token to move now, whether to break a block, whether to risk a capture. **A client with the seed does not cheat at Ludo, it solves it.**

So the seed rides the secret channel, is persisted alongside the public state, and is never in a broadcast frame ([`GameEngine.ts:83-96`](../../../backend/games/src/engine/GameEngine.ts#L83-L96), [`matches.ts`](../../../backend/games/src/matches.ts) `LiveMatch.secret`).

**This is the rule [`README.md`](./README.md) §1.3 states and Ludo is its clearest case:**

> The seed goes in `serializeSecret()`, not `serialize()`, whenever a future draw from it is information a player would pay for.

**And it must survive the round-trip.** [`GameEngine.ts:86-91`](../../../backend/games/src/engine/GameEngine.ts#L86-L91) documents what happens otherwise: hand cricket's picks were "silently dropped a millisecond after being made" and the game "looped between the two players forever." Ludo's failure would be quieter and worse — a lost RNG state means the engine reseeds, so **every roll would be drawn from a fresh sequence seeded identically on every input.** In the worst case the die returns the same face forever; in the best case the sequence is silently non-random. Neither would look like a crash and both would take a long time to diagnose.

`restore` therefore takes the seed from `secret`, never from `state`, exactly as [`cricket/index.ts:273`](../../../backend/games/src/engine/cricket/index.ts#L273) takes `pending`. A restore with no secret must reseed **loudly** — log it, because a match whose dice sequence restarted is a match that quietly stopped being fair.

## 4.7 The die

```ts
private rollDie(): number {
  return 1 + Math.floor(this.rng.next() * 6);
}
```

Uniform, mulberry32, seeded per match. **Not `Math.random()`** — [`geometry.ts:105-111`](../../../backend/games/src/engine/snake/geometry.ts#L105-L111) explains why that is fatal for anything round-tripping through `restore`: "an engine using global randomness would produce a different world each time it was restored."

**No weighting, no pity timer, no anti-streak correction.** Every Ludo implementation is accused of rigging its dice and most are innocent; the defence is that the die is a uniform draw from a seeded PRNG and the sequence is reproducible from the seed for anyone auditing a match after the fact. Adding "fairness" adjustments would make that defence untrue.

Worth being blunt in the code comment: **players will believe the dice are rigged.** Six-starved streaks are common — the probability of no 6 in six rolls is 33% — and the human pattern-matcher will find them. The answer is not to bias the die; it is to be able to prove it is not biased.

## 4.8 Tick-rate independence

Not applicable — no `tick()`, nothing integrated. The only time-dependent value is `deadlineAt`, an **absolute epoch timestamp** rather than a countdown, so it is correct regardless of when it is read or how long the process was down.

---

# 5. Anti-cheat

**A Ludo client can express exactly two things: "roll" and "move token N".**

| Attempt | Defence |
|---|---|
| Choose the die face | No input frame expresses it. The die is drawn server-side from the secret RNG |
| **Predict the die** | **The seed is in `serializeSecret()` and never broadcast** (§4.6). This is the attack the design is shaped around |
| Move an illegal token | Membership check against the server's own `legal` set (§4.2) |
| Move out of turn | `turn` check |
| Move twice | `phase` advances inside `applyInput` before returning |
| Roll twice | `phase` check — the field §4.3 flags as the one a naive design loses |
| Move an opponent's token | `move` indexes only the caller's own tokens |
| Claim a capture | Capture is computed server-side from the resulting position |
| Skip a forfeit | Deadline is server state in a Redis sorted set the client cannot see |
| Flood inputs | 60/min, silent drop ([`index.ts:29-61`](../../../backend/games/src/index.ts#L29-L61)) |
| Input into someone else's match | Membership checked from the live record ([`index.ts:262-264`](../../../backend/games/src/index.ts#L262-L264)) |

**There is no residual attack surface worth naming**, which makes Ludo the most cheat-resistant game in this folder — a consequence of having no hidden player information and no continuous simulation. The whole security model is one line: the seed is secret.

**Collusion between two players in a 4-player game** is real, undetectable, and social. Same conclusion as [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §5.3: invite-only matches between people who already talk to each other, no ranked ladder, no prizes. Not an engineering problem.

---

# 6. Client rendering

## 6.1 What it reuses

| Piece | Source | Notes |
|---|---|---|
| Turn-based board patterns | [`TicTacToeBoard.swift`](../../../apps/ios/Voiid/Voiid/Games/TicTacToeBoard.swift) / [`TicTacToeScreen.kt`](../../../apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeScreen.kt) | Tap targets, cell state, turn indication |
| Produced-board look | [`CricketPitch.swift`](../../../apps/ios/Voiid/Voiid/Games/CricketPitch.swift) | The bar for a turn-based visual in this app |
| `GamesEngine` | existing | Unchanged |
| `GameAudio` / `GameHaptics` | [`GameAudio.swift`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift) | One new `soundNames(for:)` entry |
| Lobby | [`GameLobbyView.swift`](../../../apps/ios/Voiid/Voiid/Games/GameLobbyView.swift) | **Extended to N seats — the shared work of §2.4** |

## 6.2 What it adds

**iOS:** the board is one SwiftUI `Canvas` (static geometry — track, yards, home columns, stars) with tokens as overlaid views so they can animate individually with SwiftUI's own animation system. **Not Metal**; the scene is ~70 static cells and ≤16 tokens, and [`GAMES.md`](../../GAMES.md) §4 specifies plain views for board games.

**Android:** Compose `Canvas` for the board, `Box`-positioned token composables with `animate*AsState`, mirroring iOS.

**The board geometry is a shared lookup table**, not drawing code: `squareCenter(index) → (x, y)` in normalised board space, one array of 52 + 4×5 + 4×4 positions, ported identically to both platforms. Every token animation, tap target and highlight reads from it. Two hand-drawn board layouts that disagree by a few points is exactly the kind of parity drift [`ANDROID_IOS_PARITY.md`](../../ANDROID_IOS_PARITY.md) exists to prevent, and a table is checkable.

## 6.3 The 4-player layout problem

Four players, four yards, one portrait screen. The board is square; the screen is not.

**Decision: the board is a square, centred, occupying the full width, with player strips above and below.**

- **You are always at the bottom.** The board is rotated so the local player's yard is bottom-left, exactly as Air Hockey always puts your goal at the bottom ([`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §2.1). This is a client-side rotation the server knows nothing about, and it means every player has the same spatial relationship to their own tokens.
- **Opponent strips** carry name, colour, tokens-home count, and an active-turn indicator.
- **On a compact screen** the board still gets the full width; the strips compress to one line each.

**The active player's strip is the primary turn indicator, not the board.** With four players a subtle board highlight is not enough — whose turn it is must be readable at a glance from across a room, because in a 4-player game you are mostly waiting.

---

# 7. Controls

## 7.1 The scheme

1. **Tap the die** to roll. It is large, centre-bottom, and it is the only interactive element when `phase === 'awaitingRoll'`.
2. **Legal tokens pulse.** After the roll, every token in `legal` (§4.3) lifts slightly and pulses. Illegal tokens are dimmed to 45%.
3. **Tap a token to move it.** A ghost preview shows the destination square while the finger is down; releasing commits.
4. **Zero or one legal move → no tap needed** (§3.4).

**No drag.** Dragging a token along a track that wraps a corner is ambiguous and slow, and the destination is fully determined by the die — there is nothing to drag *to*. Tap-to-select is faster and unambiguous.

## 7.2 Small screens and one-handed use

- **The die is the primary target**, bottom-centre, 64 pt, reachable by either thumb.
- **Tokens are small** — a 52-square track on a 390 pt board gives ~40 pt cells with ~28 pt tokens. Below the 44 pt minimum, so: **tap targets are 48 pt regardless of visual size**, and where two tokens are adjacent the hit regions split rather than overlap.
- **A stack shows a count badge** and tapping it selects the top token; tapping again cycles. Rare, and it beats an ambiguous target.
- **Preview before commit.** The destination ghost means a mis-tap is visible before it is irreversible, which is the same reasoning as [`SEA_BATTLE.md`](./SEA_BATTLE.md) §7.2's two-step commit, at lower cost because a Ludo move is one of at most four options rather than one of a hundred.

---

# 8. Visual design

## 8.1 Art direction

**Warm, tactile, physical.** Ludo is a board game people played on a mat on the floor, and this is the one game in the folder where nostalgia is an asset rather than a liability. Contrast Snake and Voiid Run, where abstraction is correct because there is no referent.

- **Board:** a printed surface — subtle paper texture, printed ink, a soft drop shadow so it sits *on* the screen rather than in it.
- **Tokens:** rounded 3/4-view pieces with a soft shadow. They should look like objects that can be picked up, which is what makes the hop animation (§9) read.
- **Safe squares:** printed stars, unmistakable. This is a rule the board must teach.
- **Home columns:** the player's colour, running to a home triangle.
- **Yards:** four corner pockets holding un-entered tokens.

**Four colours that are distinguishable by more than hue** ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13). Each player's tokens carry a distinct **shape marker** — dot, ring, cross, bar — visible on the token face, in the strip, and in the yard. Ludo is traditionally colour-only and that is precisely the trap; with four players it is four times worse than Snake's version of the same problem.

## 8.2 What the player must see without a tap

1. **Whose turn it is** — the active strip, unmistakably.
2. **The die**, current face, large.
3. **Which tokens are legal**, once rolled.
4. **Every player's tokens-home count.**
5. **The turn timer**, when under 15 s (§13.2).
6. **What just happened** — `lastMove` animated, and a capture called out by name: *"Priya sent your token home."* Free from `lastMove`, and in a 4-player game where you are mostly watching, it is what keeps the other three players' turns legible.

---

# 9. Motion and feel

Behind reduce-motion ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13, open question O13). Under it: tokens teleport with a 120 ms fade, the die cuts to its face, no shake.

| Moment | Motion | Duration | Curve |
|---|---|---|---|
| Die roll | Tumble through 6–9 faces, decelerating, then settle with an overshoot | 700 ms | `easeOut` on the tumble; settle `spring(0.3, 0.6)` |
| Die settles | Scale 1.0 → 1.15 → 1.0, glow pulse | 220 ms | `spring(0.2, 0.55)` |
| Legal tokens highlight | Lift 4 pt, pulse at 1.2 Hz | 260 ms in | `easeOut` |
| **Token move** | **Hops square by square**, ~110 ms per square, arcing 12 pt with a squash on each landing | 110 ms × distance | Per hop: `easeInOut` position, `spring(0.14, 0.5)` squash |
| Token enters from yard | Drops in from above with a bounce | 360 ms | `spring(0.26, 0.6)` |
| **Capture** | Captured token pops to 1.3, then arcs back to its yard over 520 ms while spinning | 620 ms total | pop `spring(0.16, 0.5)`, arc `easeInOut` |
| Extra turn granted | Die glows and re-enables with a small bounce | 300 ms | `easeOut` |
| Token enters home column | Colour saturates, a small sparkle | 400 ms | `easeOut` |
| Token home | Scale pop, particle burst, home-count increments | 500 ms | `spring(0.24, 0.55)` |
| Three sixes | Die shakes and greys, turn passes | 400 ms | `easeInOut` |
| Turn passes | Active strip cross-fades to the next player | 280 ms | `easeInOut` |
| Match won | Winner's tokens do a victory bounce, board dims | 900 ms | staggered `spring` |

**The hop is the most important animation in the game and it must not be optimised away.**

A token that slides or teleports to its destination discards the one piece of information the movement carries: *how far*. Hopping square by square shows the count, which is what makes a 6 feel different from a 2 — and in a 4-player game where you spend three quarters of your time watching, it is what makes other people's turns worth watching.

**Cap total travel at 900 ms** (6 squares × 110 ms ≈ 660 ms, so this only bites on home-column runs) and let a tap skip to the end. Watching is good; waiting is not.

**The capture arc is the second most important.** A capture is the emotional event of Ludo, and a token that vanishes reads as a bug. Sending it visibly, spinning, all the way back to its yard is the game's cruelty made legible — and the player it happened to needs to see it happen, not discover it.

---

# 10. Sound

Inherits [`SOUND_DESIGN.md`](../SOUND_DESIGN.md). New entry in `soundNames(for:)` ([`GameAudio.swift:282`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L282)).

## 10.1 The shared catch sound

> **The catch moment in Ludo is: your token is captured and sent back to the yard.**

Textbook — a player's attempt is ended by an opponent ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §3). A token 40 squares along its journey is the most concrete "attempt" in any game in this folder.

Played **unmodified**, layered never replacing: `catch.wav` **+** the token's landing thud, and then the arc back to the yard (§9) with its own softer landing. Same three-layer structure as cricket's wicket: `catch` + `wicket_timber` + a delayed crowd reaction.

**Only when it is *your* token.** Capturing someone else's plays a different, brighter sound — the vocabulary rule is about the player whose attempt ended, and both players hearing `catch` would flatten the most asymmetric moment in the game.

## 10.2 The palette

**Physical, recorded** — Ludo has real referents and they are trivially recordable, which [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §5.2 recommends: "Record it... they will beat a generic library clip because they will be exactly the length and character specified above."

| Event | Sound | Notes |
|---|---|---|
| Die roll | `die_roll.wav` | Real dice in a cup or on a board, ~700 ms, matched to the tumble |
| Die settles | `die_settle.wav` | The final clack. Must land on the same frame the face resolves |
| Token hop | `hop_1..4.wav` | Very short (~60 ms) wooden tap. **The most-triggered sound in the game** — a 6-square move fires it 6 times, ~200 times a match. 4 variants plus ±4% varispeed, per the chalk argument ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.3) |
| Token enters play | `enter.wav` | A firmer placement thud |
| **You capture** | `capture.wav` | Bright, satisfying — a sharp wooden knock |
| **You are captured** | **`catch.wav`** + `capture.wav` (quieter) | §10.1 |
| Token home | `home.wav` | Warm, resolving |
| Extra turn | `extra_turn.wav` | Short rising tick |
| Three sixes | `three_sixes.wav` | Falling, deflating. Deliberately anticlimactic, like cricket's dot ball |
| No legal move | `pass.wav` | Soft, brief |
| Your turn starts | `your_turn.wav` | Shared with Sea Battle. Fires a lot; must be gentle |
| Match win / loss | Existing stingers | — |

**No ambience bed.** Ludo is played in bursts of attention with silences between; a bed would fill the silence that makes the die roll land. Cricket earns its crowd because cricket is about atmosphere; Ludo is about a table.

**Mono, always** ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §6.6 — a stereo asset is a hard AVAudioEngine crash).

## 10.3 Haptics

- **Die settles:** sharp transient. The tactile half of the roll.
- **Each hop:** very light tick. With the cap at ~8 hops this is a texture, not a buzz.
- **Capture (yours):** the existing `death()` pattern ([`GameHaptics.swift:89`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameHaptics.swift#L89)).
- **Capture (theirs):** the existing `kill()` pattern ([`GameHaptics.swift:73`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameHaptics.swift#L73)).
- **Token home:** medium double transient.
- **Your turn starts:** light, and **only when the app is foregrounded and the screen is on.** In a 4-player game the turn comes round often, and a buzz every 40 seconds while someone is reading a message is user-hostile.

---

# 11. Bots

Client-side, like [`RpsBot.swift`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift) and [`CricketBot.swift`](../../../apps/ios/Voiid/Voiid/Games/CricketBot.swift). Also used server-side for timeout auto-play (§13.2) — one policy, two consumers.

## 11.1 What difficulty varies

Move selection. The die is untouched — **difficulty never touches the dice, at any level, ever.** A bot that rolls better is not a harder bot, it is a cheat, and in a game where players already suspect the dice it is the single most damaging thing that could be built.

| Band | Policy |
|---|---|
| 0.0–0.25 | **Random legal move.** No preference at all |
| 0.25–0.5 | **Greedy priority:** capture > enter home > enter from yard > advance the furthest token |
| 0.5–0.75 | **Risk-aware.** Adds a threat model: for each candidate destination, compute the probability it is captured before your next turn — for each opponent token 1–6 squares behind, `1/6` per token, adjusted for safes and blocks — and subtract a weighted penalty. Prefers safe squares and forming blocks |
| 0.75–1.0 | **Expectimax, depth 2.** Enumerates its own moves, then all 6 die faces for the next opponent weighted 1/6, then that opponent's best reply. Evaluates on progress, tokens home, threat exposure and block value |

Between bands, the higher policy is played with probability `skill` and the lower otherwise — the construction [`RpsBot.chooseThrow`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L50) uses. This makes the scale continuous and makes a mid-skill bot *inconsistent* rather than uniformly mediocre, which is closer to how people actually play.

## 11.2 What the top of the scale can and cannot do — the honest part

**This section matters more in Ludo than in any other game in this folder, because Ludo is mostly luck and a difficulty slider over it is very easy to make dishonest.**

**Ludo is roughly 80% dice and 20% decisions.** In a 4-player game the baseline win rate is 25%. A perfect player against three random players wins about **33–36%**. That is the entire value of playing well: **8 to 11 percentage points.**

So, stated plainly and in the register [`RpsBot.swift:17-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L17-L21) sets:

> **The hardest Ludo bot will lose to a beginner about six times in ten.** That is not a weakness in the bot. It is the game. Any implementation whose "hard" difficulty reliably beats a competent human is rolling better dice, and that is a cheat rather than a difficulty setting.

**It can:** avoid landing in front of opponent tokens, form blocks at chokepoints, time entries, and choose correctly when to break a block. Over 50 matches it will be measurably ahead.

**It cannot:** overcome bad dice, and there is no depth of search that would let it. This is not RPS's "cannot beat a truly random human because nothing can" — it is worse, because in Ludo skill does not even guarantee an edge in a single match.

**The design consequence:** difficulty is presented as **playstyle, not strength.** "Careless / Steady / Cautious / Sharp" rather than "Easy / Hard". Naming it by strength promises something the game cannot deliver, and a player who loses to "Easy" will correctly conclude the labels are meaningless.

## 11.3 Presentation

- **Thinking delay 700–1600 ms**, randomised, plus the roll animation. An instant move reads as a lookup table.
- **The bot occasionally takes the second-best move** at high skill — 8% of the time, when the gap is small. Perfect consistency is the tell, and Ludo's decisions are close enough that a small deviation costs nearly nothing.
- **Plausible names** from a pool like [`snake/index.ts:95-101`](../../../backend/games/src/engine/snake/index.ts#L95-L101)'s — "a bot labelled as a bot changes how players treat it."

---

# 12. Progression and retention — R3

## 12.1 The floor

[`README.md`](./README.md) §1.6's four, with a multi-player adaptation:

1. **Rematch** — same players, same options, one tap. **With 3–4 players this must be "rematch, and everyone who taps in is in"**, with a 30 s window, rather than requiring all four. Requiring unanimity means one distracted person kills the session.
2. **Post-match summary** — placement, tokens home, captures made and suffered, longest single move, luckiest/unluckiest (6s rolled vs expected).
3. **Head-to-head** — in a 4-player game this is a *table*, not a pair. Wins per player in this group.
4. **Share result into the chat** — the natural artifact is the final board plus the placement table.

## 12.2 The specific hook

**It is the game that gets four people into the app at the same time.**

Named precisely: not "Ludo is fun" but *"Ludo is a scheduled social event, and this app is where the scheduling already happens."* A group chat says "Ludo?" and three people say yes. Every other game here is a 1:1 arrangement.

Supporting properties:

- **Everyone can win from behind.** A single capture can undo three minutes of someone's progress, so nobody is out of it, so nobody leaves early. This is why Ludo has survived as a group game: the luck that makes it a weak skill test (§11.2) is exactly what keeps four people engaged to the end.
- **Watching is participating.** Someone else's capture is *your* event too. Contrast Chess, where the other player's turn is dead time.
- **It generates talk.** The dice are the most reliable trash-talk generator in games, and the talk lands in a chat thread that already exists.

## 12.3 How it uses the fact that this is a messenger

- **Group-chat invites.** [`OpponentPickerSheet.swift`](../../../apps/ios/Voiid/Voiid/Games/OpponentPickerSheet.swift) today deliberately excludes groups — its header says groups "would imply a lobby this system does not have." Ludo is the game that builds that lobby, and **"play Ludo with this group" from a group thread is the single highest-value entry point in this doc.** One tap from the conversation to a filled lobby.
- **The live match makes the group thread synchronous**, which is the thing groups want and rarely get.
- **The result table is a message.** Four names and four places, dropped into the thread.
- **Capture notifications are unnecessary and must not be sent.** Ludo is live (§3.6); a push per capture in a 15-minute match is 20 pushes. The only notification is the invite.

## 12.4 What the first 30 seconds feel like

- **0–5 s.** Accept from the group thread. The lobby shows four seats, two filled, filling as people accept. **Seats filling in real time is itself engaging** — it is the "who else is coming" moment and it should be visible, not a spinner.
- **5–8 s.** Board appears, rotated so your yard is bottom-left. Your colour is announced. Turn order is shown.
- **8–12 s.** Someone rolls. The die tumbles, lands, a token hops out. **Everyone knows this game already** — this is the only game here with zero explanation cost and an existing emotional relationship.
- **12–30 s.** Your turn. Tap the die. You probably do not roll a 6 (67% chance), and the turn passes. **This is the first friction point and it must not feel like a bug** — a "no 6, no move" state needs a clear, brief, slightly-funny beat rather than silence.

**Ship a one-screen rules sheet anyway**, behind a `?`, covering the two house rules a returning Ludo player will assume differently: blocks on (§2.4) and the token-count default (§2.7). The rules everyone knows are not the rules everyone agrees on.

## 12.5 What someone with 50 matches is chasing

- **The group table.** "Who has won the most in this group" over months. This is Ludo's version of head-to-head and it is stronger, because it is a standing between four people who all see it.
- **Capture stats.** Captures made vs suffered is the stat Ludo players actually care about and it is a one-line derivation from match history.
- **The unluckiest-player award.** 6s rolled versus expected, per match. It is a joke, it is free, and it defuses the "the dice are rigged" complaint (§4.7) by making the randomness visible and shared.
- **Block mastery.** The only genuine skill in the game (§11.2) and the thing a good player does that a new one does not notice.
- **Speedruns in 2-player, 2-token mode.** A 7-minute format is repeatable in a way the classic game is not.

Explicitly **not**: cosmetics, boards, token skins. Snake already demonstrates the failure mode — [`SNAKE.md`](../SNAKE.md) §3.5: "the skin picker is a preference, not a reward, so there is no reason to keep playing." If cosmetics are ever added they must be *earned*, and that is a decision for after the group table proves people are coming back.

---

# 13. Failure and edge cases

## 13.1 Disconnect

**A live 3–4 player game is the worst case in this folder for a disconnect**, because three people are blocked on one.

- **The match continues.** A disconnected player's turns are **auto-played by the bot** at the timeout (§13.2), not skipped. Skipping would make disconnecting a strategy — you cannot be captured on a square you never moved to.
- **Their strip shows a disconnected badge.** With four players, an unexplained pause is ambiguous; naming it removes the ambiguity.
- **Reconnect resumes seamlessly.** Full state frame, nothing to reconcile.
- **After 3 consecutive auto-played turns**, the player is marked absent and their remaining turns are auto-played with no timer wait, so the match speeds up rather than grinding.

## 13.2 The turn deadline

Needs the deadline sweeper ([`README.md`](./README.md) §2.3): `games:deadlines` sorted set + a 1 s interval + `deadlineAt()` / `onTimeout()`.

| Mode | Deadline | On expiry |
|---|---|---|
| Live (3–4 players) | **45 s** per action | **Auto-play** the mid-skill bot's choice. Never forfeit |
| Live (2 players) | 45 s | Same |
| Async 2-player (§3.6) | **24 h** | Auto-play, with a warning at 18 h |
| Absent player (3+ auto-plays) | **3 s** | Auto-play immediately |
| Whole match | **abandon after 10 min of no input from anyone** | `winnerId: null`, honest scores |

**Auto-play, not forfeit, and this is the key decision.**

[`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §6 proposes "60 s → forfeit" for turn-based games. Forfeiting is right for a 2-player game where the absent player is only hurting their opponent. It is **wrong for Ludo**, because forfeiting one of four players mid-match ruins the game for the other three — the board changes shape, the remaining tokens' odds change, and the match becomes something nobody signed up for.

Auto-play keeps the game intact. The absent player plays badly and probably loses, which is the correct consequence, and the other three finish the game they started.

**45 seconds**, not 60: a Ludo action is "tap the die" then "tap one of at most four tokens". 45 s is generous for a decision that size and it bounds a 60-turn match at a length people will finish.

**A visible countdown from 15 s**, with an escalating pulse. Not from 45 — a 45-second countdown is pressure applied to nothing.

**Idempotency:** the timeout frame carries the `moveCount` it was scheduled against (§4.3) and is dropped if it does not match. Without it a duplicate sweeper delivery auto-plays twice, which in Ludo means moving a token the player has already moved.

## 13.3 A player leaves deliberately

- **2 players:** the other wins. Same shape as a resignation.
- **3–4 players:** the leaver's tokens **stay on the board and are auto-played** to the end. Removing them would be a large, arbitrary change to everyone else's odds mid-match — a player one square from being captured would be saved by their opponent quitting.
- Recorded honestly: last place, flagged as a walkover, counted as a loss.

## 13.4 Not everyone joins the lobby

`handleJoin` gates the start on `joined.length >= players.length` ([`index.ts:359`](../../../backend/games/src/index.ts#L359)), which already works for any seat count — the multi-seat work is client-side ([`README.md`](./README.md) §2.4).

**A 5-minute lobby timeout**, then: start with bots filling empty seats (with everyone's consent, shown in the lobby), or cancel. **Recommend offering the bot-fill** — three people who showed up should not be blocked by a fourth who did not, and a bot in the fourth seat is a much better outcome than a cancelled match.

## 13.5 The engine restarts mid-match

- No tick loop to lose (turn-based).
- State reloads from Redis, or from the durable table on a TTL miss (§2.2 of the README) if async 2-player is in scope. **A live 15-minute Ludo game fits inside the 1-hour TTL**, so live Ludo does not strictly need the durable table — a useful property, since it means Ludo is not blocked on that work.
- **The RNG state must reload with it** (§4.6). Store `state` and `secret` in the same write. A reseed must be logged loudly.
- Deadlines survive in the sorted set, and `deadlineAt` is in `serialize()` as a backstop.

## 13.6 Ties

Impossible for first place — one player finishes first. Placements 2–4 are ranked by tokens home then distance travelled, and a genuine tie there is displayed as a tie.

## 13.7 A player has no legal move, forever

Possible in principle: all tokens in the yard and no 6 for many turns. Handled by §3.4 (auto-pass) and bounded by the fact that the expected wait for a 6 is 6 rolls. Not a stall — just bad luck, and the pass beat (§10.2's `pass.wav`) should make it feel like an event rather than a hang.

**A genuine stall — everyone blocked, nobody able to move — is impossible**, because blocks cannot form on safe squares (§2.4) and a blocking player must move if that is their only legal move.

---

# 14. Build plan

## Phase 0 — multi-seat lobbies *(shared infrastructure, not Ludo work)*

[`README.md`](./README.md) §2.4. The API already takes an array of `opponent_ids` ([`games.ts`](../../../backend/api/src/routes/games.ts)), `player_ids` is a jsonb array, the catalog has min/max players, and `handleJoin` already gates on seat count. **The gap is entirely client-side:** [`OpponentPickerSheet.swift`](../../../apps/ios/Voiid/Voiid/Games/OpponentPickerSheet.swift) is a single-select callback and its Android twin matches.

Work: multi-select picker, group-chat entry point (§12.3), a seat list in the lobby with per-seat join state, and bot-fill (§13.4).

**This is the same work that unlocks Snake's 3–6 player mode** ([`SNAKE.md`](../SNAKE.md) §3.6), which is currently 1 human + 5 bots for exactly this reason. **Sequence it once; three games get it.** Ship it against Snake first — Snake's engine already supports 6 seats, so it is a pure client change with no new rules, which makes it the cheapest possible way to debug the lobby.

Also needed: the deadline sweeper ([`README.md`](./README.md) §2.3), if it has not shipped with Sea Battle.

## Phase 1 — engine, headless

`engine/ludo/` + registry + tests. The rules are fiddly, so the tests carry real weight:

- Entry requires a 6; exact roll to home; overshoot is illegal
- Capture, capture-on-safe rejected, capture in home column rejected
- Blocks: cannot land, cannot pass; no block on a safe square; must break if it is the only legal move
- Three-sixes forfeits and does not use the third 6
- Extra turns compose to one, not two
- Auto-pass on zero legal moves; auto-move on exactly one
- **Serialize → restore → serialize byte equality**, specifically covering `phase`, `sixStreak` and `extraTurn` (§4.3)
- **Restore with the secret preserves the exact dice sequence**, and restore without it is logged (§4.6)
- A full match simulated from a fixed seed produces a fixed result — the determinism test that makes the rest trustworthy

## Phase 2 — iOS practice mode

Board, tokens, die, hop animation, capture arc, the bot at all four bands, sound, motion. **No networking**, 1 human + 3 bots. This is where the game is tuned and where §9's animation timings are found.

## Phase 3 — iOS online, 2-player

Wire to `GamesEngine` with the existing single-select picker. **2-player first, deliberately:** it exercises the full engine and netcode without depending on Phase 0, so the game can be proven before the lobby work lands.

## Phase 4 — 3–4 player

On top of Phase 0. Multi-seat lobby, group entry, 4-player layout (§6.3), auto-play on timeout.

## Phase 5 — Android parity

Phases 2–4. iOS is the reference; constants and the board lookup table (§6.2) ported literally.

## Phase 6 — retention

Post-match summary, group rematch, the group win table, capture stats, unluckiest-player award, share-to-chat.

## Phase 7 — polish

Rules sheet, colourblind shape markers, reduce-motion, accessibility pass.

---

# 15. Open questions

1. **Two, three or four seats at launch — and is 2-player Ludo worth shipping first?** *(O6 in [`README.md`](./README.md) §5)* Recommendation: **yes, ship 2-player first** (Phase 3). It unblocks the game from the lobby work entirely, proves the engine and netcode, and 2-player Ludo is a genuinely good short game. 3–4 players follows when Phase 0 lands.

2. **Default token count.** Recommendation: **2 for 3–4 players, 4 for 2 players** (§2.7). This is the most player-visible departure from "real" Ludo in the doc and it is made to keep a default match under 20 minutes. It deserves an explicit decision rather than being discovered in the options sheet.

3. **Blocks on or off?** Recommendation: **on**, with no blocks on safe squares (§2.4). Off is simpler and faster and removes the only real decision in the game.

4. **Sequence the lobby work against Snake or against Ludo?** Recommendation: **Snake** (Phase 0). Its engine already supports 6 seats, so it is a pure client change and the cheapest way to debug multi-seat.

5. **Is bot-fill acceptable when a lobby does not fill?** (§13.4) Recommendation: **yes, offered explicitly and visibly**, never silently. Three people blocked by a fourth is the most likely way a Ludo session dies.

6. **Difficulty labels: strength or playstyle?** Recommendation: **playstyle** — "Careless / Steady / Cautious / Sharp" (§11.2). Ludo's skill ceiling is worth ~10 percentage points of win rate, and strength labels promise something the game cannot deliver.

7. **Do bot matches count for the group table?** Cross-cutting (O10). Recommendation: no.

8. **Options-bag typing.** *(O11)* `tokens` is an int and fits today's `[String: Int]` ([`GamesAPI.swift:37`](../../../apps/ios/Voiid/Voiid/Networking/GamesAPI.swift#L37)). Noted only because a future board-variant option would be a string, which is the third such case in this folder.

9. **Reduce-motion.** §9 specifies hop chains, capture arcs and particle bursts. The switch does not exist ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13). Ludo's motion is more informational than decorative, so the reduced version must still communicate distance — a token that teleports loses the count, which is why the fallback is a fade *plus a distance readout*, not just a fade.

---

# 16. What was built

Recorded here rather than left implicit, so the next person reads what is true rather than what was planned.

## 16.1 The engine

[`engine/ludo/`](../../../backend/games/src/engine/ludo/) — `board.ts` for the pure movement maths, `index.ts` for the rules, plus a test suite covering everything §14 asks for: entry requiring a 6, exact roll to home, overshoot illegal, capture and its two exemptions, blocks that cannot be landed on or passed, no block on a safe square, three sixes forfeiting without using the third, extra turns composing to one, auto-pass and auto-move, the serialize→restore byte-equality round trip over `phase`/`sixStreak`/`extraTurn`, and a fixed-seed dice determinism check.

**The seed is in `serializeSecret()` and the registry test asserts it is absent from `serialize()`.** This is the folder's clearest case of the §1.3 rule: mulberry32's state *is* its seed, so a client holding it computes every future roll.

Two test bugs are worth recording because both "passed" while measuring nothing. The dice-uniformity check sampled a board where every token was in the yard — a non-6 auto-passes and clears the die, so the sample recorded only sixes and read as a die that always rolls 6. And a wrap assertion had the wrong seat: square 50 is the end of seat 0's lap so it turns into the home column, while the same square mid-lap for seat 1 wraps. Both engine behaviours were correct.

## 16.2 Both renderers

`LudoBoard`/`LudoBoardView`/`LudoView` and their Kotlin twins. The board geometry is a shared lookup table per §6.2, and it was **derived by tracing the cross rather than typed** — the hand-written first pass had four corner steps that jumped two cells, which would have walked tokens through walls and was not visible by reading. `LudoBoardTest` pins the properties: 52 distinct cells, entries matching the server's `seat * 13`, exactly 48 orthogonal and 4 diagonal steps, columns of 5 that never touch the track, and all 944 possible token placements landing on the board.

The four diagonal steps are inherent — the orthogonal perimeter of this cross is 56, so a 52-cell ring must cut the arm corners.

Built as specified: you are always at the bottom (client-side rotation, tokens counter-rotated), the active player's strip as the primary turn indicator, shape markers so colour is never the only channel, legal tokens lifting while illegal ones dim, the die as the primary target, the three-sixes state made visible, and captures narrated by name.

## 16.3 Multi-seat lobbies (§14 phase 0)

`SeatPickerSheet` on both platforms, plus `createMulti` and a seat-count-aware lobby. Which picker opens is keyed on the **catalog row**, so the next multi-seat game needs no client change.

**This uncovered a real bug in shipped code:** both lobbies decided a match had started by watching three state fields and silently omitted Snake, so a Snake friend match would have sat in the lobby forever while its board was live behind it. Fixed on both platforms.

## 16.4 Three departures from this doc

1. **The hop chain is not built.** §9 calls it the most important animation in the game and says it must not be optimised away — it is what shows the player *how far* a move went. Tokens currently spring between squares. It is deliberately deferred because §9 also requires it behind the reduce-motion switch (§15 Q9), which still does not exist, and shipping motion without the opt-out is what CROSS_CUTTING.md §13 flags about Snake. **This is the single largest visible gap against the doc.**

2. **Groups are still excluded from the picker.** §12.3 calls "play Ludo with this group" the highest-value entry point in this doc. It needs a group-membership read and a fan-out invite, which the picker has no business inventing, so seats are filled from direct chats and the group entry point is named as the next piece of work.

3. **No bot, so no practice mode (phase 2).** §11's four bands and the "playstyle, not strength" labelling are unbuilt. Timeout auto-play uses the middle greedy policy server-side, which is the same shape §11.1 describes for band 0.25–0.5, but it is not exposed as a difficulty.

## 16.5 What is still open before this is playable

- **Migration 042 has not been applied.** The catalog is server-side, so Ludo does not appear in either app's game list until it runs. A push to `main` applies it via `deploy-dev.sh` and restarts the services.
- **The sound assets do not exist.** `die_roll`, `die_settle`, `hop_1..4`, `enter`, `capture`, `home` are registered in both `GameAudio` tables and referenced by `LudoSound`. A missing buffer is a silent no-op on both platforms, so the game plays correctly and quietly.
- **Neither renderer has been seen running.** Both compile and their geometry tests pass; no match has been played, because the catalog row does not exist yet.
