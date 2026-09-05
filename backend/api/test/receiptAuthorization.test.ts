// ═══════════════════════════════════════════════════════════════════════════════════
// RECEIPTS ARE METADATA, AND METADATA IS STILL PRIVATE.
//
// routes/receipts.ts authenticated the caller and then trusted every id it was handed.
// Neither endpoint asked the one question that matters — "may THIS caller touch THIS
// message?" — so an authenticated account could, for any message id it could guess or
// observe:
//
//   1. WRITE a receipt for a conversation it is not in (forgery: the sender sees Delivered
//      or Seen for someone who was never a recipient).
//   2. Attribute that receipt to ANOTHER USER'S DEVICE, because device_id was read from
//      the body/query and never checked for ownership.
//   3. Clear `is_pending` on someone else's messages, which is the flag the offline fetch
//      uses — the recipient's device would never be handed them again.
//   4. READ the full receipt roster for any message: which users, which devices, and when
//      each delivered and read it.
//
// None of this decrypts anything — the ciphertext is untouched. It forges delivery state,
// leaks the social graph and per-device activity times, and can suppress delivery.
//
// These tests drive the REAL router over HTTP against an in-memory Postgres stand-in, in
// the style of callConference.test.ts. They deliberately do NOT re-implement the route's
// helpers: a test that copies the logic it is checking passes while production stays
// broken, which is exactly how this hole survived a test file about receipts already
// existing (receiptDevice.test.ts copies callerDeviceId).
// ═══════════════════════════════════════════════════════════════════════════════════
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'http';
import express from 'express';
import { randomUUID } from 'crypto';

import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { issueToken } from '../src/auth';
import receiptsRouter from '../src/routes/receipts';

redis.disconnect();
publisher.disconnect();

interface Row { [k: string]: any }

const db = {
  users: [] as Row[],
  devices: [] as Row[],
  conversations: [] as Row[],
  conversation_members: [] as Row[],
  messages: [] as Row[],
  message_read_receipts: [] as Row[],
  message_ciphertexts: [] as Row[],
};

const published: { channel: string; payload: any }[] = [];
const now = () => new Date().toISOString();

function resetDb() {
  for (const k of Object.keys(db) as (keyof typeof db)[]) db[k] = [];
  published.length = 0;
}

const normalizeSql = (s: string) => s.replace(/\s+/g, ' ').trim().toLowerCase();

/**
 * A small SQL interpreter over the tables above. Anything unrecognised THROWS: a silent
 * empty result would let a new query slip through unexercised, and in an authorization
 * test "returned nothing" and "was never asked" must not look the same.
 */
async function fakeQuery(text: string, params: any[] = []): Promise<{ rows: Row[] }> {
  const s = normalizeSql(text);
  const p = params ?? [];
  const rows = (r: Row[]) => ({ rows: r });

  if (s === 'begin' || s === 'commit' || s === 'rollback') return rows([]);

  // auth.ts: account liveness
  if (s.includes('deleted_at is null) as ok from users')) {
    const u = db.users.find((x) => x.id === p[0]);
    return rows(u ? [{ ok: !u.deleted_at }] : []);
  }

  // receipts.ts: device ownership
  if (s.startsWith('select 1 as one from devices where id =')) {
    return rows(
      db.devices
        .filter((d) => d.id === p[0] && d.user_id === p[1] && !d.revoked_at)
        .slice(0, 1)
        .map(() => ({ one: 1 }))
    );
  }

  // receipts.ts: which of these messages may the caller touch?
  if (s.includes('from messages m') && s.includes('conversation_members cm') && s.includes('= any(')) {
    const [ids, userId, deviceId] = p;
    const allowed = db.messages
      .filter(
        (m) =>
          ids.includes(m.id) &&
          (m.ciphertext != null || (s.includes('m.sender_id = $2') && m.sender_id === userId) || db.message_ciphertexts.some(c => c.message_id === m.id && c.recipient_device_id === deviceId)) &&
          db.conversation_members.some(
            (cm) => cm.conversation_id === m.conversation_id && cm.user_id === userId && !cm.left_at
          )
      )
      .map((m) => ({ id: m.id, sender_id: m.sender_id }));
    return rows(allowed);
  }

  // receipts.ts: the upsert
  if (s.startsWith('insert into message_read_receipts')) {
    const [ids, userId, deviceId, status] = p;
    const changed: Row[] = [];
    for (const mid of ids) {
      const existing = db.message_read_receipts.find(r =>
        r.message_id === mid && r.user_id === userId && r.device_id === deviceId);
      if (existing?.status === 'read') continue;
      if (existing) {
        existing.status = status;
        if (status === 'read') existing.read_at ??= now();
      } else {
        db.message_read_receipts.push({message_id: mid, user_id: userId,
          device_id: deviceId, status, delivered_at: now(), read_at: status === 'read' ? now() : null});
      }
      changed.push({message_id: mid, status});
    }
    return rows(changed);
  }

  // receipts.ts: clear is_pending
  if (s.startsWith('update messages set is_pending = false')) {
    const ids: string[] = p[0];
    for (const m of db.messages) if (ids.includes(m.id)) m.is_pending = false;
    return rows([]);
  }

  // receipts.ts: notify senders
  if (s.startsWith('select id, sender_id from messages')) {
    const [ids, notUser] = p;
    return rows(
      db.messages
        .filter((m) => ids.includes(m.id) && m.sender_id !== notUser)
        .map((m) => ({ id: m.id, sender_id: m.sender_id }))
    );
  }

  // receipts.ts: GET receipts for a message
  if (s.startsWith('select user_id, device_id, status, delivered_at, read_at')) {
    return rows(db.message_read_receipts.filter((r) => r.message_id === p[0]));
  }

  throw new Error(`fakeQuery: unrecognised SQL: ${s}`);
}

