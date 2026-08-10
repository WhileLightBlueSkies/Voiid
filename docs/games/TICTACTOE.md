# Tic Tac Toe

> **Files:** [`engine/tictactoe/index.ts`](../../backend/games/src/engine/tictactoe/index.ts) (158) · [`TicTacToeView.swift`](../../apps/ios/Voiid/Voiid/Games/TicTacToeView.swift), [`TicTacToeBotView.swift`](../../apps/ios/Voiid/Voiid/Games/TicTacToeBotView.swift), [`TicTacToeBoard.swift`](../../apps/ios/Voiid/Voiid/Games/TicTacToeBoard.swift), [`TicTacToeBot.swift`](../../apps/ios/Voiid/Voiid/Games/TicTacToeBot.swift) · [`TicTacToeScreen.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeScreen.kt), [`TicTacToeBotScreen.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeBotScreen.kt), [`TicTacToeBot.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeBot.kt)

The reference implementation — deliberately the first game built, because trivial rules meant any bug found was a plumbing bug. That job is done and the code is correct.

---

# 1. What is good

- **Genuinely correct and complete.** Every illegal input is rejected and the file says which: out of range, occupied, not your turn, game over. There is no frame a modified client can send that moves twice or places the opponent's mark.
- **`line` is serialized**, so the client highlights the winning triple without re-deriving the win. Small, right call.
- **The bot is honest about being unbeatable** at `skill 1.0` (minimax), and the skill slider degrades it by *probability of playing the optimal move* rather than by weakening the search. That is the correct way to build a difficulty scale.
- Board extracted into its own view on iOS.

---

# 2. What is missing

## 2.1 The real problem: solved games have no replay value

Tic Tac Toe is a **solved game**. Two competent players draw 100% of the time, and a competent player never loses to the bot at any difficulty. There is no skill ceiling, no variance, and nothing to learn after the first ten minutes. Every other item in this doc is downstream of that.

**This is not a bug and it is not fixable by polish.** The game is complete and correct; it is just finished. The only ways to give it legs are to change the shape of the game (§4) or to wrap it in a meta-game (see [`CROSS_CUTTING.md`](./CROSS_CUTTING.md)).

## 2.2 No draw-specific treatment

A draw is the *expected* outcome between competent players and it is currently the least interesting screen in the app. It deserves at minimum different copy and different audio from a loss.

## 2.3 No first-move alternation

Whoever created the match is always X, and X has the advantage. Across a series that is a systematic bias. Alternate the starting seat by round.

## 2.4 No board memory between matches

Rematch doesn't exist ([`CROSS_CUTTING.md`](./CROSS_CUTTING.md)), so a "series" is not a concept — every match is standalone and nothing accumulates.

## 2.5 Android board is inline in the screen

Maintainability only; iOS extracted `TicTacToeBoard.swift` and Android did not.

---

# 3. What makes it addictive

Given §2.1, honest ranking:

| # | Change | Why |
|---|---|---|
| 1 | **Best-of-3 or best-of-5 series, alternating who starts** | The single highest-value change. Turns a coin-flip-or-draw into a match with a shape. RPS already does exactly this (`target`, default 3) — copy the pattern directly into the TTT engine. |
| 2 | **Speed mode: 5 seconds per move** | Time pressure is the only way to reintroduce mistakes into a solved game, and mistakes are what makes it fun. Cheap: one timer in the engine, forfeit-the-turn on expiry. |
| 3 | **Head-to-head record vs each friend** | "You 4 — Priya 3" above the board reframes an unwinnable game as an ongoing rivalry. Data is already in `game_match_results`. |
| 4 | **Ultimate Tic Tac Toe as a mode** | 9 boards in a 3×3 grid; your move dictates which board the opponent plays in. Same input frame (a cell index 0-80), same UI language, **not** a solved game, and a real skill ceiling. This is the cheapest way to get a genuinely deep board game out of code that already exists. |
| 5 | **Misère mode** (three-in-a-row *loses*) | One line in the win check, completely different game, and it defeats everyone's ingrained instincts — which is exactly why it's funny to play with a friend. |
| 6 | Draw-specific copy and sound | Cheap dignity for the most common outcome. |

**Recommendation:** ship #1 and #3, then treat **Ultimate Tic Tac Toe (#4)** as the actual investment. It reuses the board renderer, the input frame and the entire netcode, and unlike the base game it is worth playing more than once.
