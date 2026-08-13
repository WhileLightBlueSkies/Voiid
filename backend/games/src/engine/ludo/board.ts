// Ludo board geometry and movement maths (docs/games/future/LUDO.md §2.1, §2.2).
//
// Split from index.ts because all of it is pure: it takes a position and a die and returns a
// position, holds no match state, and is therefore the part that can be tested exhaustively.
// The rules four players will argue about live here.

/** Main track: 52 shared squares, indices 0-51. */
export const TRACK = 52;
/** Home column: 5 private squares per player. */
export const COLUMN = 5;
export const MAX_SEATS = 4;

/**
 * A token's position is ONE integer:
 *
 *   -1        in the yard
 *   0..51     on the main track, ABSOLUTE index
 *   100..104  in the home column, 100 + step
 *   200       home
 *
 * ABSOLUTE TRACK INDICES, NOT PER-PLAYER RELATIVE ONES. Relative encoding makes "am I on the
 * same square as an opponent?" a conversion at every comparison, and capture checks run against
 * every opponent token on every move. One conversion at move time is cheaper and much harder to
 * get wrong.
 */
export const YARD = -1;
export const COLUMN_BASE = 100;
export const HOME = 200;

export const inYard = (p: number) => p === YARD;
export const onTrack = (p: number) => p >= 0 && p < TRACK;
export const inColumn = (p: number) => p >= COLUMN_BASE && p < COLUMN_BASE + COLUMN;
export const isHome = (p: number) => p === HOME;

/** Player `p`'s entry square: 0, 13, 26, 39. */
export const entrySquare = (seat: number) => (seat * 13) % TRACK;

/**
 * The eight starred squares: the four entry squares and the four 8 ahead of each.
 *
 * NO CAPTURE MAY OCCUR ON A SAFE SQUARE. This is the rule that stops the most-quit-inducing
 * moment in any Ludo implementation — a token sent home one square from its own column.
 */
export const SAFE_SQUARES = new Set([0, 8, 13, 21, 26, 34, 39, 47]);
export const isSafe = (p: number) => onTrack(p) && SAFE_SQUARES.has(p);

/**
 * How far a token has travelled from its own entry, 0-51.
 *
 * The one conversion the absolute encoding costs, and it is done here rather than inline so
 * there is exactly one copy of the modular arithmetic. Getting this wrong shifts a player's
 * whole home column and is invisible until someone overshoots.
 */
export const relative = (absolute: number, seat: number) =>
  (absolute - entrySquare(seat) + TRACK) % TRACK;

/**
 * Where a token ends up, or null when the move is illegal.
 *
 * THIS IS THE ONLY PLACE MOVEMENT IS COMPUTED. LUDO.md §4.2 requires one code path for "what
 * can this player do", used by validation, auto-move, timeout auto-play and the bot — four
 * consumers of one function cannot disagree about the rules.
 *
 * Blocks are NOT considered here; they need the whole board and are applied by the caller
 * (§2.4). This answers the narrower question: where does this die take this token.
 */
export function destination(pos: number, die: number, seat: number): number | null {
  if (isHome(pos)) return null;

  // A 6 is required to leave the yard, and it places the token on the entry square — it does
  // NOT then move 6 more. That is the rule people most often implement twice.
  if (inYard(pos)) return die === 6 ? entrySquare(seat) : null;

  if (inColumn(pos)) {
    const step = pos - COLUMN_BASE + die;
    if (step === COLUMN) return HOME;
    // EXACT ROLL REQUIRED TO REACH HOME. A token 3 from home cannot move on a 5 — the move is
    // illegal rather than clamped, and if no legal move exists the turn passes.
    if (step > COLUMN) return null;
    return COLUMN_BASE + step;
  }

  // On the main track. Measure progress from this seat's own entry to know when the token
  // turns off into its home column.
  const travelled = relative(pos, seat);
  const next = travelled + die;

  // 51 squares of track, then 5 of column, then home: 52 lands on the first column square.
  if (next === TRACK + COLUMN) return HOME;
  if (next > TRACK + COLUMN) return null;   // overshoot — illegal, same as the column case
  if (next >= TRACK) return COLUMN_BASE + (next - TRACK);

  return (entrySquare(seat) + next) % TRACK;
}

/**
 * The squares a token passes THROUGH, excluding where it starts and including where it lands.
 *
 * Needed only for blocks: an opponent's block cannot be landed on OR passed (§2.4), so the
 * whole path matters, not just the destination. A token entering from the yard passes nothing —
 * it is placed directly on its entry square.
 */
export function path(pos: number, die: number, seat: number): number[] {
  if (inYard(pos)) {
    const dest = destination(pos, die, seat);
    return dest === null ? [] : [dest];
  }
  const squares: number[] = [];
  for (let step = 1; step <= die; step++) {
    const at = destination(pos, step, seat);
    if (at === null) return squares;
    squares.push(at);
  }
  return squares;
}
