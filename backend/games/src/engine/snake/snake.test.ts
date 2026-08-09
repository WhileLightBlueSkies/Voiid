// Headless engine test. Run: npx tsx src/engine/snake/snake.test.ts
//
// This exists because the runtime rebuilds the engine from serialized state on EVERY tick.
// That round-trip is the single most dangerous property of a continuous game in this
// architecture: any state a module forgets to serialize is silently reset 12 times a second,
// and the symptom is not a crash but a game that subtly refuses to progress. So the round
// trip is what these assertions are mostly about.

import { snake, TUNING } from './index';
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

/** Drive a match the way the runtime does: restore, tick, serialize, discard. */
function runRoundTripped(ticks: number, players: string[], bots: number) {
  let state: GameStatePayload = snake.create(players, { bots }).serialize();
  let finished = false;

  for (let i = 0; i < ticks && !finished; i++) {
    const engine: GameEngine = snake.restore(state);
    const r = engine.tick!();
    state = engine.serialize();
    if (r.outcome) finished = true;
  }
  return { state, finished };
}

console.log('\nSnake engine\n');

// --- 1. A match progresses at all ------------------------------------------------------
{
  const TICKS = 60;
  const { state } = runRoundTripped(TICKS, ['u1'], 5);
  const t = state.t as number;
  // The point of this check is that `t` SURVIVES the restore round-trip and accumulates. A
  // module that forgot to serialize `t` would report 1 tick's worth here, forever.
  check('time advances across restore cycles',
    Math.abs(t - TICKS / TUNING.TICK_HZ) < 0.05, `t=${t}, expected ${TICKS / TUNING.TICK_HZ}`);

  const snakes = state.snakes as any[];
  check('all snakes spawned', snakes.length === 6, `got ${snakes.length}`);
  check('snakes have moved from origin', snakes.some((s) => Math.hypot(s.x, s.y) > 1));
  // Only LIVING snakes are expected to have a body: kill() converts the whole path to food
  // and empties it, so a snake awaiting respawn legitimately has none.
  const living = snakes.filter((s) => s.a);
  check('living snakes have bodies',
    living.length > 0 && living.every((s) => s.p.length >= 4),
    `${living.filter((s) => s.p.length < 4).length} of ${living.length} bodyless`);
}

// --- 2. Determinism --------------------------------------------------------------------
// Same starting state + same inputs must give the same result, or Redis round-tripping
// would make the match diverge from itself.
{
  const base = snake.create(['u1'], { bots: 3 }).serialize();

  const drive = () => {
    let s: GameStatePayload = JSON.parse(JSON.stringify(base));
    for (let i = 0; i < 40; i++) {
      const e = snake.restore(s);
      e.tick!();
      s = e.serialize();
    }
    return s;
  };

  const a = JSON.stringify(drive());
  const b = JSON.stringify(drive());
  check('identical seeds produce identical matches', a === b);
}

// --- 3. Input is clamped, not trusted --------------------------------------------------
{
  const engine = snake.create(['u1'], { bots: 0 });
  const before = (engine.serialize().snakes as any[])[0];
  const h0 = before.h;

  // Ask for a full reversal; the turn-rate clamp must refuse to grant it in one tick.
  engine.applyInput('u1', { h: h0 + Math.PI });
  engine.tick!();
  const after = (engine.serialize().snakes as any[])[0];

  const turned = Math.abs(after.h - h0);
  const maxPerTick = (TUNING.TURN_RATE * Math.PI / 180) / TUNING.TICK_HZ;
  // Tolerance covers the 3-dp rounding applied to `h` on the wire, which can report a turn
  // marginally larger than the one actually taken.
  check('heading obeys the turn-rate clamp',
    turned <= maxPerTick + 2e-3, `turned ${turned.toFixed(4)} > max ${maxPerTick.toFixed(4)}`);

  check('non-player input is rejected',
    engine.applyInput('somebody-else', { h: 1 }).accepted === false);

  check('garbage heading does not corrupt state', (() => {
    engine.applyInput('u1', { h: 'north' as unknown as number });
    engine.tick!();
    const s = (engine.serialize().snakes as any[])[0];
    return Number.isFinite(s.h) && Number.isFinite(s.x);
  })());
}

