# Voiid Games — Full Audit

> **Date:** 2026-08-07
> **Scope:** every game, every screen, every platform. What exists, what is missing, what is broken, and what to build next.
> **Companion docs:** [`GAMES.md`](./GAMES.md) (original architecture plan), [`GAMES_HAND_CRICKET.md`](./GAMES_HAND_CRICKET.md), [`snake-play.md`](../snake-play.md) (Snake design bible), [`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) (P0 control bug + P1 flicker), [`GAMES_AUDIO.md`](./GAMES_AUDIO.md) (sound design + audio engine), [`GAMES_ANIMATION.md`](./GAMES_ANIMATION.md) (animation bible).

---

## Table of contents

1. [Executive summary](#1-executive-summary)
2. [What is actually built](#2-what-is-actually-built)
3. [Spec vs build — the delta](#3-spec-vs-build--the-delta)
4. [Missing screens](#4-missing-screens)
5. [Missing features](#5-missing-features)
6. [Platform parity gaps](#6-platform-parity-gaps)
7. [Bugs and correctness issues found](#7-bugs-and-correctness-issues-found)
8. [The flow problem — and the flow that replaces it](#8-the-flow-problem--and-the-flow-that-replaces-it)
9. [Animation: making it feel out-of-this-world](#9-animation-making-it-feel-out-of-this-world)
10. [Prioritised build order](#10-prioritised-build-order)

---

# 1. Executive summary

Voiid ships **four games** — Tic Tac Toe, Rock Paper Scissors, Hand Cricket, Snake — against an architecture plan that scoped **ten**. The infrastructure underneath them is genuinely good: server-authoritative, one rules module per game, a shared client engine per platform, and a clean `GameEngine` interface that makes adding a game "one folder plus one renderer." That foundation is not the problem.

The problem is everything *around* the games:

- **Snake is unplayable.** A single stale constant in the WebSocket relay throttles game input to 2 frames/second, freezing the controls ~10 seconds into every match on both platforms. Full diagnosis in [`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md).
- **There is no meta-game.** No match history screen (the API exists and is unused), no stats, no rematch, no achievements, no progression. You play a match, it ends, and nothing about it persists in the UI.
- **There is no sound. At all.** Zero audio across all four games on both platforms. This is the single largest gap between "a tech demo" and "a game."
- **Android has no haptics in games.** iOS has 20 call sites. Android has zero.
- **Snake's renderer is not the same game on the two platforms.** iOS draws it on the GPU with a Metal shader; Android draws it with Compose `Canvas`. They will never look alike until this is addressed.
- **Snake's multiplayer is unreachable.** The catalog says up to 6 players. The UI can only ever pick one opponent, and the friend-invite path passes no bots — so "play Snake with a friend" is two lonely snakes in an arena built for eight.
- **The flow to start a game with a friend is 6+ taps and depends on the opponent opening a chat.**

---

# 2. What is actually built

## 2.1 The four games

| Game | Slug | Category | Players | Online | Vs bot | Bot location | Tick |
|---|---|---|---|---|---|---|---|
| Tic Tac Toe | `tictactoe` | board | 2 | ✅ | ✅ | on-device | turn-based |
| Rock Paper Scissors | `rps` | board | 2 | ✅ | ✅ | on-device | turn-based |
| Hand Cricket | `cricket` | board | 2 | ✅ | ✅ | on-device | turn-based |
| Snake | `snake` | arcade | 1-6 | ⚠️ (see §5.1) | ✅ | **server-side** | 10 Hz |

Seeded in [`024_games.sql`](../database/migrations/024_games.sql), [`025_games_hand_cricket.sql`](../database/migrations/025_games_hand_cricket.sql), [`026_games_snake.sql`](../database/migrations/026_games_snake.sql).

## 2.2 Backend

```
backend/games/src/
  index.ts              420 loc  — Redis subscriber, tick loops, match lifecycle
  matches.ts            117 loc  — Redis live-match records
  tournaments.ts        344 loc  — bracket advancement, forfeits
  db.ts, redis.ts
  engine/
    GameEngine.ts       123 loc  — the shared interface
    registry.ts          16 loc  — slug → factory
    tictactoe/          158 loc
    rps/                179 loc
    cricket/            281 loc
    snake/              915 loc + geometry (212) + bot (185) + tests (346)
```

**API routes** ([`backend/api/src/routes/games.ts`](../backend/api/src/routes/games.ts)):

