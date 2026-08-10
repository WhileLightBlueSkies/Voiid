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
