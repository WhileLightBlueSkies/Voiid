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
  movingPointsMinDist2,
  segmentSegmentDist2,
  shortestAngle,
  trimPath,
  Rng,
  type ArenaShape,
  type Vec,
} from './geometry';
import { stepBot, type BotMemory } from './bot';
import {
  HAZARD_TUNING,
  generateHazards,
  hazardHit,
  spikeExtended,
  type Hazard,
} from './hazards';

// --- Tuning ---------------------------------------------------------------------------
// Exported so the headless test can reason about them, and so a future dev overlay has one
// place to write to.
export const TUNING = {
  // STAYS AT 10, and this is a measured decision rather than a default.
  //
  // Raising it was the obvious move and it does not pay. Measured per player: 10 Hz = 26 KB/s,
  // 12 Hz = 37, 15 Hz = 41 — worse than linear, because a faster tick also keeps bots alive
  // longer, so they grow longer, so every body costs more on every frame.
  //
  // And the thing it would buy is no longer worth buying. Before prediction, tick rate bought
  // SMOOTHNESS. Now that the local snake is predicted, it only decides how often prediction
  // is corrected — and those corrections were already invisible at 10. Paying 40% more mobile
  // data for accuracy nobody is looking at is the wrong trade.
  // 20 Hz. Raised 10 -> 12 -> 20 as the bandwidth budget opened up, and this is the number
  // that actually closes the prediction gap rather than narrowing it.
  //
  // The old comment argued 10 was right because tick rate "only decides how often prediction
  // is corrected", and those corrections were invisible. True of the LOCAL snake, which is
  // predicted. Never true of every OTHER snake, which is interpolated behind a jitter buffer
  // measured in TICKS — so the buffer's real-time depth is a direct function of this number,
  // and that depth is what playtesting kept hitting as "there was a gap and I still died".
  //
  //   10 Hz -> 250 ms buffer -> ~75 units of staleness
  //   12 Hz -> 208 ms        -> ~62
  //   20 Hz -> 125 ms        -> ~38
  //
  // Against a 22-unit kill radius, and with lead extrapolation taking roughly three quarters
  // of what is left on a snake travelling straight, 20 Hz is the first setting where the
  // residual error (~9 units) is SMALLER than the radius that decides a fight. Below that the
  // screen and the server can still disagree about a collision; at 20 they agree.
  //
  // Measured at 46.9 KB/s over six seeds, after trimming th/ra from the wire.
  TICK_HZ: 20,
  // Faster, per user testing: 240 read as sluggish rather than as weighty.
  BASE_SPEED: 300,          // units/sec
  BOOST_SPEED: 510,
  // RESPONSIVENESS, and the single biggest complaint from testing ("hard to move", "takes
  // time"). At 260 deg/s a half-turn took 0.7 s — long enough that a player stops believing
  // the control is connected to the snake. 400 puts it at 0.45 s, which still arcs (this is
  // not a grid game) but answers the thumb.
  TURN_RATE: 400,           // degrees/sec
  // Boosting turns FASTER, not slower.
  //
  // The original 195 made boost a commitment you could not steer out of, which is one valid
  // design — but it reads as the controls going vague exactly when the player is paying most
  // attention. Turning up with speed keeps the turn RADIUS roughly constant instead of
  // ballooning, so a boosting snake still feels like it is being steered.
  TURN_RATE_BOOST: 440,
  START_MASS: 10,
  MIN_BOOST_MASS: 12,
  BOOST_DRAIN: 3.57,        // mass/sec
  HEAD_RADIUS: 11,
  BODY_RADIUS: 10,
  SEGMENT_SPACING: 14,
  // Base mouth radius, scaled by mass exactly like the head is. A FIXED value here was the
  // bug: `radiusFor` grows a head to 2.2x, so a heavy snake's drawn head overlapped a pellet
  // well before its mouth did, and eating went from generous to fiddly as you grew — the
  // opposite of the reward curve the rest of the tuning builds.
  //
  // A reference implementation solves the same feel problem with MAGNETISM — pellets slide
  // toward the head — but that needs pellet positions on the wire every tick, and this protocol
  // deliberately sends only adds and removals (food was once 59% of the payload). Scaling the
  // mouth costs nothing on the wire and, because a bigger mouth clears pellets sooner, it
  // actually LOWERS sustained bandwidth: 30 KB/s to 28 KB/s in the wire-size check below.
  EAT_RADIUS: 28,
  // 2000, up from 1400 — twice the play area.
  //
  // Measured over six seeds, one config per process: 1400 cost 28.7 KB/s and 2000 cost 24.4.
  // A BIGGER ARENA IS CHEAPER, which is not the obvious result. Two reasons: body points are
  // delta-encoded, so arena size does not change the size of a delta and a wider world costs
  // nothing per point; and more space means less tangling, so snakes stay shorter and bodies
  // ARE the payload. Bandwidth was never the constraint here — match length and bot count are.
  ARENA_RADIUS: 2000,
  // Scaled by AREA, not radius. Holding the old 260 over twice the area would have made the
  // arena barren, which is the actual risk of growing it.
  //
  // BOT COUNT IS NOT SCALED WITH IT, deliberately. Measured in this arena over six seeds:
  // 4 bots = 30.3 KB/s, 6 = 46.9, 8 = 67.1. Bots are what the payload is made of — every one
  // is a body on the wire every tick — so the obvious "bigger arena, more bots" would have
  // spent four times what the arena itself cost. The arena is free; the population is not.
  FOOD_TARGET: 530,
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
 * Skin ids, assigned to bots the same way names are (docs/GAMES_SNAKE_VISUALS.md §2).
 *
 * The SERVER assigns them so every device in a match shows the same snake wearing the same
 * skin — a client picking its own would mean two players describing different arenas.
 *
 * The id is all that travels. What a skin looks like is client data, so adding a colourway is
 * a client release and never a server one.
 */
const BOT_SKINS: readonly string[] = [
  'rainbow', 'candy', 'lava', 'frost', 'shadow', 'bunny', 'corgi', 'lion', 'unicorn',
];

/** Ids a client may ask for. Anything else falls back to the plain palette colour. */
const VALID_SKINS: ReadonlySet<string> = new Set(BOT_SKINS);

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

type DeathCause = 'border' | 'body' | 'head' | 'rock';

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
  /**
   * Skin id. Null means "no skin" and the client draws the plain palette colour — which is
   * also what an older client does with a skin it has never heard of.
   */
  skin: string | null;
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
  /**
   * Simulation time until which this snake is still slowed by a slick it has left.
   *
   * A TIMESTAMP, NOT A BOOLEAN, for the same reason `invulnUntil` is: the engine is rebuilt
   * from serialized state on every input, so a flag would have to be cleared by something and
   * an absolute time simply expires on its own.
   */
  slickUntil?: number;
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
  /**
   * Arena geography (hazards.ts). STATIC for the whole match: generated once from the match
   * seed and never mutated, which is what lets it be broadcast once rather than every tick.
   */
  hazards: Hazard[];
  /** Recent deaths, for client-side VFX. Cleared each broadcast. */
  events: {
    k: string;
    x: number;
    y: number;
    /**
     * WHOSE EVENT THIS IS, and it means different things per kind — deliberately, because the
     * clients branch on exactly this. On `death` it is the snake that died; on `kill` it is the
     * KILLER. Both call sites in the renderers depend on that asymmetry.
     */
    id: string;
    /** Death cause ("border" | "body" | "head"), on `death` only. */
    c?: string;
    /** The VICTIM, on `kill` only — `id` is already spent on the killer. */
    v?: string;
  }[];

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
// 300 ticks (30 s), not 60 (6 s).
//
// A full snapshot is ~8.7 KB against a ~1.6 KB steady frame, so its FREQUENCY — not the
// steady state — is what set the average. And it is a RECOVERY path: every add and removal
// already rides the deltas, so this only exists to repair a client that dropped a frame.
// Repairing every 30 s instead of every 6 s costs a dropped-frame client a little staleness
// in the worst case and saves the other 99% of frames the spike.
const FOOD_FULL_INTERVAL = 120;


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

    // "Put me back in." Only honoured once the respawn delay has elapsed, so the button
    // cannot be used to skip the penalty for dying.
    if (input.respawn === true) {
      if (!this.canRespawn(snake)) return { accepted: false };
      this.spawnSnake(snake);
      this.s.events.push({ k: 'spawn', x: snake.x, y: snake.y, id: snake.id });
      // NOT silent: this one changes the world immediately, so the player should see it
      // without waiting for the next tick.
      return { accepted: true };
    }

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
        stepBot(sn, mem, dt, this.s.snakes, this.s.food, this.s.arena, this.s.arenaRadius,
        this.s.hazards, this.rng);
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
        // Was 0.5 — halved alongside the speed increase, for the same reason as the
        // replenish cap: a faster boosting snake drops far more pellets per second, and each
        // one is a new id on the wire.
        if (this.rng.next() < 0.25) {
          samplePath(sn.path, Math.min(pathLength(sn.path), sn.mass * TUNING.SEGMENT_SPACING), scratch);
          this.addFood(scratch.x, scratch.y, 0.5);
        }
        if (sn.mass <= TUNING.MIN_BOOST_MASS) {
          sn.mass = TUNING.MIN_BOOST_MASS;
          sn.boost = false;
        }
      }

      let speed = boosting ? TUNING.BOOST_SPEED : TUNING.BASE_SPEED;
      // SLICKS SLOW YOU, and the slow LINGERS briefly after you leave.
      //
      // Without the linger, clipping a slick's edge produced a one-tick stutter that read as
      // a dropped frame rather than as terrain — the same class of complaint SNAKE.md §2
      // documents for the render clock. Decaying out of it makes it feel like ground.
      if (this.s.t < (sn.slickUntil ?? 0)) speed *= HAZARD_TUNING.SLICK_SPEED;
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

      // Border. Sampled along the swept motion, not just at the endpoint — and the sample
      // COUNT scales with how far the head actually moved.
      //
      // A fixed 3 samples was a tunnelling bug waiting for a speed increase, and the speed
      // increase came: at 510 u/s boost a head covers 51 units per tick, so three samples
      // left 17-unit gaps against an 11-unit radius and a head could step clean over the
      // wall and out of the arena. Sampling every ~half-radius keeps the gaps smaller than
      // the head at any speed this game can reach.
      let hitBorder = false;
      const sweep = Math.hypot(sn.x - prevX, sn.y - prevY);
      const steps = Math.max(3, Math.ceil(sweep / (headR * 0.5)));
      for (let k = 1; k <= steps; k++) {
        const t = k / steps;
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

      // ARENA GEOGRAPHY, tested before any snake-vs-snake rule: the world kills you regardless
      // of who happens to be nearby, and a rock you hit while someone was also hitting you is
      // still a rock.
      //
      // Swept along the same samples the border uses, for the same reason — at boost speed a
      // head covers 51 units a tick and would otherwise step clean over a 26-unit rock.
      let hazardDeath = false;
      let slicked = false;
      for (const h of this.s.hazards) {
        let touched = false;
        for (let k = 1; k <= steps && !touched; k++) {
          const t = k / steps;
          const sx = prevX + (sn.x - prevX) * t;
          const sy = prevY + (sn.y - prevY) * t;
          if (hazardHit(h, sx, sy, headR)) touched = true;
        }
        if (!touched) continue;

        if (h.k === 'rock') {
          // Lethal, like a wall. It IS a wall — just one in the middle.
          doomed.push({ snake: sn, cause: 'rock', killer: null });
          hazardDeath = true;
          break;
        }
        if (h.k === 'spike' && spikeExtended(h, this.s.t)) {
          // COSTS MASS, DOES NOT KILL OUTRIGHT. Mass is the health bar this game already has:
          // the player watches it, it is already on the wire, and losing it is immediately
          // legible as "that hurt" without a single new HUD element. Falling under the floor
          // kills, which is the same way starving already works.
          sn.mass -= HAZARD_TUNING.SPIKE_MASS_COST;
          this.s.events.push({ k: 'spike', x: Math.round(sn.x), y: Math.round(sn.y), id: sn.id });
          if (sn.mass < TUNING.START_MASS * 0.5) {
            doomed.push({ snake: sn, cause: 'rock', killer: null });
            hazardDeath = true;
            break;
          }
        }
        if (h.k === 'slick') slicked = true;
      }
      // Refreshed every tick while inside, then decays — so the edge is soft rather than a
      // one-tick stutter that reads as a dropped frame.
      if (slicked) sn.slickUntil = this.s.t + HAZARD_TUNING.SLICK_LINGER;
      if (hazardDeath) continue;

      // Head-to-head: longer survives; within 5% both die.
      //
      // TESTED IN TIME, NOT JUST IN SPACE. This used to sweep our head against the other head's
      // END position held still, which is wrong in both directions: it missed a head that moved
      // INTO us during the tick, and — far more visibly — it killed pairs whose paths merely
      // CROSSED at different moments. Two snakes passing through the same point a fraction of a
      // tick apart never touched, and reporting that as a mutual kill is exactly the "there was
      // a gap and we both died" case. Both heads are now advanced by the same t.
      let resolved = false;
      for (const other of this.s.snakes) {
        if (other.id === sn.id || !other.alive) continue;
        if (this.s.t < other.invulnUntil) continue;
        const rr = headR + radiusFor(other.mass, TUNING.HEAD_RADIUS);
        // The other head's own start-of-tick position. A snake that has not moved yet this tick
        // (a fresh spawn with a short path) falls back to its current position, which is where
        // it has been all tick anyway.
        const oPrevX = other.path.length >= 4 ? other.path[2] : other.x;
        const oPrevY = other.path.length >= 4 ? other.path[3] : other.y;
        if (movingPointsMinDist2(prevX, prevY, sn.x, sn.y, oPrevX, oPrevY, other.x, other.y) <= rr * rr) {
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

      // SKIP THE NECK. path[0..1] is the other snake's HEAD, and the segments closest behind it
      // are underneath that head. Testing from index 0 meant brushing the side of someone's head
      // counted as hitting their BODY — so the toucher died and the touched snake walked away,
      // when the head-to-head rule above (longer survives) is the one that should have decided
      // it. That is the "they touched the side of my mouth and I died too" case.
      //
      // The head-to-head test has already run for this pair by the time we get here, so anything
      // genuinely head-on has been resolved; skipping the neck here cannot let a real head
      // collision through, it only stops the body rule from stealing one.
      const neck = radiusFor(other.mass, TUNING.HEAD_RADIUS) + headR;
      let walked = 0;
      for (let i = 0; i + 3 < path.length; i += 2) {
        let ax = path[i], ay = path[i + 1];
        const bx = path[i + 2], by = path[i + 3];
        const segLen = Math.hypot(bx - ax, by - ay);

        // CLIP THE NECK MID-SEGMENT, do not skip whole segments. Path points are laid down one
        // per tick — about 30 units apart at cruise — while the neck is only ~22, so a
        // segment-granular skip would clear the neck on the very first segment and protect
        // nothing. Advancing the segment's START past the neck keeps the rest of that same
        // segment lethal, which is what makes this a head-footprint exclusion rather than a
        // free first tick of body.
        if (walked + segLen > neck) {
          if (walked < neck && segLen > 1e-6) {
            const t = (neck - walked) / segLen;
            ax = ax + (bx - ax) * t;
            ay = ay + (by - ay) * t;
          }

          if (segmentSegmentDist2(
            prevX, prevY, sn.x, sn.y,
            ax, ay, bx, by
          ) <= rr * rr) {
            return other.id;
          }
        }

        walked += segLen;
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

    // `id` is the VICTIM and `v` carries the KILLER — the inverse of the 'kill' event below,
    // which spends `id` on the killer. Without this a client could not attribute a death, and
    // no test could assert "X killed Y" from the death event alone.
    this.s.events.push({ k: 'death', x: sn.x, y: sn.y, id: sn.id, c: cause, v: killerId ?? undefined });

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
        // `v` is the VICTIM. `id` on a kill event is the KILLER (that asymmetry is
        // deliberate and load-bearing — see the client call sites), which means a kill event
        // alone could never say who was eaten. A feed reading "You ate someone" is worth
        // nothing; "You ate Priya" is the line a player screenshots.
        this.s.events.push({ k: 'kill', x: sn.x, y: sn.y, id: killerId, v: sn.id });
      }
    }
  }

  private resolveEating(): void {
    for (const sn of this.s.snakes) {
      // NO INVULNERABILITY CHECK HERE, and its absence is deliberate.
      //
      // `resolveCollisions` skips invulnerable snakes because invulnerability is protection
      // FROM HARM. This loop used to share that guard, which meant that for the first 1.5 s of
      // every life a snake drove over pellets and none of them registered: measured on seed
      // 4242, a fresh spawn crossed 21 planted pellets in its invulnerable window and ate
      // exactly 0, leaving them behind it on the board. Nothing on screen explains that, so it
      // reads as the game not registering input at the one moment a player is most likely to
      // conclude the controls are broken.
      //
      // Invulnerability protects you from dying. It was never meant to protect you from food.
      if (!sn.alive) continue;

      // Per-snake, because the mouth scales with the head. Same `radiusFor` curve the hitbox
      // and the drawn head use, so a snake's reach can never disagree with its own size.
      const r = radiusFor(sn.mass, TUNING.EAT_RADIUS);
      const r2 = r * r;

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

    // Two per tick, not four.
    //
    // Every spawned pellet is a NEW id and therefore a new entry in `foodAdd` — and once
    // snakes got faster they ate fast enough that the deficit never closed, so this ran at
    // its cap forever and the delta churn became the single largest thing on the wire,
    // bigger than every snake body combined. 20/s still refills the arena faster than six
    // snakes can clear it; it just stops paying to re-announce the field continuously.
    const deficit = TUNING.FOOD_TARGET - standard;
    const spawn = Math.min(deficit, 2);
    for (let i = 0; i < spawn; i++) {
      const a = this.rng.next() * Math.PI * 2;
      const rad = Math.sqrt(this.rng.next()) * (this.s.arenaRadius - 60);
      this.addFood(Math.cos(a) * rad, Math.sin(a) * rad, 1);
    }
  }

  /**
   * Put snakes back in the arena.
   *
   * BOTS respawn on a timer. HUMANS DO NOT — a human is respawned only when their client
   * asks (`{ respawn: true }`), because auto-respawning meant a player never got to see that
   * they had died: the death panel appeared and vanished inside the 2.5 s delay, and being
   * teleported back into play unprompted reads as "the match restarted by itself".
   *
   * `respawnAt` still gates the request, so a dead player cannot re-enter instantly and
   * dodge the consequence of dying.
   */
  private respawnDue(): void {
    for (const sn of this.s.snakes) {
      if (sn.alive || this.s.t < sn.respawnAt) continue;
      if (!sn.bot) continue;
      this.spawnSnake(sn);
      this.s.events.push({ k: 'spawn', x: sn.x, y: sn.y, id: sn.id });
    }
  }

  /** True when this snake is dead and past its respawn delay, i.e. may re-enter on request. */
  private canRespawn(sn: SnakeState): boolean {
    return !sn.alive && this.s.t >= sn.respawnAt;
  }

  /**
   * Place a snake far from anything that can kill it, at starting mass. No catch-up bonus.
   *
   * SCORED AGAINST BODIES AND ROCKS, NOT JUST HEADS. This used to measure distance to other
   * snakes' HEADS only, which is not the thing that kills you: a head is one point, a body is
   * a polyline hundreds of units long, and a rock is lethal on contact. So a spawn could land
   * on top of a long snake's tail or inside a rock, sit through its 1.5 s of invulnerability,
   * and then die the instant that expired — with nothing visible happening, because nothing
   * visible DID happen. Measured before the fix: 4 of 129 spawns landed within 40 units of a
   * body, the worst at 13.4 units, which is inside the kill radius.
   */
  private spawnSnake(sn: SnakeState): void {
    const headR = radiusFor(TUNING.START_MASS, TUNING.HEAD_RADIUS);

    /** Distance from a candidate point to the nearest thing that could kill this snake. */
    const clearance = (px: number, py: number): number => {
      let nearest = Infinity;

      for (const o of this.s.snakes) {
        if (o.id === sn.id || !o.alive) continue;

        // The HEAD, then the BODY. Broad-phase reject first, exactly as bodyHit does, so a
        // spawn search stays cheap even in a crowded late-game arena.
        const d = Math.hypot(px - o.x, py - o.y);
        if (d < nearest) nearest = d;

        const reach = pathLength(o.path) + headR + radiusFor(o.mass, TUNING.BODY_RADIUS);
        if (d > reach) continue;

        const path = o.path;
        for (let i = 0; i + 1 < path.length; i += 2) {
          const bd = Math.hypot(px - path[i], py - path[i + 1])
            - radiusFor(o.mass, TUNING.BODY_RADIUS);
          if (bd < nearest) nearest = bd;
        }
      }

      // Rocks kill outright and spikes cost mass; both are worth spawning away from. Slicks
      // only slow you down, so they are not a spawn hazard.
      for (const h of this.s.hazards) {
        if (h.k === 'slick') continue;
        const hd = Math.hypot(px - h.x, py - h.y) - h.r;
        if (hd < nearest) nearest = hd;
      }

      return nearest === Infinity ? 9999 : nearest;
    };

    let bx = 0, by = 0, best = -Infinity;
    for (let attempt = 0; attempt < 20; attempt++) {
      const a = this.rng.next() * Math.PI * 2;
      const rad = Math.sqrt(this.rng.next()) * (this.s.arenaRadius - 240);
      const px = Math.cos(a) * rad, py = Math.sin(a) * rad;

      const nearest = clearance(px, py);
      if (nearest > best) { best = nearest; bx = px; by = py; }
      // Good enough to stop looking. A spawn only has to be SAFE, not optimal, and stopping
      // early keeps the common case at one or two candidates.
      if (best > SAFE_SPAWN_CLEARANCE) break;
    }

    // Nothing acceptable in 20 random draws — sweep a ring instead of accepting a spawn that
    // is known to be inside something. A spawn is rare enough to afford the search, and
    // "spawned inside a body" is the exact failure this function exists to prevent.
    if (best < SAFE_SPAWN_CLEARANCE) {
      const rings = [0.45, 0.62, 0.78, 0.30];
      outer:
      for (const frac of rings) {
        const rad = this.s.arenaRadius * frac;
        for (let k = 0; k < 24; k++) {
          const a = (k / 24) * Math.PI * 2;
          const px = Math.cos(a) * rad, py = Math.sin(a) * rad;
          const nearest = clearance(px, py);
          if (nearest > best) { best = nearest; bx = px; by = py; }
          if (best > SAFE_SPAWN_CLEARANCE) break outer;
        }
      }
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

    // Highest SCORE wins — score, not mass, because score rewards kills and eating while mass
    // alone would reward turtling. Bots are excluded from being the winner: a practice match is the
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
      // ALWAYS here: this is the persistence shape, and a field missing from it is silently
      // reset on the next tick. The WIRE copy is gated (see serializeForWire).
      hazards: this.s.hazards,
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
    // HAZARDS RIDE THE FULL-FOOD FRAME, AND THE REASON IS A BUG WORTH RECORDING.
    //
    // The obvious design is "send once, then never again", with a flag on the engine. It does
    // not work here, and the bandwidth test caught it: the runtime REBUILDS THE ENGINE FROM
    // REDIS ON EVERY INPUT (index.ts), so any per-instance flag resets constantly and the
    // "sent once" field went out on essentially every frame — the opposite of the intent, and
    // invisible except as a number in a test.
    //
    // Persisting the flag in serialize() would be worse: a client that joined late, or dropped
    // the one frame carrying the field, would then never receive the arena at all.
    //
    // So it rides the existing full-snapshot cadence, which already exists precisely to be a
    // resync floor for late and lossy clients. ~12 static objects on a frame that is already
    // sending the whole food field is noise, and it inherits a path that is already tested.
    const base = {
      ...this.common(true, wantFull),
      pathStep: PATH_STEP,
      ...(wantFull ? { hazards: this.s.hazards } : {}),
    };

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
        // Name and skin both ride FULL frames only: neither ever changes for the life of a
        // match, so resending them 10x/sec was pure overhead, and a full frame is exactly the
        // frame a client that missed everything needs.
        ...(wire && !full ? {} : { n: sn.name, sk: sn.skin }),
        // Head radius, so the client draws EXACTLY the circle that kills. Deriving it
        // client-side would mean two formulas that could drift apart on any tuning change.
        hr: round(radiusFor(sn.mass, TUNING.HEAD_RADIUS), 1),
        // BODY radius, for the same reason — and it is NOT the head radius.
        //
        // Sending only `hr` was a real bug, not an omission. The clients drew the body as a
        // ribbon of width `hr * 1.9` (half-width ~1.05 * hr) while `bodyHit` tests against
        // `headR + radiusFor(mass, BODY_RADIUS)` — roughly 2 * hr. So the lethal zone around
        // every snake was about TWICE the width of the body drawn on screen, and a player
        // could die from a visible gap away with nothing on screen to explain it. It read as
        // lag; it was geometry.
        br: round(radiusFor(sn.mass, TUNING.BODY_RADIUS), 1),
        x: round(sn.x), y: round(sn.y),
        h: round(sn.h, 3),
        // DESIRED heading and respawn deadline are PERSISTENCE ONLY. The engine needs both to
        // restore itself; no client reads either — the clients render `h`, and `cr` already
        // answers "may I respawn" without them having to reason about the server's clock.
        // Sending them cost ~70 bytes per frame per snake for nothing.
        ...(wire ? {} : { th: round(sn.th, 3), ra: sn.respawnAt }),
        m: round(sn.mass, 1),
        a: sn.alive,
        b: sn.boost,
        p: wire ? encodePath(sn.path) : sn.path.map((v) => round(v)),
        k: sn.kills, d: sn.deaths, s: Math.floor(sn.score),
        // Whether this snake may respawn right now, so the client can enable its button
        // without having to reason about the server's clock.
        cr: !sn.alive && this.s.t >= sn.respawnAt,
        // Deadlines are compared against `t`, so they carry full precision for the same
        // reason `t` does — a rounded deadline drifts against an unrounded clock. Rounded to
        // milliseconds on the wire, where nobody can perceive the difference and the digits
        // are pure payload; full precision is kept for persistence.
        iv: wire ? round(sn.invulnUntil, 3) : sn.invulnUntil,
        // SLICK EXPIRY. Not cosmetic: the engine rebuilds itself from this payload every tick,
        // so a field missing here is silently reset before it can ever be read. `slickUntil`
        // was set and read but never serialized, which meant slicks did NOTHING — a snake
        // parked in one moved the full 30 units per tick instead of 18.6, for the entire life
        // of the feature. It is on the wire as well as in persistence because the client's
        // predictor has to apply the same slowdown or the local snake fights a correction for
        // as long as the player is in a slick.
        sl: wire ? round(sn.slickUntil ?? 0, 3) : (sn.slickUntil ?? 0),
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
// 3, not 2. Body points are quantised to this on the wire, and at a body radius of ~20 the
// difference between 2 and 3 units is well under a pixel at play zoom — while the snakes got
// faster (more points per body) and pushed the frame past its ceiling. Precision nobody can
// see is the right thing to spend.
/**
 * How many snakes an arena wants in it, humans and bots together.
 *
 * 6, because that is what the bandwidth budget affords: in the 2000-unit arena, 6 snakes costs
 * about 47 KB/s and 8 costs 67. The arena is free to grow; the population is not.
 */
const TARGET_SNAKES = 6;

const PATH_STEP = 3;

/**
 * Clearance a spawn point must have from any body, head or lethal hazard.
 *
 * Comfortably outside the kill radius (a start-mass head plus a grown body radius is ~35), with
 * room for both snakes to have moved by the time invulnerability ends.
 */
const SAFE_SPAWN_CLEARANCE = 90;

/** Body points nearest the head sent at full resolution; the tail beyond is halved. */
// Reduced from 24 alongside the speed increase.
//
// A faster snake covers more ground per tick, so its path holds more points for the same
// body length and the frame grew past the 25 KB/s ceiling. The tail is decimated anyway and
// the eye is on the head, so buying the bandwidth back from tail detail is the cheapest
// place to take it.
const HEAD_DETAIL_POINTS = 16;

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
  // Progressive decimation: full detail near the head, then coarser and coarser toward the
  // tail. A long snake's tail is behind it, is usually off-screen, and is drawn as a smooth
  // curve through whatever points arrive — so spending equal bytes on it was the single
  // biggest avoidable cost once snakes got fast enough to grow long.
  for (let i = 2; i + 1 < path.length; ) {
    const pts = i / 2;
    const stride = pts >= HEAD_DETAIL_POINTS * 3 ? 8
                 : pts >= HEAD_DETAIL_POINTS ? 4
                 : 2;
    // Quantise the DELTA, then advance the reference by the quantised amount rather than the
    // true one. Tracking the true position instead would let rounding error accumulate along
    // the body, and a long snake's tail would bend away from where it really is.
    const dx = Math.round((path[i] - prevX) / PATH_STEP);
    const dy = Math.round((path[i + 1] - prevY) / PATH_STEP);
    out.push(dx, dy);
    prevX += dx * PATH_STEP;
    prevY += dy * PATH_STEP;
    i += stride;
  }
  return out;
}

function restoreState(state: GameStatePayload): State {
  const snakes = (state.snakes as any[]).map((sn) => ({
    id: sn.id as string,
    bot: sn.bot === true,
    name: (sn.n as string | null) ?? null,
    skin: (sn.sk as string | null) ?? null,
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
    slickUntil: (sn.sl as number | undefined) ?? 0,
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
    // A match created BEFORE hazards shipped has none in its state. Regenerating from the seed
    // is the only answer that keeps such a match playable AND identical for every client —
    // defaulting to an empty field would silently hand one player a clear arena.
    hazards: (state.hazards as Hazard[] | undefined)
      ?? generateHazards(
           new Rng(((state.seed as number) ?? 1) ^ 0x51ed270b),
           (state.arenaRadius as number) ?? TUNING.ARENA_RADIUS),
    events: (state.events as State['events']) ?? [],
  };
}

export const snake: GameFactory = {
  slug: 'snake',
  // The first game to set this. Its presence is what tells the runtime to start a loop.
  tickHz: TUNING.TICK_HZ,

  create(playerIds: string[], options?: Record<string, unknown>): GameEngine {
    // Options come from the client that created the match, so every value is clamped.
    // BOTS TOP UP TO A TARGET POPULATION rather than being an absolute count.
    //
    // The arena wants roughly the same number of snakes in it however many humans turned up:
    // six snakes is a busy arena, and whether five of them are bots or one of them is does not
    // change how it plays. So the client asks for a population, and the engine fills whatever
    // the humans did not.
    //
    // WHY A CAP MATTERS MORE THAN THE TARGET. Measured over six seeds in the 2000-unit arena:
    // 4 bots = 30.3 KB/s, 6 = 46.9, 8 = 67.1. Every snake is a body on the wire every tick, so
    // population is the single most expensive knob in the game — far more than arena size,
    // which is free. TARGET_SNAKES is chosen for that budget, not for how full the arena looks.
    const rawBots = Number(options?.bots);
    const requested = Number.isFinite(rawBots) ? clamp(Math.floor(rawBots), 0, 12) : 0;
    // A match that asked for no bots gets none — solo practice and real multiplayer both rely
    // on that. Otherwise fill the gap the humans left, never below zero.
    const bots = requested === 0
      ? 0
      : clamp(TARGET_SNAKES - playerIds.length, 0, requested);
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
      // Drawn from a DERIVED seed rather than the match RNG itself, so adding hazards does not
      // shift every subsequent draw and change the food layout of an otherwise identical seed.
      hazards: generateHazards(new Rng(seed ^ 0x51ed270b), TUNING.ARENA_RADIUS),
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

    // The human's chosen skin. UNTRUSTED like every other option, so an unknown id becomes
    // null and the client falls back to a plain colour rather than the server trusting a
    // string it has never seen.
    const rawSkin = options?.skin;
    let humanSkin =
      typeof rawSkin === 'string' && VALID_SKINS.has(rawSkin) ? rawSkin : 'rainbow';

    // A CUSTOM COLOUR, sent as a packed 0xRRGGBB integer.
    //
    // The options bag is typed [String: Int] across every game (see GamesAPI), and widening
    // that for one game's colour picker would touch four unrelated games. An integer carries
    // a colour perfectly well, and the client renders any colour as a checkered two-band skin
    // anyway — so "custom" needs no catalogue entry, just the value.
    const rawColor = Number(options?.color);
    if (Number.isFinite(rawColor) && rawColor >= 0 && rawColor <= 0xffffff) {
      // `custom:RRGGBB` — the client parses the suffix; an older client sees an unknown skin
      // id and falls back to a plain palette colour, which is exactly the right degradation.
      humanSkin = `custom:${Math.floor(rawColor).toString(16).padStart(6, '0')}`;
    }

    // Bot skins are drawn without replacement where possible, so a small arena does not end
    // up with four identical snakes — the whole point of skins is telling players apart.
    const skinPool = BOT_SKINS.slice();
    for (let i = skinPool.length - 1; i > 0; i--) {
      const j = Math.floor(nameRng.next() * (i + 1));
      [skinPool[i], skinPool[j]] = [skinPool[j], skinPool[i]];
    }
    const botSkins = Array.from({ length: bots }, (_, i) => skinPool[i % skinPool.length]);

    let colorIdx = 0;
    for (const id of playerIds) {
      state.snakes.push(blankSnake(id, false, colorIdx++, null, humanSkin));
    }
    for (let i = 0; i < bots; i++) {
      state.snakes.push(
        blankSnake(`bot:${i}`, true, colorIdx++, botNames[i], botSkins[i]));
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
  id: string, bot: boolean, color: number, name: string | null, skin: string | null
): SnakeState {
  return {
    id, bot, name, skin, x: 0, y: 0, h: 0, th: 0,
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