| Route | Purpose | Client uses it? |
|---|---|---|
| `GET /games` | catalog | ✅ |
| `POST /games/matches` | create match | ✅ |
| `POST /games/matches/:id/join` | join | ✅ |
| `POST /games/matches/:id/decline` | decline invite | ✅ |
| `GET /games/invites` | pending invites | ✅ (20 s poll) |
| `GET /games/leaderboard` | standings | ✅ |
| **`GET /games/matches`** | **match history** | ❌ **never called on either platform** |

## 2.3 Client screens that exist

| Screen | iOS | Android |
|---|---|---|
| Games home (catalog grid) | `GamesHomeView.swift` | `GamesHomeScreen.kt` |
| Game setup sheet (friend/bot + difficulty) | `GameSetupSheet.swift` | `GameSetupSheet.kt` |
| Opponent picker | `OpponentPickerSheet.swift` | `OpponentPickerSheet.kt` |
| Overs picker (cricket) | `OversSheet.swift` | `OversSheet.kt` |
| Lobby / waiting for opponent | `GameLobbyView.swift` | `GameLobbyScreen.kt` |
| Leaderboard | `LeaderboardView.swift` | `LeaderboardScreen.kt` |
| Invite banner | `InviteBanner.swift` | `InviteBanners.kt` |
| Tic Tac Toe — online | `TicTacToeView.swift` | `TicTacToeScreen.kt` |
| Tic Tac Toe — bot | `TicTacToeBotView.swift` | `TicTacToeBotScreen.kt` |
| RPS — online | `RpsMatchView.swift` | `RpsMatchScreen.kt` |
| RPS — bot | `RpsBotView.swift` | `RpsBotScreen.kt` |
| Cricket — online | `CricketMatchView.swift` | `CricketMatchScreen.kt` |
| Cricket — bot | `CricketBotView.swift` | `CricketBotScreen.kt` |
| Snake — arena | `SnakeArenaView` + **`SnakeMetalView` + `Snake.metal`** | `SnakeArenaScreen.kt` (Compose Canvas) |

**~13,600 lines of game code total.** The bones are there. The flesh is not.

---

# 3. Spec vs build — the delta

## 3.1 Against `GAMES.md` (the architecture plan)

Ten games were scoped. **Four shipped. Six were never started:**

