# Chess

> **Status:** design only, nothing built. **We recommend deferring this game** — see §1.
> **Kind:** turn-based, 2 players, deep rules. No `tickHz`.
> **Blocked on:** durable turn-based state ([`README.md`](./README.md) §2.2) and the deadline sweeper (§2.3). Both ship with Sea Battle.
> **Reference implementations to read first:** [`tictactoe/index.ts`](../../../backend/games/src/engine/tictactoe/index.ts) for the turn model, [`SEA_BATTLE.md`](./SEA_BATTLE.md) for the async pattern this game copies wholesale.

---

# 1. What the game is — and the honest argument against building it

Chess. The rules are the rules.

**This section is the most important one in the document, and it argues against the rest of it.**

## 1.1 This is a solved market

There are excellent, free, mature chess apps. lichess is open source, has a world-class engine, puzzles, opening books, tournaments, analysis, a huge user base, and costs nothing. Chess.com has the largest player base in history. Both have been refined for over a decade by teams who do nothing else.

**Building chess in Voiid means spending months to produce something worse than a free app the player already has.** Not slightly worse — categorically worse, on every axis a chess player cares about: engine strength, analysis, puzzles, opening prep, time controls, rating pools, and the thing that actually matters, *finding an opponent at your level in ten seconds.*

Voiid will never have a rating pool. It has your contacts.

That is not pessimism, it is the correct framing, and any plan for this game that does not start there is going to produce a disappointment.

## 1.2 The one argument that survives

**Rivalry with one specific person.**

Not chess quality. Not features. The scenario where Voiid Chess wins is:

> You and one friend have a chess game running. It has been running for three days. The record is 7–5. Neither of you would install a chess app to play each other, and neither of you would find the other on lichess.

That is real, and it is genuinely something the big apps do badly — they are optimised for finding *any* opponent, not for a permanent slow game with one person you already talk to. A game living inside the thread where you already talk is a different product from a game living in a chess app.

But notice what that argument depends on: **it is entirely about head-to-head records and async play**, and neither of those is a chess feature. Both are [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) items that every game in this folder needs.

## 1.3 The recommendation

**Defer. Build head-to-head records and async play first, ship Sea Battle on them, and see whether anyone uses them.**

Sea Battle tests exactly the same hypothesis — *"will people keep a slow, async, one-opponent game running for days inside this app?"* — at roughly a tenth of the cost. It shares the durable-state work, the turn notifications, the async UI, and the head-to-head record.

**If Sea Battle's async loop works, the argument for chess becomes real and it becomes a much smaller project**, because the infrastructure is already proven and only the rules and renderer remain. **If it does not work, chess would have been months spent on a feature nobody asked for twice.**

This document exists so that the decision can be made with the design in hand, and so that if the answer is yes, the work is already scoped.

## 1.4 What it would cost

The largest rules surface in this folder by a wide margin. Castling through check, en passant discovered pins, stalemate detection, threefold repetition, the fifty-move rule, insufficient material, promotion under check — every one is a place correctness bugs live, and every one has been paid for already by libraries with perft suites.

**Which is why §4.1 recommends not hand-rolling it**, and why that recommendation is a deliberate, flagged disagreement with [`GAMES.md`](../../GAMES.md) §4.

With a library: the engine is small. The renderer is a board and 32 pieces — comparable to Ludo. The clock is real work (§2.6). The bot is where the honest limits are (§11).

Estimate: **2–3× Sea Battle**, most of it in the clock, the bot, and the long tail of rules that are individually small and collectively not.

---

# 2. Rules as implemented

**Standard FIDE rules, complete. No variants, no house rules, no simplifications.**

Chess is the one game in this folder where deviation is not a design choice, it is a bug. Every other game here has folk variants and this doc picks one; chess has a single canonical rule set that every player knows, and a chess implementation that gets a rule wrong is not "a variant", it is broken.

## 2.1 The complete rule set

The full list, because "standard chess" is a large surface and each item is a place to be wrong:

| Rule | Detail |
|---|---|
| **Movement** | All six piece types, standard |
| **Check** | A move that leaves your own king in check is illegal — including a move by a *pinned* piece |
| **Checkmate** | Check with no legal move. Win |
| **Stalemate** | No legal move, not in check. **Draw** |
| **Castling** | King and rook unmoved, squares between empty, king not in check, king does not *pass through* or land on an attacked square. The rook may pass through an attacked square |
| **En passant** | Only on the move immediately after the double pawn push |
| **Promotion** | To queen, rook, bishop or knight. **Underpromotion must be offered** — it matters in real positions |
| **Threefold repetition** | Same position, same side to move, **same castling rights and same en-passant availability**, three times. Claimable draw |
| **Fivefold repetition** | Automatic draw |
| **Fifty-move rule** | 50 moves by each side with no capture and no pawn move. Claimable draw |
| **Seventy-five-move rule** | Automatic draw |
| **Insufficient material** | K vs K, K+B vs K, K+N vs K, K+B vs K+B same colour. Automatic draw |
| **Draw by agreement** | Offer / accept |
| **Resignation** | Immediate loss |
| **Timeout** | Loss, unless the opponent has insufficient material to mate — then a draw |

Three of those are the ones implementations get wrong, and they are worth naming because they are the argument for §4.1:

- **Threefold repetition includes castling rights and en-passant availability in the position comparison.** Two positions with identical piece placement are *different positions* if one side has lost the right to castle. Implementations that hash piece placement only will declare draws that are not draws.
- **Castling is illegal through an attacked square but the rook may pass through one.** The asymmetry is frequently reversed.
- **Timeout against insufficient material is a draw, not a loss.** Rarely implemented, and it comes up in real blitz games.

## 2.2 Time control

**Chess is the one game here that wants a real clock, not a per-move deadline**, and this is a genuine architectural difference from every other turn-based game in this folder.

