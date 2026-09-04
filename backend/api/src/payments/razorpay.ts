// Razorpay, implementing the PaymentProvider seam in provider.ts.
//
// ── WHAT THIS FILE IS ALLOWED TO DO ──────────────────────────────────────────────
//
// Exactly two things: open a checkout, and translate a webhook delivery into the three
// words the rest of the system understands ('paid' | 'failed' | 'refunded'). Everything
// else — idempotency, underpayment refusal, ticket minting — already lives in
// routes/payments.ts and settleOrder, and must not be reimplemented here. provider.ts's
// header is explicit that a vendor's assumptions stay inside its own implementation.
//
// ── THE SIGNATURE IS HMAC-SHA256 OVER THE RAW BYTES ──────────────────────────────
//
// key = webhook secret, message = the raw request body, compared against
// x-razorpay-signature. The Buffer arriving here is the untouched body precisely because
// re-serialised JSON is a different byte string; that is why the interface takes a Buffer
// and why routes/payments.ts refuses to run behind express.json().
//
// Compared with timingSafeEqual, not ===. A byte-by-byte early return leaks where the
// first difference is, and with enough attempts that is a forgeable signature. Lengths are
// checked first because timingSafeEqual throws on a length mismatch.
//
// ── WHY NOT THE razorpay npm SDK ─────────────────────────────────────────────────
//
// It is a dependency for two HTTPS calls and one HMAC, and its validateWebhookSignature
// takes a STRING — which invites JSON.stringify(body) at the call site, the exact bug the
// raw-Buffer contract exists to prevent. The Orders API is a POST with basic auth.
//
// ── EVENT NAMES, AND WHY THE MAP IS CONSERVATIVE ─────────────────────────────────
//
// Razorpay sends dozens of event types. Only the ones whose meaning is unambiguous are
// mapped; anything else returns ok:true with NO outcome, which routes/payments.ts records
// as a delivery and acts on not at all. That is deliberate: an unrecognised event must be
// visible in payment_webhook_events and must never guess its way into moving money.
import { createHmac, timingSafeEqual } from 'node:crypto';
import type {
  CheckoutHandle, CheckoutRequest, PaymentProvider, WebhookVerdict,
} from './provider';

const API = 'https://api.razorpay.com/v1';

/** Razorpay's own event names → our three words. Anything absent is recorded, not acted on. */
const OUTCOMES: Record<string, 'paid' | 'failed' | 'refunded'> = {
  // The order is what we opened and what provider_ref points at, so order.paid is the
  // settlement signal. payment.captured names the PAYMENT, whose id we never stored.
  'order.paid': 'paid',
  'payment.failed': 'failed',
  'refund.processed': 'refunded',
  // A full reversal after settlement. Partial refunds also arrive here; the handler treats
  // any refund as a status change on the order rather than trying to do arithmetic, which
  // is the honest limit of what one boolean column can represent.
  'refund.created': 'refunded',
};

export class RazorpayProvider implements PaymentProvider {
  readonly name = 'razorpay';

  constructor(
    private readonly keyId: string,
    private readonly keySecret: string,
    private readonly webhookSecret: string,
  ) {}

