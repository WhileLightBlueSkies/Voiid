# Hand Cricket — Game Spec

Third game in the Voiid games system. Read `GAMES.md` first: this document specifies only
what is particular to hand cricket and assumes the transport, invite flow, referee process
and leaderboard described there.

---

## 1. Why this game fits, and what it reuses

Hand cricket is **structurally the same problem as Rock Paper Scissors**: both players choose
a number secretly and reveal simultaneously. Everything the RPS engine already does — hold
each choice server-side, never serialize the opponent's pending choice, reveal both in one
broadcast — is exactly what hand cricket needs. So this is not new architecture; it is a
second rules module with a richer scoreboard.

The one genuinely new thing is **innings state**: unlike RPS, a hand cricket match has phases
(first innings, second innings, done), a target, and role reversal. That is state the server
owns, and it is why the game cannot be a client-only affair even though the rules are trivial.

| Concern | Hand cricket | Already solved by |
| --- | --- | --- |
| Simultaneous secret reveal | Both pick 1–6 | RPS engine (`engine/rps`) |
| Anti-cheat on the reveal | Never send the pending pick | RPS `serialize()` |
| Turn/phase tracking | Innings, target, roles | New — this doc, §3 |
| Invite + join | Ordinary E2EE message | `GameInvite` + `POST /games/matches` |
| Result → leaderboard | `winner_id` on the match row | `game_match_results` |

---

## 2. Rules as implemented (the decisions, not the folklore)

Hand cricket has no single canonical ruleset, so this section is the **normative** one for
Voiid. Where the street game varies, the choice made here is stated with its reason.

### Core loop

1. Both players secretly choose a number **0–6** (0 = closed fist).
2. Both reveal at once.
3. **Different numbers** → the batter scores their own number as runs. Showing 0 scores
   nothing — a dot ball.
4. **Same number** → the batter is **out**. This includes **0 vs 0**.

### Voiid's choices among the common house rules

| Rule | Voiid's choice | Why |
| --- | --- | --- |
| **Dot ball (0)** | **Used.** Range is 0–6 (closed fist = 0). | Gives the batter a genuine defensive option, and the bowler something to read. |
| **0 vs 0** | **OUT**, like any other match | Keeps one rule with no exceptions: same number = out. If 0-vs-0 were safe, a batter could block forever against a bowler who also picked 0, and the match would stall with no way out. |
| **Wickets per innings** | **2** | With overs also capping the innings there are two end conditions already; 2 wickets keeps a wicket meaningful without ending the match on one unlucky guess. |
| **Overs** | **Player picks 1–5 at match start**, 6 balls each (6–30 balls) | Bounds the match so it can't run indefinitely, and makes the choice a real one: fewer overs rewards risk, more rewards patience. Locked once the match begins, exactly like bot difficulty. |
| **Powerplay / doubles** | **Not used.** | Multiplies variance without adding a decision. |
| **Who bats first** | **Server picks at random**, announced in the opening frame | A coin-toss UI is a second interaction before the game starts. Random and stated is honest and instant. |
| **Tie** | **Recorded as a draw** (`winner_id` null) | Matches how tic-tac-toe draws are already stored, and the leaderboard already counts draws separately. |

### Innings

An innings ends when **either** 2 wickets fall **or** the overs are bowled out — whichever
comes first.

- **First innings**: batter accumulates runs until the innings ends. Final total sets the
  **target** (`score + 1`) to chase.
- **Second innings**: roles swap. The chasing batter wins the moment they **reach** the
  target. They lose if their innings ends while still short. Equal totals = tie.
- **Chase ends immediately on reaching the target.** No "play out the overs" — the match is
  decided, and continuing would be theatre.

---

## 3. Server state (`backend/games/src/engine/cricket`)

Follows the `GameEngine` interface exactly as `rps` does.

```ts
const BALLS_PER_OVER = 6;
const WICKETS_PER_INNINGS = 2;

interface State {
  players: string[];        // seat order, fixed at creation
  overs: number;            // 1..5, chosen at creation, never changes
  battingSeat: 0 | 1;       // who is batting RIGHT NOW
  innings: 1 | 2;
  scores: [number, number]; // runs by seat
  wickets: [number, number];// wickets lost by seat
  ballsBowled: number;      // in the CURRENT innings; resets on the switch
  target: number | null;    // set when innings 1 ends; runs needed to WIN (score+1)
  pending: [number | null, number | null];  // secret picks — NEVER serialized
  history: BallLog[];
  finished: boolean;
  winnerIdx: number | null; // null on a tie
}

interface BallLog {
  picks: [number, number];  // both picks, safe once resolved
  battingSeat: 0 | 1;
  innings: 1 | 2;
  runs: number;             // 0 on a wicket or a dot
  wicket: boolean;
}
```