(pool as any).query = fakeQuery;
(pool as any).connect = async () => ({ query: fakeQuery, release() {} });
(publisher as any).publish = async (channel: string, payload: string) => {
  published.push({ channel, payload: JSON.parse(payload) });
  return 1;
};

const app = express();
app.use(express.json());
app.use('/receipts', receiptsRouter);

let server: http.Server;
let base = '';

test.before(async () => {
  await new Promise<void>((resolve) => {
    server = app.listen(0, '127.0.0.1', () => {
      base = `http://127.0.0.1:${(server.address() as any).port}`;
      resolve();
    });
  });
});
test.after(() => server?.close());

async function call(
  method: 'GET' | 'POST',
  urlPath: string,
  actor: { user: string; device?: string },
  body?: unknown
) {
  const token = issueToken(
    actor.device ? { user_id: actor.user, device_id: actor.device } : { user_id: actor.user }
  );
  const res = await fetch(`${base}${urlPath}`, {
    method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: method === 'POST' ? JSON.stringify(body ?? {}) : undefined,
  });
  return { status: res.status, body: (await res.json()) as any };
}

// ── the cast ───────────────────────────────────────────────────────────────────────
// ANA and BEN share a conversation. MAL is an authenticated account in neither.
const ANA = randomUUID(), BEN = randomUUID(), MAL = randomUUID();
const ANA_DEV = randomUUID(), BEN_DEV = randomUUID(), MAL_DEV = randomUUID();
const CONV = randomUUID();
let MSG: string;

function seed() {
  resetDb();
  db.users.push(
    { id: ANA, deleted_at: null }, { id: BEN, deleted_at: null }, { id: MAL, deleted_at: null }
  );
  db.devices.push(
    { id: ANA_DEV, user_id: ANA, revoked_at: null },
    { id: BEN_DEV, user_id: BEN, revoked_at: null },
    { id: MAL_DEV, user_id: MAL, revoked_at: null }
  );
  db.conversations.push({ id: CONV, type: 'direct' });
  db.conversation_members.push(
    { conversation_id: CONV, user_id: ANA, left_at: null },
    { conversation_id: CONV, user_id: BEN, left_at: null }
  );
  MSG = randomUUID();
  db.messages.push({
    id: MSG, conversation_id: CONV, sender_id: ANA, is_pending: true, ciphertext: Buffer.from("legacy"),
    delivered_at: null, created_at: now(),
  });
}

test('a member may mark a message in their own conversation', async () => {
  seed();
  const res = await call('POST', '/receipts/mark', { user: BEN }, {
    message_ids: [MSG], status: 'read', device_id: BEN_DEV,
  });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const r = db.message_read_receipts.find((x) => x.message_id === MSG && x.user_id === BEN);
  assert.ok(r, 'the receipt must be written');
  assert.equal(r!.status, 'read');
  assert.equal(r!.device_id, BEN_DEV);
  // The sender is told, so their ticks advance.
  assert.equal(published.filter((x) => x.channel === `channel:user:${ANA}`).length, 1);
});

test('a non-member cannot forge a receipt for a conversation they are not in', async () => {
  seed();
  const res = await call('POST', '/receipts/mark', { user: MAL }, {
    message_ids: [MSG], status: 'read', device_id: MAL_DEV,
  });
  assert.equal(res.status, 403, JSON.stringify(res.body));
  assert.equal(
    db.message_read_receipts.length, 0,
    'an unauthorized mark must write NO receipt'
  );
  assert.equal(
    published.length, 0,
    'and must not tell the sender their message was delivered'
  );
});

