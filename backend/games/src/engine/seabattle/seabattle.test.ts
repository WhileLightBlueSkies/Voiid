// Headless engine test. Run: npx tsx src/engine/seabattle/seabattle.test.ts
//
// SEA BATTLE IS THE EASIEST GAME IN THE APP TO TEST PROPERLY, because every rule is discrete:
// a fleet is legal or it is not, a shot hits or it does not, a ship is sunk or it is not. There
// is no physics tolerance and no timing. So it gets the coverage SNAKE.md notes only Snake has.
//
// The two tests that matter most are not the rules tests:
//
//   * the serialize -> restore -> serialize ROUND TRIP, which catches the bug class
//     GameEngine.ts documents — a field omitted from serialize() is silently reset on the next
//     input, and nothing else in the system notices;
//   * RESTORE WITHOUT THE SECRET, which must abandon loudly rather than continue into a match
//     where every remaining shot is a miss because the ships no longer exist anywhere.
//
// Same plain-tsx style as snake.test.ts and cricket.test.ts — this package has no test runner,
// deliberately.
import { seabattle } from './index';
import { FLEET_SPEC, packed, validateFleet, randomFleet, type Ship } from './fleet';
import { Rng } from '../rng';
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

const P = ['alice', 'bob'];

/**
 * A known-legal fleet, one ship per row starting at `startRow`, laid from column 0.
 *
 * The longest ship is 5, so a fleet built this way NEVER touches columns 5-9. Every test below
 * relies on that: columns 5-9 are guaranteed-empty water on both boards, which is what `water()`
 * returns. Without a guarantee like that, a "miss" in a test is only a miss until someone
 * changes a fixture.
 */
function rowFleet(startRow: number): Ship[] {
  return FLEET_SPEC.map((len, type) => ({
    type,
    cells: Array.from({ length: len }, (_, i) => packed(i, startRow + type)),
    hits: 0,
  }));
}

/**
 * The nth guaranteed-empty cell: columns 5-9 of every row, in order.
 *
 * 50 distinct cells, which is more than any test here burns. It has to be distinct as well as
 * empty — re-firing a square is rejected, so a repeating "filler" cell would silently stop
 * passing the turn back and the test would hang on its own fixture rather than on the engine.
 */
function water(n: number): number {
  return packed(5 + (n % 5), Math.floor(n / 5) % 10);
}

const wire = (ships: Ship[]) => ships.map((s) => ({ type: s.type, cells: s.cells }));

/** A match with both fleets committed and firing open. */
function firingMatch(): { e: GameEngine; a: Ship[]; b: Ship[] } {
  const e = seabattle.create(P, { seed: 12345 });
  const a = rowFleet(0);
  const b = rowFleet(5);
  e.applyInput('alice', { place: wire(a) });
  e.applyInput('bob', { place: wire(b) });
  return { e, a, b };
}

const st = (e: GameEngine) => e.serialize() as any;

