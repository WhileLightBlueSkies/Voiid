# The eight unbuilt games — design docs

> **Status:** design only. No engine, renderer, migration or client screen in this folder has been written.
> **Written against:** [`GameEngine.ts`](../../../backend/games/src/engine/GameEngine.ts) · [`index.ts`](../../../backend/games/src/index.ts) · [`snake/index.ts`](../../../backend/games/src/engine/snake/index.ts) · [`cricket/index.ts`](../../../backend/games/src/engine/cricket/index.ts) · [`GAMES.md`](../../GAMES.md) · [`SNAKE.md`](../SNAKE.md) · [`SOUND_DESIGN.md`](../SOUND_DESIGN.md) · [`CROSS_CUTTING.md`](../CROSS_CUTTING.md)

Four games ship today: Tic Tac Toe, RPS, Hand Cricket, Snake. These are the eight named in [`GAMES.md`](../../GAMES.md) that do not, each with a full design doc detailed enough to build from.

| Doc | Game | Kind | Hook, in one line |
|---|---|---|---|
| [`SEA_BATTLE.md`](./SEA_BATTLE.md) | Sea Battle | turn-based, hidden state | The only game here you can play across a whole day — fire a shot, put the phone down, get a notification |
| [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) | Air Hockey | continuous, 2-player physics | Ninety seconds, no rules to learn, and the rematch button is the whole game |
| [`VOIID_RUN.md`](./VOIID_RUN.md) | Voiid Run | single-player, real-time | One seed a day, everyone runs the same course, and the leaderboard is your contacts |
| [`LUDO.md`](./LUDO.md) | Ludo | turn-based, 2-4 player | The only four-player game in the catalog, and the one with a built-in audience |
| [`VOIID_CARDS.md`](./VOIID_CARDS.md) | Voiid Cards | turn-based, 2-6 player, hidden hands | A group game where the trash talk is the point and the cards are the excuse |
| [`CHESS.md`](./CHESS.md) | Chess | turn-based, deep rules | A permanent record against one specific friend — not chess quality, rivalry |
| [`ARCHERY.md`](./ARCHERY.md) | Archery | event-driven | Both draw, both loose, both find out together — RPS's dramatic beat with a skill ceiling |
| [`SNOW_FIGHT.md`](./SNOW_FIGHT.md) | Snow Fight | event-driven | Archery plus a position to defend and cover that stops stopping bullets |

---

# 1. What these games share

## 1.1 The contract, unchanged

Every one of them is a folder under [`backend/games/src/engine/`](../../../backend/games/src/engine/) implementing [`GameEngine`](../../../backend/games/src/engine/GameEngine.ts), registered by one line in [`registry.ts`](../../../backend/games/src/engine/registry.ts), plus one catalog row and one renderer per platform. Transport, auth, invites, rate limiting, match lifecycle and results are already built and none of these games change them.

The division that already exists holds for all eight: a factory with `tickHz` gets a per-match interval loop; a factory without one is purely reactive and costs nothing when nobody is looking at it. Six of these eight games declare no `tickHz` at all.

## 1.2 The seat model