test('a non-member cannot clear is_pending on a message they do not own', async () => {
  seed();
  // is_pending is what the offline fetch uses. Clearing it for a device that never received
  // the message means that device is never handed it again — suppression, not just forgery.
  await call('POST', '/receipts/mark', { user: MAL }, {
    message_ids: [MSG], status: 'read', device_id: MAL_DEV,
  });
  assert.equal(
    db.messages.find((m) => m.id === MSG)!.is_pending, true,
    'a stranger must not be able to un-pend delivery'
  );
});

test('a receipt cannot be attributed to another user\'s device', async () => {
  seed();
  // Ben is a legitimate member, so membership alone would let this through. The device id
  // is the second half of the check: it is read from the body and must be proved to belong
  // to the caller, or a member can pin activity on someone else's hardware.
  const res = await call('POST', '/receipts/mark', { user: BEN }, {
    message_ids: [MSG], status: 'read', device_id: ANA_DEV,
  });
  assert.equal(res.status, 403, JSON.stringify(res.body));
  assert.equal(db.message_read_receipts.length, 0);
});

test('a mixed batch is refused whole, with no partial side effects', async () => {
  seed();
  // Ben may touch MSG. He may not touch a message in a conversation he is not in. The batch
  // must be all-or-nothing: a partial apply would let an attacker use one legitimate id as
  // a carrier for a hundred foreign ones.
  const foreign = randomUUID();
  db.conversations.push({ id: 'other-conv', type: 'direct' });
  db.messages.push({
    id: foreign, conversation_id: 'other-conv', sender_id: MAL, is_pending: true,
    delivered_at: null, created_at: now(),
  });
  const res = await call('POST', '/receipts/mark', { user: BEN }, {
    message_ids: [MSG, foreign], status: 'read', device_id: BEN_DEV,
  });
  assert.equal(res.status, 403, JSON.stringify(res.body));
  assert.equal(db.message_read_receipts.length, 0, 'not even the permitted id may be written');
  assert.equal(db.messages.find((m) => m.id === MSG)!.is_pending, true);
  assert.equal(db.messages.find((m) => m.id === foreign)!.is_pending, true);
});

test('the refusal does not disclose which foreign ids exist', async () => {
  seed();
  const real = randomUUID();
  db.messages.push({
    id: real, conversation_id: 'other-conv', sender_id: MAL, is_pending: true,
    delivered_at: null, created_at: now(),
  });
  const invented = randomUUID();

  const a = await call('POST', '/receipts/mark', { user: MAL }, {
    message_ids: [real], status: 'read', device_id: MAL_DEV,
  });
  const b = await call('POST', '/receipts/mark', { user: MAL }, {
    message_ids: [invented], status: 'read', device_id: MAL_DEV,
  });
  // Mal is in neither conversation. A message that EXISTS and one that does not must be
  // indistinguishable, or the endpoint is a message-id oracle.
  assert.equal(a.status, b.status);
  assert.deepEqual(a.body, b.body);
});

test('a stranger cannot read the receipt roster for a message', async () => {
  seed();
  // Seed a real receipt so there is something worth stealing: who read it, on which device,
  // and when.
  db.message_read_receipts.push({
    message_id: MSG, user_id: BEN, device_id: BEN_DEV,
    status: 'read', delivered_at: now(), read_at: now(),
  });
  const res = await call('GET', `/receipts/${MSG}`, { user: MAL });
  assert.equal(res.status, 403, JSON.stringify(res.body));
  assert.equal(res.body.receipts, undefined, 'no roster may leak in the body');
});

test('a member may still read the roster for their own conversation', async () => {
  seed();
  db.message_read_receipts.push({
    message_id: MSG, user_id: BEN, device_id: BEN_DEV,
    status: 'read', delivered_at: now(), read_at: now(),
  });
  const res = await call('GET', `/receipts/${MSG}`, { user: ANA });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.receipts.length, 1);
});

test('a former member loses both write and read access', async () => {
  seed();
  // left_at is the existing membership signal used across messages.ts; leaving must revoke
  // receipt access the same way it revokes everything else.
  const m = db.conversation_members.find((x) => x.user_id === BEN)!;
  m.left_at = now();

  const write = await call('POST', '/receipts/mark', { user: BEN }, {
    message_ids: [MSG], status: 'read', device_id: BEN_DEV,
  });
  assert.equal(write.status, 403);
  const read = await call('GET', `/receipts/${MSG}`, { user: BEN });
  assert.equal(read.status, 403);
});