// --- 4. Steering input does not trigger a broadcast ------------------------------------
{
  const engine = snake.create(['u1'], { bots: 0 });
  const r = engine.applyInput('u1', { h: 0.5 });
  check('steering is accepted but silent', r.accepted === true && r.silent === true);
}

// --- 5. The border kills ---------------------------------------------------------------
// Drive a snake straight at the wall with boost held and confirm it dies, rather than
// sliding along the edge or escaping the arena.
{
  let state = snake.create(['u1'], { bots: 0 }).serialize();
  let died = false;
  let escaped = false;

  for (let i = 0; i < 200 && !died; i++) {
    const e = snake.restore(state);
    const sn = (e.serialize().snakes as any[])[0];
    // Aim directly away from the centre.
    e.applyInput('u1', { h: Math.atan2(sn.y, sn.x) || 0, boost: true });
    e.tick!();
    state = e.serialize();

    const now = (state.snakes as any[])[0];
    if (Math.hypot(now.x, now.y) > (state.arenaRadius as number) + 50) escaped = true;
    if (!now.a) died = true;
  }

  check('a snake driven into the wall dies', died);
  check('no snake escapes the arena', !escaped);
}

// --- 6. Death converts the body to food ------------------------------------------------
{
  let state = snake.create(['u1'], { bots: 0 }).serialize();
  const foodAtStart = (state.food as any[]).length;

  let died = false;
  for (let i = 0; i < 200 && !died; i++) {
    const e = snake.restore(state);
    const sn = (e.serialize().snakes as any[])[0];
    e.applyInput('u1', { h: Math.atan2(sn.y, sn.x) || 0, boost: true });
    e.tick!();
    state = e.serialize();
    if (!(state.snakes as any[])[0].a) died = true;
  }

  check('death leaves corpse food behind',
    died && (state.food as any[]).some((f) => f[2] === 2));
  check('food field did not collapse',
    (state.food as any[]).length > foodAtStart * 0.5);
}

// --- 7. Respawn returns at starting mass -----------------------------------------------
{
  let state = snake.create(['u1'], { bots: 0 }).serialize();

  // Kill it.
  for (let i = 0; i < 200; i++) {
    const e = snake.restore(state);
    const sn = (e.serialize().snakes as any[])[0];
    e.applyInput('u1', { h: Math.atan2(sn.y, sn.x) || 0, boost: true });
    e.tick!();
    state = e.serialize();
    if (!(state.snakes as any[])[0].a) break;
  }

  // Wait out the delay, then ASK to respawn. Humans are no longer put back automatically —
  // being teleported into play unprompted meant a player never saw that they had died.
  for (let i = 0; i < Math.ceil(TUNING.RESPAWN_DELAY * TUNING.TICK_HZ) + 4; i++) {
    const e = snake.restore(state);
    e.tick!();
    state = e.serialize();
  }

  check('a dead human stays dead until it asks',
    (state.snakes as any[])[0].a === false);
  check('the client is told it may respawn',
    (state.snakes as any[])[0].cr === true);

  {
    const e = snake.restore(state);
    e.applyInput('u1', { respawn: true });
    e.tick!();
    state = e.serialize();
  }

  const sn = (state.snakes as any[])[0];
  check('snake respawns', sn.a === true);
  check('respawn is at starting mass, no catch-up bonus',
    Math.abs(sn.m - TUNING.START_MASS) < 0.01, `m=${sn.m}`);
  check('respawn is inside the arena',
    Math.hypot(sn.x, sn.y) < (state.arenaRadius as number));
}