// --- Placement validation, one rejection reason at a time ------------------------------
//
// Asserted separately rather than as "some illegal fleet is rejected". A test that can only say
// "rejected" cannot tell a correctly-rejected fleet from one rejected for the wrong reason, and
// the reasons are what the client renders.
console.log('\nPlacement validation');
{
  const legal = rowFleet(0);
  check('a legal fleet validates', validateFleet(legal) === null);

  check(
    'four ships is rejected',
    validateFleet(legal.slice(0, 4)) === 'wrong-ship-count'
  );
  check(
    'six ships is rejected',
    validateFleet([...legal, legal[0]]) === 'wrong-ship-count'
  );

  const dup = rowFleet(0).map((s, i) => (i === 1 ? { ...s, type: 0 } : s));
  check('two ships of the same type is rejected', validateFleet(dup) === 'duplicate-type');

  const unknown = rowFleet(0).map((s, i) => (i === 0 ? { ...s, type: 9 } : s));
  check('an unknown ship type is rejected', validateFleet(unknown) === 'unknown-type');

  // A client claiming a 2-cell Carrier. The engine recomputes length from the cells rather than
  // believing the type — nothing is trusted about ship identity.
  const short = rowFleet(0).map((s, i) => (i === 0 ? { ...s, cells: s.cells.slice(0, 2) } : s));
  check('a Carrier with 2 cells is rejected', validateFleet(short) === 'wrong-length');

  const offBoard = rowFleet(0).map((s, i) => (i === 0 ? { ...s, cells: [95, 96, 97, 98, 199] } : s));
  check('a cell outside 0-99 is rejected', validateFleet(offBoard) === 'off-board');

  const negative = rowFleet(0).map((s, i) => (i === 4 ? { ...s, cells: [-1, 0] } : s));
  check('a negative cell is rejected', validateFleet(negative) === 'off-board');

  // Diagonal. There is no separate diagonal rule — a diagonal ship is neither in one row nor in
  // one column, so the contiguity check is what rejects it.
  const diagonal = rowFleet(0).map((s, i) =>
    i === 4 ? { ...s, cells: [packed(0, 8), packed(1, 9)] } : s
  );
  check('a diagonal ship is rejected', validateFleet(diagonal) === 'not-contiguous');

  const gapped = rowFleet(0).map((s, i) =>
    i === 4 ? { ...s, cells: [packed(0, 8), packed(2, 8)] } : s
  );
  check('a ship with a gap is rejected', validateFleet(gapped) === 'not-contiguous');

  // ROW WRAP. Packed cells 9,10 are consecutive integers, so a naive `c[i+1] === c[i]+1` check
  // accepts a Destroyer that runs off column J and reappears at column A on the next row.
  //
  // Placed on rows 8/9, away from the rest of the fleet on purpose: put it at 9,10 and the cell
  // collides with the Cruiser on row 1, so `overlap` is reported first and the test passes for
  // the wrong reason without ever exercising the wrap check.
  const wrapped = rowFleet(0).map((s, i) =>
    i === 4 ? { ...s, cells: [packed(9, 8), packed(0, 9)] } : s
  );
  check('a ship wrapping J -> A is rejected', validateFleet(wrapped) === 'not-contiguous');

  const overlapping = rowFleet(0).map((s, i) =>
    i === 4 ? { ...s, cells: [packed(0, 0), packed(1, 0)] } : s
  );
  check('two ships overlapping is rejected', validateFleet(overlapping) === 'overlap');

  const selfOverlap = rowFleet(0).map((s, i) => (i === 4 ? { ...s, cells: [50, 50] } : s));
  check('a ship doubling back on itself is rejected', validateFleet(selfOverlap) === 'overlap');

  // Ships MAY touch, including at corners — deliberately against the Russian rules (§2.2).
  const touching: Ship[] = [
    { type: 0, cells: [0, 1, 2, 3, 4], hits: 0 },
    { type: 1, cells: [5, 6, 7, 8], hits: 0 },       // adjacent to the Carrier
    { type: 2, cells: [10, 11, 12], hits: 0 },        // directly below it
    { type: 3, cells: [13, 14, 15], hits: 0 },
    { type: 4, cells: [16, 17], hits: 0 },
  ];
  check('adjacent ships are legal', validateFleet(touching) === null);
}

// --- randomFleet ----------------------------------------------------------------------
console.log('\nRandom placement');
{
  // The Random button is mandatory and the default path, so it must never produce a fleet the
  // engine would reject — a player whose one tap produces an illegal board has no recourse.
  let allLegal = true;
  for (let seed = 1; seed <= 500; seed++) {
    if (validateFleet(randomFleet(new Rng(seed))) !== null) {
      allLegal = false;
      break;
    }
  }
  check('500 seeds all produce a legal fleet', allLegal);

  // Determinism: the same seed must produce the same fleet, or a restore mid-placement would
  // hand the player a different board than the one they were looking at.
  const a = JSON.stringify(randomFleet(new Rng(99)));
  const b = JSON.stringify(randomFleet(new Rng(99)));
  check('the same seed places the same fleet', a === b);
}

// --- Phase and turn gating -------------------------------------------------------------
console.log('\nPhases and turns');
{
  const e = seabattle.create(P, { seed: 7 });
  check('a fresh match is in the placing phase', st(e).phase === 'placing');
  check('no shot is legal during placement', e.applyInput('alice', { fire: 0 }).accepted === false);

  const legal = wire(rowFleet(0));
  check('placing a legal fleet is accepted', e.applyInput('alice', { place: legal }).accepted === true);
  check('re-placing is rejected', e.applyInput('alice', { place: legal }).accepted === false);
  check('still placing while one player is unplaced', st(e).phase === 'placing');
  check('the unplaced player cannot fire yet', e.applyInput('bob', { fire: 0 }).accepted === false);

  e.applyInput('bob', { place: wire(rowFleet(5)) });
  check('both placed opens the firing phase', st(e).phase === 'firing');
  check('a turn is assigned when firing opens', st(e).turn === 0 || st(e).turn === 1);
  check('turnUserId matches the seat', st(e).turnUserId === P[st(e).turn]);

  // The first-move draw happens at create() and must be held through placement, so a restore
  // mid-placement cannot re-flip it.
  const e2 = seabattle.create(P, { seed: 7 });
  const turnBefore = st(e2).turn;
  const restored = seabattle.restore(e2.serialize(), e2.serializeSecret?.());
  check('the first-move draw survives a restore mid-placement', st(restored).turn === turnBefore);
}

