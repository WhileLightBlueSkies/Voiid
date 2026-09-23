// Cashfree webhook verification and amount conversion — the rules that decide whether a
// ticket is minted.
//
//   1. THE SIGNATURE IS base64(HMAC-SHA256(timestamp + RAW body)). A body whose re-serialisation
//      differs (key order, whitespace, a decimal like 499.10) must still verify from the bytes.
//   2. ONLY A SUCCESSFUL PAYMENT MOVES THE ORDER. A failed or dropped attempt is recorded with no
//      outcome, because a Cashfree order accepts retries — see cashfree.ts's header.
//   3. AMOUNTS CROSS FROM RUPEES TO PAISE HERE AND NOWHERE ELSE, exactly.
//   4. THE DELIVERY ID IS STABLE ACROSS RETRIES of the same bytes, and differs between events.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { CashfreeProvider, cashfreeRefFor, toMajor, toMinor, CASHFREE_REF_RE } from '../src/payments/cashfree';

const SECRET = 'cf_test_secret';
const p = new CashfreeProvider('cf_test_id', SECRET, 'sandbox', 'https://api.example.test');
const REF = cashfreeRefFor('0b6a4c1e-2f3d-4e5f-8a9b-0c1d2e3f4a5b');

function signed(raw: string, ts = '1717000000000', secret = SECRET) {
  const sig = createHmac('sha256', secret).update(ts + raw).digest('base64');
  return { raw: Buffer.from(raw, 'utf8'), headers: { 'x-webhook-signature': sig, 'x-webhook-timestamp': ts } };
}

// Deliberately NOT what JSON.stringify would produce: spacing and a trailing-zero decimal.
const success = `{"type":"PAYMENT_SUCCESS_WEBHOOK", "data":{"order":{"order_id":"${REF}","order_amount":499.10,"order_currency":"INR"},"payment":{"cf_payment_id":"1453002795","payment_status":"SUCCESS","payment_amount":499.10,"payment_currency":"INR","payment_message":"00::Transaction success"}},"event_time":"2025-01-15T11:16:10+05:30"}`;

test('order references are Cashfree-legal and derived from our order id', () => {
  assert.match(REF, CASHFREE_REF_RE);
  assert.ok(REF.length <= 45);
  assert.equal(cashfreeRefFor('0B6A4C1E-2F3D-4E5F-8A9B-0C1D2E3F4A5B'), REF);
});

test('rupees and paise convert exactly both ways', () => {
  assert.equal(toMinor(499.1), 49910);
  assert.equal(toMinor('0.29'), 29);   // 0.29 * 100 = 28.999… in floating point
  assert.equal(toMajor(49910), 499.1);
  assert.equal(toMinor('not a number'), undefined);
});

test('a signed success over the raw bytes verifies and settles', () => {
  const { raw, headers } = signed(success);
  const v = p.verifyWebhook(raw, headers);
  assert.equal(v.ok, true);
  assert.equal(v.outcome, 'paid');
  assert.equal(v.providerRef, REF);
  assert.equal(v.amountMinor, 49910);
  assert.equal(v.currency, 'INR');
  assert.equal(v.eventType, 'PAYMENT_SUCCESS_WEBHOOK');
});

test('a wrong secret, a changed body or a changed timestamp is refused', () => {
  const good = signed(success);
  assert.equal(p.verifyWebhook(good.raw, { ...good.headers, 'x-webhook-signature': signed(success, '1717000000000', 'other').headers['x-webhook-signature'] }).ok, false);
  assert.equal(p.verifyWebhook(Buffer.from(success.replace('499.10', '1.00')), good.headers).ok, false);
  assert.equal(p.verifyWebhook(good.raw, { ...good.headers, 'x-webhook-timestamp': '1717000000001' }).ok, false);
  assert.equal(p.verifyWebhook(good.raw, {}).ok, false);
});

test('failed and dropped attempts are recorded but never close the order', () => {
  for (const type of ['PAYMENT_FAILED_WEBHOOK', 'PAYMENT_USER_DROPPED_WEBHOOK']) {
    const body = success.replace('PAYMENT_SUCCESS_WEBHOOK', type).replace('"SUCCESS"', '"FAILED"');
    const { raw, headers } = signed(body);
    const v = p.verifyWebhook(raw, headers);
    assert.equal(v.ok, true, type);
    assert.equal(v.outcome, undefined, type);
    assert.equal(v.providerRef, REF, type);
  }
});

test('only a completed refund refunds', () => {
  const refund = (status: string) =>
    `{"type":"REFUND_STATUS_WEBHOOK","data":{"refund":{"order_id":"${REF}","cf_refund_id":"r1","refund_status":"${status}","refund_amount":499.10,"refund_currency":"INR"}}}`;
  const done = signed(refund('SUCCESS'));
  assert.equal(p.verifyWebhook(done.raw, done.headers).outcome, 'refunded');
  const pending = signed(refund('PENDING'));
  assert.equal(p.verifyWebhook(pending.raw, pending.headers).outcome, undefined);
});

test('the delivery id is stable for a retry and distinct per event', () => {
  const a = signed(success);
  const again = signed(success, '1717000009999');   // a retry re-signs with a new timestamp
  const other = signed(success.replace('1453002795', '1453002796'));
  const id = p.verifyWebhook(a.raw, a.headers).eventId;
  assert.equal(p.verifyWebhook(again.raw, again.headers).eventId, id);
  assert.notEqual(p.verifyWebhook(other.raw, other.headers).eventId, id);
});

test('the app gets a checkout URL on this API, never a secret', () => {
  const payload = p.resumeCheckout(REF, 49910, 'INR');
  assert.equal(payload.provider, 'cashfree');
  assert.equal(payload.checkout_url, `https://api.example.test/payments/checkout/cashfree/${REF}`);
  assert.ok(!JSON.stringify(payload).includes(SECRET));
  assert.throws(() => p.resumeCheckout('order_123', 49910, 'INR'));
});
