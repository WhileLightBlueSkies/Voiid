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

import { TUNING } from './index';
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

/** How close a smaller snake must be before a bot commits to cutting it off. */
const HUNT_RADIUS = 420;

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
  /**
   * Arena geography. A bot that does not know about rocks drives into them, which is not a
   * difficulty setting — it is a broken opponent, and the headless test caught exactly that:
   * 14 deaths in 25 seconds once hazards existed.
   */
  hazards: readonly { k: string; x: number; y: number; r: number }[] = [],
  rng: Rng
): void {
  sn.boost = false;

  // Read from TUNING rather than hardcoded.
  //
  // These were literals (240 and 260 deg/s) calibrated for the old, slower game, and after
  // the speed/turn-rate increase the bots' wall avoidance was tuned for a game that no longer
  // existed: they began braking far too late and drove into the boundary. A bot that dies to
  // a wall it "saw" reads as broken, and the numbers must not be able to drift from the
  // simulation's again.
  const speed = TUNING.BASE_SPEED;

  // --- Survival: border ---------------------------------------------------------------
  // The awareness distance is derived from the turn radius, not picked by feel. A bot must
  // start turning while it still has room to complete the turn; below speed/turnRate no
  // amount of reaction time saves it, and every wall becomes lethal.
  const turnRadius = speed / (TUNING.TURN_RATE * DEG);
  // 2.6x the turn radius, widened from 1.7 after the speed increase.
  //
  // A turn radius is the space needed for a PERFECT turn started at exactly the right
  // instant. A bot decides at 10 Hz, so it can be up to a tick late, and it may already be
  // turning the wrong way when it notices — 1.7x left no room for either and bots drove into
  // the wall in numbers. The margin has to cover the reaction, not just the geometry.
  const awareness = turnRadius * 2.6;

  const borderDist = -arenaSdf(arena, arenaRadius, sn.x, sn.y);
  // Look a full second ahead, not 0.9 — at 300 u/s that is 300 units of warning.
  const lookX = sn.x + Math.cos(sn.h) * speed * 1.0;
  const lookY = sn.y + Math.sin(sn.h) * speed * 1.0;
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

  // --- Survival: rocks -----------------------------------------------------------------
  //
  // MODELLED ON THE WALL, NOT ON BODIES, and that distinction is the whole fix. The first
  // attempt treated a rock as an obstacle to react to once it was already in front of the
  // head, which is how a body is handled — and bots died to rocks 12 times in 25 seconds.
  //
  // A wall gets an AWARENESS RADIUS covering the turn radius plus reaction time, because a bot
  // decides at 10 Hz and may already be turning the wrong way when it notices. A rock is the
  // same problem in the middle of the arena, so it gets the same margin: steer away as soon as
  // one is within reach, rather than when it is unavoidable.
  {
    let worst: { h: typeof hazards[number]; d: number } | null = null;
    for (const h of hazards) {
      if (h.k !== 'rock') continue;
      const d = Math.hypot(h.x - sn.x, h.y - sn.y) - h.r;
      // Only rocks roughly ahead matter — one behind is not a threat, and steering away from
      // it would make bots wander.
      const bearing = Math.atan2(h.y - sn.y, h.x - sn.x);
      if (Math.abs(shortestAngle(sn.h, bearing)) > Math.PI / 2.2) continue;
      // A WIDER MARGIN THAN THE WALL'S, because a rock can be dodged on either side and the
      // arena cannot. Tuned against the headless test: at plain `awareness` bots still died to
      // rocks often enough to fail the survival check, because the cone below only considers
      // rocks roughly ahead — so a rock entering the cone late needs the extra room.
      if (d < awareness * 1.6 && (!worst || d < worst.d)) worst = { h, d };
    }
    if (worst) {
      // Turn to whichever side clears the rock with the smaller course change, so avoidance
      // arcs around it rather than reading as a panic flip.
      const bearing = Math.atan2(worst.h.y - sn.y, worst.h.x - sn.x);
      const away = shortestAngle(sn.h, bearing) > 0 ? -1 : 1;
      // Wider turn the closer it is: a rock at arm's length needs a hard commit, one at the
      // edge of awareness only needs a nudge.
      const urgency = 1 - Math.max(0, worst.d) / (awareness * 1.6);
      sn.th = sn.h + away * (Math.PI / 3) * (0.45 + 0.55 * urgency);
      mem.targetFood = -1;
      return;
    }
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

  // A ROCK AHEAD BLOCKS, exactly as a body does. Spikes and slicks deliberately do NOT: a
  // spike is survivable and a slick is only slow, so steering hard around either would make
  // bots look frightened of terrain that is not actually dangerous.
  if (!blocked) {
    for (const h of hazards) {
      if (h.k !== 'rock') continue;
      const dx = h.x - lookX, dy = h.y - lookY;
      const reach = h.r + 34;
      if (dx * dx + dy * dy < reach * reach) { blocked = true; break; }
    }
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
      // Score rocks into the SAME clearance number rather than as a separate veto: an escape
      // turn that dodges a body straight into a rock is not an escape.
      for (const h of hazards) {
        if (h.k !== 'rock') continue;
        const d = Math.hypot(h.x - px, h.y - py) - h.r;
        if (d < clear) clear = d;
      }
      // Bias toward small turns, so escaping never looks like a physically impossible flip.
      const score = clear - Math.abs(deg) * 0.6;
      if (score > bestClear) { bestClear = score; bestH = h; }
    }
    sn.th = bestH;
    mem.targetFood = -1;
    return;
  }

  // --- Hunt ------------------------------------------------------------------------------
  //
  // Bots previously only survived and ate, which is why testing read them as passive. A bot
  // that never threatens you makes the arena feel empty however many are in it.
  //
  // The rule is deliberately narrow: cut ahead of a SMALLER snake that is already close.
  // Intercepting where the target WILL be (rather than where it is) is what makes a cut-off
  // work at all — steering at a moving target just follows it forever.
  //
  // Only smaller targets, because head-to-head kills the shorter snake: a bot that charged
  // something bigger would be suiciding, which reads as broken rather than as aggressive.
  var huntTarget: BotSnake | null = null;
  var huntDist = Infinity;
  for (const other of all) {
    if (!other.alive || other.id === sn.id) continue;
    // A clear size advantage, so the bot wins the exchange it is starting.
    if (other.mass > sn.mass * 0.85) continue;
    const d = Math.hypot(other.x - sn.x, other.y - sn.y);
    if (d < huntDist && d < HUNT_RADIUS) { huntDist = d; huntTarget = other; }
  }

  if (huntTarget) {
    // Lead the target by roughly the time it takes to reach it.
    const lead = Math.min(huntDist / speed, 1.2);
    const px = huntTarget.x + Math.cos(huntTarget.h) * speed * lead;
    const py = huntTarget.y + Math.sin(huntTarget.h) * speed * lead;

    // Never chase into the wall, and never chase while ALREADY short of room. A bot that
    // trades a kill for its own death reads as broken, not as aggressive — and at the higher
    // speed it now runs at, the wall arrives sooner than it used to.
    const ownRoom = -arenaSdf(arena, arenaRadius, sn.x, sn.y);
    // Require more room than the wall-avoidance threshold, so hunting can never pull a bot
    // into the band where it should already be turning away.
    if (-arenaSdf(arena, arenaRadius, px, py) > awareness && ownRoom > awareness * 1.4) {
      sn.th = Math.atan2(py - sn.y, px - sn.x);
      mem.jitter += dt * 2.6;
      sn.th += Math.sin(mem.jitter) * 2 * DEG;
      return;
    }
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