`players[]` is seat order and the index into it is the seat. Every existing engine uses this ([`cricket/index.ts:82`](../../../backend/games/src/engine/cricket/index.ts#L82), [`tictactoe`](../../../backend/games/src/engine/tictactoe/index.ts)), the outcome map is keyed by user id, and `winnerId: null` means draw rather than unfinished. Nothing here departs from it. Ludo and Voiid Cards extend it from two seats to four and six, which is a change in the *client* picker, not in the model.

## 1.3 One RNG, and a rule about where its seed lives

Seven of the eight use `Rng` (mulberry32) from [`snake/geometry.ts:113`](../../../backend/games/src/engine/snake/geometry.ts#L113) — Chess is the exception and draws nothing after the opening colour assignment. It should be promoted out of `snake/` into `engine/rng.ts` when the second consumer arrives — it has no snake in it and the file comment already explains why `Math.random()` is fatal for anything that round-trips through `restore`.

**Then the rule that is not obvious, and that Snake gets to break:**

> The seed goes in `serializeSecret()`, not `serialize()`, whenever a future draw from it is information a player would pay for.

Snake serializes its seed onto the wire ([`snake/index.ts:786`](../../../backend/games/src/engine/snake/index.ts#L786)) and that is fine there: the sequence drives pellet spawn positions and bot jitter, and knowing where a pellet will appear a frame before it is drawn is worth nothing. It is **fatal** in Ludo, where the next draw is the dice, and in Voiid Cards, where the sequence *is* the shuffle. A client holding the seed in either of those games knows the future.

So the eight sort into three groups, and every doc states which it is in and why rather than copying Snake's placement:

| Placement | Games | Why |
|---|---|---|
| **`serializeSecret()`** | Ludo, Voiid Cards, Archery, Snow Fight | The next draw is the dice, the shuffle, or the wind sequence. A client holding the seed knows the future |
| **`serialize()`, publicly** | Sea Battle, Air Hockey | Sea Battle draws only bot placement in a practice match; Air Hockey draws a serve angle already visible the instant it happens and a half-degree wall jitter. Nothing to buy |
| **Public *by necessity*** | Voiid Run | The client must have the seed to generate the course. The course is not secret information, it is the shared premise — see [`VOIID_RUN.md`](./VOIID_RUN.md) §4.3, which inverts this rule deliberately and protects the score by validation instead |
| **No RNG at all** | Chess | One colour draw at creation, nothing after |

## 1.4 Determinism is a persistence requirement, not a nicety

The runtime round-trips `serialize()` / `restore()` on **every input** ([`index.ts:279`](../../../backend/games/src/index.ts#L279)) and persists on a throttled cadence (`PERSIST_EVERY = 5`, [`index.ts:155`](../../../backend/games/src/index.ts#L155)). Two bugs are already documented in [`GameEngine.ts`](../../../backend/games/src/engine/GameEngine.ts): state omitted from `serialize()` is silently reset on the next tick, and a simultaneous-reveal secret omitted from it was dropped a millisecond after being made, which looped hand cricket forever between two players until `serializeSecret` was added.

Every doc in this folder therefore lists its `serialize()` shape field by field with a reason per field. Not as a formality — three of the eight found a field during that exercise that would have been silently lost.

## 1.5 Sound

Every game inherits [`SOUND_DESIGN.md`](../SOUND_DESIGN.md), including its central rule: **one shared `catch.wav`, played unmodified, at the moment a player's attempt is intercepted or ended by the opponent.** The mapping for the new games:

| Game | The catch moment |
|---|---|
| Sea Battle | One of *your* ships is sunk |
| Air Hockey | Your shot is stopped by their paddle while travelling toward their goal |
| Ludo | Your token is captured and sent back to the yard |
| Voiid Cards | A stacked draw penalty lands on you |
| Chess | One of your pieces is captured |
| Archery | You lose the round — their arrow beat yours |
| Snow Fight | A snowball hits you |
| **Voiid Run** | **None — and that is correct** |

Voiid Run is the exception and it is the same exception Snake already makes for death by border: *"You were not caught, you crashed"* ([`SOUND_DESIGN.md`](../SOUND_DESIGN.md) §4.2). Nothing intercepts you in a single-player runner. Playing `catch` on an obstacle collision would be the first thing to teach the player that the sound means nothing in particular, which is exactly what the shared-vocabulary rule exists to prevent.

## 1.6 Retention is a day-one requirement

[`CROSS_CUTTING.md`](../CROSS_CUTTING.md) documents four shipped games with no rematch, no post-match summary and no head-to-head record. That is the single largest gap in the games surface and it exists because all four were built without those being requirements.

They are requirements here. **No game in this folder is considered shippable without:**

1. **Rematch** on the post-match screen, with the opponent's name on it
2. **A post-match summary** worth reading — result, the two or three numbers that game is about, whether it was a personal best, and what changed in the head-to-head
3. **Head-to-head record** against that specific opponent, shown before and after
4. **Share result into the chat it was arranged in** — this app is a messenger and this is its only structural advantage over a standalone game app

Every doc's §12 argues its own hook on top of that floor, and every doc answers two specific questions: what the first thirty seconds feel like for someone who has never played, and what someone with fifty matches is still chasing.

---

# 2. Five things in the existing architecture that must change

These are shared infrastructure, not per-game work. Four of the eight games are **blocked** on one or more of them. Sequencing them wrong means building the same thing twice.

## 2.1 Per-recipient wire frames — blocks Sea Battle and Voiid Cards

[`broadcast()`](../../../backend/games/src/index.ts#L69) builds **one** frame and publishes the same bytes to every player:

```ts
const frame = JSON.stringify({ type: 'game_state', /* ... */ payload: wire ?? m.state });
for (const uid of m.players) await pub.publish(`channel:user:${uid}`, frame);
```

There is no way to send a player something the others do not get. `serializeSecret` is the wrong tool: it is *server-only* and never reaches a client at all, which is right for a hand-cricket pick and wrong for your own fleet — you need to see your own ships.

The workaround of "the client remembers what it placed" collapses on rejoin, reinstall, second device, and cold start after a push notification. For an async game, cold start **is** the normal case.

**The change:** one new optional method on the interface, preferred by the runtime when present.

```ts
/**
 * The state as ONE specific player may see it.
 *
 * Distinct from serializeForWire(), which is a bandwidth projection sent identically to
 * everyone. This is an INFORMATION projection: your own fleet, your own hand. It is called
 * once per recipient, so it must be pure — serializeForWire() is explicitly allowed to clear
 * delta buffers and this is explicitly not.
 *
 * A spectator, or any caller with no seat, gets serialize()/serializeForWire() instead, which
 * is what makes a leak to a spectator structurally impossible rather than merely unwritten.
 */
serializeForPlayer?(playerId: string): GameStatePayload;
```

`broadcast()` moves from taking a pre-built payload to taking the engine, and builds one frame per recipient when the method exists. Cost: N JSON serializations per broadcast instead of one, for turn-based games broadcasting a few times a minute. Nothing measurable.

Deliberately **not** overloading `serializeForWire(playerId?)`: its contract already says it "may clear per-frame delta buffers", Snake relies on that ([`snake/index.ts:721`](../../../backend/games/src/engine/snake/index.ts#L721)), and calling it once per recipient would drain the buffers after the first player and under-report changes to everyone else. A separate method with a separate purity requirement cannot make that mistake.

## 2.2 Durable turn-based state — blocks Sea Battle, Chess, and async anything

Live match state is a Redis key with a **one-hour TTL** ([`redis.ts:27`](../../../backend/games/src/redis.ts#L27)):

```ts
export const STATE_TTL_SECONDS = Number(process.env.VOIID_GAME_STATE_TTL_SECONDS) || 3600;
```

An unfinished chess game evaporates in an hour. So does a Sea Battle where the opponent went to lunch. Both docs describe async play as their main reason to exist, and **neither is buildable as designed until this changes.** Raising the TTL is not the fix: [`GAMES.md`](../../GAMES.md) §5 accepts that a games-process restart loses in-flight arcade matches, and Redis is not the place to store something that has to survive a week.

**The change:** a `game_match_state` table — `match_id` primary key, `state jsonb`, `secret jsonb`, `seq int`, `updated_at`. Written on every accepted input **for turn-based games only**, and read by `loadMatch` as a fallback when Redis misses. Redis stays the hot path.

Scoped to turn-based deliberately. [`index.ts:308-322`](../../../backend/games/src/index.ts#L308-L322) already documents why a continuous game must not persist per input — Snake's `serialize()` captures ~260 food items plus every body polyline, ten to fifteen times a second per steering player. A turn-based game moves every few seconds and is nowhere near a budget, which is the same reasoning that leaves those games round-tripping through Redis today.

## 2.3 A deadline sweeper — blocks turn timeouts in all six turn-based games

[`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §6: a turn-based match with an absent opponent hangs forever. There is no move timer and no forfeit, and there is nowhere to put one — turn-based factories have no `tickHz` and therefore no clock, by design.

Giving them a `tickHz` to get a timer would be the wrong fix twice over: it would start a per-match interval for a game that changes state once a minute, and a `setTimeout` measured in days would not survive the weekly process restart it is supposed to outlast.

**The change:** one Redis sorted set, `games:deadlines`, scored by epoch milliseconds and keyed by match id, plus one `setInterval(1000)` in the games service that pops what is due and feeds it back through the same path an input takes. Two optional interface additions:

```ts
/** Epoch ms by which the player to move must act, or null when nothing is pending. */
deadlineAt?(): number | null;
/** The deadline passed. Same return shape as applyInput — forfeit, auto-move, or pass. */
onTimeout?(): ApplyResult;
```

The sorted set survives restarts, one timer serves every match in the process, and a deadline 72 hours out costs exactly one member in a set. Each doc specifies its own timeout value and what happens when it fires — they are not the same answer, and Chess in particular wants a real clock rather than a per-move deadline.

## 2.4 Multi-seat lobbies — blocks Ludo and Voiid Cards

Less broken than it looks. The **API already takes an array**: `POST /games/matches` accepts `opponent_ids: [uuid, ...]` ([`games.ts:96`](../../../backend/api/src/routes/games.ts#L96)), `player_ids` is a jsonb array, the catalog has `min_players`/`max_players`, and [`handleJoin`](../../../backend/games/src/index.ts#L334) already gates the start on `joined.length >= players.length` for any number of seats.

The gap is client-side and small: [`OpponentPickerSheet.swift:22`](../../../apps/ios/Voiid/Voiid/Games/OpponentPickerSheet.swift#L22) is `let onPick: (VConversation) -> Void` — a single-select callback — and its Android twin matches. Multi-select, a seat list in the lobby, and per-seat join state in [`GameLobbyView`](../../../apps/ios/Voiid/Voiid/Games/GameLobbyView.swift) is the whole job.

**This is the same work that unlocks Snake's 3-6 player mode** ([`SNAKE.md`](../SNAKE.md) §3.6), which is currently 1 human + 5 bots because the picker returns exactly one conversation. Sequence it once, three games get it.

## 2.5 `tick()` cannot tell how late it is — affects Air Hockey most

`tick()` takes no arguments, so [Snake hardcodes](../../../backend/games/src/engine/snake/index.ts#L315) `const dt = 1 / TUNING.TICK_HZ`. When a tick runs long, the `running` guard ([`index.ts:231`](../../../backend/games/src/index.ts#L231)) **drops the next one entirely** — so the simulation does not run late, it runs *slow*: a 180-second Snake match is 1800 ticks and takes however long 1800 ticks take.

Snake survives this because nothing outside the sim measures its clock. A puck does not: half a second of dropped ticks in Air Hockey is half a second where the puck was somewhere other than where physics says, and the player felt it.

**The change, in preference order:**

1. **Widen the signature to `tick(dtMs?: number)`** and have the runtime pass the true elapsed time. Backwards-compatible — every existing engine ignores the argument and behaves exactly as today.
2. Failing that, an engine measures its own wall clock internally, clamped. This works but the clamp and the last-tick timestamp then live in every engine that needs them, and `lastTickAt` must **not** be serialized: after a restart, wall time has passed but the simulation must not jump forward through it.

Air Hockey's answer either way is a **fixed-step accumulator** — integrate physics at a fixed 240 Hz regardless of how the broadcast tick fires, and carry the accumulator remainder in `serialize()`. See [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §4. That is what "tick proof" means concretely for a physics game: a late tick produces *more substeps*, not *different physics*.

---

# 3. Build order

Ordered so nothing is built twice, and each step ships on its own.

| # | Step | Why here | Unblocks |
|---|---|---|---|
| 0 | **Per-recipient wire** (§2.1) + **durable turn-based state** (§2.2) + **deadline sweeper** (§2.3) | Three small changes, one PR, and the first game needs all three | Sea Battle, Chess, every turn timer |
| 1 | **Sea Battle** | Lowest risk in the folder, and the game that proves async play works end to end | The async pattern every later turn-based game copies |
| 2 | **Air Hockey** | Inherits Snake's entire tick machinery; adds `physics2d/`, which Ping Pong and Pool would later share | The continuous-physics template |
| 3 | **Multi-seat lobbies** (§2.4) | Client work, no engine | Ludo, Voiid Cards, **and Snake 3-6P** |
| 4 | **Ludo** | Biggest audience of the four-player games, simplest of them | — |
| 5 | **Archery**, then **Snow Fight** | Share one engine shape; Snow Fight is Archery plus a positional layer | — |
| 6 | **Voiid Cards** | Hardest hidden-state game; wants the async and multi-seat patterns already proven | — |
| 7 | **Voiid Run** | Highest cost, highest risk, and the only one that reuses none of the multiplayer stack | — |
| 8 | **Chess** | Last, or never. See [`CHESS.md`](./CHESS.md) §1 | — |

**Steps 1 and 2 are the recommended slice.** One async turn-based game and one real-time physics game, built on infrastructure that six more games then reuse. If only two of these eight ever ship, they should be these two.

## 3.1 Two games we recommend against building now

Stated plainly here rather than buried, because a doc that recommends everything it describes is not advice.

- **Chess** — a solved market with excellent free apps. Building it here is months of rule work to be worse than lichess, and the only argument that survives is the *social* one: a permanent record against one friend in your contacts. If head-to-head records (§1.6) ship first and people actually use them, that argument becomes real. If they do not, chess is a large amount of work for a feature nobody asked for twice. Full reasoning in [`CHESS.md`](./CHESS.md) §1.
- **Voiid Run** — the only game here needing sustained 60 fps procedural rendering on both platforms, and the only one that uses none of the multiplayer architecture that makes the other seven cheap. Its hook is genuinely good and genuinely conditional: it is worth building **only if** the daily challenge and share-to-chat loop ship with it. Without those it is a worse Subway Surfers that the player already has installed. Full cost comparison in [`VOIID_RUN.md`](./VOIID_RUN.md) §1.3.

---

# 4. Where these docs disagree with existing docs

Flagged rather than silently contradicted, per the house rule.

| Existing | This folder | Why |
|---|---|---|
| [`GAMES.md`](../../GAMES.md) §1: *"the server is always the referee"*, all games online-only and server-authoritative | Voiid Run is **client-simulated** with a server-issued seed and server-side score validation | A single-player 60 fps runner has no opponent to protect and no state another player depends on. Server authority there buys nothing and costs a round-trip of input latency in a game made of frame-perfect reactions. Argued as a deliberate, scoped exception in [`VOIID_RUN.md`](./VOIID_RUN.md) §3, not an oversight |
| [`GAMES.md`](../../GAMES.md) §4: no new third-party dependencies | Chess **should** use a known move-generation library, server-side only | That section's argument is about client binary size, a second build toolchain, and breaking the SwiftUI/Compose parity workflow. None of it applies to a Node dependency in `backend/games`. Hand-rolling chess move generation is where correctness bugs live — castling through check, en passant discovered pins — and a library with a perft suite has already paid for them. See [`CHESS.md`](./CHESS.md) §4.1 |
| [`GAMES.md`](../../GAMES.md) §4: Air Hockey, Ping Pong, Pool at "server tick ~20-30/sec" | Air Hockey at **30 Hz broadcast over a 240 Hz fixed physics step** | The table's rate is the *broadcast* rate and it is right. It does not say anything about integration rate, and integrating at 30 Hz would tunnel a 900 u/s puck straight through a paddle — the same swept-collision problem [`geometry.ts:8-13`](../../../backend/games/src/engine/snake/geometry.ts#L8-L13) already documents for Snake |
| [`GAMES.md`](../../GAMES.md) §8 build order: turn-based games, then aim games, then continuous | Air Hockey moves to second | It is the most immediately fun thing on the list, matches are 90 seconds, and the tick machinery it needs already exists — the cost that put it last has already been paid by Snake |
| [`NEW_GAME_IDEAS.md`](../NEW_GAME_IDEAS.md) tiering | Agrees throughout | Sea Battle low-risk and first among these, Chess honest about the solved market, Ludo and Cards gated on lobby work. This folder is the detailed version of that ranking, not a revision of it |

---

# 5. The complete open-questions list

Collected from all eight docs, deduplicated. Everything here needs a decision that is not ours to make.

**Blocking — a game cannot be built until these are answered**

1. **Is async play in scope?** (§2.2) If turn-based matches are expected to live for days, the durable-state table and a "your turn" notification are both required. If matches are expected to be single-sitting only, Sea Battle and Chess lose most of their argument and should be re-evaluated. Everything in this folder assumes yes.
2. **What carries a "your turn" push?** The invite rides the E2EE message pipe and gets wake and push for free ([`GAMES.md`](../../GAMES.md) §3). A turn notification has no such carrier — it is not a message, and it needs to fire when the app is closed. New push type, or a system message in the arranging thread?
3. **Build Chess at all?** ([`CHESS.md`](./CHESS.md) §15) We recommend deferring until head-to-head records prove the social hook.
4. **Build Voiid Run at all, and with what rendering budget?** ([`VOIID_RUN.md`](./VOIID_RUN.md) §15) We recommend yes-but-conditional, three-lane rather than free movement.

**Design decisions with real consequences**

5. **Sea Battle: are sunk-ship announcements on or off?** ([`SEA_BATTLE.md`](./SEA_BATTLE.md) §15) We recommend on — it is what makes the endgame deduction rather than grind.
6. **Ludo: two, three or four seats at launch, and is a 2-player Ludo worth shipping first** to avoid blocking on lobby work? ([`LUDO.md`](./LUDO.md) §15)
7. **Voiid Cards: how close to UNO?** ([`VOIID_CARDS.md`](./VOIID_CARDS.md) §15) The rules are not copyrightable but the name, the card faces and the trade dress are. A licensing/brand review before art is drawn, not after.
8. **Air Hockey: first-to-7 or 90-second clock?** ([`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §15) We recommend the clock — it bounds the match, which matters when the match is happening inside a chat.
9. **Voiid Run: is there a revive, and does anything cost money?** ([`VOIID_RUN.md`](./VOIID_RUN.md) §15) The runner genre's economics assume monetisation and this app has none. Recommend one free revive per run and nothing purchasable.
10. **Do bots count for progression?** Cross-cutting. `BotScoreStore` keeps bot scores client-side today; if bot wins feed head-to-head or a global leaderboard, both become meaningless.

**Smaller, but decide before building**

11. The options bag is typed `[String: Int]` on both clients ([`GamesAPI.swift:37`](../../../apps/ios/Voiid/Voiid/Networking/GamesAPI.swift#L37)) and Snake had to smuggle its skin string alongside it as a separate field ([`games.ts:110-113`](../../../backend/api/src/routes/games.ts#L110-L113)). **Four** games here want a string option — Voiid Run's mode, Voiid Cards' match format, Ludo's board variant, Snake's existing skin. Widen the type once, or keep adding sibling fields?
12. Spectating. Every doc assumes a spectator receives `serialize()` and never `serializeForPlayer()`, which makes leaks structurally impossible — but no spectator seat exists yet ([`SNAKE.md`](../SNAKE.md) §4, item 10). Ludo and Chess are the cheapest games to prove it on: both have completely public state, so a spectator seat is already correct there.
13. Reduce-motion. [`CROSS_CUTTING.md`](../CROSS_CUTTING.md) §13 flags that hitstop and shake shipped with no opt-out. Every §9 in this folder specifies motion; all of it needs the switch that does not exist yet. **Voiid Run and Air Hockey should not ship without it.**

**Surfaced while writing the eight docs**

14. **Widen `tick()` to `tick(dtMs)`?** (§2.5) One backwards-compatible line in the runtime — every existing engine ignores the argument. Without it a physics match runs measurably *slow* rather than late under load. Recommend shipping it with [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §4.6.
15. **Extract a shared client netcode module — jitter buffer and render clock — and migrate Snake onto it?** ([`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §6.1) Real work with no visible feature; the payoff is that [`SNAKE.md`](../SNAKE.md) §2's stutter fix has one home per platform instead of four. Touches shipped Snake code, so it needs a call.
16. **Score direction on the leaderboard.** [`SEA_BATTLE.md`](./SEA_BATTLE.md) §2.5: its score is *shots fired*, lower is better, and the global leaderboard sorts descending — so adding it unchanged would put the worst player on top. Add a direction column, or keep Sea Battle off the global board (recommended). Related: [`CHESS.md`](./CHESS.md) §4.3 — a chess draw is 0.5 and `game_match_results.score` is an integer; store doubled and halve at display, or it rounds away.
17. **Who makes the art, and when does it start?** ([`VOIID_RUN.md`](./VOIID_RUN.md) §6.5, [`VOIID_CARDS.md`](./VOIID_CARDS.md) §1.3, [`CHESS.md`](./CHESS.md) §6.2) Three games carry external asset dependencies with real lead times — a runner character with five animation states, an original card deck that survives a trade-dress review, and a chess set that is not CC-BY-SA. Each needs commissioning before its build phase, not after.
18. **Default match lengths.** Three docs deliberately shorten a game people think they know, to keep a default match under ~20 minutes: [`LUDO.md`](./LUDO.md) §2.7 (2 tokens at 3–4 players, against Ludo's traditional 4), [`VOIID_CARDS.md`](./VOIID_CARDS.md) §2.7 (single round, against point-based), [`AIR_HOCKEY.md`](./AIR_HOCKEY.md) §2.5 (90-second clock, against first-to-7). Each is argued in place, and each is the most player-visible departure in its doc.
19. **Snake's 3–6 player mode ships with the multi-seat lobby work** (§2.4), whether or not Ludo follows. It is the cheapest way to debug that lobby — Snake's engine already supports six seats, so it is a pure client change with no new rules. Worth confirming that is wanted, since it changes a shipped game.
