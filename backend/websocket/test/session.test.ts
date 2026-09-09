// S03 — the relay's connect-time authorization, against real PostgreSQL.
// SESSION_TEST_DATABASE_URL=postgres://.../voiid_test_sessions npx tsx --test test/session.test.ts
//
// The relay carries the messages, calls and locations. Before this it checked a signature
// and an account tombstone in Redis, so a revoked DEVICE kept its socket, and a Redis flush
// re-opened the door for a deleted account. These tests pin both.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';
import jwt from 'jsonwebtoken';

const url = process.env.SESSION_TEST_DATABASE_URL;
// Set before the module reads them. session.ts resolves both lazily, on first use, precisely
// so the relay can be exercised without a live database at import time.
process.env.JWT_SECRET = 'relay-session-test-secret';
process.env.DATABASE_URL = url ?? '';

import { authorizeConnection, sessionPool, useSessionCache } from '../src/session';

test('relay connect authorization against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `relay_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const pool = sessionPool();
  (pool as any).query = db.query.bind(db);

  const cache = new Map<string, string>();
  useSessionCache({
    get: async (key: string) => cache.get(key) ?? null,
    set: async (key: string, value: string) => { cache.set(key, value); return 'OK'; },
  });

  const user = randomUUID(), device = randomUUID(), other = randomUUID();
  const token = (claims: Record<string, unknown>) => jwt.sign(claims, process.env.JWT_SECRET!, { expiresIn: '30d' });

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    await db.query('insert into users(id, phone_number) values($1,$2)', [user, '+19990002001']);
    for (const id of [device, other]) {
      await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
        values($1,$2,'test',$3,$4)`, [id, user, id === device ? 1 : 2, Buffer.from('key')]);
    }
    const live = (await db.query('insert into device_sessions(user_id,device_id) values($1,$2) returning id', [user, device])).rows[0].id;
    const spare = (await db.query('insert into device_sessions(user_id,device_id) values($1,$2) returning id', [user, other])).rows[0].id;
    const sessionToken = token({ user_id: user, device_id: device, sid: live, scope: 'session' });
    const spareToken = token({ user_id: user, device_id: other, sid: spare, scope: 'session' });

    await t.test('a missing or unverifiable token is refused', async () => {
      cache.clear();
      assert.equal((await authorizeConnection(null)).ok, false);
      assert.equal((await authorizeConnection('not-a-jwt')).ok, false);
      const forged = jwt.sign({ user_id: user, device_id: device, sid: live }, 'a-different-secret');
      const result = await authorizeConnection(forged);
      assert.equal(result.ok, false);
      assert.equal((result as any).code, 4401);
    });

    await t.test('a live session connects', async () => {
      cache.clear();
      const result = await authorizeConnection(sessionToken);
      assert.equal(result.ok, true);
      assert.equal((result as any).userId, user);
      assert.equal((result as any).deviceId, device);
    });

    await t.test('a web capability requires a durable session and survives authorization', async () => {
      cache.clear();
      assert.equal((await authorizeConnection(token({ user_id: user, device_id: device, client: 'web' }))).ok, false);
      const result = await authorizeConnection(token({ user_id: user, device_id: device, sid: live, scope: 'session', client: 'web' }));
      assert.equal(result.ok, true);
      assert.equal((result as any).client, 'web');
    });

    await t.test('a revoked session is refused, and a flushed cache keeps refusing it', async () => {
      cache.clear();
      assert.equal((await authorizeConnection(sessionToken)).ok, true); // warms the cache
      await db.query('update device_sessions set revoked_at=now(), revoked_reason=$2 where id=$1', [live, 'user_revoked']);
      // Redis still holds the positive verdict; the API writes a tombstone over it on revoke.
      cache.set(`auth:session:${live}:${user}:${device}`, '0');
      const refused = await authorizeConnection(sessionToken);
      assert.equal(refused.ok, false);
      assert.equal((refused as any).code, 4403);

      // The cache is gone entirely — a restart, a flush. The database still refuses.
      cache.clear();
      const afterFlush = await authorizeConnection(sessionToken);
      assert.equal(afterFlush.ok, false);
      assert.equal((afterFlush as any).code, 4403);

      // The user's other device is unaffected.
      assert.equal((await authorizeConnection(spareToken)).ok, true);
      await db.query('update device_sessions set revoked_at=null, revoked_reason=null where id=$1', [live]);
    });

    await t.test('revoking the device ends its sessions without touching the session row', async () => {
      cache.clear();
      await db.query('update devices set revoked_at=now(), revoked_reason=$2 where id=$1', [device, 'user_revoked']);
      assert.equal((await authorizeConnection(sessionToken)).ok, false);
      assert.equal((await authorizeConnection(spareToken)).ok, true);
      await db.query('update devices set revoked_at=null, revoked_reason=null where id=$1', [device]);
    });

    await t.test('a deleted account is refused even with a live session row', async () => {
      cache.clear();
      await db.query('update users set deleted_at=now() where id=$1', [user]);
      const result = await authorizeConnection(sessionToken);
      assert.equal(result.ok, false);
      assert.equal((result as any).code, 4403);
      await db.query('update users set deleted_at=null where id=$1', [user]);
    });

    await t.test('legacy user-only tokens connect until the cutoff, then never again', async () => {
      cache.clear();
      const legacy = token({ user_id: user });
      delete process.env.VOIID_SESSION_CUTOFF;
      assert.equal((await authorizeConnection(legacy)).ok, true);
      process.env.VOIID_SESSION_CUTOFF = '2000-01-01T00:00:00Z';
      try {
        assert.equal((await authorizeConnection(legacy)).ok, false);
        assert.equal((await authorizeConnection(sessionToken)).ok, true);
      } finally { delete process.env.VOIID_SESSION_CUTOFF; }
    });

    await t.test('an unreachable database refuses the socket rather than guessing', async () => {
      cache.clear();
      (pool as any).query = async () => { throw new Error('connection refused'); };
      try {
        const result = await authorizeConnection(sessionToken);
        assert.equal(result.ok, false);
        // Distinct from a revocation: the client should retry, not sign the user out.
        assert.equal((result as any).code, 4503);
      } finally { (pool as any).query = db.query.bind(db); }
    });
  } finally {
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
    await pool.end().catch(() => {});
  }
});
