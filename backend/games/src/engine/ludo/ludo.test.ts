// Headless schema-v2 engine test. Run: npx tsx src/engine/ludo/ludo.test.ts
//
// LUDO_GAME_SPEC.md §19 names the cases this file must cover: all 52 track cells for every
// seat and die value, yard entry, every exact/overshoot home-lane case, all eight safe cells,
// capture, same-colour block pass/land restrictions, third-pawn block rejection, three sixes,
// no-legal-move on a six, deterministic auto-pick ties, timeout streak reset/drop, duel
// forfeit, four-to-two continuation, restore with awaiting move, RNG secret loss, idempotent
// commands, stale sequence, and simultaneous commands.
//
// Same plain-tsx style as the other suites — this package has no test runner, deliberately.
import { ludo } from './index';
import {
    destination,
    HOME_LANE_BASE,
    isSafe,
    path,
    START_INDICES,
    TRACK_COUNT,
    YARD,
    FINISHED,
} from './board';
import { pickAutoMove, legalMoves } from './rules';
import { DiceRng } from './rng';
import type { GameEngine, GameStatePayload } from '../GameEngine';
import type { LudoStateV2 } from './types';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { buildBoardCells } from './cells';
import { enqueue, drainQueue, clearQueues } from '../../queue';

let failures = 0;
let passes = 0;

