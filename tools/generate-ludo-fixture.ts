// Generates the canonical Ludo board geometry fixture from the backend's own tables
// (LUDO_GAME_SPEC.md §3, §19).
//
//   npx tsx tools/generate-ludo-fixture.ts
//
// The fixture is checked into packages/design-tokens/fixtures/ludo_board_v2.json and is the
// ONE source iOS, Android and the backend validate against — no platform keeps an independent
// hand-entered coordinate array. After regenerating, run tools/sync-ludo-fixture.sh to copy
// it into both apps' test bundles.
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import {
    CENTER_RECT,
    DUEL_SEATS,
    ENTRY_INDICES,
    HOME_LANE_COORDS,
    SAFE_INDICES,
    SEAT_COLORS,
    STAR_INDICES,
    START_INDICES,
    TRACK_COORDS,
    YARD_SLOTS,
} from '../backend/games/src/engine/ludo/board';
import { buildBoardCells } from '../backend/games/src/engine/ludo/cells';

const here = __dirname;

const cells = buildBoardCells();

const fixture = {
    schemaVersion: 2,
    rulesVersion: 'ludo-classic-1',
    boardSide: 15,
    trackCount: 52,
    homeLaneCount: 5,
    tokensPerSeat: 4,
    seatColors: SEAT_COLORS,
    duelSeats: DUEL_SEATS,
    safeIndices: [...SAFE_INDICES].sort((a, b) => a - b),
    entryIndices: ENTRY_INDICES,
    starIndices: STAR_INDICES,
    startIndicesBySeat: START_INDICES,
    centerRect: CENTER_RECT,
    trackCoords: TRACK_COORDS.map(([x, y]) => ({ x, y })),
    homeLaneCoords: HOME_LANE_COORDS.map((lane) => lane.map(([x, y]) => ({ x, y }))),
    yardSlots: YARD_SLOTS.map((slots) => slots.map(([x, y]) => ({ x, y }))),
    // Normalized clockwise border anchors (§12.1): red 0.00 bottom-left, green 0.25 top-left,
    // yellow 0.50 top-right, blue 0.75 bottom-right.
    borderAnchors: [
        { seat: 0, color: 'red', fraction: 0.0 },
        { seat: 1, color: 'green', fraction: 0.25 },
        { seat: 2, color: 'yellow', fraction: 0.5 },
        { seat: 3, color: 'blue', fraction: 0.75 },
    ],
    cells,
};

const out = resolve(here, '../packages/design-tokens/fixtures/ludo_board_v2.json');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(fixture, null, 2) + '\n');
console.log(`wrote ${out} (${cells.length} cells)`);