A per-move deadline (Sea Battle's 24 hours, Ludo's 45 seconds) says "act within N". A chess clock says "you have a *budget* for the whole game, spend it how you like" — and the budgeting *is* chess. A player who spends eight minutes on move 12 and then blitzes the rest is playing correctly.

**Offered controls:**

| Name | Control | Mode |
|---|---|---|
| **Daily** | **3 days per move**, no cumulative budget | **Default.** Async |
| Rapid | 10 min + 5 s increment | Live |
| Blitz | 5 min + 3 s | Live |
| Bullet | 2 min + 1 s | Live |

**Daily is the default**, and it is the only one that fits §1.2's argument. Rapid, Blitz and Bullet are the modes where Voiid is competing directly with lichess and losing.

**Note the asymmetry:** Daily is a per-move deadline (which the sweeper already provides) and the others are cumulative clocks (which need real clock accounting, §4.5). **Ship Daily first.** It needs no new mechanism beyond what Sea Battle already builds, and it is the mode the game exists for.

## 2.3 Colours and first move

- White moves first.
- **Colour alternates between matches against the same opponent.** First-ever match is decided by the match RNG and announced in the opening frame, exactly as hand cricket announces the toss ([`cricket/index.ts:237`](../../../backend/games/src/engine/cricket/index.ts#L237)).

Alternating rather than re-rolling is the right call for a rivalry: over a series, colours are exactly balanced, and neither player can attribute the record to luck of the draw.

## 2.4 Claimable versus automatic draws

Threefold and fifty-move are **claimable** — the player to move may claim, or may play on. Fivefold and seventy-five-move are **automatic**.

This distinction is real chess and it matters: a player who is winning may prefer to play on through a repetition. **The engine must therefore track both thresholds separately** and expose a "claim draw" affordance only when the claimable condition holds.

## 2.5 What is deliberately not included

| Feature | Excluded because |
|---|---|
| **Analysis / engine evaluation** | This is where lichess is untouchable, and a weak evaluation is worse than none |
| **Opening book display** | Same |
| **Puzzles** | A different product |
| **Rating (Elo)** | §12.3. A rating pool of your contacts is not a rating |
| **Variants (960, King of the Hill, …)** | The rule set is already the largest here |
| **Takebacks** | Popular in casual play and corrosive to a record. The head-to-head is the whole point (§1.2) |

**Post-game analysis links out.** If a player wants their game analysed, the right answer is an export to PGN and a link to lichess's analysis board, which is free, excellent, and takes an afternoon to wire up. Competing there would be the exact mistake §1.1 describes.

---

# 3. Network model — R2

## 3.1 Pattern

Fourth row of [`GAMES.md`](../../GAMES.md) §4: pure turn-based, one `game_input` per move, one broadcast in response. **The lowest-bandwidth game in the app** — a move is ~4 bytes of meaning, and state is ~250 bytes.

No `tickHz`, no loop, no render clock, no interpolation. The [`SNAKE.md`](../SNAKE.md) §2 stutter class cannot occur.

## 3.2 Async is the point

Everything in [`SEA_BATTLE.md`](./SEA_BATTLE.md) §3 applies unchanged, and chess is the *more* natural async game of the two: a chess move is one decision, thinking time is legitimate and expected, and 3 days per move is a real, standard time control that millions of people play. Correspondence chess is a century old.

**Which means chess is blocked on the same thing:** [`redis.ts:27`](../../../backend/games/src/redis.ts#L27)'s one-hour TTL. A three-day-per-move game in a one-hour store is not a game.

## 3.3 The clock and the network

**A live clock over a network needs one decision made explicitly: whose clock is authoritative and when does it start.**

- **The server's clock is authoritative.** Always.
- **A player's clock starts when the server broadcasts the position they must move from**, not when their client renders it. This costs the moving player one network latency per move.
- **In Daily mode this is irrelevant** — 200 ms against 3 days.
- **In Bullet it is not.** At 2+1, a player on 300 ms RTT loses ~0.3 s per move to latency, which over 40 moves is 12 seconds of a 120-second budget. **This is a real competitive disadvantage and it is unfixable without trusting the client's clock**, which is unacceptable.

**This is a strong additional argument for shipping Daily only** (§2.2). Bullet chess over an unoptimised relay against opponents on different networks is a worse experience than the free apps, on the exact axis those apps have spent years optimising.

If Blitz/Bullet ship later, mitigate with **increment** (already in the controls above — increment compensates for latency by design) and by **crediting the measured one-way latency back to the moving player**, capped at 500 ms. Standard practice, and it needs a latency estimate the client does not currently produce.

## 3.4 What happens on a 3-second network stall

- **Not your turn:** nothing.
- **Your turn, Daily:** nothing. You have 3 days.
- **Your turn, Blitz:** **your clock is still running**, because the server's clock is authoritative and it has no way to know you are stalled. This is correct and it is harsh, and it is the fourth argument for Daily-first.
- **You moved during the stall:** the piece animates to its square and enters a pending state with a spinner after 800 ms. If rejected, it animates back.
- **Socket down:** the "Reconnecting…" state ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §7). Essential in Blitz, where it must show clearly that the clock is still running.
- **On reconnect:** full state frame, nothing to reconcile.

---

# 4. Engine design — R1

Folder: `backend/games/src/engine/chess/`.

## 4.1 Use a move-generation library — a flagged disagreement

**Recommendation: use `chess.js` (or an equivalent with a published perft suite) server-side.**

[`GAMES.md`](../../GAMES.md) §4 argues against new third-party dependencies, and [`README.md`](./README.md) §4 records this as a deliberate disagreement rather than an oversight. The argument is worth setting out because the *reason* for that rule does not reach this case.

**What §4 actually argues.** Read it carefully and every reason is about the **client**: "a second build toolchain, a huge binary size increase, and an escape hatch out of SwiftUI/Compose that breaks the 'iOS is the reference, Android must match it' parity workflow." The examples are Unity, Unreal, Godot and JS engines in a WebView.

**None of that applies to a ~50 KB npm package in `backend/games`.** No binary size, no toolchain, no parity impact. The service already depends on `ioredis` and `pg`.

**And [`GAMES.md`](../../GAMES.md) §5 already anticipates exactly this**, in the file layout it proposes:

> `chess/ — move validation (a small well-known chess-rules package, e.g. chess.js-equivalent logic ported/used server-side)`

So the disagreement is narrower than it looks: the architecture doc's own build plan named this dependency. What this doc adds is the recommendation to *use* it rather than port it.

**Why hand-rolling is the wrong choice.** Chess move generation is where correctness bugs live, and they are the worst kind: rare, position-specific, and they invalidate a game that took three days. Castling through check, en passant discovered pins, stalemate in a position with a pinned piece, repetition with differing castling rights. A library with a **perft suite** — node counts at fixed depths from known positions, the standard correctness test — has already paid for all of them. Hand-rolling means re-earning that, and the only way to know you have is to build the perft suite anyway.

**The scope of the dependency, stated tightly:**

- **Server only.** `backend/games` and nowhere else.
- **Rules only** — legal moves, check, mate, stalemate, draw conditions, FEN, SAN. **Not an evaluation engine, not a search.**
- **The clients do not depend on it.** They render a board from the server's state and send a move; a client-side legality preview (§7.1) is a small independent implementation whose only failure mode is offering a move the server rejects.
- **The bot does not depend on it** either — the bot is client-side (§11) with its own generator.

**If a dependency is genuinely unacceptable**, the fallback is to port a known-correct generator and **build the perft suite first, before any game code.** That is a real, defensible option; it is just strictly more work for the same result.

## 4.2 Interface surface

| Method | Present | Why |
|---|---|---|
| `applyInput` | yes | move / resign / offer draw / accept draw / claim draw |
| `tick` | **no** | Turn-based. **Even with a live clock** — §4.5 |
| `serialize` | yes | Complete position and history |
| `serializeForWire` | **no** | ~250 bytes, everything matters |
| `serializeForPlayer` | **no** | **Chess has no hidden information** |
| `serializeSecret` | **no** | Nothing to hide |
| `deadlineAt` / `onTimeout` | **yes** | Both the Daily deadline and the live clock flag |
| `isFinished` | yes | — |

**No secret and no per-player projection.** Chess is the only game in this folder besides Air Hockey and Ludo with completely public state, which makes spectating free and makes the engine's security surface trivially small (§5).

## 4.3 `serialize()` — field by field

```ts
{
  players: string[],          // [white, black]
  fen: string,                // full FEN: placement, side, castling, ep, halfmove, fullmove
  moves: string[],            // SAN, in order
  positionCounts: Record<string, number>,  // repetition key → count
  turn: 0 | 1,
  timeControl: { initial: number, increment: number, perMove: number | null },
  clocks: [number, number],   // ms remaining, live modes only
  lastMoveAt: number,         // server epoch ms
  drawOffer: 0 | 1 | null,
  claimable: 'threefold' | 'fifty' | null,
  check: boolean,
  result: '1-0' | '0-1' | '1/2-1/2' | null,
  resultReason: string | null,
  moveCount: number,
  deadlineAt: number | null,
  finished: boolean,
  winnerUserId: string | null,
}
```

- **`players`** — seat 0 is White. Lose it and the board flips.
- **`fen`** — **the entire position in one string.** Placement, side to move, castling rights, en-passant target, halfmove clock, fullmove number. The halfmove clock is the fifty-move counter and the en-passant target is a *rights* field, so **FEN carries three pieces of state that are invisible on the board.** A design that serialized only the piece placement would silently lose castling rights and en passant on every restore — which happens **on every input** ([`index.ts:279`](../../../backend/games/src/index.ts#L279)) — and the bug would look like "sometimes castling stops working."
- **`moves`** — SAN move list. The game record, the PGN export, and the move-list UI. Not derivable from the FEN, which holds only the current position.
- **`positionCounts`** — **the field a naive design loses, and the one that is genuinely hard.** Threefold repetition requires counting *positions*, and the key must include castling rights and en-passant availability (§2.1) but **not** the halfmove or fullmove counters. So it is FEN's first four fields, not all six. Storing a map is the only way; recomputing it by replaying `moves` on every input is O(n) per move and grows for the whole game.
- **`turn`** — redundant with FEN's side-to-move field and stored anyway, because every consumer reads it and parsing FEN to answer "whose turn" is silly.
- **`timeControl`** — from match options, clamped. Serialized so the renderer never assumes and a restore cannot change the control mid-game.
- **`clocks`** — ms remaining per player, live modes only. §4.5.
- **`lastMoveAt`** — **server wall time**, deliberately, because it is what the elapsed-time deduction is computed from (§4.5). One of two places in this folder where wall time is correct.
- **`drawOffer`** — which seat has an offer outstanding. Lose it and an offer silently evaporates, which players will report as the button not working.
- **`claimable`** — whether a draw claim is currently legal (§2.4). Derived, and stored so the client and the validator read the same answer.
- **`check`** — sent rather than derived so the renderer never needs a move generator.
- **`result` / `resultReason`** — `'1-0'` plus `'checkmate'` / `'resignation'` / `'timeout'` / `'stalemate'` / `'threefold'` / `'fifty-move'` / `'insufficient material'` / `'agreement'`. **The reason matters** — a draw by stalemate and a draw by agreement are different stories, and the post-match screen should say which.
- **`moveCount`** — monotonic; the idempotency key for deadline frames (§13.2).
- **`deadlineAt`** — absolute epoch ms, serialized rather than recomputed. Recomputing from "now" on restore would hand an absent player a fresh 3 days at every restart.
- **`finished` / `winnerUserId`** — terminal. `winnerUserId: null` with `result: '1/2-1/2'` is a **draw**, which is exactly what [`GameEngine.ts:22-23`](../../../backend/games/src/engine/GameEngine.ts#L22-L23) means by "finished and has a winner are separate facts". Chess is the game where draws are most common, so this distinction gets exercised hard.

**`scores`** in the outcome: 1 / 0 / 0.5, the standard chess scoring. Note this is the only fractional score in the app and the results table stores an integer — **store 2 / 0 / 1 (double the score)** and halve at display, or the draw rounds away. Small, real, and worth catching before it ships.

## 4.4 RNG and determinism

**Chess has no randomness at all** — the only draw in the entire game is the first-match colour assignment (§2.3), and after that the game is fully determined by the moves.

Consequently **no seed is serialized and no RNG state is held.** Chess is the one game in this folder where [`README.md`](./README.md) §1.3's seed-placement question does not arise, and it is worth stating rather than leaving as an absence.

Colour assignment reads the previous match's colours from match history at `create` time, falling back to one `Rng` draw when there is no history.

## 4.5 The clock — and why it needs no `tick()`

**The naive design gives chess a `tickHz` so it can count down. That would be wrong twice over**, and [`README.md`](./README.md) §2.3 makes the general version of this argument:

> *"it would start a per-match interval for a game that changes state once a minute, and a `setTimeout` measured in days would not survive the weekly process restart it is supposed to outlast."*

**The correct design: clocks are stored as remaining milliseconds and deducted arithmetically on each move.**

```ts
// On an accepted move by `seat`:
const elapsed = Date.now() - this.s.lastMoveAt;
this.s.clocks[seat] = this.s.clocks[seat] - elapsed + this.s.timeControl.increment;
this.s.lastMoveAt = Date.now();
if (this.s.clocks[seat] <= 0) return this.flagFall(seat);
```

Properties:

- **Nothing ticks.** The clock is a number and a timestamp; "time remaining right now" is `clocks[turn] - (now - lastMoveAt)`, computed by whoever needs it — including the client, which renders a smooth countdown locally from those two values without any server traffic at all.
- **It is exactly correct across process restarts**, because it is derived from absolute timestamps rather than accumulated ticks.
- **Flag-fall is detected two ways**: on the next move (arithmetic, above), and by the **deadline sweeper** ([`README.md`](./README.md) §2.3) when nobody moves — `deadlineAt()` returns `lastMoveAt + clocks[turn]`, and `onTimeout()` awards the win. One mechanism serves both the 3-day Daily deadline and the live flag, which is a pleasing consequence of the sweeper being a sorted set of absolute times rather than a timer.

**The client renders the countdown locally and it will drift slightly against the server.** Show the server's number as authoritative on every frame arrival; between frames, count down locally. Never let the local clock reach zero on its own — display "0:00" and wait for the server to confirm the flag, because the server's clock is the one that decides.

## 4.6 Tick-rate independence

No `tick()`, nothing integrated. Every time-dependent value — `deadlineAt`, `lastMoveAt`, the clocks — is an **absolute timestamp or a duration**, never a countdown being decremented. Correct whenever read, however long the process was down, however many restarts happened.

**This is what "tick proof" means for a game with a clock**, and it is a stronger property than any continuous game in this folder can offer: chess's timing is not merely robust to tick timing, it is entirely independent of any tick existing.

## 4.7 `applyInput`

```ts
{ move: string }            // 'e4' SAN, or 'e2e4' UCI; accept both, normalise to SAN
{ move: string, promotion: 'q'|'r'|'b'|'n' }
{ resign: true }
{ drawOffer: true }
{ drawAccept: true }
{ drawDecline: true }
{ claimDraw: true }
```

Validation: not finished; `turn === seat`; the move is in the library's generated legal move list. **Legality is never re-derived by hand** — one generator, one answer.

A draw offer rides *with* a move in real chess ("I offer a draw" is said after moving). Accept that shape: `{ move, drawOffer: true }` is one input.

`claimDraw` is valid only when `claimable !== null` (§2.4).

All non-`silent` per [`GameEngine.ts:38-40`](../../../backend/games/src/engine/GameEngine.ts#L38-L40).

---

# 5. Anti-cheat

**Chess has the smallest attack surface in this folder**, because there is no hidden state and no continuous simulation.

| Attempt | Defence |
|---|---|
| Illegal move | Checked against the library's generated legal move list |
| Move out of turn | `turn` check |
| Move twice | Turn advances inside `applyInput` |
| Move the opponent's piece | The move is generated for the side to move only |
| Claim a checkmate | Computed server-side |
| Claim a draw that is not claimable | `claimable` check |
| Add time to the clock | Clocks are server arithmetic on server timestamps (§4.5) |
| Flood inputs | 60/min, silent drop ([`index.ts:29-61`](../../../backend/games/src/index.ts#L29-L61)) |
| Input into another match | Membership checked ([`index.ts:262-264`](../../../backend/games/src/index.ts#L262-L264)) |

## 5.1 Engine assistance — the honest one

**A player can run the position through Stockfish on another device and play the best move. This is undetectable and unfixable.**

Every chess platform in the world has this problem, and the large ones spend serious engineering on statistical detection — move-match rates against engine choices, time-usage patterns, centipawn-loss distributions. **We will do none of that**, and it should be stated rather than implied.

Why that is acceptable here and only here: matches are invite-only between people who already talk to each other ([`GAMES.md`](../../GAMES.md) §3), there is no rating, no ladder, no prize, and no strangers. **Cheating at chess against your friend, in a chat thread, to win a number only the two of you can see, is a social act with a social cost.**

It also means **the head-to-head record is the only thing at stake, which is exactly §1.2's argument, and it is also the thing cheating devalues.** If chess ever gets a rating or a public leaderboard, this section needs to be rewritten and the honest answer would be "do not."

---

# 6. Client rendering

## 6.1 What it reuses

| Piece | Source | Notes |
|---|---|---|
| Grid board | [`TicTacToeBoard.swift`](../../../apps/ios/Voiid/Voiid/Games/TicTacToeBoard.swift) / [`TicTacToeScreen.kt`](../../../apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeScreen.kt) | 8×8 instead of 3×3, same hit-testing and cell-state model |
| Async patterns | **Sea Battle**, wholesale | Reconnect state, cold-start-from-push, turn notifications, deadline display |
| `GamesEngine` | existing | Unchanged |
| `GameAudio` / `GameHaptics` | [`GameAudio.swift`](../../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift) | One new `soundNames(for:)` entry |
| Lobby | [`GameLobbyView.swift`](../../../apps/ios/Voiid/Voiid/Games/GameLobbyView.swift) | Unchanged, 2 seats |

**Chess should be built after Sea Battle specifically so it inherits the async UI rather than inventing it.** That is most of the client work, and it is the same work.

## 6.2 What it adds

Plain views on both platforms. **No `Canvas`, no Metal** — a chessboard is 64 rectangles and 32 piece views, and [`GAMES.md`](../../GAMES.md) §4 specifies plain views for board games.

**iOS:** `LazyVGrid` of squares, pieces as overlaid views animated with `matchedGeometryEffect`.
**Android:** Compose `Box` grid, `animate*AsState` on piece positions.

**Pieces are vector assets** (SF Symbols are not adequate; chess pieces need real glyphs). One set, licensed appropriately — **the standard Cburnett set is CC-BY-SA**, which is usable but requires attribution the app has nowhere to put, the same problem [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §8 flags for audio. **Prefer a CC0 set or commission one.**

## 6.3 The board on a phone

An 8×8 board on a 390 pt screen gives ~46 pt squares — **above the 44 pt minimum, unlike Sea Battle's 10×10.** So chess needs no loupe and no two-step commit, which is a genuine simplification.

- **Board fills the width**, centred vertically.
- **Your pieces are at the bottom, always** — board flipped for Black. Same principle as Air Hockey's goal and Ludo's yard.
- **Above and below the board:** captured pieces, material advantage, clock, player name. Compact.
- **Move list** is a collapsible strip, not a panel. On a phone the board is the screen.

---

# 7. Controls

## 7.1 The scheme

- **Tap a piece to select.** Legal destinations light up as dots (empty) or rings (captures). **This is the tutorial, and it is free** — the server already sends the position and a client-side generator produces the destinations.
- **Tap a destination to move.**
- **Or drag the piece.** Faster for experienced players; snaps to the nearest legal square, illegal drops return with a spring.
- **Tapping another of your pieces reselects** rather than deselecting. Deselecting on a mis-tap is the most annoying interaction in every chess app.
- **Promotion:** a four-piece picker appears at the promotion square. **Underpromotion must be reachable in one tap**, not behind a menu (§2.1).
- **Draw offer / resign** behind a single overflow button, both with confirmation. Resigning by mis-tap in a three-day game is unforgivable.

## 7.2 Client-side legality

The client runs its own move generator for highlighting. **It is a hint, not authority** — the server's answer decides.

This is the one place a client-side chess implementation is needed, and it is deliberately small: pseudo-legal generation plus a self-check filter. **It does not need to handle repetition, the fifty-move rule, or insufficient material** — those are game-end conditions, not move legality, and the server owns them.

If the two ever disagree, the server wins and the client shows the move being rejected. That failure is visible and recoverable, unlike the reverse.

## 7.3 One-handed and small screens

- 46 pt squares are usable; the board is the whole width.
- **Selected pieces lift and enlarge**, and destination markers are 24 pt targets centred in 46 pt squares.
- The move list and clock never overlap the board.
- **Board flip is automatic** by seat, with a manual toggle for reviewing.

---

# 8. Visual design

## 8.1 Art direction

**Restraint.** Chess is the one game here where the correct visual design is the least visual design — players want a legible board, and every flourish is something between them and the position.

- **Board:** two-tone, low contrast, matte. Not marble, not wood grain, not neon. The pieces must be the highest-contrast thing on screen.
- **Pieces:** a clean, conventional set. **Not stylised.** A player must recognise a knight instantly, and originality here costs recognition for no gain.
- **Coordinates** on the edge files and ranks, always visible — a player calling a move in the chat needs to read it off the board.
- **Last move** highlighted on both squares, subtly.
- **Check:** the king's square glows. Unmissable, because missing check is the most common beginner loss.
- **Legal destinations:** dots and rings, low opacity.

## 8.2 What the player must see without a tap

1. **Whose turn.**
2. **Both clocks**, or the deadline in Daily mode.
3. **Check state.**
4. **The last move** — critical in async, where "what changed since yesterday" is the first question.
5. **Material balance** — `+2` next to the leader. Cheap and it is what a casual player uses to know how they are doing.
6. **Captured pieces**, both sides.
7. **A draw offer**, if outstanding.

## 8.3 Accessibility

- **Piece identity by shape**, never colour alone — inherent to chess pieces, and the reason not to stylise them.
- **Light and dark pieces must differ in more than lightness** — a subtle outline treatment, so the two sets are distinguishable at low contrast and for low-vision players.
- **VoiceOver / TalkBack:** every square labelled ("e4, white pawn"), moves announced in SAN. [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13 flags that no game has board labels. **Chess is the game where this matters most** — it is genuinely playable non-visually, blind players play chess competitively, and SAN is already a complete verbal notation. This is a real accessibility win available almost for free.

---

# 9. Motion and feel

Chess wants **less** motion than anything else in this folder. Behind reduce-motion ([`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13).

| Moment | Motion | Duration | Curve |
|---|---|---|---|
| Piece selected | Lift 6 pt, scale 1.06, shadow | 140 ms | `spring(0.2, 0.75)` |
| Destinations appear | Dots fade in, staggered 12 ms from the piece | 180 ms | `easeOut` |
| **Piece moves** | Travels to the square | 200 ms | `spring(0.26, 0.85)` — **critically damped, no bounce** |
| Capture | Captured piece scales to 0.7 and fades; capturer lands | 180 ms | `easeIn` on the fade |
| Castling | Both pieces move together, rook trailing 60 ms | 260 ms | `spring(0.26, 0.85)` |
| En passant | Captured pawn fades from a square the capturer did not land on | 180 ms | `easeIn` |
| Promotion | Picker scales in at the square; pawn morphs on choice | 220 ms | `spring(0.24, 0.7)` |
| Check | King's square glows, one pulse | 400 ms | `easeInOut` |
| Checkmate | King's square flashes, board dims, result card rises | 700 ms | `easeOut` |
| Illegal drop | Piece springs back | 220 ms | `spring(0.2, 0.6)` |
| Clock under 30 s | Digits pulse at 1 Hz, turn amber then red | 300 ms/pulse | `easeInOut` |

**The piece move must be critically damped.** A bouncing chess piece is wrong in a way that is hard to articulate and obvious to see — chess pieces are placed, not thrown. `damping: 0.85` and no overshoot.

**No screen shake anywhere. No particles. No hitstop.** Every one would be right in Air Hockey and wrong here.

---

# 10. Sound

Inherits [`SOUND_DESIGN.md`](../SOUND_DESIGN.md).

## 10.1 The shared catch sound

> **The catch moment in Chess is: one of your pieces is captured.**

Per [`README.md`](./README.md) §1.5. The clearest possible case of "a player's attempt is intercepted or ended by the opponent" ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §3) — a developed piece is an attempt, and capturing it ends it.

**Only when it is *your* piece.** Capturing gets its own brighter sound. Both players hearing `catch` would flatten an asymmetric moment, the same rule as Ludo ([`LUDO.md`](./LUDO.md) §10.1).

Played **unmodified**, layered: `catch.wav` **+** the piece-placement thud.

**Not on a check, not on a checkmate.** Checkmate is a loss, not an interception, and it has its own sound. Reserving `catch` for capture keeps it meaning one thing.

## 10.2 The palette

**Physical, recorded, and quiet.** Chess is played in silence; the sounds are wood on wood and nothing else. Trivially recordable ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §5.2).

| Event | Sound | Notes |
|---|---|---|
| Piece lifted | `piece_lift.wav` | Very short, ~40 ms |
| **Piece placed** | `piece_place_1..3.wav` | Wood on wood, ~120 ms. Most-triggered sound; 3 variants + ±4% varispeed |
| **Your piece captured** | **`catch.wav`** + `piece_place` | §10.1 |
| You capture | `capture.wav` + `piece_place` | Sharper knock |
| Castling | Two `piece_place`, 60 ms apart | Matches the animation |
| Check | `check.wav` | A single clear tone. Distinct, not alarming |
| Checkmate | `checkmate.wav` | Final, resolving. **No `catch`** |
| Illegal move | `error` (existing) | — |
| Draw offer | `offer.wav` | Soft, questioning |
| Draw agreed | `draw.wav` | Neutral, deliberately unsatisfying |
| Clock low (< 30 s) | `tick_urgent.wav` at 1 Hz | Live modes only. **Silent in Daily** |
| Flag falls | `flag.wav` | Sharp, final |
| Your turn (async) | `your_turn.wav` | Shared with Sea Battle |

**No ambience.** Silence is the correct room tone for chess and the placement sounds land better in it.

**Mono, always** ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §6.6 — a stereo asset is a hard AVAudioEngine crash).

## 10.3 Haptics

Minimal. Piece placed: light transient. Your piece captured: medium. Check: double transient. Flag falls: sharp. Nothing else.

---

# 11. Bots

**The most honest section in this document, because chess bots are where difficulty scales are most often faked and most easily exposed.**

## 11.1 What difficulty varies

**Search depth and evaluation quality. Never the rules, never a hidden advantage.**

Client-side, like every other bot in the app ([`RpsBot.swift`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift), [`CricketBot.swift`](../../../apps/ios/Voiid/Voiid/Games/CricketBot.swift)). Alpha-beta over a material + piece-square-table evaluation.

| Band | Search | Evaluation | Approx strength |
|---|---|---|---|
| 0.0–0.25 | Depth 1, **30% random legal move** | Material only | ~600 |
| 0.25–0.5 | Depth 2, 10% random | Material + PST | ~1000 |
| 0.5–0.75 | Depth 3, quiescence | + mobility, king safety | ~1400 |
| 0.75–1.0 | Depth 4–5, quiescence, iterative deepening | + pawn structure, rook files | **~1700** |

**The "random move" at low bands is a real design decision and it is the honest way to build a weak bot.** The dishonest way is to weaken the evaluation, which produces a bot that plays *strategically incoherently but tactically perfectly* — it will never hang a piece, so it feels alien and it never gives a beginner the win they need. A bot that occasionally plays a bad move plays like a beginner, because that is what beginners do.

## 11.2 What the top of the scale can and cannot do

In the register [`RpsBot.swift:17-21`](../../../apps/ios/Voiid/Voiid/Games/RpsBot.swift#L17-L21) sets:

> **The strongest bot here is roughly 1700 Elo. It will beat most casual players comfortably and it will lose to any club player, every time.** It is not close to Stockfish and it never will be.

**It can:** win material with 3-move tactics, avoid hanging pieces, castle sensibly, and punish a beginner's mistakes reliably.

**It cannot:** play an opening plan, understand pawn structure beyond a heuristic, calculate a 6-move combination, or hold a difficult endgame. It has no opening book and no tablebase.

**Why not embed a real engine.** Stockfish compiled to WASM or ported per-platform would give a 3000+ opponent. It is rejected for three reasons: binary size (multiple MB per platform), the build complexity [`GAMES.md`](../../GAMES.md) §4 exists to avoid, and — the decisive one — **nobody wants to play a 3000-rated bot.** The useful range for a casual player is 600–1600, and a simple alpha-beta covers it. Adding an engine would be a large cost to serve a band of users who are already on lichess.

**This is the honest ceiling and it should be stated in the UI**, not as a rating but as a shape: the top difficulty is "a decent club-level club player would beat this."

## 11.3 Presentation

- **Thinking time 800–2500 ms**, scaled by position complexity and difficulty. Chess is the one game where a *visible* think is correct — instant play from a bot destroys the fiction entirely.
- **The bot does not play instantly in a lost position** either; resigning or playing on quickly is a tell.
- **It resigns** when down more than a queen with no counterplay, at high difficulty. Playing on hopelessly is what weak bots do and it wastes the player's time.

---

# 12. Progression and retention — R3

## 12.1 The floor

[`README.md`](./README.md) §1.6's four:

1. **Rematch**, opponent's name on it, **colours swapped** (§2.3)
2. **Post-match summary** — result, reason, move count, material swings, biggest blunder if a simple check can find one, head-to-head change
3. **Head-to-head record**, before and after
4. **Share result into the chat**, with the final position as an image and PGN attached

## 12.2 The specific hook

**A permanent record against one specific person.** §1.2, restated: this is the *only* hook, and everything else in this section is support for it.

The concrete artifact: **"You 7 — Priya 5, since March."** A number that only exists here, that neither player could get from lichess, and that both of them care about precisely because it is against each other.

## 12.3 How it uses the fact that this is a messenger

- **The game lives in the thread.** A move notification is a message in a conversation you already have, and the reply is a move.
- **A three-day game is a three-day conversation.** This is the property no chess app has: your chess game and your chat are the same thread.
- **Sharing the position is sharing a message.** "What would you play here?" with a board image is a genuinely good message to send.
- **No rating, deliberately.** A rating pool of your twelve contacts is not a rating — it is a number with no meaning that would be taken to mean something. The head-to-head record is honest about being a record between two people. This is a decision, not an omission.

## 12.4 What the first 30 seconds feel like

**Chess is the worst first-30-seconds in this folder, and it cannot be fixed.**

- **0–5 s.** Accept. Board appears, your pieces at the bottom, colour announced.
- **5–15 s.** If you play chess, you play `e4` and you are home. If you do not, you are looking at 32 pieces and no idea, and **no onboarding will fix that in 30 seconds** — chess takes an hour to learn and years to play.
- **15–30 s.** Your opponent's move arrives, or does not, because it is a 3-day game.

**So chess must not be presented to people who do not play chess.** It should sit behind an explicit choice, never be a default or a suggestion, and the catalog entry should be honest about the time control. A new player's first Voiid game must not be chess.

What *does* help, and should ship: **legal-move highlighting** (§7.1), which is genuine onboarding for a beginner and costs nothing, and a **"learn the moves" link out** rather than a built-in tutorial.

## 12.5 What someone with 50 matches is chasing

- **The head-to-head record.** The only answer.
- **A win streak against one person.**
- **Beating the top bot**, which is a real milestone at ~1700 for a casual player.
- **Their own game archive** — 50 games against a friend is a genuinely interesting personal artifact, and PGN export makes it portable.

Explicitly **not**: rating, puzzles, analysis, opening trainers. All four are where the free apps are excellent and we would be embarrassing (§1.1, §2.5).

---

# 13. Failure and edge cases

## 13.1 Disconnect

**Daily mode: nothing.** No live connection requirement, exactly as [`SEA_BATTLE.md`](./SEA_BATTLE.md) §13.1. This is the mode the game is for.

**Live modes: your clock keeps running** (§3.4). Correct and harsh. The "Reconnecting…" state must make it unmistakable that the clock is running, because a player who thinks the game is paused and loses on time will be justifiably furious.

## 13.2 Deadlines and flag-fall

Both handled by the deadline sweeper ([`README.md`](./README.md) §2.3), with `deadlineAt()` returning different things per mode (§4.5):

| Mode | `deadlineAt()` | On expiry |
|---|---|---|
| Daily | `lastMoveAt + 3 days` | **Loss on time.** Warning notification at 24 h and 2 h remaining |
| Live | `lastMoveAt + clocks[turn]` | **Flag falls.** Loss on time |
| Either, opponent has insufficient material | — | **Draw**, not a loss (§2.1) |

**Loss on time, not auto-play**, and this is the opposite of Ludo's choice ([`LUDO.md`](./LUDO.md) §13.2). The reasoning differs because the situation does: Ludo auto-plays because forfeiting one of four players ruins the game for the other three. Chess has two players, the absent one is only affecting their opponent, and **losing on time is a real chess rule that every player already understands.** Auto-playing a chess move would be worse than forfeiting — it would play a move the player did not choose, in a game where every move is the point.

**Warnings before the Daily deadline are mandatory.** Losing a three-day game on time without notice is the single most likely thing to make someone stop using this feature.

**Idempotency:** timeout frames carry `moveCount` (§4.3) and are dropped on mismatch.

## 13.3 Rejoin

The normal case in Daily mode — every turn begins with a cold start.

`handleJoin`'s resync branch ([`index.ts:355-359`](../../../backend/games/src/index.ts#L355-L359)) already handles it, and **chess is the easiest rejoin in the folder**: no hidden state, no deltas, no prediction. One full frame and the client is correct.

**But it requires the durable table** ([`README.md`](./README.md) §2.2). A three-day game in a one-hour Redis TTL does not exist.

## 13.4 Resignation, timeout, abandonment

| Outcome | `result` | `winnerId` | Head-to-head |
|---|---|---|---|
| Checkmate | `1-0` / `0-1` | winner | W/L |
| Resignation | `1-0` / `0-1` | opponent | W/L, flagged |
| Timeout | `1-0` / `0-1` | opponent | W/L, flagged |
| Timeout vs insufficient material | `1/2-1/2` | **null** | Draw |
| Stalemate / repetition / 50-move / insufficient / agreement | `1/2-1/2` | **null** | Draw |
| Abandoned before move 1 | `null` | **null** | **Not counted** |

**Draws must be recorded as draws, not as nothing.** Chess is the game where they are common, `winnerId: null` is exactly the shape [`GameEngine.ts:22-23`](../../../backend/games/src/engine/GameEngine.ts#L22-L23) specifies, and a head-to-head that shows "7–5" while hiding four draws is lying. Show `7–5–4`.

## 13.5 The engine restarts mid-match

- No tick loop.
- State from Redis, or from the durable table on a TTL miss — **which for Daily chess is the normal path, not the fallback.**
- No secret to lose.
- **Clocks are correct across the restart by construction** (§4.5), because they are absolute timestamps rather than accumulated ticks. This is the property that makes chess clocks work without a tick loop, and it should be tested explicitly: serialize, wait, restore, and assert the remaining time is right.

## 13.6 Threefold repetition detection

The subtle one. `positionCounts` (§4.3) is keyed on FEN's **first four fields only** — placement, side to move, castling rights, en-passant target — excluding the halfmove and fullmove counters.

Getting the key wrong in either direction is a real bug:
- **Including the counters:** no position ever repeats, and threefold never fires.
- **Excluding castling rights:** positions that differ in a meaningful way are counted as the same, and a draw is offered where none exists.

**Test with known repetition positions.** This is exactly the kind of rule §4.1 argues for using a library for, and if `chess.js` is used it provides repetition detection directly.

## 13.7 Both players offer a draw simultaneously

Cannot happen — frames are processed serially off one Redis subscription ([`index.ts:479`](../../../backend/games/src/index.ts#L479)). The second offer arrives after the first is recorded, and an offer against an outstanding offer is treated as an **accept**, which is what the player meant.

---

# 14. Build plan

**Phase 0 is a gate, not a phase.**

## Phase 0 — the decision

Ship Sea Battle. Ship head-to-head records. **Wait, and look at whether people keep async matches running for days** (§1.3).

If yes, chess is a much smaller project than this document implies and the hook is real. If no, stop here.

## Phase 1 — engine, headless, Daily only

`engine/chess/` + `chess.js` + registry + tests. **Daily time control only** (§2.2) — no cumulative clocks.

Tests: castling in all its illegal cases, en passant including discovered check, promotion including under check, stalemate, all four draw conditions, **repetition with differing castling rights** (§13.6), and a **serialize → restore → serialize byte-equality** test covering the FEN fields that are invisible on the board (§4.3).

If a library is used, its perft suite covers move generation and these tests cover *our* layer — the clock, the repetition map, the serialization.

## Phase 2 — iOS practice mode

Board, pieces, drag and tap, legal highlighting, promotion picker, the bot at all four bands, sound, motion. No networking.

## Phase 3 — iOS online, Daily

On top of Sea Battle's async infrastructure. Turn notifications, deadline warnings, cold start from push, reconnect state.

## Phase 4 — Android parity

Phases 2–3. iOS is the reference.

## Phase 5 — retention

Post-match summary, rematch with colour swap, head-to-head **including draws** (§13.4), share position + PGN.

## Phase 6 — live time controls, *if wanted*

Cumulative clocks (§4.5), flag-fall via the sweeper, latency crediting (§3.3). **Deliberately last**, because this is the mode where Voiid competes head-on with free apps that do it better, and §3.3 shows the network disadvantage is real.

## Phase 7 — polish

VoiceOver/TalkBack board labels (§8.3 — the highest-value accessibility work in the folder), PGN export, lichess analysis link-out, reduce-motion.

---

# 15. Open questions

1. **Build chess at all?** *(O3 in [`README.md`](./README.md) §5, blocking)* Recommendation: **defer until head-to-head records and async play prove the social hook via Sea Battle** (§1.3). This is the only game in this folder we recommend not starting.

2. **Use `chess.js` server-side?** Recommendation: **yes** (§4.1). A flagged disagreement with [`GAMES.md`](../../GAMES.md) §4, whose reasoning is entirely about client-side dependencies and does not reach a Node package in `backend/games` — and [`GAMES.md`](../../GAMES.md) §5's own file layout already names this dependency. If refused, port a known-correct generator and **build the perft suite first**.

3. **Daily only, or live time controls too?** Recommendation: **Daily first, live last or never** (§2.2, §3.3). Daily is the mode the hook depends on and needs no new mechanism. Blitz over an unoptimised relay is a worse experience than the free apps on the exact axis they have optimised for years.

4. **Piece set licensing.** (§6.2) The standard Cburnett set is CC-BY-SA and the app has nowhere to put attribution — the same problem [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §8 flags for audio. Needs a CC0 set or a commission, decided before art work starts.

5. **Rating?** Recommendation: **no** (§12.3). A rating pool of your contacts is not a rating; it is a number that would be taken to mean something it does not. Head-to-head is honest.

6. **Store fractional scores how?** (§4.3) A draw is 0.5 and `game_match_results.score` is an integer. Recommendation: store doubled (2/1/0) and halve at display. Small, and it will be wrong if not decided.

7. **Takebacks?** Recommendation: **no** (§2.5). Popular in casual play, and corrosive to the head-to-head record that is the game's entire reason to exist.

8. **Analysis?** Recommendation: **link out to lichess** with a PGN (§2.5). Competing there is the mistake §1.1 describes.
