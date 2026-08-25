// Ludo board geometry and movement maths (LUDO_GAME_SPEC.md §3, §5).
//
// Split from index.ts because all of it is pure: it takes a position and a die and returns a
// position, holds no match state, and is therefore the part that can be tested exhaustively.
// The tables here are the SINGLE SOURCE the checked-in geometry fixture
// (packages/design-tokens/fixtures/ludo_board_v3.json) is generated from and validated
// against — clients mirror them literally, and the parity tests fail if any copy drifts.

/** Main track: 52 shared squares, indices 0-51. */
export const TRACK_COUNT = 52;
/** Home column: 5 private squares per seat. */
export const HOME_LANE_COUNT = 5;
export const MAX_SEATS = 4;
export const TOKENS_PER_SEAT = 4;

/**
 * A token's position is ONE integer:
 *
 *   -1        in the yard (pawn index selects the yard slot)
 *   0..51     on the main track, ABSOLUTE index
 *   100..104  in the owner's home lane, 100 + homeStep
 *   200       finished/home
 */
export const YARD = -1;
export const HOME_LANE_BASE = 100;
export const FINISHED = 200;

export const inYard = (p: number) => p === YARD;
export const onTrack = (p: number) => p >= 0 && p < TRACK_COUNT;
export const inHomeLane = (p: number) => p >= HOME_LANE_BASE && p < HOME_LANE_BASE + HOME_LANE_COUNT;
export const isFinishedPos = (p: number) => p === FINISHED;

/**
 * Fixed physical seats. The board never rotates and the colour order never changes:
 * red bottom-left, green top-left, yellow top-right, blue bottom-right. Clockwise turn
 * order red → green → yellow → blue is plain ascending seat order.
 */
export type SeatColor = 'red' | 'green' | 'yellow' | 'blue';
export const SEAT_COLORS: SeatColor[] = ['red', 'green', 'yellow', 'blue'];
/** Duel uses opposite seats only. */
export const DUEL_SEATS = [0, 2];

/** Shared-track absolute indices → board coordinates (x right, y down), (0,0) top-left. */
export const TRACK_COORDS: ReadonlyArray<readonly [number, number]> = [
    [6, 13], [6, 12], [6, 11], [6, 10], [6, 9], [5, 8],
    [4, 8], [3, 8], [2, 8], [1, 8], [0, 8], [0, 7],
    [0, 6], [1, 6], [2, 6], [3, 6], [4, 6], [5, 6],
    [6, 5], [6, 4], [6, 3], [6, 2], [6, 1], [6, 0],
    [7, 0], [8, 0], [8, 1], [8, 2], [8, 3], [8, 4],
    [8, 5], [9, 6], [10, 6], [11, 6], [12, 6], [13, 6],
    [14, 6], [14, 7], [14, 8], [13, 8], [12, 8], [11, 8],
    [10, 8], [9, 8], [8, 9], [8, 10], [8, 11], [8, 12],
    [8, 13], [8, 14], [7, 14], [6, 14],
];

/** The eight starred/entry safe indices. A capture may never occur on one. */
export const SAFE_INDICES = new Set([0, 8, 13, 21, 26, 34, 39, 47]);
export const isSafe = (p: number) => onTrack(p) && SAFE_INDICES.has(p);

/** Colored start cells are fully filled and contain no symbol. */
export const ENTRY_INDICES = [0, 13, 26, 39];
export const STAR_INDICES = [8, 21, 34, 47];
/** Non-safe approach cells carry the open chevrons. */
export const APPROACH_INDICES = [50, 11, 24, 37];

/** Per-seat start index on the shared track: 0, 13, 26, 39. */
export const START_INDICES = [0, 13, 26, 39];
export const startIndex = (seat: number) => START_INDICES[seat] ?? (seat * 13) % TRACK_COUNT;

/**
 * How far a token has travelled from its own start, 0-51.
 *
 * The one conversion the absolute encoding costs, done here rather than inline so there is
 * exactly one copy of the modular arithmetic.
 */
export const progressOf = (absolute: number, seat: number) =>
    (absolute - startIndex(seat) + TRACK_COUNT) % TRACK_COUNT;

/** Home lane coordinates per seat, OUTSIDE to INSIDE (homeStep 0..4). */
export const HOME_LANE_COORDS: ReadonlyArray<ReadonlyArray<readonly [number, number]>> = [
    [[7, 13], [7, 12], [7, 11], [7, 10], [7, 9]],   // red, bottom-left
    [[1, 7], [2, 7], [3, 7], [4, 7], [5, 7]],       // green, top-left
    [[7, 1], [7, 2], [7, 3], [7, 4], [7, 5]],       // yellow, top-right
    [[13, 7], [12, 7], [11, 7], [10, 7], [9, 7]],   // blue, bottom-right
];

