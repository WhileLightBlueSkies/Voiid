// Real router + real PostgreSQL. Run against an explicitly named disposable local DB:
// RECEIPT_TEST_DATABASE_URL=postgres://.../voiid_test_receipts npm test -w @voiid/api
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';
import express from 'express';
import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { issueToken } from '../src/auth';
import receiptsRouter from '../src/routes/receipts';
import messagesRouter from '../src/routes/messages';

redis.disconnect();
publisher.disconnect();
const url = process.env.RECEIPT_TEST_DATABASE_URL;

test('receipt authorization against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `receipt_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db);
  (pool as any).connect = db.connect.bind(db);
  const events: any[] = [];
  (publisher as any).publish = async (_channel: string, payload: string) => {
    events.push(JSON.parse(payload)); return 1;
  };
  const app = express();
  app.use(express.json());
  app.use('/receipts', receiptsRouter);
  app.use('/messages', messagesRouter);
  app.use((_error: unknown, _req: any, res: any, _next: any) => res.status(500).json({error: 'test failure'}));
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;
  const ana = randomUUID(), ben = randomUUID(), mal = randomUUID();
  const anaDev = randomUUID(), benDev = randomUUID(), benOther = randomUUID(), malDev = randomUUID();
  const conv = randomUUID(), msg = randomUUID(), fanout = randomUUID();
  async function call(path: string, user = ben, device: string | undefined = undefined, body?: any) {
    const response = await fetch(`${base}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: {'content-type': 'application/json', authorization: `Bearer ${issueToken({user_id: user, device_id: device})}`},
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return {status: response.status, body: await response.json() as any};
  }
  async function mark(message_ids = [msg], device_id: unknown = benDev, status = 'read', user = ben, tokenDevice?: string) {
    return call('/receipts/mark', user, tokenDevice, {message_ids, device_id, status});
  }
  async function reset() {
    events.length = 0;
    await db.query('truncate message_read_receipts');
    await db.query('update devices set revoked_at = null');
    await db.query('update conversation_members set left_at = null');
  }
  try {
    // Use the real table definitions and NULL-device migration.
    const root = resolve(__dirname, '../../..');
    for (const file of ['001_users.sql', '002_devices.sql', '005_conversations.sql', '006_messages.sql',
      '007_message_read_receipts.sql', '013_message_ciphertexts.sql', '027_receipt_null_device.sql']) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    for (const [i, id] of [ana, ben, mal].entries()) {
      await db.query('insert into users(id, phone_number) values($1,$2)', [id, `+1999000000${i}`]);
    }
    for (const [i, [id, user]] of [[anaDev, ana], [benDev, ben], [benOther, ben], [malDev, mal]].entries()) {
      await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
        values($1,$2,'test',$3,$4)`, [id, user, i, Buffer.from('public fixture key')]);
    }
    await db.query('insert into conversations(id) values($1)', [conv]);
    for (const user of [ana, ben]) await db.query(
      'insert into conversation_members(conversation_id,user_id) values($1,$2)', [conv, user]);
    await db.query(`insert into messages(id,conversation_id,sender_id,ciphertext)
      values($1,$3,$4,$5),($2,$3,$4,null)`, [msg, fanout, conv, ana, Buffer.from('opaque')]);
    await db.query('insert into message_ciphertexts values($1,$2,$3,null)', [fanout, benDev, Buffer.from('opaque fanout')]);

    await t.test('legacy and fanout succeed; duplicates and NULL-device conflict targets are monotonic', async () => {
      await reset();
      for (const device of [benDev, null]) {
        for (const status of ['read', 'delivered', 'read']) {
          assert.equal((await mark([msg, msg.toUpperCase()], device, status)).status, 200);
        }
      }
      assert.equal((await mark([fanout])).status, 200);
      const { rows } = await db.query('select status,delivered_at,read_at from message_read_receipts');
      assert.equal(rows.length, 3);
      assert.ok(rows.every(r => r.status === 'read' && r.delivered_at && r.read_at));
      assert.ok(events.every(e => e.status === 'read'));
    });
    await t.test('outsider, mixed missing IDs, foreign, unknown and revoked devices cannot mutate', async () => {
      await reset();
      assert.equal((await mark([msg], malDev, 'read', mal)).status, 403);
      assert.equal((await mark([msg, randomUUID()])).status, 403);
      for (const device of [anaDev, randomUUID(), '', 42]) {
        assert.equal((await mark([msg], device)).status, 403);
      }
      await db.query('update devices set revoked_at=now() where id=$1', [benDev]);
      assert.equal((await mark([msg], benOther, 'read', ben, benDev)).status, 403);
      assert.equal((await call(`/receipts/${msg}`, ben, benDev)).status, 403);
      assert.equal((await db.query('select * from message_read_receipts')).rows.length, 0);
      assert.equal(events.length, 0);
    });
    await t.test('fanout access requires the addressed device; sender may inspect its roster', async () => {
      await reset();
      assert.equal((await mark([fanout], benOther)).status, 403);
      assert.equal((await mark([fanout], null)).status, 403);
      assert.equal((await call(`/receipts/${fanout}?device_id=${benOther}`)).status, 403);
      assert.equal((await call(`/receipts/${fanout}`, ana)).status, 200);
      assert.equal((await call(`/receipts/${fanout}?device_id=${benDev}`)).status, 200);
      await db.query('update conversation_members set left_at=now() where user_id=$1', [ben]);
      assert.equal((await mark()).status, 403);
      assert.equal((await call(`/receipts/${msg}`)).status, 403);
    });
    await t.test('one reader cannot suppress another device or recipient legacy queue', async () => {
      await reset();
      assert.equal((await mark()).status, 200);
      assert.equal((await db.query('select is_pending from messages where id=$1', [msg])).rows[0].is_pending, true);
      const own = await call(`/messages/pending/${ben}?device_id=${benDev}`);
      const other = await call(`/messages/pending/${ben}?device_id=${benOther}`);
      const sender = await call(`/messages/pending/${ana}?device_id=${anaDev}`, ana);
      assert.equal(own.status, 200); assert.equal(other.status, 200); assert.equal(sender.status, 200);
      assert.ok(!own.body.messages.some((m: any) => m.id === msg));
      assert.ok(other.body.messages.some((m: any) => m.id === msg));
      assert.ok(sender.body.messages.some((m: any) => m.id === msg));
    });
    await t.test('statement failure rolls the entire batch back and publishes nothing', async () => {
      await reset();
      await db.query(`create function fail_receipt() returns trigger language plpgsql as $$
        begin if new.message_id = '${fanout}'::uuid then raise exception 'injected failure'; end if;
        return new; end $$`);
      await db.query(`create trigger fail_receipt before insert on message_read_receipts
        for each row execute function fail_receipt()`);
      try {
        assert.equal((await mark([msg, fanout])).status, 500);
        assert.equal((await db.query('select * from message_read_receipts')).rows.length, 0);
        assert.equal(events.length, 0);
      } finally {
        await db.query('drop trigger fail_receipt on message_read_receipts');
        await db.query('drop function fail_receipt()');
      }
    });
    await t.test('concurrent receipt retries preserve one read row', async () => {
      await reset();
      const results = await Promise.all(Array.from({length: 12}, (_, i) => mark([msg], benDev, i % 2 ? 'read' : 'delivered')));
      assert.ok(results.every(r => r.status === 200));
      const {rows} = await db.query('select * from message_read_receipts');
      assert.equal(rows.length, 1); assert.equal(rows[0].status, 'read');
    });
    await t.test('revocation committed while a request waits prevents the receipt', async () => {
      await reset();
      const blocker = await db.connect();
      try {
        await blocker.query('begin');
        await blocker.query('update devices set revoked_at=now() where id=$1', [benDev]);
        const pending = mark();
        // Wait for a real lock wait, rather than assuming HTTP has reached the DB.
        const deadline = Date.now() + 3000;
        let waiting = false;
        while (Date.now() < deadline) {
          const {rows} = await db.query(`select 1 from pg_stat_activity where datname=current_database()
            and wait_event_type='Lock' and query like 'select 1 as one from devices%'`);
          if (rows.length) { waiting = true; break; }
          await new Promise(resolve => setTimeout(resolve, 10));
        }
        await blocker.query('commit');
        const result = await pending;
        assert.ok(waiting, 'request reached the device lock');
        assert.equal(result.status, 403);
        assert.equal((await db.query('select * from message_read_receipts')).rows.length, 0);
      } finally { await blocker.query('rollback'); blocker.release(); }
    });
  } finally {
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    (pool as any).query = originalQuery;
    (pool as any).connect = originalConnect;
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
  }
});
