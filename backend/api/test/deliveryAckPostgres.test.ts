// M02 — a message is delivered when the DEVICE says so, not when the server sends bytes.
// ACK_TEST_DATABASE_URL=postgres://.../voiid_test_ack npx tsx --test test/deliveryAckPostgres.test.ts
//
// Its own database, not just its own schema: every DB-backed suite replays the full migration
// set and `create extension` is database-scoped, so two of them in one database race.
//
// THE FAILURE. GET /messages/pending stamped `delivered_at` in the same statement that read
// the ciphertext, and committed before the response left the process. Cut the socket, kill the
// app, fail the disk write — the row is marked delivered, the next fetch omits it, and the
// message is gone with no error anywhere. Fetch is now non-destructive and the device
// acknowledges only what it has actually stored.
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
const url = process.env.ACK_TEST_DATABASE_URL;

test('delivery acknowledgement against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `ack_test_${randomUUID().replaceAll('-', '')}`;
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

  const ana = randomUUID(), ben = randomUUID();
  const anaDev = randomUUID(), benPhone = randomUUID(), benTablet = randomUUID();
  const conv = randomUUID();
  const CIPHER = Buffer.from('opaque').toString('base64');

  async function call(method: string, path: string, user: string, device: string | undefined, body?: any) {
    const response = await fetch(`${base}${path}`, {
      method,
      headers: { 'content-type': 'application/json', authorization: `Bearer ${issueToken({ user_id: user, device_id: device })}` },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: response.status, body: await response.json().catch(() => ({})) as any };
  }
  const pendingFor = (device: string) => call('GET', `/messages/pending/${ben}?device_id=${device}`, ben, device);
  const ack = (device: string | undefined, ids: string[], user = ben) =>
    call('POST', '/messages/ack', user, device, { device_id: device, message_ids: ids });

  async function fanoutTo(devices: string[]): Promise<string> {
    const sent = await call('POST', '/messages/send', ana, anaDev, {
      conversation_id: conv, sender_device_id: anaDev, client_message_id: randomUUID(),
      messages: devices.map((d) => ({ recipient_device_id: d, ciphertext: CIPHER })),
    });
    assert.equal(sent.status, 200, JSON.stringify(sent.body));
    return sent.body.message_id;
  }
  async function legacyMessage(): Promise<string> {
    const sent = await call('POST', '/messages/send', ana, anaDev, {
      conversation_id: conv, ciphertext: CIPHER, device_id: anaDev, client_message_id: randomUUID(),
    });
    assert.equal(sent.status, 200, JSON.stringify(sent.body));
    return sent.body.message_id;
  }
  const deliveredAt = async (messageId: string, device: string) =>
    (await db.query('select delivered_at from message_ciphertexts where message_id=$1 and recipient_device_id=$2',
      [messageId, device])).rows[0]?.delivered_at;
  const has = (body: any, id: string) => body.messages.some((m: any) => m.id === id);

  async function reset() {
    await db.query('delete from message_deliveries');
    await db.query('delete from message_read_receipts');
    await db.query('delete from message_outbox');
    await db.query('delete from message_ciphertexts');
    await db.query('delete from messages');
  }

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    for (const [i, id] of [ana, ben].entries()) {
      await db.query('insert into users(id, phone_number) values($1,$2)', [id, `+1999000700${i}`]);
    }
    for (const [i, [id, owner]] of [[anaDev, ana], [benPhone, ben], [benTablet, ben]].entries()) {
      await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
        values($1,$2,'test',$3,$4)`, [id, owner, i, Buffer.from('key')]);
    }
    await db.query("insert into conversations(id, type) values($1,'group')", [conv]);
    for (const id of [ana, ben]) {
      await db.query('insert into conversation_members(conversation_id,user_id) values($1,$2)', [conv, id]);
    }

    await t.test('fetching does not deliver; the message survives a fetch that never arrived', async () => {
      await reset();
      const id = await fanoutTo([benPhone]);

      // The device asked, and the response was lost on the way back.
      const first = await pendingFor(benPhone);
      assert.equal(first.status, 200);
      assert.ok(has(first.body, id));
      assert.equal(await deliveredAt(id, benPhone), null, 'reading is not delivering');

      // It asks again. THIS is the case the old code lost: the row had been stamped
      // delivered by the fetch that never reached the device.
      const second = await pendingFor(benPhone);
      assert.ok(has(second.body, id), 'still pending until the device says otherwise');
    });

    await t.test('an acknowledgement is what settles it, and it settles exactly once', async () => {
      await reset();
      const id = await fanoutTo([benPhone]);
      assert.ok(has((await pendingFor(benPhone)).body, id));

      const acked = await ack(benPhone, [id]);
      assert.equal(acked.status, 200, JSON.stringify(acked.body));
      assert.equal(acked.body.acknowledged, 1);
      const at = await deliveredAt(id, benPhone);
      assert.ok(at, 'the device stored it, so now it is delivered');

      assert.ok(!has((await pendingFor(benPhone)).body, id), 'and it stops being pending');

      // Replaying the batch is safe and does not move the timestamp.
      const replay = await ack(benPhone, [id, id]);
      assert.equal(replay.status, 200);
      assert.equal((await deliveredAt(id, benPhone)).getTime(), at.getTime(), 'idempotent');
    });

    await t.test("one device's acknowledgement leaves the other device's copy pending", async () => {
      await reset();
      const id = await fanoutTo([benPhone, benTablet]);
      assert.equal((await ack(benPhone, [id])).body.acknowledged, 1);
      assert.ok(!has((await pendingFor(benPhone)).body, id));
      assert.ok(has((await pendingFor(benTablet)).body, id), 'the tablet has not stored it yet');
      assert.equal(await deliveredAt(id, benTablet), null);
    });

    await t.test('a device cannot acknowledge for another device, or another account', async () => {
      await reset();
      const id = await fanoutTo([benPhone, benTablet]);
      // Ana is not the recipient at all.
      assert.equal((await ack(anaDev, [id], ana)).body.acknowledged, 0);
      assert.equal(await deliveredAt(id, benPhone), null);
      // Ben's phone naming Ben's tablet: the ack is scoped to the authenticated device.
      const crossDevice = await call('POST', '/messages/ack', ben, benPhone,
        { device_id: benTablet, message_ids: [id] });
      assert.equal(crossDevice.status, 403);
      assert.equal(await deliveredAt(id, benTablet), null, "the tablet's copy is untouched");
      // A device that is not the caller's at all.
      assert.equal((await call('POST', '/messages/ack', ben, benPhone,
        { device_id: anaDev, message_ids: [id] })).status, 403);
    });

    await t.test('history no longer marks anything delivered as a side effect of reading it', async () => {
      await reset();
      const id = await fanoutTo([benPhone]);
      const history = await call('GET', `/messages/conversation/${conv}?device_id=${benPhone}`, ben, benPhone);
      assert.equal(history.status, 200);
      assert.ok(history.body.messages.some((m: any) => m.id === id));
      assert.equal(await deliveredAt(id, benPhone), null, 'scrolling is not receiving');
      assert.ok(has((await pendingFor(benPhone)).body, id), 'and it is still owed to the device');
    });

    await t.test('a legacy message is tracked per recipient device, not by one shared bit', async () => {
      await reset();
      const id = await legacyMessage();
      assert.ok(has((await pendingFor(benPhone)).body, id));
      assert.ok(has((await pendingFor(benTablet)).body, id));

      assert.equal((await ack(benPhone, [id])).body.acknowledged, 1);
      assert.ok(!has((await pendingFor(benPhone)).body, id));
      // THE SHARED-BIT BUG: one device acknowledging used to clear the message for everyone.
      assert.ok(has((await pendingFor(benTablet)).body, id), 'the tablet still needs it');
      assert.equal(
        Number((await db.query('select count(*)::int as n from message_deliveries')).rows[0].n), 1);
    });

    await t.test('acknowledging a message the caller was never sent changes nothing', async () => {
      await reset();
      const mine = await fanoutTo([benPhone]);
      const stranger = randomUUID();
      const result = await ack(benPhone, [stranger, mine]);
      assert.equal(result.status, 200);
      assert.equal(result.body.acknowledged, 1, 'only the one actually addressed to this device');
      assert.ok(await deliveredAt(mine, benPhone));
    });

    await t.test('a malformed batch is refused rather than partly applied', async () => {
      await reset();
      const id = await fanoutTo([benPhone]);
      for (const ids of [['not-a-uuid'], [id, 'not-a-uuid'], [42 as any], 'nope' as any]) {
        const bad = await call('POST', '/messages/ack', ben, benPhone, { device_id: benPhone, message_ids: ids });
        assert.equal(bad.status, 400, JSON.stringify(bad.body));
      }
      assert.equal(await deliveredAt(id, benPhone), null, 'nothing was applied');
    });

    await t.test('retention rules for delivered and undelivered ciphertext are declared', async () => {
      const { rows } = await db.query(
        `select table_name, retention_basis, enforced_by, sweep_rule
           from data_retention_policy where table_name in ('message_ciphertexts','message_deliveries')
          order by table_name`
      );
      assert.equal(rows.length, 2, 'both tables carry an explicit, reviewable policy');
      assert.ok(rows.every((r: any) => r.sweep_rule && r.sweep_rule.length > 40));
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
