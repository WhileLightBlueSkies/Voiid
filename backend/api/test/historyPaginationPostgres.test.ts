// M04 — history pages that cannot skip a message, and receipt semantics that are decided.
// HISTORY_TEST_DATABASE_URL=postgres://.../voiid_test_history npx tsx --test test/historyPaginationPostgres.test.ts
//
// Its own database: every DB-backed suite replays the migration set and `create extension` is
// database-scoped, so two of them in one database race.
//
// THE CURSOR DEFECT. History ordered by `created_at desc` and paged with `before=<timestamp>`,
// strictly less-than. `created_at` is not unique — a fan-out send writes its rows in one
// transaction, and a burst of messages lands inside the same millisecond. When a page boundary
// falls inside such a group, `before` skips every remaining row sharing that timestamp: they are
// not "after the cursor", they ARE the cursor, and the next page starts past them. The messages
// are on the server and the client never asks for them again.
//
// THE SEMANTICS QUESTION. The blue tick compares "recipients who read" against "active members
// other than the sender" — a CURRENT-roster count. Someone joining a group after a message was
// sent therefore un-reads it for everyone. This file pins the decision either way so it stops
// being an accident.
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
const url = process.env.HISTORY_TEST_DATABASE_URL;

test('history pagination against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `history_test_${randomUUID().replaceAll('-', '')}`;
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

  const ana = randomUUID(), ben = randomUUID(), cleo = randomUUID();
  const anaDev = randomUUID(), benDev = randomUUID();
  const conv = randomUUID();

  async function history(query = '', user = ana, device = anaDev) {
    const res = await fetch(`${base}/messages/conversation/${conv}?device_id=${device}${query}`, {
      headers: { authorization: `Bearer ${issueToken({ user_id: user, device_id: device })}` },
    });
    return { status: res.status, body: await res.json().catch(() => ({})) as any };
  }

  /** Page backwards the way a client scrolling up does, following whatever cursor it is given. */
  async function pageAll(pageSize: number) {
    const seen: string[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 400; page++) {
      const q = `&limit=${pageSize}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`;
      const res: any = await history(q);
      assert.equal(res.status, 200, JSON.stringify(res.body));
      seen.push(...res.body.messages.map((m: any) => m.id));
      cursor = res.body.next_cursor ?? null;
      if (!cursor) return seen;
    }
    throw new Error('history did not drain in 400 pages');
  }

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    for (const [i, id] of [ana, ben, cleo].entries()) {
      await db.query('insert into users(id, phone_number) values($1,$2)', [id, `+1999003000${i}`]);
    }
    for (const [i, [id, owner]] of [[anaDev, ana], [benDev, ben]].entries()) {
      await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
        values($1,$2,'test',$3,$4)`, [id, owner, i, Buffer.from('key')]);
    }
    await db.query("insert into conversations(id, type) values($1,'group')", [conv]);
    for (const id of [ana, ben]) {
      await db.query('insert into conversation_members(conversation_id,user_id) values($1,$2)', [conv, id]);
    }

    // THE FIXTURE THE ACCEPTANCE NAMES: "several hundred identical timestamps".
    const sameInstant = '2026-03-01T09:00:00.000Z';
    const tied: string[] = [];
    for (let i = 0; i < 300; i++) {
      const id = randomUUID();
      await db.query(
        `insert into messages (id, conversation_id, sender_id, sender_device_id, ciphertext, created_at)
         values ($1,$2,$3,$4,$5,$6)`,
        [id, conv, ana, anaDev, Buffer.from(`m-${i}`), sameInstant]
      );
      tied.push(id);
    }
    // A few either side, so the boundary between tied and untied rows is exercised too.
    const spread: string[] = [];
    for (let i = 0; i < 20; i++) {
      const id = randomUUID();
      await db.query(
        `insert into messages (id, conversation_id, sender_id, sender_device_id, ciphertext, created_at)
         values ($1,$2,$3,$4,$5,$6)`,
        [id, conv, ana, anaDev, Buffer.from(`s-${i}`), new Date(Date.parse(sameInstant) + (i + 1) * 1000).toISOString()]
      );
      spread.push(id);
    }
    const everything = new Set([...tied, ...spread]);

    await t.test('300 identical timestamps paginate without skipping a single message', async () => {
      const seen = await pageAll(25);
      assert.equal(new Set(seen).size, seen.length, 'a message appeared on two pages');
      const missing = [...everything].filter((id) => !seen.includes(id));
      assert.deepEqual(
        missing, [],
        `${missing.length} messages were skipped at a page boundary — the client can never ask for them again`
      );
      assert.equal(seen.length, everything.size);
    });

    await t.test('a page size of one still walks the whole tied block', async () => {
      const seen = await pageAll(1);
      assert.equal(new Set(seen).size, everything.size);
    });

    await t.test('history is returned newest first, and stays so across pages', async () => {
      const first = await history('&limit=10');
      const times = first.body.messages.map((m: any) => Date.parse(m.created_at));
      assert.deepEqual(times, [...times].sort((a, b) => b - a), 'a page is out of order');
    });

    await t.test('an unusable limit or cursor is refused rather than guessed at', async () => {
      for (const q of ['&limit=0', '&limit=-1', '&limit=abc']) {
        assert.equal((await history(q)).status, 400, q);
      }
      assert.equal((await history('&cursor=not-a-cursor')).status, 400);
    });

    await t.test('the legacy before= parameter still works for clients that send it', async () => {
      // Dual-compatible, per M04's migration note: a client that has not learned about cursors
      // must keep paginating, even though `before` cannot express a tie.
      const res = await history(`&before=${encodeURIComponent(new Date(Date.parse(sameInstant) + 5000).toISOString())}`);
      assert.equal(res.status, 200);
      assert.ok(res.body.messages.length > 0);
      assert.ok(
        res.body.messages.every((m: any) => Date.parse(m.created_at) < Date.parse(sameInstant) + 5000),
        'before= returned something at or after the cursor'
      );
    });

    // ── The receipt-status decision M04 asks to be made explicitly ────────────────
    await t.test('read status is judged against the roster AT SEND TIME, not the current one', async () => {
      // A message the page is GUARANTEED to contain. `tied[0]` is not: 300 rows share a
      // timestamp and the tie-break is a random uuid, so which of them lands in any given page
      // is luck — this subtest failed on roughly two runs in three before that was noticed.
      // Newest-first, so a distinctly later timestamp is always on page one.
      const msg = spread[spread.length - 1];
      // Ben, the only other member when it was sent, reads it.
      await db.query(
        `insert into message_read_receipts (message_id, user_id, device_id, status, delivered_at, read_at)
         values ($1,$2,$3,'read', now(), now())`,
        [msg, ben, benDev]
      );
      const before = await history('&limit=100');
      const readNow = before.body.messages.find((m: any) => m.id === msg);
      assert.equal(readNow.receipt_status, 'read', 'every recipient at send time has read it');

      // Cleo joins the group AFTER that message existed.
      await db.query('insert into conversation_members(conversation_id,user_id) values($1,$2)', [conv, cleo]);
      const after = await history('&limit=100');
      const stillRead = after.body.messages.find((m: any) => m.id === msg);
      assert.equal(
        stillRead.receipt_status, 'read',
        'a new member un-read an old message: the tick went backwards for everyone, and the ' +
          'new member cannot read a message they were never sent'
      );
      await db.query('delete from conversation_members where conversation_id=$1 and user_id=$2', [conv, cleo]);
      await db.query('delete from message_read_receipts where message_id=$1', [msg]);
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
