// The 15×15 addressable board-cell model (LUDO_GAME_SPEC.md §3).
//
// ONE immutable array of 225 nodes in row-major order. Clients mirror this layout literally;
// the checked-in fixture (packages/design-tokens/fixtures/ludo_board_v2.json) is generated
// from these tables and the parity tests fail if any copy drifts.
import {
    CENTER_RECT,
    ENTRY_INDICES,
    HOME_LANE_COORDS,
    SAFE_INDICES,
    STAR_INDICES,
    TRACK_COORDS,
    YARD_SLOTS,
} from './board';

export type CellRole =
    | 'yard'
    | 'yardPocket'
    | 'sharedTrack'
    | 'homeLane'
    | 'center'
    | 'unused';

export type CellDecoration = 'none' | 'star' | 'entryChevron';

export interface BoardCellNode {
    /** "cell-x-y" — stable across platforms and releases. */
    id: string;
    x: number;
    y: number;
    role: CellRole;
    /** Owner seat 0..3 or null for shared cells. */
    seat: number | null;
    trackIndex: number | null;
    homeStep: number | null;
    isSafe: boolean;
    decoration: CellDecoration;
}

const SIDE = 15;

const TRACK_AT = new Map<string, number>(
    TRACK_COORDS.map(([x, y], i) => [`${x},${y}`, i]),
);

const HOME_LANE_AT = new Map<string, { seat: number; step: number }>(
    HOME_LANE_COORDS.flatMap((lane, seat) =>
        lane.map(([x, y], step) => [`${x},${y}`, { seat, step }] as const),
    ),
);

function inCenter(x: number, y: number): boolean {
    return (
        x >= CENTER_RECT.x0 &&
        x <= CENTER_RECT.x1 &&
        y >= CENTER_RECT.y0 &&
        y <= CENTER_RECT.y1
    );
}

/**
 * Quadrant origins: red bottom-left (0,9), green top-left (0,0), yellow top-right (9,0),
 * blue bottom-right (9,9). Each 6×6 quadrant's INNER 4×4 region is the inset pawn pocket.
 */
function quadrantOf(x: number, y: number): { seat: number; ox: number; oy: number } | null {
    if (x < 6 && y < 6) return { seat: 1, ox: 0, oy: 0 };
    if (x > 8 && y < 6) return { seat: 2, ox: 9, oy: 0 };
    if (x < 6 && y > 8) return { seat: 0, ox: 0, oy: 9 };
    if (x > 8 && y > 8) return { seat: 3, ox: 9, oy: 9 };
    return null;
}

export function buildBoardCells(): BoardCellNode[] {
    const cells: BoardCellNode[] = [];
    for (let y = 0; y < SIDE; y++) {
        for (let x = 0; x < SIDE; x++) {
            const key = `${x},${y}`;
            const node: BoardCellNode = {
                id: `cell-${x}-${y}`,
                x,
                y,
                role: 'unused',
                seat: null,
                trackIndex: null,
                homeStep: null,
                isSafe: false,
                decoration: 'none',
            };

            if (inCenter(x, y)) {
                node.role = 'center';
            } else if (TRACK_AT.has(key)) {
                const idx = TRACK_AT.get(key)!;
                node.role = 'sharedTrack';
                node.trackIndex = idx;
                node.isSafe = SAFE_INDICES.has(idx);
                node.decoration = ENTRY_INDICES.includes(idx)
                    ? 'entryChevron'
                    : STAR_INDICES.includes(idx)
                        ? 'star'
                        : 'none';
            } else if (HOME_LANE_AT.has(key)) {
                const { seat, step } = HOME_LANE_AT.get(key)!;
                node.role = 'homeLane';
                node.seat = seat;
                node.homeStep = step;
            } else {
                const q = quadrantOf(x, y);
                if (q) {
                    const lx = x - q.ox;
                    const ly = y - q.oy;
                    // Inner 4×4 of the quadrant is the pocket holding the four pawn slots.
                    if (lx >= 1 && lx <= 4 && ly >= 1 && ly <= 4) {
                        node.role = 'yardPocket';
                        node.seat = q.seat;
                    } else {
                        node.role = 'yard';
                        node.seat = q.seat;
                    }
                }
            }

            cells.push(node);
        }
    }
    return cells;
}
