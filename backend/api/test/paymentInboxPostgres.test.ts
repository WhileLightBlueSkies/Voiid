// C01 — the payment webhook inbox, against the real routers and real PostgreSQL.
// SESSION_TEST_DATABASE_URL=postgres://.../voiid_test_payments npx tsx --test test/paymentInboxPostgres.test.ts
//
// Every scenario here is about MONEY THAT HAS ALREADY MOVED. The provider has taken the
// buyer's money before it tells us; if this endpoint loses the delivery, the buyer has paid
// and holds no ticket, and no retry will ever fix it because the delivery ledger says the
// event was handled. That is the failure this file pins.
//
// Never point this at Supabase. The guard below refuses anything that is not a loopback host
// with a disposable `voiid_test_*` database.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';
import express from 'express';

process.env.NODE_ENV = 'test';
process.env.VOIID_PAYMENT_PROVIDER = 'testpay';

import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { issueToken } from '../src/auth';
import { register as registerProvider } from '../src/payments/provider';
import type { PaymentProvider, WebhookVerdict } from '../src/payments/provider';
import paymentsRouter from '../src/routes/payments';
import eventsRouter from '../src/routes/events';

redis.disconnect();
publisher.disconnect();
const url = process.env.PAYMENTS_TEST_DATABASE_URL;

/**
 * A provider whose "signature" is a fixed header and whose verdict is whatever the body says.
 * Deliberately trivial: razorpayWebhook.test.ts already pins real signature verification, and
 * what THIS file is testing is what the route does with a verdict once it has one.
 */
let nextCheckoutRef = 'ref_unused';
const testProvider: PaymentProvider = {
  name: 'testpay',
  async createCheckout() {
    return { providerRef: nextCheckoutRef, clientPayload: { ok: true } };
  },
  verifyWebhook(raw: Buffer, headers: Record<string, unknown>): WebhookVerdict {
    if (headers['x-test-signature'] !== 'good') return { ok: false };
    const body = JSON.parse(raw.toString());
    return {
      ok: true,
      eventId: body.event_id,
      eventType: body.type ?? 'test.event',
      providerRef: body.ref,
      outcome: body.outcome,
      reason: body.reason,
      amountMinor: body.amount,
      currency: body.currency,
      payload: body,
    };
  },
};
registerProvider(testProvider);