// --- 8. Bots survive on their own ------------------------------------------------------
// The web build shipped a bug where 100% of deaths were border deaths because bots never
// evaluated in time. This is the regression guard for it.
{
  const { state } = runRoundTripped(TUNING.TICK_HZ * 25, ['u1'], 5);
  const bots = (state.snakes as any[]).filter((s) => s.bot);
  const totalDeaths = bots.reduce((a, s) => a + s.d, 0);
  const alive = bots.filter((s) => s.a).length;

  check('bots are mostly alive after 25s', alive >= 3, `${alive}/5 alive`);
  check('bots are not dying constantly', totalDeaths <= 6, `${totalDeaths} deaths in 25s`);
  check('bots grow by eating', bots.some((s) => s.m > TUNING.START_MASS + 2),
    `max mass ${Math.max(...bots.map((s) => s.m))}`);
}

// --- 9. The match ends ------------------------------------------------------------------
{
  let state = snake.create(['u1'], { bots: 2, seconds: 60 }).serialize();
  let outcome = null as any;

  for (let i = 0; i < TUNING.TICK_HZ * 65 && !outcome; i++) {
    const e = snake.restore(state);
    const r = e.tick!();
    state = e.serialize();
    if (r.outcome) outcome = r.outcome;
  }

  check('match finishes at its duration', outcome !== null);
  check('outcome scores only real players',
    outcome !== null && Object.keys(outcome.scores).length === 1
      && 'u1' in outcome.scores);
  check('engine reports finished', (state.finished as boolean) === true);
}

// --- 10. Food delta correctness ---------------------------------------------------------
// A client applying deltas must end up with exactly the server's food field. If this drifts,
// pellets appear that cannot be eaten, or eaten pellets linger — both look like desync.
{
  let state: GameStatePayload = snake.create(['u1'], { bots: 4, seed: 777 }).serialize();
  const client = new Map<number, [number, number, number]>();

  for (let i = 0; i < TUNING.TICK_HZ * 40; i++) {
    const e = snake.restore(state);
    e.tick!();
    state = e.serialize();
    const wire = e.serializeForWire!() as any;

    if (wire.foodFull) {
      client.clear();
      for (const [x, y, v, id] of wire.food) client.set(id, [x, y, v]);
    } else {
      for (const [x, y, v, id] of wire.foodAdd) client.set(id, [x, y, v]);
      for (const id of wire.foodDel) client.delete(id);
    }
  }

  const server = new Map<number, unknown>();
  for (const [x, y, v, id] of state.food as any[]) server.set(id, [x, y, v]);

  check('delta-applied food matches the server exactly',
    client.size === server.size && [...server.keys()].every((k) => client.has(k)),
    `client ${client.size} vs server ${server.size}`);
}

// --- 10b. Bot names ---------------------------------------------------------------------
{
  const state = snake.create(['u1'], { bots: 8, seed: 4242 }).serialize();
  const snakes = state.snakes as any[];
  const bots = snakes.filter((s) => s.bot);
  const human = snakes.find((s) => !s.bot);

  check('every bot has a name', bots.every((b) => typeof b.n === 'string' && b.n.length > 0));
  check('bot names are unique within a match',
    new Set(bots.map((b) => b.n)).size === bots.length);
  // Humans are named by the client from its own directory; a server-side name would be a
  // second source of truth that could disagree with it.
  check('humans carry no server name', human.n === null);

  // Same seed must give the same names, or a replayed match would not reproduce.
  const again = snake.create(['u1'], { bots: 8, seed: 4242 }).serialize();
  check('names are deterministic for a seed',
    JSON.stringify((again.snakes as any[]).map((s) => s.n)) ===
    JSON.stringify(snakes.map((s) => s.n)));
}

