// Snake — the first CONTINUOUS game (docs/GAMES.md §80, §137).
//
// Every rules module before this one was turn-based: state changed only inside applyInput,
// and the runtime never needed a clock. Snake is the first that must move on its own, so it
// is also the module that forced `tick()` and the runtime's per-match loop into existence.
// Air Hockey, Ping Pong and Pool inherit that machinery unchanged.
//
// SERVER-AUTHORITATIVE, CONCRETELY. A client sends exactly one thing: the heading it wants
// and whether it is holding boost. It does not send its position, its length, whether it
// ate, or whether it died — all of those are decided here. The two lies a modified client
// can tell are "I want to face this direction" and "I am boosting", and neither is a lie
// worth telling: heading is clamped to the legal turn rate below, so claiming an impossible
// angle just makes the snake turn as fast as it legally can, which it would do anyway.
//
// WHY THE STATE IS SHAPED FOR THE WIRE. Unlike the turn-based games, this state is
// broadcast 12 times a second to every player in the match, and it round-trips through
// Redis as JSON on every one of those ticks. So the serialized shape is deliberately flat
// and short-keyed, paths are trimmed to the snake's actual body length, and nothing
// derivable is stored. A pretty object model here would cost real bandwidth on a phone.
import type {
  ApplyResult,
  GameEngine,
  GameFactory,
  GameInput,
  GameOutcome,
  GameStatePayload,
} from '../GameEngine';
import {
  arenaSdf,
  clamp,
  pathLength,
  samplePath,
  segmentSegmentDist2,
  shortestAngle,
  trimPath,
  Rng,
  type ArenaShape,
  type Vec,
} from './geometry';
import { stepBot, type BotMemory } from './bot';

// --- Tuning ---------------------------------------------------------------------------
// Exported so the headless test can reason about them, and so a future dev overlay has one
// place to write to.
export const TUNING = {
  // docs/GAMES.md §80 allows ~10-15/sec. 10 is chosen at the bottom of that band because
  // bandwidth scales linearly with it and this frame is not small: 15 Hz measured 39 KB/s
  // per player against 26 at 10 Hz, for motion the client interpolates smoothly either way.
  TICK_HZ: 10,
  BASE_SPEED: 240,          // units/sec
  BOOST_SPEED: 420,
  TURN_RATE: 260,           // degrees/sec
  TURN_RATE_BOOST: 195,
  START_MASS: 10,
  MIN_BOOST_MASS: 12,
  BOOST_DRAIN: 3.57,        // mass/sec
  HEAD_RADIUS: 11,
  BODY_RADIUS: 10,
  SEGMENT_SPACING: 14,
  EAT_RADIUS: 28,
  ARENA_RADIUS: 1400,
  FOOD_TARGET: 260,
  RESPAWN_DELAY: 2.5,       // seconds
  INVULN: 1.5,              // seconds
  MAX_MASS: 600,
  MATCH_SECONDS: 180,
};

const DEG = Math.PI / 180;

/**
 * Handles for practice-mode bots.
 *
 * Plausible player names, never anything that reads as a machine: a bot labelled as a bot
 * changes how players treat it, and practice is more useful when the arena feels real.
 */
const BOT_NAMES: readonly string[] = [
  'Vex', 'Nyx', 'Kilo', 'Ora', 'Pike', 'Zeph', 'Juno', 'Rune', 'Axl', 'Wisp',
  'Bram', 'Coil', 'Dax', 'Echo', 'Fen', 'Gale', 'Hux', 'Iris', 'Jinx', 'Kade',
  'Lux', 'Mox', 'Nova', 'Onyx', 'Pax', 'Quill', 'Rig', 'Sable', 'Tor', 'Umbra',
  'Vale', 'Wren', 'Xen', 'Yara', 'Zane', 'Ash', 'Blitz', 'Cobalt', 'Drift',
  'Ember', 'Flux', 'Grit', 'Haze', 'Ion', 'Jet', 'Kestrel', 'Lark', 'Mica',
];

/**
 * Collision radius for a given mass.
 *
 * A snake now THICKENS as it eats, not just lengthens, so the radius can no longer be a
 * constant. Critically this is used for BOTH the hitbox and the drawn width (the head radius
 * is serialized): if the two ever disagreed, a fat snake would be killed by something that
 * visually missed it, which is the single most infuriating kind of unfairness in this genre.
 *
 * Linear in mass so growth is felt immediately, capped at 2.2x so a late-game snake cannot
 * fill the arena or make its own turning circle impossible.
 */
