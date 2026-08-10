# New game ideas

Ranked by **(how sticky it is) ÷ (what it costs to build here)**, judged against what this codebase already has: a server-authoritative engine interface, a tick loop keyed on `tickHz`, a simultaneous-secret-reveal pattern used twice already, and two native renderers.

**The filter used throughout:** Voiid is a *messenger*. A game's value here is not how good it is standalone — it is how well it creates a reason to message someone. A brilliant solo game is worth less than a mediocre one that generates a rematch and a bit of trash talk. That is the advantage no standalone game app has, and it should decide what gets built.

---

# Tier 1 — build these

## 1. Ultimate Tic Tac Toe
**Cost: very low.** Same input frame (cell index 0-80), same board renderer, same netcode. **Stickiness: high** — it is not a solved game, has a real skill ceiling, and every player's first three matches are humbling.

Nine boards in a 3×3 grid; your move dictates which board your opponent must play in. The cheapest route from "correct but finished" (see [`TICTACTOE.md`](./TICTACTOE.md)) to a game worth replaying. Effectively free depth.

## 2. Daily Challenge (not a game — a wrapper)
**Cost: very low.** One seed parameter on the existing Snake engine, one leaderboard query, one push. **Stickiness: highest on this page.**

Everyone gets the identical seeded Snake arena each day; leaderboard resets at midnight. This is the single highest retention-per-line-of-code feature in casual gaming, it needs no new engine, and it gives the push notification channel something to say that isn't a message.

## 3. Sea Battle (Battleship)
**Cost: low.** Pure turn-based, grid state, no physics — [`GAMES.md`](../GAMES.md) §8 named it the recommended first game and it is still unbuilt. **Stickiness: medium-high.**

Hidden state (your fleet) is the interesting bit and the server already has the pattern from RPS/cricket's `secret` channel. Placement phase gives it a distinct opening, and the slow reveal is naturally suited to **asynchronous play** — fire a shot, put the phone down, get a notification. That async shape fits a messenger better than anything else on this list.

## 4. Word Duel (a Wordle-style head-to-head)
**Cost: low.** Turn-based, tiny state, no renderer work beyond a grid of letters. **Stickiness: very high.**

Both players race the same word; you see your opponent's *pattern* of greys/yellows/greens but not their letters. That is the same simultaneous-partial-information problem the RPS engine already solves, and word games have the broadest demographic reach of any genre — they pull in the people who will never play Snake.

Needs a word list shipped with the server. Nothing else is new.

---

# Tier 2 — good, more work

## 5. Air Hockey
**Cost: medium.** Inherits Snake's entire tick machinery; adds a small 2D physics helper (velocity, friction, wall reflection, paddle collision). **Stickiness: high** — it is the most immediately fun thing on this list, and 30-second matches are perfect for a chat context.

Do this before Ping Pong or Pool; all three share the physics helper, and Air Hockey is the one that needs the least of it.

## 6. Ludo
**Cost: medium.** 4-player state, dice, capture, home run. **Stickiness: very high in India specifically**, and given Hand Cricket is already in the catalog that is clearly a target audience.

The reason it is Tier 2 rather than Tier 1: 4-player lobbies are a real change to the invite flow, which currently picks exactly one opponent. That work is shared with unlocking Snake's 3-6 player mode, so sequence them together.

## 7. Voiid Cards (UNO-like)
**Cost: medium-high.** Deck state, hidden hands, 2-6 players. **Stickiness: high.**

Hidden hands are a bigger version of the `secret` channel the engine already has. Gated behind the same multi-player lobby work as Ludo.

## 8. Chess
**Cost: high.** Move validation, check/mate, castling, en passant, promotion, draws by repetition. **Stickiness: high but narrow** — chess players are devoted, and everyone else bounces.

Honest note: chess is a solved market with excellent free apps. Building it here is a lot of work to be worse than lichess. Worth it only if the *social* framing (rivalry records against friends in your contacts) is the whole point — which it might be.

---

# Tier 3 — later or not at all

## 9. Archery / Snow Fight
Event-driven, no tick loop, low-medium cost. Fine games, but neither has an obvious hook and they compete with Air Hockey for the same "fast arcade" slot.

## 10. Ping Pong, Pool
Ping Pong shares Air Hockey's physics and adds little. Pool is genuinely hard — multi-ball physics, spin, pocket detection — and is the wrong place to spend a physics budget.

---

# Ideas not in the original plan, worth considering

## 11. Would You Rather / This or That
**Cost: trivial.** Two options, both answer, reveal, see whether you matched. Not really a game — a **conversation generator**, which in a messenger is arguably worth more than a game. Reuses the RPS simultaneous-reveal engine almost verbatim.

## 12. Trivia head-to-head
**Cost: low-medium** (needs a question bank, which is the real cost). Same simultaneous-answer shape, high replay value, and category selection gives it depth for free.

## 13. Drawing telephone
**Cost: medium-high** (needs a drawing surface and image transport, though the app already has media). **Stickiness: extremely high in groups**, and it is the most *shareable* thing on this page — the output is a funny artefact that lands back in the chat.

This is the one idea here that could plausibly drive installs. It is also the one that most needs the group-lobby work.

---

# Recommended sequence

1. **Daily Challenge** on existing Snake — highest return, no new engine.
2. **Ultimate Tic Tac Toe** — free depth from existing code.
3. **Word Duel** — broadest audience, low cost.
4. **Sea Battle** — async play fits the messenger shape.
5. **Multi-player lobby work** (unlocks Snake 3-6P *and* Ludo *and* Cards).
6. **Air Hockey** — the physics helper that Ping Pong and Pool would later share.
7. **Ludo**, then **Voiid Cards**.

Note that steps 1-4 add **zero** new infrastructure. Everything before the lobby work is a rules module plus a renderer, which is exactly what the `GameEngine` interface was designed for.