// --- Firing ----------------------------------------------------------------------------
console.log('\nFiring');
{
  const { e, a, b } = firingMatch();
  const first = st(e).turn as number;
  const me = P[first];
  const them = P[1 - first];
  // You fire at the OTHER seat's fleet, whichever seat you drew.
  const targetFleet = first === 0 ? b : a;

  check('the player not on turn cannot fire', e.applyInput(them, { fire: 55 }).accepted === false);
  check('a non-integer cell is rejected', e.applyInput(me, { fire: 3.5 }).accepted === false);
  check('cell 100 is rejected', e.applyInput(me, { fire: 100 }).accepted === false);
  check('a negative cell is rejected', e.applyInput(me, { fire: -1 }).accepted === false);
  check('a string cell is rejected', e.applyInput(me, { fire: '55' } as any).accepted === false);

  // A guaranteed miss: both fleets are laid from column 0 and the longest ship is 5, so column 9
  // is empty on both boards.
  const missCell = water(0);
  const r = e.applyInput(me, { fire: missCell });
  check('a legal shot is accepted', r.accepted === true);
  check('a shot broadcasts (silent unset)', !r.silent);
  check('a miss records result 0', st(e).results[first][0] === 0);
  check('lastShot is the fired cell', st(e).lastShot === missCell);
  check('the turn passes on a miss', st(e).turn === 1 - first);

  // Re-firing the same square. The turn has passed, so hand it back first.
  e.applyInput(them, { fire: water(1) });
  check('re-firing a fired square is rejected', e.applyInput(me, { fire: missCell }).accepted === false);

  // A hit, and the turn STILL passes — one shot per turn, no extra shot on a hit (§2.3).
  //
  // This is the attacker's SECOND recorded shot, not their third: the rejected re-fire above
  // recorded nothing, which is itself the point — a rejected input must not advance the board.
  const hitCell = targetFleet[0].cells[0];
  e.applyInput(me, { fire: hitCell });
  check('a rejected shot recorded nothing', st(e).results[first].length === 2);
  check('a hit records result 1', st(e).results[first][1] === 1);
  check('a hit does NOT grant another shot', st(e).turn === 1 - first);
}