function radiusFor(mass: number, base: number): number {
  return base * Math.min(1 + Math.max(0, mass - TUNING.START_MASS) * 0.012, 2.2);
}

type DeathCause = 'border' | 'body' | 'head';

interface SnakeState {
  /** User id, or `bot:<n>` for a practice-mode bot. */
  id: string;
  bot: boolean;
  /**
   * Display handle for a bot; null for humans, whose names the client already resolves from
   * its own user directory.
   *
   * Assigned here rather than client-side so every device in a match shows the SAME name for
   * the same bot — two players comparing a leaderboard that disagreed on who was who would be
   * worse than no names at all.
   */
  name: string | null;
  x: number;
  y: number;
  /** Radians. */
  h: number;
  /** Requested heading; the turn-rate clamp is the only filter applied to it. */
  th: number;
  mass: number;
  alive: boolean;
  boost: boolean;
  /** Flattened [x0,y0,x1,y1,...], index 0 = newest. Trimmed to body length every tick. */
  path: number[];
  kills: number;
  deaths: number;
  score: number;
  /** Simulation time at which this snake respawns; 0 when alive. */
  respawnAt: number;
  /** Simulation time until which this snake cannot kill or be killed. */
  invulnUntil: number;
  /** Colour index, assigned at spawn and stable for the match. */
  color: number;
}

interface FoodItem {
  x: number;
  y: number;
  /** 1 = standard, 2 = corpse (worth more), 0.5 = boost drop. */
  v: number;
  /** Stable id, so the client can apply removals without re-sending the whole field. */
  i: number;
}

interface State {
  players: string[];
  snakes: SnakeState[];
  food: FoodItem[];
  /** Elapsed simulation seconds. */
  t: number;
  finished: boolean;
  winnerId: string | null;
  seed: number;
  arena: ArenaShape;
  arenaRadius: number;
  duration: number;
  /** Recent deaths, for client-side VFX. Cleared each broadcast. */
  events: { k: string; x: number; y: number; id: string; c?: string }[];

  // --- Food delta bookkeeping -----------------------------------------------------------
  // Food was 59% of a 7 KB payload — 300+ pellets resent 12x/sec when almost none of them
  // ever move. Only the CHANGES go on the wire now: pellets added since the last frame, and
  // the ids of pellets removed. A client that misses a frame recovers via `foodFull`, which
  // is sent periodically and on the first frame.
  nextFoodId: number;
  /** Ids eaten since the last serialize. */
  removed: number[];
  /** Items added since the last serialize. */
  added: FoodItem[];
  /** Ticks since the last full food snapshot was sent. */
  sinceFull: number;
}

/** How often a full food snapshot is sent regardless of deltas (ticks). */
const FOOD_FULL_INTERVAL = 60;

const scratch: Vec = { x: 0, y: 0 };
const scratchB: Vec = { x: 0, y: 0 };

class SnakeEngine implements GameEngine {
  private s: State;
  private rng: Rng;
  /** Bot scratch memory. Server-only and cheap to rebuild, so it is NOT serialized. */
  private botMem = new Map<string, BotMemory>();

  constructor(state: State) {
    this.s = state;
    this.rng = new Rng(state.seed);
  }

  /**
   * Place every snake and seed the food field. Called once by `create`, never by `restore` —
   * a restored match already has its world and re-running this would teleport everyone.
   */
  bootstrap(): void {
    for (const sn of this.s.snakes) this.spawnSnake(sn);
    for (let i = 0; i < TUNING.FOOD_TARGET; i++) {
      const a = this.rng.next() * Math.PI * 2;
      const rad = Math.sqrt(this.rng.next()) * (this.s.arenaRadius - 60);
      this.addFood(Math.cos(a) * rad, Math.sin(a) * rad, 1);
    }
  }

  /**
   * The ONLY way food enters the world. Centralised so the delta bookkeeping cannot be
   * forgotten at a call site — a pellet added without recording it would be invisible to
   * clients until the next full snapshot, i.e. it would flicker into existence seconds late.
   */
  private addFood(x: number, y: number, v: number): void {
    const item: FoodItem = { x, y, v, i: this.s.nextFoodId++ };
    this.s.food.push(item);
    this.s.added.push(item);
  }

  /** The only way food leaves the world. Swap-removes and records the id. */
  private removeFoodAt(index: number): void {
    const item = this.s.food[index];
    this.s.removed.push(item.i);
    this.s.food[index] = this.s.food[this.s.food.length - 1];
    this.s.food.pop();
  }