### `serialize()` — what the client is allowed to know

```ts
{
  players, overs, innings, battingSeat, scores, wickets,
  ballsBowled, ballsTotal,          // ballsTotal = overs * 6, so the client needn't derive it
  target,
  hasPicked: [boolean, boolean],    // CRITICAL: booleans, never `pending`
  history,                          // resolved balls only
  finished, winnerUserId
}
```

The `hasPicked` line carries the entire anti-cheat property of the game, exactly as
`hasThrown` does in RPS. **If a future change serializes `pending`, the game is broken** — the
player who picks second could always avoid the batter's number, or match it at will.

### Input

```ts
{ pick: 0 | 1 | 2 | 3 | 4 | 5 | 6 }
```

Rejected when: match finished, pick outside 0–6, or this seat has already picked this ball
(re-picking would let a player change their mind after the opponent commits).

### Overs at creation

`overs` arrives with the match, not as a game input — it is chosen in the setup sheet before
anything exists, the same way bot difficulty is. `POST /games/matches` therefore accepts an
optional `options` object (`{ overs: 3 }`), which the factory reads and clamps to 1–5. A
missing or invalid value defaults to **2 overs**.

---

## 4. Client state machine

The renderer is a **dumb view**, per `GAMES.md` §4 — it never decides runs, wickets, or who
won. It draws what the frame says and reports picks.

States a ball can be in, and what each shows:

| Condition | Display |
| --- | --- |
| Neither has picked | Both hands covered; "Pick a number" |
| I picked, they haven't | My hand covered, theirs covered; "Waiting for them…" |
| They picked, I haven't | Both covered; "They've picked — your pick" |
| Ball resolved (from `history.last`) | Both hands revealed + outcome banner |
| Innings 1 over | "N to win" banner, roles visibly swapped |
| Finished | Result + final scores |

Always on screen: **score/wickets** for the batting side, and **balls bowled of total**
(`ballsBowled` / `ballsTotal`) rendered as overs — `2.3` means two overs and three balls. In
the second innings the **target** sits beside it, because a chase without a number is not a
chase.

**The opponent's pick is never rendered before resolution**, for the same reason as RPS: the
server does not send it, and inventing it would be showing state the client was deliberately
denied.

---

## 5. Animations — which event triggers which

Runs are not all equal, and the animation vocabulary should say so. Requested behaviour,
specified precisely:

| Outcome | Animation | Rationale |
| --- | --- | --- |
| **6 runs** | Bat strike → ball arcs out over the boundary | The biggest hit deserves the biggest motion |
| **4 runs** | Bat strike → ball races along the ground to the rope | Distinct from a six: flat, fast, not airborne |
| **1, 2, 3 runs** | **No animation.** Score ticks up only | If every ball animates, nothing reads as special. Restraint is what makes 4 and 6 land |
| **0 (dot ball)** | **No animation.** Brief "dot" marker | A dot is the absence of an event; animating it would contradict that |
| **Wicket, matched on 0–2** | **Catch** — fielder takes it | A low matched number reads as a soft edge into hands |
| **Wicket, matched on 3–6** | **Bowled** — stumps struck, timber flies | A big swing that misses is a hit wicket |
| **Over complete** | Brief "End of over N" marker | The innings has structure now; the player needs to feel the clock |
| **Innings change** | Scoreboard flip + "N to win" | The one moment the whole frame of reference changes |
| **Match won/lost** | Result card, bouncy entry | Matches the existing bot-screen result treatment |

The wicket animation is chosen by the **matched number**, so it is deterministic from the ball
itself and needs no extra state: `picks[0] <= 2 ? catch : bowled`.

3D treatment: these are **sprite/transform animations over a styled pitch**, not a 3D engine.
Compose/SwiftUI transforms plus the artwork you supply gets the "3D-ish" look the cards
already have, with no new dependency.

---

## 6. Build order

Smallest end-to-end slice first, matching `GAMES.md` §8:

1. **Rules module + registry entry** — `engine/cricket/index.ts`, unit-testable in isolation
2. **Migration** — one row in `games` (`slug: 'cricket'`), no schema change needed
3. **Bot screen** — local opponent, full animation set, no network. Fastest path to seeing it
4. **Online screen** — same renderer over `GamesEngine` frames
5. **Sounds** — wired to the same events as the animations (§5)
6. **iOS parity** — both screens

The bot comes before the online path deliberately: it exercises every animation without
needing two devices.
