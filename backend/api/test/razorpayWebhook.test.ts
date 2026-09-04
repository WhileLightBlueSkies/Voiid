// Razorpay webhook verification — the rules that are easy to get wrong and impossible to
// notice when they are.
//
// WHAT THIS EXISTS FOR
// --------------------
// verifyWebhook is the ONLY authentication on the one endpoint a stranger can call, and the
// one that mints tickets. Three of its properties look like implementation detail and are
// actually the whole security story:
//
//   1. THE SIGNATURE IS OVER THE RAW BYTES. A re-serialised body is a different byte string,
//      so an implementation that verifies JSON.stringify(parsed) verifies nothing while
//      passing every happy-path test. Pinned here by signing bytes whose re-serialisation
//      would differ — key order and whitespace.
//   2. AN UNKNOWN EVENT IS RECORDED, NOT ACTED ON. Razorpay sends dozens of event types and
//      the map is deliberately conservative. `ok: true` with no `outcome` is the contract:
//      routes/payments.ts writes the delivery row and does nothing else.
//   3. THE DELIVERY ID IS THE HEADER'S, NOT THE PAYLOAD'S. 032 has two idempotency keys and
//      they are not interchangeable — deduplicating on the order reference would drop the
//      legitimate refund event.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { RazorpayProvider } from '../src/payments/razorpay';

const SECRET = 'whsec_test_only';
const p = new RazorpayProvider('rzp_test_key', 'secret', SECRET);

function sign(raw: Buffer | string, secret = SECRET) {
  return createHmac('sha256', secret).update(raw).digest('hex');
}
function headers(raw: Buffer | string, eventId = 'evt_1', secret = SECRET) {
  return { 'x-razorpay-signature': sign(raw, secret), 'x-razorpay-event-id': eventId };
}

const orderPaid = (orderId = 'order_abc', paid = 50000) => Buffer.from(JSON.stringify({
  event: 'order.paid',
  payload: { order: { entity: { id: orderId, amount_paid: paid, currency: 'INR' } } },
}));

test('a correctly signed delivery verifies and translates to paid', () => {
  const raw = orderPaid();
  const v = p.verifyWebhook(raw, headers(raw));
  assert.equal(v.ok, true);
  assert.equal(v.outcome, 'paid');
  assert.equal(v.providerRef, 'order_abc');
  assert.equal(v.amountMinor, 50000);
  assert.equal(v.currency, 'INR');
});

test('a wrong secret does not verify', () => {
  const raw = orderPaid();
  assert.equal(p.verifyWebhook(raw, headers(raw, 'evt_1', 'other')).ok, false);
});

test('a missing signature header does not verify', () => {
  const raw = orderPaid();
  assert.equal(p.verifyWebhook(raw, { 'x-razorpay-event-id': 'evt_1' }).ok, false);
});

test('a tampered body does not verify', () => {
  const raw = orderPaid();
  const h = headers(raw);
  // Same signature, different amount — the shape of an attacker inflating what settled.
  const tampered = orderPaid('order_abc', 1);
  assert.equal(p.verifyWebhook(tampered, h).ok, false);
});

test('SIGNED OVER RAW BYTES, not over a re-serialisation', () => {
  // Key order and whitespace that JSON.stringify(JSON.parse(x)) would not reproduce. If the
  // implementation ever re-serialises before hashing, this is the test that fails.
  const raw = Buffer.from(
    '{  "payload" : { "order" : { "entity" : { "currency":"INR",  "id" : "order_ws", "amount_paid":100 } } },\n'
    + '  "event"  :  "order.paid"  }'
  );
  assert.notEqual(raw.toString(), JSON.stringify(JSON.parse(raw.toString())));
  const v = p.verifyWebhook(raw, headers(raw));
  assert.equal(v.ok, true);
  assert.equal(v.providerRef, 'order_ws');
  assert.equal(v.amountMinor, 100);
});

test('an unknown event verifies but carries NO outcome', () => {
  const raw = Buffer.from(JSON.stringify({
    event: 'payment.authorized',
    payload: { payment: { entity: { order_id: 'order_x', amount: 100, currency: 'INR' } } },
  }));
  const v = p.verifyWebhook(raw, headers(raw));
  assert.equal(v.ok, true);
  assert.equal(v.eventType, 'payment.authorized');
  // The point: recorded as a delivery, acts on nothing.
  assert.equal(v.outcome, undefined);
});

test('the delivery id comes from the header, not the payload', () => {
  const raw = Buffer.from(JSON.stringify({
    event: 'order.paid', id: 'payload_id_should_lose',
    payload: { order: { entity: { id: 'order_abc', amount_paid: 1, currency: 'INR' } } },
  }));
  const v = p.verifyWebhook(raw, headers(raw, 'evt_header_wins'));
  assert.equal(v.eventId, 'evt_header_wins');
});

test('a refund names the ORDER, because provider_ref is the order id', () => {
  const raw = Buffer.from(JSON.stringify({
    event: 'refund.processed',
    payload: { refund: { entity: { id: 'rfnd_1', order_id: 'order_abc', amount: 50000 } } },
  }));
  const v = p.verifyWebhook(raw, headers(raw));
  assert.equal(v.outcome, 'refunded');
  assert.equal(v.providerRef, 'order_abc');
});

test('a failed payment carries the reason and the order it was for', () => {
  const raw = Buffer.from(JSON.stringify({
    event: 'payment.failed',
    payload: { payment: { entity: {
      order_id: 'order_abc', amount: 50000, currency: 'INR',
      error_description: 'card declined',
    } } },
  }));
  const v = p.verifyWebhook(raw, headers(raw));
  assert.equal(v.outcome, 'failed');
  assert.equal(v.providerRef, 'order_abc');
  assert.equal(v.reason, 'card declined');
});

test('signed but unparseable is refused rather than recorded', () => {
  const raw = Buffer.from('{not json');
  assert.equal(p.verifyWebhook(raw, headers(raw)).ok, false);
});

test('amount_paid wins over the attempted payment amount', () => {
  // The underpayment guard in settleOrder compares against what SETTLED. Handing it the
  // attempted amount would let a partial capture mint a full ticket.
  const raw = Buffer.from(JSON.stringify({
    event: 'order.paid',
    payload: {
      order: { entity: { id: 'order_abc', amount_paid: 100, currency: 'INR' } },
      payment: { entity: { order_id: 'order_abc', amount: 50000, currency: 'INR' } },
    },
  }));
  assert.equal(p.verifyWebhook(raw, headers(raw)).amountMinor, 100);
});
