// Guards the three turn-based games against the GameEngine changes Snake required
// (`silent` on ApplyResult, optional `serializeForWire`). Both are optional, so these must
// behave exactly as before: every accepted move still broadcasts, and none of them grows a
// wire projection.
import { factoryFor } from './registry';

let bad = 0;
const ok = (n: string, c: boolean) => { console.log(`${c ? 'PASS' : 'FAIL'}  ${n}`); if (!c) bad++; };

for (const slug of ['tictactoe', 'rps', 'cricket']) {
  const f = factoryFor(slug)!;
  ok(`${slug} registered`, !!f);
  ok(`${slug} stays turn-based (no tickHz)`, f.tickHz === undefined);
  const e = f.create(['a', 'b'], { overs: 1 });
  ok(`${slug} has no wire projection`, e.serializeForWire === undefined);
  ok(`${slug} has no tick`, e.tick === undefined);
  // Sea Battle added three more optional members to the interface. The shipped games must not
  // acquire any of them by accident: a serializeForPlayer here would silently switch that game
  // to per-recipient frames, and a deadlineAt would put it on the sweeper's clock.
  ok(`${slug} has no player projection`, e.serializeForPlayer === undefined);
  ok(`${slug} has no deadline`, e.deadlineAt === undefined);
  ok(`${slug} has no timeout handler`, e.onTimeout === undefined);
}

// Snake, the continuous game, must also stay off the deadline sweeper — it has its own clock.
{
  const s = factoryFor('snake')!.create(['a'], { bots: 1 });
  ok('snake has no deadline', s.deadlineAt === undefined);
  ok('snake has no player projection', s.serializeForPlayer === undefined);
}

// LUDO HAS NO HIDDEN PLAYER INFORMATION, so it must NOT acquire a player projection — unusual
// for a multi-seat game, and worth asserting because the instinct after Sea Battle is that more
// seats implies per-seat views. Its secret is the RNG alone: the next draw is the dice, and a
// client holding the seed does not cheat at Ludo, it solves it.
{
  const f = factoryFor('ludo')!;
  ok('ludo registered', !!f);
  ok('ludo stays turn-based (no tickHz)', f.tickHz === undefined);
  const e = f.create(['a', 'b', 'c', 'd'], { mode: 'four' });
  // Schema v2 (LUDO_GAME_SPEC.md §6): Ludo now projects PER RECIPIENT — not for hidden
  // state, but for the identity projection. A viewer must never RECEIVE an unauthorized
  // real username, so names are resolved server-side per frame.
  ok('ludo has a player projection (identity, schema v3)', typeof e.serializeForPlayer === 'function');
  const frame = JSON.stringify(e.serializeForPlayer!('a'));
  ok('projection carries no raw user ids', !frame.includes('"a"') && !frame.includes('"players"'));
  ok('ludo has a secret channel (rng + seat roster)', typeof e.serializeSecret === 'function');
  ok('ludo keeps its seed OFF the wire', !('seed' in e.serialize()));
  ok('ludo has a deadline', typeof e.deadlineAt === 'function');
  ok('ludo has a timeout handler', typeof e.onTimeout === 'function');
}

// Sea Battle is the one that opts into all three.
{
  const f = factoryFor('seabattle')!;
  ok('seabattle registered', !!f);
  ok('seabattle is turn-based (no tickHz)', f.tickHz === undefined);
  const e = f.create(['a', 'b']);
  ok('seabattle has a player projection', typeof e.serializeForPlayer === 'function');
  ok('seabattle has a deadline', typeof e.deadlineAt === 'function');
  ok('seabattle has a timeout handler', typeof e.onTimeout === 'function');
  ok('seabattle has a secret channel', typeof e.serializeSecret === 'function');
  ok('seabattle has no wire projection', e.serializeForWire === undefined);
}

// A legal tictactoe move must still be a broadcasting move.
const ttt = factoryFor('tictactoe')!.create(['a', 'b']);
const r = ttt.applyInput('a', { cell: 0 });
ok('tictactoe move accepted', r.accepted === true);
ok('tictactoe move still broadcasts (silent unset)', !r.silent);

// Snake is the only one that opts into the new behaviour.
const snake = factoryFor('snake')!;
// Checks the CONTRACT (it has a tick rate, in the band GAMES.md §80 allows), not a specific
// number — the rate is a tuning value and pinning it here makes every tuning change look
// like a regression.
ok('snake is continuous (tickHz set, 10-15 Hz)',
   typeof snake.tickHz === 'number' && snake.tickHz >= 10 && snake.tickHz <= 15);
const s = snake.create(['a'], { bots: 1 });
ok('snake has a wire projection', typeof s.serializeForWire === 'function');
ok('snake steering is silent', s.applyInput('a', { h: 1 }).silent === true);

console.log(bad === 0 ? '\nRegression OK\n' : `\n${bad} FAILED\n`);
process.exit(bad === 0 ? 0 : 1);