  // --- Input ---------------------------------------------------------------------------

  /**
   * The only thing a client may say: where it wants to point, and whether it is boosting.
   *
   * Note this does NOT return `accepted: false` for an out-of-range heading — it clamps and
   * accepts. Rejecting would be wrong here: unlike a chess move, a steering frame arriving
   * during a lag spike is not an attempt to cheat, and dropping it would freeze the player's
   * snake at its last heading. Clamping is both safer and kinder.
   */
  applyInput(playerId: string, input: GameInput): ApplyResult {
    if (this.s.finished) return { accepted: false };

    const snake = this.s.snakes.find((sn) => sn.id === playerId);
    if (!snake) return { accepted: false };

    const h = input.h;
    if (typeof h === 'number' && Number.isFinite(h)) {
      snake.th = h;
    }
    snake.boost = input.boost === true;

    // Steering does not itself change the world — tick() does. So an input frame is
    // accepted but produces no broadcast of its own: the next tick carries the result.
    // This is what keeps a player mashing input from amplifying into fan-out.
    return { accepted: true, silent: true };
  }

  // --- Simulation ----------------------------------------------------------------------

  tick(): { changed: boolean; outcome?: GameOutcome } {
    if (this.s.finished) return { changed: false };

    const dt = 1 / TUNING.TICK_HZ;
    this.s.t += dt;
    this.s.events.length = 0;
    // Advanced here rather than in serializeForWire() — see the note there for why.
    this.s.sinceFull++;

    // Bots decide first, so their steering lands on the same tick as a human's.
    for (const sn of this.s.snakes) {
      if (sn.bot && sn.alive) {
        let mem = this.botMem.get(sn.id);
        if (!mem) {
          mem = { targetFood: -1, retarget: 0, jitter: this.rng.next() * Math.PI * 2 };
          this.botMem.set(sn.id, mem);
        }
        stepBot(sn, mem, dt, this.s.snakes, this.s.food, this.s.arena, this.s.arenaRadius, this.rng);
      }
    }

    this.moveAll(dt);
    this.resolveCollisions();
    this.resolveEating();
    this.replenishFood();
    this.respawnDue();

    if (this.s.t >= this.s.duration) {
      return { changed: true, outcome: this.finish() };
    }

    return { changed: true };
  }

  private moveAll(dt: number): void {
    for (const sn of this.s.snakes) {
      if (!sn.alive) continue;

      // Turn-rate clamp. This is the ONLY filter on requested heading, and it is what makes
      // a lying client harmless: no matter what angle it asks for, it turns at the legal rate.
      const rate = (sn.boost && sn.mass > TUNING.MIN_BOOST_MASS
        ? TUNING.TURN_RATE_BOOST
        : TUNING.TURN_RATE) * DEG;
      const delta = shortestAngle(sn.h, sn.th);
      sn.h += clamp(delta, -rate * dt, rate * dt);

      const boosting = sn.boost && sn.mass > TUNING.MIN_BOOST_MASS;
      if (boosting) {
        sn.mass -= TUNING.BOOST_DRAIN * dt;
        // Drained mass is dropped behind as food, so boosting feeds the arena rather than
        // deleting value from it.
        if (this.rng.next() < 0.5) {
          samplePath(sn.path, Math.min(pathLength(sn.path), sn.mass * TUNING.SEGMENT_SPACING), scratch);
          this.addFood(scratch.x, scratch.y, 0.5);
        }
        if (sn.mass <= TUNING.MIN_BOOST_MASS) {
          sn.mass = TUNING.MIN_BOOST_MASS;
          sn.boost = false;
        }
      }

      const speed = boosting ? TUNING.BOOST_SPEED : TUNING.BASE_SPEED;
      sn.x += Math.cos(sn.h) * speed * dt;
      sn.y += Math.sin(sn.h) * speed * dt;

      sn.path.unshift(sn.x, sn.y);
      trimPath(sn.path, sn.mass * TUNING.SEGMENT_SPACING + TUNING.SEGMENT_SPACING);
    }
  }

