// V PIN against a real PostgreSQL — the claims that only hold with a database underneath:
// the lock is enforced server-side, cannot be raced, cannot be cleared by the legacy routes,
// and the envelope is never handed out without the right PIN.
//
// VPIN_TEST_DATABASE_URL=postgres://.../voiid_test_vpin npx tsx --test test/vpinPostgres.test.ts
// Its own database, for the same reason as recoveryMeteringPostgres.test.ts.
import test from 'node:test';
import assert from 'node:assert/strict';
import { pbkdf2Sync, randomBytes, randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';
import express from 'express';

process.env.NODE_ENV = 'test';
process.env.VOIID_SECRETBOX_KEY = randomBytes(32).toString('base64');

import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { issueToken } from '../src/auth';
import recoveryRouter from '../src/routes/recovery';
import { resetSecretboxKeyForTests } from '../src/secretbox';
import { PROOF_BYTES, PROOF_ITERATIONS, PROOF_SALT_PREFIX } from '../src/vpin';

resetSecretboxKeyForTests();
redis.disconnect();
publisher.disconnect();
const url = process.env.VPIN_TEST_DATABASE_URL;

const proofOf = (pin: string, salt: Buffer) =>
  pbkdf2Sync(Buffer.from(pin, 'utf8'), Buffer.concat([Buffer.from(PROOF_SALT_PREFIX), salt]),
    PROOF_ITERATIONS, PROOF_BYTES, 'sha256').toString('base64');

test('V PIN against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname), 'never run this against a shared database');
  const schema = `vpin_test_${randomUUID().replaceAll('-', '')}`;
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
  const headers = () => ({
    authorization: `Bearer ${issueToken({ user_id: user, device_id: device })}`,
    'content-type': 'application/json',
  });
  const envelope = { version: 1, salt: 'c2FsdA==', nonce: 'bm9uY2U=', ciphertext: 'Y2lwaGVy' };
  const salt = randomBytes(16);
  const PIN = '24681357';

  const setPin = (pin = PIN) => fetch(`${base}/recovery/pin`, {
    method: 'PUT', headers: headers(),
    body: JSON.stringify({ wrapped_key: envelope, auth_salt: salt.toString('base64'), proof: proofOf(pin, salt) }),
  });
  const unlock = (pin: string) => fetch(`${base}/recovery/pin/unlock`, {
    method: 'POST', headers: headers(), body: JSON.stringify({ proof: proofOf(pin, salt) }),
  });
  const status = async () => (await fetch(`${base}/recovery/status`, { headers: headers() })).json();
  const row = async () => (await db.query(
    'select pin_version, wrapped_key, pin_verifier, sealed_envelope, failed_attempts, locked_until from recovery_keys where user_id=$1',
    [user])).rows[0];
  const clearLock = () => db.query('update recovery_keys set failed_attempts=0, locked_until=null where user_id=$1', [user]);

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    // 096 must be re-runnable, like every migration.
    await db.query(await readFile(resolve(root, 'database/migrations/096_recovery_vpin.sql'), 'utf8'));
    await db.query('insert into users(id, phone_number) values($1,$2)', [user, '+19990096001']);
    await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
      values($1,$2,'test',1,$3)`, [device, user, Buffer.from('key')]);

    await t.test('setting a V PIN stores no PIN, no proof and no readable envelope', async () => {
      assert.equal((await setPin()).status, 200);
      const r = await row();
      assert.equal(r.pin_version, 2);
      assert.equal(r.wrapped_key, null, 'the client-readable column must stay empty');
      assert.ok(!r.pin_verifier.includes(proofOf(PIN, salt)), 'the verifier is not the proof');
      assert.ok(!JSON.stringify(r).includes('Y2lwaGVy'), 'the envelope is sealed, not stored in the clear');
      const s = await status();
      assert.equal(s.has_pin_wrap, false, 'an old app must not offer its legacy PIN flow');
      assert.equal(s.vpin.attempts_left, 5);
      assert.equal(s.vpin.auth_salt, salt.toString('base64'));
    });

    await t.test('the right PIN releases the envelope', async () => {
      const res = await unlock(PIN);
      assert.equal(res.status, 200);
      assert.deepEqual((await res.json()).wrapped_key, envelope);
    });

    await t.test('wrong PINs count down, and the 5th locks for 24 hours', async () => {
      await clearLock();
      for (let left = 4; left >= 1; left--) {
        const res = await unlock('11112222');
        assert.equal(res.status, 401);
        assert.equal((await res.json()).attempts_left, left);
      }
      const fifth = await unlock('11112222');
      assert.equal(fifth.status, 429);
      const body = await fifth.json();
      assert.equal(body.code, 'vpin_locked');
      assert.equal(body.just_locked, true);
      const hours = (new Date(body.locked_until).getTime() - Date.now()) / 3_600_000;
      assert.ok(hours > 23.9 && hours <= 24, `lock should be 24h, got ${hours.toFixed(2)}h`);
    });

    await t.test('while locked, even the RIGHT PIN is refused', async () => {
      const res = await unlock(PIN);
      assert.equal(res.status, 429, 'a lock that the right answer skips is only a delay');
      const s = await status();
      assert.equal(s.vpin.attempts_left, 0);
      assert.ok(s.vpin.retry_after > 0);
    });

    await t.test('the legacy routes cannot clear the lock or hand out the envelope', async () => {
      const report = await fetch(`${base}/recovery/attempt-result`, {
        method: 'POST', headers: headers(), body: JSON.stringify({ success: true }),
      });
      assert.equal(report.status, 409, 'a client-reported "success" must not touch a V PIN');
      assert.ok((await row()).locked_until, 'the lock must survive a reported success');

      const legacyFetch = await fetch(`${base}/recovery/key`, { headers: headers() });
      assert.equal(legacyFetch.status, 409);
      assert.equal((await legacyFetch.json()).code, 'vpin_required');
    });

    await t.test('after the lock expires there are 5 fresh attempts, and the right PIN works', async () => {
      await db.query(`update recovery_keys set locked_until = now() - interval '1 second' where user_id=$1`, [user]);
      assert.equal((await status()).vpin.attempts_left, 5);
      assert.equal((await unlock(PIN)).status, 200);
    });

    await t.test('parallel wrong guesses cannot share an attempt', async () => {
      await clearLock();
      // Ten at once. Without the row lock several would read "0 wrong" and each write 1,
      // turning 10 guesses into far more than 5. With it: 4 × 401, then locks.
      const results = await Promise.all(Array.from({ length: 10 }, () => unlock('99998888')));
      const statuses = results.map((r) => r.status);
      assert.equal(statuses.filter((s) => s === 401).length, 4,
        `expected exactly 4 counted wrong answers before the lock, got ${JSON.stringify(statuses)}`);
      assert.equal(statuses.filter((s) => s === 429).length, 6);
      assert.ok((await row()).locked_until, 'ten parallel guesses must end locked');
    });

    await t.test('a correct PIN resets the count', async () => {
      await clearLock();
      assert.equal((await unlock('11112222')).status, 401);
      assert.equal((await unlock(PIN)).status, 200);
      assert.equal(Number((await row()).failed_attempts), 0);
    });

    await t.test('a malformed proof is refused without costing an attempt', async () => {
      await clearLock();
      const res = await fetch(`${base}/recovery/pin/unlock`, {
        method: 'POST', headers: headers(), body: JSON.stringify({ proof: 'not-a-proof' }),
      });
      assert.equal(res.status, 400);
      assert.equal(Number((await row()).failed_attempts), 0);
    });

    await t.test('changing the PIN replaces it and clears the lock', async () => {
      await db.query(`update recovery_keys set locked_until = now() + interval '1 day' where user_id=$1`, [user]);
      assert.equal((await setPin('13572468')).status, 200);
      assert.equal((await unlock(PIN)).status, 401, 'the old PIN must stop working');
      assert.equal((await unlock('13572468')).status, 200);
    });

    await t.test('removing it leaves nothing to unlock', async () => {
      assert.equal((await fetch(`${base}/recovery/key`, { method: 'DELETE', headers: headers() })).status, 200);
      const res = await unlock(PIN);
      assert.equal(res.status, 404);
      assert.equal((await status()).vpin, null);
    });

    await t.test('the database refuses a half-written V PIN row', async () => {
      await assert.rejects(db.query(
        `insert into recovery_keys (user_id, wrapped_key, pin_version) values ($1, null, 2)`, [user]),
        /recovery_keys_pin_scheme_ck/);
    });
  } finally {
    server.close();
    (pool as any).query = originalQuery;
    (pool as any).connect = originalConnect;
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
  }
});
