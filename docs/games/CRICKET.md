# Hand Cricket

> **Files:** [`engine/cricket/index.ts`](../../backend/games/src/engine/cricket/index.ts) (281) · [`CricketMatchView.swift`](../../apps/ios/Voiid/Voiid/Games/CricketMatchView.swift), [`CricketBotView.swift`](../../apps/ios/Voiid/Voiid/Games/CricketBotView.swift), [`CricketPitch.swift`](../../apps/ios/Voiid/Voiid/Games/CricketPitch.swift), [`CricketBot.swift`](../../apps/ios/Voiid/Voiid/Games/CricketBot.swift), [`OversSheet.swift`](../../apps/ios/Voiid/Voiid/Games/OversSheet.swift) · Android equivalents
> **Spec:** [`../GAMES_HAND_CRICKET.md`](../GAMES_HAND_CRICKET.md)

Simultaneous secret pick 0-6, two innings, 2 wickets, 1-5 overs. Structurally RPS with a scoreboard — and the best-designed game in the app.

---

# 1. What is good

- **The rules were actually decided, not inherited.** [`GAMES_HAND_CRICKET.md`](../GAMES_HAND_CRICKET.md) §2 picks a side on every house rule with a stated reason: 0 is a dot ball, 0-vs-0 is out (so a batter can't block forever), 2 wickets, no powerplay because it "multiplies variance without adding a decision." This is real game design, not a port of street folklore.
- **The anti-cheat invariant is documented at the point of danger:** if `pending` ever enters `serialize()`, the game is broken — the second picker could match at will for a guaranteed wicket, or dodge forever for unlimited runs. That warning sits directly above the code it protects.
- **Innings state is genuine server-owned state** — phases, target, role reversal, over clock — which is the thing that makes this more than RPS with extra steps.
- **Overs are a real choice**, exposed in the UI, locked at match start: fewer overs rewards risk, more rewards patience.
- `CricketPitch` (321 iOS / 394 Android) is the most produced visual in the turn-based set.

---

# 2. What is missing

## 2.1 The game does not explain itself — and this is the top issue

**"Same number = out" is not discoverable.** A player who has never played hand cricket picks a number, sees "WICKET", and has no idea why. There is no rules screen, no first-run explainer, no inline hint anywhere in the app.

Every other game in the catalog is self-evident from the board. This one is not, and it is the game most likely to be a new player's first *and last* match. The spec is excellent; none of it reaches the player.

**Minimum fix:** a one-screen "how to play" on first launch of the game and behind a `?` in the HUD, plus an inline line the first time a wicket falls: *"Same number — that's a wicket."*

## 2.2 The chase has no tension surfaced

The second innings is the good part: a known target, a shrinking ball count, and a batter who must take risks. The state carries everything needed — `target`, `ballsBowled`, `overs`, `wickets` — and the HUD does not turn it into pressure. Missing: **required run rate**, **balls remaining**, and an escalating visual/audio state as it gets close.

"12 needed off 8 balls" is the single most exciting sentence in cricket and the app never says it.

## 2.3 No ball-by-ball commentary

`history: BallLog[]` records both picks, the batting seat, innings, runs and wicket for every ball. It is serialized and largely unused. A running commentary strip is free from data already on the wire, and it is what makes a scoreboard feel like a match.

## 2.4 The bot has no visible personality

`CricketBot` picks numbers; the player has no sense of an opponent. Cricket is a bowler-vs-batter mind game, and the bot is anonymous.

## 2.5 No innings-break beat

Innings change is the natural halftime — target reveal, roles swap. Currently it just happens. This is the cheapest drama in the game.

## 2.6 Toss is invisible

The server picks who bats first at random and announces it in the opening frame. Correct decision (a toss UI would be a second interaction before play), but it currently reads as arbitrary rather than as a toss. A one-second coin animation over the already-decided result costs nothing and frames it.

---

# 3. What makes it addictive

| # | Change | Why |
|---|---|---|
| 1 | **How-to-play screen + first-wicket inline hint** (§2.1) | Without this the game is unplayable for anyone who doesn't already know it. Nothing else on this list matters more. |
| 2 | **Chase HUD: required rate, balls left, escalating tension** (§2.2) | The chase is the game. Surface it and the last over becomes the reason people replay. |
| 3 | **Ball-by-ball commentary strip** (§2.3) | Free from `history`. Turns a scoreboard into a match. |
| 4 | **Innings-break screen** with the target reveal | The natural halftime beat, currently skipped. |
| 5 | **Named bot personalities** — an aggressive bowler, a patient one, one that reads your patterns like `RpsBot` does | Gives the mind game an opponent. Reuse the RPS frequency-tracking approach; it fits here even better because picks are 0-6. |
| 6 | **Super over on a tie** | Ties are currently a draw row. A one-over decider is the most-watched thing in real cricket and it is a small engine addition. |
| 7 | **Career batting stats** — total runs, high score, best chase, strike rate | Cricket is the game where stats *are* the culture. This is the most natural fit for progression in the whole app. |
| 8 | **Rivalry record vs each friend** | See [`CROSS_CUTTING.md`](./CROSS_CUTTING.md). |

**Recommendation:** #1 is a blocker on the game being playable at all by newcomers. #2 and #3 are cheap and are what make a match memorable. This game has the most upside per unit of work of the three turn-based games, because the design underneath it is already right.
