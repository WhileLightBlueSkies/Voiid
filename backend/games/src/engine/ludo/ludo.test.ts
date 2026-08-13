// Headless engine test. Run: npx tsx src/engine/ludo/ludo.test.ts
//
// LUDO'S RULES ARE FIDDLIER THAN ITS REPUTATION SUGGESTS, and every edge case is one somebody
// remembers differently: blocks, exact entry, three sixes, capture-on-safe, extra turns
// composing. LUDO.md §14 lists the cases that carry weight and they are all here.
//
// The tests that matter most are not the rule tests:
//
//   * serialize -> restore -> serialize BYTE EQUALITY, specifically covering `phase`,
//     `sixStreak` and `extraTurn` — losing `phase` lets a player who rolled a 2 roll again for a
//     better number, and the round trip happens on EVERY input;
//   * RESTORE WITH THE SECRET preserving the exact dice sequence, and restore without it being
//     loud. A lost seed means every roll is drawn from a sequence reseeded identically on every
//     input, which does not look like a failure and takes a long time to diagnose.
//
// Same plain-tsx style as the other suites — this package has no test runner, deliberately.
import { ludo } from './index';
import {
  COLUMN_BASE,
  HOME,
  YARD,
  destination,
  entrySquare,
  isSafe,
  path,
  relative,
} from './board';
import type { GameEngine, GameStatePayload } from '../GameEngine';

let failures = 0;