  /**
   * Head-only collision (bodies are passive), swept from the previous head position.
   *
   * All deaths are computed against the SAME pre-move world: every snake's death is decided
   * before any body is removed. Resolving one snake at a time would make the outcome depend
   * on array order — the snake with the lower index would get to kill and vanish before the
   * other's test ran, so two snakes colliding head-on would produce one survivor chosen by
   * seating rather than by the rules.
   */
  private resolveCollisions(): void {
    const doomed: { snake: SnakeState; cause: DeathCause; killer: string | null }[] = [];

    for (const sn of this.s.snakes) {
      if (!sn.alive) continue;
      if (this.s.t < sn.invulnUntil) continue;
      if (sn.path.length < 4) continue;

      const prevX = sn.path[2], prevY = sn.path[3];
      // Scales with mass, and is the SAME value the client draws with (serialized as `hr`),
      // so a thick snake's hitbox and its visible body can never disagree.
      const headR = radiusFor(sn.mass, TUNING.HEAD_RADIUS);

      // Border. Sampled along the swept motion, not just at the endpoint.
      let hitBorder = false;
      for (let k = 1; k <= 3; k++) {
        const t = k / 3;
        const sx = prevX + (sn.x - prevX) * t;
        const sy = prevY + (sn.y - prevY) * t;
        if (arenaSdf(this.s.arena, this.s.arenaRadius, sx, sy) + headR >= 0) {
          hitBorder = true;
          break;
        }
      }
      if (hitBorder) {
        doomed.push({ snake: sn, cause: 'border', killer: null });
        continue;
      }

      // Head-to-head: longer survives; within 5% both die.
      let resolved = false;
      for (const other of this.s.snakes) {
        if (other.id === sn.id || !other.alive) continue;
        if (this.s.t < other.invulnUntil) continue;
        const rr = headR + radiusFor(other.mass, TUNING.HEAD_RADIUS);
        if (segmentSegmentDist2(prevX, prevY, sn.x, sn.y, other.x, other.y, other.x, other.y) <= rr * rr) {
          const ratio = Math.abs(sn.mass - other.mass) / Math.max(sn.mass, other.mass);
          if (ratio <= 0.05) {
            doomed.push({ snake: sn, cause: 'head', killer: null });
            resolved = true;
          } else if (sn.mass < other.mass) {
            doomed.push({ snake: sn, cause: 'head', killer: other.id });
            resolved = true;
          }
          break;
        }
      }
      if (resolved) continue;

      // Head into another snake's body. The MOVER dies; the snake that was hit is unharmed.
      // That asymmetry is the whole game: it is what lets a short snake kill a long one by
      // cutting in front of it, instead of length being the only thing that matters.
      const killer = this.bodyHit(sn, prevX, prevY, headR);
      if (killer) doomed.push({ snake: sn, cause: 'body', killer });
    }

    for (const d of doomed) this.kill(d.snake, d.cause, d.killer);
  }

  /** Returns the id of the snake whose body was hit, or null. Skips self (self-collision is safe). */
  private bodyHit(
    sn: SnakeState, prevX: number, prevY: number, headR: number
  ): string | null {
    for (const other of this.s.snakes) {
      if (!other.alive) continue;
      // A snake cannot die on its own body — it may coil freely. This is a rule, not an
      // optimisation, so it is expressed as an explicit skip rather than a distance check.
      if (other.id === sn.id) continue;

      const path = other.path;
      // Broad phase: bounding-radius reject before walking the polyline. Without it this is
      // O(snakes x pathPoints) every tick and dominates the tick budget once snakes are long.
      const reach = pathLength(path) + headR + radiusFor(other.mass, TUNING.BODY_RADIUS);
      const dx = other.x - sn.x, dy = other.y - sn.y;
      if (dx * dx + dy * dy > reach * reach) continue;

      const rr = headR + radiusFor(other.mass, TUNING.BODY_RADIUS);
      for (let i = 0; i + 3 < path.length; i += 2) {
        if (segmentSegmentDist2(
          prevX, prevY, sn.x, sn.y,
          path[i], path[i + 1], path[i + 2], path[i + 3]
        ) <= rr * rr) {
          return other.id;
        }
      }
    }
    return null;
  }

  private kill(sn: SnakeState, cause: DeathCause, killerId: string | null): void {
    if (!sn.alive) return;
    sn.alive = false;
    sn.deaths += 1;
    sn.boost = false;
    sn.respawnAt = this.s.t + TUNING.RESPAWN_DELAY;

    this.s.events.push({ k: 'death', x: sn.x, y: sn.y, id: sn.id, c: cause });

    // The whole body becomes food. Not a fraction — a long snake dying next to you is the
    // single biggest opportunity in the game, and scaling it down would remove the reason to
    // fight anyone larger than you.
    const step = TUNING.SEGMENT_SPACING;
    const total = pathLength(sn.path);
    for (let d = 0; d < total; d += step) {
      if (!samplePath(sn.path, d, scratchB)) break;
      this.addFood(
        scratchB.x + this.rng.range(-6, 6),
        scratchB.y + this.rng.range(-6, 6),
        2
      );
    }
    sn.path.length = 0;

    if (killerId) {
      const killer = this.s.snakes.find((k) => k.id === killerId);
      if (killer) {
        killer.kills += 1;
        killer.score += 250 + Math.floor(sn.mass * 2);
        this.s.events.push({ k: 'kill', x: sn.x, y: sn.y, id: killerId });
      }
    }
  }

