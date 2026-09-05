// S03 — device-bound sessions, against the real routers and real PostgreSQL.
// SESSION_TEST_DATABASE_URL=postgres://.../voiid_test_sessions npx tsx --test test/sessionPostgres.test.ts
//
// Never point this at Supabase (staging/production). The guard below refuses anything that
// is not a loopback host with a disposable `voiid_test_*` database name.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';
import express from 'express';

process.env.AUTH_DEV_BYPASS = '1';
process.env.NODE_ENV = 'test';

import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { issueToken } from '../src/auth';
import authRouter from '../src/routes/auth';
import devicesRouter from '../src/routes/devices';
import prekeysRouter from '../src/routes/prekeys';
import messagesRouter from '../src/routes/messages';

redis.disconnect();
publisher.disconnect();
const url = process.env.SESSION_TEST_DATABASE_URL;

test('device-bound sessions and revocation against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `session_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db);
  (pool as any).connect = db.connect.bind(db);

  // Redis stands in as a real key/value cache so both the CACHED verdict and its
  // invalidation are exercised. `cache.clear()` then models a flush/restart, which must
  // not resurrect anything — the database stays the authority.
  const cache = new Map<string, string>();
  (redis as any).get = async (key: string) => cache.get(key) ?? null;
  (redis as any).set = async (key: string, value: string) => { cache.set(key, value); return 'OK'; };
  (redis as any).del = async (key: string) => { cache.delete(key); return 1; };
  const events: any[] = [];
  (publisher as any).publish = async (channel: string, payload: string) => {
    events.push({ channel, ...JSON.parse(payload) }); return 1;
  };
  (redis as any).publish = (publisher as any).publish;

  const app = express();
  app.use(express.json());
  app.use('/auth', authRouter);
  app.use('/devices', devicesRouter);
  app.use('/prekeys', prekeysRouter);
  app.use('/messages', messagesRouter);
  app.use((_error: unknown, _req: any, res: any, _next: any) => res.status(500).json({ error: 'test failure' }));
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>((done) => server.once('listening', () => done()));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;

  async function call(method: string, path: string, token?: string, body?: any) {
    const response = await fetch(`${base}${path}`, {
      method,
      headers: {
        'content-type': 'application/json',
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: response.status, body: await response.json().catch(() => ({})) as any };
  }

  // The real onboarding sequence: OTP exchange, then device registration.
  async function login(phone: string) {
    const res = await call('POST', '/auth/firebase', undefined, { id_token: `dev:${phone}` });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    return res.body as { token: string; user_id: string };
  }
  let registrationSeed = 1000;
  async function register(token: string, platform = 'ios', registration_id = ++registrationSeed) {
    return call('POST', '/devices/register', token, {
      platform, registration_id,
      identity_public_key: Buffer.from(`identity-${registration_id}`).toString('base64'),
    });
  }
  // Every capability S03 names: upload keys, send, fetch.
  const uploadKeys = (token: string, device_id: string) =>
    call('POST', '/prekeys/upload', token, {
      device_id,
      one_time_prekeys: [{ key_id: Math.floor(Math.random() * 1e6), public_key: Buffer.from('otk').toString('base64') }],
    });
  const fetchPending = (token: string, user: string, device_id: string) =>
    call('GET', `/messages/pending/${user}?device_id=${device_id}`, token);

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }

    await t.test('login yields a bootstrap credential, and registering it mints the session', async () => {
      cache.clear(); events.length = 0;
      const { token: bootstrap, user_id } = await login('+19990001001');
      const claims = JSON.parse(Buffer.from(bootstrap.split('.')[1], 'base64url').toString());
      assert.equal(claims.scope, 'bootstrap');
      assert.equal(claims.device_id, undefined);
      assert.equal(claims.sid, undefined);

      const registered = await register(bootstrap);
      assert.equal(registered.status, 200, JSON.stringify(registered.body));
      assert.ok(registered.body.token, 'register returns a device-bound session token');
      const session = JSON.parse(Buffer.from(registered.body.token.split('.')[1], 'base64url').toString());
      assert.equal(session.scope, 'session');
      assert.equal(session.device_id, registered.body.device_id);
      assert.match(session.sid ?? '', /^[0-9a-f-]{36}$/);
      assert.equal(session.user_id, user_id);
      assert.equal((await uploadKeys(registered.body.token, registered.body.device_id)).status, 200);
      // The session row is the durable authority the JWT now points at.
      const { rows } = await db.query('select user_id, device_id, revoked_at from device_sessions where id=$1', [session.sid]);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].user_id, user_id);
      assert.equal(rows[0].device_id, registered.body.device_id);
      assert.equal(rows[0].revoked_at, null);
    });

    await t.test('past the cutoff only a device session is accepted, but registration still is', async () => {
      cache.clear(); events.length = 0;
      const { token: bootstrap, user_id } = await login('+19990001009');
      process.env.VOIID_SESSION_CUTOFF = '2000-01-01T00:00:00Z';
      try {
        // A credential with no session cannot touch the messaging surface any more.
        const denied = await fetchPending(bootstrap, user_id, randomUUID());
        assert.equal(denied.status, 401);
        assert.equal(denied.body.code, 'device_session_required');
        assert.equal((await uploadKeys(bootstrap, randomUUID())).status, 401);

        // Registration must keep accepting it — it is the only way to obtain a session,
        // so gating it behind one would strand every client on the wrong side of the cutoff.
        const registered = await register(bootstrap);
        assert.equal(registered.status, 200, JSON.stringify(registered.body));
        assert.equal((await uploadKeys(registered.body.token, registered.body.device_id)).status, 200);
      } finally {
        delete process.env.VOIID_SESSION_CUTOFF;
      }
    });

    await t.test('logout revokes this device only; its old token cannot upload, send or fetch', async () => {
      cache.clear(); events.length = 0;
      const { token: bootstrap, user_id } = await login('+19990001002');
      const first = (await register(bootstrap, 'ios')).body;
      const second = (await register(bootstrap, 'android')).body;
      assert.equal((await uploadKeys(first.token, first.device_id)).status, 200);
      assert.equal((await uploadKeys(second.token, second.device_id)).status, 200);

      assert.equal((await call('POST', '/auth/logout', first.token)).status, 200);

      // The revoked device's own token is dead on every path S03 names.
      for (const result of [
        await uploadKeys(first.token, first.device_id),
        await fetchPending(first.token, user_id, first.device_id),
        await call('POST', '/messages/send', first.token, { conversation_id: randomUUID(), ciphertext: 'b3A=' }),
      ]) {
        assert.equal(result.status, 401);
        assert.equal(result.body.code, 'session_revoked');
      }
      // The other linked device is untouched.
      assert.equal((await uploadKeys(second.token, second.device_id)).status, 200);
      assert.equal((await fetchPending(second.token, user_id, second.device_id)).status, 200);

      // Explicit user revocation is recorded as such, and the live socket is told to go.
      const { rows } = await db.query('select revoked_at, revoked_reason from devices where id=$1', [first.device_id]);
      assert.ok(rows[0].revoked_at);
      assert.equal(rows[0].revoked_reason, 'user_revoked');
      assert.ok(events.some((e) => e.type === 'force_signout' && e.device_id === first.device_id));
    });

    await t.test('a flushed cache does not resurrect a revoked session', async () => {
      cache.clear(); events.length = 0;
      const { token: bootstrap, user_id } = await login('+19990001003');
      const device = (await register(bootstrap)).body;
      assert.equal((await fetchPending(device.token, user_id, device.device_id)).status, 200);
      assert.equal((await call('POST', '/auth/logout', device.token)).status, 200);
      assert.equal((await fetchPending(device.token, user_id, device.device_id)).status, 401);

      cache.clear(); // process restart / Redis flush: the durable record must still refuse
      const afterFlush = await fetchPending(device.token, user_id, device.device_id);
      assert.equal(afterFlush.status, 401);
      assert.equal(afterFlush.body.code, 'session_revoked');
    });

    await t.test('DELETE /devices revokes that device session and prekey upload cannot undo it', async () => {
      cache.clear(); events.length = 0;
      const { token: bootstrap } = await login('+19990001004');
      const device = (await register(bootstrap)).body;
      assert.equal((await call('DELETE', `/devices/${device.device_id}`, device.token)).status, 200);
      assert.equal((await uploadKeys(device.token, device.device_id)).status, 401);

      // Even a still-valid sibling session must not be able to reinstate a device the user
      // explicitly revoked — that was the reactivation hole.
      const sibling = (await register(bootstrap, 'android')).body;
      assert.equal((await uploadKeys(sibling.token, device.device_id)).status, 404);
      const { rows } = await db.query('select revoked_at, revoked_reason from devices where id=$1', [device.device_id]);
      assert.ok(rows[0].revoked_at, 'user revocation survives a prekey upload');
      assert.equal(rows[0].revoked_reason, 'user_revoked');
    });

    await t.test('a device superseded by reinstall is still reinstatable by its own upload', async () => {
      cache.clear(); events.length = 0;
      const { token: bootstrap } = await login('+19990001005');
      const first = (await register(bootstrap, 'ios')).body;
      // Reinstall: same platform, fresh registration id — supersedes the previous row.
      const reinstalled = (await register(bootstrap, 'ios')).body;
      assert.notEqual(reinstalled.device_id, first.device_id);
      const superseded = await db.query('select revoked_at, revoked_reason from devices where id=$1', [first.device_id]);
      assert.ok(superseded.rows[0].revoked_at);
      assert.equal(superseded.rows[0].revoked_reason, 'superseded');

      // The superseded device's SESSION is gone — reinstall recovery needs fresh authorization.
      assert.equal((await uploadKeys(first.token, first.device_id)).status, 401);
      // But the row itself is reinstatable, which is how a raced upload recovers.
      assert.equal((await uploadKeys(reinstalled.token, first.device_id)).status, 200);
      const revived = await db.query('select revoked_at from devices where id=$1', [first.device_id]);
      assert.equal(revived.rows[0].revoked_at, null);
    });

    await t.test('legacy user-only tokens work in the grace window and stop at the cutoff', async () => {
      cache.clear(); events.length = 0;
      const { token: bootstrap, user_id } = await login('+19990001006');
      const device = (await register(bootstrap)).body;
      const legacy = issueToken({ user_id }); // pre-S03 shape: no scope, no sid

      delete process.env.VOIID_SESSION_CUTOFF;
      assert.equal((await fetchPending(legacy, user_id, device.device_id)).status, 200);

      process.env.VOIID_SESSION_CUTOFF = '2000-01-01T00:00:00Z';
      try {
        const expired = await fetchPending(legacy, user_id, device.device_id);
        assert.equal(expired.status, 401);
        assert.equal(expired.body.code, 'reauthentication_required');
        // The migrated client keeps working across the same cutoff.
        assert.equal((await fetchPending(device.token, user_id, device.device_id)).status, 200);
      } finally {
        delete process.env.VOIID_SESSION_CUTOFF;
      }
    });

    await t.test('a session naming another user or a foreign device is refused', async () => {
      cache.clear(); events.length = 0;
      const mine = (await register((await login('+19990001007')).token)).body;
      const theirs = await login('+19990001008');
      const foreign = (await register(theirs.token)).body;

      // Same signature, swapped subject: the session row pins user and device together.
      const forged = issueToken({ user_id: theirs.user_id, device_id: foreign.device_id, sid: mineSid(mine.token), scope: 'session' } as any);
      assert.equal((await uploadKeys(forged, foreign.device_id)).status, 401);
      // An unknown session id is not a session at all.
      const unknown = issueToken({ user_id: theirs.user_id, device_id: foreign.device_id, sid: randomUUID(), scope: 'session' } as any);
      assert.equal((await uploadKeys(unknown, foreign.device_id)).status, 401);
      assert.equal((await uploadKeys(mine.token, mine.device_id)).status, 200);
    });

    function mineSid(token: string): string {
      return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).sid;
    }
  } finally {
    await new Promise<void>((done, fail) => server.close((error) => (error ? fail(error) : done())));
    (pool as any).query = originalQuery;
    (pool as any).connect = originalConnect;
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
  }
});