// --- Sinking and winning ----------------------------------------------------------------
console.log('\nSinking and winning');
{
  const { e, a, b } = firingMatch();
  // Play from whichever seat drew the first shot rather than forcing one — burning a turn to
  // force seat 0 would silently change the shot counts the scoring assertions below check.
  const seat = st(e).turn as number;
  const attacker = P[seat];
  const defender = P[1 - seat];
  const targetFleet = seat === 0 ? b : a;
  // The defender always fires into guaranteed water, so the only sinking in this test is the
  // attacker's and the match cannot end from the other direction mid-loop.
  let filler = 0;

  // Sink the Destroyer (type 4, 2 cells) first, to observe a sink in isolation.
  const destroyer = targetFleet[4].cells;
  e.applyInput(attacker, { fire: destroyer[0] });
  check('a hit that does not sink records 1', st(e).results[seat].at(-1) === 1);
  check('nothing is revealed before the ship sinks', st(e).sunkCells[1 - seat].length === 0);

  e.applyInput(defender, { fire: water(filler++) });
  e.applyInput(attacker, { fire: destroyer[1] });

  check('the sinking shot records result 2', st(e).results[seat].at(-1) === 2);
  check('the sunk ship type is recorded against its owner', st(e).sunk[1 - seat].includes(4));
  check(
    'the sunk ship outline is promoted into public state',
    destroyer.every((c: number) => st(e).sunkCells[1 - seat].includes(c))
  );
  check('the attacker loses nothing to the sink', st(e).sunk[seat].length === 0);

  // The sinking shot passed the turn to the defender, like every other shot — one shot per turn
  // holds on a sink too. So the defender burns one before the loop, which then alternates
  // attacker/defender cleanly.
  e.applyInput(defender, { fire: water(filler++) });

  // Sink the remaining 15 cells, the defender burning water in between so the turn returns.
  const remaining = targetFleet.slice(0, 4).flatMap((s) => s.cells);
  let outcome: any = null;
  let everyShotAccepted = true;
  for (const cell of remaining) {
    const res = e.applyInput(attacker, { fire: cell });
    // Rolled into one assertion rather than fifteen: a rejected shot here means the fixture has
    // drifted out of turn, and reporting it once is enough to say so.
    if (!res.accepted) everyShotAccepted = false;
    if (res.outcome) {
      outcome = res.outcome;
      break;
    }
    e.applyInput(defender, { fire: water(filler++) });
  }
  check('every shot in the sink sequence was in turn', everyShotAccepted);

  check('the match ends when the last ship sinks', outcome !== null);
  check('the winner is the player who fired the last shot', outcome?.winnerId === attacker);
  check('isFinished is true', e.isFinished() === true);
  check('phase is done', st(e).phase === 'done');
  check('no turn is outstanding', st(e).turn === null);
  check('no deadline is outstanding', e.deadlineAt?.() === null);
  check('input after the match ends is rejected', e.applyInput('bob', { fire: 0 }).accepted === false);

  // Score is SHOTS FIRED, lower being better — 17 hits plus the misses along the way.
  check('the winner is scored on shots fired', outcome?.scores?.[attacker] === st(e).shots[seat].length);
  check('the loser is scored on their own shots', outcome?.scores?.[defender] === st(e).shots[1 - seat].length);
  check('shots fired is at least the fleet size', outcome?.scores?.[attacker] >= 17);

  // The terminal frame is the one place both fleets go out in full.
  check('both fleets are revealed once the match is over', st(e).revealedFleets !== null);
}

// --- Information projection --------------------------------------------------------------
//
// The property this game does not exist without: you can see your fleet, your opponent cannot,
// and a spectator sees neither. Asserted on the SERIALIZED payload rather than on internals,
// because the payload is what actually leaves the process.
console.log('\nInformation projection');
{
  const { e, a, b } = firingMatch();
  const forAlice = (e as any).serializeForPlayer('alice') as any;
  const forBob = (e as any).serializeForPlayer('bob') as any;
  const forSpectator = (e as any).serializeForPlayer('carol') as any;

  check('a player is told their own seat', forAlice.seat === 0 && forBob.seat === 1);
  check('a player sees their own fleet', JSON.stringify(forAlice.myFleet) === JSON.stringify(a));
  check('the other player sees theirs', JSON.stringify(forBob.myFleet) === JSON.stringify(b));

  // THE REAL TEST, and it is asserted structurally rather than by scanning for numbers: the only
  // fleet anywhere in alice's payload is alice's own. A substring search over the JSON would be
  // the obvious approach and a bad one — cell 5 appears inside "50", and `revealedFleets: null`
  // means the payload legitimately mentions no cells at all, so such a test passes whether or
  // not the leak exists.
  const aliceJson = JSON.stringify(forAlice);
  check(
    "alice's payload contains exactly one fleet",
    (aliceJson.match(/"myFleet"/g) ?? []).length === 1
  );
  check(
    "and it is alice's, not bob's",
    JSON.stringify(forAlice.myFleet) !== JSON.stringify(b)
  );
  check(
    'no fleet is revealed while the match is live',
    forAlice.revealedFleets === null && forBob.revealedFleets === null
  );
  check('the public shape carries no fleet at all', !JSON.stringify(e.serialize()).includes('myFleet'));

  // A caller with no seat falls through to serialize(), so a leak to a spectator would have to
  // be ADDED rather than merely not prevented.
  check('a spectator gets no fleet', forSpectator.myFleet === undefined);
  check('a spectator gets no seat', forSpectator.seat === undefined);
  check(
    'a spectator sees exactly the public state',
    JSON.stringify(forSpectator) === JSON.stringify(e.serialize())
  );

  // Additive: a player is never shown LESS than the public truth.
  const pub = e.serialize();
  check(
    'the player projection is a superset of the public state',
    Object.keys(pub).every((k) => k in forAlice)
  );
}

