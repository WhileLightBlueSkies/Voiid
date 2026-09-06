// M03 — a reconnect backlog that drains in pages instead of all at once.
// PENDING_TEST_DATABASE_URL=postgres://.../voiid_test_pending npx tsx --test test/pendingPaginationPostgres.test.ts
//
// Its own database: every DB-backed suite replays the migration set, and `create extension` is
// database-scoped, so two of them in one database race.
//
// M02 MADE THIS URGENT. Fetching used to mark messages delivered, so a second fetch returned
// nothing and the missing page limit rarely showed. Now that fetch is non-destructive, every
// pending message comes back on EVERY fetch until the device acknowledges it — so a phone that
// has been off for a fortnight asks the server to load, sort and serialise its entire backlog
// in memory, repeatedly, and the response is as large as the backlog is.
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
import messagesRouter from '../src/routes/messages';

redis.disconnect();
publisher.disconnect();
const url = process.env.PENDING_TEST_DATABASE_URL;

test('pending backlog pagination against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `pending_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db);
  (pool as any).connect = db.connect.bind(db);
  (publisher as any).publish = async () => 1;

  const app = express();
  app.use(express.json());
  app.use('/messages', messagesRouter);
  app.use((_e: unknown, _req: any, res: any, _next: any) => res.status(500).json({ error: 'test failure' }));
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>((done) => server.once('listening', () => done()));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;

  const ana = randomUUID(), ben = randomUUID(), mal = randomUUID();
  const anaDev = randomUUID(), benPhone = randomUUID(), benTablet = randomUUID();
  const conv = randomUUID();

  async function fetchPending(query = '', user = ben, device: string | undefined = benPhone) {
    const res = await fetch(`${base}/messages/pending/${user}?device_id=${device}${query}`, {
      headers: { authorization: `Bearer ${issueToken({ user_id: user, device_id: device })}` },
    });
    return { status: res.status, body: await res.json().catch(() => ({})) as any };
  }

  /** Drain the whole backlog the way a client would, following the cursor. */
  async function drain(pageQuery = '') {
    const seen: string[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 500; page++) {
      const q = `${pageQuery}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`;
      const res: any = await fetchPending(q);
      assert.equal(res.status, 200, JSON.stringify(res.body));
      seen.push(...res.body.messages.map((m: any) => m.id));
      cursor = res.body.next_cursor ?? null;
      if (!cursor) return { ids: seen, pages: page + 1 };
    }
    throw new Error('backlog did not drain in 500 pages');
  }

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    for (const [i, id] of [ana, ben, mal].entries()) {
      await db.query('insert into users(id, phone_number) values($1,$2)', [id, `+1999000800${i}`]);
    }
    for (const [i, [id, owner]] of [[anaDev, ana], [benPhone, ben], [benTablet, ben]].entries()) {
      await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
        values($1,$2,'test',$3,$4)`, [id, owner, i, Buffer.from('key')]);
    }
    await db.query("insert into conversations(id, type) values($1,'group')", [conv]);
    for (const id of [ana, ben]) {
      await db.query('insert into conversation_members(conversation_id,user_id) values($1,$2)', [conv, id]);
    }

    // A fortnight offline: 250 fan-out messages, interleaved with 50 legacy ones so the merge
    // of the two branches is exercised by the pagination rather than by an in-memory sort.
    const ordered: string[] = [];
    for (let i = 0; i < 300; i++) {
      const id = randomUUID();
      const at = new Date(Date.UTC(2026, 0, 1, 0, 0, 0) + i * 1000).toISOString();
      const legacy = i % 6 === 0;
      await db.query(
        `insert into messages (id, conversation_id, sender_id, sender_device_id, ciphertext, created_at)
         values ($1,$2,$3,$4,$5,$6)`,
        [id, conv, ana, anaDev, legacy ? Buffer.from(`legacy-${i}`) : null, at]
      );
      if (!legacy) {
        for (const dev of [benPhone, benTablet]) {
          await db.query('insert into message_ciphertexts values($1,$2,$3,null)', [id, dev, Buffer.from(`c-${i}`)]);
        }
      }
      ordered.push(id);
    }

    await t.test('a large backlog drains in pages, in order, with nothing lost or repeated', async () => {
      const { ids, pages } = await drain('&limit=40');
      assert.ok(pages > 1, 'a 300-message backlog must not arrive in one response');
      assert.deepEqual(ids, ordered, 'every message, exactly once, oldest first');
      assert.equal(new Set(ids).size, ids.length, 'no message appeared on two pages');
    });

    await t.test('the page size is capped however large a client asks for', async () => {
      const huge = await fetchPending('&limit=100000');
      assert.equal(huge.status, 200);
      assert.ok(
        huge.body.messages.length <= 500,
        `a client asked for everything and got ${huge.body.messages.length}`
      );
      // A client that asks for more than the cap is not refused — wanting everything is not
      // wrong — it is given a page and a cursor. Checked with a small limit so the assertion
      // does not depend on the fixture being larger than the cap.
      const one = await fetchPending('&limit=1');
      assert.equal(one.body.messages.length, 1);
      assert.ok(one.body.next_cursor, 'and is told where to continue from');
    });

    // THE REASON THE CURSOR IS (created_at, id) AND NOT created_at ALONE. `created_at` is not
    // unique — a fan-out send writes its rows in one transaction, and a burst arrives inside the
    // same millisecond. If the page boundary falls inside such a group, a cursor that carries
    // only the timestamp either skips the rest of the group or serves it twice, forever.
    await t.test('a page boundary inside identically timestamped messages loses nothing', async () => {
      const tied = randomUUID();
      await db.query('insert into conversations(id, type) values($1,$2)', [tied, 'group']);
      for (const id of [ana, ben]) {
        await db.query('insert into conversation_members(conversation_id,user_id) values($1,$2)', [tied, id]);
      }
      const sameInstant = '2026-06-01T12:00:00.000Z';
      const clustered: string[] = [];
      for (let i = 0; i < 10; i++) {
        const id = randomUUID();
        await db.query(
          `insert into messages (id, conversation_id, sender_id, sender_device_id, ciphertext, created_at)
           values ($1,$2,$3,$4,null,$5)`, [id, tied, ana, anaDev, sameInstant]);
        await db.query('insert into message_ciphertexts values($1,$2,$3,null)', [id, benPhone, Buffer.from(`t-${i}`)]);
        clustered.push(id);
      }
      // Small pages, so several boundaries land inside the tied group.
      const { ids } = await drain('&limit=3');
      const got = ids.filter((id) => clustered.includes(id));
      assert.equal(got.length, clustered.length, 'a tied message was dropped or repeated across a page');
      assert.equal(new Set(got).size, clustered.length);
      await db.query('delete from message_ciphertexts where message_id = any($1::uuid[])', [clustered]);
      await db.query('delete from messages where id = any($1::uuid[])', [clustered]);
    });

    await t.test('a nonsense limit or cursor is refused rather than guessed at', async () => {
      for (const q of ['&limit=0', '&limit=-5', '&limit=abc']) {
        assert.equal((await fetchPending(q)).status, 400, q);
      }
      assert.equal((await fetchPending('&cursor=not-a-cursor')).status, 400);
    });

    await t.test('acknowledging a page shrinks the backlog rather than shifting it', async () => {
      const first = await fetchPending('&limit=40');
      const ids = first.body.messages.map((m: any) => m.id);
      const acked = await fetch(`${base}/messages/ack`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${issueToken({ user_id: ben, device_id: benPhone })}` },
        body: JSON.stringify({ device_id: benPhone, message_ids: ids }),
      });
      assert.equal(acked.status, 200);
      // The next fetch from the START must not return what was just acknowledged — this is
      // what stops an interrupted drain from re-reading the same page forever.
      const after = await fetchPending('&limit=40');
      const overlap = after.body.messages.filter((m: any) => ids.includes(m.id));
      assert.deepEqual(overlap, [], 'acknowledged messages came back');
      const { ids: rest } = await drain('&limit=40');
      assert.equal(rest.length, ordered.length - ids.length);
    });

    await t.test('a revoked device is served nothing, however it paginates', async () => {
      await db.query('update devices set revoked_at=now() where id=$1', [benTablet]);
      const res = await fetchPending('&limit=10', ben, benTablet);
      assert.equal(res.status, 403, 'a revoked device is not a device');
      await db.query('update devices set revoked_at=null where id=$1', [benTablet]);
    });

    await t.test('a blocked sender contributes nothing to any page', async () => {
      await db.query('insert into user_blocks(blocker_user_id,blocked_user_id) values($1,$2)', [ben, ana]);
      const res = await fetchPending('&limit=500', ben, benTablet);
      assert.equal(res.status, 200);
      assert.deepEqual(res.body.messages, [], 'blocking must apply to the stored backlog, not only to pushes');
      await db.query('delete from user_blocks');
    });

    await t.test('an outsider cannot page through someone else s backlog', async () => {
      const res = await fetch(`${base}/messages/pending/${ben}?device_id=${benPhone}&limit=10`, {
        headers: { authorization: `Bearer ${issueToken({ user_id: mal, device_id: anaDev })}` },
      });
      assert.equal(res.status, 403);
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
