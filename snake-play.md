# Snake Battle — Game Design Document

> **Version:** 1.0 (Pre-Production Draft)
> **Document Owner:** Game Design
> **Audience:** Full development team — engineering, art, animation, audio, backend, QA, production
> **Status:** Approved for scoping and technical pre-production

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Design Pillars](#2-design-pillars)
3. [Gameplay Loop](#3-gameplay-loop)
4. [Core Rules](#4-core-rules)
5. [Game Modes](#5-game-modes)
6. [Room Management & Flow](#6-room-management--flow)
7. [Arena Design](#7-arena-design)
8. [Snake Systems](#8-snake-systems)
9. [Food Systems](#9-food-systems)
10. [Boost System](#10-boost-system)
11. [Death & Conversion](#11-death--conversion)
12. [Growth, Score & Win Conditions](#12-growth-score--win-conditions)
13. [Controls](#13-controls)
14. [Camera System](#14-camera-system)
15. [AI & Bot Behavior](#15-ai--bot-behavior)
16. [Animation Bible](#16-animation-bible)
17. [Particle & VFX Catalogue](#17-particle--vfx-catalogue)
18. [Sound Design](#18-sound-design)
19. [UI Layout & HUD](#19-ui-layout--hud)
20. [Networking & Synchronization](#20-networking--synchronization)
21. [Technical Architecture & Performance](#21-technical-architecture--performance)
22. [Collision Detection](#22-collision-detection)
23. [Progression, Cosmetics & Meta](#23-progression-cosmetics--meta)
24. [Statistics & Leaderboards](#24-statistics--leaderboards)
25. [Edge Cases](#25-edge-cases)
26. [Developer Notes](#26-developer-notes)
27. [Future Expansion](#27-future-expansion)
28. [Appendix: Tuning Tables](#28-appendix-tuning-tables)

---

# 1. Executive Summary

**Snake Battle** is a real-time, mobile-first competitive arena game for up to **25 simultaneous snakes**. Players control a single snake inside a **finite, deadly-bordered arena**, eating food to grow, boosting to hunt, and forcing opponents into fatal collisions. Matches are short, loud, colorful, and decisive.

The game is played exclusively in **private, invite-only rooms**. There is no public matchmaking. Any unfilled slot in a room is automatically occupied by an **AI bot**, so a match always starts full — a room of 25 with 8 humans plays as 8 humans + 17 bots. A **Solo Mode** lets one player face a chosen number of bots with no networking at all.

| Attribute | Specification |
|---|---|
| Genre | Competitive arena / .io-style survival |
| Platform | iOS, Android (portrait and landscape) |
| Session length | 3–6 minutes |
| Players per match | Up to 25 (humans + bots, always summing to room size) |
| Network model | Server-authoritative, client-predicted |
| Target framerate | Locked 60 FPS on mid-tier devices; 120 FPS opt-in on high refresh |
| Monetization | Cosmetic only (skins, trails, death effects) — no gameplay advantage |
| Art direction | Neon-modern, high-contrast, saturated, readable at small scale |

> [!IMPORTANT]
> **The single most important quality bar for this project is responsiveness.** Every design decision below is subordinate to the rule that input must feel instantaneous. If a feature, animation, or network optimization introduces perceptible input latency, the feature loses.

---

# 2. Design Pillars

Four pillars govern every decision. When two features conflict, resolve the conflict by consulting the pillar order below — earlier pillars win.

### Pillar 1 — Instant Response

Input-to-visual latency must not exceed **one frame of prediction**. The snake head begins turning on the same frame the finger moves. There is no input buffering, no acceleration curve on turn start, no dead frame between touch and reaction.

### Pillar 2 — Fluid Motion

Nothing in Snake Battle snaps, teleports, or pops. The snake is a **continuous spline**, not a chain of grid cells. Food drifts. Borders breathe. The camera glides. Every value that changes over time is interpolated with an easing curve, never assigned directly.

### Pillar 3 — Readable Chaos

Twenty-five snakes on one screen is visual noise unless disciplined. Colors are assigned from a perceptually-separated palette, the player's own snake is always the brightest object in frame, and threat information (a nearby head, an incoming boost) is communicated through motion and light before it is communicated through UI.

### Pillar 4 — Fair Competition

No player starts larger. No purchase grants advantage. Bots follow the same physics and the same collision rules as humans, with no speed bonuses or wall immunity. Difficulty is expressed through **decision quality**, never through cheating.

---

# 3. Gameplay Loop

## 3.1 Macro Loop (Session)

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│   App Launch ──► Main Menu ──► Create or Join Room        │
│                                    │                     │
│                                    ▼                     │
│                            Lobby / Configure             │
│                                    │                     │
│                                    ▼                     │
│                           Countdown ──► MATCH            │
│                                    │                     │
│                                    ▼                     │
│                      Results ──► Rewards ──► XP           │
│                                    │                     │
│                    ┌───────────────┴────────────┐        │
│                    ▼                            ▼        │
│              Rematch (same room)          Return to Menu  │
│                    │                            │        │
│                    └────────────► Main Menu ◄───┘        │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

## 3.2 Micro Loop (Moment-to-Moment)

The 5–15 second cycle the player actually feels:

```
        ┌─────────────────────────────────────────┐
        │                                         │
        ▼                                         │
   ASSESS ──► APPROACH ──► COMMIT ──► RESOLVE ────┘
   (scan)     (position)   (boost)    (eat / kill / die)
```

| Phase | Player Question | Duration | Systems Engaged |
|---|---|---|---|
| **Assess** | Where is safe food? Who is near me? | 1–3 s | Camera zoom, minimap, threat glow |
| **Approach** | Can I reach it before they do? | 2–5 s | Steering, speed, spatial reasoning |
| **Commit** | Is this cut-off worth the mass? | 0.5–2 s | Boost, mass drain, risk |
| **Resolve** | Did I win the exchange? | 0.2–1 s | Collision, death VFX, food burst |

> [!NOTE]
> The **Commit** phase is the emotional core of the game. Boost is the only mechanic that costs the player something to use, which makes it the only mechanic that generates real tension. Tune boost drain carefully — too cheap and every fight is a boost war; too expensive and players never engage.

## 3.3 Arc of a Match

| Time | Phase | Population | Player Experience |
|---|---|---|---|
| 0:00–0:30 | **Scramble** | 25 snakes | Dense, chaotic, safe-ish food everywhere. Early deaths from panic. |
| 0:30–1:30 | **Growth** | ~18–22 | Snakes are long enough to threaten. First real hunting. |
| 1:30–3:00 | **Hunt** | ~8–15 | Massive food piles from deaths. Territory forms. Border kills spike. |
| 3:00–4:30 | **Endgame** | 2–6 | Huge snakes, tight space, every boost is decisive. |
| 4:30+ | **Resolution** | 1 or timer | Victory conditions trigger. Cinematic camera. |

---

# 4. Core Rules

These are the complete, authoritative rules of Snake Battle. Everything else in this document elaborates on them.

| # | Rule | Detail |
|---|---|---|
| R1 | **Equal start** | Every snake — human or bot — spawns at exactly the same length. There is no "Start Big." No exceptions, no purchases, no unlocks. |
| R2 | **Growth by eating only** | Length increases solely by consuming food pellets. |
| R3 | **Finite arena** | Every match uses one fixed, bounded map. The world does not wrap and is not infinite. |
| R4 | **Deadly border** | If a snake's **head** touches the arena boundary, that snake dies instantly. |
| R5 | **Body collision** | If a snake's **head** touches **another snake's body**, that snake dies instantly. The snake that was hit is unharmed. |
| R6 | **Self-collision is safe** | A snake cannot kill itself on its own body. It may coil freely. |
| R7 | **Full conversion** | On death, the entire body converts into food pellets that persist in the arena. |
| R8 | **Persistent food** | Food never despawns due to age. It remains until eaten. |
| R9 | **Boost costs mass** | Boosting increases speed and continuously drains length, dropping the lost mass behind as food. |
| R10 | **Unique colors** | Every snake in a match receives a visually distinct color. |
| R11 | **Room capacity** | Rooms hold up to 25 participants; unfilled slots become bots. |
| R12 | **Invite only** | There is no public matchmaking. Rooms are joined by code or direct invite. |

> [!WARNING]
> **R5 is asymmetric and this is the whole game.** Head-to-body means the *mover* dies. A player can kill a much larger snake by cutting in front of it. Do not "simplify" this into mutual destruction during implementation — the asymmetry is what makes small snakes dangerous and what makes the game competitive rather than a pure size race.

## 4.1 Head-to-Head Collision

When two heads collide within the same physics tick:

| Condition | Outcome |
|---|---|
| Lengths differ by > 5% | Shorter snake dies, longer survives |
| Lengths within 5% | **Both die.** Both bodies convert to food. |

A simultaneous double-death triggers the **Mutual Destruction** VFX (a single shared shockwave rather than two overlapping ones) and awards a kill to neither player, but counts as a death for both.

---

# 5. Game Modes

## 5.1 Multiplayer Room

- **Maximum 25 participants** per room.
- **Invite-only.** Joined via 6-character room code or a share-sheet deep link.
- **No public matchmaking** exists anywhere in the product.
- **Remaining slots automatically fill with AI bots** at match start.

**Composition example:**

```
Room Size:   25
Humans:       8   ████████
Bots:        17   █████████████████
             ──
Total:       25
```

The host sets room size (5–25). Bot count is always `roomSize − humansPresentAtStart`. If a human joins during the countdown, one bot is silently removed to make space. If a human disconnects mid-match, their snake is **not** replaced (see [Edge Cases](#25-edge-cases)).

| Setting | Owner | Options | Default |
|---|---|---|---|
| Room size | Host | 5–25 | 25 |
| Arena | Host | Circle / Square / Oval / Hexagon / Stadium / Custom | Circle |
| Bot difficulty | Host | Easy / Medium / Hard | Medium |
| Win condition | Host | Largest Snake / Last Survivor | Largest Snake |
| Match timer | Host | 3 / 5 / 8 min (Largest Snake only) | 5 min |
| Boost enabled | Host | On / Off | On |

## 5.2 Solo Mode

A fully offline mode. One human player versus a chosen number of bots. No server connection is required; the simulation runs entirely on-device using the same deterministic core as the server build.

**Supported configurations:**

| Preset | Composition | Intended Feel |
|---|---|---|
| Practice | 1 Player + 5 Bots | Open space, low pressure, learn steering |
| Standard | 1 Player + 10 Bots | Balanced density |
| Full Arena | 1 Player + 24 Bots | True match density, offline |
| Custom | 1 Player + 1–24 Bots | Player-defined |

The player chooses both bot count and bot difficulty. Solo Mode awards **reduced XP** (50%) and does not contribute to competitive leaderboards, but does count toward achievements and daily challenges.

> [!TIP]
> Solo Mode is also the **fallback experience for connection failure**. If a player loses network during lobby, offer a one-tap "Play Solo instead" that preserves their chosen arena and difficulty. Never dead-end a player at an error screen.

---

# 6. Room Management & Flow

## 6.1 Room Creation Flow

```
   ┌─────────────┐
   │ Create Room │
   └──────┬──────┘
          ▼
   ┌─────────────────┐
   │  Choose Arena   │  Circle · Square · Oval · Hexagon · Stadium · Custom
   └──────┬──────────┘
          ▼
   ┌──────────────────────┐
   │ Choose Bot Difficulty│  Easy · Medium · Hard
   └──────┬───────────────┘
          ▼
   ┌─────────────────┐
   │ Invite Friends  │  Room code · Share link · Recent players
   └──────┬──────────┘
          ▼
   ┌──────────────────────────────┐
   │ Fill Remaining Slots w/ Bots │  auto: roomSize − humans
   └──────┬───────────────────────┘
          ▼
   ┌─────────────┐
   │ Start Match │  host-triggered, 3-2-1 countdown
   └──────┬──────┘
          ▼
   ┌────────────────────┐
   │ Play Until Match   │
   │       Ends         │
   └────────────────────┘
```

## 6.2 Room State Machine

```
        ┌────────────┐
        │   EMPTY    │  room created, host only
        └─────┬──────┘
              │ player joins
              ▼
        ┌────────────┐  ◄──── players join / leave freely
        │  LOBBY     │        host edits settings
        └─────┬──────┘
              │ host taps START
              ▼
        ┌────────────┐
        │  LOCKING   │  0.5s — settings frozen, bots instantiated
        └─────┬──────┘
              │
              ▼
        ┌────────────┐
        │ COUNTDOWN  │  3 s — cinematic arena reveal
        └─────┬──────┘
              │
              ▼
        ┌────────────┐  ◄──── the match
        │   ACTIVE   │
        └─────┬──────┘
              │ win condition met
              ▼
        ┌────────────┐
        │ RESOLVING  │  4 s — victory camera, no input
        └─────┬──────┘
              │
              ▼
        ┌────────────┐
        │  RESULTS   │  leaderboard, XP, rewards
        └─────┬──────┘
              │ rematch          │ leave
              ▼                  ▼
          LOBBY              (destroy room)
```

| State | Duration | Input Accepted | Notes |
|---|---|---|---|
| `EMPTY` | — | UI only | Auto-destroys after 10 min idle |
| `LOBBY` | Unbounded | UI only | Host may kick, change settings |
| `LOCKING` | 0.5 s | None | Bot AI instances allocated from pool |
| `COUNTDOWN` | 3.0 s | Steering **accepted and buffered** | Player can pre-aim before the whistle |
| `ACTIVE` | ≤ timer | Full | — |
| `RESOLVING` | 4.0 s | None | Cinematic camera locks to winner |
| `RESULTS` | Unbounded | UI only | — |

> [!NOTE]
> **Steering is accepted during COUNTDOWN.** The snake does not move, but the head visually rotates to face the player's aim. This eliminates the "I wasn't ready" feeling at match start and is a meaningful perceived-responsiveness win for almost no engineering cost.

## 6.3 Room Management Rules

| Scenario | Behavior |
|---|---|
| Host leaves in lobby | Host migrates to longest-tenured player; room persists |
| Host leaves mid-match | Match continues; host role migrates for rematch purposes |
| Room full, player uses link | Show "Room Full" with a **Spectate** option |
| Player rejoins after disconnect | Allowed during `ACTIVE` if their snake is still alive (see 25.3) |
| Room idle 10 min | Auto-destroyed, players returned to menu |
| Rematch | Same players, same settings, bots re-rolled with new personalities |

---

# 7. Arena Design

## 7.1 Core Principle

> [!IMPORTANT]
> **Arenas are finite.** Unlike classic snake games and unlike most .io titles, the world does not scroll infinitely and does not wrap. Every match takes place inside one fixed, fully-bounded map with a lethal edge. This constraint is the source of the game's pressure — space is a resource that shrinks in value as snakes grow.

## 7.2 Arena Shapes

| Shape | Silhouette | Play Character | Recommended Population |
|---|---|---|---|
| **Circle** | `( )` | No corners, uniform pressure, purest chase gameplay | 15–25 |
| **Square** | `[ ]` | Corners are death traps; territorial, punishing | 10–20 |
| **Oval** | `(  )` | Two natural "ends" create migration lanes | 15–25 |
| **Hexagon** | `⬡` | Six soft corners, good compromise | 15–25 |
| **Stadium** | `(═══)` | Long straights + rounded caps; fastest, most linear | 20–25 |
| **Custom** | varies | Designer-authored, may include interior obstacles | varies |

### Shape Diagrams

```
   CIRCLE                 SQUARE                HEXAGON
   ░░▓▓▓▓▓▓░░            ▓▓▓▓▓▓▓▓▓▓            ░░▓▓▓▓▓▓░░
   ░▓▓░░░░▓▓░            ▓░░░░░░░░▓            ░▓░░░░░░▓░
   ▓▓░░░░░░▓▓            ▓░░░░░░░░▓            ▓░░░░░░░░▓
   ▓▓░░ ● ░░▓▓           ▓░░░ ● ░░▓            ▓░░░ ● ░░▓
   ▓▓░░░░░░▓▓            ▓░░░░░░░░▓            ▓░░░░░░░░▓
   ░▓▓░░░░▓▓░            ▓░░░░░░░░▓            ░▓░░░░░░▓░
   ░░▓▓▓▓▓▓░░            ▓▓▓▓▓▓▓▓▓▓            ░░▓▓▓▓▓▓░░

   OVAL                          STADIUM
   ░░▓▓▓▓▓▓▓▓▓▓░░               ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓░
   ▓▓░░░░░░░░░░▓▓               ▓░░░░░░░░░░░░░░▓
   ▓░░░░░ ● ░░░░▓               ▓░░░░░░ ● ░░░░░▓
   ▓▓░░░░░░░░░░▓▓               ▓░░░░░░░░░░░░░░▓
   ░░▓▓▓▓▓▓▓▓▓▓░░               ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓░

   ▓ = lethal boundary band    ░ = playable    ● = arena center
```

## 7.3 Arena Sizing

Arena area scales with participant count so that density stays constant regardless of room size.

```
arenaRadius = BASE_RADIUS * sqrt(participantCount / 25)
```

| Participants | Radius (units) | Playable Area | Starting Density |
|---|---|---|---|
| 5 | 1,073 | 3.6 M u² | 1 snake / 723 K u² |
| 10 | 1,518 | 7.2 M u² | 1 snake / 723 K u² |
| 15 | 1,859 | 10.9 M u² | 1 snake / 723 K u² |
| 25 | 2,400 | 18.1 M u² | 1 snake / 723 K u² |

> [!TIP]
> Keep density constant, not area. A 5-player match in a 25-player arena feels empty and dead. Designers should tune the single density constant, and all room sizes inherit correct pacing automatically.

## 7.4 The Boundary

The boundary is not a thin line. It is a **three-layer construct**:

| Layer | Width | Function | Visual |
|---|---|---|---|
| **Warning Field** | 120 u | Advisory only, no damage | Faint gradient tint, subtle inward-drifting particles |
| **Glow Band** | 40 u | Advisory, intensifies | Bright animated pulse, hum audio rises |
| **Lethal Line** | 0 u (exact) | Kills on head contact | Hard bright edge, the actual collision surface |

The **Lethal Line is a mathematically exact boundary**, not the visual band. A snake may safely graze the glow — this creates skill expression in edge-running while remaining fair, because the killing surface is precisely where the brightest pixel is.

### Boundary Animation

- **Idle pulse:** boundary emissive intensity oscillates on a 2.4 s sine, ±18% amplitude, so the arena feels alive rather than drawn.
- **Proximity flare:** when any snake head enters the Warning Field, the nearest ~30° arc of boundary brightens by 60% over 200 ms (`easeOutQuad`) and returns over 600 ms.
- **Impact rupture:** on a border death, the boundary at the impact point ruptures outward — a 1.2 s radial distortion wave travelling ±90° along the edge, decaying with distance.
- **Endgame constriction (optional):** in Last Survivor mode with a timer, the boundary may contract inward at 8 u/s in the final 60 s, with a continuous low-frequency rumble and a visible inward-sweeping energy ring.

## 7.5 Arena Themes

Each arena shape ships with at least two visual themes. Themes are **purely cosmetic** and must never alter collision geometry.

| Theme | Palette | Ambient Motion | Signature Effect |
|---|---|---|---|
| **Neon Grid** | Deep indigo, cyan, magenta | Slow-scrolling grid lines | Grid cells light up under snakes |
| **Solar** | Warm orange, gold, deep red | Rising heat shimmer | Solar flares arc across boundary |
| **Abyss** | Near-black, teal, bioluminescent | Drifting plankton motes | Snakes cast light on the floor |
| **Circuit** | Slate, lime, white | Data pulses along traces | Traces route toward the largest snake |
| **Frost** | Ice blue, white, pale violet | Falling crystalline flecks | Frost creeps in from the boundary |

**Universal theme requirements:**

- Ambient particle count: 200–400 on-screen, pooled, never allocated at runtime.
- Ambient lighting: one soft global gradient + per-snake emissive contribution.
- Animated decorations must be **non-interactive and never obscure a snake body**. Decorations render below the gameplay layer, at reduced alpha, with a hard rule: nothing decorative may exceed 35% opacity in the play area.
- Every theme must be validated for colorblind readability against all 25 snake colors.

---

# 8. Snake Systems

## 8.1 Anatomy

A snake is composed of three logical parts, which must be kept conceptually separate in code:

| Part | Purpose | Update Rate |
|---|---|---|
| **Path** | Authoritative history of head positions (a polyline) | Simulation tick (30 Hz) |
| **Spline** | Smoothed curve derived from Path (Catmull–Rom) | Render frame (60 Hz) |
| **Segments** | Visual/collision bodies sampled along the Spline | Render frame (60 Hz) |

```
   Head
    ●───────────────────────────────────────────
     ╲                                          ╲
      ● ← Path point (30 Hz, authoritative)      ╲
       ╲                                          ╲
        ○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○  ← Segments (60 Hz, sampled on spline)
       └──── smoothed Catmull–Rom spline ────┘
```

> [!IMPORTANT]
> **The snake is not a chain of followers.** Do not implement segments as physics bodies each chasing the one ahead — that approach accumulates error, wobbles under framerate variance, and desyncs across the network. Segments are **sampled positions on a curve**. The curve is the truth. This is non-negotiable for both visual quality and network determinism.

## 8.2 Movement Model

| Parameter | Value | Notes |
|---|---|---|
| Base speed | 240 u/s | Identical for all snakes regardless of length |
| Boost speed | 420 u/s | 1.75× base |
| Turn rate (base) | 260 °/s | |
| Turn rate (boosting) | 195 °/s | 75% — boosting reduces agility, a deliberate cost |
| Turn acceleration | Instant | **No ramp.** Pillar 1. |
| Segment spacing | 14 u | Constant; length is expressed as segment count |
| Head radius | 11 u | |
| Body radius | 10 u | Slightly smaller than head — visually tapers |

**Speed does not decrease with length.** A 400-segment snake moves exactly as fast as a 20-segment snake. This is a deliberate departure from some genre conventions: it keeps late-game engaging and prevents the leader from becoming a slow, helpless target.

### Turning

Turning is angular, not directional-snapping. The head has a heading `θ`. Player input supplies a **target heading** `θ_target`. Each tick:

```
delta   = shortestAngleBetween(θ, θ_target)
maxStep = turnRate * dt
θ      += clamp(delta, -maxStep, +maxStep)
```

The head begins rotating on the **first frame** input changes. There is no smoothing applied to `θ_target` itself — smoothing lives entirely in the `maxStep` clamp, which is a physical constraint, not an input delay.

## 8.3 Snake Colors

Every snake receives a **unique, visually distinct color**.

**Base palette (assigned in shuffled order, guaranteed distinct):**

| # | Name | Hex | # | Name | Hex |
|---|---|---|---|---|---|
| 1 | Crimson | `#FF3B47` | 14 | Amber | `#FFB020` |
| 2 | Cyan | `#22E0F0` | 15 | Rose | `#FF6FA8` |
| 3 | Violet | `#9B5CFF` | 16 | Sky | `#4DA8FF` |
| 4 | Lime | `#5CE65C` | 17 | Coral | `#FF7A55` |
| 5 | Orange | `#FF8A2B` | 18 | Aqua | `#3FE0C0` |
| 6 | Gold | `#FFD93D` | 19 | Orchid | `#C77DFF` |
| 7 | Magenta | `#FF4FD8` | 20 | Fern | `#7ED957` |
| 8 | White | `#F5F7FF` | 21 | Tangerine | `#FF9F1C` |
| 9 | Emerald | `#12C98C` | 22 | Sapphire | `#3D6BFF` |
| 10 | Scarlet | `#E02A5B` | 23 | Mint | `#8DF7C8` |
| 11 | Azure | `#2B7BFF` | 24 | Plum | `#8A4FCF` |
| 12 | Chartreuse | `#C6F53D` | 25 | Ivory | `#FFF3D6` |
| 13 | Turquoise | `#1FD6C4` | | | |

### Assignment Algorithm

```
1. Convert all 25 palette entries to CIELAB.
2. Shuffle the palette with the match seed.
3. Assign sequentially. Before confirming assignment i:
     if ΔE(color_i, any already-assigned color) < 22:
         swap color_i with the next candidate that satisfies ΔE ≥ 22
4. The local human player is ALWAYS assigned index 0 of the shuffled
   list, then their chosen cosmetic tint is applied on top.
```

> [!WARNING]
> **Never assign perceptually similar colors in the same match.** Two snakes of near-identical hue produce unfair deaths — a player cuts in front of what they believe is their own tail. The ΔE ≥ 22 constraint in CIELAB is a hard requirement, not a guideline. QA must include an automated test that generates 10,000 matches and asserts no pair falls below threshold.

### Player Distinguishability

Beyond unique hue, the local player's snake is separated by three additional channels:

1. **Outline** — a 2 u bright rim the player's snake alone possesses.
2. **Brightness** — the player's snake renders at 115% emissive relative to others.
3. **Nameplate** — "YOU" indicator, fading in only when the camera is zoomed out beyond 1.4×.

## 8.4 Length & Mass

Length is stored as a float `mass`, rendered as an integer `segments`.

```
segments = floor(mass)
```

| Event | Mass Delta |
|---|---|
| Starting mass | `10.0` (all snakes, always) |
| Eat standard pellet | `+1.0` |
| Eat corpse pellet | `+1.0` |
| Eat boost-drop pellet | `+0.5` |
| Boost drain | `−1.0 per 0.28 s` |

---

# 9. Food Systems

## 9.1 Food Sources

| Source | When | Value | Distribution |
|---|---|---|---|
| **Initial spawn** | Match start | 1.0 | Poisson-disc across the arena, min spacing 40 u |
| **Ambient replenish** | Continuous | 1.0 | Maintains a target count; spawns away from all heads |
| **Dead snakes** | On death | 1.0 each | Along the corpse's spline (see 11.2) |
| **Boost mass loss** | While boosting | 0.5 each | Dropped at the tail, behind the snake |

## 9.2 Persistence

> [!IMPORTANT]
> **Food never expires.** There is no despawn timer, no decay, no age-out. A pellet dropped in the first second of the match is still there in the last second if nobody ate it. This makes the arena a persistent record of everything that has happened and rewards players who remember where a big fight occurred.

Ambient replenishment maintains a floor, not a ceiling:

```
targetAmbient = 900 * (arenaArea / BASE_AREA)

if (ambientPelletCount < targetAmbient)
    spawn (targetAmbient - ambientPelletCount) * 0.05 pellets this tick
```

Corpse and boost pellets **do not count** toward `ambientPelletCount`. This means a bloody match genuinely becomes food-rich, which accelerates the endgame — a desirable pacing property.

## 9.3 Food Animation

Every pellet, at all times, runs the following composited motion. All of it is done in the vertex/fragment shader — **zero per-pellet CPU animation cost**.

| Layer | Motion | Parameters |
|---|---|---|
| **Float** | Vertical sine bob | Amplitude 3 u, period 2.2 s, phase = `hash(id)` |
| **Pulse** | Scale oscillation | 0.94× ↔ 1.06×, period 1.6 s, `easeInOutSine` |
| **Glow** | Emissive breath | 0.8 ↔ 1.2 intensity, period 1.9 s, offset from pulse |
| **Rotate** | Slow Y spin | 24 °/s, direction = `hash(id) & 1` |
| **Sparkle** | Occasional flash | 4-frame bloom burst, ~1 chance per 6 s per pellet |

> [!TIP]
> Offset every pellet's animation phase by a hash of its ID. If all pellets pulse in sync, the field looks like a screensaver. Desynchronized, it looks alive. This single line of shader code is the difference between "cheap" and "premium."

## 9.4 Collection Animation

When a head enters a pellet's collection radius, the pellet does **not** vanish. It performs a 180 ms **magnetize-and-consume**:

```
Frame 0        ● pellet at rest
   │
   │  0–40ms   Anticipation: pellet scales to 1.25×, glow spikes to 2.0
   │           (easeOutBack) — reads as "noticed"
   │
   │  40–150ms Flight: quadratic Bézier toward the head's MOUTH point
   │           (not head center). Control point offset perpendicular
   │           to flight path → the pellet arcs, it does not travel straight.
   │           Scale lerps 1.25 → 0.3. Trail ribbon emitted.
   │
   │ 150–180ms Impact: pellet reaches mouth, scale → 0
   │           Head performs a 1.08× "gulp" scale pop (easeOutBack, 120ms)
   │           Micro burst: 6 particles in snake's color
   ▼
 Consumed, returned to pool
```

**Critical detail:** mass is credited to the snake at **frame 0**, not at frame 180. The animation is purely cosmetic and must never gate the gameplay effect. A player who dies during the flight animation still ate the food.

**Magnetize radius** is larger than the collision radius (28 u vs 11 u), so pellets begin flying toward a head slightly before technical contact. This makes eating feel generous and responsive.

## 9.5 Special Food (Post-Launch Hook)

Reserved in the data model, disabled at launch:

| Type | Value | Visual | Notes |
|---|---|---|---|
| Standard | 1.0 | Small orb | Launch |
| Corpse | 1.0 | Slightly larger, snake-tinted | Launch |
| Boost drop | 0.5 | Small, dim | Launch |
| **Mega** | 5.0 | Large, rotating polyhedron | Reserved |
| **Golden** | 1.0 + score bonus | Gold, heavy sparkle | Reserved |

---

# 10. Boost System

## 10.1 Rules

- Boost is **enabled by default** (host may disable).
- While boosting: speed 240 → **420 u/s** over a 120 ms ramp (`easeOutQuad`).
- While boosting: mass drains at **1.0 per 0.28 s**.
- Drained mass is **dropped behind the snake as 0.5-value pellets**, one pellet per 0.5 mass.
- Boost requires `mass > MIN_BOOST_MASS (12.0)`. At or below that, boost silently fails with a short "denied" thump and a red flicker on the boost button.

| Parameter | Value |
|---|---|
| Speed multiplier | 1.75× |
| Ramp up | 120 ms `easeOutQuad` |
| Ramp down | 220 ms `easeOutCubic` |
| Mass drain | 3.57 mass/s |
| Pellet drop rate | ~7.1 pellets/s |
| Turn-rate penalty | ×0.75 |
| Minimum mass to boost | 12.0 |

## 10.2 Boost Economy

```
   Cost of 1 second of boost:  3.57 mass
   Distance gained vs base:     180 u
   Food required to recover:    3.57 pellets (~4)

   ⇒ A 1-second boost must gain you >4 pellets of value
     or a kill, or it was a losing trade.
```

This is a genuinely tense decision, which is exactly the design intent. Boost is not a movement ability; it is a **wager**.

## 10.3 Boost VFX & Animation

| Element | Specification |
|---|---|
| **Speed trail** | Ribbon mesh from the head, 14 segments long, snake-colored, additive blend, alpha fading tail-ward. Width modulated by speed. Persists 300 ms after boost ends, fading via `easeOutCubic`. |
| **Body stretch** | Segment spacing lerps 14 → 16.5 u over the ramp. The snake visibly *elongates* under acceleration and compresses back on release (see 16.4). |
| **Head flare** | Head emissive ×1.6, plus a forward-facing cone glow that scales with the ramp. |
| **Chevron pulses** | Bright chevrons travel head→tail along the body at 3/s, additive, snake-colored. Communicates "this snake is boosting" to opponents from off-screen distance. |
| **Drop puffs** | Each dropped pellet spawns with an 8-particle outward puff and a 60 ms scale-in from 0. |
| **Screen effect** | Player-only: radial motion blur at 12% intensity + FOV/zoom widen by 4% over 200 ms. |
| **Haptic** | Light continuous haptic at boost start (single impact, medium), nothing sustained (battery). |
| **Audio** | Rising filtered-noise whoosh, loops seamlessly, low-pass opens with the ramp. |

> [!TIP]
> The chevron pulses are the highest-value element in this table. In a 25-snake match, players need to identify *who is committing* at a glance. Motion travelling along a body is readable at far lower pixel counts than a color change or a UI icon.

---

# 11. Death & Conversion

## 11.1 Death Conditions

A snake dies when:

| Condition | Rule |
|---|---|
| **Head → other body** | Head circle overlaps any body segment of another snake |
| **Head → arena border** | Head circle crosses the Lethal Line |
| **Head → head** | Per [4.1](#41-head-to-head-collision) |

A snake **cannot** die from:

- Its own body (self-collision is explicitly safe)
- Its own tail
- Being hit by another snake's head (the mover dies, not the target)
- Running out of mass (boost simply becomes unavailable at the floor)

## 11.2 Conversion to Food

> [!IMPORTANT]
> **The entire body converts to food.** Not a percentage, not a scaled fraction — every segment becomes a pellet other snakes may eat. A 300-segment snake dying near you is a 300-pellet windfall, and the whole late game is built on that fact.

**Conversion rules:**

| Property | Value |
|---|---|
| Pellets produced | 1 per segment |
| Pellet value | 1.0 each |
| Placement | Along the corpse spline at original segment positions |
| Jitter | ±6 u random offset, so the corpse doesn't read as a rigid line |
| Tint | Blend of the dead snake's color and standard food color (60/40) |
| Availability | Pellets become edible **300 ms after death**, staggered head→tail |

The 300 ms stagger prevents the killer from instantly hoovering the entire corpse and gives nearby snakes a fair chance to contest it — a small rule with a large competitive impact.

## 11.3 Death Animation ("Dissolve")

The full death sequence runs **900 ms**. Gameplay-wise the snake is dead at t=0; everything below is presentation.

```
 t = 0ms      ██ FREEZE
              Snake stops instantly. Time-scale for this snake only → 0.
              Head flashes pure white, 1 frame.
              Screen shake if it is the local player (see 14.4).

 t = 0–120ms  ██ FLASH
              Full body emissive ramps to white over 80ms (easeOutExpo),
              holds 40ms. Body scale +12%. Reads as an overload.

 t = 120–420  ██ FRACTURE
              Body splits into segments at the seams. Each segment:
                · inherits a velocity = (outward normal * 40..90 u/s)
                · gains random angular velocity ±180°/s
                · begins a dissolve shader (noise-threshold burn from
                  edges inward, hot rim in the snake's color)
              Stagger: 8ms delay per segment, head → tail.
              A shockwave ring expands from the head: 0 → 260 u,
              easeOutQuart, alpha 0.9 → 0, 400ms.

 t = 300–700  ██ CONVERT
              Each segment's dissolve completes; at completion the segment
              spawns its food pellet with a 120ms scale-in from 0.15×
              (easeOutBack). Pellet inherits a fraction of the segment's
              velocity, then damps to rest over 500ms (easeOutCubic).

 t = 400–900  ██ SETTLE
              Ember particles (30–60, count scaled by length, capped)
              drift upward, fading.
              Residual light bloom at the death site decays over 500ms.
              A faint scorch decal fades in then out over 3s.
```

**Length-scaled intensity:** a 20-segment death is a small pop; a 300-segment death is an event. Scale shockwave radius, ember count, shake magnitude, and audio layer count by `clamp(mass / 150, 0.3, 1.0)`.

> [!NOTE]
> **Death must feel good even when it happens to you.** The most common emotional failure in this genre is a death that feels cheap and abrupt. The 900 ms sequence gives the player time to *understand* what killed them. Immediately after, present a 1.5 s slow-motion replay from a pulled-back angle showing the final approach, with the killing snake highlighted. Then offer **Respawn** / **Spectate** / **Leave**.

## 11.4 Death Camera

| Phase | Camera Behavior |
|---|---|
| 0–150 ms | Snap zoom in 12% toward death point, hard shake |
| 150–600 ms | Slow pull back to 1.6× normal zoom, `easeOutCubic` |
| 600–900 ms | Settle, slight orbit drift (2°) for cinematic feel |
| 900–2400 ms | Replay: pulled-back framing of the last 1.5 s at 0.4× time-scale |

## 11.5 Respawn

In **Largest Snake** mode, death is not elimination — players respawn.

| Property | Value |
|---|---|
| Respawn delay | 2.5 s (after the 900 ms death sequence) |
| Respawn mass | `10.0` — the same as everyone's start. No catch-up bonus. |
| Placement | Safest available point: maximizes distance to all heads and the border |
| Invulnerability | **1.5 s**, indicated by a pulsing rim and 60% body alpha |
| Behavior during invuln | Cannot kill or be killed; cannot eat |

In **Last Survivor** mode, death is final — the player enters Spectate.

**Respawn animation (600 ms):**

```
  0–100ms   Ground pulse ring at the spawn point, snake-colored
 100–300ms  Snake materializes head-first: segments scale in sequentially
            from 0 → 1 (easeOutBack, 10ms stagger), with a vertical
            light-column effect collapsing inward
 300–450ms  Head does a 1.15× "arrival" pop and a quick 15° look-around
 450–600ms  Invulnerability shimmer establishes; control returns at 450ms
```

> [!WARNING]
> **Return control at 450 ms, not 600 ms.** The last 150 ms of the animation must play out *while the player is already steering*. Any respawn animation that holds input hostage until it finishes will be described in reviews as "sluggish," regardless of how pretty it is.

---

# 12. Growth, Score & Win Conditions

## 12.1 Growth Formula

Mass is linear; **visual thickness is sub-linear**. If thickness scaled linearly, a 400-segment snake would consume the entire screen.

```
mass       = Σ(food eaten) − Σ(boost drain)      [linear, authoritative]
segments   = floor(mass)
bodyRadius = BASE_RADIUS * (1 + log10(1 + mass / 25) * 0.55)
```

| Mass | Segments | Body Radius | On-Screen Feel |
|---|---|---|---|
| 10 | 10 | 10.0 u | Starting size |
| 25 | 25 | 12.4 u | Noticeably grown |
| 50 | 50 | 14.6 u | Confident |
| 100 | 100 | 17.1 u | Threatening |
| 200 | 200 | 19.8 u | Dominant |
| 400 | 400 | 22.6 u | Arena presence |

Length grows without bound; thickness asymptotes. Long snakes dominate by **covering space**, not by being fat — which is both the fair design and the readable one.

## 12.2 Score System

Score is distinct from mass. Mass is the win condition in Largest Snake mode; score drives progression and leaderboards.

| Action | Score |
|---|---|
| Eat standard pellet | +10 |
| Eat corpse pellet | +10 |
| Eat boost pellet | +5 |
| Kill a snake | +250 + (victim's mass × 2) |
| Survive 30 s | +50 |
| Border-trap kill (victim died to border while you were within 300 u) | +100 bonus |
| Match victory | +1,000 |
| 2nd place | +500 |
| 3rd place | +250 |
| Largest-snake-at-any-point (≥30 s held) | +300 |

## 12.3 Win Conditions

The host selects one:

### Mode A — Largest Snake

- Match runs for a fixed timer (3 / 5 / 8 minutes).
- Death causes respawn at starting mass.
- **Winner: highest mass when the timer expires.**
- Encourages: greedy growth, risk-taking, comeback potential.

### Mode B — Last Survivor

- No timer (soft cap 10 min, then largest wins).
- Death is elimination; player enters Spectate.
- **Winner: the last snake alive.**
- Encourages: caution, positioning, patience.

| | Largest Snake | Last Survivor |
|---|---|---|
| Death | Respawn at 10 mass | Elimination |
| Timer | 3 / 5 / 8 min | None (10 min cap) |
| Bot behavior | More aggressive | More cautious |
| Typical length | 4–6 min | 3–8 min |
| Feel | Frantic, forgiving | Tense, decisive |

## 12.4 Victory & Defeat Presentation

**Victory (4 s cinematic + results):**

```
 0–400ms    Time-scale → 0.25×. Radial gold light blooms from the winner.
 400–1200   Camera arcs around the winner (orbit, easeInOutCubic),
            slow zoom in. Confetti + light-shaft particles.
            All remaining food gravitates gently toward the winner
            (purely cosmetic, no mass gained).
 1200–2400  "VICTORY" wordmark scales in with easeOutBack overshoot,
            letter-by-letter 40ms stagger, gold shimmer sweep.
 2400–4000  Winner's snake performs an idle celebration coil
            (a slow, elegant spiral) as the camera settles.
 4000+      Results panel slides up: rankings, score breakdown,
            XP bar filling with easeOutQuart, reward cards flipping in.
```

**Defeat (3 s + results):**

```
 0–300ms    Desaturation to 35% over 300ms. Time-scale 0.4×.
 300–900    Camera pulls back from the death point, easeOutCubic.
 900–1800   "DEFEAT" wordmark fades in — no overshoot, no shimmer.
            Slower, heavier easing than victory. Final placement
            counts up beneath it.
 1800–3000  Camera holds on the arena; the match continues visibly
            behind the UI if others are still playing.
 3000+      Results panel — identical layout to victory, different
            accent color. Highlights personal bests if any.
```

> [!TIP]
> **Defeat must never feel punitive.** Use the same panel layout, the same reward animations, and always surface at least one positive stat ("Longest snake you've ever been", "3 kills — a personal best"). The single strongest retention lever in this genre is how the losing screen feels.

---

# 13. Controls

## 13.1 Mobile Touch Controls

Two schemes, both available, selectable in Settings. Default is **Floating Joystick**.

### Scheme A — Floating Joystick (default)

```
   ┌─────────────────────────────┐
   │                             │
   │         GAMEPLAY            │
   │                             │
   │                             │
   │      ╭───╮                  │
   │      │ ◉ │ ← joystick       │
   │      ╰───╯   appears where  │
   │              you touch      │       ╭─────╮
   │                             │       │BOOST│
   └─────────────────────────────┘       ╰─────╯
```

- Touch anywhere in the left 65% of the screen → joystick origin spawns there.
- Drag → heading = angle from origin to finger.
- Dead zone: **8 px** (small — Pillar 1).
- Full deflection at 55 px; beyond that, angle only.
- Release → snake maintains current heading (it does not stop or drift).
- Origin **re-centers** if the finger travels more than 90 px from origin, preventing the joystick from "running out of room."

### Scheme B — Direct Touch

- Snake steers toward the finger's absolute screen position.
- More intuitive for new players; less precise at high zoom.
- Recommended for tablets.

### Boost Input

| Method | Description |
|---|---|
| **Dedicated button** | Bottom-right, thumb-reachable, 72 px hit target (visual 56 px) |
| **Second finger** | Tap anywhere with a second finger while steering |
| **Joystick over-push** | Push past 85 px deflection (optional, off by default) |

All three are active simultaneously except joystick over-push. Boost activates on `touchDown` and deactivates on `touchUp` — **never on tap-toggle**, which costs a frame and breaks Pillar 1.

## 13.2 Input Requirements

| Requirement | Specification |
|---|---|
| Input polling | Every frame, at the top of the frame, before simulation |
| Touch-to-visual latency | ≤ 16 ms (one frame) |
| Predicted movement | Client applies input immediately, before server confirmation |
| Multi-touch | Minimum 2 simultaneous points tracked |
| Left-handed mode | Mirrors joystick and boost regions |
| Sensitivity | 0.5×–2.0× slider, default 1.0× |
| Haptics | Toggleable; on by default |

> [!WARNING]
> **Never process input in a fixed-timestep physics callback.** Sample input on the render frame and feed the most recent value into the simulation step. Processing input at 30 Hz to match the tick rate makes the game feel unresponsive on 60 Hz displays, even though it is technically "correct."

## 13.3 Accessibility

| Feature | Implementation |
|---|---|
| Colorblind modes | Protanopia / Deuteranopia / Tritanopia palettes; ΔE validated per mode |
| High-contrast mode | Boosts snake/background separation, dims decorations to 15% |
| Reduced motion | Removes screen shake, motion blur, camera orbit; retains gameplay animation |
| Larger touch targets | +30% on all buttons |
| Left-handed layout | Full mirror |
| Audio cues | Distinct sounds for nearby threat, boost, and death, independent of visuals |

---

# 14. Camera System

## 14.1 Follow

The camera targets a **lead point** ahead of the head, not the head itself:

```
targetPos = headPos + (headVelocity.normalized * LOOKAHEAD * speedFactor)

LOOKAHEAD    = 90 u
speedFactor  = currentSpeed / BASE_SPEED     (so boosting extends lookahead)
```

Position is critically damped toward the target:

```
camPos = damp(camPos, targetPos, DAMPING, dt)
DAMPING = 6.5    // higher = snappier; 6.5 is tuned for 60fps
```

Use a **framerate-independent damp** (`1 - exp(-λ·dt)`), never a raw `lerp(a, b, 0.1)` — the latter changes behavior with framerate and will feel different on 60 vs 120 Hz devices.

## 14.2 Zoom

Zoom scales with the player's length so a growing snake always remains framed.

```
targetZoom = clamp(BASE_ZOOM * (1 + log10(1 + mass / 30) * 0.42),
                   MIN_ZOOM, MAX_ZOOM)
```

| Mass | Zoom | Visible Arena Width |
|---|---|---|
| 10 | 1.00× | 1,200 u |
| 50 | 1.22× | 1,464 u |
| 100 | 1.35× | 1,620 u |
| 200 | 1.49× | 1,788 u |
| 400 | 1.63× | 1,956 u |
| Cap | 1.75× | 2,100 u |

Zoom transitions are damped at **λ = 2.2** — deliberately slower than position damping. Fast zoom changes are nauseating; the player should never consciously notice zoom moving.

### Contextual Zoom Modifiers

| Trigger | Modifier | Blend |
|---|---|---|
| Boosting | +4% (widen) | 200 ms in, 300 ms out |
| Within 200 u of border | +6% (widen — show the danger) | 400 ms |
| Enemy head within 150 u | −3% (tighten — heighten tension) | 250 ms |
| Match countdown | Starts at 2.2×, eases to 1.0× over 3 s | `easeInOutCubic` |

## 14.3 Damping & Constraints

| Property | Value |
|---|---|
| Position damping λ | 6.5 |
| Zoom damping λ | 2.2 |
| Rotation | Locked (no camera roll during gameplay) |
| Border clamp | Camera never shows more than 180 u beyond the arena edge |
| Max velocity | 1,400 u/s (prevents a teleport-correction from whipping the view) |

## 14.4 Screen Shake

Shake is **trauma-based**: events add trauma, trauma decays, and shake magnitude is `trauma²` (squared, so small trauma is genuinely subtle).

```
shake     = maxOffset * trauma²
trauma   -= TRAUMA_DECAY * dt        // 1.6 /s
trauma    = clamp(trauma, 0, 1)
```

| Event | Trauma Added | Max Offset | Notes |
|---|---|---|---|
| Local player death (border) | 0.85 | 22 px | Plus a 60 ms freeze frame |
| Local player death (body) | 0.75 | 20 px | |
| Local player kills someone | 0.35 | 10 px | Positive-feeling, short |
| Nearby death (< 400 u) | 0.20 × falloff | 8 px | Scales with victim mass |
| Boost start | 0.08 | 3 px | Barely perceptible, adds punch |
| Match start whistle | 0.15 | 5 px | |
| Victory | 0.30 | 10 px | Then camera goes cinematic |

Shake uses **Perlin noise**, not random jitter — random shake reads as a rendering bug, Perlin reads as impact. Frequency: 22 Hz. Rotational shake: ±1.2° max, applied only for player death.

> [!NOTE]
> Respect the **Reduced Motion** accessibility setting: when enabled, replace all shake with a brief chromatic-aberration pulse and a stronger flash. The feedback is preserved; the vestibular trigger is not.

## 14.5 Cinematic Victory Camera

On victory the camera detaches from follow logic entirely and runs an authored sequence: a 270° orbit around the winning snake at 0.55× radius, 3.6 s duration, `easeInOutCubic`, with a 10% dolly-in and a slow tilt from 0° to 12°. Depth of field blurs the arena to 60% while the winner stays sharp.

## 14.6 Spectator Camera

For eliminated players in Last Survivor mode:

- Default: auto-follow the current largest snake.
- Swipe left/right to cycle targets; a name card slides in on switch (240 ms, `easeOutBack`).
- Pinch to free-zoom between 0.6× and 3.0×.
- Two-finger drag for free-pan, with a "Return to Action" pill that fades in after 3 s idle.

---

# 15. AI & Bot Behavior

Bots are the majority of participants in most matches. Their quality *is* the game's quality.

> [!IMPORTANT]
> **Bots must never cheat.** Same speed, same turn rate, same boost economy, same collision rules, same starting mass. Difficulty is expressed exclusively through **perception radius, reaction latency, decision quality, and aggression** — never through mechanical advantage. A player who inspects the game must find nothing unfair, because there is nothing unfair.

## 15.1 Architecture: Behavior Tree + Utility Scoring

Bots use a **hybrid** model. A behavior tree governs high-level state; within the tree, action selection uses **utility scoring** so bots make graded rather than binary decisions.

```
                        ┌─────────────────┐
                        │   ROOT (?)      │  selector, evaluated 10 Hz
                        └────────┬────────┘
             ┌───────────────────┼───────────────────┬──────────────┐
             ▼                   ▼                   ▼              ▼
      ┌─────────────┐    ┌──────────────┐    ┌────────────┐  ┌───────────┐
      │  SURVIVE    │    │    HUNT      │    │   FEED     │  │  WANDER   │
      │ (priority 0)│    │ (priority 1) │    │(priority 2)│  │(fallback) │
      └──────┬──────┘    └──────┬───────┘    └─────┬──────┘  └─────┬─────┘
             │                  │                  │               │
   ┌─────────┼────────┐    ┌────┴─────┐      ┌─────┴─────┐   ┌─────┴─────┐
   ▼         ▼        ▼    ▼          ▼      ▼           ▼   ▼           ▼
 Avoid    Avoid    Escape  Cut-off  Encircle Nearest  Contest  Patrol  Reposition
 Border   Body     Trap                      Food     Corpse           to Center
```

### Node Definitions

| Node | Precondition | Action |
|---|---|---|
| **Avoid Border** | Predicted position in `reactionTime` intersects Lethal Line | Steer to tangent of arena edge, away from wall |
| **Avoid Body** | Predicted path intersects any body segment | Steer to the widest safe angular gap |
| **Escape Trap** | Safe angular gap < 40° | Boost through the largest remaining gap |
| **Cut-off** | Target head within `huntRadius`, interception point reachable | Boost to interception point ahead of target |
| **Encircle** | Bot mass > 2× target, target near border | Arc around target, shrinking their space |
| **Nearest Food** | Any pellet in `perceptionRadius` | Path to highest-utility pellet |
| **Contest Corpse** | Corpse cluster within `perceptionRadius` | Path to cluster centroid, boost if contested |
| **Patrol** | Nothing else scored | Wander with smoothed noise heading |
| **Reposition** | Bot is within 250 u of border with no food | Steer toward arena center |

### Utility Scoring

For food selection, each candidate pellet scores:

```
utility = (value / distance²) * 1000
        * safetyFactor                   // 0..1, drops near enemies/border
        * clusterBonus                   // 1.0 .. 1.8 for dense corpse piles
        * contestPenalty                 // 0.4 if an enemy is closer than us
        * personalityWeight              // per-bot, see 15.4
```

The bot targets the highest-utility candidate and **re-evaluates every 100 ms**, with hysteresis: a new target must beat the current one by 15% to cause a switch. Without hysteresis, bots visibly dither between two equally good pellets, which reads as broken.

## 15.2 Difficulty Tiers

### Easy

| Parameter | Value |
|---|---|
| Reaction time | 380–520 ms (randomized per decision) |
| Perception radius | 420 u |
| Path lookahead | 0.4 s |
| Pathfinding quality | Greedy nearest-food; ignores clustering |
| Aggression | 8% — rarely initiates |
| Boost usage | Only to escape; never to attack |
| Mistake rate | 18% — will sometimes steer into avoidable danger |
| Border awareness | Reacts at 90 u; sometimes too late |
| Turn efficiency | 70% — overshoots targets |

**Character:** Easy bots are pleasant, slightly clumsy company. They collect food, occasionally kill themselves on the border, and almost never hunt. They exist so new players can learn the arena without pressure. They must still look *purposeful* — a bot that wanders aimlessly reads as broken, not as easy.

### Medium

| Parameter | Value |
|---|---|
| Reaction time | 180–260 ms |
| Perception radius | 780 u |
| Path lookahead | 0.9 s |
| Pathfinding quality | Utility-scored with clustering |
| Aggression | 32% |
| Boost usage | Escape + opportunistic cut-offs |
| Mistake rate | 7% |
| Border awareness | Reacts at 180 u; reliably safe |
| Turn efficiency | 88% |

**Character:** Medium bots play a competent, recognizably human game. They take good food, avoid obvious danger, and will punish a player who cuts too close. They do not coordinate. This is the default and should be tuned to be genuinely satisfying to beat.

### Hard

| Parameter | Value |
|---|---|
| Reaction time | 80–130 ms |
| Perception radius | 1,400 u |
| Path lookahead | 1.8 s |
| Pathfinding quality | Full utility + predictive interception |
| Aggression | 68% |
| Boost usage | Aggressive; commits to kills, manages mass budget |
| Mistake rate | 2% |
| Border awareness | Reacts at 300 u; will *use* the border offensively |
| Turn efficiency | 97% |
| Coordination | Loose — up to 3 bots may converge on one high-value target |

**Character:** Hard bots hunt. They predict where the player will be, cut in front, and use the arena boundary as a weapon — driving the player toward the wall and closing the escape angle. They surround. They contest corpses aggressively. They are the reason the game has a skill ceiling.

### Comparison

| Trait | Easy | Medium | Hard |
|---|---|---|---|
| Reaction time | 380–520 ms | 180–260 ms | 80–130 ms |
| Perception | 420 u | 780 u | 1,400 u |
| Aggression | 8% | 32% | 68% |
| Mistake rate | 18% | 7% | 2% |
| Predictive aim | ✗ | Partial | ✓ |
| Uses border as weapon | ✗ | Rarely | ✓ |
| Encircles | ✗ | ✗ | ✓ |
| Coordinates | ✗ | ✗ | Loose (≤3) |

## 15.3 Key Behaviors Explained

### Predictive Interception (Hard only)

Rather than steering at the target's current position, the bot solves for where the target *will* be:

```
1. Estimate target velocity from the last 6 ticks (smoothed).
2. Solve the interception time t where:
       |targetPos + targetVel * t − botPos| = botSpeed * t
3. If t < 2.0s and the interception point is inside the arena
   and not inside another snake:
       steer to interception point, engage boost if t < 1.2s
4. Abort if the bot's own escape angle would drop below 50°.
```

Step 4 is essential. Without it, Hard bots suicide constantly by committing to kills they cannot survive — the classic failure mode of naive aggressive AI.

### Border Weaponization (Hard only)

```
   Player heading ──────►
                          ▓▓▓▓▓▓ border
   ┌─────────────────────────────┐
   │                       ░░░░░ │
   │      ╔══════╗ ← bot arcs    │
   │      ║ BOT  ║   to close    │
   │      ╚══════╝   the gap     │
   │                             │
   │   ● PLAYER ─────────►  ✕    │  ← escape angle shrinking
   └─────────────────────────────┘
```

The bot computes the player's **escape cone** — the angular range of headings that avoid both the bot's body and the border. It then positions to shrink that cone. When the cone drops below ~35°, it boosts to close. This is genuinely difficult to escape and is the signature Hard-tier threat.

### Threat Assessment (all tiers)

Every 100 ms, each bot evaluates nearby snakes:

```
threat = (theirMass / myMass)
       * (1 / distance)
       * headingTowardMe        // 0..1 dot product
       * (theyAreBoosting ? 1.8 : 1.0)
```

If `max(threat) > tierThreshold`, the bot transitions to `SURVIVE`, overriding all lower-priority nodes.

### Escape Solver

When trapped, the bot performs a radial sweep at 5° increments across 360°, ray-casting `lookahead × speed` units. It selects the heading with the greatest clear distance, weighted toward headings near its current one (to avoid a physically impossible reversal). If the best clear distance is below a critical threshold, it boosts — accepting mass loss to survive.

## 15.4 Bot Personalities

To prevent 17 identical bots from behaving as a hive, each bot is assigned a **personality** at spawn that modulates its tier parameters by ±25%.

| Personality | Weight | Traits |
|---|---|---|
| **Glutton** | 20% | +30% food utility, −20% aggression. Grows fast, fights rarely. |
| **Hunter** | 20% | +35% aggression, −15% food utility. Seeks kills. |
| **Coward** | 15% | +40% threat sensitivity, boosts away early. Survives long. |
| **Bruiser** | 15% | Contests corpses hard, +25% boost usage. |
| **Drifter** | 15% | Wanders more, less optimal, more unpredictable. |
| **Camper** | 15% | Prefers arena-edge territory, ambushes passers-by. |

Personalities are re-rolled every match, including rematches, so a room never feels like it's playing the same opponents twice.

## 15.5 Bot Naming & Presentation

Bots must be **indistinguishable from humans in the UI**. No "BOT" label, no robot icon.

- Names drawn from a curated pool of 400+ plausible player handles.
- Names are unique within a match.
- Bots exhibit **human-like imperfection**: micro-hesitations (a 40–90 ms pause before committing to a turn), occasional slightly-suboptimal food choices, and small heading jitter (±2°) so their paths are not machine-perfect straight lines.
- Bots "react" to near-misses with a small evasive flourish.

> [!TIP]
> The heading jitter is the single most effective humanizing trick. A bot travelling in a perfectly straight line is instantly identifiable. Two degrees of noise on a 0.4 Hz sine costs nothing and destroys the tell.

## 15.6 Bot Spawn Logic

```
1. At LOCKING, compute botCount = roomSize − humansPresent.
2. Acquire botCount instances from the pre-warmed bot pool.
3. Assign each: unique name, unique color (post-human assignment),
   personality (weighted roll), tier params (from host setting).
4. Spawn placement:
     · Distribute all participants (human + bot) via Poisson-disc
       sampling across the arena.
     · Minimum separation: 260 u.
     · Minimum distance from border: 220 u.
     · Humans are placed first, in the most central positions.
5. Stagger AI activation across 200 ms so 24 first-frame decisions
   do not spike the CPU.
```

## 15.7 AI Performance Budget

| Metric | Budget |
|---|---|
| Total AI CPU per frame | ≤ 2.0 ms (24 bots) |
| Per-bot per decision | ≤ 0.08 ms |
| Decision frequency | 10 Hz, **round-robin staggered** |
| Bots evaluated per frame @60fps | ~4 |
| Perception queries | Via shared spatial hash; never brute-force |

Round-robin staggering is mandatory: evaluating all 24 bots on the same frame produces a periodic 10 Hz frame spike that players perceive as stutter.

---

# 16. Animation Bible

> [!IMPORTANT]
> **Nothing in Snake Battle snaps.** Every state change, every value transition, every appearance and disappearance is animated. A static UI element is a bug. This section is the contract between design and engineering on what "premium" means for this title.

## 16.1 Easing Vocabulary

| Curve | Use Case | Cubic-Bezier |
|---|---|---|
| `easeOutQuad` | Fast responses, quick settles | `(0.25, 0.46, 0.45, 0.94)` |
| `easeOutCubic` | Standard UI entrance | `(0.22, 0.61, 0.36, 1.0)` |
| `easeOutQuart` | Camera, long settles | `(0.17, 0.84, 0.44, 1.0)` |
| `easeOutExpo` | Impacts, flashes | `(0.19, 1.0, 0.22, 1.0)` |
| `easeOutBack` | Playful pops, arrivals | `(0.34, 1.56, 0.64, 1.0)` |
| `easeInOutCubic` | Camera orbits, symmetric moves | `(0.65, 0.05, 0.36, 1.0)` |
| `easeInBack` | Exits, dismissals | `(0.36, 0.0, 0.66, -0.56)` |
| Spring (stiff) | Buttons, cards | stiffness 320, damping 24 |
| Spring (soft) | Panels, large elements | stiffness 180, damping 22 |

**Rule:** entrances overshoot (`Back`), exits do not. Overshooting exits look indecisive.

## 16.2 Snake — Movement Animation

### Spline Movement

The rendered body is a **Catmull–Rom spline** through path points, resampled at uniform arc length. The visual snake is continuous at any framerate and any speed, with no visible segment stepping.

| Property | Value |
|---|---|
| Spline type | Catmull–Rom, tension 0.5 |
| Path point spacing | 14 u |
| Render samples | 3 per segment (≈4.7 u) |
| Resampling | Uniform arc-length, recomputed per frame |

### Fluid Turning

The head does not merely rotate — the whole body flows through the turn.

- Head banks (rolls) into turns: up to **±14°**, proportional to angular velocity, damped at λ=8.
- The first 5 segments inherit a fraction of the bank, decaying by 0.75× per segment, producing a natural lean through the curve.
- On sharp turns (>200°/s), the outer edge of the body stretches by 6% and the inner edge compresses by 6% — a squash-and-stretch effect that sells the force of the maneuver.

### Tail Follow Interpolation

The tail tip does not stop instantly when the head does. Its position is interpolated toward its spline anchor with λ = 14, producing a very slight drag. On sharp direction changes the tail whips outward with a 90 ms delay and settles with a damped oscillation (2 cycles, amplitude decaying 0.4× per cycle).

### Head Wobble

A subtle sinusoidal lateral oscillation on the head, communicating locomotion:

```
wobbleAngle = sin(time * WOBBLE_FREQ) * WOBBLE_AMP * speedFactor

WOBBLE_FREQ = 7.5 rad/s
WOBBLE_AMP  = 2.8°
speedFactor = currentSpeed / BASE_SPEED    // stronger while boosting
```

The wobble propagates down the first 8 segments with a per-segment phase delay of 0.06 rad, creating a serpentine ripple. This is the animation that most makes the snake feel *alive* rather than like a moving rectangle.

### Idle Breathing

When the snake is nearly stationary (countdown, victory pose, respawn invulnerability):

- Body radius oscillates ±3% on a 2.8 s `easeInOutSine`.
- Head performs slow look-around: ±8° yaw on a 4.5 s cycle with randomized pauses.
- The tail tip drifts gently, 4 u amplitude, 3.2 s period.

## 16.3 Snake — Growth Animation

Growth must never look like segments teleporting into existence.

```
 On eating (mass += 1.0):

  0–120ms   The head performs a "gulp": scale 1.0 → 1.08 → 1.0
            (easeOutBack). A subtle bulge travels head→tail.

  0–350ms   BULGE PROPAGATION
            A localized radius increase (+18%) travels down the body
            at 340 u/s, decaying in amplitude. Visually, you can see
            the food moving through the snake. This is the single
            most-loved growth animation in the genre — do not cut it.

 300–450ms  TAIL EXTENSION
            The new segment does not pop in. The tail tip extends:
            the tail's arc-length target grows by 14 u, interpolated
            with easeOutCubic. The last segment scales from 0.4 → 1.0
            over the same window.
```

Rapid eating (a corpse pile) **stacks** bulges rather than restarting the animation. A snake hoovering 40 pellets should ripple continuously — an intentional, extremely satisfying visual.

## 16.4 Snake — Body Stretching & Compression

Segment spacing is dynamic, driven by acceleration:

| State | Spacing | Effect |
|---|---|---|
| Constant speed | 14.0 u | Neutral |
| Accelerating (boost start) | → 16.5 u | Body **stretches**, taut and fast |
| Decelerating (boost end) | → 12.2 u | Body **compresses**, momentarily bunched |
| Sharp turn | outer +6%, inner −6% | Body arcs and flexes |

Spacing lerps toward its target at λ = 9. Because segments sample the same spline, stretching changes only the sampling density — it never distorts the path, so **collision geometry is unaffected**. This is a purely visual effect with zero gameplay consequence, which is exactly what it should be.

## 16.5 Snake — Spawn Animation

```
   0–120ms   Anticipation ring: a flat ring expands at the spawn point,
             0 → 90 u, snake-colored, alpha 1 → 0. (easeOutQuart)

 100–320ms   Materialization: segments scale in from 0, head-first,
             12ms stagger. Each segment scales 0 → 1.12 → 1.0
             (easeOutBack). A vertical light column at the spawn point
             collapses inward and disappears.

 320–460ms   Settle: head performs a 1.12× pop and a 20° look-around.
             Body settles into idle breathing.

 460ms       CONTROL RETURNS.

 460–900ms   Spawn shimmer fades: a bright rim on the body fades from
             1.0 → 0 over 440ms (easeOutCubic).
```

## 16.6 Snake — Death Dissolve

Fully specified in [11.3](#113-death-animation-dissolve). Summary of the shader work:

| Shader Parameter | Behavior |
|---|---|
| `_BurnThreshold` | 0 → 1 over the segment's dissolve window |
| `_BurnRimWidth` | 0.06, constant |
| `_BurnRimColor` | Snake color × 3.5 (HDR, blooms) |
| `_NoiseScale` | 8.0 — fine grain, reads as disintegration not melting |
| `_EmissiveBoost` | 1 → 4 over the flash, then decays with the burn |

## 16.7 Food Conversion Animation

The moment a body segment becomes a pellet:

```
  Segment (dissolving) ───► Pellet (spawning)

  · Overlap window: 80ms. The pellet begins scaling in at 0.15×
    while the segment is still at 25% dissolve. There is never a
    frame where neither exists — a gap reads as a dropped frame.
  · The pellet inherits 35% of the segment's outward velocity,
    then damps to rest over 500ms (easeOutCubic).
  · Pellet color starts at the snake's color and lerps to
    corpse-food color over 400ms.
  · A single bright spark connects the two for 60ms — a visual
    "handoff" that makes the conversion legible.
```

## 16.8 UI Animation Specification

### Global Rules

| Rule | Specification |
|---|---|
| Entrance | Fade + scale from 0.94, `easeOutCubic`, 240 ms |
| Exit | Fade + scale to 0.97, `easeInBack`, 160 ms |
| Stagger | 40 ms per element in a list, capped at 8 elements |
| Button press | Scale 0.94 over 80 ms, release to 1.0 with stiff spring |
| Value change | Always count/tween — **never** assign a number directly |
| Panel slide | 320 ms, soft spring, with a 12 px directional offset |
| No element appears without animation | Zero exceptions |

### Screen-by-Screen

| Screen | Animation |
|---|---|
| **Main Menu** | Logo scales in with `easeOutBack` + shimmer sweep. Buttons stagger up 40 ms apart. Background snakes idle-swim in parallax layers. |
| **Create Room** | Panel slides up (soft spring). Arena selector is a horizontal carousel with 3D perspective tilt; the centered card scales to 1.08× and its preview animates live. |
| **Arena Preview** | Miniature arena rotates slowly, boundary pulses, 3 demo snakes swim procedural paths. |
| **Difficulty Selector** | Three cards; selection triggers a color sweep across the chosen card (300 ms) and a subtle icon animation (Easy: gentle bob; Medium: steady pulse; Hard: sharp flicker). |
| **Invite Friends** | Room code characters flip in individually (60 ms stagger, 3D Y-rotation). Copy button morphs into a checkmark on tap (240 ms). |
| **Lobby** | Player slots fill with a scale-in + colored ring sweep. Bot slots fill with a slightly different "materialize" effect *internally* — but must be visually identical to players in the UI. |
| **Countdown** | "3 · 2 · 1 · GO": each numeral scales from 2.4× → 1.0× with `easeOutExpo`, then fades and scales to 0.6× on exit. "GO!" adds a full-screen radial flash and a shockwave ring. Camera zooms from 2.2× to 1.0× across the whole 3 s. |
| **HUD entrance** | Elements slide in from their nearest screen edge, 60 ms stagger, after "GO!". |
| **Kill notification** | Slides in from the right with `easeOutBack`, holds 2.2 s, exits right with `easeInBack`. Multiple kills stack vertically and push previous entries down with a spring. Text: `YOU ELIMINATED <name>` with the victim's color as accent. |
| **Leaderboard (in-match)** | Rank changes animate: rows slide vertically over 400 ms (`easeOutCubic`), the moving row briefly highlights, and the player's own row has a permanent subtle glow. Numbers tween. |
| **Victory** | Per [12.4](#124-victory--defeat-presentation). |
| **Defeat** | Per [12.4](#124-victory--defeat-presentation). |
| **Results panel** | Rows stagger in 50 ms apart. XP bar fills with `easeOutQuart` over 1.2 s with a leading glow. Reward cards flip in 3D (`easeOutBack`, 120 ms stagger). Level-up triggers a full-screen burst. |
| **Settings** | Toggles slide with a spring and a color crossfade. Sliders show a live-updating value pill that scales in on grab. Section headers stick with a blur-backed header. |

> [!WARNING]
> **Never block input on a UI animation.** Every animated element must be interactive from the first frame of its entrance. If a player taps "PLAY" 80 ms into the menu animation, the button must respond. Animation is presentation; input is sacred.

---

# 17. Particle & VFX Catalogue

All particle systems are **pooled**. Zero runtime allocation. Every system below has a hard cap and an LOD tier.

| Event | Particles | Behavior | Cap | Duration |
|---|---|---|---|---|
| **Eat food** | 6–8 | Radial burst from mouth, snake-colored, additive, 40 u/s, gravity 0 | 8 | 300 ms |
| **Eat corpse pellet** | 10 | As above + 2 larger embers in the victim's color | 12 | 400 ms |
| **Boost trail** | Ribbon + 20/s emitters | Ribbon mesh + spark motes trailing, additive | 60 live | continuous |
| **Boost drop** | 8 per pellet | Outward puff, snake-colored, quick fade | 8 | 200 ms |
| **Death (small, <50)** | 30 + shockwave | Embers + one ring | 40 | 900 ms |
| **Death (large, ≥150)** | 60 + shockwave + shards | Embers, ring, 12 fracture shards with trails | 90 | 900 ms |
| **Border collision** | 40 | Sparks along the border tangent + a rupture wave travelling ±90° along the edge | 50 | 1,200 ms |
| **Spawn / Respawn** | 24 | Inward-collapsing ring + upward light motes | 30 | 600 ms |
| **Kill confirm** | 16 | Screen-space bloom pulse at the kill point + radial chevrons | 20 | 500 ms |
| **Victory** | 200 | Confetti (physics, tumbling), light shafts, gold motes rising | 220 | 4,000 ms |
| **Defeat** | 30 | Downward-drifting grey motes, desaturated | 30 | 2,000 ms |
| **New high score** | 60 | Golden burst from the score HUD element + a shimmer sweep across the whole HUD | 60 | 1,500 ms |
| **Largest snake** | 40 | Persistent crown aura: slow orbiting gold motes around the head | 40 (persistent) | while held |
| **Level up** | 120 | Full-screen radial burst + expanding ring + text shimmer | 120 | 2,000 ms |

### VFX LOD Tiers

| Tier | Device Class | Particle Budget | Reductions |
|---|---|---|---|
| **High** | Flagship | 100% | Full spec, all post-processing |
| **Medium** | Mid-tier | 60% | Halved ambient, no motion blur, simplified trails |
| **Low** | Budget / thermal-throttled | 30% | Essential feedback only, no ambient, flat trails, no bloom on non-gameplay |

> [!IMPORTANT]
> **LOD must never remove gameplay-critical feedback.** Death VFX, kill confirmation, boost chevrons, and border warnings are on the **protected list** — they scale in *density* but never disappear, at any tier. A player on a budget device must still be able to read the fight.

---

# 18. Sound Design

## 18.1 Philosophy

Audio is the second responsiveness channel. Sound must fire on the **input frame**, not on the confirmation frame. A boost sound that waits for server acknowledgement makes the game feel laggy even when it isn't.

## 18.2 Sound Catalogue

### UI

| Sound | Character | Length |
|---|---|---|
| Button tap | Soft, warm click with a pitched-up tail | 90 ms |
| Button back/cancel | Same, pitched down 3 semitones | 90 ms |
| Panel open | Airy swell, rising | 320 ms |
| Panel close | Descending, shorter | 180 ms |
| Toggle on / off | Two-tone click, up / down | 70 ms |
| Room code copied | Bright confirm chime | 400 ms |
| Player joins lobby | Warm ascending two-note | 500 ms |
| Player leaves lobby | Soft descending single note | 350 ms |
| Error / denied | Muted low thump, no harshness | 150 ms |
| Reward card flip | Paper-flick + soft sparkle | 260 ms |
| Level up | Full ascending fanfare, layered | 2,000 ms |

### Gameplay

| Sound | Character | Notes |
|---|---|---|
| **Eat pellet** | Short, bright "pip" | Pitch rises with a combo counter: +0.4 semitones per pellet within 500 ms of the last, capping at +12. Eating a corpse pile plays as a rising musical run — a top-tier satisfaction mechanic. |
| **Eat corpse pellet** | Deeper, rounder "pop" | Distinct from ambient food, so players hear that they're in a windfall |
| **Boost start** | Sharp intake + noise whoosh onset | Fires on `touchDown`, always |
| **Boost loop** | Filtered noise, low-pass opening with the ramp | Seamless loop, ducked under other SFX |
| **Boost end** | Falling whoosh tail | 220 ms |
| **Boost denied** | Dry thump | When below minimum mass |
| **Near miss** | Doppler whoosh | When an enemy head passes within 60 u — the pure adrenaline sound |
| **Kill (you killed)** | Deep impact + rising bright confirm | Layered, punchy, unmistakably positive |
| **Kill (nearby)** | Muffled impact, distance-attenuated | Spatialized |
| **Death — body** | Wet impact + glassy shatter + descending tail | Layered by victim mass |
| **Death — border** | Electric zap + rupture + descending tail | Distinct from body death, so players know what killed them |
| **Own death** | All of the above + a full-spectrum duck of every other sound for 400 ms | The silence is what sells the moment |
| **Respawn** | Rising materialize shimmer | 600 ms |
| **Border proximity** | Rising hum, volume/pitch tied to distance | Continuous, subtle, never annoying — this is a warning system |
| **Largest snake gained** | Regal short sting | Once per acquisition |

### Match Flow

| Sound | Character |
|---|---|
| Countdown "3, 2, 1" | Three rising tones, each a perfect fourth apart |
| "GO!" | Bright stab + a low sub-boom + a music downbeat |
| Match victory | Full triumphant cue, 6 s, resolves cleanly |
| Match defeat | Descending, melancholic but warm — never harsh, never mocking |
| 30 s remaining | Subtle tempo lift in the music + a single chime |
| Final 10 s | Ticking layer enters, music intensity rises |

### Ambient

| Layer | Description |
|---|---|
| Arena ambience | Theme-specific bed — Neon Grid hums, Abyss has distant sonar, Frost has wind |
| Boundary hum | Spatialized along the border, rising as the player approaches |
| Crowd density | A subtle "swarm" layer whose intensity tracks nearby snake count — players *feel* danger before seeing it |
| Music | Adaptive, layered stems: intensity tracks `f(nearbyThreats, playerMass, timeRemaining)`. Stems cross-fade over 2 s at bar boundaries. |

## 18.3 Technical Audio Requirements

| Requirement | Specification |
|---|---|
| Max concurrent voices | 32 (mobile) |
| Voice stealing | Priority-based; gameplay-critical SFX never stolen |
| Spatialization | 2D panning + distance attenuation (no HRTF — battery) |
| Latency | ≤ 20 ms; use low-latency audio paths (AAudio / AVAudioEngine) |
| Ducking | Own-death ducks everything −18 dB for 400 ms |
| Compression | Master bus limiter to prevent clipping in 25-snake chaos |
| Mute behavior | Respects device silent switch; music and SFX have separate sliders |
| Format | Compressed streaming for music, decompressed in-memory for SFX |

> [!TIP]
> **The combo-pitch eating sound is the highest-ROI audio feature in the entire game.** It costs almost nothing to implement and converts a mundane action into a dopamine loop. Prioritize it in the first playable.

---

# 19. UI Layout & HUD

## 19.1 In-Match HUD

```
┌──────────────────────────────────────────────────────────┐
│ ┌──────────┐                                ┌──────────┐ │
│ │ LENGTH   │           ⏱ 3:24              │ 1 ▓▓ 412 │ │
│ │   142    │                                │ 2 ▓▓ 388 │ │
│ └──────────┘                                │ 3 ▓▓ 301 │ │
│                                             │ 4 ▓▓ 260 │ │
│                                             │ ● YOU 142│ │
│                                             └──────────┘ │
│                                                          │
│                                                          │
│                      G A M E P L A Y                     │
│                                                          │
│                                                          │
│                                            ┌───────────┐ │
│  ╭───╮                                     │  MINIMAP  │ │
│  │ ◉ │  ← floating joystick                │  ·  ·  ●  │ │
│  ╰───╯    (appears on touch)                │    ·   · │ │
│                                             └───────────┘ │
│                                                  ╭─────╮ │
│                                                  │BOOST│ │
│                                                  ╰─────╯ │
└──────────────────────────────────────────────────────────┘
```

### HUD Elements

| Element | Position | Behavior |
|---|---|---|
| **Length counter** | Top-left | Large numeral, tweens on change, pulses + scales 1.15× on growth. Colored in the player's snake color. |
| **Match timer** | Top-center | Largest Snake mode only. Turns amber at 60 s, red at 10 s with a per-second pulse. |
| **Leaderboard** | Top-right | Top 4 + player's own row (always visible even if outside top 4). Rows animate on rank change. Each row shows a color swatch, name, and length. |
| **Minimap** | Bottom-right | Arena silhouette, player as a bright dot, other snakes as smaller dots (colored), dense food regions as a soft heat tint. Fades to 45% opacity when the player is not near the border, returns to 100% when they are. |
| **Boost button** | Bottom-right, above minimap | 56 px visual / 72 px hit. Fills with a radial "fuel" indicator representing distance to `MIN_BOOST_MASS`. Dims and desaturates when unavailable. |
| **Kill feed** | Right edge, mid | Transient. `<killer> ✕ <victim>` with both colors, 2.2 s hold. |
| **Threat indicators** | Screen edges | When an enemy head is off-screen and closing, a colored arc glows at the corresponding screen edge; intensity ∝ threat. Off in Reduced Motion? No — this is gameplay-critical and stays on. |
| **Pause** | Top-left corner, small | Solo Mode only. Multiplayer has no pause; it offers a Settings sheet that does not stop the match. |

> [!NOTE]
> **HUD opacity budget:** total HUD coverage must not exceed **14% of screen area**, and no HUD element may sit in the central 40% of the screen. Twenty-five snakes need room to be read.

## 19.2 Menu Structure

```
MAIN MENU
├── PLAY
│   ├── Create Room ──► Arena ──► Difficulty ──► Invite ──► Lobby
│   ├── Join Room   ──► Enter Code ──► Lobby
│   └── Solo Mode   ──► Arena ──► Bot Count ──► Difficulty ──► Play
├── LOCKER
│   ├── Skins
│   ├── Trails
│   ├── Death Effects
│   └── Nameplates
├── PROGRESS
│   ├── Level & XP
│   ├── Achievements
│   ├── Statistics
│   └── Daily Rewards
├── LEADERBOARDS
│   ├── Friends
│   ├── Weekly
│   └── All-Time
└── SETTINGS
    ├── Controls
    ├── Graphics
    ├── Audio
    ├── Accessibility
    └── Account
```

## 19.3 Key Screen Specifications

### Lobby

```
┌─────────────────────────────────────────────────┐
│  ROOM  ·  A7K2M9              [copy]  [share]   │
│  ─────────────────────────────────────────────  │
│  Arena: Circle       Difficulty: Medium         │
│  Mode: Largest Snake     Timer: 5:00            │
│  ─────────────────────────────────────────────  │
│  ┌────┐┌────┐┌────┐┌────┐┌────┐                 │
│  │ ▓  ││ ▓  ││ ▓  ││ ▓  ││ ▓  │   ... 25 slots  │
│  │Alex││Sam ││Kit ││Rey ││Jo  │                 │
│  └────┘└────┘└────┘└────┘└────┘                 │
│                                                 │
│  8 players · 17 filling                         │
│  ─────────────────────────────────────────────  │
│            ╭──────────────────╮                 │
│            │   START MATCH    │                 │
│            ╰──────────────────╯                 │
└─────────────────────────────────────────────────┘
```

- Player slots fill with a scale-in and a colored ring sweep.
- Empty slots show a soft breathing placeholder; they convert to filled slots at `LOCKING` with the same animation as a human join.
- Host-only controls are visually distinguished but always present (disabled state for non-hosts, never hidden — hidden controls confuse).
- The **START MATCH** button pulses gently when at least 2 humans are present.

### Results Panel

| Section | Content | Animation |
|---|---|---|
| Header | Placement (1st / 2nd / …) + wordmark | Scale-in, `easeOutBack` |
| Final ranking | Top 5 + player row | 50 ms stagger |
| Score breakdown | Food, kills, survival, placement | Rows count up sequentially, 300 ms each |
| XP bar | Fill + level indicator | `easeOutQuart`, 1.2 s, glow at leading edge |
| Rewards | Coin/cosmetic cards | 3D flip, 120 ms stagger |
| Actions | Rematch / Menu | Slide up last, spring |

---

# 20. Networking & Synchronization

## 20.1 Model

**Server-authoritative with client-side prediction and entity interpolation.**

| Layer | Rate | Responsibility |
|---|---|---|
| Server simulation | 30 Hz | Authoritative movement, collision, death, food, bots |
| Client render | 60 Hz | Prediction, interpolation, all presentation |
| Client → Server | 20 Hz | Input (heading + boost flag) |
| Server → Client | 15 Hz | Delta-compressed world state, AOI-filtered |

## 20.2 Data Flow

```
   CLIENT                          SERVER
   ──────                          ──────
   Sample input (60Hz)
        │
        ├──► Apply LOCALLY, immediately  ← Pillar 1
        │    (predicted head position)
        │
        ├──► Buffer in pending-inputs
        │
        └──► Send {seq, heading, boost} ──►  Receive, validate
                                             (heading rate-limited to
                                              legal turn rate)
                                                    │
                                             Simulate 30Hz tick
                                                    │
                                             Resolve collisions
                                                    │
        Receive snapshot  ◄──────────────────  Broadcast AOI snapshot
              │                                (15Hz, delta-compressed)
              │
        Reconcile:
          · Discard acked inputs
          · If |predicted − authoritative| > 6u:
                smoothly correct over 150ms (easeOutCubic)
            else: accept prediction silently
              │
        Interpolate remote snakes 100ms in the past
              │
        Render at 60Hz
```

## 20.3 Client-Side Prediction

The local player's snake **never waits for the server**. Input is applied on the frame it is sampled. When a server snapshot arrives:

1. Rewind to the server's authoritative state at sequence `N`.
2. Re-apply all locally-buffered inputs with sequence `> N`.
3. Compare the result to the current predicted state.
4. If divergence ≤ **6 u**, do nothing — the prediction was good.
5. If divergence > 6 u, blend the correction in over **150 ms** with `easeOutCubic`.

> [!WARNING]
> **Never snap the local snake to a corrected position.** Even a 20 u snap is instantly visible and reads as lag. Always blend. The only exception is death, where the position no longer matters, and respawn, where the snake is not yet visible.

## 20.4 Entity Interpolation

Remote snakes render **100 ms in the past**, interpolating between the two most recent snapshots that bracket the render time. This costs 100 ms of visual staleness in exchange for perfectly smooth remote motion, which is the correct trade for this game — you are steering around bodies, not shooting at heads.

If the buffer runs dry (packet loss), **extrapolate** for up to 200 ms along the last known velocity, with confidence decaying so the snake gently slows rather than continuing forever. Beyond 200 ms, hold position and fade the snake's rim to signal uncertainty.

## 20.5 Lag Compensation

| Mechanism | Purpose |
|---|---|
| **Input timestamping** | Every input carries a client timestamp and a sequence number |
| **Server rewind** | For collision resolution, the server rewinds up to 200 ms to the shooter's view |
| **Rewind cap** | Hard cap at 200 ms — beyond that, the high-latency player is disadvantaged rather than everyone else being punished |
| **Grace window** | A death is confirmed only if the collision holds true in both the rewound and current frames, eliminating "I was already past them" deaths |
| **Adaptive interpolation delay** | Interpolation buffer grows to `RTT/2 + jitter × 2`, capped at 250 ms |

## 20.6 Bandwidth Optimization

| Technique | Saving |
|---|---|
| **Area of Interest** | Only entities within 1.6× the client's viewport are sent | ~70% |
| **Delta compression** | Only changed fields vs the client's last-acked snapshot | ~55% |
| **Quantization** | Positions to 0.25 u (16-bit), headings to 1/256 turn (8-bit) | ~50% |
| **Path deltas** | Snake bodies sent as head position + heading history, not full point lists | ~85% on long snakes |
| **Food batching** | Food sent as regional bitmasks; only newly-spawned/eaten pellets are itemized | ~90% |
| **Bot delegation** | Bot *inputs* are simulated server-side and never sent as separate entity streams | — |

**Target:** ≤ **28 KB/s** down, ≤ **3 KB/s** up in a full 25-snake match. This must hold on 3G.

## 20.7 Connection Handling

| Condition | Behavior |
|---|---|
| RTT < 80 ms | Full prediction, 100 ms interpolation |
| RTT 80–200 ms | Extended interpolation buffer, unchanged feel |
| RTT > 200 ms | "High Ping" indicator; interpolation extends to 250 ms |
| Packet loss < 5% | Invisible; extrapolation covers it |
| Packet loss > 15% | Warning indicator, extrapolation more conservative |
| Disconnect | 15 s reconnect window; snake continues under a defensive server-side autopilot |
| Reconnect success | Camera eases back to the snake over 600 ms; control returns instantly |
| Reconnect failure | Snake dies, converts to food normally, player sees results |

> [!NOTE]
> The 15-second **autopilot** is important. A player whose train enters a tunnel should not automatically lose a 4-minute match. Autopilot runs the `SURVIVE` branch of the bot tree only — it avoids danger, eats nothing, and never attacks. It keeps you alive; it does not play for you.

---

# 21. Technical Architecture & Performance

## 21.1 Frame Budget (60 FPS = 16.67 ms)

| System | Budget | Notes |
|---|---|---|
| Input sampling | 0.2 ms | Top of frame, always |
| Simulation step | 2.5 ms | Movement, spline update |
| Collision detection | 2.0 ms | Spatial hash, broad + narrow phase |
| AI (24 bots, staggered) | 2.0 ms | ~4 bots evaluated per frame |
| Network processing | 1.0 ms | Deserialize, reconcile, interpolate |
| Animation | 1.5 ms | Splines, easing, procedural motion |
| Particles | 1.5 ms | Pooled, GPU-simulated where possible |
| Rendering | 4.5 ms | Batched, instanced |
| UI | 0.8 ms | Dirty-flag only |
| **Total** | **16.0 ms** | 0.67 ms headroom |

## 21.2 Object Pooling

> [!IMPORTANT]
> **Zero runtime allocation during a match.** Every object that can be created during gameplay is pre-allocated at match start and recycled. A single GC pause is a dropped frame, and a dropped frame during a boost commit is a lost match.

| Pool | Pre-allocated | Growth Policy |
|---|---|---|
| Food pellets | 4,000 | Grow by 500, never shrink mid-match |
| Snake segments | 12,000 | Shared across all snakes |
| Particles | 3,000 | Fixed; oldest recycled when exhausted |
| Trail ribbons | 25 | One per possible snake |
| Damage/kill notifications | 12 | Fixed |
| Audio voices | 32 | Fixed |
| Network snapshot buffers | 64 | Ring buffer |

Pool warm-up occurs during the `LOCKING` and `COUNTDOWN` states (3.5 s) — long enough to allocate everything before the first gameplay frame.

## 21.3 Spatial Partitioning

A **uniform spatial hash** is used, not a quadtree. Rationale: entities are small, numerous, uniformly distributed, and move every frame — quadtree rebalancing costs more than it saves.

| Property | Value |
|---|---|
| Cell size | 120 u (≈ 8.5× body radius) |
| Grid | Hash map, sparse |
| Rebuild | Incremental — entities move between cells on position change |
| Queries | Head collision checks only the 9 cells around the head |
| Food queries | Radius query across ⌈r/120⌉² cells |

```
   Spatial hash query for one head:

   ┌────┬────┬────┐
   │    │    │    │     Only these 9 cells are searched.
   ├────┼────┼────┤     With 25 snakes × ~200 segments = 5,000
   │    │ ●  │    │     bodies in the arena, a typical query
   ├────┼────┼────┤     examines 8–20 candidates instead of 5,000.
   │    │    │    │
   └────┴────┴────┘     ~250× reduction.
```

## 21.4 Rendering Optimization

| Technique | Application |
|---|---|
| GPU instancing | All food pellets in one draw call; all snake segments in one per-material call |
| Texture atlas | Single 2048² atlas for all gameplay sprites |
| Batched trails | All 25 trail ribbons in one dynamic mesh, rebuilt per frame |
| Frustum culling | Off-screen snakes skip segment mesh generation entirely (still simulated) |
| Segment LOD | Snakes >1,000 u from camera render at 1/3 spline sample density |
| Shader complexity | Single über-shader with keyword variants; no per-object material instances |
| Overdraw control | Additive effects capped; bloom threshold tuned to avoid full-screen HDR blowout in 25-snake fights |
| Resolution scaling | Dynamic 0.75×–1.0× render scale, driven by a rolling frame-time average |

**Target draw calls:** ≤ 45 per frame in a full match.

## 21.5 Mobile & Battery Optimization

| Technique | Effect |
|---|---|
| Adaptive resolution | Drops render scale before dropping framerate |
| Thermal monitoring | On thermal warning: step down VFX LOD, then render scale, then cap to 30 FPS as a last resort |
| Menu framerate cap | 30 FPS in all non-gameplay screens |
| Background suspension | Full simulation pause + audio release when backgrounded |
| Texture compression | ASTC on both platforms |
| Audio | Decompress-on-load for SFX; stream music |
| Network batching | One coalesced send per 50 ms rather than per-event sends — radio wake-ups are a major battery cost |
| Screen brightness | Never overridden |

**Battery target:** ≤ 9% drain per 30 minutes of continuous play on a mid-tier device.

## 21.6 Device Tiers

| Tier | Example Class | Settings |
|---|---|---|
| **High** | Recent flagship | 60 FPS (120 opt-in), full VFX, 1.0× resolution, all post-processing |
| **Medium** | 2–3 year old mid-range | 60 FPS, 60% VFX, 0.85× resolution, bloom only |
| **Low** | Budget / older | 60 FPS target with 30 FPS floor, 30% VFX, 0.7× resolution, no post-processing |

> [!TIP]
> **Framerate is the last thing to sacrifice.** A player will accept fewer particles and a softer image without noticing. They will notice 45 FPS immediately, and they will blame the game rather than their device. Degrade visual fidelity aggressively before touching the frame target.

---

# 22. Collision Detection

## 22.1 Overview

Collision is checked **only for snake heads**. Bodies are passive. This reduces the problem from O(n²) segment-pairs to O(heads × localSegments), which is the single largest performance win in the entire simulation.

```
 For each snake head (25 max):
   ├─► Broad phase: query the 9 surrounding spatial-hash cells
   │
   ├─► Narrow phase A — Border
   │     signed distance from head center to arena boundary
   │     if (distance - headRadius <= 0) → BORDER DEATH
   │
   ├─► Narrow phase B — Bodies
   │     for each candidate segment NOT belonging to self:
   │        swept circle-circle vs the segment's capsule
   │        if overlap → BODY DEATH
   │
   ├─► Narrow phase C — Heads
   │     for each other head in range:
   │        if overlap → resolve per rule 4.1
   │
   └─► Narrow phase D — Food
         circle query at magnetizeRadius (28u)
         collect all overlapping pellets
```

## 22.2 Continuous Collision Detection

At 420 u/s boost speed and a 30 Hz tick, a head travels **14 u per tick** — larger than its own radius. Discrete point-checks would tunnel through thin bodies.

**Solution: swept collision.** Each tick, the head's motion is treated as a capsule from `prevPos` to `newPos` with radius `headRadius`, tested against body segment capsules.

```
   Discrete (WRONG):        Swept (CORRECT):

   ●         ●              ●━━━━━━━━━━●
   │         │              ╰──capsule──╯
   ▓▓▓▓▓  ← missed!         ▓▓▓▓▓  ← detected
```

The same applies to border checks: the swept segment is tested against the boundary curve, not just the endpoint.

## 22.3 Border Collision by Shape

| Shape | Test | Cost |
|---|---|---|
| Circle | `length(head − center) + headRadius ≥ radius` | Trivial |
| Oval | Ellipse SDF, or transform to unit circle space | Cheap |
| Square | Per-axis AABB test | Trivial |
| Hexagon | Max of 6 half-plane distances | Cheap |
| Stadium | Distance to a line segment, compared to radius | Cheap |
| Custom | Precomputed SDF texture, bilinear sampled | Constant-time |

> [!TIP]
> Using a **precomputed signed distance field** for custom arenas makes arbitrary map shapes cost exactly the same as a circle. Bake the SDF at build time at 4 u/texel resolution. This is what makes user-generated or seasonal maps feasible without any per-shape collision code.

## 22.4 Self-Collision Exclusion

A snake's own segments are excluded from its head's body-collision candidates. Implementation: each segment stores its `ownerId`; the narrow phase skips any candidate where `ownerId == self.id`.

This is a rule, not an optimization — self-collision is explicitly safe (R6) and snakes are expected to coil tightly, especially in the endgame.

## 22.5 Determinism

The server simulation must be **deterministic** given the same inputs, so that Solo Mode's client simulation and the server simulation share one code path and one behavior.

| Requirement | Implementation |
|---|---|
| Fixed timestep | 1/30 s exactly; accumulator pattern, never variable dt |
| Deterministic math | Fixed iteration order; no floating-point reduction reordering |
| Seeded RNG | One seeded PRNG per match, threaded explicitly — no global random |
| Stable ordering | Entities processed in ascending ID order, always |
| No frame-rate dependence | Simulation never reads render dt |

---

# 23. Progression, Cosmetics & Meta

## 23.1 Player Progression

XP is earned every match, win or lose.

```
matchXP = (score / 10)
        + (kills * 25)
        + (placement bonus)
        + (survivalSeconds / 4)
        × modeMultiplier          // Solo = 0.5, Multiplayer = 1.0
        × firstWinOfDay ? 2.0 : 1.0
```

| Level Band | XP per Level | Typical Unlocks |
|---|---|---|
| 1–10 | 500 | Base skins, first trail |
| 11–25 | 1,200 | Color variants, nameplates |
| 26–50 | 2,500 | Patterned skins, death effects |
| 51–75 | 4,000 | Animated skins |
| 76–100 | 6,000 | Prestige cosmetics |
| 100+ | 8,000 | Prestige levels, badge tiers |

> [!IMPORTANT]
> **Progression unlocks cosmetics only.** No level, purchase, or reward may alter speed, turn rate, starting mass, boost economy, or collision size. Rule R1 (equal start) is absolute and applies to every player at every level forever.

## 23.2 Cosmetic Skins

| Category | Description | Examples |
|---|---|---|
| **Body skins** | Pattern and material of the snake body | Solid, Striped, Gradient, Scales, Circuit, Galaxy, Holographic, Liquid Metal |
| **Head accessories** | Small decorations on the head | Crown, Visor, Horns, Halo, Flame |
| **Trails** | Boost trail appearance | Standard, Fire, Ice, Rainbow, Void, Lightning, Petals |
| **Death effects** | The dissolve VFX variant | Standard, Shatter, Vaporize, Bloom, Implosion, Fireworks |
| **Nameplates** | Frame and font of the name label | Tiered by level and achievement |
| **Emotes** | Lobby-only expressive animations | Wave, Taunt, Coil, Spin |

**Hard constraints on all cosmetics:**

| Constraint | Rule |
|---|---|
| Silhouette | Must not change the snake's collision silhouette by even 1 u |
| Readability | Must remain distinguishable from all 24 other colors |
| Brightness | Capped — no skin may be brighter than the player-highlight tier |
| Visibility | Head accessories must never obscure the head's leading edge |
| Performance | Every skin must render within the same draw-call budget |

## 23.3 Daily Rewards

A 7-day rotating cycle that resets if a day is missed (a soft reset to day 1, with a one-time "streak restore" available).

| Day | Reward |
|---|---|
| 1 | 100 coins |
| 2 | 150 coins |
| 3 | Trail (rotating) |
| 4 | 250 coins |
| 5 | XP boost (2× for 3 matches) |
| 6 | 400 coins |
| 7 | Premium skin (rotating) |

**Presentation:** the daily reward is a card-flip sequence with a full-screen shimmer, staged reveal, and a satisfying weight to the final card. It must feel disproportionately good relative to its value — this is a retention mechanic and its animation quality is the mechanic.

## 23.4 Achievements

| Achievement | Requirement | Tier |
|---|---|---|
| First Blood | Get your first kill | Bronze |
| Centurion | Reach 100 length | Bronze |
| Survivor | Win a Last Survivor match | Silver |
| Titan | Reach 400 length | Gold |
| Untouchable | Win without dying once | Gold |
| Executioner | 10 kills in one match | Gold |
| Wall Artist | Force 5 border deaths in one match | Silver |
| Efficient | Win with under 10 s of total boost | Silver |
| Marathon | Play 100 matches | Silver |
| Perfectionist | Win on every arena shape | Platinum |
| Apex | Reach level 100 | Platinum |
| Kingmaker | Hold largest snake for 3 continuous minutes | Gold |

Achievement unlock presentation: a slide-in banner (`easeOutBack`), tier-colored particle burst, distinct audio sting per tier, and a persistent badge on the player's nameplate.

---

# 24. Statistics & Leaderboards

## 24.1 Tracked Statistics

| Category | Metrics |
|---|---|
| **Lifetime** | Matches played, wins, win rate, total kills, total deaths, K/D, total food eaten, total distance travelled, total playtime |
| **Records** | Longest snake, most kills in a match, longest survival, highest single-match score, longest win streak |
| **Per-arena** | Matches, wins, win rate, average placement, favorite arena |
| **Per-mode** | Largest Snake vs Last Survivor splits |
| **Behavioral** | Average boost usage, boost-to-kill conversion rate, border deaths vs body deaths, average time to first kill |

The behavioral stats are surfaced to players as a lightweight "playstyle" summary (e.g. *Aggressive Hunter*, *Patient Grower*, *Boost Specialist*) — cheap to compute, highly shareable, strongly retentive.

## 24.2 Leaderboards

| Board | Scope | Reset | Ranking Metric |
|---|---|---|---|
| **Friends** | Social graph | Never | Total XP |
| **Weekly** | Global | Monday 00:00 UTC | Weekly score |
| **All-Time** | Global | Never | Lifetime score |
| **Room History** | Per-room | Per-session | Match wins in that room |

Solo Mode results are **excluded** from Weekly and All-Time boards to preserve integrity, but count toward Friends and personal records.

**Leaderboard presentation:** rows stagger in 40 ms apart. The player's own row is pinned to the bottom edge when scrolled out of view, with a smooth dock/undock transition. Rank changes since last view animate with an up/down arrow and a color pulse.

---

# 25. Edge Cases

Every case below must have an explicit, tested behavior. Ambiguity here becomes a bug report.

## 25.1 Gameplay

| Case | Behavior |
|---|---|
| Two heads collide, exactly equal mass | Both die (within the 5% band). Shared shockwave VFX. Neither is credited a kill. |
| Head touches border and body simultaneously | **Border takes priority** in the kill feed and audio (the border sound is more informative). |
| Snake dies while a food-flight animation is in progress | Mass was already credited at frame 0. The in-flight pellet is returned to the pool immediately, no visual pop. |
| Boost held while mass hits the floor | Boost cuts out with the ramp-down animation and a "denied" thump. Player is not punished further. |
| Snake fully coiled on itself | Legal and safe. No collision. Rendering must not z-fight — use a stable per-snake depth offset. |
| Snake spawns where food already exists | Food is displaced outward by 40 u with a 200 ms ease. Never destroyed. |
| Two snakes claim the same pellet in one tick | Resolved by ascending entity ID for determinism. The loser's magnetize animation reverses over 100 ms rather than snapping. |
| Player's mass exceeds the segment pool | Hard cap at 1,200 segments. Additional mass increments score but not visual length. Astronomically unlikely; must not crash. |
| Arena contracts (endgame) into a snake's body | Body segments outside the new boundary are silently trimmed and converted to food. Only the **head** touching the boundary kills. |
| All bots die, one human remains, timer left | Largest Snake: the match continues (free farming). Last Survivor: immediate victory. |
| Zero humans remain (all disconnected) | Match auto-terminates after 20 s; room returns to lobby. |

## 25.2 Room & Lobby

| Case | Behavior |
|---|---|
| Human joins during `COUNTDOWN` | Allowed. One bot is removed, and the human takes that bot's slot and color. |
| Human joins during `ACTIVE` | Not allowed. Offered Spectate + auto-join next match. |
| Host disconnects in lobby | Host migrates to the longest-tenured player. Settings are preserved. A toast announces the change. |
| All humans leave mid-match | Server terminates after 20 s. No results are recorded. |
| Room code collision | Server generates codes from a namespace with active-collision checking; a collision retries transparently. |
| Player kicked | Immediate removal, returned to menu with a clear message. Cannot rejoin that room for 5 minutes. |
| Rematch with different player count | Bot count recalculates automatically. Arena resizes per 7.3. Colors are re-shuffled. |

## 25.3 Network

| Case | Behavior |
|---|---|
| Disconnect mid-match | Snake enters defensive autopilot for 15 s. Reconnect within that window resumes control instantly. |
| Reconnect after 15 s | Snake has died and converted to food normally. Player sees the results screen. |
| Extreme lag spike (>500 ms) | Client extrapolates 200 ms, then freezes remote snakes with a fading rim. Local prediction continues so the player still feels in control. |
| Server tick overrun | Simulation drops to 20 Hz temporarily; clients extend interpolation to compensate. Logged as a critical metric. |
| Client clock drift | Server timestamps are authoritative; the client maintains an offset estimate with outlier rejection. |
| Duplicate/out-of-order packets | Sequence numbers; older-than-latest snapshots are discarded silently. |
| Mid-match app backgrounding | Simulation pauses locally; on return, the client fast-forwards via the latest snapshot with a 400 ms camera ease. Server-side, autopilot covers the gap. |

## 25.4 Device & Platform

| Case | Behavior |
|---|---|
| Incoming call mid-match | Audio ducks and releases; the match continues under autopilot; a resume prompt appears on return. |
| Low battery mode engaged | Auto-drop to Medium VFX tier with a non-blocking toast. |
| Thermal throttling | Progressive degradation per 21.5. Framerate is protected until last. |
| Screen rotation | Supported. Layout reflows with a 300 ms animated transition; gameplay is uninterrupted. |
| Notch / dynamic island / cutouts | HUD respects safe areas on every device. No element within 8 pt of a cutout. |
| Very small screen (< 4.7") | HUD scales to 88%; minimap can be collapsed by the player. |
| Tablet / very large screen | Camera zoom compensates so the visible arena area is comparable to phone. Controls anchor to the thumb regions, not to screen corners. |

---

# 26. Developer Notes

Practical guidance from design to the implementing team. These are the decisions most likely to be misread from the spec alone.

## 26.1 Build Order

| Milestone | Contents | Success Criterion |
|---|---|---|
| **M1 — Feel Prototype** | One snake, one circular arena, steering, boost, food, camera. No networking, no UI, no bots. | *Steering a snake around an empty arena is already fun.* If this is not true, stop and fix it before anything else. |
| **M2 — Combat Core** | Collision, death, conversion to food, respawn. Placeholder VFX. | A death reads clearly and feels fair. |
| **M3 — Bots** | Full behavior tree, three tiers, personalities, spawn logic. | A Medium bot is mistakable for a human over a 60 s observation. |
| **M4 — Networking** | Server sim, prediction, interpolation, rooms. | 25 snakes at 150 ms RTT feel identical to Solo Mode. |
| **M5 — Presentation** | Full animation bible, VFX catalogue, audio, HUD. | The game looks and sounds finished. |
| **M6 — Meta** | Progression, cosmetics, leaderboards, dailies. | Retention loop closes. |
| **M7 — Polish & Optimization** | Device tiers, LOD, battery, accessibility, edge cases. | Passes all budgets on a Low-tier device. |

> [!IMPORTANT]
> **Do not begin M5 before M1 passes its criterion.** The most common failure mode for this genre is a beautiful game with mushy controls. Feel is not a polish-phase concern; it is the foundation, and it is very difficult to retrofit.

## 26.2 Common Pitfalls

| Pitfall | Consequence | Prevention |
|---|---|---|
| Segments as follow-chains | Wobble, desync, framerate dependence | Sample a spline (8.1) |
| Input in the physics callback | Feels laggy at 60 Hz | Sample on render frame (13.2) |
| Snapping network corrections | Reads as lag | Blend over 150 ms (20.3) |
| Uniform bot decisions per frame | Periodic 10 Hz stutter | Round-robin stagger (15.7) |
| Runtime allocation | GC hitches | Pool everything (21.2) |
| Discrete collision at boost speed | Tunneling through bodies | Swept capsules (22.2) |
| Similar snake colors | Unfair deaths, player anger | ΔE ≥ 22 enforcement (8.3) |
| Blocking input on animation | Feels unresponsive | Interactive from frame 1 (16.8) |
| Bots that cheat | Detected quickly, destroys trust | Identical physics (15) |
| Death animation gating the death | Desyncs, exploits | Kill at t=0, animate after (11.3) |
| Synchronized food pulse | Looks like a screensaver | Hash-offset phases (9.3) |
| Speed scaling with length | Late game becomes helpless | Constant speed (8.2) |

## 26.3 Tuning Philosophy

Expose these as live-tunable values in a developer overlay. They **will** change dozens of times during playtesting, and requiring a rebuild for each change will cost weeks:

- Base speed, boost multiplier, turn rates
- Boost drain rate and minimum mass
- Segment spacing, growth curve constants
- Camera damping, lookahead, zoom curve
- Per-tier bot reaction time, perception radius, aggression
- Food spawn density and replenish rate
- Trauma values for every shake source

## 26.4 QA Focus Areas

| Area | Specific Tests |
|---|---|
| Color assignment | 10,000 generated matches, assert ΔE ≥ 22 for every pair, in every colorblind mode |
| Collision | Automated tunneling test: boost at max speed through bodies at every approach angle |
| Determinism | Same seed + same inputs → identical outcome, client vs server, 1,000 runs |
| Network | Simulated 300 ms RTT, 10% loss, 80 ms jitter — game must remain playable |
| Pools | Instrument allocations; assert zero managed allocations during `ACTIVE` |
| Thermal | 45-minute continuous session on a Low-tier device; framerate must hold |
| Edge cases | Every row in section 25 has a corresponding automated or scripted manual test |
| Accessibility | Full playthrough in each colorblind mode and with Reduced Motion enabled |

## 26.5 Analytics to Instrument

Ship these from the first playable — they answer the design questions that playtesting alone cannot:

| Event | Why |
|---|---|
| Death cause distribution (border / body / head-on) | Is the border too punishing? |
| Boost usage per match, boost-to-kill conversion | Is boost priced correctly? |
| Time-to-first-death, per skill bracket | Onboarding difficulty |
| Match length distribution per mode | Are timers set right? |
| Bot difficulty selection distribution | Is Medium actually the right default? |
| Rematch rate | The single best proxy for whether the game is fun |
| Session length and matches per session | Retention health |
| Frame time p95 and p99 by device model | Where optimization effort should go |

---

# 27. Future Expansion

Ideas deliberately scoped **out** of v1.0, recorded here so architecture can accommodate them without rework.

## 27.1 Near-Term

| Feature | Description | Architectural Prerequisite |
|---|---|---|
| **Team Mode** | 2–5 teams; teammates pass through each other harmlessly | Collision must already support an owner/team filter |
| **Custom Map Editor** | Player-authored arenas with interior obstacles | SDF-based collision (22.3) already makes this cheap |
| **Mega Food** | High-value pellets that spawn periodically at contested points | Food type field is already in the data model |
| **Tournament Rooms** | Multi-match brackets within one room | Room state machine needs a `SERIES` wrapper |
| **Spectator Broadcast** | A shareable spectate link for non-participants | AOI system already supports arbitrary viewpoints |
| **Replays** | Deterministic input recording and playback | Determinism (22.5) is the whole requirement |

## 27.2 Longer-Term

| Feature | Description |
|---|---|
| **Interior Obstacles** | Pillars, moving walls, and one-way gates inside the arena |
| **Environmental Hazards** | Slow zones, speed pads, gravity wells — cosmetically themed per arena |
| **Seasonal Arenas** | Time-limited themed maps with unique ambient effects |
| **Clans / Guilds** | Persistent social groups with shared progression and private rooms |
| **Daily Challenges** | Rotating modifiers (double boost cost, no boost, tiny arena) |
| **Ranked Ladder** | Opt-in competitive mode with MMR — would require public matchmaking, a deliberate departure from R12 and therefore a product-level decision |
| **Cross-Platform Play** | Desktop and web clients sharing the same server |
| **Snake Trails as Terrain** | A mode where boost trails leave temporary lethal walls |

> [!NOTE]
> **Ranked mode is the one item on this list that conflicts with a core rule.** R12 (invite-only, no public matchmaking) is a deliberate product identity choice, not a technical limitation. If ranked play is ever pursued, it must be scoped as an explicitly separate mode rather than as a change to the existing room system — the private-room experience is the product.

---

# 28. Appendix: Tuning Tables

## 28.1 Master Constants

| Constant | Value | Section |
|---|---|---|
| `BASE_SPEED` | 240 u/s | 8.2 |
| `BOOST_SPEED` | 420 u/s | 8.2 |
| `BOOST_MULTIPLIER` | 1.75× | 10.1 |
| `TURN_RATE_BASE` | 260 °/s | 8.2 |
| `TURN_RATE_BOOST` | 195 °/s | 8.2 |
| `SEGMENT_SPACING` | 14 u | 8.2 |
| `HEAD_RADIUS` | 11 u | 8.2 |
| `BODY_RADIUS_BASE` | 10 u | 8.2 |
| `STARTING_MASS` | 10.0 | 8.4 |
| `MIN_BOOST_MASS` | 12.0 | 10.1 |
| `BOOST_DRAIN` | 3.57 mass/s | 10.1 |
| `MAGNETIZE_RADIUS` | 28 u | 9.4 |
| `BASE_ARENA_RADIUS` | 2,400 u (25p) | 7.3 |
| `WARNING_FIELD_WIDTH` | 120 u | 7.4 |
| `GLOW_BAND_WIDTH` | 40 u | 7.4 |
| `CAMERA_LOOKAHEAD` | 90 u | 14.1 |
| `CAMERA_DAMPING` | λ 6.5 | 14.1 |
| `ZOOM_DAMPING` | λ 2.2 | 14.2 |
| `TRAUMA_DECAY` | 1.6 /s | 14.4 |
| `SPATIAL_CELL_SIZE` | 120 u | 21.3 |
| `SERVER_TICK` | 30 Hz | 20.1 |
| `SNAPSHOT_RATE` | 15 Hz | 20.1 |
| `INPUT_RATE` | 20 Hz | 20.1 |
| `INTERP_DELAY` | 100 ms | 20.4 |
| `RECONCILE_THRESHOLD` | 6 u | 20.3 |
| `MAX_REWIND` | 200 ms | 20.5 |
| `COLOR_MIN_DELTA_E` | 22 | 8.3 |

## 28.2 Animation Timing Reference

| Animation | Duration | Curve |
|---|---|---|
| Food collection flight | 180 ms | Bézier + `easeOutQuad` |
| Head gulp | 120 ms | `easeOutBack` |
| Growth bulge propagation | 350 ms | linear travel, decaying amplitude |
| Tail extension | 150 ms | `easeOutCubic` |
| Boost ramp up | 120 ms | `easeOutQuad` |
| Boost ramp down | 220 ms | `easeOutCubic` |
| Death sequence (total) | 900 ms | multi-phase |
| Death flash | 120 ms | `easeOutExpo` |
| Death fracture | 300 ms | staggered 8 ms/segment |
| Spawn sequence | 600 ms | multi-phase, control at 460 ms |
| Respawn sequence | 600 ms | multi-phase, control at 450 ms |
| Network correction blend | 150 ms | `easeOutCubic` |
| UI entrance | 240 ms | `easeOutCubic` |
| UI exit | 160 ms | `easeInBack` |
| Panel slide | 320 ms | soft spring |
| Countdown numeral | 600 ms each | `easeOutExpo` |
| Victory cinematic | 4,000 ms | `easeInOutCubic` |
| Defeat sequence | 3,000 ms | `easeOutCubic` |
| XP bar fill | 1,200 ms | `easeOutQuart` |
| Kill notification | 2,200 ms hold | `easeOutBack` / `easeInBack` |

## 28.3 Performance Targets Summary

| Metric | Target |
|---|---|
| Framerate | 60 FPS locked (120 opt-in on capable hardware) |
| Frame budget | 16.0 ms of 16.67 ms |
| Draw calls | ≤ 45 |
| Managed allocations during match | 0 |
| AI CPU (24 bots) | ≤ 2.0 ms/frame |
| Collision CPU | ≤ 2.0 ms/frame |
| Bandwidth down | ≤ 28 KB/s |
| Bandwidth up | ≤ 3 KB/s |
| Battery | ≤ 9% per 30 min |
| Cold start to menu | ≤ 3.0 s |
| Match load | ≤ 1.5 s |
| Input-to-visual latency | ≤ 16 ms |

---

## Document Sign-Off

| Discipline | Reviews For |
|---|---|
| Design | Rules, balance, pillars, win conditions |
| Engineering | Networking, performance, collision, determinism |
| Art | Palette, themes, readability, LOD |
| Animation | Sections 16–17 in full |
| Audio | Section 18 |
| UX | Sections 13, 19, accessibility |
| Production | Build order (26.1), scope boundaries (27) |

> [!IMPORTANT]
> **The four pillars in Section 2 are the tiebreaker for every decision in this document.** When a proposed change improves one thing at the cost of another, resolve it by pillar order: Instant Response, then Fluid Motion, then Readable Chaos, then Fair Competition. If a change violates Pillar 1, it does not ship.

---

*End of document — Snake Battle GDD v1.0*
