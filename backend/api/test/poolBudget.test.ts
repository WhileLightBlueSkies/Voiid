// P04 — every service declares what it may consume, instead of inheriting a default.
//
// WHAT WAS UNBOUNDED. The API and games pools took node-postgres defaults: `max: 10` per
// process with NO connection-acquisition timeout and NO statement timeout. Three consequences,
// all of which only appear under the load nobody has run yet:
//
//   * A slow query holds a connection until it finishes. With no statement timeout there is no
//     "until" — one pathological query can hold a connection for the life of the process.
//   * With no acquisition timeout, a request that cannot get a connection waits forever rather
//     than failing. Under saturation the queue grows without limit and every waiting request
//     holds its socket, its memory and its client's patience.
//   * Supabase enforces a connection ceiling across the WHOLE deployment. Four processes each
//     claiming an unstated share is how the fifth one cannot connect at all, and the fix
//     ("choose final pool sizes from measurements") starts with the sizes being stated
//     somewhere they can be measured against.
//
// These are budgets, not tuning. The numbers are argued from the ceiling and the workload
// shape; P04 explicitly asks that final sizes come from measurement, and that measurement has
// NOT been done — see the completion record.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { poolBudget, describePoolBudget } from '@voiid/common-utils';

process.env.NODE_ENV = 'test';
// Importing the redis module opens real connections. The fan-out tests below need the module
// (they swap `publisher.publish`), so drop the sockets immediately or the process never exits.
import { redis, publisher } from '../src/redis';
redis.disconnect();
publisher.disconnect();

test('every budget bounds acquisition, statements and size', () => {
  for (const service of ['api', 'games', 'workers', 'websocket'] as const) {
    const b = poolBudget(service, {});
    assert.ok(b.max >= 1, `${service} has no pool ceiling`);
    assert.ok(b.connectionTimeoutMillis > 0, `${service} would wait forever for a connection`);
    assert.ok(b.statement_timeout > 0, `${service} would let one query hold a connection forever`);
    assert.ok(
      b.idleTimeoutMillis > 0,
      `${service} would hold idle connections against the deployment ceiling indefinitely`
    );
  }
});

test('the declared budgets fit inside the deployment connection ceiling', () => {
  const total = (['api', 'games', 'workers', 'websocket'] as const)
    .reduce((n, s) => n + poolBudget(s, {}).max, 0);
  // Supabase's smallest paid tier allows 60 direct connections; the pooler allows more but is
  // not what a direct DATABASE_URL uses. Leaving headroom for migrations, psql and a deploy
  // running alongside the services is the point of stating this at all.
  assert.ok(total <= 40, `the four services claim ${total} connections between them`);
});

test('the relay and the workers stay deliberately small', () => {
  // The relay asks one question per socket connect; the workers run one low-frequency job at a
  // time. Both were already capped on purpose and that intent must survive this change.
  assert.ok(poolBudget('websocket', {}).max <= 4, 'the relay does not need a large pool');
  assert.ok(poolBudget('workers', {}).max <= 4, 'the reaper must never starve the API');
});

test('a budget can be overridden per deployment, and a bad value is ignored', () => {
  assert.equal(poolBudget('api', { VOIID_API_POOL_MAX: '12' }).max, 12);
  for (const bad of ['0', '-3', 'lots', '']) {
    assert.equal(
      poolBudget('api', { VOIID_API_POOL_MAX: bad }).max, poolBudget('api', {}).max,
      `VOIID_API_POOL_MAX=${JSON.stringify(bad)} was accepted`
    );
  }
});

test('the statement timeout is expressed to Postgres, not just to node', () => {
  // `statement_timeout` is a server-side setting. A client-side deadline alone leaves the query
  // running on the database after the caller has given up, which is the expensive half.
  const b = poolBudget('api', {});
  assert.equal(typeof b.statement_timeout, 'number');
  assert.ok(b.statement_timeout <= 30_000, 'a 30s+ statement is a bug, not a slow query');
});

test('the budget is describable, so an operator sees it at boot', () => {
  const line = describePoolBudget('api', poolBudget('api', {}));
  assert.match(line, /api/);
  assert.match(line, /\d+/);
});

