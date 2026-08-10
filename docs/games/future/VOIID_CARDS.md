# Voiid Cards

> **Status:** design only, nothing built.
> **Kind:** turn-based, 2–6 players, hidden hands. No `tickHz`.
> **Blocked on:** per-recipient wire frames ([`README.md`](./README.md) §2.1) — **hard blocker, the game is not expressible without it** — plus multi-seat lobbies (§2.4) and the deadline sweeper (§2.3).
> **Reference implementations to read first:** [`cricket/index.ts`](../../../backend/games/src/engine/cricket/index.ts) for the secret channel, and [`SEA_BATTLE.md`](./SEA_BATTLE.md) §4.3 for `serializeForPlayer`, which this game pushes much harder.

---

# 1. What the game is

A shed-your-hand card game for 2–6 players. Match the top of the discard pile by colour or by number, play an action card to punish the next player, and get rid of every card in your hand first.

It is a UNO-like, and it should be called that internally so nobody is confused about what is being built. It is **not** UNO, for reasons in §1.3 that are legal rather than creative.

## 1.1 Why it belongs in Voiid

**It is the loudest game in the catalog, and loud is what a group chat is for.**

Every other multi-seat game here is a race (Ludo) or a duel (everything else). Voiid Cards is the only one where the interesting event is *doing something to a specific person*. You do not beat the field; you stack four draw cards onto Priya, specifically, on purpose, and then everyone talks about it. The cards are the excuse and the trash talk is the point.

That maps onto a messenger better than any other game here. Ludo's captures are impersonal — the dice chose. A `+4` is chosen, aimed and unmistakably personal, and the natural response is a message.

Three supporting properties:

- **Fast turns.** A turn is one card. Five seconds. A 6-player round is 8–12 minutes.
- **Nobody is out early.** Unlike elimination games, everyone plays until someone wins.
- **Scales to 6** without the game changing shape, which no other game here does.

## 1.2 Cost

The **engine is the hardest hidden-state problem in this folder** — a bigger `serializeSecret` than anything shipped, plus a per-player projection with a conditional reveal (§4.5). None of it is difficult once the shape is right, and all of it is unforgiving if it is wrong: a leak here shows one player another player's hand, which is not a bug, it is the end of the game.

The renderer is a fan of cards with drag-to-play, plus opponent hands as face-down stacks. Moderate — card layout on a phone with six players is a real design problem (§6.3).

The **licensing review (§1.3) is a genuine external dependency** and it must happen before art is drawn, not after.

## 1.3 The legal position, stated up front

**Game rules are not copyrightable.** The mechanics — match colour or number, action cards, draw penalties, a wild — are free to implement. This is well-settled.

**The name, the card faces, the trade dress and the specific card names are protected.** "UNO" is a trademark. The specific visual design of the cards, the colour scheme, and the distinctive names are Mattel's.

So: **own name, own art, own card names, own colours.** Not "a recolour of UNO" — a genuinely separate visual identity that happens to share mechanics.

| Generic | Voiid Cards |
|---|---|
| Colours: Red / Yellow / Green / Blue | **Ember / Pulse / Frost / Moss** |
| Skip | **Block** |
| Reverse | **Turn** |
| Draw Two | **Push 2** |
| Wild | **Voiid** |
| Wild Draw Four | **Voiid 4** |
| Calling "UNO" | **"Last card"** |

