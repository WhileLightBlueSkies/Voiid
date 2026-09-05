// M01 — the sweep that keeps the promise the send transaction made, against real PostgreSQL.
// OUTBOX_TEST_DATABASE_URL=postgres://.../voiid_test_outbox npx tsx --test test/outbox.test.ts
//
// Its own database, not just its own schema: every DB-backed suite replays the full migration
// set and `create extension` is database-scoped, so two of them in one database race.
//
// The API publishes inline immediately after commit and that settles almost everything. This
// is what happens to the rest — the wakes owed when Redis was down, or when the process died
// between the commit and the publish. Without it those messages exist and nobody is told.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';

const url = process.env.OUTBOX_TEST_DATABASE_URL;
process.env.DATABASE_URL = url ?? '';

import { pool } from '../src/db';
import { flushOutbox, OUTBOX_MAX_ATTEMPTS } from '../src/outbox';

test('outbox sweep against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `outbox_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db);
  (pool as any).connect = db.connect.bind(db);

  const ana = randomUUID(), ben = randomUUID();
  const conv = randomUUID();

  let published: { channel: string; payload: string }[] = [];
  let failNext = 0;
  const publish = async (channel: string, payload: string) => {
    if (failNext > 0) { failNext--; throw new Error('redis is down'); }
    published.push({ channel, payload });
    return 1;
  };

  async function owe(count: number, messageId?: string): Promise<string[]> {
    const id = messageId ?? (await db.query(
      `insert into messages (conversation_id, sender_id, ciphertext) values ($1,$2,$3) returning id`,
      [conv, ana, Buffer.from('opaque')]
    )).rows[0].id;
    const ids: string[] = [];
    for (let i = 0; i < count; i++) {
      const row = await db.query(
        `insert into message_outbox (message_id, channel, payload) values ($1,$2,$3::jsonb) returning id`,
        [id, `channel:user:${ben}`, JSON.stringify({ type: 'message', message_id: id, n: i })]
      );
      ids.push(row.rows[0].id);
    }
    return ids;
  }
  const statusOf = async (id: string) =>
    (await db.query('select status, attempts, last_error, lease_until from message_outbox where id=$1', [id])).rows[0];
  async function reset() {
    published = []; failNext = 0;
    await db.query('delete from message_outbox');
    await db.query('delete from messages');
  }

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    for (const [i, id] of [ana, ben].entries()) {
      await db.query('insert into users(id, phone_number) values($1,$2)', [id, `+1999000600${i}`]);
    }
    await db.query('insert into conversations(id) values($1)', [conv]);

    await t.test('an owed wake is published and settled', async () => {
      await reset();
      const [id] = await owe(1);
      const result = await flushOutbox(publish);
      assert.equal(result.published, 1);
      assert.equal(published.length, 1);
      assert.equal(published[0].channel, `channel:user:${ben}`);
      const row = await statusOf(id);
      assert.equal(row.status, 'published');
      assert.equal(row.lease_until, null, 'the lease is released with the row');
    });

    await t.test('a settled row is never published a second time', async () => {
      await reset();
      await owe(1);
      await flushOutbox(publish);
      published = [];
      const again = await flushOutbox(publish);
      assert.equal(again.claimed, 0);
      assert.equal(published.length, 0);
    });

    await t.test('a publish failure leaves the row retryable, with the reason recorded', async () => {
      await reset();
      const [id] = await owe(1);
      failNext = 1;
      const first = await flushOutbox(publish);
      assert.equal(first.failed, 1);
      const failedRow = await statusOf(id);
      assert.equal(failedRow.status, 'failed');
      assert.equal(failedRow.attempts, 1);
      assert.match(failedRow.last_error, /redis is down/);
      assert.equal(failedRow.lease_until, null, 'released, so the next sweep can claim it');

      // THE POINT OF THE WHOLE MECHANISM: the next sweep delivers it.
      const second = await flushOutbox(publish);
      assert.equal(second.published, 1);
      assert.equal((await statusOf(id)).status, 'published');
    });

    await t.test('a row that keeps failing is eventually left alone rather than retried forever', async () => {
      await reset();
      const [id] = await owe(1);
      for (let i = 0; i < OUTBOX_MAX_ATTEMPTS + 2; i++) {
        failNext = 1;
        await flushOutbox(publish);
      }
      const row = await statusOf(id);
      assert.equal(row.status, 'failed');
      assert.equal(row.attempts, OUTBOX_MAX_ATTEMPTS, 'it stops being claimed at the ceiling');
      // Still in the table, so it is visible to an operator rather than silently dropped.
      const stuck = await flushOutbox(publish);
      assert.equal(stuck.claimed, 0);
    });

    await t.test('a lease held by a live sweep is not claimed by a second one', async () => {
      await reset();
      await owe(6);
      // Two sweeps at once, as two boxes running the worker would be.
      const [a, b] = await Promise.all([flushOutbox(publish), flushOutbox(publish)]);
      assert.equal(a.published + b.published, 6, 'every row delivered');
      assert.equal(published.length, 6, 'and each exactly once');
      const rows = await db.query('select status from message_outbox');
      assert.ok(rows.rows.every((r: any) => r.status === 'published'));
    });

    await t.test('an expired lease is reclaimed, so a dead sweep does not strand a wake', async () => {
      await reset();
      const [id] = await owe(1);
      // A worker claimed this and died: leased, never settled.
      await db.query(
        `update message_outbox set lease_until = now() - interval '1 minute', attempts = 1 where id=$1`,
        [id]
      );
      const result = await flushOutbox(publish);
      assert.equal(result.published, 1, 'the stranded wake is delivered');
      assert.equal((await statusOf(id)).status, 'published');
    });

    await t.test('the oldest debt is paid first, and a batch is bounded', async () => {
      await reset();
      await owe(5);
      const result = await flushOutbox(publish, { batch: 2 });
      assert.equal(result.claimed, 2, 'the batch size is respected');
      const order = published.map((p) => JSON.parse(p.payload).n);
      assert.deepEqual(order, [0, 1], 'in the order the debts were incurred');
    });
  } finally {
    (pool as any).query = originalQuery;
    (pool as any).connect = originalConnect;
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
    await pool.end().catch(() => {});
  }
});
