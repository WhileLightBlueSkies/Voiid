// S04 — the half of recovery the server can actually enforce.
// RECOVERY_TEST_DATABASE_URL=postgres://.../voiid_test_recovery npx tsx --test test/recoveryMeteringPostgres.test.ts
//
// Its own database: every DB-backed suite replays the migration set and
// `create extension` is database-scoped, so two of them in one database race.
//
// WHAT THIS DOES NOT TEST, stated first so nobody mistakes a green run for
// assurance: nothing here establishes any resistance to offline PIN guessing. That
// is S04's actual subject and it needs a reviewed protocol and a cryptographic
// reviewer, neither of which a test file can supply. These tests cover exactly two
// code-level claims — that the client-reported counter cannot be raced into losing
// failures, and that the envelope fetch (the one unforgeable signal) is counted and
// bounded server-side.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';
import express from 'express';

process.env.NODE_ENV = 'test';

import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { issueToken } from '../src/auth';
import recoveryRouter from '../src/routes/recovery';

redis.disconnect();
publisher.disconnect();
const url = process.env.RECOVERY_TEST_DATABASE_URL;

test('recovery metering against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  const schema = `recovery_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db);
  (pool as any).connect = db.connect.bind(db);

  const app = express();
  app.use(express.json());
  app.use('/recovery', recoveryRouter);
  app.use((_e: unknown, _req: any, res: any, _next: any) => res.status(500).json({ error: 'test failure' }));
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>((done) => server.once('listening', () => done()));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;

  const user = randomUUID();
  const device = randomUUID();
  const auth = () => ({ authorization: `Bearer ${issueToken({ user_id: user, device_id: device })}` });

  const envelope = { version: 1, salt: 'c2FsdA==', nonce: 'bm9uY2U=', ciphertext: 'Y2lwaGVy' };

  async function putKey() {
    return fetch(`${base}/recovery/key`, {
      method: 'PUT', headers: { ...auth(), 'content-type': 'application/json' },
      body: JSON.stringify(envelope),
    });
  }
  const getKey = () => fetch(`${base}/recovery/key`, { headers: auth() });
  const report = (success: boolean) =>
    fetch(`${base}/recovery/attempt-result`, {
      method: 'POST', headers: { ...auth(), 'content-type': 'application/json' },
      body: JSON.stringify({ success }),
    });
  const state = async () =>
    (await db.query('select failed_attempts, locked_until, fetch_count, last_fetched_at from recovery_keys where user_id=$1', [user])).rows[0];

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    await db.query('insert into users(id, phone_number) values($1,$2)', [user, '+19990040001']);
    await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
      values($1,$2,'test',1,$3)`, [device, user, Buffer.from('key')]);

    assert.equal((await putKey()).status, 200);

    await t.test('concurrent failure reports cannot lose an increment', async () => {
      await db.query('update recovery_keys set failed_attempts=0, locked_until=null where user_id=$1', [user]);
      // Select-then-update loses increments under READ COMMITTED: both requests read
      // the same value and both write the same n+1. Fire enough of them at once that
      // a lost update is overwhelmingly likely if the read and write are separate.
      const N = 8;
      await Promise.all(Array.from({ length: N }, () => report(false)));
      const after = await state();
      assert.equal(
        Number(after.failed_attempts), N,
        `${N} failures were reported but the counter reached ${after.failed_attempts} — ` +
          `concurrent reports overwrote each other, so an attacker can hold the counter down ` +
          `by reporting failures in parallel`
      );
    });

    await t.test('storing a new wrap resets the counter and the fetch meter', async () => {
      assert.equal((await putKey()).status, 200);
      const after = await state();
      assert.equal(Number(after.failed_attempts), 0);
      assert.equal(Number(after.fetch_count), 0, 'a genuine recovery must clear the fetch meter');
      assert.equal(after.locked_until, null);
    });

    await t.test('every envelope fetch is counted server-side', async () => {
      await db.query('update recovery_keys set fetch_count=0, last_fetched_at=null where user_id=$1', [user]);
      for (let i = 1; i <= 3; i++) {
        assert.equal((await getKey()).status, 200);
        assert.equal(
          Number((await state()).fetch_count), i,
          'the fetch is the only signal the client cannot forge; it must not be missed'
        );
      }
      assert.ok((await state()).last_fetched_at, 'last_fetched_at was never recorded');
    });

    await t.test('harvesting the envelope is bounded, and the bound is server-side', async () => {
      // Past the limit the server refuses, regardless of what the client reports about
      // its attempts — this is the one control an offline attacker cannot decline.
      await db.query('update recovery_keys set fetch_count=1000 where user_id=$1', [user]);
      const res = await getKey();
      assert.equal(res.status, 429, 'unbounded fetches let a stolen token harvest freely');
      assert.ok(res.headers.get('retry-after'), 'a 429 must say when to come back');
      const body: any = await res.json();
      assert.match(body.error, /fetch/i);
    });

    await t.test('a refused fetch is counted, but cannot push the window forward', async () => {
      // An attacker hammering into a refusal is exactly the behaviour worth seeing, so the
      // refusal still counts. It is CAPPED at the limit + 1 rather than climbing forever:
      // an unbounded counter, paired with a last_fetched_at that every refused request
      // refreshed, meant the cooldown window could never expire and an honest user's own
      // recovery key became permanently unfetchable.
      await db.query('update recovery_keys set fetch_count=1000 where user_id=$1', [user]);
      await getKey();
      const after = await state();
      assert.equal(Number(after.fetch_count), 26, 'the counter is bounded at the limit + 1');

      // The load-bearing half: a blocked retry must not extend its own lockout.
      const frozen = after.last_fetched_at;
      await getKey();
      assert.equal(+(await state()).last_fetched_at, +frozen,
        'a refused retry that moves last_fetched_at makes the cooldown unexpirable');
    });

    await t.test('an honest client is not locked out of its own recovery', async () => {
      await db.query('update recovery_keys set fetch_count=0, locked_until=null where user_id=$1', [user]);
      for (let i = 0; i < 20; i++) {
        assert.equal((await getKey()).status, 200, `a legitimate retry was refused at fetch ${i + 1}`);
      }
    });

    // The claim the code must NOT make. This is a regression guard on the honesty of
    // the documentation, because the false claim is what made the defect dangerous.
    await t.test('the code does not claim client reports are a security boundary', async () => {
      const src = await readFile(resolve(root, 'backend/api/src/routes/recovery.ts'), 'utf8');
      assert.match(
        src, /THREAT MODEL/,
        'the threat model must be stated in the file people edit'
      );
      for (const claim of [
        /SERVER-SIDE guess limiting/,
      ]) {
        assert.ok(
          !claim.test(src.replace(/THAT CLAIM WAS FALSE[\s\S]*$/, '')),
          `recovery.ts still asserts ${claim} ahead of the correction — the counter is ` +
            `client-reported and the client is the attacker`
        );
      }
    });
  } finally {
    await new Promise<void>((done, fail) => server.close((e) => (e ? fail(e) : done())));
    (pool as any).query = originalQuery;
    (pool as any).connect = originalConnect;
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
  }
});
