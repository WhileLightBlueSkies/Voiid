// Arena hazards — the things in the world that are not food (docs/games/SNAKE.md).
//
// WHAT THIS ADDS, AND WHAT IT DELIBERATELY DOES NOT.
//
// Snake today is binary: you are alive or you are not, and everything that touches you either
// kills you outright (a border, another snake's body) or feeds you. That is a clean rule and it
// is why the game reads instantly. Hazards must not turn it into a health-bar game, because a
// health bar would make every death a slow argument rather than a mistake you can point at.
//
// So MASS IS THE HEALTH BAR. It already exists, it is already on the wire, it already decides
// head-to-head outcomes, and the player already watches it — a hazard that costs mass is
// immediately legible as "that hurt" without a single new HUD element. Dropping below the
// existing minimum kills you, exactly as starving would.
//
// THREE KINDS, EACH ANSWERING A DIFFERENT QUESTION:
//
//   ROCK      static, permanent, lethal on contact. The arena stops being an empty disc and
//             starts having geography — cover to cut behind, corners to trap someone against.
//   SPIKE     static, periodic. Deadly only while extended, so it is a timing problem rather
//             than a wall. It is what makes a route sometimes-open.
//   SLICK     static, harmless, slows you. A soft hazard: it costs you tempo and position
//             rather than your run, so it creates pressure without creating deaths.
//
// A NOTE ON WHY NOTHING HERE MOVES. Moving hazards would need their own integration, their own
// wire fields every tick, and their own prediction story on the client — Snake's netcode is
// already the most delicate thing in the app (SNAKE.md §2 is a whole section on one stutter
// bug). Static geometry is broadcast ONCE at match start and never again, which means hazards
// cost nothing per frame and cannot desync.
import { Rng } from '../rng';

export type HazardKind = 'rock' | 'spike' | 'slick';

export interface Hazard {
  k: HazardKind;
  x: number;
  y: number;
  /** Collision radius. */
  r: number;
  /**
   * Period in seconds for a spike's extend/retract cycle, and the fraction of it spent
   * extended. Absent on rock and slick, which never change state.
   *
   * DERIVED FROM SIMULATION TIME, NOT STORED AS A FLAG. The engine round-trips through
   * serialize/restore on every input, and a phase stored as "currently extended" would be a
   * second source of truth that could disagree with the clock after a restore. `t` is
   * authoritative; the state is a pure function of it.
   */
  p?: number;
  /** Phase offset in seconds, so a field of spikes does not pulse in unison. */
  o?: number;
}

/** How much of the arena radius the hazard field avoids at the centre, where players spawn. */
const SPAWN_CLEARANCE = 0.22;
/** Nothing within this fraction of the wall — a hazard hugging the border is an unfair pinch. */
const WALL_CLEARANCE = 0.86;

export const HAZARD_TUNING = {
  /** Mass lost to a spike. Enough to matter, not enough to be an instant loss. */
  SPIKE_MASS_COST: 8,
  /** Speed multiplier inside a slick. */
  SLICK_SPEED: 0.62,
  /** Seconds a snake keeps being slowed after leaving a slick, so it is not a hard edge. */
  SLICK_LINGER: 0.35,
  /** A spike is dangerous for this fraction of its period. */
  SPIKE_DUTY: 0.45,
};

/**
 * Is this spike currently out?
 *
 * A pure function of simulation time, per the note on `Hazard.p`.
 */
export function spikeExtended(h: Hazard, t: number): boolean {
  if (h.k !== 'spike') return false;
  const period = h.p ?? 3;
  const phase = ((t + (h.o ?? 0)) % period) / period;
  return phase < HAZARD_TUNING.SPIKE_DUTY;
}

/**
 * Lay out a hazard field for one match.
 *
 * DRAWN FROM THE MATCH RNG, so every client and the server agree without the field ever being
 * recomputed — and so a replay of the same seed is the same arena. The count scales with arena
 * area rather than being a flat number, so a bigger arena is not emptier.
 *
 * PLACEMENT RULES, all of them about not being unfair rather than about looking good:
 *   - nothing near the centre, where snakes spawn and cannot yet steer
 *   - nothing hugging the wall, which would turn a survivable graze into a pinch with no out
 *   - nothing overlapping anything else, so a "gap" is never secretly closed
 */
export function generateHazards(rng: Rng, arenaRadius: number, density = 1): Hazard[] {
  const out: Hazard[] = [];
  // ~12 hazards at the default 1400-unit arena, area-proportional so the field feels the same
  // whatever the arena size.
  //
  // TUNED DOWN FROM 18, AND THE MEASUREMENT IS WORTH RECORDING because the obvious reading was
  // wrong twice.
  //
  // The field costs 0.8 KB and rides the existing full-food frame, so it is not the payload.
  // What hazards actually move is BOT SURVIVAL: geography breaks up the open arena, bots live
  // longer, longer bots have longer bodies, and every body is on the wire ten times a second.
  // Snake's own TICK_HZ comment predicts exactly that coupling, and it applies to geography.
  //
  // Single-seed readings swung between 27 and 34 KB/s and sent two rounds of tuning chasing
  // noise. Averaged over six seeds the count barely matters — 8/10/12/14 hazards all land
  // between 27 and 28.5 — so 12 is chosen for the arena it makes, not for the bytes.
  const target = Math.round(12 * density * (arenaRadius / 1400) ** 2);

  const minR = arenaRadius * SPAWN_CLEARANCE;
  const maxR = arenaRadius * WALL_CLEARANCE;

  let guard = 0;
  while (out.length < target && guard < target * 40) {
    guard++;

    // Uniform over the ANNULUS, not over the radius — sampling r uniformly would bunch
    // everything toward the centre, which is exactly where the clearance says not to put it.
    const a = rng.next() * Math.PI * 2;
    const r = Math.sqrt(
      minR * minR + rng.next() * (maxR * maxR - minR * minR)
    );
    const x = Math.cos(a) * r;
    const y = Math.sin(a) * r;

    // Roughly half rocks, a third spikes, the rest slicks: geography first, timing second,
    // friction as seasoning.
    const roll = rng.next();
    const kind: HazardKind = roll < 0.5 ? 'rock' : roll < 0.82 ? 'spike' : 'slick';

    const radius =
      kind === 'rock' ? 26 + rng.next() * 34 :
      kind === 'spike' ? 22 + rng.next() * 14 :
      70 + rng.next() * 50;   // slicks are large — they are terrain, not obstacles

    // No overlaps, with a gap wide enough for a snake to pass between two hazards.
    const clearance = 60;
    let clash = false;
    for (const h of out) {
      const dx = h.x - x, dy = h.y - y;
      if (Math.hypot(dx, dy) < h.r + radius + clearance) { clash = true; break; }
    }
    if (clash) continue;

    const hazard: Hazard = { k: kind, x: Math.round(x), y: Math.round(y), r: Math.round(radius) };
    if (kind === 'spike') {
      hazard.p = Math.round((2.4 + rng.next() * 2.2) * 10) / 10;
      // Offset per spike so a field does not pulse as one, which would read as a global
      // heartbeat rather than as independent traps.
      hazard.o = Math.round(rng.next() * (hazard.p ?? 3) * 10) / 10;
    }
    out.push(hazard);
  }

  return out;
}

/** Squared distance from a point to a hazard's centre — the hot-path test. */
export function hazardHit(h: Hazard, x: number, y: number, headR: number): boolean {
  const dx = h.x - x, dy = h.y - y;
  const rr = h.r + headR;
  return dx * dx + dy * dy <= rr * rr;
}
