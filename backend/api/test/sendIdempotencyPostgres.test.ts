// M01 — atomic, retry-safe message acceptance, against the real router and real PostgreSQL.
// SEND_TEST_DATABASE_URL=postgres://.../voiid_test_send npx tsx --test test/sendIdempotencyPostgres.test.ts
//
// Its own database, not just its own schema: every DB-backed suite replays the full migration
// set and `create extension` is database-scoped, so two of them in one database race.
//
// WHAT THIS IS ABOUT. A send that is accepted and then not acknowledged — the reply is lost,
// the socket dies, the app is killed — is retried by the client. Without a stable id from the
// client, that retry is a NEW message: the recipient sees the same thing twice and the sender
// cannot tell which one landed. And a Redis failure after the row was committed meant the
// message existed but nobody was ever told about it.
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
const url = process.env.SEND_TEST_DATABASE_URL;

test('atomic, retry-safe send against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `send_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });

  // Statements recorded PER CONNECTION, so the send's own transaction can be measured on its
  // own. A global counter also picks up the fire-and-forget wake lookups and anything still
  // settling from an earlier request, which says nothing about what one send costs.
  let transactions: string[][] = [];
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = (...args: any[]) => (db as any).query(...args);
  (pool as any).connect = async () => {
    const client = await db.connect();
    const inner = client.query.bind(client);
    const sqls: string[] = [];
    (client as any).query = (...args: any[]) => { sqls.push(String(args[0])); return inner(...args); };
    const release = client.release.bind(client);
    (client as any).release = (...args: any[]) => { transactions.push(sqls); return release(...args); };
    return client;
  };

  let published: any[] = [];
  let publishFails = false;
  (publisher as any).publish = async (_channel: string, payload: string) => {
    if (publishFails) throw new Error('redis is down');
    published.push(JSON.parse(payload));
    return 1;
  };

  const app = express();
  app.use(express.json());
  app.use('/messages', messagesRouter);
  app.use((_e: unknown, _req: any, res: any, _next: any) => res.status(500).json({ error: 'test failure' }));
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>((done) => server.once('listening', () => done()));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;

  const ana = randomUUID(), ben = randomUUID();
  const anaDev = randomUUID(), benDev = randomUUID(), benOther = randomUUID();
  const conv = randomUUID();
  const CIPHER = Buffer.from('opaque').toString('base64');

  async function send(body: any, user = ana, device = anaDev) {
    const response = await fetch(`${base}/messages/send`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${issueToken({ user_id: user, device_id: device })}` },
      body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json().catch(() => ({})) as any };
  }
  const fanout = (clientId: string, cipher = CIPHER) => ({
    conversation_id: conv,
    client_message_id: clientId,
    sender_device_id: anaDev,
    messages: [{ recipient_device_id: benDev, ciphertext: cipher }],
  });
  const countMessages = async () =>
    Number((await db.query('select count(*)::int as n from messages')).rows[0].n);
  const outboxRows = async (messageId: string) =>
    (await db.query('select * from message_outbox where message_id=$1 order by channel', [messageId])).rows;

  async function reset() {
    published = []; publishFails = false; transactions = [];
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
      await db.query('insert into users(id, phone_number) values($1,$2)', [id, `+1999000500${i}`]);
    }
    for (const [i, [id, owner]] of [[anaDev, ana], [benDev, ben], [benOther, ben]].entries()) {
      await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
        values($1,$2,'test',$3,$4)`, [id, owner, i, Buffer.from('key')]);
    }
    await db.query("insert into conversations(id, type) values($1,'group')", [conv]);
    for (const id of [ana, ben]) {
      await db.query('insert into conversation_members(conversation_id,user_id) values($1,$2)', [conv, id]);
    }

    await t.test('an identical retry returns the first message rather than sending a second', async () => {
      await reset();
      const key = randomUUID();
      const first = await send(fanout(key));
      assert.equal(first.status, 200, JSON.stringify(first.body));
      assert.notEqual(first.body.duplicate, true);

      const retry = await send(fanout(key));
      assert.equal(retry.status, 200, JSON.stringify(retry.body));
      assert.equal(retry.body.duplicate, true, 'the retry is recognised, not re-sent');
      assert.equal(retry.body.message_id, first.body.message_id, 'and answers with the SAME message');
      assert.equal(await countMessages(), 1, 'one bubble, not two');
      assert.equal(
        Number((await db.query('select count(*)::int as n from message_ciphertexts')).rows[0].n), 1);
    });

    await t.test('the same key with a different payload is refused, not silently accepted', async () => {
      await reset();
      const key = randomUUID();
      assert.equal((await send(fanout(key))).status, 200);
      const first = (await db.query('select id from messages')).rows[0].id;
      const different = await send(fanout(key, Buffer.from('a different secret').toString('base64')));
      assert.equal(different.status, 409);
      assert.equal(different.body.code, 'idempotency_key_reuse');
      assert.equal(await countMessages(), 1, 'the second payload was not stored');
      // The conflict has to say WHICH message the key already produced. A client that
      // re-encrypts on retry (Olm advances the ratchet, so the bytes differ) lands here on a
      // perfectly legitimate retry, and this is how it learns its send already succeeded.
      assert.equal(different.body.message_id, first);
      assert.equal(different.body.delivered_devices, 1);
    });

    await t.test('concurrent retries of one send produce exactly one message', async () => {
      await reset();
      const key = randomUUID();
      const results = await Promise.all(Array.from({ length: 8 }, () => send(fanout(key))));
      assert.ok(results.every((r) => r.status === 200), results.map((r) => r.status).join(','));
      const ids = new Set(results.map((r) => r.body.message_id));
      assert.equal(ids.size, 1, 'every caller was told about the same message');
      assert.equal(await countMessages(), 1);
    });

    await t.test('concurrent reuse with different ciphertext returns a conflict', async () => {
      await reset();
      const key = randomUUID();
      // Delay insertion so both independent requests complete their initial not-found probe.
      await db.query(`create function delay_send() returns trigger language plpgsql as $$
        begin perform pg_sleep(0.1); return new; end $$`);
      await db.query('create trigger delay_send before insert on messages for each row execute function delay_send()');
      try {
        const results = await Promise.all([send(fanout(key)), send(fanout(key, Buffer.from('different payload').toString('base64')))]);
        assert.deepEqual(results.map(r => r.status).sort(), [200, 409]);
        assert.equal(results.find(r => r.status === 409)?.body.code, 'idempotency_key_reuse');
        assert.equal(await countMessages(), 1);
      } finally {
        await db.query('drop trigger delay_send on messages');
        await db.query('drop function delay_send()');
      }
    });

    await t.test('a failure before commit leaves no message, no ciphertext and no notification', async () => {
      await reset();
      await db.query(`create function fail_ct() returns trigger language plpgsql as $$
        begin raise exception 'injected ciphertext failure'; end $$`);
      await db.query(`create trigger fail_ct before insert on message_ciphertexts
        for each row execute function fail_ct()`);
      try {
        const key = randomUUID();
        assert.equal((await send(fanout(key))).status, 500);
        assert.equal(await countMessages(), 0, 'the metadata rolled back with the ciphertext');
        assert.equal(Number((await db.query('select count(*)::int as n from message_outbox')).rows[0].n), 0);
        assert.equal(published.length, 0, 'nothing was announced for a message that does not exist');

        // And the key is free: the send never happened, so retrying it must be a fresh send.
        await db.query('drop trigger fail_ct on message_ciphertexts');
        const retry = await send(fanout(key));
        assert.equal(retry.status, 200);
        assert.notEqual(retry.body.duplicate, true, 'a rolled-back attempt does not burn the key');
        assert.equal(await countMessages(), 1);
      } finally {
        await db.query('drop trigger if exists fail_ct on message_ciphertexts');
        await db.query('drop function fail_ct()');
      }
    });

    await t.test('a Redis outage does not corrupt acceptance; the notification stays owed', async () => {
      await reset();
      publishFails = true;
      const sent = await send(fanout(randomUUID()));
      assert.equal(sent.status, 200, 'the message is accepted even though nobody could be told');
      assert.equal(await countMessages(), 1);

      // THE DURABLE PART. The publish failed, so the obligation to announce this message must
      // survive in the database for the worker to pick up — otherwise the message exists and
      // no device is ever told it does.
      const rows = await outboxRows(sent.body.message_id);
      assert.ok(rows.length >= 1, 'an outbox row per recipient channel');
      assert.ok(rows.every((r: any) => r.status === 'pending'), 'still owed');
      assert.ok(rows.some((r: any) => r.channel === `channel:user:${ben}`));
    });

    await t.test('a successful send publishes and settles its outbox in the same breath', async () => {
      await reset();
      const sent = await send(fanout(randomUUID()));
      assert.equal(sent.status, 200);
      const rows = await outboxRows(sent.body.message_id);
      assert.ok(rows.length >= 1);
      assert.ok(rows.every((r: any) => r.status === 'published'), 'nothing left owed on the happy path');
      assert.ok(published.some((p) => p.message_id === sent.body.message_id && p.type === 'message'));
    });

    await t.test('the legacy single-ciphertext path is idempotent too', async () => {
      await reset();
      const key = randomUUID();
      const legacy = { conversation_id: conv, ciphertext: CIPHER, client_message_id: key, device_id: anaDev };
      const first = await send(legacy);
      assert.equal(first.status, 200, JSON.stringify(first.body));
      const retry = await send(legacy);
      assert.equal(retry.status, 200);
      assert.equal(retry.body.duplicate, true);
      assert.equal(retry.body.message_id, first.body.message_id);
      assert.equal(await countMessages(), 1);
    });

    await t.test('a send with no client id still works, for clients that predate this', async () => {
      await reset();
      const one = await send({ conversation_id: conv, sender_device_id: anaDev,
        messages: [{ recipient_device_id: benDev, ciphertext: CIPHER }] });
      const two = await send({ conversation_id: conv, sender_device_id: anaDev,
        messages: [{ recipient_device_id: benDev, ciphertext: CIPHER }] });
      assert.equal(one.status, 200); assert.equal(two.status, 200);
      // Two distinct sends, because without a key there is nothing to recognise them by.
      // That is the pre-M01 behaviour, kept working rather than made to fail.
      assert.notEqual(one.body.message_id, two.body.message_id);
      assert.equal(await countMessages(), 2);
    });

    await t.test('fan-out cost does not grow one round trip per device', async () => {
      await reset();
      const extra: string[] = [];
      for (let i = 0; i < 40; i++) {
        const id = randomUUID();
        await db.query(`insert into devices(id,user_id,platform,registration_id,identity_public_key)
          values($1,$2,'test',$3,$4)`, [id, ben, 100 + i, Buffer.from('key')]);
        extra.push(id);
      }

      async function costOf(targets: string[]): Promise<{ statements: number; inserts: number }> {
        transactions = [];
        const sent = await send({
          conversation_id: conv, sender_device_id: anaDev, client_message_id: randomUUID(),
          messages: targets.map((id) => ({ recipient_device_id: id, ciphertext: CIPHER })),
        });
        assert.equal(sent.status, 200, JSON.stringify(sent.body));
        assert.equal(sent.body.delivered_devices, targets.length);
        // The send's own transaction is the longest statement list it took a connection out for.
        const txn = transactions.reduce((a, b) => (b.length > a.length ? b : a), [] as string[]);
        return {
          statements: txn.length,
          inserts: txn.filter((sql) => /insert into message_ciphertexts/i.test(sql)).length,
        };
      }

      const few = await costOf(extra.slice(0, 5));
      const many = await costOf(extra);
      // GROWTH is the property. Constant per-send overhead — membership, announcement,
      // blocking, outbox — is irrelevant, and pinning an absolute number would only make the
      // threshold arbitrary. Eight times the devices must not mean more statements.
      assert.equal(many.statements, few.statements,
        `fan-out cost grew with device count: ${few.statements} statements for 5 devices, ${many.statements} for 40`);
      // And the blobs land in ONE statement, which is the specific thing M01 asks for.
      assert.equal(many.inserts, 1, 'the ciphertext bundle is a single insert');
      assert.equal(
        Number((await db.query('select count(*)::int as n from message_ciphertexts')).rows[0].n), 45);
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