// --- 10b-2. Skins ------------------------------------------------------------------------
{
  const state = snake.create(['u1'], { bots: 6, seed: 31337, skin: 'frost' }).serialize();
  const snakes = state.snakes as any[];
  const bots = snakes.filter((s) => s.bot);

  check('the human wears the skin it asked for',
    snakes.find((s) => !s.bot).sk === 'frost');
  check('every bot has a skin', bots.every((b) => typeof b.sk === 'string'));
  check('bot skins vary', new Set(bots.map((b) => b.sk)).size > 1);

  // An unknown id must not be trusted through to clients that would not understand it.
  const bogus = snake.create(['u1'], { bots: 1, seed: 1, skin: 'not-a-skin' }).serialize();
  check('an unknown requested skin falls back rather than being echoed',
    (bogus.snakes as any[]).find((s) => !s.bot).sk === 'rainbow');

  // Skin rides full frames only; a delta frame omits it and the client carries it forward.
  let st: GameStatePayload = snake.create(['u1'], { bots: 3, seed: 7 }).serialize();
  let sawDelta = false;
  for (let i = 0; i < 30; i++) {
    const e = snake.restore(st);
    e.tick!();
    st = e.serialize();
    const wire = e.serializeForWire!() as any;
    if (!wire.foodFull) {
      sawDelta = true;
      check('a delta frame omits the skin', wire.snakes[0].sk === undefined);
      break;
    }
  }
  check('delta frames actually occur', sawDelta);
  check('skin survives the restore round-trip',
    (st.snakes as any[])[0].sk !== undefined);
}

// --- 10c. Mass-scaled radius --------------------------------------------------------------
// The drawn width comes from `hr`, so if this stops scaling the client silently goes back to
// a fixed-width snake whose hitbox no longer matches what is on screen.
{
  let state: GameStatePayload = snake.create(['u1'], { bots: 3, seed: 88 }).serialize();
  const startHr = (state.snakes as any[])[0].hr;

  // Run long enough for something to eat.
  for (let i = 0; i < TUNING.TICK_HZ * 45; i++) {
    const e = snake.restore(state);
    e.tick!();
    state = e.serialize();
  }

  const snakes = (state.snakes as any[]).filter((s) => s.a);
  const grown = snakes.find((s) => s.m > TUNING.START_MASS + 5);

  check('head radius is on the wire', typeof startHr === 'number' && startHr > 0);
  check('a grown snake is thicker than it started',
    grown !== undefined && grown.hr > startHr,
    grown ? `m=${grown.m} hr=${grown.hr} vs start ${startHr}` : 'nothing grew');
  check('thickness is capped',
    snakes.every((s) => s.hr <= startHr * 2.2 + 0.001),
    `max hr ${Math.max(...snakes.map((s) => s.hr))}`);
}

// --- 11. Wire size ----------------------------------------------------------------------
// This payload goes to every player 12x/sec. If it is fat, phones pay for it continuously —
// on mobile data, for the whole match.
{
  let state: GameStatePayload = snake.create(['u1', 'u2'], { bots: 4, seed: 999 }).serialize();
  let totalWire = 0;
  let frames = 0;
  let peak = 0;

  const TICKS = TUNING.TICK_HZ * 30;
  for (let i = 0; i < TICKS; i++) {
    const e = snake.restore(state);
    e.tick!();
    state = e.serialize();
    const bytes = JSON.stringify(e.serializeForWire!()).length;
    totalWire += bytes;
    if (bytes > peak) peak = bytes;
    frames++;
  }

  const avg = totalWire / frames;
  const perSec = (avg * TUNING.TICK_HZ) / 1024;
  console.log(`\n  wire frame: avg ${(avg / 1024).toFixed(1)} KB, peak ${(peak / 1024).toFixed(1)} KB`);
  console.log(`  bandwidth : ${perSec.toFixed(0)} KB/s per player at ${TUNING.TICK_HZ} Hz`);

  // 30 KB/s, raised from 25 alongside the speed increase user testing asked for.
  //
  // Faster snakes mean longer bodies on the wire and more food churn per second; the old
  // ceiling was set when the game was a third slower. 30 KB/s is still comfortably inside a
  // weak mobile connection (roughly a quarter of what a low-bitrate video call uses), and
  // holding the old number would have meant paying for it in gameplay — which is the wrong
  // trade when the testing feedback was specifically that the game felt sluggish.
  check('sustained bandwidth under 30 KB/s', perSec < 30, `${perSec.toFixed(0)} KB/s`);
}

console.log(failures === 0 ? '\nAll checks passed.\n' : `\n${failures} check(s) FAILED.\n`);
process.exit(failures === 0 ? 0 : 1);
