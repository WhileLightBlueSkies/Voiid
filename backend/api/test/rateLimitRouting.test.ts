import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import { redis, publisher } from '../src/redis';
import { pool } from '../src/db';
import { issueToken } from '../src/auth';

// Exercise the real application's mount order; only external dependencies are replaced.
test('ordinary reads do not spend creation limits and authenticated users have separate buckets', async () => {
  redis.disconnect(); publisher.disconnect();
  const counters = new Map<string, number>();
  const increment = (key: string) => { const n = (counters.get(key) ?? 0) + 1; counters.set(key, n); return n; };
  (redis as any).incr = async (key: string) => increment(key);
  (redis as any).expire = async () => 1;
  (redis as any).eval = async (_script: string, _keys: number, key: string) => [increment(key), 60000];
  (redis as any).get = async () => '1';
  (pool as any).query = async () => ({ rows: [], rowCount: 0 });
  let application: express.Express | undefined;
  const listen = express.application.listen;
  express.application.listen = function(this: express.Express) { application = this; return {} as any; } as any;
  try { await import('../src/index'); } finally { express.application.listen = listen; }
  assert.ok(application);
  const server = listen.call(application, 0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${(server.address() as any).port}/v1`;
  const alice = issueToken({ user_id: '00000000-0000-4000-8000-000000000001' });
  const bob = issueToken({ user_id: '00000000-0000-4000-8000-000000000002' });
  const request = (path: string, token?: string, method = 'GET') => fetch(base + path, { method, headers: token ? { Authorization: `Bearer ${token}` } : {} });
  try {
    for (let n = 0; n < 31; n++) assert.equal((await request('/communities/search?q=hello', alice)).status, 200);
    assert.equal([...counters.keys()].filter(k => k.includes('community-host-thread')).length, 0);
    for (let n = 0; n < 20; n++) assert.equal((await request('/communities/invalid/host-thread', alice, 'POST')).status, 400);
    assert.equal((await request('/communities/invalid/host-thread', alice, 'POST')).status, 429);
    assert.equal((await request('/communities/invalid/host-thread', bob, 'POST')).status, 400);
    // Anonymous floods still hit the global IP budget.
    counters.clear();
    for (let n = 0; n < 300; n++) await request('/missing');
    assert.equal((await request('/missing')).status, 429);
  } finally { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); await pool.end(); }
});

test('rejection floods never write per-request SQL and include retry timing', async () => {
  const { rateLimit, checkPairRateLimit } = await import('../src/security');
  let sqlWrites = 0;
  (pool as any).query = async () => { sqlWrites++; return { rows: [] }; };
  (redis as any).incr = async () => 100;
  (redis as any).eval = async () => [100, 1234];
  let status = 200;
  const headers = new Map<string, string>();
  const res: any = { status(n: number) { status = n; return this; }, setHeader(k: string, v: string) { headers.set(k, v); }, json() { return this; } };
  const limit = rateLimit({ max: 1, windowSeconds: 60, bucket: 'test' });
  for (let n = 0; n < 100; n++) await limit({ ip: '127.0.0.1' } as any, res, () => assert.fail('must reject'));
  assert.equal(status, 429);
  assert.equal(headers.get('Retry-After'), '2');
  assert.equal(sqlWrites, 0);
  (redis as any).eval = async () => { throw new Error('Redis unavailable'); };
  (redis as any).incr = async () => { throw new Error('Redis unavailable'); };
  assert.equal(await checkPairRateLimit({ max: 5, windowSeconds: 60, bucket: 'keyfetch', callerId: 'a', targetId: 'b' }), false, 'key depletion fails closed');
});
