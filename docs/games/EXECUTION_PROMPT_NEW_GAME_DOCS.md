# Execution prompt — write the design docs for the eight future games

> Paste this to an AI agent working in the Voiid repo.
>
> **This task produces DOCUMENTS ONLY. Write no game code.** The output is one full design doc per game, detailed enough that a different agent could build the game from it without asking questions.

---

## The deliverable

Eight new files under `docs/games/future/`, one per game:

| File | Game | Kind |
|---|---|---|
| `VOIID_RUN.md` | **Voiid Run** — endless runner, Temple Run / Subway Surfers shaped | single-player, real-time |
| `SEA_BATTLE.md` | Sea Battle (Battleship) | turn-based, hidden state |
| `AIR_HOCKEY.md` | Air Hockey | continuous, 2-player physics |
| `LUDO.md` | Ludo | turn-based, 2-4 player |
| `VOIID_CARDS.md` | Voiid Cards (UNO-like) | turn-based, 2-6 player, hidden hands |
| `CHESS.md` | Chess | turn-based, deep rules |
| `ARCHERY.md` | Archery | event-driven |
| `SNOW_FIGHT.md` | Snow Fight | event-driven |

Plus `docs/games/future/README.md` indexing them with a one-line hook each, a build-order recommendation, and a short "what these games share" section.

**Do not write engine code, renderers, migrations or client screens.** If you find yourself editing anything outside `docs/games/future/`, stop.

---

## Read first — this is not optional

The architecture already exists and works. These docs must be written **against it**, not around it.

1. [`backend/games/src/engine/GameEngine.ts`](../../backend/games/src/engine/GameEngine.ts) — **the contract every game implements.** Read every comment; they encode bugs already paid for.
2. [`backend/games/src/index.ts`](../../backend/games/src/index.ts) — the runtime: tick loops, persistence cadence, broadcast, match lifecycle
3. [`backend/games/src/engine/snake/index.ts`](../../backend/games/src/engine/snake/index.ts) — the reference **continuous** game
4. [`backend/games/src/engine/cricket/index.ts`](../../backend/games/src/engine/cricket/index.ts) — the reference **simultaneous-reveal / hidden-state** game
5. [`docs/GAMES.md`](../GAMES.md) — the original architecture plan, especially §4's per-game update-rate table
6. [`docs/games/SNAKE.md`](./SNAKE.md) §2 — **the netcode failure mode you must design every real-time game against**
7. [`docs/games/SOUND_DESIGN.md`](./SOUND_DESIGN.md) — the sound palette every new game inherits
8. [`docs/games/CROSS_CUTTING.md`](./CROSS_CUTTING.md) — the meta-game gaps; every new game must not repeat them

**Anything you assert about the existing system must come from reading it.** Do not describe how you assume the runtime works.

---

## The hard architectural requirements

The user's brief: *"create plan and architecture in such a way that game is tick proof and everything without any lag and experience is loved by people."*

That is three requirements. Every doc must address all three explicitly, in its own section.

### R1 — "Tick proof": the engine must be correct regardless of tick timing

The runtime round-trips `serialize()` / `restore()` on **every input**, persists on a throttled cadence (`PERSIST_EVERY`), and may restart at any moment. `GameEngine.ts` documents two real bugs this caused:

- State omitted from `serialize()` is **silently reset on the next tick**
- Simultaneous-reveal secrets omitted from `serialize()` were **dropped a millisecond after being made** — hand cricket looped forever between two players until `serializeSecret` was added

So each doc must state:

- **The complete `serialize()` shape**, field by field, and a sentence per field on why it must survive a restart
- **Whether the game needs `serializeSecret`**, and exactly what is hidden from whom. Sea Battle (fleet positions), Voiid Cards (hands), Archery/Snow Fight (aim before release) all do
- **Whether it needs `serializeForWire`** — required for any game whose full state is bigger than what changes per frame. Snake's food field was 59% of payload before this split
- **Tick-rate independence.** A continuous engine must integrate using a **delta time**, never assume a fixed frame. If a tick is late, the game must be *correct*, not *wrong at a different speed*
- **Determinism and RNG.** Where randomness enters (Ludo dice, card shuffle, Voiid Run's obstacle generation), it must be **server-side and seeded**, with the seed in `serialize()`. A client that can predict or influence the roll is a cheat; a shuffle that doesn't survive a restart is a lost match

### R2 — "Without any lag": name the netcode model per game

**There is no single answer, and a doc that gives one is wrong.** [`GAMES.md`](../GAMES.md) §4 already sorts games into four network patterns. Each doc must state which pattern applies and why, then design against it.

**Every real-time game must explicitly address the Snake stutter** ([`SNAKE.md`](./SNAKE.md) §2): the render clock must **never be re-anchored to frame arrival time**. That bug shipped once on both platforms. Each real-time doc must specify:

- **Server tick rate**, and why that rate (bandwidth vs. responsiveness)
- **Interpolation delay**, in ticks, with the buffer-underrun tradeoff stated — 1.5 ticks was shipped and was too tight; 2.5 is the current answer
- **Free-running, rate-adjusted render clock** as a stated requirement, not an optimisation
- **What the client predicts locally**, if anything, and **how a misprediction is reconciled**. Snake already has `SnakePredictor` on both platforms — read it
- **What happens on a 3-second network stall**, concretely

**Voiid Run is the interesting case and needs its own reasoning.** It is single-player and real-time. Ask, in the doc, whether it should be server-authoritative at all:

- Server-authoritative at 60 Hz for a single-player runner is expensive and adds input latency to a game that lives on frame-perfect reactions
- Client-simulated with a **seeded, server-issued run seed** plus **server-side score validation** on submit gives zero input lag and still bounds cheating on the leaderboard
- **Recommend the second**, and say so plainly, but state the anti-cheat tradeoff honestly: a determined cheater can forge a score, and the mitigation is replay validation (submit the input trace, server re-simulates) rather than pretending client trust is safe
- This is a **deliberate, documented exception** to the "server is always the referee" rule in [`GAMES.md`](../GAMES.md) §1 — frame it that way, with reasoning, not as an oversight

### R3 — "Experience is loved by people": the retention argument

Every doc needs a section answering: **why would someone play this a second time?**

- The specific hook, named. "It's fun" is not an answer
- **How it uses the fact that this is a messenger.** A game inside a chat app that doesn't create a reason to message someone is wasting its only structural advantage over standalone game apps
- Rematch, post-match summary, and head-to-head record are **requirements from day one**, not later additions. [`CROSS_CUTTING.md`](./CROSS_CUTTING.md) documents the four shipped games missing all three — do not repeat it
- Async play where the game allows it. Sea Battle and Chess are naturally async: fire a shot, put the phone down, get a notification. That fits a messenger better than anything requiring both players present
- What the **first 30 seconds** feel like for someone who has never played it
- What a player who has played 50 matches is still chasing

---

## Required structure for each game doc

Same section order in all eight, so they are comparable. Adapt content, not structure.

```
1.  What the game is                — the pitch, and why it belongs in Voiid specifically
2.  Rules as implemented            — normative. Every house-rule variation decided, with reasons
3.  Network model                   — R2. Pattern, tick rate, interp delay, prediction, stall behaviour
4.  Engine design                   — R1. GameEngine methods, serialize shape field by field,
                                      secret/wire splits, RNG and determinism
5.  Anti-cheat                      — what a modified client can and cannot express in an input frame
6.  Client rendering                — iOS and Android approach, explicitly. Reuse before invention
7.  Controls                        — input scheme, and how it handles one-handed / small screens
8.  Visual design                   — art direction, HUD, what the player must be able to see
9.  Motion and feel                 — key animations with durations and curves
10. Sound                           — inherits SOUND_DESIGN.md, including the shared `catch` sound
11. Bots                            — difficulty as a MEANINGFUL scale, not a fake one (see below)
12. Progression and retention       — R3
13. Failure and edge cases          — disconnect, AFK, forfeit, rejoin, tie
14. Build plan                      — phased, each phase independently shippable
15. Open questions                  — things needing the user's decision. Be honest here
```

### On §11, bots

[`RpsBot.swift`](../../apps/ios/Voiid/Voiid/Games/RpsBot.swift) is the standard to match. It refuses to fake a difficulty scale: against a truly random opponent RPS has no skill, so difficulty is implemented as *exploitation of human non-randomness*, and the file says outright that skill 1.0 is **not** unbeatable because nothing can be.

Meanwhile Snake maps difficulty to **bot count only** — "hard" means more opponents of identical ability ([`SNAKE.md`](./SNAKE.md) §3.4). That is the anti-pattern.

Every doc must define what its difficulty scale actually varies, and say honestly what the top of the scale can and cannot do.

### On §6, reuse

The repo has: a Metal SDF renderer and shader for Snake, a Compose Canvas equivalent, `CricketPitch`, board grids, `GameAudio`, `GameHaptics`, a jitter buffer and camera spring on both platforms.

**Each doc must state what it reuses before what it invents.** A doc proposing a new rendering approach must argue why the existing one is insufficient. No new third-party dependencies, no game engine, no WebView — [`GAMES.md`](../GAMES.md) §4 argues this and it still holds.

---

## Per-game notes

**Voiid Run** — the hardest and highest-risk. Endless runner, single-player, 60 fps, procedural generation. Cover: the seeded generator (same seed → same run, which is what makes daily challenges and score validation possible), the three-lane vs free-movement decision, obstacle/pickup vocabulary, difficulty ramp over distance, death and revive, and the score-validation model from R2. **Also address whether it is affordable at all** — it is the only game here needing sustained 60 fps procedural rendering on both platforms, and the doc should state the honest cost against, say, Air Hockey. Recommend a position.

**Sea Battle** — [`GAMES.md`](../GAMES.md) §8 named it the best first game and it is still unbuilt. Lowest risk. Emphasise async play and the placement phase.

**Air Hockey** — inherits Snake's entire tick machinery. Specify the shared 2D physics helper that Ping Pong and Pool would later reuse. Server-authoritative physics is non-negotiable; describe the client-side smoothing.

**Ludo** — 4-player state is a real change to the invite flow, which today picks exactly one opponent. Note that this work is **shared with unlocking Snake's 3-6 player mode** and should be sequenced together. Cover dice RNG (R1), capture, home run, and turn timeouts.

**Voiid Cards** — hidden hands are a bigger `serializeSecret`. Specify exactly what each player sees of others' state (card count, not cards) and how a spectator/rejoin works without leaking.

**Chess** — be honest in §1: this is a solved market with excellent free apps, and building it here is a lot of work to be worse than lichess. The argument for it is *social* (rivalry with contacts), not chess quality. Cover the full rule set including castling, en passant, promotion, repetition and the 50-move rule, and whether to use a known move-generation library server-side.

**Archery / Snow Fight** — both event-driven, no tick loop: send angle/power, server resolves trajectory, broadcast result. They share a model; write both docs but make Snow Fight's differences explicit rather than duplicating Archery. Aim-before-release is hidden state (`serializeSecret`).

---

## Style

Match the existing docs in `docs/games/` — read two of them first.

- **Reason, don't assert.** Every non-obvious choice gets its "why". The best writing in this repo is in the code comments; match that register
- **Be specific.** Real numbers: tick rates, durations, curves, buffer sizes. "Smooth animation" is not a spec
- **Be honest about cost and risk.** If something is expensive or likely to disappoint, say so in the doc. Chess and Voiid Run both need this
- **Cite files with clickable relative links** — `[file.ts:42](../../path/file.ts#L42)`
- **Flag disagreements with existing docs** rather than silently contradicting them
- Long is fine. Vague is not

---

## Order

1. `future/README.md` skeleton — forces the shared decisions first
2. **Sea Battle** — simplest, establishes the doc template
3. **Air Hockey** — establishes the continuous/physics template
4. **Voiid Run** — hardest; do it once both templates exist
5. Ludo, Voiid Cards, Chess
6. Archery, then Snow Fight
7. Finalise `future/README.md` with build order and the shared-infrastructure section

---

## Report when done

- The eight docs plus the index, with a one-line summary each
- **Any game you concluded is not worth building**, and why — that is a valid, useful outcome
- Every open question needing the user's decision, collected in one list
- Anything in the existing architecture that would need to change to support these games (multi-player lobbies is the obvious one — call it out explicitly)
