// Headless engine test. Run: npx tsx src/engine/cricket/cricket.test.ts
//
// Focused on the TOSS. It is the first thing in this game a player could cheat at other than
// the picks, so it gets the same treatment they do: the properties that make it fair are
// asserted rather than assumed —
//
//   * the coin is never visible before it is called (or the caller wins every toss);
//   * only the caller may call, and only the WINNER may elect (or the loser takes the prize);
//   * no ball is playable until the toss resolves;
//   * a restore mid-toss does not re-flip a coin that has already been called;
//   * a match created BEFORE the toss shipped still plays.
//
// Same plain-tsx style as snake.test.ts — this package has no test runner, deliberately.
import { cricket } from './index';
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

const tossOf = (e: GameEngine): Record<string, unknown> =>
  e.serialize().toss as Record<string, unknown>;

/** Create a match and work out which player the server chose to hold the call. */
function open(): { e: GameEngine; caller: string; other: string } {
  const e = cricket.create(P, { overs: 1 });
  const callerSeat = tossOf(e).callerSeat as 0 | 1;
  return { e, caller: P[callerSeat], other: P[callerSeat === 0 ? 1 : 0] };
}

/** The coin, read off the SECRET channel — which is the only place it exists pre-call. */
const coinOf = (e: GameEngine): string =>
  (e.serializeSecret!() as GameStatePayload).coin as string;

/** Call correctly, whatever the coin happens to be. */
function winTheToss(e: GameEngine, caller: string): void {
  check('  (setup) correct call accepted', e.applyInput(caller, { call: coinOf(e) }).accepted);
}

console.log('\nCricket toss\n');

// --- 1. The match opens on a toss ------------------------------------------------------
{
  const { e } = open();
  check('opens in toss-call, not in play', e.serialize().phase === 'toss-call');
}

// --- 2. The coin is hidden until called ------------------------------------------------
{
  const { e, caller } = open();
  check('coin is null before the call', tossOf(e).coin === null);
  winTheToss(e, caller);
  const revealed = tossOf(e).coin;
  check('coin revealed after the call', revealed === 'heads' || revealed === 'tails',
        String(revealed));
}

// --- 3. Only the caller may call --------------------------------------------------------
{
  const { e, other } = open();
  check('non-caller cannot call', !e.applyInput(other, { call: 'heads' }).accepted);
  check('phase unchanged by the refused call', e.serialize().phase === 'toss-call');
}

// --- 4. Garbage and double calls are refused --------------------------------------------
{
  const { e, caller } = open();
  check('nonsense call refused', !e.applyInput(caller, { call: 'edge' }).accepted);
  winTheToss(e, caller);
  check('second call refused', !e.applyInput(caller, { call: 'heads' }).accepted);
}

// --- 5. The call resolves to the right seat, both ways ----------------------------------
{
  for (const shouldWin of [true, false]) {
    const { e, caller, other } = open();
    const coin = coinOf(e);
    const call = shouldWin ? coin : coin === 'heads' ? 'tails' : 'heads';
    e.applyInput(caller, { call });
    const winner = P[tossOf(e).wonSeat as 0 | 1];
    check(`${shouldWin ? 'correct' : 'wrong'} call -> ${shouldWin ? 'caller' : 'opponent'} wins`,
          winner === (shouldWin ? caller : other));
  }
}

// --- 6. Only the toss winner may elect ---------------------------------------------------
{
  const { e, caller, other } = open();
  winTheToss(e, caller);
  check('toss loser cannot elect', !e.applyInput(other, { elect: 'bat' }).accepted);
  check('toss winner can elect', e.applyInput(caller, { elect: 'bat' }).accepted);
}

// --- 7. Both elections are honoured ------------------------------------------------------
{
  for (const elect of ['bat', 'bowl'] as const) {
    const { e, caller, other } = open();
    winTheToss(e, caller);
    e.applyInput(caller, { elect });
    const batting = P[e.serialize().battingSeat as 0 | 1];
    check(`elect ${elect} -> ${elect === 'bat' ? 'winner' : 'opponent'} bats`,
          batting === (elect === 'bat' ? caller : other));
    check(`elect ${elect} -> phase becomes play`, e.serialize().phase === 'play');
  }
}

// --- 8. No cricket before the toss is done -----------------------------------------------
{
  const { e, caller, other } = open();
  check('pick refused before the call', !e.applyInput(caller, { pick: 3 }).accepted);
  check('opponent pick refused too', !e.applyInput(other, { pick: 3 }).accepted);
  winTheToss(e, caller);
  check('pick still refused before the election', !e.applyInput(caller, { pick: 3 }).accepted);
  e.applyInput(caller, { elect: 'bat' });
  check('pick accepted once the toss resolves', e.applyInput(caller, { pick: 3 }).accepted);
}

// --- 9. A restore mid-toss must not re-flip a called coin --------------------------------
{
  const { e, caller } = open();
  winTheToss(e, caller);
  const coin = tossOf(e).coin;
  const wonSeat = tossOf(e).wonSeat;

  const revived = cricket.restore(e.serialize(), e.serializeSecret!());
  check('coin survives restore', tossOf(revived).coin === coin);
  check('toss winner survives restore', tossOf(revived).wonSeat === wonSeat);
  check('phase survives restore', revived.serialize().phase === 'toss-decide');
}

// --- 10. Matches predating the toss keep playing ------------------------------------------
{
  // These are mid-innings right now and must not be dragged back to a toss they passed.
  const legacy = cricket.restore(
    {
      players: P, overs: 1, battingSeat: 1, innings: 1, scores: [4, 0], wickets: [0, 0],
      ballsBowled: 2, target: null, history: [], finished: false, winnerUserId: null,
    },
    undefined,
  );
  check('legacy match reports phase play', legacy.serialize().phase === 'play');
  check('legacy match accepts a pick', legacy.applyInput(P[1], { pick: 2 }).accepted);
}

// --- 11. Neither seat holds the call more often than chance -------------------------------
{
  const N = 4000;
  let seatZero = 0;
  for (let i = 0; i < N; i += 1) {
    const s = cricket.create(P, { overs: 1 }).serialize();
    if ((s.toss as Record<string, unknown>).callerSeat === 0) seatZero += 1;
  }
  const drift = Math.abs(seatZero / N - 0.5);
  // ~4 sigma; a hardcoded seat or an off-by-one blows straight through it.
  check('call is a fair coin across seats', drift < 0.032, `drift ${drift.toFixed(4)}`);
}

// --- 12. A full match still plays end to end ----------------------------------------------
{
  const { e, caller } = open();
  winTheToss(e, caller);
  e.applyInput(caller, { elect: 'bat' });

  let balls = 0;
  while (!e.isFinished() && balls < 200) {
    // Deterministic but unequal picks, so the match progresses without constant wickets.
    e.applyInput(P[0], { pick: balls % 7 });
    e.applyInput(P[1], { pick: (balls + 3) % 7 });
    balls += 1;
  }
  check('match reaches a finish through the toss path', e.isFinished(), `${balls} balls`);
  const s = e.serialize();
  check('finished match still reports its toss', (s.toss as Record<string, unknown>).choice === 'bat');
}

console.log(failures === 0 ? '\nAll checks passed.\n' : `\n${failures} check(s) FAILED.\n`);
process.exit(failures === 0 ? 0 : 1);