  private resolveEating(): void {
    const r = TUNING.EAT_RADIUS;
    const r2 = r * r;

    for (const sn of this.s.snakes) {
      if (!sn.alive || this.s.t < sn.invulnUntil) continue;

      // Iterate backwards so swap-removal below cannot skip an item.
      for (let i = this.s.food.length - 1; i >= 0; i--) {
        const f = this.s.food[i];
        const dx = f.x - sn.x, dy = f.y - sn.y;
        if (dx * dx + dy * dy > r2) continue;

        sn.mass = Math.min(sn.mass + f.v, TUNING.MAX_MASS);
        sn.score += f.v >= 2 ? 20 : 10;
        this.s.events.push({ k: 'eat', x: f.x, y: f.y, id: sn.id });

        this.removeFoodAt(i);
      }
    }
  }

  private replenishFood(): void {
    // A floor, not a ceiling: corpse food is left alone, so a bloody match genuinely becomes
    // food-rich and the endgame accelerates.
    let standard = 0;
    for (const f of this.s.food) if (f.v === 1) standard++;
    if (standard >= TUNING.FOOD_TARGET) return;

    const deficit = TUNING.FOOD_TARGET - standard;
    const spawn = Math.min(deficit, 4);
    for (let i = 0; i < spawn; i++) {
      const a = this.rng.next() * Math.PI * 2;
      const rad = Math.sqrt(this.rng.next()) * (this.s.arenaRadius - 60);
      this.addFood(Math.cos(a) * rad, Math.sin(a) * rad, 1);
    }
  }

  private respawnDue(): void {
    for (const sn of this.s.snakes) {
      if (sn.alive || this.s.t < sn.respawnAt) continue;
      this.spawnSnake(sn);
      this.s.events.push({ k: 'spawn', x: sn.x, y: sn.y, id: sn.id });
    }
  }

  /** Place a snake at a point far from other heads, at starting mass. No catch-up bonus. */
  private spawnSnake(sn: SnakeState): void {
    let bx = 0, by = 0, best = -Infinity;
    for (let attempt = 0; attempt < 20; attempt++) {
      const a = this.rng.next() * Math.PI * 2;
      const rad = Math.sqrt(this.rng.next()) * (this.s.arenaRadius - 240);
      const px = Math.cos(a) * rad, py = Math.sin(a) * rad;

      let nearest = Infinity;
      for (const o of this.s.snakes) {
        if (o.id === sn.id || !o.alive) continue;
        const d = Math.hypot(px - o.x, py - o.y);
        if (d < nearest) nearest = d;
      }
      if (nearest === Infinity) nearest = 9999;
      if (nearest > best) { best = nearest; bx = px; by = py; }
    }

    sn.x = bx;
    sn.y = by;
    sn.h = Math.atan2(-by, -bx);
    sn.th = sn.h;
    sn.mass = TUNING.START_MASS;
    sn.alive = true;
    sn.boost = false;
    sn.respawnAt = 0;
    sn.invulnUntil = this.s.t + TUNING.INVULN;

    // Seed a body backwards along -heading, so the snake exists as a body on its first tick
    // rather than growing a tail over the following second.
    sn.path = [];
    const dx = -Math.cos(sn.h), dy = -Math.sin(sn.h);
    for (let i = 0; i <= TUNING.START_MASS; i++) {
      sn.path.push(bx + dx * i * TUNING.SEGMENT_SPACING, by + dy * i * TUNING.SEGMENT_SPACING);
    }
  }

  private finish(): GameOutcome {
    this.s.finished = true;

    // Highest mass wins. Bots are excluded from being the winner: a practice match is the
    // human's to win or lose, and recording "bot:2 won" in game_matches would corrupt the
    // results table with a user id that does not exist.
    let winner: SnakeState | null = null;
    for (const sn of this.s.snakes) {
      if (sn.bot) continue;
      if (!winner || sn.score > winner.score) winner = sn;
    }
    this.s.winnerId = winner ? winner.id : null;

    const scores: Record<string, number> = {};
    for (const id of this.s.players) {
      const sn = this.s.snakes.find((x) => x.id === id);
      scores[id] = sn ? Math.floor(sn.score) : 0;
    }

    // A single human practising is not "beating" anyone, so there is no winner to record.
    const contested = this.s.players.length > 1;
    return { winnerId: contested ? this.s.winnerId : null, scores };
  }