test('a revoked device cannot write a receipt', async () => {
  seed();
  db.devices.find((d) => d.id === BEN_DEV)!.revoked_at = now();
  const res = await call('POST', '/receipts/mark', { user: BEN }, {
    message_ids: [MSG], status: 'read', device_id: BEN_DEV,
  });
  assert.equal(res.status, 403, JSON.stringify(res.body));
  assert.equal(db.message_read_receipts.length, 0);
});

test('retries stay safe: duplicate and out-of-order marks never downgrade', async () => {
  seed();
  await call('POST', '/receipts/mark', { user: BEN }, {
    message_ids: [MSG], status: 'read', device_id: BEN_DEV,
  });
  // A delayed 'delivered' arriving after the 'read' must not revert the tick, and a repeat
  // must not create a second row.
  await call('POST', '/receipts/mark', { user: BEN }, {
    message_ids: [MSG], status: 'delivered', device_id: BEN_DEV,
  });
  await call('POST', '/receipts/mark', { user: BEN }, {
    message_ids: [MSG], status: 'read', device_id: BEN_DEV,
  });
  const mine = db.message_read_receipts.filter((r) => r.message_id === MSG && r.user_id === BEN);
  assert.equal(mine.length, 1, 'one receipt row per (message, user, device)');
  assert.equal(mine[0].status, 'read', 'status only ever advances');
});


test('a revoked token device cannot bypass ownership on either endpoint', async () => {
  seed();
  db.devices.find(d => d.id === BEN_DEV)!.revoked_at = now();
  assert.equal((await call('POST', '/receipts/mark', {user: BEN, device: BEN_DEV}, {
    message_ids: [MSG], device_id: ANA_DEV,
  })).status, 403);
  assert.equal((await call('GET', `/receipts/${MSG}`, {user: BEN, device: BEN_DEV})).status, 403);
});

test('unknown and malformed device claims never fall back to NULL', async () => {
  seed();
  for (const device_id of [randomUUID(), '', 123, 'invalid']) {
    assert.equal((await call('POST', '/receipts/mark', {user: BEN}, {
      message_ids: [MSG], device_id,
    })).status, 403);
  }
  assert.equal(db.message_read_receipts.length, 0);
});

test('fanout receipts require an envelope addressed to the actual device', async () => {
  seed();
  db.messages[0].ciphertext = null;
  for (const device_id of [BEN_DEV, undefined]) {
    assert.equal((await call('POST', '/receipts/mark', {user: BEN}, {
      message_ids: [MSG], device_id,
    })).status, 403);
  }
  db.message_ciphertexts.push({message_id: MSG, recipient_device_id: BEN_DEV});
  assert.equal((await call('POST', '/receipts/mark', {user: BEN}, {
    message_ids: [MSG], device_id: BEN_DEV,
  })).status, 200);
});

test('a reader never clears shared pending state or emits a downgraded receipt', async () => {
  seed();
  for (const status of ['read', 'delivered', 'read']) {
    assert.equal((await call('POST', '/receipts/mark', {user: BEN}, {
      message_ids: [MSG, MSG.toUpperCase()], device_id: BEN_DEV, status,
    })).status, 200);
  }
  assert.equal(db.messages[0].is_pending, true);
  assert.equal(published.length, 1);
  assert.equal(published[0].payload.status, 'read');
});

test('legacy NULL-device retries and sender-linked receipts stay valid', async () => {
  seed();
  for (const status of ['read', 'delivered', 'read']) {
    assert.equal((await call('POST', '/receipts/mark', {user: BEN}, {
      message_ids: [MSG], status,
    })).status, 200);
  }
  assert.equal(db.message_read_receipts.length, 1);
  assert.equal(db.message_read_receipts[0].status, 'read');
  published.length = 0;
  assert.equal((await call('POST', '/receipts/mark', {user: ANA, device: ANA_DEV}, {
    message_ids: [MSG], device_id: BEN_DEV,
  })).status, 200);
  assert.equal(db.message_read_receipts[1].device_id, ANA_DEV);
  assert.equal(published.length, 0);
});

test('receipt batch limits reject malformed, empty and excessive requests', async () => {
  seed();
  for (const message_ids of [[], ['invalid'], Array(501).fill(MSG)]) {
    assert.equal((await call('POST', '/receipts/mark', {user: BEN}, {message_ids})).status, 400);
  }
  assert.equal(db.message_read_receipts.length, 0);
});