/**
 * Yard pawn slots per seat, in pawn order, as CONTINUOUS grid coordinates — not cell indices.
 *
 * Each 6x6 yard starts at its origin below; the pocket drawn inside it spans origin+0.8 to
 * origin+5.2, so its centre is origin+3. The four slots sit at that centre ±1 on both axes,
 * which is what makes them read as evenly inset from the pocket edge.
 *
 * These used to be cell indices, and were consumed as cell CENTRES (index + 0.5), which pushed
 * every pawn half a cell down-right. Seats 2 and 3 were additionally a full cell off, so their
 * pawns sat visibly closer to one pocket edge than the other — the "floating" look.
 */
const YARD_ORIGINS: ReadonlyArray<readonly [number, number]> = [
    [0, 9],   // red, bottom-left
    [0, 0],   // green, top-left
    [9, 0],   // yellow, top-right
    [9, 9],   // blue, bottom-right
];

export const YARD_SLOTS: ReadonlyArray<ReadonlyArray<readonly [number, number]>> =
    YARD_ORIGINS.map(([ox, oy]) => [
        [ox + 2, oy + 2],
        [ox + 4, oy + 2],
        [ox + 2, oy + 4],
        [ox + 4, oy + 4],
    ] as ReadonlyArray<readonly [number, number]>);

/** Center-local finish slots, indexed by physical seat then pawn index. */
export const FINISH_SLOTS: ReadonlyArray<ReadonlyArray<readonly [number, number]>> = [
    [[1.15, 2.15], [1.85, 2.15], [1.15, 2.65], [1.85, 2.65]],
    [[0.35, 1.15], [0.85, 1.15], [0.35, 1.85], [0.85, 1.85]],
    [[1.15, 0.35], [1.85, 0.35], [1.15, 0.85], [1.85, 0.85]],
    [[2.15, 1.15], [2.65, 1.15], [2.15, 1.85], [2.65, 1.85]],
];

/** The center occupies this inclusive rect; four triangles meet at its middle. */
export const CENTER_RECT = { x0: 6, y0: 6, x1: 8, y1: 8 };

/**
 * Where a token ends up, or null when the move is illegal.
 *
 * THIS IS THE ONLY PLACE MOVEMENT IS COMPUTED (spec §5.2): validation, auto-play and the
 * timeout sweeper are consumers of one function and cannot disagree.
 *
 * Blocks are NOT considered here; they need the whole board and are applied by rules.ts.
 */
export function destination(pos: number, die: number, seat: number): number | null {
    if (isFinishedPos(pos)) return null;

    // A 6 is required to leave the yard, and it places the token on the start index — it does
    // NOT then advance another six cells.
    if (inYard(pos)) return die === 6 ? startIndex(seat) : null;

    if (inHomeLane(pos)) {
        const step = pos - HOME_LANE_BASE + die;
        if (step === HOME_LANE_COUNT) return FINISHED;
        // EXACT COUNT REQUIRED TO REACH FINISHED. Overshooting is illegal, not clamped.
        if (step > HOME_LANE_COUNT) return null;
        return HOME_LANE_BASE + step;
    }

    // On the main track. Measure progress from this seat's own start to know when the token
    // turns off into its home lane.
    const travelled = progressOf(pos, seat);
    const next = travelled + die;

    // 51 squares of track, then 5 of lane, then finished: travelled 52 lands on lane step 0,
    // travelled 56 lands exactly on FINISHED.
    if (next === TRACK_COUNT + HOME_LANE_COUNT) return FINISHED;
    if (next > TRACK_COUNT + HOME_LANE_COUNT) return null;
    if (next >= TRACK_COUNT) return HOME_LANE_BASE + (next - TRACK_COUNT);

    return (startIndex(seat) + next) % TRACK_COUNT;
}

/**
 * The squares a token passes THROUGH, excluding where it starts and including where it lands.
 *
 * Needed for blocks: an opponent's block cannot be landed on OR passed, so the whole path
 * matters, not just the destination. A token entering from the yard passes nothing — it is
 * placed directly on its start cell.
 *
 * Also returned on the wire as `lastAction.move.path` so every client animates the exact
 * same route without re-deriving it (§15).
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

/** Track index → coordinate, for tests and the fixture generator. */
export const trackCoord = (i: number): readonly [number, number] => TRACK_COORDS[i];