  // --- Serialization -------------------------------------------------------------------

  /**
   * PERSISTENCE shape — complete, and never lossy. The runtime hands this straight back to
   * `restore`, so anything missing here is silently reset on the very next tick.
   */
  serialize(): GameStatePayload {
    // Both serialize() and serializeForWire() ask this same question and must get the same
    // answer, because serialize() has to persist the counter value that MATCHES whatever the
    // wire frame ends up doing. Deriving it from shared state rather than from call order is
    // what keeps the two in agreement no matter which the runtime calls first.
    const willSendFull = this.wantsFullFood();

    return {
      ...this.common(false, true),
      food: this.s.food.map((f) => [round(f.x), round(f.y), f.v, f.i]),
      nextFoodId: this.s.nextFoodId,
      // Deltas are cleared by a full frame, so persisting them would resend stale changes.
      added: willSendFull ? [] : this.s.added.map((f) => [round(f.x), round(f.y), f.v, f.i]),
      removed: willSendFull ? [] : this.s.removed,
      sinceFull: willSendFull ? 0 : this.s.sinceFull,
    };
  }

  /** Whether this frame's food should go out as a full snapshot rather than a delta. */
  private wantsFullFood(): boolean {
    const deltaCost = this.s.added.length * 3 + this.s.removed.length;
    const fullCost = this.s.food.length * 3;
    return this.s.sinceFull >= FOOD_FULL_INTERVAL || deltaCost >= fullCost;
  }

  /**
   * WIRE shape — the same state with the food bulk replaced by a delta.
   *
   * A full snapshot goes out when the deltas would cost more than the snapshot anyway (a big
   * death converts an entire body at once), and every FOOD_FULL_INTERVAL ticks as a resync
   * floor, so a client that drops a frame is wrong for at most a few seconds rather than for
   * the rest of the match.
   */
  serializeForWire(): GameStatePayload {
    // The counter is advanced in tick() and the reset is applied by serialize(), so this
    // method only READS the decision — it never mutates the counter. An earlier version
    // incremented here, which meant serialize() (called first by the runtime) persisted a
    // stale value that reset on every restore: the threshold was never reached, every single
    // frame sent a full snapshot, and the delta encoding silently did nothing at all.
    const wantFull = this.wantsFullFood();
    const base = { ...this.common(true, wantFull), pathStep: PATH_STEP };

    if (wantFull) {
      this.s.added = [];
      this.s.removed = [];
      return {
        ...base,
        foodFull: true,
        food: this.s.food.map((f) => [round(f.x), round(f.y), f.v, f.i]),
      };
    }

    const out = {
      ...base,
      foodFull: false,
      foodAdd: this.s.added.map((f) => [round(f.x), round(f.y), f.v, f.i]),
      foodDel: this.s.removed,
    };
    this.s.added = [];
    this.s.removed = [];
    return out;
  }

