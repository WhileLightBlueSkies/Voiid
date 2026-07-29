# Voiid Games — Architecture & Build Plan

Status: proposal, not yet built. Companion precedents to read first: [`LOCATION.md`](./LOCATION.md) (live-relay pattern) and [`STORIES_PROTOCOL.md`](./STORIES_PROTOCOL.md) (wake-then-fetch pattern) — the games system reuses pieces of both.

This doc covers a "Games" surface added to the app: Snake (`.io`-style live), Ludo, Air Hockey, Ping Pong, Pool, Chess, Archery, Snow Fight, Sea Battle (Battleship), and Voiid Cards (a UNO-like game). It explains **in plain language** how each piece works, why it's built that way given what already exists in this repo, and what stays the same vs. changes per game.

---

## 1. The one decision that shapes everything: online-only, server-authoritative

**All ten games are online multiplayer, and the server is always the referee.**

Here's the reasoning. Two of the games you listed (Snake, Air Hockey) are physics-y and twitchy — if each phone just simulated its own version of the ball/snake and only told the other player "here's where I am now," the two phones would drift out of sync within seconds, and a cheater could just edit their local state to teleport or never die. The other games (Chess, Ludo, Sea Battle, Voiid Cards, Uno) are turn-based, so cheating is even easier to attempt if the client is trusted — a modified client could claim an illegal move happened.

So one rule for all ten: **the server holds the one true copy of game state, applies every rule, and pushes the result to both players.** Phones become "controllers with a screen" — they capture input (taps, drags, swipes) and render whatever the server says is true. This is a bigger lift than peer-to-peer, but it's the only version that is fair, cheat-resistant, and works when players are on different networks/NATs (which peer-to-peer WebRTC data channels handle badly without a relay anyway — and you already avoid WebRTC data channels entirely for anything besides calls).

There is no offline/local-pass-and-play mode in this plan. If you want a "play a bot" or "practice offline" mode later, that's a separate, much simpler addition (same rendering code, a local rules engine instead of a network call) — worth doing, but not part of this doc's scope unless you ask for it.

---

## 2. Where this lives in the existing system, and why

Your backend is already split into small, independently-deployable Node services under `backend/` — `api` (REST), `websocket` (the `ws` + Redis relay), `workers` (background jobs). I'm proposing a **fourth service, `backend/games`**, rather than bolting game logic onto the existing `api` or `websocket` packages. Reasoning:

- **`websocket` is deliberately a dumb pipe today.** Its whole design (per `LOCATION.md`) is "the WS process has no database, authorization lives in REST." Game logic needs to validate moves against real rules and state every tick/turn — that's business logic, not relay logic. Cramming it into the relay would break the one architectural rule that service currently follows.
- **A crashing or slow game simulation must never take down messaging.** Messaging is the core product; games are a new, higher-risk, higher-churn surface (new rules, new bugs, more frequent iteration). Keeping it a separate pm2 process on the same box (or its own box later, exactly like how LiveKit already got split onto "Box B" so calls can't degrade the API) means a bad Snake update can be restarted or rolled back without touching chat.
- **It still rides the existing WebSocket relay for transport**, it doesn't open a second socket. The relay already fans messages out via `channel:user:<id>` in Redis; a game server just publishes to that same channel to push state to a player, exactly the way the API does today for message/story wake signals. This means no new client-side connection code, no new reconnect/backoff logic (you already have a battle-tested one on both iOS and Android) — new game frame types are just new `case`s in the same `switch` that already handles `loc_update`, `call_offer`, etc.

So the shape is:

```
Phone (iOS/Android)
   │  existing WebSocketClient (already open for chat/calls/location)
   ▼
backend/websocket  (unchanged relay, +2 new frame types: game_input, game_state)
   │  Redis pub/sub channel:user:<id>  (unchanged mechanism)
   ▼
backend/games  (NEW — owns match state, runs rules, ticks physics, validates moves)
   │  reads/writes
   ▼
Redis  (live match state — fast, ephemeral)      Postgres  (match history, ELO/stats, card/board config)
```

Why state lives in **Redis, not Postgres**, while a game is in progress: a live Snake match might update 10-20 times a second; a chess game updates every few seconds. Postgres is the durable source of truth for your users/messages, but hammering it every tick for a game that only lasts 2 minutes and then disappears is the wrong tool. Redis already holds your ephemeral/live-only data (presence, typing, the `loc:last:*` buffers) — a live match is the same shape of problem: fast, short-lived, doesn't need to survive a server restart perfectly. When a match **ends**, the games service writes one row to Postgres (final score, players, duration, winner) for history/stats/leaderboards — that's the only part that needs to be durable.

### New database tables (Postgres, via a new migration `020_games.sql`)

- `games` — static catalog: id, name, slug, min/max players, category (arcade / board / card), icon asset key. Seeded once, rarely changes.
- `game_matches` — id, game_id, player ids (jsonb array, supports 2+ for Ludo/cards), status (`waiting`/`active`/`finished`/`abandoned`), started_at, ended_at, winner_id.
- `game_match_results` — per-player row: match_id, user_id, score, placement, rating_delta (if you want ranked play later).
- `game_ratings` — optional, per-user-per-game ELO-style rating, only needed if you want ranked matchmaking rather than just "invite a friend."

Nothing here needs to be end-to-end encrypted the way chat is — game moves aren't private content in the same sense, and the server must read them anyway to referee. This is a deliberate, explicit exception to the app's "server never sees plaintext" rule for messaging, scoped only to game state. Worth stating plainly in the doc so nobody mistakes it for a precedent to weaken E2EE elsewhere.

---

## 3. Matchmaking & invites — reusing what you have, not building a lobby system from scratch

You already have a social graph (contacts, conversations) and a working notification path (WS wake + APNs/FCM push for offline users, per the calls/stories pattern). Reuse it:

- **"Play with a friend"** — from any chat conversation, a new message type `game_invite` (rides the *existing* E2EE message pipe, same as a text or media message, since an invite itself is just "hey, want to play chess" — no game state in it). Tapping it opens the game screen and creates a `game_matches` row in `waiting` state. This is exactly the same wake-then-fetch shape Stories uses: the invite is a lightweight signal, the actual match session is fetched/joined via a REST call (`POST /v1/games/matches/:id/join`) the moment the recipient taps in.
- **"Quick match" / public matchmaking** (optional, phase 2) — a simple Redis-backed queue per game (`queue:snake`, `queue:chess`), matched FIFO or by rating bucket if you add ELO. This is intentionally the *last* thing to build — invite-a-friend covers the "play with people I know" case that fits Voiid's private/social-first identity, and matchmaking-with-strangers is a much bigger moderation/safety surface (see §7).

---

## 4. Client side: one native rendering approach per platform, no game engine dependency

Neither app has any canvas/game code today — this is greenfield on both. Given that, and given this codebase's consistent pattern of "stay native, avoid heavy third-party deps unless there's no alternative" (SPM-vendored WebRTC/Firebase, hand-rolled WebSocket client instead of Socket.io, raw OkHttp instead of Retrofit), I'd resist pulling in Unity/Unreal/Godot or a JS game engine wrapped in a WebView. That would mean: a second build toolchain, a huge binary size increase, and an escape hatch out of SwiftUI/Compose that breaks the "iOS is the reference, Android must match it" parity workflow you already run (`docs/ANDROID_IOS_PARITY.md`). For the specific games on your list — none of which need 3D, physics engines, or particle systems beyond what you can hand-roll — native 2D rendering is enough and keeps everything consistent with how the rest of the app is built.

- **iOS:** SwiftUI `Canvas` + `TimelineView(.animation)` for anything that redraws every frame (Snake, Air Hockey, Ping Pong, Pool, Archery, Snow Fight, Sea Battle's animations). `Canvas` gives you immediate-mode 2D drawing (paths, images, gradients) inside ordinary SwiftUI, so it composes with your existing `DesignSystem/` tokens and view hierarchy instead of living in a separate rendering island. For static/turn-based boards (Chess, Ludo, Voiid Cards, Sea Battle's grid-placement phase), plain SwiftUI views (a `Grid`/`LazyVGrid` of tappable cells) are enough — no need for `Canvas` there at all.
- **Android:** Jetpack Compose `Canvas` + `withFrameNanos` (or `rememberInfiniteTransition` for simpler loops) as the direct equivalent. Same split: `Canvas` for the physics/arcade games, plain composables (`LazyVerticalGrid`, `Box` grids) for the board/card games.
- **A shared `GamesEngine` client module per platform** (`Networking/GamesEngine.swift`, `net/GamesEngine.kt`) — mirrors the existing `LocationShareEngine`/`MapPresenceEngine` pattern: owns the WS subscription for game frames, exposes the current match state as an observable (`@Published`/`StateFlow`), and turns local input events into `game_input` frames sent over the existing `WebSocketClient`. Each game screen is a dumb renderer of whatever state this engine currently holds, plus input handlers that call into it — this keeps all ten games structurally consistent and means a new game is "add a renderer + a server-side rules module," not "reinvent networking."

### Update rates — not every game needs 60fps over the network

This matters for both server cost and battery/bandwidth on the client, so it's worth deciding per game up front rather than defaulting everything to "stream everything constantly":

| Game | Network pattern | Why |
|---|---|---|
| Snake (`.io` style) | Server tick ~10-15/sec, broadcasts full board diff to all players in the match | Continuous, all-players-see-all-players, matches the genre |
| Air Hockey, Ping Pong, Pool | Server tick ~20-30/sec for ball physics, client-side interpolation between ticks for smoothness | Fast but only 2 players, physics must be authoritative to prevent phasing/cheating |
| Archery, Snow Fight | Event-driven (send a "shot fired" with angle/power, server resolves trajectory and broadcasts result) rather than continuous streaming | These are aim-and-release actions, not continuous motion — no need to stream every frame of a bow draw |
| Chess, Ludo, Sea Battle, Voiid Cards | Pure turn-based: one `game_input` per move, one `game_state` broadcast in response | Lowest bandwidth of all; this is identical in shape to how `typing`/`receipt` frames already work today |

This table is the main thing that differs game-to-game — everything else (transport, auth, matchmaking, storage) is shared infrastructure.

---

## 5. Server side: one process, per-game "rules modules," not ten separate services

`backend/games` runs as a single Node/TypeScript pm2 process (same deploy shape as `api`/`websocket`/`workers` — `npm run build`, `pm2 start`, added to the existing dev/prod deploy scripts). Internally it's organized as one small "rules module" per game behind a common interface, e.g.:

```
backend/games/src/
  index.ts              — subscribes to Redis, routes game_input frames to the right match's rules module
  matchmaking.ts         — invite/join/queue logic, writes game_matches rows
  engine/
    GameEngine.ts         — shared interface: init(players), applyInput(playerId, input), tick(), serialize()
    snake/                — Snake-specific board logic, collision, growth
    airhockey/, pingpong/, pool/  — shared simple 2D physics helper (velocity/friction/collision) + per-game config
    chess/                 — move validation (a small well-known chess-rules package, e.g. chess.js-equivalent logic ported/used server-side)
    ludo/, seabattle/, cards/, archery/, snowfight/  — one folder each, same interface
```

Games with continuous motion (Snake, Air Hockey, Ping Pong, Pool) run on a `setInterval` tick loop per active match that calls `engine.tick()` and broadcasts the new state. Turn-based games (Chess, Ludo, Sea Battle, Voiid Cards) are purely reactive — no loop, just `applyInput` → validate → broadcast on each incoming move. This keeps CPU cost proportional to how many *arcade* matches are live, not how many matches exist total.

A match's live state is a single Redis key (`match:<id>:state`, JSON, short TTL refreshed on every tick/move) — if the games process restarts, in-progress arcade matches are lost (acceptable — same tradeoff the app already accepts for live location fixes) but turn-based matches can be safely resumed from the last-persisted-to-Postgres move if you want that durability later, since each move is cheap enough to also log.

---

## 6. New WebSocket frame types (additions to `backend/websocket/src/index.ts`)

Only two new frame shapes needed, deliberately kept generic so all ten games reuse them instead of each getting bespoke frame types (same philosophy as `loc_update` being generic over "any live position stream"):

- `game_input` (client → server): `{type: 'game_input', match_id, payload}` — `payload` is opaque to the relay (exactly like location's ciphertext is opaque to it), interpreted only by the matching rules module in `backend/games`. Rate-limited per match per socket, same token-bucket pattern as `loc_update` (12-30/60s depending on game, configurable per game type).
- `game_state` (server → client): `{type: 'game_state', match_id, seq, payload}` — broadcast to all players in the match via the existing `channel:user:<id>` Redis fan-out, one publish per recipient (mirrors how location shares fan out to an audience). `seq` is a monotonically increasing counter per match so a client that receives frames out of order (possible over UDP-like best-effort delivery, though WS over TCP makes this rare) can discard stale ones — same defensive posture as the existing offline-buffer/flush pattern.

The relay itself doesn't change its trust model: it still doesn't understand game rules, it just routes `game_input` to `backend/games` (via a Redis channel the games service subscribes to, `channel:games:input`) and routes `game_state` back out to players — structurally identical to how it already relays location and call-signaling payloads without understanding them.

---

## 7. What's genuinely new risk here (worth deciding consciously, not defaulting into)

- **This is the first backend surface that reads plaintext game state by design.** Explicitly scope that exception (§2) so it's a documented decision, not scope creep into the E2EE guarantee.
- **Public matchmaking with strangers** means two Voiid accounts that don't know each other end up in a live session together — a moderation/reporting surface you don't currently need for a friends-and-contacts-first messaging app. Recommend shipping invite-only first (§3) and treating public matchmaking as an explicit later decision, not a default.
- **Abandonment/AFK handling** — turn-based games need a per-match timeout (e.g., 60s to move or forfeit) and arcade games need a disconnect grace period (reuse the existing reconnect-with-outbound-queue pattern already in `WebSocketClient`/`WebSocketClient.kt`) before declaring a player forfeited.

---

## 8. Build order (smallest end-to-end slice first)

Recommended sequence, each step shippable and testable on its own:

1. **Plumbing only, no real game**: add the `games` tab (6th case in the existing `RootTabView` enum, both platforms — per the Explore agent's finding, this enum is deliberately structured to make a new tab a single compile-checked change), stand up `backend/games` with just health-check + the two new WS frame types wired end-to-end, and ship one trivial game to prove the pipe works — **Sea Battle (Battleship)** is the best first pick: purely turn-based, simple grid state, no physics, exercises invite → match → move → state-broadcast → win-condition end to end.
2. **Turn-based games next** (share the most infrastructure, least risk): Voiid Cards, Ludo, Chess — each is "new rules module + new renderer," no new transport work.
3. **Event-driven aim games**: Archery, Snow Fight — introduce trajectory resolution but still not continuous-tick.
4. **Continuous-tick arcade games last** (highest infra cost — tick loops, interpolation, physics tuning): Air Hockey, Ping Pong, Pool, Snake. Snake specifically (`.io`-style, implying possibly >2 players free-for-all in one board) is the most complex of the ten — good candidate for last.

---

## 9. Summary table

| Layer | Choice | Reuses |
|---|---|---|
| Multiplayer model | Online-only, server-authoritative | — |
| Transport | Existing `backend/websocket` relay, 2 new frame types (`game_input`/`game_state`) | Identical mechanism to `loc_update`/`call_offer` |
| Game logic host | New `backend/games` pm2 service | Same deploy shape as `api`/`workers` |
| Live match state | Redis, ephemeral, TTL-refreshed | Same as presence/typing/`loc:last:*` |
| Match history/stats | New Postgres tables (`020_games.sql`) | Same migration system as everything else |
| Invites | New `game_invite` message type over existing E2EE chat pipe | Same as any message |
| iOS rendering | SwiftUI `Canvas`/`TimelineView` (arcade) + plain views (board/card) | No new dependency |
| Android rendering | Compose `Canvas` (arcade) + plain composables (board/card) | No new dependency |
| Client networking | New `GamesEngine` per platform, rides existing `WebSocketClient`/`WebSocketClient.kt` | Same reconnect/backoff/outbound-queue already built |
| New tab | 6th case in existing `RootTabView` enum | Explicitly designed to be low-friction |