function check(name: string, cond: boolean, detail = ''): void {
  if (cond) {
    console.log(`  PASS  ${name}`);
  } else {
    failures++;
    console.error(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`);
  }
}

const P2 = ['alice', 'bob'];
const P4 = ['alice', 'bob', 'carol', 'dave'];
const st = (e: GameEngine) => e.serialize() as any;

/**
 * Drive the engine to a known board.
 *
 * The die is drawn from the secret RNG, so a test cannot ask for a 6 — it restores an engine
 * with the board it wants instead. That is also a small proof that restore works, since every
 * test below is built on one.
 */
function withBoard(
  players: string[],
  tokens: number[][],
  over: Partial<Record<string, unknown>> = {}
): GameEngine {
  const base = ludo.create(players, { tokens: tokens[0].length, seed: 42 });
  const state = { ...base.serialize(), tokens, ...over };
  return ludo.restore(state, base.serializeSecret!());
}

// --- Board maths ------------------------------------------------------------------------
console.log('\nBoard geometry');
{
  check('entry squares are 0, 13, 26, 39',
    [0, 1, 2, 3].map(entrySquare).join(',') === '0,13,26,39');

  // A 6 is required to leave the yard, and it PLACES the token on the entry square — it does
  // not then move six more. That is the rule most often implemented twice.
  check('a 6 brings a token out to the entry square', destination(YARD, 6, 0) === 0);
  check('seat 2 comes out on its own entry square', destination(YARD, 6, 2) === 26);
  for (const die of [1, 2, 3, 4, 5]) {
    check(`a ${die} cannot leave the yard`, destination(YARD, die, 0) === null);
  }

  check('a token advances along the track', destination(3, 4, 0) === 7);

  // ABSOLUTE INDICES WRAP, BUT THE SEAT'S OWN ENTRY DECIDES WHEN A TOKEN TURNS OFF — which is
  // the whole reason `relative` exists, and the case a per-player-relative encoding gets wrong.
  //
  // Square 50 is near the END of seat 0's lap (it entered at 0), so a 4 takes it into its home
  // column, NOT round to square 2. The same square is mid-lap for seat 1 (entry 13), so the
  // identical move wraps the absolute index instead. One square, two seats, two right answers.
  check('a late seat turns into its own column', destination(50, 4, 0) === COLUMN_BASE + 2);
  check('the same square mid-lap wraps instead', destination(50, 4, 1) === 2);

  // EXACT ROLL REQUIRED TO REACH HOME. A token 3 from home cannot move on a 5 — illegal rather
  // than clamped, and if no legal move exists the turn passes.
  check('exact roll enters home', destination(COLUMN_BASE + 4, 1, 0) === HOME);
  check('overshooting home is illegal', destination(COLUMN_BASE + 4, 2, 0) === null);
  check('overshooting from the track is illegal', destination(51, 7, 0) === null);
  check('a token already home cannot move', destination(HOME, 3, 0) === null);

  // 51 squares of track, then the column: relative 52 is the first column square.
  check('leaving the track enters the column', destination(50, 3, 0) === COLUMN_BASE + 1);
  check('relative position is measured from own entry', relative(13, 1) === 0);

  // The eight starred squares — the four entries and the four 8 ahead of each.
  check('entry squares are safe', [0, 13, 26, 39].every(isSafe));
  check('the +8 squares are safe', [8, 21, 34, 47].every(isSafe));
  check('an ordinary square is not safe', !isSafe(5));

  // The path matters because a block cannot be PASSED, not just landed on.
  check('the path covers every square crossed',
    path(0, 3, 0).join(',') === '1,2,3');
  check('entering from the yard passes nothing',
    path(YARD, 6, 0).join(',') === '0');
}

// --- Turn structure ---------------------------------------------------------------------
console.log('\nTurns and rolling');
{
  const e = ludo.create(P2, { seed: 7 });
  check('a fresh match awaits a roll', st(e).phase === 'awaitingRoll');
  check('no die is showing yet', st(e).die === null);
  check('seat 0 is on the clock', st(e).turn === 0);

  check('the seat not on the clock cannot roll',
    e.applyInput('bob', { roll: true }).accepted === false);
  check('a move before a roll is rejected',
    e.applyInput('alice', { move: 0 }).accepted === false);
  check('a non-player cannot roll',
    e.applyInput('mallory', { roll: true }).accepted === false);

  const r = e.applyInput('alice', { roll: true });
  check('rolling is accepted', r.accepted === true);
  check('a roll broadcasts (silent unset)', !r.silent);
  const die = st(e).die;
  check('a die face is 1-6 or the turn passed',
    die === null || (Number.isInteger(die) && die >= 1 && die <= 6));
}

// --- Auto-pass and auto-move --------------------------------------------------------------
console.log('\nAuto-actions');
{
  // All tokens in the yard and a non-6: zero legal moves, so the turn passes in the SAME frame
  // as the roll rather than prompting for a tap that changes nothing.
  const e = withBoard(P2, [[YARD, YARD], [YARD, YARD]], { phase: 'awaitingRoll' });
  let passes = 0;
  for (let i = 0; i < 40; i++) {
    const before = st(e).turn;
    e.applyInput(P2[before], { roll: true });
    const s = st(e);
    // Either a 6 came up and there is now a move to make, or the turn passed automatically.
    if (s.turn !== before) { passes++; continue; }
    check('a 6 in the yard produces legal moves', s.phase === 'awaitingMove' && s.legal.length > 0);
    break;
  }
  check('a non-6 with everything in the yard passes the turn', passes > 0);
}

// --- Capture ------------------------------------------------------------------------------
console.log('\nCapture');
{
  // Alice one square behind bob, on an ordinary square. Bob's token is at 5, which is not safe.
  const e = withBoard(P2, [[4, YARD], [5, YARD]],
    { phase: 'awaitingMove', die: 1, legal: [0], turn: 0 });
  const r = e.applyInput('alice', { move: 0 });
  check('landing on a lone opponent is accepted', r.accepted === true);
  check('the captured token goes back to the yard', st(e).tokens[1][0] === YARD);
  check('the capture is reported in lastMove',
    st(e).lastMove?.captured?.join(',') === '1,0');
  // A capture grants another turn, so the seat does NOT change.
  check('capturing grants an extra turn', st(e).turn === 0 && st(e).phase === 'awaitingRoll');
  check('extraTurn is set', st(e).extraTurn === true);

  // NO CAPTURE ON A SAFE SQUARE (§2.1). Square 8 is starred.
  const safe = withBoard(P2, [[7, YARD], [8, YARD]],
    { phase: 'awaitingMove', die: 1, legal: [0], turn: 0 });
  safe.applyInput('alice', { move: 0 });
  check('a token on a safe square is not captured', st(safe).tokens[1][0] === 8);
  check('landing on a safe square grants no extra turn', st(safe).turn === 1);

  // No capture in a home column — it is private, and an opponent can never be in yours.
  const col = withBoard(P2, [[COLUMN_BASE, YARD], [COLUMN_BASE, YARD]],
    { phase: 'awaitingMove', die: 1, legal: [0], turn: 0 });
  col.applyInput('alice', { move: 0 });
  check('a token in a home column is untouched', st(col).tokens[1][0] === COLUMN_BASE);
}

// --- Blocks -------------------------------------------------------------------------------
console.log('\nBlocks');
{
  // Two of bob's tokens on square 5 form a block. Alice at 3 rolling 2 would land on it.
  const land = withBoard(P2, [[3, YARD], [5, 5]], { phase: 'awaitingRoll', turn: 0 });
  const legalLand = (ludo.restore(
    { ...land.serialize(), phase: 'awaitingMove', die: 2, turn: 0 },
    land.serializeSecret!()) as any);
  // Re-derive through a roll rather than trusting a hand-written legal set.
  const s1 = withBoard(P2, [[3, YARD], [5, 5]], { phase: 'awaitingRoll', turn: 0 });
  let landedOnBlock = false;
  for (let i = 0; i < 60; i++) {
    const before = st(s1);
    if (before.turn !== 0) break;
    s1.applyInput('alice', { roll: true });
    const after = st(s1);
    if (after.phase === 'awaitingMove' && after.die === 2 && after.legal.includes(0)) {
      landedOnBlock = true; break;
    }
    if (after.phase === 'awaitingMove') break;
  }
  check('a block cannot be landed on', !landedOnBlock);
  void legalLand;

  // A block cannot be PASSED either, so a 4 from square 3 (crossing 5) is also illegal.
  const pass = withBoard(P2, [[3, YARD], [5, 5]], { phase: 'awaitingMove', die: 4, legal: [], turn: 0 });
  check('a block cannot be passed', !st(pass).legal.includes(0));

  // BLOCKS CANNOT FORM ON SAFE SQUARES. Two tokens on starred square 8 stack but do not block —
  // otherwise a permanent block on an entry square would lock a player out of the game.
  const onSafe = withBoard(P2, [[6, YARD], [8, 8]], { phase: 'awaitingMove', die: 2, legal: [0], turn: 0 });
  const r = onSafe.applyInput('alice', { move: 0 });
  check('a stack on a safe square does not block', r.accepted === true);
  check('and the stacked tokens are not captured',
    st(onSafe).tokens[1][0] === 8 && st(onSafe).tokens[1][1] === 8);
}

// --- Three sixes --------------------------------------------------------------------------
console.log('\nThree sixes');
{
  // Seeded at two consecutive sixes already, so the next 6 forfeits. The streak is state, so
  // this is set directly rather than hunting a seed that rolls three sixes.
  const e = withBoard(P2, [[10, YARD], [30, YARD]],
    { phase: 'awaitingRoll', turn: 0, sixStreak: 2 });
  let forfeited = false;
  for (let i = 0; i < 200; i++) {
    const probe = ludo.restore(
      { ...e.serialize(), phase: 'awaitingRoll', turn: 0, sixStreak: 2, seed: undefined },
      { rng: 1000 + i });
    probe.applyInput('alice', { roll: true });
    const s = st(probe);
    if (s.sixStreak === 0 && s.turn === 1 && s.die === null) {
      // A third 6 forfeits the turn AND the die is not used.
      forfeited = true;
      check('the third 6 is not used', s.die === null);
      check('the turn is forfeited', s.turn === 1);
      break;
    }
  }
  check('three consecutive sixes forfeit the turn', forfeited);
}

// --- Extra turns compose ------------------------------------------------------------------
console.log('\nExtra turns');
{
  // Capturing WITH a 6 grants ONE extra turn, not two — the flag is boolean, not a counter,
  // or a good turn spirals.
  const e = withBoard(P2, [[4, YARD], [10, YARD]],
    { phase: 'awaitingMove', die: 6, legal: [0], turn: 0 });
  e.applyInput('alice', { move: 0 });
  check('capturing with a 6 keeps the turn', st(e).turn === 0);
  check('extraTurn is a boolean, not a tally', st(e).extraTurn === true);

  // Getting a token home also grants one.
  const home = withBoard(P2, [[COLUMN_BASE + 4, YARD], [10, YARD]],
    { phase: 'awaitingMove', die: 1, legal: [0], turn: 0 });
  home.applyInput('alice', { move: 0 });
  check('reaching home grants an extra turn', st(home).turn === 0);
  check('the token is home', st(home).tokens[0][0] === HOME);
}

// --- Winning ------------------------------------------------------------------------------
console.log('\nWinning');
{
  // One token left, one square from home.
  const e = withBoard(P2, [[HOME, COLUMN_BASE + 4], [10, 12]],
    { phase: 'awaitingMove', die: 1, legal: [1], turn: 0 });
  const r = e.applyInput('alice', { move: 1 });
  check('the match ends when the last token gets home', r.outcome !== undefined);
  check('the finisher wins', r.outcome?.winnerId === 'alice');
  check('isFinished is true', e.isFinished() === true);
  check('phase is done', st(e).phase === 'done');
  check('no deadline is outstanding', (e as any).deadlineAt() === null);
  check('input after the match is rejected',
    e.applyInput('bob', { roll: true }).accepted === false);

  // scores is TOKENS HOME, higher is better, so it drops onto the existing leaderboard.
  check('the winner scores their tokens home', r.outcome?.scores?.alice === 2);
  check('the loser scores theirs', r.outcome?.scores?.bob === 0);
}

// --- Serialize / restore round trip --------------------------------------------------------
console.log('\nSerialize / restore round trip');
{
  const e = ludo.create(P4, { tokens: 2, seed: 99 });
  e.applyInput('alice', { roll: true });

  const before = e.serialize();
  const secret = e.serializeSecret!();
  const restored = ludo.restore(
    JSON.parse(JSON.stringify(before)), JSON.parse(JSON.stringify(secret)));
  const after = restored.serialize();

  check('serialize -> restore -> serialize is byte-identical',
    JSON.stringify(before) === JSON.stringify(after),
    `\n    before: ${JSON.stringify(before)}\n    after:  ${JSON.stringify(after)}`);
  check('the secret round-trips',
    JSON.stringify(secret) === JSON.stringify(restored.serializeSecret!()));

  // THE SEED IS NOT ON THE WIRE. A client holding it can compute every future roll.
  check('the seed is NOT in the public state', !('seed' in (before as any)));
  check('the seed IS in the secret', typeof (secret as any).rng === 'number');

  // The fields §4.3 flags as the ones a naive shape loses.
  for (const field of ['phase', 'sixStreak', 'extraTurn', 'deadlineAt', 'legal', 'die']) {
    check(`${field} survives the round trip`,
      JSON.stringify((before as any)[field]) === JSON.stringify((after as any)[field]));
  }
}

// --- The dice sequence ----------------------------------------------------------------------
console.log('\nDice determinism');
{
  // The same seed must produce the same sequence, or a restore mid-match silently changes the
  // future — and the reproducibility is the only defence against "the dice are rigged".
  const roll = (seed: number) => {
    const e = ludo.create(P2, { tokens: 4, seed });
    const faces: number[] = [];
    for (let i = 0; i < 12; i++) {
      const turn = st(e).turn;
      e.applyInput(P2[turn], { roll: true });
      const d = st(e).die;
      if (d !== null) faces.push(d);
      if (st(e).phase === 'awaitingMove') {
        e.applyInput(P2[turn], { move: st(e).legal[0] });
      }
    }
    return faces.join(',');
  };
  check('the same seed produces the same dice', roll(12345) === roll(12345));
  check('different seeds produce different dice', roll(1) !== roll(2));

  // Uniformity, loosely. Not a rigorous chi-square — just enough to catch a die that is
  // structurally broken (always even, never 6, off-by-one into 0-5).
  //
  // ROLLED ON A BOARD WITH MOVABLE TOKENS, which is the subtle part. With everything in the
  // yard a non-6 has no legal move, so the turn auto-passes and CLEARS the die — sampling that
  // board records only the sixes and "proves" a die that always rolls 6. The failure was in the
  // measurement, not the die, and it is exactly the shape that would have been believed.
  const counts = new Array(7).fill(0);
  const seeded = withBoard(P2, [[10, 20], [30, 40]], { phase: 'awaitingRoll', turn: 0 });
  let s = seeded.serialize();
  let sec = seeded.serializeSecret!();
  for (let i = 0; i < 3000; i++) {
    const probe = ludo.restore({ ...s, phase: 'awaitingRoll', turn: 0 }, sec);
    probe.applyInput('alice', { roll: true });
    const d = st(probe).die;
    if (d !== null) counts[d]++;
    sec = probe.serializeSecret!();
    s = probe.serialize();
  }
  const rolled = counts.slice(1).reduce((a, b) => a + b, 0);
  check('every face 1-6 appears', counts.slice(1).every((n) => n > 0),
    `counts: ${counts.slice(1).join(',')}`);
  check('no face is wildly over-represented',
    counts.slice(1).every((n) => n < rolled * 0.30),
    `counts: ${counts.slice(1).join(',')}`);
  check('0 is never rolled', counts[0] === 0);
}

// --- Restore without the secret --------------------------------------------------------------
console.log('\nRestore without the secret');
{
  const e = ludo.create(P2, { tokens: 2, seed: 55 });
  const orphan = ludo.restore(JSON.parse(JSON.stringify(e.serialize())), undefined);
  // It must keep PLAYING — unlike Sea Battle, a lost Ludo seed is recoverable by reseeding,
  // because no past result depends on it. It must be loud, which is asserted by the console
  // error in restore() rather than here; what this checks is that it does not silently die.
  check('a match without its secret still plays', orphan.isFinished() === false);
  check('and can still be rolled', orphan.applyInput('alice', { roll: true }).accepted === true);
  check('and has a fresh seed', typeof (orphan.serializeSecret!() as any).rng === 'number');
}

// --- Deadlines and auto-play -------------------------------------------------------------------
console.log('\nDeadlines and auto-play');
{
  const e = ludo.create(P4, { tokens: 2, seed: 3 });
  const d = (e as any).deadlineAt();
  check('a deadline is set at creation', typeof d === 'number' && d > Date.now());
  check('it is about 45 seconds out', Math.abs(d - Date.now() - 45_000) < 2000);
  check('a future deadline does not fire', (e as any).onTimeout().accepted === false);

  // AUTO-PLAY, NOT FORFEIT. Forfeiting one of four players mid-match ruins the game for the
  // other three: the board changes shape and the match becomes something nobody signed up for.
  const expired = ludo.restore(
    { ...e.serialize(), deadlineAt: Date.now() - 1 }, e.serializeSecret!());
  const r = (expired as any).onTimeout();
  check('an expired turn auto-plays rather than forfeiting', r.accepted === true);
  check('the match is NOT finished by a timeout', expired.isFinished() === false);
  check('nobody was removed', st(expired).players.length === 4);

  // On a move deadline it picks from the server's own legal set.
  const mid = withBoard(P4,
    [[4, YARD], [10, YARD], [20, YARD], [30, YARD]],
    { phase: 'awaitingMove', die: 1, legal: [0], turn: 0, deadlineAt: Date.now() - 1 });
  const r2 = (mid as any).onTimeout();
  check('an expired move auto-plays a legal move', r2.accepted === true);
  check('and the token actually moved', st(mid).tokens[0][0] === 5);
}

// --- Options and seats -------------------------------------------------------------------------
console.log('\nOptions and seats');
{
  // DEFAULTS ARE THE LENGTH DECISION (§2.7): 4 tokens at two players, 2 at three or four, so no
  // default configuration exceeds ~20 minutes.
  check('2 players default to 4 tokens',
    st(ludo.create(P2)).tokensPerPlayer === 4);
  check('4 players default to 2 tokens',
    st(ludo.create(P4)).tokensPerPlayer === 2);
  check('3 players default to 2 tokens',
    st(ludo.create(P4.slice(0, 3))).tokensPerPlayer === 2);

  // Untrusted, so clamped rather than believed.
  check('an explicit token count is honoured',
    st(ludo.create(P4, { tokens: 4 })).tokensPerPlayer === 4);
  check('a token count over 4 is clamped',
    st(ludo.create(P4, { tokens: 99 })).tokensPerPlayer === 4);
  check('a token count under 2 is clamped',
    st(ludo.create(P4, { tokens: 0 })).tokensPerPlayer === 2);
  check('a non-integer token count falls back',
    st(ludo.create(P4, { tokens: 2.5 as any })).tokensPerPlayer === 2);

  check('four seats each get their own tokens',
    st(ludo.create(P4, { tokens: 2 })).tokens.length === 4);
  check('every token starts in the yard',
    st(ludo.create(P4, { tokens: 2 })).tokens.every((row: number[]) => row.every((p) => p === YARD)));
}

// --- Contract -----------------------------------------------------------------------------------
console.log('\nContract');
{
  check('ludo is turn-based (no tickHz)', ludo.tickHz === undefined);
  const e = ludo.create(P4, { tokens: 2 });
  check('it has no tick loop', e.tick === undefined);
  check('it has no wire projection', e.serializeForWire === undefined);
  // LUDO HAS NO HIDDEN PLAYER INFORMATION, so no per-player projection — unusual for a 4-player
  // game and worth stating, because the instinct after Sea Battle is that multi-seat implies
  // per-seat views. A consequence: spectating Ludo is free.
  check('it has NO player projection (nothing is hidden)',
    (e as any).serializeForPlayer === undefined);
  check('it has a secret channel (the RNG)', typeof e.serializeSecret === 'function');
  check('it has a deadline', typeof (e as any).deadlineAt === 'function');
  check('it has a timeout handler', typeof (e as any).onTimeout === 'function');
}

console.log(failures === 0 ? '\nLudo OK\n' : `\n${failures} FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