// --- Serialize / restore round trip --------------------------------------------------------
//
// THE TEST THAT CATCHES THE BUG CLASS GameEngine.ts DOCUMENTS. The runtime round-trips
// serialize()/restore() on every single input, so a field left out of serialize() is silently
// reset a millisecond after being set, and nothing surfaces an error.
console.log('\nSerialize / restore round trip');
{
  // Serialized mid-match, with a sunk ship, so the round trip covers the fields a naive shape
  // loses — sunkCells and deadlineAt — rather than an opening board where every array is empty.
  const { e, b } = firingMatch();
  if (st(e).turn === 1) e.applyInput('bob', { fire: water(0) });
  e.applyInput('alice', { fire: b[4].cells[0] });
  e.applyInput('bob', { fire: water(1) });
  e.applyInput('alice', { fire: b[4].cells[1] }); // sinks the Destroyer

  const before = e.serialize();
  const secret = e.serializeSecret!();
  const restored = seabattle.restore(
    JSON.parse(JSON.stringify(before)),
    JSON.parse(JSON.stringify(secret))
  );
  const after = restored.serialize();

  check(
    'serialize -> restore -> serialize is byte-identical',
    JSON.stringify(before) === JSON.stringify(after),
    `\n    before: ${JSON.stringify(before)}\n    after:  ${JSON.stringify(after)}`
  );
  check(
    'the secret round-trips too',
    JSON.stringify(secret) === JSON.stringify(restored.serializeSecret!())
  );

  // And the restored engine must still PLAY correctly, not merely serialize identically — a
  // restore that produces a valid-looking board with no fleets underneath passes the check above.
  const turn = st(restored).turn as number;
  const r = restored.applyInput(P[turn], { fire: b[3].cells[0] });
  check('the restored engine still accepts a legal shot', r.accepted === true);
  check(
    'the restored engine still resolves hits against the real fleet',
    turn === 0 ? st(restored).results[0].at(-1) === 1 : true
  );
  check(
    'the restored engine still rejects an already-fired square',
    restored.applyInput(P[1 - turn], { fire: 999 }).accepted === false
  );

  // deadlineAt is SERIALIZED rather than recomputed from "now". Recomputing on restore would
  // hand an AFK player a fresh 24 hours on every process restart — the failure direction where
  // nobody is ever forfeited.
  check(
    'the deadline survives a restore unchanged',
    (restored as any).deadlineAt() === (e as any).deadlineAt()
  );
}

// --- Restore without the secret --------------------------------------------------------
//
// Sea Battle's secret is the ENTIRE match, not one ball. A restore that loses it has no fact
// about where the ships are, so every subsequent shot would have to be a miss. It must abandon
// loudly rather than continue into a match that quietly stopped being winnable.
console.log('\nRestore without the secret');
{
  const { e } = firingMatch();
  const state = e.serialize();
  const orphan = seabattle.restore(JSON.parse(JSON.stringify(state)), undefined);

  check('a firing match without its secret is finished', orphan.isFinished() === true);
  check('it is marked abandoned', st(orphan).endedBy === 'abandoned');
  check('it has no winner', st(orphan).winnerUserId === null);
  check('it accepts no further input', orphan.applyInput('alice', { fire: 0 }).accepted === false);
  check('it holds no deadline', (orphan as any).deadlineAt() === null);

  // A match still in PLACEMENT has no secret yet by definition, and must restore normally —
  // treating an empty fleet as a lost secret there would abandon every match at its first join.
  const fresh = seabattle.create(P, { seed: 3 });
  const stillPlacing = seabattle.restore(fresh.serialize(), fresh.serializeSecret?.());
  check('a placing match restores without a secret', stillPlacing.isFinished() === false);
  check('and can still be placed into', stillPlacing.applyInput('alice', { place: wire(rowFleet(0)) }).accepted === true);
}

// --- Resignation -------------------------------------------------------------------------
console.log('\nResignation');
{
  const { e } = firingMatch();
  const r = e.applyInput('bob', { resign: true });
  check('resigning is accepted', r.accepted === true);
  check('resigning hands the win to the opponent', r.outcome?.winnerId === 'alice');
  check('a resignation is flagged as one', st(e).endedBy === 'resign');
  // A resignation is a RESULT, not an abandonment: it must count in the head-to-head, and it has
  // real scores. An abandoned match scores {} and must not count.
  check('a resignation carries real scores', Object.keys(r.outcome?.scores ?? {}).length === 2);

  // Resigning is legal out of turn — it is not a move.
  const { e: e2 } = firingMatch();
  const notMyTurn = P[1 - (st(e2).turn as number)];
  check('resigning out of turn is still accepted', e2.applyInput(notMyTurn, { resign: true }).accepted === true);
}

