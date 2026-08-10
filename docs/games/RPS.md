# Rock Paper Scissors

> **Files:** [`engine/rps/index.ts`](../../backend/games/src/engine/rps/index.ts) (179) · [`RpsMatchView.swift`](../../apps/ios/Voiid/Voiid/Games/RpsMatchView.swift), [`RpsBotView.swift`](../../apps/ios/Voiid/Voiid/Games/RpsBotView.swift), [`RpsBot.swift`](../../apps/ios/Voiid/Voiid/Games/RpsBot.swift) · [`RpsMatchScreen.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/RpsMatchScreen.kt), [`RpsBotScreen.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/RpsBotScreen.kt), [`RpsBot.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/RpsBot.kt)

Best-of-3, simultaneous reveal. The simplest rules in the app sitting on top of the most interesting server-side problem in it.

---

# 1. What is good

- **The simultaneity design is genuinely correct.** Throws are held server-side and never appear in the opponent's state while the round is open — `serialize()` reports only that a player *has thrown*. This prevents a real cheat (move second, see the first throw, win every time), and it is the reason this trivial game justifies being server-authoritative.
- **Best-of-3 rather than single-round**, with the reasoning stated: one round is a coin flip and a coin flip makes a meaningless leaderboard entry. Correct call, and the game the other two turn-based games should copy.
- **The bot is the most intellectually honest thing in the codebase.** It acknowledges that against a truly random opponent RPS has no skill, so difficulty is implemented as *exploitation of human non-randomness* — frequency-tracking the player and countering their most likely next throw at `skill` probability. It explicitly refuses to claim unbeatability. That is the right model, and it happens to also be how the game is actually played well.

---

# 2. What is missing

## 2.1 The bot's insight is not shown to the player

The bot reads your patterns — and never tells you. That is the entire game hiding behind the curtain. A player who loses 6 rounds straight to a pattern-reader experiences it as bad luck, not as being outplayed, and learns nothing.

**This is the biggest missed opportunity in the game.** After the match, show what it saw:

```
You threw rock 7 of 12 times.
After a loss, you switched 80% of the time.
That's what I was counting on.
```

Suddenly there is something to *beat*, and the next match is about being unpredictable rather than about luck. The data already exists in the bot's frequency table — it is thrown away at match end.

## 2.2 No round history on screen

`history: RoundLog[]` is serialized and carries every round's throws and winner. Neither client shows a running strip of it. In a best-of-3 you cannot see what your opponent has been doing, which is the only information the game offers.

## 2.3 The reveal is the whole game and it is under-produced

Simultaneous reveal is the dramatic beat. Both throws land in the same broadcast — that is a synchronised moment the server hands the client for free, and it deserves a real countdown ("rock… paper… scissors… shoot"), a synchronised commit animation on both devices, and a hitstop on the reveal. Audio exists; the choreography does not.

## 2.4 No "waiting for opponent" texture

After you throw, you sit until they do. There is nothing to look at and no indication whether they are thinking or gone (no AFK handling — see [`CROSS_CUTTING.md`](./CROSS_CUTTING.md)).

## 2.5 Best-of-N is fixed at 3

`target` is a state field with a default, and no UI exposes it. Cricket has an overs picker; RPS has no equivalent.

---

# 3. What makes it addictive

| # | Change | Why |
|---|---|---|
| 1 | **Post-match pattern read-out** (§2.1) | Converts luck into skill in the player's own head. Highest impact, data already exists, one screen. |
| 2 | **Round history strip** | The only information the game has, currently hidden. |
| 3 | **Real reveal choreography** — countdown, synchronised commit, hitstop | This game is 100% one dramatic beat; produce it properly. |
| 4 | **A "predictability score" that persists** | Track how exploitable a player is across all their matches and show it as a stat they can improve. This is the meta-game RPS actually has, and nobody ships it. |
| 5 | **Best-of-N picker (3 / 5 / 7)** | Longer series reward pattern-reading and punish luck — which is precisely what makes the game skill-based. Copy the `OversSheet` pattern. |
| 6 | **Lizard-Spock (5 throws) as a mode** | Doubles the state space, breaks everyone's memorised habits, ~10 lines in `BEATS`. Cheapest real depth available. |
| 7 | **Sudden-death tiebreak** on 1-1 | Framing, not mechanics, but a "final round" is worth more than a third round. |

**Recommendation:** #1 and #2 together turn this from a coin flip into a psychology game, and they are both cheap. Do them before anything else.