  async createCheckout(req: CheckoutRequest): Promise<CheckoutHandle> {
    // receipt is OUR order id. It is what makes a Razorpay order traceable back to a row
    // here from their dashboard, and it is capped at 40 chars by their API — a uuid is 36.
    const body = {
      amount: req.amountMinor,
      currency: req.currency,
      receipt: req.orderId,
      // Capture the moment the customer authorises. The alternative is a two-phase flow
      // whose second phase this codebase has nowhere to put, and an authorised-but-uncaptured
      // payment silently expires — which looks to a buyer exactly like a lost ticket.
      payment_capture: 1,
      notes: req.notes,
    };

    const res = await fetch(`${API}/orders`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Basic ${Buffer.from(`${this.keyId}:${this.keySecret}`).toString('base64')}`,
      },
      body: JSON.stringify(body),
    });

    if (!res.ok) {
      // The body is logged, not returned: a gateway error can name the account or the key,
      // and this string would otherwise travel to a buyer's phone.
      const detail = await res.text().catch(() => '');
      console.error(`[razorpay] createOrder ${res.status}: ${detail.slice(0, 500)}`);
      throw new Error('could not open a checkout');
    }

    const order = (await res.json()) as { id?: string };
    if (!order.id) throw new Error('razorpay returned no order id');

    return {
      providerRef: order.id,
      // What Checkout needs on the device, and nothing more. The key id is publishable by
      // design; the secret never leaves this process.
      clientPayload: {
        key: this.keyId,
        order_id: order.id,
        amount: req.amountMinor,
        currency: req.currency,
        name: 'Voiid',
        description: req.description,
      },
    };
  }

  verifyWebhook(rawBody: Buffer, headers: Record<string, unknown>): WebhookVerdict {
    const sent = String(headers['x-razorpay-signature'] ?? '');
    if (!sent) return { ok: false };

    const expected = createHmac('sha256', this.webhookSecret).update(rawBody).digest('hex');
    const a = Buffer.from(expected, 'utf8');
    const b = Buffer.from(sent, 'utf8');
    // Length first: timingSafeEqual throws rather than returning false on a mismatch, and a
    // thrown error here would become a 500 that retries forever.
    if (a.length !== b.length || !timingSafeEqual(a, b)) return { ok: false };

    let payload: any;
    try {
      payload = JSON.parse(rawBody.toString('utf8'));
    } catch {
      // Signed but unparseable. The signature verified, so this came from Razorpay — worth
      // refusing loudly rather than recording an event whose contents we cannot read.
      return { ok: false };
    }

    const eventType = String(payload?.event ?? '');
    // x-razorpay-event-id is the per-DELIVERY id and is what the caller writes to
    // payment_webhook_events. Falling back to the payload's own id would deduplicate on the
    // wrong thing — see 032's header on the two idempotency keys.
    const eventId = String(headers['x-razorpay-event-id'] ?? payload?.id ?? '');
    if (!eventType || !eventId) return { ok: false };

    const entities = payload?.payload ?? {};
    const order = entities?.order?.entity;
    const payment = entities?.payment?.entity;
    const refund = entities?.refund?.entity;

    // provider_ref is the Razorpay ORDER id, so that is what has to come back on every
    // event kind — including a refund, which names the payment first.
    const providerRef =
      order?.id ?? payment?.order_id ?? refund?.order_id ?? undefined;

    const outcome = OUTCOMES[eventType];

    // The settled amount, for settleOrder's underpayment guard. Taken from the ORDER's
    // amount_paid where present — the payment entity's `amount` is what was attempted.
    // Left undefined rather than guessed when neither is present: undefined means "the
    // provider did not say", and the guard treats that differently from a low number.
    const amountMinor =
      typeof order?.amount_paid === 'number' ? order.amount_paid
      : typeof payment?.amount === 'number' ? payment.amount
      : undefined;

    const currency = order?.currency ?? payment?.currency ?? undefined;

    return {
      ok: true,
      eventId,
      eventType,
      providerRef,
      outcome,
      reason: payment?.error_description ?? undefined,
      amountMinor,
      currency,
      payload,
    };
  }
}

/**
 * Build from the environment, or null when it is not configured.
 *
 * ALL THREE OR NOTHING. A half-configured provider is worse than an absent one: it would
 * register, activeProvider() would return it, paid events would start being offered, and
 * the first webhook would fail its signature check forever. provider.ts already treats a
 * missing provider as a supported state — this returns to it rather than half-working.
 */
export function razorpayFromEnv(): RazorpayProvider | null {
  const keyId = process.env.RAZORPAY_KEY_ID?.trim();
  const keySecret = process.env.RAZORPAY_KEY_SECRET?.trim();
  const webhookSecret = process.env.RAZORPAY_WEBHOOK_SECRET?.trim();
  if (!keyId || !keySecret || !webhookSecret) {
    if (keyId || keySecret || webhookSecret) {
      console.error(
        '[razorpay] partially configured — need RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET and ' +
        'RAZORPAY_WEBHOOK_SECRET. Not registering; paid events stay disabled.'
      );
    }
    return null;
  }
  return new RazorpayProvider(keyId, keySecret, webhookSecret);
}
