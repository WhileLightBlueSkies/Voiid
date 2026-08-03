// Snake geometry — arena boundary, spline sampling, swept collision.
//
// Split out from index.ts because this is the only part of Snake that is pure maths with no
// knowledge of matches, players or Redis. It is also the part most likely to need tuning
// during playtesting, and the part a future Air Hockey / Pool module will want to borrow
// (the swept capsule test is the same problem).
//
// WHY SWEPT AND NOT DISCRETE. At boost speed a head moves further per tick than its own
// radius, so a point-in-circle test at each tick end would let a head pass straight through
// a body between two samples. Every head test here is therefore a capsule from the previous
// position to the new one. This is not premature rigour: at 12 Hz (our tick rate, per
// docs/GAMES.md §80) a head covers ~35 units per tick against an 11-unit radius, so
// tunnelling would be the common case, not the edge case.

/** Arena shapes. Circle is the only one used at launch; the rest cost nothing to keep. */
export type ArenaShape = 'circle' | 'square';

export interface Vec {
  x: number;
  y: number;
}

export function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

/** Signed shortest angular delta from a to b, in (-PI, PI]. */
export function shortestAngle(a: number, b: number): number {
  const TAU = Math.PI * 2;
  let d = (b - a) % TAU;
  if (d > Math.PI) d -= TAU;
  if (d < -Math.PI) d += TAU;
  return d;
}

export function dist2(ax: number, ay: number, bx: number, by: number): number {
  const dx = bx - ax;
  const dy = by - ay;
  return dx * dx + dy * dy;
}

/**
 * Signed distance to the arena boundary. Negative inside, zero exactly on the lethal line.
 *
 * Expressing the boundary as an SDF rather than a shape-specific test means adding an arena
 * shape later is one case here and nothing else — collision, spawn placement and bot
 * avoidance all read this one function.
 */
export function arenaSdf(shape: ArenaShape, radius: number, x: number, y: number): number {
  if (shape === 'square') {
    const dx = Math.abs(x) - radius;
    const dy = Math.abs(y) - radius;
    const outside = Math.hypot(Math.max(dx, 0), Math.max(dy, 0));
    return outside + Math.min(Math.max(dx, dy), 0);
  }
  return Math.hypot(x, y) - radius;
}

/**
 * Closest approach between two segments, squared.
 *
 * Uses the clamped-parametric method rather than a full analytic solve: for near-parallel
 * segments the analytic form is numerically unstable, and this runs for every head against
 * every nearby body sample on every tick.
 */
export function segmentSegmentDist2(
  a0x: number, a0y: number, a1x: number, a1y: number,
  b0x: number, b0y: number, b1x: number, b1y: number
): number {
  const dax = a1x - a0x, day = a1y - a0y;
  const dbx = b1x - b0x, dby = b1y - b0y;
  const rx = a0x - b0x, ry = a0y - b0y;

  const a = dax * dax + day * day;
  const e = dbx * dbx + dby * dby;
  const f = dbx * rx + dby * ry;

  let s: number, t: number;

  if (a < 1e-9 && e < 1e-9) return dist2(a0x, a0y, b0x, b0y);

  if (a < 1e-9) {
    s = 0;
    t = clamp(f / e, 0, 1);
  } else {
    const c = dax * rx + day * ry;
    if (e < 1e-9) {
      t = 0;
      s = clamp(-c / a, 0, 1);
    } else {
      const b = dax * dbx + day * dby;
      const denom = a * e - b * b;
      s = denom > 1e-9 ? clamp((b * f - c * e) / denom, 0, 1) : 0;
      t = (b * s + f) / e;
      if (t < 0) { t = 0; s = clamp(-c / a, 0, 1); }
      else if (t > 1) { t = 1; s = clamp((b - c) / a, 0, 1); }
    }
  }

  const cax = a0x + dax * s, cay = a0y + day * s;
  const cbx = b0x + dbx * t, cby = b0y + dby * t;
  return dist2(cax, cay, cbx, cby);
}

/**
 * Deterministic PRNG (mulberry32), seeded per match and threaded explicitly.
 *
 * Math.random() would be fatal here, not merely untidy: the runtime rebuilds the engine from
 * serialized state on every single input, so an engine using global randomness would produce
 * a different world each time it was restored. Determinism is what lets state round-trip
 * through Redis unchanged.
 */
export class Rng {
  private s: number;

  constructor(seed: number) {
    this.s = seed >>> 0;
  }

  /** Current seed, so it can be serialized and the sequence resumed exactly. */
  get seed(): number {
    return this.s;
  }

  next(): number {
    this.s = (this.s + 0x6d2b79f5) >>> 0;
    let t = this.s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  range(lo: number, hi: number): number {
    return lo + this.next() * (hi - lo);
  }
}

/**
 * Sample a point at arc distance `d` back from the head along a path polyline.
 *
 * `path` is [x0,y0, x1,y1, ...] with index 0 being the NEWEST point. Walks segment by
 * segment rather than binary-searching a cumulative-length array: at our tick rate a path is
 * a few hundred points and rebuilding a cumulative array on every restore would cost more
 * than the walk saves.
 *
 * Returns false when d exceeds the path — the caller treats that as "tail reached".
 */
export function samplePath(path: number[], d: number, out: Vec): boolean {
  if (path.length < 4) {
    if (path.length >= 2) { out.x = path[0]; out.y = path[1]; }
    return false;
  }

  let remaining = d;
  for (let i = 0; i + 3 < path.length; i += 2) {
    const ax = path[i], ay = path[i + 1];
    const bx = path[i + 2], by = path[i + 3];
    const seg = Math.hypot(bx - ax, by - ay);
    if (seg < 1e-6) continue;

    if (remaining <= seg) {
      const t = remaining / seg;
      out.x = ax + (bx - ax) * t;
      out.y = ay + (by - ay) * t;
      return true;
    }
    remaining -= seg;
  }

  out.x = path[path.length - 2];
  out.y = path[path.length - 1];
  return false;
}

/** Total arc length of a path polyline. */
export function pathLength(path: number[]): number {
  let total = 0;
  for (let i = 0; i + 3 < path.length; i += 2) {
    total += Math.hypot(path[i + 2] - path[i], path[i + 3] - path[i + 1]);
  }
  return total;
}

/**
 * Trim a path to `maxLen` of arc, so a snake's stored path never grows without bound.
 *
 * This matters more on the server than it did on the client: the path is part of the state
 * written to Redis on every tick, so an untrimmed path is unbounded memory AND unbounded
 * bandwidth, on every tick, for the life of the match.
 */
export function trimPath(path: number[], maxLen: number): void {
  let total = 0;
  for (let i = 0; i + 3 < path.length; i += 2) {
    const seg = Math.hypot(path[i + 2] - path[i], path[i + 3] - path[i + 1]);

    if (total + seg >= maxLen) {
      // Cut at the EXACT arc length by moving the final point along this segment, rather
      // than dropping the whole segment.
      //
      // Truncating on the segment boundary instead makes the tail quantise to whole
      // segments: it holds still while the head travels a segment's worth, then jumps back
      // by a full segment. At 12 Hz that is a visible twitch on every snake, every tick, and
      // it also makes the body length oscillate rather than hold steady.
      const t = seg > 1e-9 ? (maxLen - total) / seg : 0;
      path[i + 2] = path[i] + (path[i + 2] - path[i]) * t;
      path[i + 3] = path[i + 1] + (path[i + 3] - path[i + 1]) * t;
      path.length = i + 4;
      return;
    }
    total += seg;
  }
}