  /**
   * Everything both shapes share.
   *
   * `wire` trades body precision for bandwidth. Path points are quantised to 2 units and
   * sent as deltas from the head rather than as absolute coordinates: a body point is
   * typically within a few units of its neighbour, so the deltas are one or two digits
   * instead of four or five. At 2-unit resolution against a 10-unit body radius the
   * difference is invisible, and the client re-integrates them on arrival.
   *
   * The persistence shape keeps full precision, because that IS the simulation state — the
   * head positions get fed back into collision on the next tick, and quantising them would
   * make the physics drift a little further every tick.
   */
  private common(wire = false, full = true): GameStatePayload {
    return {
      players: this.s.players,
      // Short keys, and paths sent as flat number arrays: this payload goes out 12x/sec to
      // every player, so field names are a real fraction of the bytes on the wire.
      snakes: this.s.snakes.map((sn) => ({
        id: sn.id,
        bot: sn.bot,
        // Name is sent only on FULL frames. It never changes for the life of a match, so
        // resending it 10x/sec was pure overhead — and a full frame is exactly the frame a
        // client that missed everything needs, so it is also where a late joiner learns it.
        ...(wire && !full ? {} : { n: sn.name }),
        // Head radius, so the client draws EXACTLY the circle that kills. Deriving it
        // client-side would mean two formulas that could drift apart on any tuning change.
        hr: round(radiusFor(sn.mass, TUNING.HEAD_RADIUS), 1),
        x: round(sn.x), y: round(sn.y),
        h: round(sn.h, 3), th: round(sn.th, 3),
        m: round(sn.mass, 1),
        a: sn.alive,
        b: sn.boost,
        p: wire ? encodePath(sn.path) : sn.path.map((v) => round(v)),
        k: sn.kills, d: sn.deaths, s: Math.floor(sn.score),
        // Deadlines are compared against `t`, so they carry full precision for the same
        // reason `t` does — a rounded deadline drifts against an unrounded clock.
        ra: sn.respawnAt,
        iv: sn.invulnUntil,
        c: sn.color,
      })),
      // Food is deliberately absent here: serialize() and serializeForWire() each add their
      // own shape (full array vs delta), which is the whole point of the split.
      //
      // NOT rounded, unlike every other float here.
      //
      // `t` is the only value that is fed back into itself: the runtime restores from this
      // payload every tick, so a rounding error does not just make one frame slightly wrong,
      // it accumulates. At 12 Hz a tick is 0.0833s, and rounding that to 2dp loses 0.0033s
      // per tick — 0.2s every 5 seconds, so a 3-minute match would run ~7s long and every
      // duration-based rule would drift with it.
      t: this.s.t,
      finished: this.s.finished,
      winnerUserId: this.s.winnerId,
      seed: this.rng.seed,
      arena: this.s.arena,
      arenaRadius: this.s.arenaRadius,
      duration: this.s.duration,
      events: this.s.events,
    };
  }

  isFinished(): boolean {
    return this.s.finished;
  }
}

function round(v: number, dp = 0): number {
  const f = Math.pow(10, dp);
  return Math.round(v * f) / f;
}

/** Quantisation step for body points on the wire, in world units. */
const PATH_STEP = 2;

/** Body points nearest the head sent at full resolution; the tail beyond is halved. */
const HEAD_DETAIL_POINTS = 24;

/**
 * Encode a body polyline as [headX, headY, dx1, dy1, dx2, dy2, ...] in PATH_STEP units.
 *
 * Absolute coordinates in a 1400-unit arena are 4-5 characters each; consecutive body points
 * are ~20 units apart, so their deltas are 1-2 characters. On a long snake that is most of
 * the frame. The client integrates the deltas back to absolute positions on arrival.
 */
function encodePath(path: number[]): number[] {
  if (path.length < 2) return [];

  const out: number[] = [round(path[0]), round(path[1])];
  let prevX = path[0];
  let prevY = path[1];

  // Decimate the TAIL of long bodies. A path gains a point per tick, so a long-lived snake
  // carries 150+ points while a fresh one carries 10 — and the long ones are exactly what
  // costs bandwidth. Past HEAD_DETAIL_POINTS the tail goes out at half resolution: it is
  // drawn as a smooth curve through these points anyway, and the lost detail is behind the
  // snake where nothing is happening. The head end keeps every point, because that is where
  // the eye goes and where near-misses are judged.
  for (let i = 2; i + 1 < path.length; i += (i / 2) >= HEAD_DETAIL_POINTS ? 4 : 2) {
    // Quantise the DELTA, then advance the reference by the quantised amount rather than the
    // true one. Tracking the true position instead would let rounding error accumulate along
    // the body, and a long snake's tail would bend away from where it really is.
    const dx = Math.round((path[i] - prevX) / PATH_STEP);
    const dy = Math.round((path[i + 1] - prevY) / PATH_STEP);
    out.push(dx, dy);
    prevX += dx * PATH_STEP;
    prevY += dy * PATH_STEP;
  }
  return out;
}

