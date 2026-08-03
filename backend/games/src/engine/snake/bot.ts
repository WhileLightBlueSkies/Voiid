// Practice-mode bots.
//
// SCOPE NOTE. docs/GAMES.md §1 states there is no offline/bot mode in the plan, and §17
// says a "play a bot" mode is a valid later addition but out of scope. This is that
// addition, built deliberately and kept narrow: bots exist so a player can learn the
// controls without waiting for an opponent, and so a one-player match is not an empty arena.
// They are NOT a stand-in for matchmaking.
//
// They run SERVER-SIDE, inside the same engine as everyone else. That is the only honest
// place for them: a client-side bot would mean the client simulating snakes the server also
// simulates, which is exactly the divergence server-authority exists to prevent.
//
// A bot steers by writing `th` — the same field a human's input frame writes. It gets no
// speed bonus, no wider turn arc, no wall immunity and no knowledge it should not have. If a
// bot beats you, it beat you with your own controls.

import {
  arenaSdf,
  shortestAngle,
  type ArenaShape,
  type Rng,
} from './geometry';

export interface BotMemory {
  /** Index into the food array it is currently going for; -1 when none. */
  targetFood: number;
  /** Seconds until it may reconsider. Prevents dithering between equal pellets. */
  retarget: number;
  /** Phase for the heading wobble that stops bots travelling on perfect straight lines. */
  jitter: number;
}

interface BotSnake {
  id: string;
  x: number;
  y: number;
  h: number;
  th: number;
  mass: number;
  alive: boolean;
  boost: boolean;
  path: number[];
}

interface Food {
  x: number;
  y: number;
  v: number;
}

const DEG = Math.PI / 180;

/**
 * One bot decision. Priority order is survival, then food — deliberately simple.
 *
 * A more elaborate hunting bot was tempting, but the failure mode of aggressive bot AI is
 * that it suicides into walls chasing kills it cannot survive, which reads as broken rather
 * than as difficult. A bot that reliably avoids death and reliably eats is a better
 * practice partner than one that occasionally makes a brilliant play and usually dies.
 */
export function stepBot(
  sn: BotSnake,
  mem: BotMemory,
  dt: number,
  all: BotSnake[],
  food: Food[],
  arena: ArenaShape,
  arenaRadius: number,
  rng: Rng
): void {
  sn.boost = false;

  const speed = 240;

  // --- Survival: border ---------------------------------------------------------------
  // The awareness distance is derived from the turn radius, not picked by feel. A bot must
  // start turning while it still has room to complete the turn; below speed/turnRate no
  // amount of reaction time saves it, and every wall becomes lethal.
  const turnRadius = speed / (260 * DEG);
  const awareness = turnRadius * 1.7;

  const borderDist = -arenaSdf(arena, arenaRadius, sn.x, sn.y);
  const lookX = sn.x + Math.cos(sn.h) * speed * 0.9;
  const lookY = sn.y + Math.sin(sn.h) * speed * 0.9;
  const wallAhead = arenaSdf(arena, arenaRadius, lookX, lookY) + 11 >= 0;

  if (borderDist < awareness || wallAhead) {
    // Steer toward the arena centre. For a circle the inward direction is simply the
    // bearing to the origin, which avoids a numeric-gradient normal entirely.
    const inward = Math.atan2(-sn.y, -sn.x);
    if (borderDist < awareness * 0.55) {
      sn.th = inward;
    } else {
      // Further out, prefer the tangent nearer the current heading so the bot arcs away
      // rather than making an obvious U-turn.
      const tA = inward + Math.PI / 2.4;
      const tB = inward - Math.PI / 2.4;
      sn.th = Math.abs(shortestAngle(sn.h, tA)) < Math.abs(shortestAngle(sn.h, tB)) ? tA : tB;
    }
    mem.targetFood = -1;
    return;
  }

  // --- Survival: bodies ----------------------------------------------------------------
  // Cheap directional probe rather than a full ray-march: sample a few headings and take the
  // one with the most clearance. At 12 Hz this is plenty of resolution to avoid a body.
  const probe = speed * 0.75;
  let blocked = false;
  for (const other of all) {
    if (!other.alive || other.id === sn.id) continue;
    const path = other.path;
    for (let i = 0; i < path.length; i += 8) {
      const dx = path[i] - lookX, dy = path[i + 1] - lookY;
      if (dx * dx + dy * dy < 40 * 40) { blocked = true; break; }
    }
    if (blocked) break;
  }

  if (blocked) {
    let bestH = sn.h;
    let bestClear = -1;
    for (let deg = -90; deg <= 90; deg += 15) {
      const h = sn.h + deg * DEG;
      const px = sn.x + Math.cos(h) * probe;
      const py = sn.y + Math.sin(h) * probe;
      if (arenaSdf(arena, arenaRadius, px, py) + 11 >= 0) continue;

      let clear = Infinity;
      for (const other of all) {
        if (!other.alive || other.id === sn.id) continue;
        const path = other.path;
        for (let i = 0; i < path.length; i += 8) {
          const d = Math.hypot(path[i] - px, path[i + 1] - py);
          if (d < clear) clear = d;
        }
      }
      // Bias toward small turns, so escaping never looks like a physically impossible flip.
      const score = clear - Math.abs(deg) * 0.6;
      if (score > bestClear) { bestClear = score; bestH = h; }
    }
    sn.th = bestH;
    mem.targetFood = -1;
    return;
  }

  // --- Feed -----------------------------------------------------------------------------
  mem.retarget -= dt;
  if (mem.retarget <= 0 || mem.targetFood < 0 || mem.targetFood >= food.length) {
    mem.retarget = 0.6;
    let best = -1;
    let bestScore = -Infinity;

    // Sample rather than scan: the food array runs to several hundred items and every bot
    // would otherwise walk all of it every retarget.
    const stride = Math.max(1, Math.floor(food.length / 60));
    const offset = Math.floor(rng.next() * stride);
    for (let i = offset; i < food.length; i += stride) {
      const f = food[i];
      const d2 = (f.x - sn.x) ** 2 + (f.y - sn.y) ** 2;
      if (d2 < 1) continue;

      // Prefer close and valuable, and discount food hugging the wall — chasing a pellet
      // into the boundary is the most common way a naive bot kills itself.
      const edge = -arenaSdf(arena, arenaRadius, f.x, f.y);
      const safety = Math.min(1, edge / 300);
      const score = (f.v / d2) * 1e6 * safety;
      if (score > bestScore) { bestScore = score; best = i; }
    }
    mem.targetFood = best;
  }

  if (mem.targetFood >= 0 && mem.targetFood < food.length) {
    const f = food[mem.targetFood];
    sn.th = Math.atan2(f.y - sn.y, f.x - sn.x);
  } else {
    // Nothing worth eating: drift, gently curving, rather than freezing on one heading.
    mem.jitter += dt * 1.4;
    sn.th = sn.h + Math.sin(mem.jitter) * 0.5;
  }

  // Heading jitter. A bot travelling a perfectly straight line is instantly identifiable as
  // a bot; two degrees of wobble costs nothing and removes the tell.
  mem.jitter += dt * 2.6;
  sn.th += Math.sin(mem.jitter) * 2 * DEG;
}