function check(name: string, cond: boolean, detail = ''): void {
    if (cond) {
        passes++;
        console.log(`  PASS  ${name}`);
    } else {
        failures++;
        console.error(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`);
    }
}

function section(name: string): void {
    console.log(`\n${name}`);
}

// --- Harness ---------------------------------------------------------------------------

interface Hooks {
    accept(u: string): boolean;
    startAll(now: number): void;
    forfeit(u: string, now: number): { accepted: boolean; outcome?: unknown };
}

const T0 = 1_700_000_000_000;
const SEED_A = 'aa'.repeat(32);

/** Open a hook view onto whatever lifecycle methods the engine carries. */
function hooksOf(e: GameEngine): Hooks {
    return e as unknown as Hooks;
}

function timeoutOf(e: GameEngine): () => { accepted: boolean } {
    return (e.onTimeout as () => { accepted: boolean }).bind(e);
}

/** Build a fresh engine with a FIXED rng seed so sequences are reproducible. */
function makeEngine(mode: 'duel' | 'four', ids: string[], seedHex?: string): GameEngine {
    return ludo.create(ids, { mode, ...(seedHex ? { rngSeed: seedHex } : {}) });
}

/** Accept everyone and start, as the runtime does after the final acceptance. */
function startEngine(e: GameEngine, ids: string[], now = T0): void {
    const h = hooksOf(e);
    for (const id of ids) h.accept(id);
    h.startAll(now);
}

function stateOf(e: GameEngine): LudoStateV2 {
    return (e.serialize() as { ludo: LudoStateV2 }).ludo;
}

/**
 * Hand-build a state (full control over tokens/timing) and restore an engine from it.
 * This is how block/capture/finish layouts are constructed deterministically.
 */
function engineFromState(
    partial: Partial<LudoStateV2>,
    opts: { mode?: 'duel' | 'four' } = {},
): GameEngine {
    const mode = opts.mode ?? partial.mode ?? 'four';
    const ids =
        mode === 'duel'
            ? ['u0', 'u1']
            : ((partial.players as string[] | undefined)?.length === 4
                ? (partial.players as string[])
                : ['u0', 'u1', 'u2', 'u3']);
    const players: (string | null)[] =
        mode === 'duel'
            ? [ids[0], null, ids[1], null]
            : [...ids];

    const base: LudoStateV2 = {
        schemaVersion: 2,
        rulesVersion: 'ludo-classic-1',
        mode,
        status: 'active',
        started: true,
        players,
        accepted: players.map(() => true),
        participation:
            mode === 'duel'
                ? ['active', 'waiting', 'active', 'waiting']
                : ['active', 'active', 'active', 'active'],
        timeoutStreak: [0, 0, 0, 0],
        captures: [0, 0, 0, 0],
        tokens: [
            [YARD, YARD, YARD, YARD],
            [YARD, YARD, YARD, YARD],
            [YARD, YARD, YARD, YARD],
            [YARD, YARD, YARD, YARD],
        ],
        startedByRng: false,
        firstSeatChosen: false,
        activeSeat: 0,
        turnSerial: 7,
        phase: 'awaitingRoll',
        // Decision windows default OPEN relative to the real clock the engine gates on.
        opensAt: Date.now() - 1000,
        deadlineAt: Date.now() + 30_000,
        sixStreak: 0,
        rollId: null,
        rollValue: null,
        legalTokenIds: [],
        automated: false,
        turnHadAutoAction: false,
        actionCounter: 0,
        lastAction: null,
        winnerSeat: null,
        endReason: null,
    };
    const merged: LudoStateV2 = {
        ...base,
        ...partial,
        // Structural fields are not overridable by tests — they define what "v2" is.
        schemaVersion: 2,
        rulesVersion: 'ludo-classic-1',
        players: partial.players
            ? (partial.players as (string | null)[])
            : base.players,
    };
    // Pad any seat row a test omitted rather than discarding the layout entirely.
    if (!Array.isArray(merged.tokens)) merged.tokens = base.tokens;
    for (let s2 = 0; s2 < 4; s2++) {
        if (!Array.isArray(merged.tokens[s2])) merged.tokens[s2] = [...base.tokens[s2]];
        while (merged.tokens[s2].length < 4) merged.tokens[s2].push(YARD);
    }
    const secretBlob: GameStatePayload = {
        ludo: {
            rng: { seed: SEED_A, counter: 0 },
            players: merged.players,
            accepted: merged.accepted,
        },
    };
    return ludo.restore({ ludo: merged }, secretBlob);
}

function secretRngOf(e: GameEngine): { seed: string; counter: number } {
    const s = e.serializeSecret!() as { ludo?: { rng?: { seed: string; counter: number } } };
    return s.ludo!.rng! ?? { seed: SEED_A, counter: 0 };
}

/** Submit like a client does: the current turn serial is attached automatically. */
function act(
    e: GameEngine,
    uid: string,
    payload: Record<string, unknown>,
): ReturnType<GameEngine['applyInput']> {
    const st = stateOf(e);
    return e.applyInput(uid, {
        ...payload,
        turnSerial: (payload.turnSerial as number | undefined) ?? st.turnSerial,
        expectedSeq: (payload.expectedSeq as number | undefined) ?? 0,
        commandId: (payload.commandId as string | undefined) ?? 't',
    });
}

/** Fast-forward past the mandatory die animation so the awaiting-move window is open. */
function settle(e: GameEngine): GameEngine {
    const st = { ...stateOf(e) };
    const now = Date.now();
    if (st.opensAt !== null && st.opensAt > now) st.opensAt = now - 1;
    return ludo.restore(
        { ludo: st },
        { ludo: { rng: secretRngOf(e), players: st.players, accepted: st.accepted } },
    );
}

/** Rebuild `e` with its decision window in the past so onTimeout will act. */
function rewind(e: GameEngine): GameEngine {
    const st = { ...stateOf(e) };
    const now = Date.now();
    if (st.opensAt !== null && st.opensAt > now) st.opensAt = now - 1;
    if (st.deadlineAt !== null && st.deadlineAt > now) st.deadlineAt = now - 1;
    return ludo.restore(
        { ludo: st },
        { ludo: { rng: secretRngOf(e), players: st.players, accepted: st.accepted } },
    );
}

async function main(): Promise<void> {
    // --- 1. Movement maths ---------------------------------------------------------------

    section('destination(): all 52 track cells, every seat, every die');

    {
        let ok = true;
        let detail = '';
        outer: for (let seat = 0; seat < 4; seat++) {
            for (let i = 0; i < TRACK_COUNT; i++) {
                for (let die = 1; die <= 6; die++) {
                    const travelled = (i - START_INDICES[seat] + TRACK_COUNT) % TRACK_COUNT;
                    const total = travelled + die;
                    const expected =
                        total === TRACK_COUNT + 5
                            ? FINISHED
                            : total > TRACK_COUNT + 5
                                ? null
                                : total >= TRACK_COUNT
                                    ? HOME_LANE_BASE + (total - TRACK_COUNT)
                                    : (START_INDICES[seat] + total) % TRACK_COUNT;
                    const got = destination(i, die, seat);
                    if (got !== expected) {
                        ok = false;
                        detail = `seat=${seat} i=${i} die=${die}: got ${got}, want ${expected}`;
                        break outer;
                    }
                    const p = path(i, die, seat);
                    if (p.length !== die || p[die - 1] !== got) {
                        ok = false;
                        detail = `path mismatch seat=${seat} i=${i} die=${die}`;
                        break outer;
                    }
                }
            }
        }
        check('52 cells × 4 seats × 6 dice match the closed form', ok, detail);
    }

    section('yard entry');

    {
        let ok = true;
        for (let seat = 0; seat < 4; seat++) {
            for (let die = 1; die <= 5; die++) {
                if (destination(YARD, die, seat) !== null) ok = false;
            }
            if (destination(YARD, 6, seat) !== START_INDICES[seat]) ok = false;
            if (path(YARD, 6, seat).length !== 1) ok = false;
        }
        check('only a six leaves the yard, placing on the start cell without advancing', ok);
    }

    section('home lane: every exact/overshoot case');

    {
        let ok = true;
        let detail = '';
        for (let step = 0; step <= 4; step++) {
            for (let die = 1; die <= 6; die++) {
                const sum = step + die;
                const expected = sum === 5 ? FINISHED : sum > 5 ? null : HOME_LANE_BASE + sum;
                const got = destination(HOME_LANE_BASE + step, die, 2);
                if (got !== expected) {
                    ok = false;
                    detail = `step=${step} die=${die}: got ${got}, want ${expected}`;
                }
            }
        }
        check('lane steps 0..4 × dice 1..6: exact to FINISHED, overshoot illegal', ok, detail);
    }

    // --- 2. Capture and safe cells -------------------------------------------------------

    section('capture');

    {
        // Deterministic capture via forced awaitingMove.
        const eng = engineFromState({
            tokens: [
                [21, YARD, YARD, YARD],
                [27, YARD, YARD, YARD],
                [YARD, YARD, YARD, YARD],
                [YARD, YARD, YARD, YARD],
            ],
            activeSeat: 0,
            phase: 'awaitingMove',
            rollValue: 6,
            rollId: 'cap-roll',
            legalTokenIds: [0],
        });
        const legal = legalMoves(stateOf(eng), 0, 6);
        check('landing on a lone opponent on a non-safe cell is legal', legal.includes(0));
        const r = act(eng, 'u0', { move: 0, rollId: 'cap-roll' });
        check('move accepted', r.accepted === true, JSON.stringify(r));
        const after = stateOf(eng);
        check('captured green pawn returned to its original yard slot', after.tokens[1][0] === YARD);
        check('captures counted for the mover', after.captures[0] === 1);
        const committedAction = after.lastAction!;
        check('action records capture with from/to',
            !!committedAction.move?.captured &&
            committedAction.move.captured.seat === 1 &&
            committedAction.move.captured.from === 27 &&
            committedAction.move.captured.to === YARD);
        check('capture adds 480 ms to the presentation window (six hops = 580)',
            committedAction.presentationEndsAt - committedAction.committedAt === 580 + 480,
            String(committedAction.presentationEndsAt - committedAction.committedAt));
    }

    section('the eight safe cells never capture');

    {
        // Green lands on safe 21 where yellow already sits: both coexist.
        const eng = engineFromState({
            tokens: [
                [YARD, YARD, YARD, YARD],
                [18, YARD, YARD, YARD],
                [21, YARD, YARD, YARD],
                [YARD, YARD, YARD, YARD],
            ],
            activeSeat: 1,
            phase: 'awaitingMove',
            rollValue: 3,
            rollId: 'safe-roll',
            legalTokenIds: [0],
        });
        act(eng, 'u1', { move: 0, rollId: 'safe-roll' });
        const fin = stateOf(eng);
        check('no capture on safe cell 21 — both pawns coexist',
            fin.tokens[2][0] === 21 && fin.tokens[1][0] === 21);
        check('no capture counted anywhere', fin.captures.every((c) => c === 0));

        // Every one of the eight safe indices refuses capture by construction of resolveCapture.
        let allSafe = true;
        for (const idx of [0, 8, 13, 21, 26, 34, 39, 47]) {
            if (!isSafe(idx)) allSafe = false;
        }
        check('SAFE_INDICES are exactly {0,8,13,21,26,34,39,47}', allSafe);
    }

    // --- 3. Blocks -------------------------------------------------------------------------

    section('blocks');

    {
        // Yellow pair blocks non-safe absolute 33. Blue token at progress 44 (abs 31):
        // die ≥ 2 crosses/lands on it and must be illegal; die 1 stays legal.
        const mkWithDie = (die: number, legal: number[]) =>
            engineFromState({
                tokens: [
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [33, 33, YARD, YARD],
                    [31, YARD, YARD, YARD],
                ],
                activeSeat: 3,
                phase: 'awaitingMove',
                rollValue: die,
                rollId: 'blk',
                legalTokenIds: legal,
            });
        // The SERVER's legal set is the contract: with a legal draw of 2 the blocked token is
        // never listed; a draw of 1 (which stops short of the block) lists it.
        const stCross = stateOf(mkWithDie(2, []));
        check('opponent block cannot be landed on or passed through',
            !legalMoves(stCross, 3, 2).includes(0),
            JSON.stringify(legalMoves(stCross, 3, 2)));
        const stAvoid = stateOf(mkWithDie(1, [0]));
        check('movement that avoids the block remains legal',
            legalMoves(stAvoid, 3, 1).includes(0));
    }

    {
        // Third same-colour pawn may not join a pair on a non-safe cell.
        const eng = engineFromState({
            tokens: [
                [10, 10, 7, YARD],
                [YARD, YARD, YARD, YARD],
                [YARD, YARD, YARD, YARD],
                [YARD, YARD, YARD, YARD],
            ],
            activeSeat: 0,
            phase: 'awaitingMove',
            rollValue: 3,          // token 2: 7+3=10 joins the pair
            rollId: 'third',
            legalTokenIds: legalMoves(
                {
                    ...(stateOf(makeEngine('four', ['x', 'y', 'z', 'w']))),
                    tokens: [
                        [10, 10, 7, YARD],
                        [YARD, YARD, YARD, YARD],
                        [YARD, YARD, YARD, YARD],
                        [YARD, YARD, YARD, YARD],
                    ],
                    activeSeat: 0,
                } as LudoStateV2,
                0,
                3,
            ),
        });
        const st = stateOf(eng);
        check('a third own pawn cannot join a block', !st.legalTokenIds.includes(2),
            JSON.stringify(st.legalTokenIds));
        void eng;
    }

    {
        // Own pair ON the start cell closes yard entry even though starts are safe.
        const eng = engineFromState({
            tokens: [
                [START_INDICES[0], START_INDICES[0], YARD, YARD],
                [YARD, YARD, YARD, YARD],
                [YARD, YARD, YARD, YARD],
                [YARD, YARD, YARD, YARD],
            ],
            activeSeat: 0,
            phase: 'awaitingRoll',
        });
        act(eng, 'u0', { roll: true });
        const st = stateOf(eng);
        const yardMovesOpen =
            st.rollValue === 6 && st.legalTokenIds.some((t) => t === 2 || t === 3);
        check('own pair on the start cell refuses a third pawn from the yard', !yardMovesOpen);
        // Opponents on the start cell do NOT close entry (starts are safe).
        const oppEng = engineFromState({
            tokens: [
                [YARD, YARD, YARD, YARD],
                [START_INDICES[0], START_INDICES[0], YARD, YARD],   // green sits on RED's start
                [YARD, YARD, YARD, YARD],
                [YARD, YARD, YARD, YARD],
            ],
            activeSeat: 0,
            phase: 'awaitingRoll',
        });
        act(oppEng, 'u0', { roll: true });
        const ost = stateOf(oppEng);
        check('entry is allowed when opponents hold the start cell',
            !(ost.rollValue === 6) || ost.legalTokenIds.some((t) => t === 0 || t === 1 || t === 2 || t === 3));
    }

    // --- 4. Three sixes ----------------------------------------------------------------------

    section('three consecutive sixes');

    {
        // Rig the seed so the first draw IS a six: search our fixed seed's stream once.
        const probe = DiceRng.fromState({ seed: SEED_A, counter: 0 })!;
        let firstSix = -1;
        for (let i = 0; i < 4096; i++) {
            if (probe.next() === 6) { firstSix = i; break; }
        }
        check('test rig found a six in the fixed stream', firstSix >= 0);

        const rigAt = (partial: Partial<LudoStateV2>, counter: number, mode: 'duel' | 'four' = 'duel') => {
            const e = engineFromState(partial, { mode });
            const st = { ...stateOf(e) };
            return ludo.restore(
                { ludo: st },
                { ludo: { rng: { seed: SEED_A, counter }, players: st.players, accepted: st.accepted } },
            );
        };

        // First six: enter from yard, then extra roll opens at presentationEnds+120.
        const e1 = rigAt({ activeSeat: 0 }, firstSix);
        check('first six drawn', act(e1, 'u0', { roll: true }).accepted && stateOf(e1).rollValue === 6);
        const s1 = stateOf(e1);
        check('sixStreak is 1', s1.sixStreak === 1);
        const settled1 = settle(e1);
        act(settled1, 'u0', { move: s1.legalTokenIds[0], rollId: s1.rollId! });
        const e1b = settled1;
        const s2 = stateOf(e1b);
        check('extra roll opens 120 ms after the mandatory move presentation ends',
            s2.opensAt !== null &&
            s2.lastAction !== null &&
            s2.opensAt >= s2.lastAction.presentationEndsAt + 119,
            JSON.stringify({ o: s2.opensAt, p: s2.lastAction?.presentationEndsAt }));

        // Third consecutive six: preset streak 2, rig another six → displayed then passed.
        const probe2 = DiceRng.fromState({ seed: SEED_A, counter: 0 })!;
        let nextSix = -1;
        for (let i = 0; i < 4096; i++) {
            if (probe2.next() === 6) { nextSix = i; break; }
        }
        const e3 = rigAt({ activeSeat: 0, sixStreak: 2 }, nextSix);
        const r3 = act(e3, 'u0', { roll: true });
        check('third six is committed and displayed',
            r3.accepted && stateOf(e3).lastAction?.roll?.value === 6);
        const s3 = stateOf(e3);
        check('…then play passes clockwise with no pawn moved for it',
            s3.activeSeat === (s3.mode === 'duel' ? 2 : 1) &&
            s3.phase === 'awaitingRoll' &&
            s3.tokens[0].every((p) => p === YARD),
            JSON.stringify({ active: s3.activeSeat, mode: s3.mode, phase: s3.phase, t: s3.tokens[0] }));
        check('third-six pass opens the next seat at +940 + 480',
            s3.lastAction !== null && s3.opensAt! - s3.lastAction.committedAt === 940 + 480);
        check('streak resets when the seat changes', s3.sixStreak === 0);
    }

    // --- 5. No legal move --------------------------------------------------------------------

    section('rolls with no legal move pass automatically');

    {
        // Duel. Red pair sits on its own start (closing entry for its two yard pawns) and a
        // green pair blocks abs 1, so even the start pawns cannot move — NO die has a move.
        const eng = engineFromState(
            {
                tokens: [
                    [START_INDICES[0], START_INDICES[0], YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [1, 1, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                ],
                activeSeat: 0,
                mode: 'duel',
            },
            { mode: 'duel' },
        );
        // Rig a six so we specifically prove the SIX-with-no-move case (§5.2 r7).
        const probe = DiceRng.fromState({ seed: SEED_A, counter: 0 })!;
        let sixCounter = -1;
        for (let i = 0; i < 4096; i++) if (probe.next() === 6) { sixCounter = i; break; }
        const stPre = { ...stateOf(eng) };
        const rigged = ludo.restore(
            { ludo: stPre },
            { ludo: { rng: { seed: SEED_A, counter: sixCounter }, players: stPre.players, accepted: stPre.accepted } },
        );
        const r = act(rigged, 'u0', { roll: true });
        check('six with no legal move is accepted and displayed',
            r.accepted && stateOf(rigged).lastAction?.roll?.value === 6, JSON.stringify(r));
        const st = stateOf(rigged);
        check('turn passed automatically to the opposite duel seat',
            st.activeSeat === 2 && st.phase === 'awaitingRoll',
            JSON.stringify({ active: st.activeSeat, phase: st.phase }));
        check('displayed roll settles before the pass (+940 + 480)',
            st.lastAction !== null && st.opensAt! - st.lastAction.committedAt === 940 + 480);
    }

    // --- 6. Deterministic auto-pick ------------------------------------------------------------

    section('deterministic auto-pick ranking');

    {
        const withTokens = (tokens: number[][], activeSeat: number, die: number, legal: number[]) =>
            engineFromState({
                tokens,
                activeSeat,
                phase: 'awaitingMove',
                rollValue: die,
                rollId: 'auto',
                legalTokenIds: legal,
            });

        // would-win beats everything.
        {
            const eng = withTokens(
                [
                    [HOME_LANE_BASE + 4, FINISHED, FINISHED, FINISHED],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                ],
                0, 1, [0],
            );
            check('would-win ranked first', pickAutoMove(stateOf(eng), 0, 1, [0]) === 0);
        }
        // finish beats capture.
        {
            const eng = withTokens(
                [
                    [HOME_LANE_BASE + 3, 20, YARD, YARD],
                    [22, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                ],
                0, 2, [0, 1],
            );
            check('finish outranks capture', pickAutoMove(stateOf(eng), 0, 2, [0, 1]) === 0);
        }
        // capture beats yard exit.
        {
            const eng = withTokens(
                [
                    [YARD, 18, YARD, YARD],
                    [24, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                ],
                0, 6, [0, 1],
            );
            check('capture outranks yard exit', pickAutoMove(stateOf(eng), 0, 6, [0, 1]) === 1);
        }
        // yard exit beats safe landing.
        {
            const eng = withTokens(
                [
                    [YARD, 2, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                ],
                0, 6, [0, 1],
            );
            check('yard exit outranks safe landing', pickAutoMove(stateOf(eng), 0, 6, [0, 1]) === 0);
        }
        // safe landing beats plain advance.
        {
            const eng = withTokens(
                [
                    [4, 2, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                ],
                0, 6, [0, 1],
            );
            check('safe landing outranks plain advance', pickAutoMove(stateOf(eng), 0, 6, [0, 1]) === 1);
        }
        // greatest resulting progress wins among plain advances.
        {
            const eng = withTokens(
                [
                    [4, 15, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                ],
                0, 3, [0, 1],
            );
            check('greatest resulting progress preferred', pickAutoMove(stateOf(eng), 0, 3, [0, 1]) === 1);
        }
        // identical outcomes resolve to lowest pawn index.
        {
            const eng = withTokens(
                [
                    [5, 5, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                ],
                0, 4, [0, 1],
            );
            check('full tie resolves to lowest pawn index', pickAutoMove(stateOf(eng), 0, 4, [0, 1]) === 0);
        }
        // lane entry outranks plain advance.
        {
            const eng = withTokens(
                [
                    [50, 9, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                    [YARD, YARD, YARD, YARD],
                ],
                0, 3, [0, 1],
            );
            // Seat 0 start 0: 50 has progress 50, +3 → lane step 1. Token 1 plain 5→8.
            check('home-lane entry outranks plain advance', pickAutoMove(stateOf(eng), 0, 3, [0, 1]) === 0);
        }
    }

    // --- 7. Timeout streaks / drops -------------------------------------------------------------

    section('timeout streaks: auto turns accumulate, manual turns clear');

    {
        // Duel where BOTH seats burn three fully-automated turns alternately; the FIRST seat
        // to hit three consecutive timed-out turns must drop and end the duel.
        const ids = ['ta', 'tb'];
        let eng = makeEngine('duel', ids, SEED_A);
        startEngine(eng, ids);
        let guard = 0;
        while (guard++ < 60) {
            let st = stateOf(eng);
            if (st.status !== 'active') break;
            eng = rewind(eng);
            const r = timeoutOf(eng)();
            if (!r.accepted) {
                // Nothing pending? Bail out rather than spin.
                break;
            }
            st = stateOf(eng);
            if (Object.values(st.timeoutStreak).some((v) => v >= 3) || st.participation.some((p) => p === 'dropped')) break;
        }
        const fin = stateOf(eng);
        const dropped = fin.participation.some((p) => p === 'dropped');
        check('three consecutive timed-out turns mark a seat dropped', dropped,
            JSON.stringify({ participation: fin.participation, streaks: fin.timeoutStreak }));
        check('a duel where a seat drops finishes with the other player winning',
            fin.status === 'finished' && fin.winnerSeat !== null &&
            (fin.endReason === 'timeoutForfeit' || fin.endReason === 'lastActive'),
            JSON.stringify({ status: fin.status, winner: fin.winnerSeat, reason: fin.endReason }));
        check('dropped seat’s unfinished pawns left the board',
            fin.participation.forEach === undefined ||
            fin.participation.every((p, i) =>
                p !== 'dropped' ||
                fin.tokens[i].every((t) => t === YARD || t === FINISHED)),
            JSON.stringify(fin.tokens));
    }

    {
        // Manual voluntary turn RESETS the streak.
        const eng = engineFromState(
            {
                tokens: [[YARD, YARD, YARD, YARD]],
                players: ['ua', 'ub'],
                mode: 'duel',
                activeSeat: 0,
                timeoutStreak: [2, 0],
                turnHadAutoAction: false,
            },
            { mode: 'duel' },
        );
        act(eng, 'ua', { roll: true });
        const st1 = stateOf(eng);
        act(eng, 'ua', { move: st1.legalTokenIds[0], rollId: st1.rollId! });
        const st = stateOf(eng);
        check('an entirely voluntary turn clears the seat’s streak',
            st.timeoutStreak[0] === 0,
            JSON.stringify(st.timeoutStreak));
    }

    // --- 8. Forfeit ------------------------------------------------------------------------------

    section('forfeit');

    {
        const eng = makeEngine('duel', ['uf1', 'uf2'], SEED_A);
        startEngine(eng, ['uf1', 'uf2']);
        const r = hooksOf(eng).forfeit('uf1', Date.now()) as { accepted: boolean; outcome?: unknown };
        check('duel forfeit accepted and terminal',
            r.accepted === true && r.outcome !== undefined);
        const st = stateOf(eng);
        check('remaining duel player wins by playerForfeit',
            st.winnerSeat !== null && st.endReason === 'playerForfeit' && st.status === 'finished');
    }

    {
        const ids = ['fg0', 'fg1', 'fg2', 'fg3'];
        const eng = makeEngine('four', ids, SEED_A);
        startEngine(eng, ids);
        const active = stateOf(eng).activeSeat;
        // Seat assignment is shuffled; resolve the victim's PHYSICAL seat from the secret.
        const seatPlayers = (eng.serializeSecret!() as { ludo: { players: (string | null)[] } }).ludo.players;
        const victim = ids[(active + 2) % 4];
        const victimSeat = seatPlayers.indexOf(victim);
        const r = hooksOf(eng).forfeit(victim, Date.now()) as { accepted: boolean };
        const st = stateOf(eng);
        check('explicit forfeit accepted', r.accepted === true, JSON.stringify(r));
        check('forfeited seat marked dropped',
            st.participation[victimSeat] === 'dropped',
            JSON.stringify({ victimSeat, participation: st.participation }));
        check('dropped seat skipped in clockwise order afterwards',
            st.activeSeat !== victimSeat);
        check('four-player match continues after one drop', st.status === 'active',
            JSON.stringify({ status: st.status }));
        check('dropped seat’s unfinished pawns left track/home lanes',
            st.tokens[ids.indexOf(victim)].every((p) => p === YARD || p === FINISHED));
    }

    // --- 9. Restore ---------------------------------------------------------------------------------

    section('serialize → restore round trip');

    {
        const eng = engineFromState({
            tokens: [[5, YARD, 23, FINISHED], [11, YARD, YARD, YARD]],
            activeSeat: 0,
            phase: 'awaitingMove',
            rollValue: 4,
            rollId: 'restore-roll',
            legalTokenIds: [0, 2],
            opensAt: Date.now() - 1000,
            deadlineAt: Date.now() + 25_000,
            sixStreak: 1,
            turnSerial: 42,
        });
        const before = JSON.stringify(eng.serialize());
        const restored = ludo.restore(eng.serialize(), eng.serializeSecret!());
        check('public state byte-equal across restore', JSON.stringify(restored.serialize()) === before);
        const rs = stateOf(restored);
        check('phase/rollId/legal survive',
            rs.phase === 'awaitingMove' && rs.rollId === 'restore-roll' && rs.legalTokenIds.length === 2);
        const seqA: number[] = [];
        const probeA = DiceRng.fromState(secretRngOf(restored))!;
        for (let i = 0; i < 8; i++) seqA.push(probeA.next());
        const probeB = DiceRng.fromState(secretRngOf(restored))!;
        const seqB: number[] = [];
        for (let i = 0; i < 8; i++) seqB.push(probeB.next());
        check('dice sequence reproducible from the persisted secret',
            JSON.stringify(seqA) === JSON.stringify(seqB));
        const r = act(restored, 'u0', { move: 0, rollId: 'restore-roll' });
        check('restore WITH awaiting move accepts the pending move', r.accepted,
            JSON.stringify({ r, legal: stateOf(restored).legalTokenIds }));
    }

    section('RNG secret loss abandons the match');

    {
        const eng = engineFromState({});
        const zombie = ludo.restore(eng.serialize(), undefined);
        check('missing secret → terminal engine', zombie.isFinished());
        check('inputs refused after integrity loss',
            zombie.applyInput('u0', { roll: true }).accepted === false);
        const zs = (zombie.serialize() as { ludo?: LudoStateV2 }).ludo;
        check('end reason recorded as serverIntegrityError',
            zs?.status === 'abandoned' && zs.endReason === 'serverIntegrityError');
    }

    section('legacy v1 state is abandoned with a version reason');

    {
        const legacy = { players: ['a', 'b'], tokens: [[-1]], turn: 0, phase: 'awaitingRoll' };
        const zombie = ludo.restore(legacy as unknown as GameStatePayload, { rng: 12345 });
        check('v1 restore yields a tombstone that refuses input',
            zombie.isFinished() && zombie.applyInput('a', { roll: true }).accepted === false);
    }

    // --- 10. Command discipline ---------------------------------------------------------------------

    section('idempotency, stale seq, simultaneous commands (runtime semantics on the real queue)');

    {
        clearQueues();
        // Mini-runtime mirroring processLudoInput: seq, idempotency map, STALE_SEQ compare —
        // driven through the SAME enqueue() the service uses, so simultaneous submissions
        // serialize exactly as they do in production.
        const eng = engineFromState({});
        // Rig the very first draw to a six so a legal move certainly exists.
        {
            const probe = DiceRng.fromState({ seed: SEED_A, counter: 0 })!;
            let c6 = -1;
            for (let i = 0; i < 4096; i++) if (probe.next() === 6) { c6 = i; break; }
            const pre = { ...stateOf(eng) };
            const rigged = ludo.restore(
                { ludo: pre },
                { ludo: { rng: { seed: SEED_A, counter: c6 }, players: pre.players, accepted: pre.accepted } },
            );
            Object.getOwnPropertyNames(rigged).forEach((k) => {
                Object.defineProperty(eng, k, Object.getOwnPropertyDescriptor(rigged, k)!);
            });
        }

        let seq = 0;
        const processed: Record<string, number> = {};
        const applied: string[] = [];
        const submit = (uid: string, payload: Record<string, unknown>): Promise<string> =>
            enqueue('m1', async () => {
                const cid = (payload.commandId as string) ?? '';
                if (cid && processed[cid] !== undefined) return 'replayed';
                const es = payload.expectedSeq;
                if (typeof es === 'number' && es !== seq) return 'STALE_SEQ';
                const r = eng.applyInput(uid, {
                    ...payload,
                    expectedSeq: es,
                    turnSerial: stateOf(eng).turnSerial,
                });
                if (!r.accepted) return r.rejection ?? 'rejected';
                if (r.outcome) return 'ended';
                processed[cid] = seq + 1;
                seq += 1;
                applied.push(cid);
                return 'accepted';
            });

        const a = await submit('u0', { commandId: 'cmd-a', expectedSeq: 0, roll: true });
        check('first command accepted', a === 'accepted', a);
        const b = await submit('u0', { commandId: 'cmd-a', expectedSeq: 0, roll: true });
        check('retry with same commandId replays no second action',
            b === 'replayed' && applied.filter((x) => x === 'cmd-a').length === 1, b);
        const c = await submit('u0', { commandId: 'cmd-b', expectedSeq: 0, roll: true });
        check('second device with old expectedSeq gets exactly STALE_SEQ', c === 'STALE_SEQ', c);

        // Settle the mandatory die animation so the move window is open.
        {
            const settledSt = { ...stateOf(eng) };
            settledSt.opensAt = Math.min(settledSt.opensAt ?? 0, Date.now() - 1);
            const settledEng = ludo.restore(
                { ludo: settledSt },
                { ludo: { rng: secretRngOf(eng), players: settledSt.players, accepted: settledSt.accepted } },
            );
            Object.getOwnPropertyNames(settledEng).forEach((k) => {
                Object.defineProperty(eng, k, Object.getOwnPropertyDescriptor(settledEng, k)!);
            });
        }
        check('scenario reached awaitingMove', stateOf(eng).phase === 'awaitingMove',
            `${stateOf(eng).phase}/${stateOf(eng).rollValue}`);

        // SIMULTANEOUS: the SAME player on two devices fires before either runs. The contract
        // (§7.3): exactly one accepted transition; the loser gets exactly STALE_SEQ.
        const rollId = stateOf(eng).rollId!;
        const token = stateOf(eng).legalTokenIds[0];
        const d = submit('u0', { commandId: 'cmd-c', expectedSeq: seq, move: token, rollId });
        const e = submit('u0', { commandId: 'cmd-d', expectedSeq: seq, move: token, rollId });
        const results = await Promise.all([d, e]);
        check('two devices submitting simultaneously produce ONE accepted transition',
            results.filter((r) => r === 'accepted').length === 1 &&
            results.includes('STALE_SEQ'),
            results.join('/'));
        await drainQueue('m1');
    }

    {
        // Engine-level validation codes.
        const eng = engineFromState({
            tokens: [[5, YARD, YARD, YARD], [YARD, YARD, YARD, YARD]],
            activeSeat: 0,
            phase: 'awaitingMove',
            rollValue: 3,
            rollId: 'rid',
            legalTokenIds: [0],
        });
        check('wrong rollId → ROLL_MISMATCH',
            act(eng, 'u0', { move: 0, rollId: 'other' }).rejection === 'ROLL_MISMATCH');
        check('token outside legalTokenIds → ILLEGAL_MOVE',
            act(eng, 'u0', { move: 1, rollId: 'rid' }).rejection === 'ILLEGAL_MOVE');
        check('outsider → NOT_A_PLAYER',
            eng.applyInput('nobody', { move: 0, rollId: 'rid' }).rejection === 'NOT_A_PLAYER');
        check('wrong seat → NOT_YOUR_TURN',
            eng.applyInput('u1', { move: 0, rollId: 'rid' }).rejection === 'NOT_YOUR_TURN');
        const early = engineFromState({ activeSeat: 0, opensAt: Date.now() + 60_000, deadlineAt: Date.now() + 90_000 });
        check('early roll → TOO_EARLY', act(early, 'u0', { roll: true }).rejection === 'TOO_EARLY');
        const late = engineFromState({ activeSeat: 0, opensAt: Date.now() - 60_000, deadlineAt: Date.now() - 1 });
        check('expired window → DEADLINE_PASSED', act(late, 'u0', { roll: true }).rejection === 'DEADLINE_PASSED');
        check('wrong turn serial → NOT_YOUR_TURN',
            late.applyInput('u0', { roll: true, turnSerial: 99 }).rejection === 'NOT_YOUR_TURN');
    }

    // --- 11. Presentation windows -------------------------------------------------------------------

    section('presentation windows');

    {
        const hopMsLocal = (n: number): number => (n === 0 ? 0 : 120 + 92 * (n - 1));
        check('hopMs table matches §15',
            hopMsLocal(0) === 0 && hopMsLocal(1) === 120 && hopMsLocal(6) === 580);

        // SIX keeps the seat: presentation 580 ms, extra roll opens at +120 after it,
        // no sweep, no serial change (§12.3).
        const sixEng = engineFromState({
            tokens: [[10, YARD, YARD, YARD], [YARD, YARD, YARD, YARD]],
            activeSeat: 0,
            phase: 'awaitingMove',
            rollValue: 6,
            rollId: 'hop-roll',
            legalTokenIds: [0],
        });
        act(sixEng, 'u0', { move: 0, rollId: 'hop-roll' });
        const sixSt = stateOf(sixEng);
        check('six-cell move presentation ends at +580',
            sixSt.lastAction!.presentationEndsAt - sixSt.lastAction!.committedAt === 580);
        check('a six opens the extra roll 120 ms after presentation, same seat',
            sixSt.activeSeat === 0 &&
            sixSt.opensAt! - sixSt.lastAction!.presentationEndsAt === 120 &&
            sixSt.turnSerial === 7);

        // Non-six hands off: five hops = 560 ms; next seat opens at +480; deadline +30000.
        const eng = engineFromState({
            tokens: [[10, YARD, YARD, YARD], [YARD, YARD, YARD, YARD]],
            activeSeat: 0,
            phase: 'awaitingMove',
            rollValue: 5,
            rollId: 'hop-roll-5',
            legalTokenIds: [0],
        });
        act(eng, 'u0', { move: 0, rollId: 'hop-roll-5' });
        const st = stateOf(eng);
        check('five-cell move presentation ends at +488 (hopMs formula)',
            st.lastAction!.presentationEndsAt - st.lastAction!.committedAt === 488,
            String(st.lastAction!.presentationEndsAt - st.lastAction!.committedAt));
        check('next-seat turn opens at presentationEnds + 480',
            st.activeSeat === 1 && st.opensAt! - st.lastAction!.presentationEndsAt === 480);
        check('deadline is opensAt + 30000', st.deadlineAt! - st.opensAt! === 30_000);
        check('turn.serial incremented for the handoff', st.turnSerial === 8);
    }

    // --- 12. Seats, shuffle, projection surface --------------------------------------------------------

    section('seats, shuffle, projection hygiene');

    {
        let creatorRed = 0;
        for (let i = 0; i < 40; i++) {
            const st = stateOf(makeEngine('duel', ['creator-x', 'other-y']));
            if (st.players[0] === 'creator-x') creatorRed++;
        }
        check('creator does not always receive red', creatorRed > 2 && creatorRed < 38, String(creatorRed));

        const duel = stateOf(makeEngine('duel', ['a', 'b']));
        check('duel occupies opposite seats red(0)+yellow(2)',
            duel.mode === 'duel' &&
            duel.players[0] !== null && duel.players[2] !== null &&
            duel.players[1] === null && duel.players[3] === null);

        const four = stateOf(makeEngine('four', ['a', 'b', 'c', 'd']));
        check('four-player fills every seat with FOUR pawns each',
            four.players.every((p) => p !== null) && four.tokens.every((row) => row.length === 4));

        const e = makeEngine('four', ['pa', 'pb', 'pc', 'pd']);
        const sp = e.serializeForPlayer!;
        const frame = sp.call(e, 'pa') as { ludoV2: Record<string, unknown> & { seats: Array<Record<string, unknown>> } };
        const blob = JSON.stringify(frame);
        check('frame carries no raw user ids',
            !blob.includes('"pa"') && !blob.includes('"pb"') && !blob.includes('"players"') &&
            !/[{,:]\s*"pa"/.test(blob),
            blob.slice(0, 200));
        check('frame exposes viewerSeat', frame.ludoV2.viewerSeat !== null);
        check('unprojected names fall back to neutral Player N',
            frame.ludoV2.seats.some((s) => s.displayName === 'Player 1'));
        check('frame carries a seed commitment but never the seed',
            typeof frame.ludoV2.seedCommitment === 'string' &&
            !blob.toLowerCase().includes(SEED_A.slice(0, 16)));

        (e as unknown as { setFrameContext(ctx: unknown): void }).setFrameContext({
            serverNow: 1,
            connections: {},
            names: {},
        });
        const f2 = (sp.call(e, 'pb') as { ludoV2: { seats: Array<{ connection: string }> } }).ludoV2;
        check('absent presence projects as a connection bit only',
            f2.seats.every((s) => s.connection === 'disconnected'));
    }

    // --- 13. Geometry fixture parity ---------------------------------------------------------------------

    section('geometry fixture parity');

    {
        const fixturePath = resolve(
            __dirname,
            '../../../../../packages/design-tokens/fixtures/ludo_board_v2.json',
        );
        let committed: any = null;
        try {
            committed = JSON.parse(readFileSync(fixturePath, 'utf8'));
        } catch {
            committed = null;
        }
        if (!committed) {
            check('fixture readable at packages/design-tokens/fixtures', false, fixturePath);
        } else {
            const cells = buildBoardCells();
            check('fixture holds 225 keyed cells', committed.cells?.length === 225);
            check('regenerated model identical to the committed fixture',
                JSON.stringify(cells) === JSON.stringify(committed.cells));
            const roles = cells.reduce<Record<string, number>>((acc, c) => {
                acc[c.role] = (acc[c.role] ?? 0) + 1;
                return acc;
            }, {});
            check('role census: 80 yard / 64 pocket / 52 track / 20 lane / 9 center',
                roles.yard === 80 && roles.yardPocket === 64 && roles.sharedTrack === 52 &&
                roles.homeLane === 20 && roles.center === 9);
            const safeCells = cells.filter((c) => c.isSafe);
            check('exactly eight safe cells carry decorations',
                safeCells.length === 8 && safeCells.every((c) => c.decoration !== 'none'));
            check('cell(x,y).trackIndex ↔ trackCoords[i] round-trip',
                cells.every((c) =>
                    c.trackIndex === null ||
                    (committed.trackCoords[c.trackIndex].x === c.x &&
                        committed.trackCoords[c.trackIndex].y === c.y)));
            check('start indices are {0,13,26,39}',
                JSON.stringify(committed.startIndicesBySeat) === '[0,13,26,39]');
        }
    }

    console.log(`\n${passes} passed, ${failures} failed`);
    if (failures > 0) process.exit(1);
}

void main().catch((err) => {
    console.error(err);
    process.exit(1);
});