**Get a licensing/brand review before any art is commissioned** (open question O7 in [`README.md`](./README.md) §5). This is the same class of item as [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §8's audio licensing note — "the one item here that is a real liability rather than a quality issue" — and the cost of getting it wrong is discovering it after the art is paid for.

---

# 2. Rules as implemented

## 2.1 The deck

108 cards, the standard distribution:

| Card | Per colour | Total |
|---|---|---|
| 0 | 1 | 4 |
| 1–9 | 2 each | 72 |
| Block | 2 | 8 |
| Turn | 2 | 8 |
| Push 2 | 2 | 8 |
| **Voiid** | — | 4 |
| **Voiid 4** | — | 4 |

Four colours: Ember, Pulse, Frost, Moss.

A card is **one integer** on the wire: `colour × 16 + rank`, with colour 4 reserved for wilds. Compact, indexable, and unambiguous — the same instinct as Sea Battle packing a coordinate into 0–99.

## 2.2 Play

- Deal **7 cards** each. Flip one card to start the discard pile.
- If the flipped card is a **Voiid 4**, reshuffle it in and flip again. A Voiid 4 as the opening card means the first player is punished before making a decision.
- If it is a **Voiid**, the first player chooses the colour.
- Play proceeds clockwise; **Turn** reverses direction.
- On your turn, play a card matching the top by **colour**, by **rank**, or play a wild.
- **If you cannot play, draw one card.** You may play it immediately if it is legal; otherwise the turn passes.

**Draw one, not draw-until-playable.** Draw-until-playable produces turns where a player draws six cards while everyone waits, and it inflates hands, which lengthens the round. Draw-one is faster, bounds the turn, and makes the draw pile last.

## 2.3 Action cards

| Card | Effect |
|---|---|
| **Block** | Next player is skipped |
| **Turn** | Direction reverses. **With 2 players it acts as a Block** |
| **Push 2** | Next player draws 2 and is skipped, unless they stack (§2.4) |
| **Voiid** | Choose the active colour |
| **Voiid 4** | Choose the colour; next player draws 4 and is skipped, unless they stack. **Playable only when you hold no card of the current colour** — challengeable (§2.5) |

## 2.4 Stacking — decided ON, with a cap

**A Push 2 may be answered with a Push 2. A Voiid 4 may be answered with a Voiid 4. The penalty accumulates and passes on.**

**Types do not mix**: a Push 2 cannot be answered with a Voiid 4, and vice versa. Mixing makes the running total hard to reason about and hands the endgame to whoever holds one wild.

**Capped at 4 cards deep** — so at most `+8` from Push 2s or `+16` from Voiid 4s. When the cap is reached the pending penalty resolves immediately onto the next player.

Stacking is the most-loved house rule in this genre and the reason is that it converts a punishment into a *conversation*: the penalty travels around the table gathering weight and everyone watches it approach. Without stacking, a Push 2 is a small tax; with it, the moment a `+8` lands is the highlight of the round.

The cap exists because uncapped stacking in a 6-player game can produce a `+12` that removes a player from contention in one card. Four deep is enough for drama and short of a knockout.

## 2.5 Challenging a Voiid 4 — the bluff, and the design's best moment

A Voiid 4 is legal **only if the player holds no card of the current colour.**

**The next player may challenge instead of drawing.**

- **Challenge succeeds** (the player did hold a matching colour): the *challenger* draws nothing; the **bluffer draws 4** and the turn passes normally.
- **Challenge fails** (the play was legal): the challenger draws **6** instead of 4.

**On a challenge, the challenged player's hand is revealed — to the challenger only, for 4 seconds.**

This is the single most interesting thing in the game and it is also the hardest thing in the engine, because it is a **conditional, targeted, temporary information reveal**: one player, briefly, sees another player's private state, and nobody else does. §4.5 handles it, and it is the reason `serializeForPlayer` has to be genuinely per-recipient rather than a two-way split.

It is worth the cost. Without a challenge, a Voiid 4 is a card you play whenever you like and the legality rule is unenforceable theatre. With it, the game acquires the only bluff in this entire folder.

**Stacking interacts:** a stacked Voiid 4 may be challenged, and the challenge applies to the *most recent* Voiid 4 only.

## 2.6 Last card

**When you play your second-to-last card, you are automatically declared on "last card".** No button to press.

**But there is a 2.5-second window during which any opponent may tap "Caught!" — and if you did not have the "last card" state announced before their tap resolves, you draw 2.**

Unpacking, because this looks contradictory. The automatic declaration is what removes the *unfair* part of the traditional rule — losing because you tapped a button slowly on a phone with 200 ms of latency is a network test, not a game. The catch window is what keeps the *social* part: opponents are watching, and there is a beat where you are visibly vulnerable.

Concretely: the declaration is automatic and instant, so **the catch always fails.** It exists as a piece of theatre — a "Caught!" button that lights up for 2.5 seconds, that people will mash, and that plays a sound and a shake when it misses.

**That is a deliberate design of a mechanic that cannot be won**, and it needs to be an explicit decision rather than a bug someone finds. The alternative — a real race — is a latency test that punishes the player on worse mobile data, which is exactly the class of unfairness this app's netcode work exists to remove. Open question O5 below; the alternative is to remove the button entirely, which is more honest and less fun.

## 2.7 Winning and scoring

- A player **goes out** when they play their last card. The round ends immediately.
- **The winner scores the sum of every other player's remaining hand**, standard values: number cards face value; Block/Turn/Push 2 = 20; Voiid/Voiid 4 = 50.

**Match format is an option:**

| Format | Length | Default |
|---|---|---|
| **Single round** | 8–12 min | **Yes** |
| Best of 3 rounds | 25–35 min | — |
| First to 300 points | 30–45 min | — |

**Single round by default**, for the same reason Ludo defaults to 2 tokens ([`LUDO.md`](./LUDO.md) §2.7): a match played inside a chat needs to be a thing people finish. Point-based UNO is the traditional format and it is a 45-minute commitment.

`GameOutcome.scores` is the round score for the winner and 0 for everyone else in single-round mode; cumulative points in the longer formats. Higher is better.

`winnerId: null` is abandonment only.

## 2.8 Rules deliberately excluded

| Variant | Excluded because |
|---|---|
| **Jump-in** (playing an identical card out of turn) | A real-time race decided by latency. The same objection as §2.6, and here it would be constant rather than occasional |
| **Seven-Zero** (7 swaps hands, 0 rotates all hands) | Rotating six hidden hands is a large `serializeSecret` churn and it makes card-counting impossible, which removes the only skill in the game |
| **Draw until playable** | §2.2 |
| **Progressive Block** | Compounds with stacking into rounds where nobody plays a card |
| **Playing multiple cards of the same rank** | Halves round length in a way that mostly rewards a lucky deal |

---

# 3. Network model — R2

## 3.1 Pattern

Fourth row of [`GAMES.md`](../../GAMES.md) §4: pure turn-based, one `game_input` per action, one broadcast in response. No `tickHz`, no loop, no cost while idle.

No render clock, no interpolation. **The [`SNAKE.md`](../SNAKE.md) §2 stutter class cannot occur** — nothing advances on its own and every animation is triggered by an arriving frame.

## 3.2 The broadcast is different, and this is the game's defining networking property

Every other turn-based game broadcasts **one frame to everyone**. Voiid Cards broadcasts **N different frames** — one per player, each containing that player's own hand and nobody else's.

[`broadcast()`](../../../backend/games/src/index.ts#L69) today builds one string and publishes the same bytes to each recipient:

```ts
const frame = JSON.stringify({ type: 'game_state', /* ... */ payload: wire ?? m.state });
for (const uid of m.players) await pub.publish(`channel:user:${uid}`, frame);
```

**This game cannot be built on that.** It is the clearest case for [`README.md`](./README.md) §2.1's `serializeForPlayer`, and unlike Sea Battle — where the private state is placed once at the start — here the private state changes on **every single turn**, for at least two players, all round.

Cost: 6 JSON serializations per broadcast instead of 1, a few times a minute. Payload is ~250 bytes public plus ~30 bytes per card in hand. Nothing measurable.

## 3.3 Rate

Turn-based default, 60 inputs/minute ([`index.ts:29`](../../../backend/games/src/index.ts#L29)). A turn is one input. The only burst risk is the "Caught!" button (§2.6), which up to 5 players may tap repeatedly during a 2.5 s window — the rate limiter's silent drop handles it, and the client should debounce anyway.

## 3.4 What happens on a 3-second network stall

- **Not your turn:** nothing. Static screen.
- **Your turn:** static screen and a 30-second clock (§13.2).
- **You played during the stall:** the card animates to the discard pile and lands in a "waiting" state with a spinner after 800 ms. The frame arrives and resolves. **If the play is rejected, the card animates back into your hand** — never silently disappears.
- **The stall outlasts your turn:** the server auto-plays (§13.2) and you see the result on reconnect.
- **Socket down:** the "Reconnecting…" state ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §7). **Essential here** — a frozen card game with six players is ambiguous between "my connection died" and "someone is thinking", and with hidden hands a player cannot tell by looking.
- **On reconnect:** a full frame including your hand, from the server (§13.3). Nothing to reconcile.

## 3.5 Is it async?

**No**, for the same reason as Ludo ([`LUDO.md`](./LUDO.md) §3.6): with up to 6 players, a fully async game means five people blocked on the slowest. Voiid Cards is live, 30-second turns, one sitting.

**2-player is async-capable** on a 24-hour deadline, for free once the sweeper exists, but it is not the primary mode and the game is much better with four.

---

# 4. Engine design — R1

Folder: `backend/games/src/engine/cards/`.

**This is the most demanding R1 section in the folder.** Three separate serialization shapes with three different audiences, and a conditional reveal on top.

## 4.1 Interface surface

| Method | Present | Why |
|---|---|---|
| `applyInput` | yes | play / draw / choose colour / challenge / caught |
| `tick` | **no** | Turn-based |
| `serialize` | yes | **Public state only.** What a spectator sees |
| `serializeForWire` | **no** | §4.4 |
| `serializeForPlayer` | **yes** | Your hand, plus a conditional challenge reveal. **The hard one** |
| `serializeSecret` | **yes** | Every hand, the draw pile, the discard pile, the RNG |
| `deadlineAt` / `onTimeout` | **yes** | 30 s turn, 2.5 s catch window |
| `isFinished` | yes | — |

## 4.2 The three shapes, and the rule that keeps them honest

```
serializeSecret()          → everything. Server only. Never leaves the process
serialize()                → public only. Spectators, and the base for every player frame
serializeForPlayer(id)     → serialize() + exactly this player's private view
```

**The invariant, and it should be a comment in the code:**

> `serializeForPlayer` is `serialize()` **plus** additions. It never re-derives, never re-computes, and never removes.

Written as `{ ...this.serialize(), myHand, ...reveal }`, so the public part is *literally the same object* every time. This matters because the leak this game must not have is "a field that was supposed to be filtered out of the public shape but was not", and the structure above makes that impossible: **there is nothing to filter.** The public shape is built from public state and never sees a hand at all.

The inverse design — build the full state and strip private fields per recipient — is the one that leaks, because a new field defaults to *included*. Here a new field defaults to *excluded*, which is the direction a mistake should fail in.

## 4.3 `serialize()` — the public shape, field by field

```ts
{
  players: string[],
  handCounts: number[],
  discardTop: number,
  activeColour: 0 | 1 | 2 | 3,
  discardCount: number,
  drawCount: number,
  turn: number,
  direction: 1 | -1,
  phase: 'play' | 'chooseColour' | 'respondToDraw' | 'catchWindow' | 'done',
  pendingDraw: number,
  pendingType: 'push2' | 'voiid4' | null,
  stackDepth: number,
  lastCard: number | null,
  lastPlayer: number | null,
  onLastCard: boolean[],
  catchWindowUntil: number | null,
  challengeable: boolean,
  roundScores: number[],
  matchFormat: 'single' | 'bo3' | 'points',
  finishedOrder: number[],
  moveCount: number,
  deadlineAt: number | null,
  finished: boolean,
  winnerUserId: string | null,
}
```

Field by field — why each must survive a restart, which round-trips **on every input** ([`index.ts:279`](../../../backend/games/src/index.ts#L279)):

- **`players`** — seat order. Lose it and no input maps to a hand.
- **`handCounts`** — **the only thing anyone learns about another player's hand, and it is essential**: knowing Priya is on one card is what makes the game a game. Derived from the secret, but published here so the public shape never touches a hand (§4.2).
- **`discardTop`** — the card to match. The board.
- **`activeColour`** — **separate from `discardTop`, and this is the field a naive design loses.** After a wild, the top card *is* the wild and the active colour is whatever was chosen. Deriving colour from the top card would silently reset a chosen colour on every restore — every input — so the game would drift back to "wild, no colour" repeatedly and legality checks would go wrong in a way that looks like random rule violations.
- **`discardCount`** / **`drawCount`** — pile sizes for rendering and for reshuffle logic (§4.7). Counts only; contents are secret.
- **`turn`** / **`direction`** — whose turn and which way. Lose direction and a Turn card is silently undone at the next restore.
- **`phase`** — the state machine. Lose it and a player who has played a wild and owes a colour choice can instead play another card.
- **`pendingDraw`** / **`pendingType`** / **`stackDepth`** — the accumulating penalty (§2.4). Lose `pendingDraw` and the whole stack evaporates: the most dramatic mechanic in the game silently does nothing.
- **`lastCard`** / **`lastPlayer`** — what to animate. A cold-started client has no previous frame to diff, so one explicit field is cheaper and correct on the first frame.
- **`onLastCard`** — who is on one card. Public by design (§2.6).
- **`catchWindowUntil`** — epoch ms, absolute rather than a countdown, so it is correct whenever it is read.
- **`challengeable`** — whether the current pending Voiid 4 may be challenged (§2.5). Lose it and a challenge is either always or never available.
- **`roundScores`** / **`matchFormat`** / **`finishedOrder`** — multi-round bookkeeping. Lose `roundScores` in a best-of-3 and the match restarts its scoring.
- **`moveCount`** — monotonic; the idempotency key for deadline frames (§13.2).
- **`deadlineAt`** — serialized rather than recomputed, or an AFK player gets a fresh 30 s at every restore and the timer never fires.
- **`finished` / `winnerUserId`** — terminal, recovered from the user id on restore per [`cricket/index.ts:276-278`](../../../backend/games/src/engine/cricket/index.ts#L276-L278).

**Not present, and the game depends on it: any card in any hand, the draw pile order, the discard pile below the top, and the RNG state.**

## 4.4 No `serializeForWire()`

Public state is ~250 bytes and every field matters to the client. [`GameEngine.ts:70-72`](../../../backend/games/src/engine/GameEngine.ts#L70-L72): turn-based games omit it.

**And it must stay omitted, for a reason specific to this game.** `serializeForWire()` is explicitly allowed to clear per-frame delta buffers ([`GameEngine.ts:79`](../../../backend/games/src/engine/GameEngine.ts#L79)) and Snake relies on that ([`snake/index.ts:721-722`](../../../backend/games/src/engine/snake/index.ts#L721-L722)). `serializeForPlayer` is called **once per recipient** and must be pure. Having both, with opposite purity requirements, in a game where six per-recipient frames are built per broadcast, is exactly the kind of ordering invariant that produced Snake's subtlest bug ([`snake/index.ts:697-701`](../../../backend/games/src/engine/snake/index.ts#L697-L701)) — where the wire method mutated a counter `serialize()` was supposed to reset and "the delta encoding silently did nothing at all."

## 4.5 `serializeForPlayer(playerId)` — the hard one

```ts
serializeForPlayer(playerId: string): GameStatePayload {
  const seat = this.s.players.indexOf(playerId);
  const base = this.serialize();
  if (seat < 0) return base;                    // spectator: public only

  const out: GameStatePayload = { ...base, seat, hand: this.s.hands[seat] };

  // Conditional, targeted, expiring reveal (§2.5). ONE recipient, and only while it lasts.
  const r = this.s.reveal;
  if (r && r.toSeat === seat && Date.now() < r.until) {
    out.revealedHand = { seat: r.ofSeat, cards: this.s.hands[r.ofSeat] };
  }
  return out;
}
```

Four properties, all deliberate:

**1. Additive over `serialize()`.** §4.2's invariant. A new public field appears for everyone automatically; a new private field must be added here explicitly, which is the safe default direction.

**2. Pure.** No mutation, no counters, no buffers. Called once per recipient — six times per broadcast in a full game.

**3. The default is safe.** A caller with no seat gets `serialize()`. A spectator leak is structurally impossible rather than merely unwritten, which is what makes the spectator seat (open question O12) cheap to add later: it is already correct.

**4. The reveal is scoped three ways at once** — to one recipient (`toSeat`), to one subject (`ofSeat`), and to a deadline (`until`). All three conditions are checked in one expression, so there is no path where a reveal outlives any of them.

**The reveal is the reason this method exists in this form.** A simple "public + own hand" split could have been a boolean parameter on an existing method. A targeted, expiring, one-recipient reveal cannot — it needs the recipient's identity, which is exactly what `serializeForPlayer(playerId)` provides and what `serializeForWire()` deliberately does not.

**The reveal is also in `serializeSecret`** (§4.6), because it must survive the round-trip. A reveal dropped on the first restore after the challenge would flash for one frame and vanish, which is precisely the hand-cricket failure [`GameEngine.ts:86-91`](../../../backend/games/src/engine/GameEngine.ts#L86-L91) documents.

## 4.6 `serializeSecret()` — everything

```ts
serializeSecret(): GameStatePayload {
  return {
    hands: this.s.hands,        // number[][], by seat
    draw: this.s.draw,          // ordered draw pile
    discard: this.s.discard,    // full pile below the top
    rng: this.rng.seed,
    reveal: this.s.reveal,      // { toSeat, ofSeat, until } | null
  };
}
```

Persisted alongside the public state and handed back to `restore` ([`matches.ts`](../../../backend/games/src/matches.ts) `LiveMatch.secret`), **never in a broadcast** — `broadcast()` sends `state`, and `secret` is deliberately not part of it.

**The draw pile order is secret and must be**, for the same reason Ludo's RNG is ([`LUDO.md`](./LUDO.md) §4.6): a client that knows the next four cards it will draw plays a different, solved game. This is also why **the RNG state is here, not in `serialize()`** — the sequence *is* the shuffle, and `Rng`'s state is its seed ([`geometry.ts:113-131`](../../../backend/games/src/engine/snake/geometry.ts#L113-L131)), so publishing it publishes the deck order.

**The discard pile below the top is secret too**, which is less obvious. It is not sensitive in itself — every card in it was played in public — but it is what the draw pile is rebuilt from on a reshuffle (§4.7). Publishing it lets a client compute the post-reshuffle deck order exactly, which is the same leak one step removed. Publishing *the count* is fine and is in `serialize()`.

**A restore without the secret is fatal** and must abandon the match loudly rather than continue. There is no recovery: without hands there is no game state, and inventing them would produce a match whose public `handCounts` contradict its private truth. The same posture [`SEA_BATTLE.md`](./SEA_BATTLE.md) §4.4 takes, and the reason it should be effectively unreachable is that `state` and `secret` are written in the same statement to the same row.

**`restore` rebuilds field by field, never by casting**, the mistake [`cricket/index.ts:254-257`](../../../backend/games/src/engine/cricket/index.ts#L254-L257) documents: a blanket cast produced an engine "whose pending is undefined, and the very next serialize() throws — taking the games service down with any match that outlived a process restart."

## 4.7 Shuffle, reshuffle, and determinism

`Rng` (mulberry32) from [`geometry.ts:113`](../../../backend/games/src/engine/snake/geometry.ts#L113), promoted to `engine/rng.ts`. **Not `Math.random()`** — the engine is rebuilt from serialized state on every input, and global randomness "would produce a different world each time it was restored" ([`geometry.ts:105-111`](../../../backend/games/src/engine/snake/geometry.ts#L105-L111)).

**Fisher-Yates**, drawn from the seeded RNG, exactly as Snake shuffles its bot name pool ([`snake/index.ts:954-959`](../../../backend/games/src/engine/snake/index.ts#L954-L959)).

**Reshuffle:** when the draw pile empties, the discard pile *below the top card* is shuffled into a new draw pile. The top card stays.

Two things about reshuffle that are easy to get wrong:

- **It uses the same RNG stream**, so the sequence is continuous and reproducible from the seed. A separately-seeded reshuffle would break the "the whole match is reproducible from the seed" property that makes disputes auditable.
- **If both piles are empty** — possible in a 6-player game with heavy stacking — the pending draw is **truncated to what is available** rather than blocking. A game that deadlocks because it ran out of cards is worse than a `+8` that only delivers 5.

## 4.8 Tick-rate independence

No `tick()`, nothing integrated. Both time-dependent values — `deadlineAt` and `catchWindowUntil` — are **absolute epoch timestamps**, correct whenever read, regardless of restarts.

The catch window (§2.6) is the one place a turn-based game touches a short timescale. It is enforced by comparing against `Date.now()` on input, **not** by a timer: an input arriving after `catchWindowUntil` is rejected. The deadline sweeper's 1-second granularity closes the window if nobody taps, and a 500 ms overshoot on a 2.5 s theatrical window is irrelevant.

## 4.9 `applyInput`

```ts
{ play: number, colour?: 0|1|2|3 }   // card index in hand; colour required for wilds
{ draw: true }
{ challenge: true }
{ caught: number }                    // seat being accused
{ pass: true }                        // after drawing an unplayable card
```

Validation for `play`:

1. Not finished; `turn === seat`; `phase` allows a play
2. `play` is an integer index into **this player's own hand** — the client sends an index, never a card, so it cannot name a card it does not hold
3. The card at that index is legal against `discardTop` / `activeColour`
4. Wilds require `colour`; non-wilds ignore it
5. **Voiid 4 legality is checked but not enforced** — an illegal Voiid 4 is *accepted* and becomes challengeable (§2.5). This is the one place the engine knowingly allows an illegal move, because bluffing is the mechanic. The engine records whether it was legal so a challenge can be resolved
6. During `respondToDraw`, only a matching stack card or `draw` is legal

**Sending an index rather than a card is the anti-cheat.** A client that sends "I play the Frost 7" could name a card it does not hold; a client that sends "index 3" can only ever name a card it does have, and the server reads the card from its own copy of the hand.

All non-`silent`, per [`GameEngine.ts:38-40`](../../../backend/games/src/engine/GameEngine.ts#L38-L40): a move is the state change.

---

# 5. Anti-cheat

## 5.1 What a modified client can express

| Attempt | Defence |
|---|---|
| **See another hand** | Hands are never in any frame sent to that player. Structural (§4.2, §4.5), not a check |
| **See the draw pile** | Secret channel, never broadcast (§4.6) |
| **Predict the shuffle** | RNG state in `serializeSecret` (§4.6). The seed *is* the deck order |
| Play a card it does not hold | Input is an **index into the server's copy** of the hand (§4.9) |
| Play an illegal card | Legality checked server-side |
| Play out of turn | `turn` check |
| Play twice | `phase` advances inside `applyInput` |
| **Play an illegal Voiid 4** | **Deliberately allowed** — it is the bluff (§2.5), and it is punished by challenge |
| Challenge without cause | Allowed and punished: a failed challenge draws 6 |
| Skip a draw penalty | `pendingDraw` is server state |
| Tap "Caught!" after the window | Rejected against `catchWindowUntil` |
| Flood inputs | 60/min, silent drop ([`index.ts:29-61`](../../../backend/games/src/index.ts#L29-L61)) |
| Input into another match | Membership checked from the live record ([`index.ts:262-264`](../../../backend/games/src/index.ts#L262-L264)) |

## 5.2 The leak surface, named

**This is the only game in the folder where the primary risk is an information leak rather than an illegal move**, so it is worth enumerating every path a hand could take to the wrong client:

1. **`serialize()` including a hand.** Prevented by §4.2's structure — the public shape is built from public state and never touches `hands`.
2. **`serializeForPlayer` returning the wrong seat's hand.** One line, `this.s.hands[seat]`, where `seat` came from `players.indexOf(playerId)`. Must be unit-tested for every seat.
3. **The reveal outliving its scope.** Three conditions in one expression (§4.5).
4. **A spectator receiving a player frame.** `seat < 0` returns `base`. Test it.
5. **`broadcast()` falling back to `m.state` for a recipient.** The runtime change ([`README.md`](./README.md) §2.1) must prefer `serializeForPlayer` when present — and when it is absent for a recipient, the fallback is `serialize()`, which is *public*, so the failure mode is "a player cannot see their own hand" rather than "a player sees someone else's". **The fallback must fail closed, and it does.**
6. **The secret reaching a client.** `broadcast()` sends `state`; `secret` is a separate field on `LiveMatch` and is never part of it ([`matches.ts`](../../../backend/games/src/matches.ts)).

**Test 1, 2, 3 and 4 explicitly**, with an assertion that no frame for player A contains any card from player B's hand. That is a single property test over a simulated match and it is the most valuable test in this engine.

## 5.3 What is not defended

**Two players sharing hands out of band** — a side chat, a phone camera. Undetectable and unfixable. Same conclusion as everywhere: matches are invite-only between people who already talk, there is no ranked ladder and no prize ([`GAMES.md`](../../GAMES.md) §3, §7). A social problem.

---

# 6. Client rendering

## 6.1 What it reuses

| Piece | Source | Notes |
|---|---|---|
| `GamesEngine` | existing | Per-player frames arrive on the same channel |
| Lobby | [`GameLobbyView.swift`](../../../apps/ios/Voiid/Voiid/Games/GameLobbyView.swift) | **Extended to N seats — shared with Ludo and Snake** ([`README.md`](./README.md) §2.4) |
| `GameAudio` / `GameHaptics` | [`GameAudio.swift`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift) | One new `soundNames(for:)` entry |
| Turn indication patterns | [`CricketMatchView.swift`](../../../apps/ios/Voiid/Voiid/Games/CricketMatchView.swift) | Whose-turn treatment |

## 6.2 What it adds

Cards. All of it is view work, none of it is `Canvas`.

**iOS:** plain SwiftUI. Cards are views with `matchedGeometryEffect` for the hand → discard transition, which is exactly the tool for "this card was there and is now here" and produces the right animation for free.

**Android:** Compose, `AnimatedContent` / shared-element transitions, mirroring iOS.

**No `Canvas`, no Metal.** [`GAMES.md`](../../GAMES.md) §4 specifies plain views for card games and it is right: cards are rectangles with text and a shadow, and view-based layout gives accessibility, dynamic type and hit-testing that a `Canvas` would have to reimplement.

## 6.3 The layout problem: six players on a phone

The real design work.

**Your hand: a fanned row along the bottom**, scrollable horizontally when it exceeds ~8 cards. Cards overlap so ~40% of each is visible; the focused card lifts and fully reveals.

**Opponents: a row of compact strips at the top**, one per player:

```
  ▣ Priya   [7]        ▣ Arun  [1] ●LAST     ▣ Sam  [4]
```

Name, card count, last-card indicator, turn highlight, and a small face-down fan whose card count is *visually* accurate up to 5 and then shows a number. Seeing that someone has two cards is the most important public information in the game and it must be readable without counting.

**Centre: the discard pile and the draw pile**, side by side, with the active colour as a wash behind the discard — essential after a wild, where the top card's own colour is wrong.

**Direction indicator:** an arc arrow around the centre that flips on a Turn. Small, and the single most confusing thing in a card game if absent.

**With 6 players the top strip is tight.** Two rows of three on compact screens, and the strips shrink to icon + count. The active player's strip always expands.

## 6.4 The information hierarchy

In priority order, because at six players there is more to show than room to show it:

1. **Your hand** — half the screen.
2. **The discard top and active colour** — what you can play.
3. **Whose turn it is.**
4. **Who is on one card** — must be unmissable; it changes everyone's play.
5. **Pending draw stack** — a large `+6` badge on the pile when one is live.
6. **Direction.**
7. **Everyone's card count.**

---

# 7. Controls

## 7.1 The scheme

- **Tap a card to select**; it lifts. **Tap again to play.** Two-step, for the same reason as [`SEA_BATTLE.md`](./SEA_BATTLE.md) §7.2: overlapping cards in a fan are sub-minimum touch targets and a mis-play is irreversible.
- **Or drag a card to the discard pile.** Faster and more satisfying for people who have played the game; drop anywhere in the centre third.
- **Illegal cards are dimmed to 40% and cannot be selected.** Not merely rejected on play — showing legality *before* the tap is what makes the game fast, and it is free from state the client already has.
- **Draw pile is a tap.** If the drawn card is playable, it appears in the hand highlighted with a "play it?" affordance for 3 seconds, then the turn passes.
- **Colour choice after a wild:** a four-way radial picker at the point of drop, thumb-sized quadrants.
- **Challenge / Caught:** large buttons that appear only when legal, in the thumb zone.

## 7.2 One-handed and small screens

- **The hand is along the bottom** — thumb territory.
- **Cards enlarge on selection** to well above the minimum target before the committing tap.
- **Horizontal scroll for large hands**, with the newest card always scrolled into view — after a `+4` a player must be able to see what they got without hunting.
- **Sorting.** A hand sorted by colour then rank, with a toggle for draw order. Not cosmetic: an unsorted 12-card hand on a phone is genuinely hard to read, and sorting is the single biggest usability win in the game.

---

# 8. Visual design

## 8.1 Art direction

**Own identity, mandated by §1.3 rather than chosen.** That is a constraint and also an opportunity: the game does not have to look like a plastic deck.

- **Cards:** dark faces, luminous glyphs. The rank is large and central; the colour is carried by a full-bleed edge glow rather than a flat fill, so a fanned hand reads as bands of colour with numbers on top.
- **Colours:** Ember (warm orange-red), Pulse (violet), Frost (cyan), Moss (green). **Deliberately not red/yellow/green/blue** — trade dress (§1.3) and a better fit for the app's dark palette.
- **Action cards** use a symbol, not a word: Block is a bar, Turn is a rotation arc, Push 2 is a double chevron with "2".
- **Wilds** are the only cards with all four colours, as a quartered glow.
- **The discard pile** shows the top card at a slight random rotation (±4°, seeded so all clients agree) with two or three cards visible beneath. A pile that looks like a pile.

## 8.2 Colour is never the only channel

The most important accessibility case in this folder, because **the game's core rule is "match the colour"** — a colour-only design is unplayable for a colourblind player, not merely harder. [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13 flags Snake for identifying players by colour alone; this is that problem multiplied.

**Every colour carries a distinct glyph in the card corner**: Ember ◆, Pulse ●, Frost ▲, Moss ■. Present on every card, on the active-colour indicator, and in the wild colour picker.

**This is not an optional accessibility mode.** It ships on by default for everyone, because a symbol system also makes the game faster to read for players with normal colour vision — the corner glyph is legible in a fan where the colour band is 40% occluded.

## 8.3 The pending stack

When `pendingDraw > 0`, the discard pile grows a large, pulsing `+4` / `+6` / `+8` badge, escalating in size and intensity with the stack depth, with a subtle shake at `+6` and above.

This is the game's most dramatic state and it should dominate the screen. Everyone at the table is watching that number travel, and the player it is pointing at should feel it.

---

# 9. Motion and feel

Behind reduce-motion ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13, open question O13). Under it: cards cross-fade between positions, no shake, no particles, no card flips — and the game must remain fully playable and fully legible, which is the test that separates feel from information.

| Moment | Motion | Duration | Curve |
|---|---|---|---|
| Card selected | Lift 24 pt, scale 1.08, shadow deepens | 180 ms | `spring(0.24, 0.7)` |
| **Card played** | Travels hand → discard, rotating to its resting angle, scaling down | 320 ms | `spring(0.32, 0.78)`, shared-element |
| Card drawn | Slides from the draw pile into the hand, flipping face-up on arrival | 380 ms | `easeOut`, flip at 60% |
| Opponent plays | Card animates from their strip to the discard, face-down until 50% then flipping | 420 ms | `easeInOut` |
| Opponent draws | A face-down card slides to their strip; count increments | 300 ms | `easeOut` |
| **Push 2 / Voiid 4 lands** | Badge scale 1.0 → 1.4 → 1.0, pile shake 4 px, colour flash toward the victim's strip | 500 ms | `spring(0.2, 0.5)` |
| **Stack grows** | Badge counts up, escalating shake and pitch | 300 ms per increment | `spring(0.16, 0.5)` |
| Direction reverses | Arc arrow spins 180°, board hue sweeps once | 420 ms | `easeInOut` |
| Colour chosen | Radial wash from the discard pile in the new colour | 340 ms | `easeOut` |
| **Challenge reveal** | The challenged hand fans out over the centre, then collapses after 4 s | 400 ms in, 300 ms out | `spring(0.3, 0.75)` |
| Last card | The player's strip pulses; a "LAST CARD" tag drops in | 500 ms | `spring(0.26, 0.6)` |
| **Caught! miss** | Button shakes, greys out, "too late" fades | 400 ms | `easeOut` |
| Round won | Winner's remaining space clears, others' hands fan face-up for scoring | 800 ms staggered 60 ms | `easeOut` |

Three notes.

**The card-played animation is the whole game's feel.** A card that teleports from hand to pile is a state update; a card that travels, rotates and lands is a *play*. `matchedGeometryEffect` and its Compose equivalent make this nearly free, and it should be the first thing built and the last thing compromised.

**Opponent cards flip at 50% of their travel**, not at the start. A card that is face-down for the first half and face-up for the second reads as a reveal — the information arrives at the moment of the flip, which is the beat everyone is waiting for. Flipping immediately throws the moment away.

**The stack escalation is the best 500 ms in the game.** Each increment gets bigger, shakier and higher-pitched. By `+8` it should be genuinely alarming. This is where the drama in §12.2's hook actually lives, and it is a badge, a shake and a pitch ramp.

---

# 10. Sound

Inherits [`SOUND_DESIGN.md`](../SOUND_DESIGN.md). New `soundNames(for:)` entry ([`GameAudio.swift:282`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L282)).

## 10.1 The shared catch sound

> **The catch moment in Voiid Cards is: a stacked draw penalty lands on you.**

Per [`README.md`](./README.md) §1.5. Precisely — **when the stack resolves onto you**, not on every Push 2. A `+2` you can answer is a threat; a penalty you must take is your attempt being ended by an opponent, which is what `catch` means ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §3).

Concretely, `catch.wav` plays when: `pendingDraw > 0` resolves onto you and you could not or did not stack.

Played **unmodified**, layered never replacing: `catch.wav` **+** the card-deal sound of the penalty cards arriving, whose length scales with the count. A `+8` is `catch` plus eight cards landing, which takes about a second and is exactly as punishing as it should feel.

**Not for a plain Block or Turn.** Being skipped is an inconvenience, not an interception. Overusing `catch` is precisely what the shared-vocabulary rule exists to prevent.

## 10.2 The palette

**Physical, recorded.** Cards have a famously specific sound and it is trivially recordable — [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §5.2's "record it" recommendation applies directly.

| Event | Sound | Notes |
|---|---|---|
| Card selected | `card_lift.wav` | Very short paper slide, ~60 ms |
| **Card played** | `card_play_1..4.wav` | Card onto a pile. ~140 ms. **Most-triggered sound in the game** — 60+ per round. 4 variants plus ±4% varispeed, per the chalk argument ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.3) |
| Card drawn | `card_draw.wav` | Slide off the deck |
| Multiple cards drawn | `card_draw` ×N at 90 ms intervals | The rhythm *is* the punishment |
| Block | `block.wav` | Short, blunt, final |
| Turn | `reverse.wav` | A sweep that changes direction mid-sound |
| Push 2 played | `push.wav` | Rising, threatening |
| **Stack grows** | `push.wav` **pitched up 8% per level** | The escalation, and the existing varispeed does it for free |
| **Penalty lands on you** | **`catch.wav`** + N × `card_draw` | §10.1 |
| Penalty lands on someone else | `card_draw` ×N only | No `catch` — it is not your attempt that ended |
| Wild played | `wild.wav` | Shimmering, colourless |
| Colour chosen | `colour_pick.wav` | Pitched per colour — a four-note vocabulary players learn |
| Challenge issued | `challenge.wav` | Sharp, confrontational |
| Challenge resolved | `reveal.wav` (reuse RPS's) | The hand fans out |
| Last card | `last_card.wav` | Bright alarm, unmistakable, plays for **everyone** |
| Caught! miss | `caught_miss.wav` | Deflating |
| Round won | Existing stingers + `crowd_applause` | Reuse cricket's |

**No ambience bed.** Card games are played in bursts of attention with a lot of silence, and the silence is what makes the next card land.

**Mono, always** ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §6.6 — a stereo asset is a hard AVAudioEngine crash).

## 10.3 Haptics

- **Card played:** light transient.
- **Penalty lands on you:** the existing `death()` pattern ([`GameHaptics.swift:89`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameHaptics.swift#L89)), intensity scaled by the stack.
- **Stack grows while it is heading toward you:** escalating tick per increment. The tactile version of the badge.
- **Last card (yours):** double transient.
- **Your turn:** light, foreground and screen-on only. With six players the turn comes round often.

---

# 11. Bots

Client-side for practice, and server-side for timeout auto-play (§13.2) — one policy, two consumers.

## 11.1 What difficulty varies

**Never the deal, never the draw.** A bot that gets better cards is a cheat, and in a game where the deck is hidden it is undetectable, which makes it the most tempting and most corrosive shortcut available. It must be stated in the code.

| Band | Policy |
|---|---|
| 0.0–0.25 | **Random legal card.** Random colour on a wild |
| 0.25–0.5 | **Greedy:** play action cards over numbers, dump the largest hand colour, choose the colour it holds most of |
| 0.5–0.75 | **Card counting.** Tracks which colours each opponent has failed to play on (a strong signal they are void in it), and which have been played out of the 108. Steers toward colours opponents are void in; **holds wilds for when it is stuck or for the endgame** rather than dumping them |
| 0.75–1.0 | **Threat-aware.** All of the above, plus: targets whoever is closest to going out with Blocks and Push 2s, saves a Push 2 to answer an incoming stack, bluffs a Voiid 4 when its read says the next player will not challenge, and challenges when the count says a Voiid 4 was likely illegal |

Between bands, the higher policy with probability `skill` — the [`RpsBot.chooseThrow`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L50) construction. Continuous, and it makes a mid-skill bot inconsistent rather than uniformly mediocre.

**Every bot sees only what a player sees**: public counts, the discard history, and its own hand. It does not read the draw pile or other hands. This must be enforced by construction — the bot takes a *player-view* state object, not the engine — so that it is impossible rather than merely intended.

## 11.2 What the top of the scale can and cannot do

In the register [`RpsBot.swift:17-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L17-L21) sets:

**Voiid Cards is roughly 70% luck.** The deal decides a lot, the draw decides more. In a 4-player game the baseline is 25%; a strong player against three random players wins about **32–36%**.

> **The hardest bot will lose to a beginner roughly six times in ten, and no amount of card counting changes that.** Any implementation whose "hard" difficulty reliably beats a competent human is dealing itself better cards.

**It can:** exploit colour voids, hold wilds correctly, target the leader, answer stacks, and win a long series measurably more often.

**It cannot:** win with a bad hand, know the draw pile, or read a human's bluff beyond the statistics.

**Difficulty is labelled by playstyle, not strength** — "Loose / Steady / Sharp / Ruthless" — for the same reason as Ludo ([`LUDO.md`](./LUDO.md) §11.2): strength labels promise something a 70%-luck game cannot deliver, and a player who loses to "Easy" will correctly conclude the labels are meaningless.

## 11.3 Presentation

- **Thinking delay 800–1800 ms**, longer when the decision is genuinely close. An instant play reads as a lookup table.
- **Occasional suboptimal play at high skill** — 10% when the gap is small.
- **Plausible names**, per [`snake/index.ts:95-101`](../../../backend/games/src/engine/snake/index.ts#L95-L101).
- **Bots must sometimes fail to challenge a bluff**, or bluffing against them becomes free and the mechanic collapses.

---

# 12. Progression and retention — R3

## 12.1 The floor

[`README.md`](./README.md) §1.6's four, adapted for N players:

1. **Rematch** — same group, same options, one tap, **and anyone who taps in within 30 s is in.** Requiring all six is how a session dies.
2. **Post-match summary** — placement, points, cards played, biggest stack survived, biggest stack delivered, wilds played.
3. **Head-to-head → the group table.** Wins per player in this group.
4. **Share result into the chat** — the placement table, plus the biggest stack of the round as a callout.

## 12.2 The specific hook

**Aimed cruelty, and everyone watching it happen.**

The named mechanic: **the travelling stack.** A `+2` becomes a `+4` becomes a `+6` as it goes round, and everyone can see exactly whose turn it will resolve on. There are four or five seconds where one specific person is about to eat eight cards and everybody knows it. That is the most reliably social moment any game in this folder produces, and it happens several times a round.

It works because:

- **It is chosen, not rolled.** Ludo's captures are the dice's fault. A stack is somebody's decision, aimed at somebody.
- **It is public and legible.** A big number, growing, pointing at a name.
- **It is survivable.** The victim keeps playing, which means they can retaliate — so the cruelty compounds into a rivalry rather than ending someone's game.

## 12.3 How it uses the fact that this is a messenger

- **Group-chat invites** — the entry point Ludo also needs ([`LUDO.md`](./LUDO.md) §12.3). [`OpponentPickerSheet.swift`](../../../apps/ios/Voiid/Voiid/Games/OpponentPickerSheet.swift) excludes groups today because they "would imply a lobby this system does not have." This game and Ludo build it.
- **The trash talk lands in the thread the game was arranged in.** No other game here generates as much of it, because no other game here has a "look what I just did to you" moment.
- **The shareable artifact is the moment, not the result** — "Priya took +8" is a better message than "Arun won", and it should be the thing the share card leads with.
- **Six seats is the biggest group this app can put in one interactive space.** Nothing else in the product does that.

## 12.4 What the first 30 seconds feel like

- **0–5 s.** Accept from a group thread. Lobby fills visibly as people join.
- **5–8 s.** Cards deal into your hand one at a time, ~90 ms apart. **The deal is the best possible opening** — it is tactile, it is the same in every card game anyone has played, and it takes exactly as long as it needs to.
- **8–12 s.** Discard flips. Your legal cards brighten and your illegal cards dim. **The game has just taught its entire core rule with a lighting change** — no text, no tutorial.
- **12–20 s.** Someone plays. Direction indicator appears. Someone plays a Block and a name gets skipped.
- **20–30 s.** Your turn. You tap a card and it flies to the pile. If a Push 2 has landed on you, you learn stacking from a badge and a highlighted card in your hand.

**Legality-by-dimming is the single best onboarding decision available in this game** and it is why §7.1 makes it a rule rather than a nicety.

Still ship a one-screen rules sheet behind a `?` for the two house rules people will assume differently: stacking on with a 4-deep cap (§2.4), and draw-one rather than draw-until-playable (§2.2).

## 12.5 What someone with 50 matches is chasing

- **The group table.** Standing among a fixed set of friends, over months.
- **Biggest stack delivered.** A leaderboard of cruelty. Free from data already recorded, and it is the number people will actually compete over.
- **Bluff success rate on Voiid 4s.** The only genuine skill statistic in the game (§2.5) and the most interesting one.
- **Card counting as a real, learnable skill.** A player who notices Priya has not played Frost in six turns knows something. Nothing in the UI helps with this, deliberately — surfacing it would remove the skill.
- **Survived-a-+8** as a badge-worthy event.

Explicitly **not**: card backs, cosmetics, XP. [`SNAKE.md`](../SNAKE.md) §3.5 documents the failure — "the skin picker is a preference, not a reward, so there is no reason to keep playing."

---

# 13. Failure and edge cases

## 13.1 Disconnect

Same shape as Ludo, and worse for the same reason: up to five people blocked on one.

- **The match continues.** A disconnected player's turns are **auto-played by the mid-skill bot** at timeout, never skipped. Skipping would make disconnecting a strategy — you cannot be stacked on if your turn never comes.
- **Their strip shows a disconnected badge.**
- **Reconnect resumes seamlessly** — and the reconnecting client gets **its hand back from the server** (§13.3).
- **After 3 consecutive auto-plays** the player is marked absent and auto-plays immediately with no timer wait, so the round speeds up rather than grinding.

## 13.2 Deadlines

Needs the sweeper ([`README.md`](./README.md) §2.3).

| Situation | Deadline | On expiry |
|---|---|---|
| Turn, live | **30 s** | **Auto-play** the mid-skill bot's choice |
| Turn, absent player | 3 s | Auto-play immediately |
| Colour choice after a wild | **10 s** | Auto-choose the player's most-held colour |
| Respond to a draw stack | **15 s** | Auto-take the penalty |
| Challenge window | **8 s** | Auto-decline; take the penalty |
| Catch window | **2.5 s** | Closes (§2.6) |
| Async 2-player | 24 h | Auto-play, warning at 18 h |
| Whole match | 10 min of no input from anyone | Abandon, `winnerId: null` |

**Auto-play, not forfeit**, for the reason [`LUDO.md`](./LUDO.md) §13.2 gives: forfeiting one of six players mid-round changes the game for everyone else — their cards leave the deck, the turn order changes, and the round becomes something nobody signed up for.

**30 seconds**, not 60: a turn is "pick a card". A visible countdown from **10 s**, escalating.

**Idempotency:** timeout frames carry the `moveCount` they were scheduled against (§4.3) and are dropped on mismatch. Without it a duplicate delivery plays two cards.

## 13.3 Rejoin — the case this game is built around

**A rejoining player must receive their hand from the server.** This is the exact case [`README.md`](./README.md) §2.1 describes as collapsing the "the client remembers" workaround: after a reinstall, a second device, or a cold start, the client remembers nothing.

`handleJoin` already handles rejoin ([`index.ts:355-359`](../../../backend/games/src/index.ts#L355-L359)) — "a rejoin after that is a genuine resync and still gets a frame." That frame must come from `serializeForPlayer`, and the runtime change is what makes it possible.

**Without it, a player who backgrounds the app during a card game loses the game.** That is not an edge case on a phone; it is a phone call.

## 13.4 A player leaves deliberately

- **2 players:** the other wins.
- **3–6 players:** the leaver's **hand stays in the game and is auto-played** to the end. Removing it would return their cards to nowhere and change everyone's counting. Recorded as a loss, flagged as a walkover.

## 13.5 Both piles empty

§4.7: the pending draw is truncated to what is available. If a player cannot draw and cannot play, the turn passes. Rare — it needs a 6-player game with heavy stacking — and the alternative is a deadlock.

## 13.6 The engine restarts mid-match

- No tick loop to lose.
- State from Redis, or the durable table on a TTL miss. **A live 10-minute round fits inside the 1-hour TTL** ([`redis.ts:27`](../../../backend/games/src/redis.ts#L27)), so live Voiid Cards is not strictly blocked on the durable table — only the async 2-player mode is.
- **The secret must reload with it** (§4.6). Same row, same write. **A restore without it must abandon loudly**, because there is no recovery from lost hands.
- Deadlines survive in the sorted set; `deadlineAt` is in `serialize()` as a backstop.

## 13.7 Ties

Impossible — one player goes out first. In point-based formats a tie on points is broken by fewest cards remaining, then by earlier finish.

## 13.8 A reveal outlives its window

Prevented by §4.5's three-condition check on every call. **Test it explicitly:** a frame built for the challenger after `until` must contain no `revealedHand`, and a frame built for anyone else must never contain one at any time.

---

# 14. Build plan

## Phase 0 — shared infrastructure *(not this game's work; hard blockers)*

1. **`serializeForPlayer` + per-recipient broadcast** ([`README.md`](./README.md) §2.1) — ships with Sea Battle, build step 0.
2. **Multi-seat lobbies** (§2.4) — ships with Ludo, and with Snake 3–6P.
3. **Deadline sweeper** (§2.3).

**All three should already exist by the time this game starts**, which is why [`README.md`](./README.md) §3 places Voiid Cards at step 6. Starting it earlier means building one of them alone.

## Phase 1 — engine, headless

`engine/cards/` + registry + tests. The tests that matter are the leak tests:

- **No frame for player A contains any card of player B's hand**, asserted over a full simulated 6-player round. The single most valuable test in this engine (§5.2)
- Spectator (`seat < 0`) receives no hand at all
- The challenge reveal reaches exactly one recipient and expires
- **Serialize → restore → serialize byte equality**, specifically covering `activeColour`, `pendingDraw`, `direction` and `phase` (§4.3)
- **Restore with the secret preserves the exact draw order**; restore without it abandons and logs
- Stacking: same-type only, capped at 4, resolves correctly
- Voiid 4 challenge: both outcomes, and the reveal
- Reshuffle preserves determinism and never loses a card — **assert 108 cards exist across all piles and hands after every single action.** A card conservation invariant catches an entire class of bug at once
- A full round from a fixed seed produces a fixed result

## Phase 2 — iOS practice mode

Renderer, hand fan, drag-to-play, legality dimming, colour picker, the bot at all four bands, sound, motion. **No networking**, 1 human + 3 bots.

Where the game is tuned, and where §9's card-play animation is found.

## Phase 3 — iOS online, 2 players

On top of `serializeForPlayer`. Proves the per-recipient path end to end with the smallest possible case. **2-player first, deliberately** — it exercises the entire hidden-state design without needing the lobby work.

## Phase 4 — 3–6 players

Multi-seat lobby, group entry, the six-player layout (§6.3), auto-play on timeout.

## Phase 5 — Android parity

Phases 2–4. iOS is the reference; constants identical ([`SNAKE.md`](../SNAKE.md) §2.4).

## Phase 6 — retention

Post-match summary, group rematch, group table, biggest-stack leaderboard, bluff stats, share-to-chat.

## Phase 7 — polish

Rules sheet, hand sorting, colourblind glyphs (**on by default**, §8.2), reduce-motion, accessibility pass.

---

# 15. Open questions

1. **How close to UNO?** *(O7 in [`README.md`](./README.md) §5, blocking on art)* Recommendation: **own name, own colours, own card names, own art** (§1.3). The rules are free; the trade dress is not. **A licensing/brand review before art is commissioned, not after.**

2. **Match format default.** Recommendation: **single round** (§2.7). Point-based is the traditional format and a 45-minute commitment; a match inside a chat needs to be a thing people finish.

3. **Stacking on, and capped at 4?** Recommendation: **yes** (§2.4). It is the most-loved house rule and the source of the game's best moment (§12.2). The cap prevents a one-card knockout in a 6-player game.

4. **Voiid 4 challenge in or out?** Recommendation: **in** (§2.5). It is the only bluff mechanic in this entire folder and the only reason the legality rule is more than theatre. It is also the most expensive thing in the engine — a targeted, expiring, one-recipient reveal — so it is a genuine cost/value decision rather than a free win.

5. **The "Caught!" button that cannot be won.** (§2.6) Recommendation: **keep it, as theatre.** A real race is a latency test that punishes the player on worse mobile data. The honest alternative is to remove the button, which is cleaner and less fun. **This one genuinely needs a decision** rather than a default — it is the only place in this folder proposing a deliberately unwinnable interaction.

6. **Async 2-player mode?** Free once the sweeper exists, but it is a different game — Voiid Cards with 24-hour turns is not really this game. Recommendation: **support it, do not lead with it.**

7. **Do bot matches count for the group table?** Cross-cutting (O10). Recommendation: no.

8. **Options-bag typing.** *(O11)* `matchFormat` is a string, `players` and `rounds` are ints. The bag is `[String: Int]` on both clients ([`GamesAPI.swift:37`](../../../apps/ios/Voiid/Voiid/Networking/GamesAPI.swift#L37)) and Snake already smuggled its skin alongside as a sibling field. **This is the fourth game in this folder wanting a string option.** Widen the type once.

9. **Reduce-motion.** §9 specifies card travel, shake, escalating stack animation and a reveal fan. The switch does not exist ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13). The reduced version must remain fully legible — a card that cross-fades still needs to show *where it came from*, or the game becomes unreadable rather than merely less lively.