| Game | Category | Status | Effort |
|---|---|---|---|
| Chess | board | ❌ not started | high (move validation, check/mate, castling, en passant, promotion) |
| Ludo | board | ❌ not started | medium (4-player state, dice, capture, home run) |
| Sea Battle / Battleship | board | ❌ not started | **low — was the recommended first game in §8** |
| Voiid Cards (UNO-like) | card | ❌ not started | medium-high (deck state, hidden hands, 2-6 players) |
| Air Hockey | arcade | ❌ not started | medium (inherits Snake's tick machinery, +2D physics) |
| Ping Pong | arcade | ❌ not started | medium (same physics helper as above) |
| Pool | arcade | ❌ not started | high (multi-ball physics, spin, pocket detection) |
| Archery | event | ❌ not started | low-medium (event-driven, no tick loop) |
| Snow Fight | event | ❌ not started | low-medium (same shape as Archery) |

Also unbuilt from the plan:

- **Quick match / public matchmaking** (§3, phase 2) — no Redis queue, no rating buckets.
- **`game_ratings` table** (§2) — no ELO, no ranked play.
- **AFK / abandonment handling** (§7) — no per-match move timeout for turn-based games, no disconnect grace period for arcade games. A player who walks away from a Tic Tac Toe match leaves it hanging forever.
- **`rating_delta` on `game_match_results`** — column planned, never used.

## 3.2 Against `snake-play.md` (the Snake design bible)

This 2,397-line document specifies a substantially more ambitious game than the one that shipped. Notable gaps:

| Spec section | Specified | Built |
|---|---|---|
| §1 | Up to **25 snakes** per match | 6 max (bandwidth ceiling, documented and deliberate) |
| §5 | Multiple game modes | one mode |
| §6 | Private invite-only **rooms**, auto-filled with bots | 1:1 invite only, bots only in solo |
| §7 | Arena variety | one circle, one radius, always |
| §10 | Boost system with full tuning | ✅ built |
| §16 | **Animation bible** | mostly unbuilt (see §9) |
| §17 | **Particle & VFX catalogue** | events (`death`/`kill`/`eat`/`spawn`) are emitted by the server and largely unrendered |
| §18 | **Sound design** | ❌ **nothing** |
| §19 | UI layout & HUD | partial — leaderboard + clock only |
| §23 | Progression, cosmetics, skins, trails, death effects | ❌ nothing |
| §24 | Statistics & leaderboards | leaderboard only, no per-player stats |

The server already emits exactly the events a VFX layer needs — `{k: 'death'|'kill'|'eat'|'spawn', x, y, id, c}` ([`snake/index.ts:164-165`](../backend/games/src/engine/snake/index.ts#L164-L165)) — and the clients parse them into `SnakeState.events`. **On Android they are not even parsed** (`parseSnake` drops the field entirely). This is the cheapest available win in the entire codebase: the data is already on the wire.

---

# 4. Missing screens

Ordered by how much each one is missed.

### 4.1 Match history — **backend already built, zero UI**
`GET /games/matches` returns id, slug, name, status, player ids and winner. Neither `GamesAPI.swift` nor `GamesService.kt` has a method for it. A player has no way to see a single match they have ever played.

### 4.2 Player profile / per-game stats
Wins, losses, streaks, best Snake length, favourite game, head-to-head record against each friend. `game_match_results` holds score and placement per player and is written on every match end — the data exists and is queried by nothing but the global leaderboard.

### 4.3 Post-match summary
Currently: `"You finished with 47"`. That is the entire post-match experience for Snake. Missing: final placement, kills, deaths, longest life, largest snake, food eaten, an XP/progress line, and — critically — **a Rematch button that works online**.

### 4.4 Rematch (online)
Snake's Restart mints a fresh *solo* match ([`GamesHomeView.swift:171-178`](../apps/ios/Voiid/Voiid/Games/GamesHomeView.swift#L171-L178)). Tic Tac Toe, RPS and Cricket have no online rematch at all — you must go back to the Games tab, pick the game, pick the friend, and send a whole new invite. This is the single most-wanted missing button in any casual multiplayer game.

### 4.5 How to play / rules
No game explains itself. Hand Cricket in particular is opaque to anyone who has not played it before — a "same number = wicket" rule with no on-screen explanation.

### 4.6 Multi-opponent picker (Snake 3-6 players)
`POST /games/matches` accepts `opponent_ids` as an **array**, and both client wrappers pass an array — but `OpponentPickerSheet` returns exactly one conversation, so the array always has length 1. Snake's `max_players: 6` is dead configuration.

### 4.7 Game settings
No per-game settings screen anywhere. Missing: sound on/off, haptics on/off, Snake control scheme (fixed joystick / floating joystick / follow-finger), left- or right-handed layout, graphics quality on low-end Android.

### 4.8 Spectate
Watch a friend's live match. The state is already broadcast to every player in `m.players`; a read-only seat is a small extension.

### 4.9 Tournaments inside the Games tab
`backend/games/src/tournaments.ts` (344 loc) implements bracket advancement and forfeits, and `031_tournaments.sql` exists — but the entire tournament UI lives under **Communities** (`CommunityTournamentsSection`), not Games. There is no path from the Games tab to a tournament, and no bracket view.

### 4.10 Reconnect / resync state
No "Reconnecting…" state on any game screen. If the socket drops mid-Snake-match, the arena simply freezes with no explanation.

### 4.11 Empty and error states
`joinError` is the only error surface, and it is a single string. No retry affordance, no offline state, no "this match has ended" screen.

---

# 5. Missing features

### 5.1 Snake multiplayer is effectively broken by omission
`startMatch` ([`GamesHomeView.swift:296-322`](../apps/ios/Voiid/Voiid/Games/GamesHomeView.swift#L296-L322)) passes `options` through, but the Snake friend-path passes **no `bots` key**. Only the solo path sets it. So an online Snake match is 2 human snakes in a radius-1400 arena sized for 8, with 260 food pellets and nothing to hunt. The engine already supports filling empty seats with bots (`options.bots`, clamped 0-12) — nothing calls it.

**Fix:** default `bots` to `max(0, 6 - humanCount)` on the friend path. One line, and it turns a dead mode into the mode `snake-play.md` §6 actually specifies.

### 5.2 No audio, anywhere
Zero `AVAudioPlayer` / `SoundPool` / `MediaPlayer` references across all game files on both platforms. No move sounds, no win/lose stingers, no Snake eat/boost/death audio, no ambience, no music. `snake-play.md` §18 specifies a full sound design and none of it exists.

### 5.3 Haptics: iOS only
20 `Haptics.*` call sites in iOS games. **Zero** in Android games. Android has `HapticFeedbackConstants` and `VibratorManager` available and unused.

### 5.4 No progression of any kind
No XP, no levels, no unlocks, no daily challenges, no achievements, no cosmetics. `snake-play.md` §23 specifies skins, trails and death effects with cosmetic-only monetisation.

### 5.5 No AFK / abandonment handling
Planned in [`GAMES.md` §7](./GAMES.md) and never built. A turn-based match with an absent opponent hangs forever; an arcade match with a disconnected player keeps ticking with a ghost.

### 5.6 Invite latency is a 20-second poll
`GamesHomeView` polls `api.invites()` every 20 s. The invite itself rides the E2EE message pipe (correct — it gets wake and push for free), but the Games *tab* only learns about it on the next poll. A friend invites you and you find out up to 20 seconds later.

### 5.7 Snake events are emitted and thrown away
Server sends `death`/`kill`/`eat`/`spawn` with world coordinates. iOS parses them into `SnakeState.events` and renders little from them. **Android does not parse them at all.** Free VFX, discarded.

### 5.8 No difficulty parity between Snake and the rest
Every other game has a continuous `skill` slider (0-1) plus three named levels. Snake maps difficulty to *bot count* only (3/5/8) — the bots themselves have no skill parameter, and `stepBot` takes none.

### 5.9 No accessibility pass
Colourblind-safe palette (Snake identifies players by colour alone), reduce-motion support, VoiceOver/TalkBack labels on boards, dynamic type in HUDs, and a larger-touch-target option are all absent.

---

# 6. Platform parity gaps

Per [`ANDROID_IOS_PARITY.md`](./ANDROID_IOS_PARITY.md), iOS is the reference. Deltas found:

| Area | iOS | Android | Impact |
|---|---|---|---|
| **Snake renderer** | Metal + `Snake.metal` shader, own display link, `MTKView` | Compose `Canvas`, CPU draw path | **Large.** Different visual ceiling entirely |
| Snake events | parsed into `SnakeState.events` | **not parsed** | Android can't do VFX without a parser change |
| Haptics in games | 20 call sites | **0** | Android games feel inert |
| Bot score persistence | `BotScoreStore.swift` | `BotGameState.kt` (different shape) | worth verifying they agree |
| Tic Tac Toe board | extracted (`TicTacToeBoard.swift`) | inline in screen | maintainability only |

---

# 7. Bugs and correctness issues found

### 7.1 P0 — Snake controls freeze (both platforms)
The relay throttles `game_input` to 2/s. Full diagnosis, trace and fix in [`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) **Part A**. **Read that first.**

### 7.1b P1 — The Snake arena flickers and jerks sideways (both platforms)
The render clock is rebuilt from the newest frame's *arrival time* on every frame, so all network jitter is injected straight back into the picture — and because the camera is rigidly locked to the head with no smoothing, the whole scene snaps ~10 units, 10 times a second, along the direction of travel. Independent of 7.1; fixing the rate limit does not fix this. Full diagnosis in [`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) **Part B**.

Carries four sub-findings worth noting here: iOS never received Android's `CameraMemory` origin guard; respawn teleports are lerped so the camera flies across the arena; iOS stamps frame arrival *after* a main-actor hop; and `snakeFramesSnapshot` is a real data race (`nonisolated(unsafe)`, written on the main actor, read from the display link).

### 7.2 P1 — Steering frames evict chat and call frames from the outbound queue
`sendGameInput` uses `queueIfDown: true`, sharing a 128-slot queue with messages, call offers and ICE candidates, dropping from the front. A Snake match on a flaky connection can silently degrade calls and messaging. Details in the bug doc §4.1.

### 7.3 P1 — Redis write amplification on every steering frame
`handleInput` serializes and persists the entire Snake world on every accepted input — 10-15 full-world writes per second per player, while the tick loop deliberately throttles itself to every 5th tick to avoid exactly that. Bug doc §4.4.

### 7.4 P2 — Both rate-limit maps leak
Neither `gameRate` (relay) nor `inputRate` (games service) is pruned on any path except a clean match end. Bug doc §4.3.

### 7.5 P2 — Snake respawn is starved by the client steering a dead snake
Nothing pauses the steering pacer while the local snake is dead, so the budget is spent on a corpse and the `respawn` frame is the one that gets dropped. Bug doc §4.2 / §3.3.

### 7.6 P3 — Broadcast `seq` is not strictly monotonic
`runTick` loads the match from Redis each tick but only persists every 5th (`PERSIST_EVERY`), so `m.seq` repeats values between persists. Both clients use a non-strict comparison (`seq >= lastSeq` / `if (seq < lastSeq) return`) so nothing breaks today — but the field does not mean what [`GAMES.md` §6](./GAMES.md) says it means ("monotonically increasing counter per match"), and any future code that assumes strict monotonicity will break subtly.

### 7.7 P3 — Snake online has no bots
See §5.1. Not a crash, but it makes the mode not worth playing.

---

# 8. The flow problem — and the flow that replaces it

## 8.1 What it takes to play a friend today

```
Games tab
  └─ tap game card
      └─ GameSetupSheet (modal)
          └─ "Play a friend"
              └─ OpponentPickerSheet (modal) — pick a conversation
                  └─ [cricket only] OversSheet (modal) — pick overs
                      └─ create match + send E2EE invite
                          └─ GameLobbyView — WAIT
                                    ⋮
                          opponent must: open Chats → open that conversation
                                       → find the invite bubble → tap Join
                                    ⋮
                              └─ both players in the match
```

**6+ taps for the inviter, 4+ for the invitee, three stacked modals, and a hard dependency on the invitee opening a specific chat thread.** The Games tab's own invite banner exists, but is up to 20 seconds stale.

## 8.2 What it takes to play a bot

```
Games tab → tap card → GameSetupSheet → "Play a bot" → pick difficulty → play
```

4 taps. Acceptable, but the setup sheet is a modal in front of a decision that could be on the card itself.

## 8.3 The principle to design against

> **A player who opens the Games tab should be in a match within two taps, without making a single decision they don't care about yet.**

Every modal in the current flow asks a question before the player has committed to playing. Difficulty, opponent and overs are all *adjustments*, and adjustments belong **after** the default, not before it.

## 8.4 Proposed flow

### Games home — one screen, three zones

```
┌──────────────────────────────────────────────────┐
│  Games                                    🏆 📊   │  ← leaderboard, stats
├──────────────────────────────────────────────────┤
│  ⚡ CONTINUE                                      │
│  ┌────────────────────────────────────────────┐  │
│  │ 🐍 Snake · your turn      Priya    [ PLAY ] │  │  ← live/pending matches
│  │ ⭕ Tic Tac Toe            Arjun    [ PLAY ] │  │     AND invites, one list
│  │ 🏏 Hand Cricket  invited  Sam  [JOIN][✕]   │  │
│  └────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────┤
│  PLAY                                             │
│  ┌───────────┐ ┌───────────┐                     │
│  │    🐍     │ │    ⭕     │                      │
│  │   Snake   │ │ Tic Tac   │   ← ONE TAP = play  │
│  │  ▸ Play   │ │  ▸ Play   │     vs bot, instantly│
│  │  ⋯ more   │ │  ⋯ more   │   ← "more" = friend, │
│  └───────────┘ └───────────┘     difficulty, etc. │
│  ┌───────────┐ ┌───────────┐                     │
│  │    ✊     │ │    🏏     │                      │
│  └───────────┘ └───────────┘                     │
├──────────────────────────────────────────────────┤
│  RECENT                              See all →    │
│  Won vs Priya · Snake · 2h ago                    │
└──────────────────────────────────────────────────┘
```

**Changes that do the work:**

1. **Tapping a card starts a match immediately** against the bot at the player's last-used difficulty (default: moderate). No sheet. One tap from tab to playing.
2. **A "⋯" affordance on each card** opens the existing setup sheet for anyone who wants a friend, a different difficulty, or a longer cricket match. The modal still exists — it is just no longer mandatory.
3. **Continue strip at the top**, merging live matches, your-turn matches and pending invites into one list. This is where a returning player looks first, and today it does not exist.
4. **Invites arrive in real time.** The invite already rides the E2EE message pipe; have `ChatEngine` post the existing `.voiidOpenGameMatch`-style notification into the Games tab on receipt instead of waiting for the 20 s poll.
5. **Recent matches strip** — wire up the `GET /games/matches` endpoint that is already built.

### Inviting a friend — collapse three modals into one

```
┌─────────────────────────────────┐
│  Play Snake with…               │
├─────────────────────────────────┤
│  🤖 A bot          ● ● ○  Med   │  ← difficulty inline, tappable
├─────────────────────────────────┤
│  ◎ Priya                        │  ← multi-select for Snake (up to 5)
│  ◎ Arjun                        │
│  ◎ Sam                          │
├─────────────────────────────────┤
│  Match length     ◀  2 overs  ▶ │  ← only for games that need it
├─────────────────────────────────┤
│         [    Start match    ]   │
└─────────────────────────────────┘
```

One sheet. Difficulty, opponent(s) and per-game options all visible at once, all optional, all defaulted. Multi-select unlocks Snake's `max_players: 6`, which is dead configuration today.

### Post-match — the screen that does not exist

```
┌─────────────────────────────────┐
│         YOU WON                 │
│      ✦ ✦ ✦ ✦ ✦ ✦ ✦             │
│                                 │
│   Length   142   ↑ personal best│
│   Kills      7                  │
│   Rank     1st of 6             │
│                                 │
│  [  REMATCH  ]   [   Exit   ]   │
│         Share result →          │
└─────────────────────────────────┘
```

**Rematch must work for online matches**, not just solo. It is the highest-value missing button in the product.

### Snake in-match HUD

Current: a clock, a top-10 leaderboard, a joystick, a boost pedal. Missing and worth adding:

- **Minimap** — a radius-1400 arena with a camera on your head means you cannot see danger coming. `snake-play.md` §19 specifies one.
- **Kill feed** — the `kill` events are already on the wire.
- **Boost meter** — mass is the boost fuel (`MIN_BOOST_MASS: 12`) and the player cannot see how much they have left.
- **Danger indicator** — a directional edge glow when approaching the lethal border.
- **Live rank badge** — "#3 of 6" near the player's own head.

---

# 9. Animation: making it feel out-of-this-world

> **Superseded in detail by [`GAMES_ANIMATION.md`](./GAMES_ANIMATION.md)**, which covers all four games, the full native capability matrix for both platforms, haptics, performance budgets and accessibility. The canonical motion-timing table now lives there. This section remains as the summary.
>
> Sound is specified separately in [`GAMES_AUDIO.md`](./GAMES_AUDIO.md).

The goal: motion that reads as **alive, weighty and reactive** rather than "shapes moving between server frames." What follows is a concrete technical plan per platform plus a shared motion language, because the fastest way to make two platforms look different is to let each invent its own timings.

## 9.1 The current state, honestly

- **iOS Snake** already does the hard structural thing right: a `MTKView` with its own display link, all mutable render state owned by the renderer class, SwiftUI left doing HUD only ([`SnakeMetalView.swift:1-20`](../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift#L1-L20)). This is the correct architecture and it should not be undone.
- **Android Snake** uses Compose `Canvas` with `withFrameNanos`. Structurally sound (the frame clock is isolated to the draw lambda so the HUD does not recompose at 60 Hz) but it is a CPU draw path with no shader access.
- **The turn-based games** use stock SwiftUI/Compose animations. Fine, but generic.
- **VFX: essentially none.** The server sends death/kill/eat/spawn events and almost nothing is drawn from them.

## 9.2 Principle: separate the three motion layers

Every good arcade renderer keeps these apart. Conflating them is why "more animation" usually means "more mush."

| Layer | Rate | Source of truth | Example |
|---|---|---|---|
| **Simulation** | 10 Hz | server | where the snake actually is |
| **Interpolation** | 60-120 Hz | jitter buffer | smooth motion between server frames |
| **Presentation** | 60-120 Hz | client-only, never authoritative | glow, trails, particles, screen shake, squash |

The presentation layer is where "out of this world" lives, and it is **completely free of correctness risk** — nothing in it can desync a match. That is the licence to be extravagant.

## 9.3 iOS — extend the Metal renderer

`Snake.metal` is 157 lines today. The following are all shader-side and cost close to nothing on an A-series GPU.

**Body rendering — signed distance fields, not polylines.**
Draw the snake as an SDF of capsules rather than stroked line segments. This gives, for free: perfectly round joints, a glow that is a function of distance, an outline at zero extra cost, and smooth blending where segments meet.

```metal
// Capsule SDF — the primitive the whole body should be built from.
float sdCapsule(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}
```

Then layer, in one pass:
- **Core** — full-saturation fill inside `d < 0`.
- **Rim** — `smoothstep` band around `d ≈ 0`, brighter on the head.
- **Bloom** — `exp(-d * k)` falloff outside the body, additively blended. This is what makes neon read as *emitting* light rather than being a bright colour.
- **Scale shimmer** — a low-amplitude sine along the body's arc length, phase-shifted by time, so the body has surface detail while moving.

**Additive bloom pass.** Render bright elements to an offscreen half-res texture, two-pass Gaussian blur, composite additively. This one change does more for "out of this world" than any other single item on this list.

**Particles — one instanced draw call.** A single GPU buffer of ~2000 particles, each `{pos, vel, life, colour, size}`, stepped in a compute shader (or on CPU — at 2000 it does not matter), drawn as instanced quads. Feed it from the events already on the wire:

| Event | Effect |
|---|---|
| `eat` | 6-10 sparks converging into the head, plus a brief head-scale pop |
| `kill` | radial burst in the victim's colour + white flash + strong haptic |
| `death` (yours) | full-screen chromatic aberration pulse, desaturate over 400 ms, slow-mo to 0.3x for 500 ms |
| `spawn` | expanding ring, snake fades in over 250 ms with a shield shimmer during `INVULN` |
| boost | continuous trail emission from the tail, screen-edge speed lines, mild FOV push |

**Camera as a character.** The camera should never be rigidly locked to the head:
- Follow with a critically-damped spring (~120 ms settle), not a hard lock.
- **Look-ahead**: offset toward the heading, scaled by speed — the player sees where they are going.
- **Zoom out** as mass grows (`1.0 → 1.35` across the mass range) so a big snake feels big.
- **Screen shake** on kills and near-misses: 3-6 px, 200 ms, decaying.

**Time as an effect.** Slow-mo on death, a 120 ms hitstop freeze on a kill, and a subtle speed-ramp when boost engages. Nothing communicates impact more cheaply.

## 9.4 Android — close the renderer gap

This is the largest single parity decision in the games surface. Three options, in order of preference:

**Option A — AGSL `RuntimeShader` (API 33+), Compose Canvas fallback below.** *Recommended.*
AGSL is essentially SkSL and takes the same SDF/glow/bloom logic as the Metal shader, so **one shader design serves both platforms**. Compose exposes it via `RuntimeShader` + `ShaderBrush`, so it drops into the existing `Canvas` without restructuring `SnakeArenaScreen.kt`. Devices below API 33 fall back to today's Canvas path with a reduced effect set.

```kotlin
// Same maths as Snake.metal — write it once, port the syntax, keep the constants identical.
val snakeShader = RuntimeShader("""
    uniform float2 uSize;
    uniform float  uTime;
    // ... capsule SDF, core + rim + bloom, identical structure to the MSL
""")
```

**Option B — `GLSurfaceView` / OpenGL ES 3.0 alongside Compose.** Full control, matches the iOS architecture most closely (own render thread, own loop), but it is a second rendering island in the app and a much bigger change to the screen.

**Option C — stay on Compose Canvas and push it.** Cheapest, and there is real headroom left: `BlendMode.Plus` for additive glow, layered translucent strokes to fake bloom, `RenderEffect.createBlurEffect` (API 31+) for a real blur pass, `Path` with `PathMeasure` for smooth bodies. It will not reach the Metal version's ceiling, but it will look markedly better than it does now.

**Whichever is chosen, do these regardless:**
- **Parse the events.** `parseSnake` in `GamesEngine.kt` drops the `events` field entirely — no VFX is possible on Android until it does not.
- **Add haptics.** `HapticFeedbackConstants.CONFIRM` on eat, `VibratorManager` with a custom `VibrationEffect` waveform on kill/death. iOS has 20 call sites; Android has none.
- **Respect the frame budget.** `withFrameNanos` gives the deadline — measure and degrade particle counts on low-end devices rather than dropping frames.

## 9.5 The shared motion language

Write these numbers down once and use them on both platforms. Divergence here is what makes two builds of the same game feel like different products.

| Motion | Curve | Duration | Notes |
|---|---|---|---|
| UI element enter | spring, damping 0.75 | 280 ms | overshoot ~4% |
| UI element exit | ease-in | 160 ms | always faster than enter |
| Button press | spring, damping 0.5 | 90 ms | scale to 0.94 |
| Card → screen | shared-element transform | 350 ms | never a cross-fade |
| Score tick-up | ease-out | 400 ms | count up, never snap |
| Death panel in | ease-out + blur behind | 300 ms | slow-mo runs *underneath* it |
| Camera follow | critically damped spring | ~120 ms settle | never rigid |
| Screen shake | decaying sine | 200 ms | 3-6 px amplitude |
| Hitstop on kill | freeze | 120 ms | then 0.3x for 380 ms |
| Eat pop | spring, damping 0.4 | 180 ms | head scale 1.0 → 1.18 → 1.0 |

**Colour and light rules:**
- Neon on near-black. The existing palette (`SnakeRenderer.palette`) is the right direction — commit to it.
- **Every bright thing emits.** If it is saturated, it gets bloom. This single rule is most of the "out of this world" feel.
- Player colours must be **distinguishable at 20% size and for colourblind players** — pair hue with a shape or pattern cue on the head.
- The arena border should **pulse and brighten as you approach it**. It is lethal and currently silent about that.

**Restraint rules — these matter as much as the effects:**
- Never animate two things competing for the same attention.
- Every effect must be **interruptible** — a player action always wins over a playing animation.
- Honour **reduce-motion**: swap slow-mo and shake for a flash, keep the information, drop the vestibular load.
- **60 fps is the floor, not the target.** An effect that costs frames is a net negative regardless of how it looks in a screenshot.

## 9.6 Where to start

If only three things get done:

1. **Additive bloom pass** (both platforms). Largest visual delta per unit of work.
2. **Wire up the four server events to particles + haptics.** The data is already arriving; Android needs a parser line first.
3. **Camera spring + look-ahead + mass-scaled zoom.** Costs almost nothing and transforms how the game *feels* to steer.

---

# 10. Prioritised build order

### P0 — Snake is broken, fix it
1. Relay rate limit → `VOIID_GAME_WS_RATE=1800` (env change, fixes installed devices immediately)
2. The rest of [`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) Part A §5
3. Stop steering frames evicting chat/call frames from the outbound queue
4. Camera follow spring, then the free-running render clock — [`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) Part B §B4. The spring alone removes most of the visible flicker and is a prerequisite for the camera work in §9.3, so it is worth doing first either way.

### P1 — Make the four games feel like a product
4. Post-match summary + **online Rematch**
5. Match history screen (`GET /games/matches` — already built)
6. Real-time invite delivery into the Games tab (drop the 20 s poll)
7. Snake online: default `bots` to fill empty seats
8. **Sound.** Even a minimal set: tap, win, lose, eat, death, boost
9. Android haptics in games

### P2 — Flow rebuild (§8)
10. One-tap play from the game card; setup sheet becomes optional
11. Continue strip merging live matches + your-turn + invites
12. Single combined setup sheet with multi-select opponents (unlocks Snake 3-6P)
13. How-to-play per game
14. Game settings (sound, haptics, control scheme, handedness)

### P3 — Animation (§9)
15. Additive bloom, both platforms
16. Parse Snake events on Android; particle system on both
17. Camera spring, look-ahead, mass zoom, screen shake, hitstop
18. Android renderer decision: AGSL `RuntimeShader` with Canvas fallback
19. Snake HUD: minimap, kill feed, boost meter, danger indicator

### P4 — Depth and reach
20. AFK / abandonment handling (planned in [`GAMES.md` §7](./GAMES.md), never built)
21. Player profile + per-game stats
22. Progression: XP, unlocks, daily challenges
23. Snake cosmetics: skins, trails, death effects (`snake-play.md` §23)
24. Tournaments surfaced in the Games tab with a bracket view
25. Accessibility pass: colourblind palette, reduce-motion, VoiceOver/TalkBack

### P5 — New games (from [`GAMES.md` §8](./GAMES.md)'s own recommended order)
26. **Sea Battle** — the plan's recommended first game, lowest risk, still unbuilt
27. Chess, Ludo, Voiid Cards
28. Archery, Snow Fight (event-driven, no tick loop)
29. Air Hockey, Ping Pong, Pool (inherit Snake's tick machinery + a shared 2D physics helper)

---

## Appendix — quick reference

| Question | Answer |
|---|---|
| Games shipped / planned | 4 / 10 |
| Total game code | ~13,600 lines |
| Backend routes built but unused by clients | 1 (`GET /games/matches`) |
| Games with sound | 0 |
| Games with Android haptics | 0 |
| Snake max players (config / reachable in UI) | 6 / 2 |
| Screens missing | 11 (§4) |
| P0 bugs | 1 (Snake controls) |
