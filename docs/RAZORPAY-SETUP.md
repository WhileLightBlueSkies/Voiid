# Turning payments on

The code is written and tested. Nothing charges until the three environment variables below
are set — until then `activeProvider()` returns null, paid events answer **501**, and free
RSVP is unaffected. That is a supported state, not a misconfiguration.

---

## 1. Server environment

On the API box (`/opt/voiid/.env`), add:

```
VOIID_PAYMENT_PROVIDER=razorpay
RAZORPAY_KEY_ID=rzp_test_xxxxxxxxxxxx
RAZORPAY_KEY_SECRET=xxxxxxxxxxxxxxxxxxxxxxxx
RAZORPAY_WEBHOOK_SECRET=xxxxxxxxxxxxxxxx
```

**All three Razorpay values or none.** A partial config refuses to register and logs why —
otherwise paid events would start being offered while every webhook failed its signature
check forever.

`RAZORPAY_WEBHOOK_SECRET` is **not** the key secret. You choose it when creating the webhook
in the dashboard (step 2) and it must match exactly.

Restart the API. Look for `[payments] razorpay registered` in the log — if it is absent,
the provider did not load and paid events are still 501.

## 2. Webhook, in the Razorpay dashboard

**Settings → Webhooks → Add New Webhook**

| Field | Value |
|---|---|
| URL | `https://api-dev.voiid.app/payments/webhook/razorpay` |
| Secret | the same string as `RAZORPAY_WEBHOOK_SECRET` |

Subscribe to exactly these four events:

- `order.paid` → settles the order and mints tickets
- `payment.failed` → marks the order failed, with Razorpay's reason
- `refund.created`
- `refund.processed`

Other events can be subscribed safely — they are recorded in `payment_webhook_events` and
acted on not at all. That is deliberate: an unrecognised event must never guess its way into
moving money.

## 3. iOS — the one step that needs Xcode

Everything except the payment sheet itself is written. To finish:

1. **File → Add Package Dependencies** → `https://github.com/razorpay/razorpay-pod` *(check
   the current SPM URL in Razorpay's iOS docs — they have shipped both CocoaPods and SPM)*
2. Add it to the **Voiid** target only, not the notification extension.
3. Tell me it is added — the call site is a small, isolated piece and I will write it.

The plumbing already in place:

- `EventService.placeOrder()` → returns `.ticketed` (free) or `.needsPayment(orderId:checkout:)`
- `EventService.Checkout` → decoded `key`, `order_id`, `amount`, `currency`, `name`, `description`
- `EventService.orderStatus()` → polls `GET /events/:id/my-order`

---

## How the flow actually works

```
app  POST /events/:id/orders
      └─ free  → order 'paid', ticket exists, response has no checkout
      └─ paid  → Razorpay order created, response carries `checkout`
app  presents Razorpay with checkout.order_id
Razorpay  ──signed webhook──▶  POST /payments/webhook/razorpay
                                 └─ signature verified over RAW BYTES
                                 └─ delivery recorded (idempotency)
                                 └─ order → 'paid', tickets minted
app  polls GET /events/:id/my-order until status is 'paid'
```

**The sheet closing is not payment.** Razorpay's callback says the customer finished at the
gateway; the money is yours once the signed webhook has arrived and `settleOrder` has run.
The app polls the server, and the server's answer is the only thing that mints a ticket.

### Guards you get for free

- **An underpayment is not a payment.** If the settled amount is less than owed, or in a
  different currency, no ticket is minted — the order is marked failed with a reason.
  Trusting the "paid" label over the amount is how a mis-configured integration hands out
  free tickets.
- **Deliveries are deduplicated per delivery, not per order.** Providers retry; dedup on the
  order reference would drop the legitimate refund event.
- **A suspended event takes no orders**, re-checked inside the row lock.

## Testing without real money

Test-mode keys (`rzp_test_*`) charge nothing. Razorpay's dashboard has a **Test Webhook**
button that sends a signed delivery — use it to confirm signature verification end to end
before involving a real card.

To watch it land:

```
GET /admin/events/:id    # orders ledger, provider_ref, settlement state
```

Every delivery is recorded in `payment_webhook_events`, including ones that changed nothing.
