// S06 — linking a companion device, once, to one account.
// LINKING_TEST_DATABASE_URL=postgres://.../voiid_test_linking npx tsx --test test/linkingPostgres.test.ts
//
// Its own database: every DB-backed suite replays the migration set and `create extension` is
// database-scoped, so two of them in one database race.
//
// THE RACES. Approval read the pending state, created a device, then wrote the result back —
// three separate steps over a cache. Two approvals from different accounts could both read
// "pending", both register a device, and both write: one account ends up holding a device row
// nobody will ever use, and which of the two the waiting browser is handed is decided by
// whichever write landed last. Polling was the same shape: read, check, delete, so two polls
// could both be handed the credential. And a crash between the device insert and the cache
// write left a registered device with a link token stuck on "pending" forever.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';
import express from 'express';

process.env.NODE_ENV = 'test';
process.env.VOIID_WEB_LINKING_ENABLED = '1';

import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { issueToken } from '../src/auth';
import linkingRouter from '../src/routes/linking';

redis.disconnect();
publisher.disconnect();
const url = process.env.LINKING_TEST_DATABASE_URL;

test('device linking against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `linking_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db);
  (pool as any).connect = db.connect.bind(db);

  const app = express();
  app.use(express.json());
  app.use('/linking', linkingRouter);
  app.use((_e: unknown, _req: any, res: any, _next: any) => res.status(500).json({ error: 'test failure' }));
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>((done) => server.once('listening', () => done()));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;

  const ana = randomUUID(), ben = randomUUID();
  const anaDev = randomUUID(), benDev = randomUUID();
  const proofs = new Map<string, string>();
  const keys = new Map<string, string>();
  // Limiter behavior is covered separately; these tests exercise real SQL transactions.
  const originalEval = redis.eval;
  (redis as any).eval = async () => [1, 300000];
  let seed = 5000;

  async function call(method: string, path: string, user?: string, body?: any, headers: Record<string, string> = {}) {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: {
        'content-type': 'application/json', ...headers,
        ...(user ? { authorization: `Bearer ${issueToken({ user_id: user, device_id: user === ben ? benDev : anaDev })}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: res.status, body: await res.json().catch(() => ({})) as any };
  }
  const request = async (overrides: any = {}) => {
    const key = randomBytes(32).toString('base64');
    const result = await call('POST', '/linking/request', undefined, {
      platform: 'web', registration_id: ++seed, identity_public_key: key, ...overrides,
    });
    proofs.set(result.body.link_token, result.body.poll_secret);
    keys.set(result.body.link_token, overrides.identity_public_key || key);
    return result;
  };
  const approve = (token: string, user = ana) => call('POST', '/linking/approve', user, { link_token: token, identity_public_key: keys.get(token) });
  const poll = (token: string, secret = proofs.get(token) || randomBytes(32).toString('base64url')) => call('GET', `/linking/poll/${token}`, undefined, undefined, { 'X-Link-Proof': secret });
  const deviceCount = async () =>
    Number((await db.query('select count(*)::int as n from devices')).rows[0].n);

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    for (const [i, id] of [ana, ben].entries()) {
      await db.query('insert into users(id, phone_number) values($1,$2)', [id, `+1999000900${i}`]);
    }
    await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
      values($1,$2,'ios',1,$3)`, [anaDev, ana, randomBytes(32)]);
    await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key) values($1,$2,'android',1,$3)`, [benDev, ben, randomBytes(32)]);

    await t.test('new linking is disabled until deployment explicitly enables it', async () => {
      delete process.env.VOIID_WEB_LINKING_ENABLED;
      try { assert.equal((await request()).status, 503); }
      finally { process.env.VOIID_WEB_LINKING_ENABLED = '1'; }
    });

    await t.test('the happy path: request, approve, collect the credential once', async () => {
      const { body: made } = await request();
      assert.ok(made.link_token);
      assert.equal((await poll(made.link_token)).body.status, 'pending');

      const approved = await approve(made.link_token);
      assert.equal(approved.status, 200, JSON.stringify(approved.body));

      const collected = await poll(made.link_token);
      assert.equal(collected.body.status, 'approved');
      assert.ok(collected.body.token, 'the companion gets its session token');
      assert.equal(collected.body.user_id, ana);
      assert.equal(collected.body.device_id, approved.body.device_id);
    });

    await t.test('the QR token alone and a wrong proof cannot steal or consume a session', async () => {
      const { body: made } = await request();
      await approve(made.link_token);
      assert.equal((await call('GET', `/linking/poll/${made.link_token}`)).status, 404);
      assert.equal((await poll(made.link_token, randomBytes(32).toString('base64url'))).status, 404);
      assert.equal((await poll(made.link_token)).body.status, 'approved');
    });
    await t.test('preview grants nothing and approval binds the previewed public key', async () => {
      const { body: made } = await request();
      const preview = await call('POST', '/linking/preview', ana, { link_token: made.link_token });
      assert.equal(preview.status, 200);
      assert.equal(preview.body.identity_public_key, keys.get(made.link_token));
      assert.match(preview.body.verification_code, /^[0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4}$/);
      assert.equal(preview.body.poll_secret, undefined);
      assert.equal((await poll(made.link_token)).body.status, 'pending');
      assert.equal((await call('POST', '/linking/approve', ana, { link_token: made.link_token, identity_public_key: randomBytes(32).toString('base64') })).status, 409);
      assert.equal((await approve(made.link_token)).status, 200);
    });
    await t.test('invalid platform and malformed identity cannot create a link', async () => {
      assert.equal((await request({ platform: 'ios' })).status, 400);
      assert.equal((await request({ identity_public_key: 'abcd' })).status, 400);
      assert.equal((await request({ registration_id: 1.5 })).status, 400);
    });
    await t.test('a registration collision cannot overwrite or un-revoke a phone', async () => {
      const before = (await db.query('select identity_public_key from devices where id=$1', [anaDev])).rows[0].identity_public_key;
      const { body: made } = await request({ registration_id: 1 });
      assert.equal((await approve(made.link_token)).status, 409);
      assert.deepEqual((await db.query('select identity_public_key from devices where id=$1', [anaDev])).rows[0].identity_public_key, before);
    });
    await t.test('a device with a legacy web token still cannot approve another browser', async () => {
      const { body: first } = await request();
      const approved = await approve(first.link_token);
      const { body: next } = await request();
      const token = issueToken({ user_id: ana, device_id: approved.body.device_id });
      for (const route of ['preview', 'approve']) {
        const result = await call('POST', `/linking/${route}`, undefined, { link_token: next.link_token, identity_public_key: keys.get(next.link_token) }, { authorization: `Bearer ${token}` });
        assert.equal(result.status, 403);
      }
    });

    await t.test('a signed browser capability cannot preview or approve links', async () => {
      const { body: first } = await request(); await approve(first.link_token);
      const collected = await poll(first.link_token);
      const { body: next } = await request();
      for (const route of ['preview', 'approve']) {
        const response = await call('POST', `/linking/${route}`, undefined, { link_token: next.link_token, identity_public_key: keys.get(next.link_token) }, { authorization: `Bearer ${collected.body.token}` });
        assert.equal(response.status, 403);
        assert.equal(response.body.code, 'companion_scope');
      }
    });
    await t.test('simultaneous redemption gives the credential to only one request', async () => {
      const { body: made } = await request(); await approve(made.link_token);
      const results = await Promise.all([poll(made.link_token), poll(made.link_token)]);
      assert.deepEqual(results.map(r => r.status).sort(), [200, 404]);
    });

    await t.test('the credential is handed over exactly once', async () => {
      const { body: made } = await request();
      await approve(made.link_token);
      const first = await poll(made.link_token);
      assert.equal(first.body.status, 'approved');
      // A second poll — a retry, a duplicate tab, an attacker who learned the token — must
      // find nothing. Read-check-delete could hand the same credential to both.
      const second = await poll(made.link_token);
      assert.equal(second.status, 404, 'the token was still redeemable after being redeemed');
    });

    await t.test('two accounts approving at once produce one owner and one device', async () => {
      const before = await deviceCount();
      const { body: made } = await request();

      // FORCED OVERLAP, not hoped-for overlap. Firing four requests and trusting them to
      // interleave is a coin toss — the first version of this test passed against a build with
      // the row lock removed. A blocker transaction holds the row so both approvals are
      // provably in flight at once: with `for update` they queue behind it and the second finds
      // the request already approved; without it they sail past and both approve.
      const blocker = await db.connect();
      let results: Awaited<ReturnType<typeof approve>>[];
      try {
        await blocker.query('begin');
        await blocker.query('select 1 from device_link_requests where token=$1 for update', [made.link_token]);

        const inFlight = Promise.all([approve(made.link_token, ana), approve(made.link_token, ben)]);

        // Wait for a real lock wait rather than assuming HTTP has reached the database.
        const deadline = Date.now() + 3000;
        let waiting = false;
        while (Date.now() < deadline) {
          const { rows } = await db.query(`select 1 from pg_stat_activity
            where datname = current_database() and wait_event_type = 'Lock'
              and query like '%device_link_requests%'`);
          if (rows.length) { waiting = true; break; }
          await new Promise((r) => setTimeout(r, 10));
        }
        assert.ok(waiting, 'neither approval took the row lock — the test proves nothing');
        await blocker.query('commit');
        results = await inFlight;
      } finally {
        await blocker.query('rollback').catch(() => {});
        blocker.release();
      }

      const winners = results.filter((r) => r.status === 200);
      assert.equal(winners.length, 1, `${winners.length} approvals succeeded, not 1`);
      assert.equal(
        await deviceCount(), before + 1,
        'a losing approval registered a device under an account that will never use it'
      );
      const collected = await poll(made.link_token);
      assert.equal(collected.body.device_id, winners[0].body.device_id, 'the browser got the winner');
    });

    await t.test('a used token cannot be approved again by anyone', async () => {
      const { body: made } = await request();
      assert.equal((await approve(made.link_token, ana)).status, 200);
      assert.equal((await approve(made.link_token, ben)).status, 409, 'a second account took it over');
      assert.equal((await approve(made.link_token, ana)).status, 409);
    });

    await t.test('an expired request approves nothing', async () => {
      const { body: made } = await request();
      await db.query(`update device_link_requests set expires_at = now() - interval '1 minute'
                       where token = $1`, [made.link_token]);
      assert.equal((await approve(made.link_token)).status, 404);
      assert.equal((await poll(made.link_token)).status, 404);
    });

    await t.test('an unknown token is refused without saying whether it ever existed', async () => {
      assert.equal((await approve('never-issued')).status, 404);
      assert.equal((await poll('never-issued')).status, 404);
    });

    await t.test('approval is one transaction, so a failure leaves no half-linked device', async () => {
      const before = await deviceCount();
      const { body: made } = await request();
      await db.query(`create function fail_session() returns trigger language plpgsql as $$
        begin raise exception 'injected session failure'; end $$`);
      await db.query(`create trigger fail_session before insert on device_sessions
        for each row execute function fail_session()`);
      try {
        assert.equal((await approve(made.link_token)).status, 500);
        assert.equal(await deviceCount(), before, 'a device was registered for a link that failed');
        const state = await db.query('select status from device_link_requests where token=$1', [made.link_token]);
        assert.equal(state.rows[0].status, 'pending', 'the request must still be approvable');
      } finally {
        await db.query('drop trigger fail_session on device_sessions');
        await db.query('drop function fail_session()');
      }
      // ...and the retry works, which is what "recoverable" has to mean.
      assert.equal((await approve(made.link_token)).status, 200);
      assert.equal(await deviceCount(), before + 1);
    });

    await t.test('linking state survives a cache being wiped', async () => {
      // The whole point of moving this off Redis: a flush used to strand every in-flight link.
      const { body: made } = await request();
      await approve(made.link_token);
      const rows = await db.query('select status from device_link_requests where token=$1', [made.link_token]);
      assert.equal(rows.rows[0].status, 'approved', 'the state is durable, not cached');
    });
  } finally {
    await new Promise<void>((done, fail) => server.close((e) => (e ? fail(e) : done())));
    (redis as any).eval = originalEval;
    (pool as any).query = originalQuery;
    (pool as any).connect = originalConnect;
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
  }
});