test('payment webhook inbox against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `payments_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db);
  (pool as any).connect = db.connect.bind(db);

  const app = express();
  app.use(paymentsRouter);            // raw body, BEFORE json — the ordering is load-bearing
  app.use(express.json());
  app.use(eventsRouter);
  app.use((_e: unknown, _req: any, res: any, _next: any) => res.status(500).json({ error: 'test failure' }));
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>((done) => server.once('listening', () => done()));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;

  const organiser = randomUUID(), buyer = randomUUID();
  const community = randomUUID(), festival = randomUUID();
  const PRICE = 25_000; // minor units

  interface Delivery {
    event_id?: string; ref: string; outcome?: string;
    amount?: number; currency?: string; reason?: string; type?: string;
  }
  async function deliver(body: Delivery, signature = 'good') {
    const payload = { event_id: `evt_${randomUUID()}`, currency: 'INR', ...body };
    const response = await fetch(`${base}/payments/webhook/testpay`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-signature': signature },
      body: JSON.stringify(payload),
    });
    return { status: response.status, body: await response.json().catch(() => ({})) as any, sent: payload };
  }

  // A pending order, written directly: how the row was created is not what these tests are
  // about, and every path that creates one produces this same shape.
  //
  // A FRESH BUYER EACH TIME, because 032 puts a partial unique index on (event_id, buyer_id)
  // for live orders — one person cannot hold two. That is the correct product rule and it
  // would otherwise make these scenarios collide with each other rather than with the code.
  // It also leaves the shared `buyer` free for the reconciliation test, which needs the real
  // ordering route.
  let refSeed = 0;
  async function pendingOrder(quantity = 1) {
    const id = randomUUID();
    const holder = randomUUID();
    const ref = `ref_${++refSeed}_${randomUUID().slice(0, 8)}`;
    await db.query('insert into users(id, phone_number) values($1,$2)', [holder, `+1999100${String(refSeed).padStart(4, '0')}`]);
    await db.query(
      `insert into event_orders (id, event_id, buyer_id, quantity, unit_price_minor, amount_minor,
                                 currency, provider, provider_ref, status)
       values ($1, $2, $3, $4, $5, $6, 'INR', 'testpay', $7, 'pending')`,
      [id, festival, holder, quantity, PRICE, PRICE * quantity, ref]
    );
    return { id, ref, quantity, holder };
  }
  const orderStatus = async (id: string) =>
    (await db.query('select status from event_orders where id=$1', [id])).rows[0]?.status;
  const ticketsFor = async (id: string) =>
    (await db.query('select state from event_tickets where order_id=$1', [id])).rows;
  const deliveryRow = async (eventId: string) =>
    (await db.query('select * from payment_webhook_events where provider_event_id=$1', [eventId])).rows[0];

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    for (const [i, id] of [organiser, buyer].entries()) {
      await db.query('insert into users(id, phone_number) values($1,$2)', [id, `+1999000300${i}`]);
    }
    await db.query('insert into communities(id, owner_id, handle, name) values($1,$2,$3,$4)',
      [community, organiser, `pay_test_${refSeed}`, 'Payments Test']);
    for (const [id, role] of [[organiser, 'owner'], [buyer, 'member']]) {
      await db.query(`insert into community_members(community_id,user_id,role,state)
        values($1,$2,$3,'active')`, [community, id, role]);
    }
    await db.query(
      `insert into community_events(id, community_id, title, starts_at, price_minor, currency, status, created_by)
       values($1,$2,'Rooftop Set', now() + interval '30 days', $3, 'INR', 'published', $4)`,
      [festival, community, PRICE, organiser]
    );

    await t.test('a delivery that dies mid-settlement is retried, not swallowed as a duplicate', async () => {
      const order = await pendingOrder(2);
      // A failure AFTER the delivery has been claimed and the order moved — the exact window
      // where the money is gone and the tickets are not yet minted.
      await db.query(`create function fail_tickets() returns trigger language plpgsql as $$
        begin raise exception 'injected ticket failure'; end $$`);
      await db.query(`create trigger fail_tickets before insert on event_tickets
        for each row execute function fail_tickets()`);
      let first: Awaited<ReturnType<typeof deliver>>;
      try {
        first = await deliver({ ref: order.ref, outcome: 'paid', amount: PRICE * 2, type: 'order.paid' });
        assert.equal(first.status, 500, 'the provider must be told to retry');
        assert.equal(await orderStatus(order.id), 'pending', 'no half-settled order');
        assert.equal((await ticketsFor(order.id)).length, 0);
        const row = await deliveryRow(first.sent.event_id);
        assert.equal(row.status, 'failed', 'recorded as retryable, not processed');
        assert.equal(row.processed_at, null);
      } finally {
        await db.query('drop trigger fail_tickets on event_tickets');
        await db.query('drop function fail_tickets()');
      }

      // THE FIX. Re-delivering the SAME event id used to return { duplicate: true } and leave
      // the buyer paid with no ticket, permanently.
      const retry = await deliver({ ...first!.sent });
      assert.equal(retry.status, 200, JSON.stringify(retry.body));
      assert.notEqual(retry.body.duplicate, true);
      assert.equal(await orderStatus(order.id), 'paid');
      assert.equal((await ticketsFor(order.id)).length, 2, 'exactly the ordered quantity');
      assert.equal((await deliveryRow(first!.sent.event_id)).status, 'processed');
    });

    await t.test('concurrent deliveries of one event mint exactly one ticket set', async () => {
      const order = await pendingOrder(3);
      const one = { event_id: `evt_${randomUUID()}`, ref: order.ref, outcome: 'paid', amount: PRICE * 3, currency: 'INR' };
      const results = await Promise.all(Array.from({ length: 8 }, () => deliver(one)));
      // Every answer is final: settled, already settled, or "someone else holds the lease".
      assert.ok(results.every((r) => r.status === 200 || r.status === 409),
        `unexpected statuses: ${results.map((r) => r.status).join(',')}`);
      // Exactly ONE delivery did the work. Without this the test would still pass if the
      // requests happened to serialise and each one re-settled a already-paid order.
      const settlers = results.filter((r) => r.status === 200 && r.body.duplicate !== true);
      assert.equal(settlers.length, 1, 'exactly one handler settled the order');
      assert.ok(results.length - settlers.length > 0, 'the rest were refused or deduplicated');
      assert.equal(await orderStatus(order.id), 'paid');
      assert.equal((await ticketsFor(order.id)).length, 3, 'no double mint');
      const rows = await db.query('select * from payment_webhook_events where provider_event_id=$1', [one.event_id]);
      assert.equal(rows.rows.length, 1, 'one delivery, one ledger row');
      assert.equal(rows.rows[0].status, 'processed');
    });

    await t.test('a webhook arriving before its order is held, then reconciled when the order appears', async () => {
      const ref = `ref_early_${randomUUID().slice(0, 8)}`;
      const early = await deliver({ ref, outcome: 'paid', amount: PRICE, type: 'order.paid' });
      assert.equal(early.status, 200);
      assert.equal(early.body.unmatched, true);
      const held = await deliveryRow(early.sent.event_id);
      assert.equal(held.status, 'unmatched', 'held for reconciliation, not marked processed');
      assert.equal(held.provider_ref, ref, 'the reference is kept so the order can find it later');
      assert.equal(held.processed_at, null);

      // Now the order lands, through the real route, carrying that same reference.
      nextCheckoutRef = ref;
      const created = await fetch(`${base}/events/${festival}/orders`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${issueToken({ user_id: buyer })}` },
        body: JSON.stringify({ quantity: 1 }),
      });
      const body = await created.json() as any;
      assert.equal(created.status, 201, JSON.stringify(body));

      assert.equal(await orderStatus(body.order.id), 'paid', 'the held payment settles the new order');
      assert.equal((await ticketsFor(body.order.id)).length, 1);
      assert.equal((await deliveryRow(early.sent.event_id)).status, 'processed');
      await db.query(`delete from event_orders where id=$1`, [body.order.id]).catch(() => {});
    });

    await t.test('a refund that arrives before the payment wins, and the later payment mints nothing', async () => {
      const order = await pendingOrder(2);
      const refund = await deliver({ ref: order.ref, outcome: 'refunded', type: 'refund.processed' });
      assert.equal(refund.status, 200);
      assert.equal(await orderStatus(order.id), 'refunded', 'a refund is terminal whenever it lands');

      const late = await deliver({ ref: order.ref, outcome: 'paid', amount: PRICE * 2, type: 'order.paid' });
      assert.equal(late.status, 200);
      assert.equal(await orderStatus(order.id), 'refunded');
      assert.equal((await ticketsFor(order.id)).length, 0, 'a refunded order never mints');
    });

    await t.test('a refund after payment voids the tickets it issued', async () => {
      const order = await pendingOrder(2);
      await deliver({ ref: order.ref, outcome: 'paid', amount: PRICE * 2 });
      assert.equal((await ticketsFor(order.id)).length, 2);
      await deliver({ ref: order.ref, outcome: 'refunded' });
      assert.equal(await orderStatus(order.id), 'refunded');
      assert.ok((await ticketsFor(order.id)).every((t: any) => t.state === 'void'));
    });

    await t.test('an underpayment mints nothing and says why', async () => {
      const order = await pendingOrder(2);
      const short = await deliver({ ref: order.ref, outcome: 'paid', amount: PRICE });
      assert.equal(short.status, 200);
      assert.equal(await orderStatus(order.id), 'failed');
      assert.equal((await ticketsFor(order.id)).length, 0);
      const { rows } = await db.query('select failure_reason from event_orders where id=$1', [order.id]);
      assert.match(rows[0].failure_reason, /underpaid/);
    });

    await t.test('a duplicate of a processed delivery changes nothing', async () => {
      const order = await pendingOrder(1);
      const paid = await deliver({ ref: order.ref, outcome: 'paid', amount: PRICE });
      assert.equal(paid.status, 200);
      const again = await deliver({ ...paid.sent });
      assert.equal(again.status, 200);
      assert.equal(again.body.duplicate, true);
      assert.equal((await ticketsFor(order.id)).length, 1);
    });

    await t.test('an unverified delivery is recorded nowhere', async () => {
      const order = await pendingOrder(1);
      const forged = await deliver({ ref: order.ref, outcome: 'paid', amount: PRICE }, 'bad');
      assert.equal(forged.status, 400);
      assert.equal(await deliveryRow(forged.sent.event_id), undefined);
      assert.equal(await orderStatus(order.id), 'pending');
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
