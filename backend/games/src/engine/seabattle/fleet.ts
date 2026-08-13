// Sea Battle board geometry, fleet rules and placement validation (docs/games/future/SEA_BATTLE.md §2).
//
// Split from index.ts because all of it is pure: it takes cells and returns verdicts, holds no
// match state, and is therefore the part that can be exhaustively tested without building an
// engine. The rules a player would argue about live here.
import { Rng } from '../rng';

/** 10x10, columns A-J, rows 1-10. */
export const SIZE = 10;
export const CELLS = SIZE * SIZE;

/**
 * Coordinates travel as a packed integer `y * 10 + x` (0-99), never as a string.
 *
 * One number, indexes an array directly, and cannot be misparsed — "B10" and "B1" differ by a
 * character and a client that gets that wrong fires at the wrong square with no error anywhere.
 */
export const packed = (x: number, y: number): number => y * SIZE + x;
export const cx = (c: number): number => c % SIZE;
export const cy = (c: number): number => Math.floor(c / SIZE);

/**
 * The classic Milton Bradley set: 17 occupied squares of 100.
 *
 * NOT the Russian variant (one 4, two 3s, three 2s, four 1s) and not a house set. 17/100 is the
 * density the entire genre's intuition is calibrated to, and a player who has played Battleship
 * anywhere else must not have to relearn it. Single-square ships are also miserable to hunt:
 * they turn the endgame into a coin flip over the remaining squares rather than deduction.
 *
 * Index is the ship's type id, and that id is what travels on the wire.
 */
export const FLEET_SPEC = [5, 4, 3, 3, 2] as const;
export const SHIP_NAMES = ['Carrier', 'Battleship', 'Cruiser', 'Submarine', 'Destroyer'] as const;
export const FLEET_CELLS = FLEET_SPEC.reduce((a, b) => a + b, 0); // 17

export interface Ship {
  /** Index into FLEET_SPEC. */
  type: number;
  /** Packed cells, in order along the ship. */
  cells: number[];
  /** How many of those cells have been hit. Sunk when it reaches cells.length. */
  hits: number;
}

export type PlacementError =
  | 'wrong-ship-count'
  | 'duplicate-type'
  | 'unknown-type'
  | 'wrong-length'
  | 'off-board'
  | 'not-contiguous'
  | 'overlap';

/**
 * Validate a whole proposed fleet.
 *
 * NOTHING IS TRUSTED ABOUT SHIP IDENTITY. The length is recomputed from the ship's own cells and
 * checked against FLEET_SPEC, so a client claiming a two-cell Carrier is rejected rather than
 * believed. Every rejection reason is returned distinctly because the client renders a different
 * message for each, and because a test that can only assert "rejected" cannot tell a
 * correctly-rejected fleet from one rejected for the wrong reason.
 */
export function validateFleet(ships: Ship[]): PlacementError | null {
  if (!Array.isArray(ships) || ships.length !== FLEET_SPEC.length) return 'wrong-ship-count';

  const seenTypes = new Set<number>();
  const occupied = new Set<number>();

  for (const ship of ships) {
    const type = ship?.type;
    if (typeof type !== 'number' || !Number.isInteger(type) || type < 0 || type >= FLEET_SPEC.length) {
      return 'unknown-type';
    }
    if (seenTypes.has(type)) return 'duplicate-type';
    seenTypes.add(type);

    const cells = ship.cells;
    if (!Array.isArray(cells) || cells.length !== FLEET_SPEC[type]) return 'wrong-length';

    for (const c of cells) {
      if (typeof c !== 'number' || !Number.isInteger(c) || c < 0 || c >= CELLS) return 'off-board';
      // Across the WHOLE fleet, not just this ship — ships may not overlap each other, and a
      // ship may not double back over itself.
      if (occupied.has(c)) return 'overlap';
      occupied.add(c);
    }

    if (!isContiguousLine(cells)) return 'not-contiguous';
  }

  return null;
}

/**
 * Contiguous and collinear along one row or one column.
 *
 * THIS SINGLE CHECK IS WHAT ENFORCES "NO DIAGONALS" — there is no separate diagonal rule,
 * because a diagonal ship is by definition neither in one row nor in one column. Diagonal
 * placement would roughly double the search space in a way that stops the hunt/target heuristic
 * working, and that heuristic is the thing that makes the game feel like reasoning.
 *
 * It also catches row wrap. A horizontal ship must not run off J and reappear at A on the next
 * row: packed cells 8,9,10 are consecutive integers but 10 is a different row, so requiring an
 * identical row for a horizontal ship rejects it. Working in packed integers is exactly where a
 * naive `cells[i+1] === cells[i]+1` check goes wrong.
 */
function isContiguousLine(cells: number[]): boolean {
  if (cells.length < 2) return true;

  const sameRow = cells.every((c) => cy(c) === cy(cells[0]));
  const sameCol = cells.every((c) => cx(c) === cx(cells[0]));
  if (!sameRow && !sameCol) return false;

  const step = sameRow ? 1 : SIZE;
  const sorted = [...cells].sort((a, b) => a - b);
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i] - sorted[i - 1] !== step) return false;
  }
  return true;
}

/**
 * A legal fleet placed at random, drawn from the match RNG.
 *
 * MANDATORY, AND THE DEFAULT PATH (§2.2). A player who has to place five ships before their
 * first shot is a player who may not get to the first shot; the board arrives already populated
 * and READY is one tap. Placing by hand stays available, and most people discover it after their
 * first match, which is the right order.
 *
 * SHIPS MAY TOUCH, including at corners — deliberately against the Russian rules. Forbidding
 * contact makes a sunk ship's neighbours provably empty, which is more structure but a large
 * free gift that shortens matches, and it makes placement fiddly on a phone: a player drags a
 * ship, gets a red cell, and has to work out the problem is a diagonal neighbour they cannot see.
 */
export function randomFleet(rng: Rng): Ship[] {
  // Bounded retry rather than backtracking. With 17 cells in 100 a rejection is rare and a
  // restart is cheaper than the bookkeeping; the loop is bounded so a pathological seed cannot
  // hang the service rather than because failure is expected.
  for (let attempt = 0; attempt < 200; attempt++) {
    const ships: Ship[] = [];
    const occupied = new Set<number>();
    let ok = true;

    // Longest first: a Carrier placed last into a crowded board is what makes attempts fail.
    for (let type = 0; type < FLEET_SPEC.length && ok; type++) {
      const len = FLEET_SPEC[type];
      let placed = false;

      for (let tries = 0; tries < 100 && !placed; tries++) {
        const horizontal = rng.next() < 0.5;
        const x = rng.int(horizontal ? SIZE - len + 1 : SIZE);
        const y = rng.int(horizontal ? SIZE : SIZE - len + 1);
        const cells: number[] = [];
        for (let i = 0; i < len; i++) {
          cells.push(horizontal ? packed(x + i, y) : packed(x, y + i));
        }
        if (cells.some((c) => occupied.has(c))) continue;
        for (const c of cells) occupied.add(c);
        ships.push({ type, cells, hits: 0 });
        placed = true;
      }

      if (!placed) ok = false;
    }

    if (ok) return ships;
  }

  // Unreachable in practice; a deterministic fallback is still better than throwing inside a
  // match. Ships laid in the first rows, one per row, which is legal and dull.
  return FLEET_SPEC.map((len, type) => ({
    type,
    cells: Array.from({ length: len }, (_, i) => packed(i, type)),
    hits: 0,
  }));
}