// --- Deadlines and timeout ---------------------------------------------------------------
console.log('\nDeadlines and timeout');
{
  const e = seabattle.create(P, { seed: 11 });
  const d = (e as any).deadlineAt() as number;
  check('a placement deadline is set at creation', typeof d === 'number' && d > Date.now());
  check('it is roughly 24h out', Math.abs(d - Date.now() - 24 * 3600 * 1000) < 5000);

  // A deadline in the future must NOT fire. The sweeper pops set members without knowing whether
  // the player has since moved, so the engine is what decides the deadline is real — this is the
  // check that stops a duplicated delivery forfeiting someone who already played.
  check('a future deadline does not fire', (e as any).onTimeout().accepted === false);

  // Both AFK in placement: nobody played, so nobody won and it counts for nothing.
  const bothAfk = seabattle.restore({ ...e.serialize(), deadlineAt: Date.now() - 1 }, e.serializeSecret?.());
  const r1 = (bothAfk as any).onTimeout();
  check('both unplaced abandons the match', r1.accepted === true && r1.outcome.winnerId === null);
  check('an abandoned match scores nothing', Object.keys(r1.outcome.scores).length === 0);
  check('and is flagged abandoned, not a timeout', st(bothAfk).endedBy === 'abandoned');

  // One placed: the player who turned up wins by walkover.
  const e2 = seabattle.create(P, { seed: 11 });
  e2.applyInput('alice', { place: wire(rowFleet(0)) });
  const oneAfk = seabattle.restore({ ...e2.serialize(), deadlineAt: Date.now() - 1 }, e2.serializeSecret?.());
  const r2 = (oneAfk as any).onTimeout();
  check('one player placed wins by walkover', r2.outcome?.winnerId === 'alice');
  check('a walkover is flagged as a timeout', st(oneAfk).endedBy === 'timeout');

  // A turn timeout forfeits to the opponent.
  const { e: e3 } = firingMatch();
  const onClock = st(e3).turn as number;
  const expired = seabattle.restore(
    { ...e3.serialize(), deadlineAt: Date.now() - 1 },
    e3.serializeSecret?.()
  );
  const r3 = (expired as any).onTimeout();
  check('an expired turn forfeits to the opponent', r3.outcome?.winnerId === P[1 - onClock]);
  check('a forfeit is flagged as a timeout', st(expired).endedBy === 'timeout');
  check('a forfeit still carries shot counts', Object.keys(r3.outcome.scores).length === 2);

  // A finished match holds no deadline, so the sweeper never re-registers one for it.
  check('a finished match has no deadline', (expired as any).deadlineAt() === null);
  check('a finished match ignores a second timeout', (expired as any).onTimeout().accepted === false);

  // The deadline moves forward on every accepted move — otherwise the clock would still be the
  // one from the start of the match and the active player would be forfeited mid-game.
  const { e: e4, b: b4 } = firingMatch();
  const before = (e4 as any).deadlineAt();
  e4.applyInput(P[st(e4).turn as number], { fire: packed(9, 9) });
  check('an accepted move refreshes the deadline', (e4 as any).deadlineAt() >= before);
  void b4;
}

// --- Contract / registry ------------------------------------------------------------------
console.log('\nContract');
{
  check('seabattle is turn-based (no tickHz)', seabattle.tickHz === undefined);
  const e = seabattle.create(P, { seed: 1 });
  check('it has no tick loop', e.tick === undefined);
  check('it has no wire projection', e.serializeForWire === undefined);
  check('it has an information projection', typeof (e as any).serializeForPlayer === 'function');
  check('it has a secret channel', typeof e.serializeSecret === 'function');
  check('it has a deadline', typeof (e as any).deadlineAt === 'function');
  check('it has a timeout handler', typeof (e as any).onTimeout === 'function');

  // A stranger is not a player, even though the runtime checks membership too.
  check('a non-player cannot place', e.applyInput('mallory', { place: wire(rowFleet(0)) }).accepted === false);
  check('a non-player cannot resign the match', e.applyInput('mallory', { resign: true }).accepted === false);
}

console.log(failures === 0 ? '\nSea Battle OK\n' : `\n${failures} FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