function restoreState(state: GameStatePayload): State {
  const snakes = (state.snakes as any[]).map((sn) => ({
    id: sn.id as string,
    bot: sn.bot === true,
    name: (sn.n as string | null) ?? null,
    x: sn.x as number,
    y: sn.y as number,
    h: sn.h as number,
    th: sn.th as number,
    mass: sn.m as number,
    alive: sn.a as boolean,
    boost: sn.b as boolean,
    path: (sn.p as number[]) ?? [],
    kills: sn.k as number,
    deaths: sn.d as number,
    score: sn.s as number,
    respawnAt: sn.ra as number,
    invulnUntil: sn.iv as number,
    color: sn.c as number,
  }));

  const food = ((state.food as [number, number, number, number][]) ?? [])
    .map(([x, y, v, i]) => ({ x, y, v, i }));

  return {
    players: state.players as string[],
    snakes,
    food,
    nextFoodId: (state.nextFoodId as number)
      // Fall back to one past the highest id present, so a restore from an older payload
      // cannot start reissuing ids that are already in use.
      ?? (food.reduce((m, f) => Math.max(m, f.i), -1) + 1),
    added: ((state.added as [number, number, number, number][]) ?? [])
      .map(([x, y, v, i]) => ({ x, y, v, i })),
    removed: (state.removed as number[]) ?? [],
    sinceFull: (state.sinceFull as number) ?? FOOD_FULL_INTERVAL,
    t: state.t as number,
    finished: state.finished as boolean,
    winnerId: (state.winnerUserId as string | null) ?? null,
    seed: state.seed as number,
    arena: (state.arena as ArenaShape) ?? 'circle',
    arenaRadius: (state.arenaRadius as number) ?? TUNING.ARENA_RADIUS,
    duration: (state.duration as number) ?? TUNING.MATCH_SECONDS,
    events: (state.events as State['events']) ?? [],
  };
}

export const snake: GameFactory = {
  slug: 'snake',
  // The first game to set this. Its presence is what tells the runtime to start a loop.
  tickHz: TUNING.TICK_HZ,

  create(playerIds: string[], options?: Record<string, unknown>): GameEngine {
    // Options come from the client that created the match, so every value is clamped.
    const rawBots = Number(options?.bots);
    const bots = Number.isFinite(rawBots) ? clamp(Math.floor(rawBots), 0, 12) : 0;
    const rawSeconds = Number(options?.seconds);
    const duration = Number.isFinite(rawSeconds)
      ? clamp(Math.floor(rawSeconds), 60, 600)
      : TUNING.MATCH_SECONDS;

    // An explicit seed makes a match reproducible, which is what lets the headless test
    // pin a scenario instead of re-rolling the world on every run. Clients never send it.
    const rawSeed = Number(options?.seed);
    const seed = Number.isFinite(rawSeed) && rawSeed > 0
      ? rawSeed >>> 0
      : (Math.random() * 0xffffffff) >>> 0;

    const state: State = {
      players: [...playerIds],
      snakes: [],
      food: [],
      t: 0,
      finished: false,
      winnerId: null,
      seed,
      arena: 'circle',
      arenaRadius: TUNING.ARENA_RADIUS,
      duration,
      events: [],
      nextFoodId: 0,
      added: [],
      removed: [],
      // Forces a full food snapshot on the first frame: a client joining mid-match has no
      // baseline to apply a delta against.
      sinceFull: FOOD_FULL_INTERVAL,
    };

    // Names drawn without replacement so no two bots in a match share a handle — a
    // leaderboard with two "Nova" rows is worse than no names at all. Shuffled with the
    // match seed, so a replayed seed produces the same arena.
    const nameRng = new Rng(seed ^ 0x9e3779b9);
    const pool = BOT_NAMES.slice();
    for (let i = pool.length - 1; i > 0; i--) {
      const j = Math.floor(nameRng.next() * (i + 1));
      [pool[i], pool[j]] = [pool[j], pool[i]];
    }
    const botNames = Array.from(
      { length: bots },
      (_, i) => pool[i % pool.length] + (i >= pool.length ? String(Math.floor(i / pool.length) + 1) : ''));

    let colorIdx = 0;
    for (const id of playerIds) {
      state.snakes.push(blankSnake(id, false, colorIdx++, null));
    }
    for (let i = 0; i < bots; i++) {
      state.snakes.push(blankSnake(`bot:${i}`, true, colorIdx++, botNames[i]));
    }

    const engine = new SnakeEngine(state);
    // Placing snakes and seeding food needs the engine's rng, so it happens after construction.
    engine.bootstrap();
    return engine;
  },

  restore(state: GameStatePayload): GameEngine {
    return new SnakeEngine(restoreState(state));
  },
};

function blankSnake(
  id: string, bot: boolean, color: number, name: string | null
): SnakeState {
  return {
    id, bot, name, x: 0, y: 0, h: 0, th: 0,
    mass: TUNING.START_MASS,
    alive: false,
    boost: false,
    path: [],
    kills: 0, deaths: 0, score: 0,
    // respawnAt 0 with alive:false means "spawn on the very first tick".
    respawnAt: 0,
    invulnUntil: 0,
    color,
  };
}