// The guard: a service that stops declaring its budget is the failure returning.
//
// This asserts the budget REACHES the Pool, not that the word `poolBudget` appears somewhere in
// the file. The first version of this test only did the latter — and when the anti-vacuity check
// deleted the `...budget` spread from the relay, leaving the now-unused call above it, the test
// still passed. That is exactly the defect Q03's guard had: matching a helper's name rather than
// the property the helper is supposed to produce.
test('no service builds a Pool without a declared budget', async () => {
  const root = resolve(__dirname, '../../..');
  for (const file of [
    'backend/api/src/db.ts',
    'backend/games/src/db.ts',
    'backend/workers/src/db.ts',
    'backend/websocket/src/session.ts',
  ]) {
    const source = (await readFile(resolve(root, file), 'utf8'))
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');

    const budgetVar = /(?:const|let)\s+(\w+)\s*=\s*poolBudget\(/.exec(source);
    assert.ok(
      budgetVar,
      `${file} constructs a Pool without going through the shared budget — defaults mean no ` +
        `acquisition timeout, no statement timeout, and an unstated share of the connection ceiling`
    );

    // Every `new Pool({ ... })` in the file must spread that budget into its options.
    const constructions = [...source.matchAll(/new Pool\(\s*\{/g)];
    assert.ok(constructions.length > 0, `${file} no longer constructs a Pool — update this guard`);
    for (const at of constructions) {
      // Walk to the matching brace so a second Pool later in the file cannot satisfy the first.
      let depth = 0, end = at.index! + at[0].length - 1;
      for (let i = end; i < source.length; i++) {
        if (source[i] === '{') depth++;
        else if (source[i] === '}' && --depth === 0) { end = i; break; }
      }
      const options = source.slice(at.index!, end);
      assert.ok(
        new RegExp(`\\.\\.\\.${budgetVar[1]}\\b`).test(options),
        `${file} builds a Pool that does not spread \`...${budgetVar[1]}\` — the budget is ` +
          `computed and then thrown away, so the pool silently takes node-postgres defaults`
      );
    }
  }
});

// ── The other half of P04: the request path's own fan-out ─────────────────────
//
// `publishOutbox` runs while the sender waits. It awaited each publish in turn, so a group send
// paid one Redis round-trip PER RECIPIENT: 50 members meant 50 sequential RTTs added to the
// sender's latency. The fix is bounded parallelism — and `Promise.all` over the whole set is not
// the fix, because it hands Redis an unbounded burst from every concurrent send at once.
test('fan-out publishes in parallel, and never unboundedly', async () => {
  const { publishOutbox } = await import('../src/messageOutbox');
  const realPublish = publisher.publish;

  let live = 0, peak = 0;
  publisher.publish = async () => {
    peak = Math.max(peak, ++live);
    // A round trip has to actually take time, or nothing can overlap and any implementation
    // "passes". This is the whole reason the test is not instantaneous.
    await new Promise((r) => setTimeout(r, 20));
    live--;
    return 1;
  };

  const settled: string[] = [];
  const execute = async (_sql: string, params: any[]) => { settled.push(...params[0]); return []; };
  const entries = Array.from({ length: 50 }, (_, i) => ({
    id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
    channel: `user:${i}`,
    payload: { n: i },
  }));

  const started = Date.now();
  try {
    await publishOutbox(execute, entries);
  } finally {
    publisher.publish = realPublish;
  }
  const elapsed = Date.now() - started;

  assert.equal(settled.length, 50, 'every wake must still be settled exactly once');
  assert.equal(new Set(settled).size, 50, 'a wake was settled twice');

  // Sequential would be 50 × 20ms = 1000ms. Anything near that is the defect.
  assert.ok(
    elapsed < 600,
    `fan-out took ${elapsed}ms for 50 recipients — that is one Redis round-trip per recipient ` +
      `on the sender's request path`
  );
  // ...and it must not simply have fired all 50 at once.
  assert.ok(peak > 1, 'fan-out is still sequential');
  assert.ok(
    peak <= 8,
    `${peak} publishes were in flight at once — an unbounded burst per send is how a Redis ` +
      `recovery becomes the next outage`
  );
});

test('a fan-out to a single recipient still works', async () => {
  const { publishOutbox } = await import('../src/messageOutbox');
  const realPublish = publisher.publish;
  publisher.publish = async () => 1;
  const settled: string[] = [];
  try {
    await publishOutbox(async (_s: string, p: any[]) => { settled.push(...p[0]); return []; },
      [{ id: '00000000-0000-4000-8000-000000000001', channel: 'user:1', payload: {} }]);
  } finally {
    publisher.publish = realPublish;
  }
  assert.deepEqual(settled, ['00000000-0000-4000-8000-000000000001']);
});

test('a publish failure leaves that wake owed, and does not stop the others', async () => {
  const { publishOutbox } = await import('../src/messageOutbox');
  const realPublish = publisher.publish;
  publisher.publish = async (channel: string) => {
    if (channel === 'user:3') throw new Error('redis is unhappy');
    return 1;
  };
  const settled: string[] = [];
  const entries = Array.from({ length: 10 }, (_, i) => ({
    id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
    channel: `user:${i}`, payload: {},
  }));
  try {
    await publishOutbox(async (_s: string, p: any[]) => { settled.push(...p[0]); return []; }, entries);
  } finally {
    publisher.publish = realPublish;
  }
  assert.equal(settled.length, 9, 'one failure must not settle, nor abort the rest of the fan-out');
  assert.ok(!settled.includes(entries[3].id), 'a wake that was never published was marked published');
});
