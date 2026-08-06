// The payments SEAM. Deliberately empty of any actual payment provider.
//
// ── WHY THERE IS NO PROVIDER IN HERE ─────────────────────────────────────────────
//
// The founder has not chosen a processor. Writing one in anyway — even "just Razorpay, we can
// swap it later" — would put a vendor's assumptions into the order table, the webhook shape
// and the error vocabulary, and swapping it later would then mean a migration rather than a
// config change. So this file defines the SHAPE of a provider and nothing else, and
// 032_events_tickets.sql keeps `provider` a text label rather than an enum for the same reason.
//
// Adding a real one is: a class implementing PaymentProvider, one line in `register()`, and an
// environment variable. It is not a schema change and it must never become one.
//
// ── WHAT THE INTERFACE IS SHAPED BY ──────────────────────────────────────────────
//
// Two facts about every processor that exists, which is why they are in the interface rather
// than in whichever implementation lands first:
//
//   1. A WEBHOOK IS DELIVERED AT LEAST ONCE. Every provider retries until it gets a 2xx, and
//      several will retry anyway. So `verifyWebhook` must return a stable per-DELIVERY id
//      (`eventId`), which the caller writes to payment_webhook_events before acting. Not the
//      order reference — a provider sends several events about one order and deduplicating on
//      the order reference would drop the legitimate refund event. See 032's header.
//   2. THE SIGNATURE IS OVER THE RAW BYTES. `verifyWebhook` therefore takes a Buffer, not a
//      parsed object. Re-serialised JSON is a different byte string — key order, unicode
//      escaping, whitespace — and an implementation that verifies a re-encoded body is
//      verifying nothing at all while looking exactly like it works.

/** What the API asks a provider to start. Amounts are MINOR UNITS, never floats. */
export interface CheckoutRequest {
  orderId: string;
  amountMinor: number;
  currency: string;
  /** Free-text description shown on the provider's page. Never contains message content. */
  description: string;
  /** Opaque to the provider; comes back on the webhook so an event can be traced to an order. */
  notes: Record<string, string>;
}

/**
 * What the provider hands back.
 *
 * `providerRef` is written to event_orders.provider_ref and is NOT NULL there: it is half of
 * the order-level idempotency key, and a provider that cannot supply one before the customer
 * pays is one whose integration has to mint a deterministic reference of its own.
 *
 * `clientPayload` is passed to the app untouched. Every SDK wants something different (an
 * order id, a session url, a token) and enumerating them here would be this file guessing.
 */
export interface CheckoutHandle {
  providerRef: string;
  clientPayload: Record<string, unknown>;
}

/** The normalised meaning of one delivery, after its signature has been checked. */
export interface WebhookVerdict {
  /** False means the signature did not verify. The caller must not act, and must not record. */
  ok: boolean;
  /** Stable id for THIS DELIVERY. The delivery-level idempotency key. */
  eventId?: string;
  /** The provider's own event name, verbatim, for the audit row. */
  eventType?: string;
  /** Matches event_orders.provider_ref. */
  providerRef?: string;
  /**
   * What this event says happened, in OUR vocabulary — the only translation the provider
   * implementation is allowed to do, because everything downstream is written against these
   * three words and not against forty vendor event names.
   */
  outcome?: 'paid' | 'failed' | 'refunded';
  /** The provider's reason for a failure. Diagnostic; never rendered to a buyer verbatim. */
  reason?: string;
  /** Settled amount in minor units, so the handler can refuse an underpayment. */
  amountMinor?: number;
  currency?: string;
  /** The verified body, parsed, for the audit row. */
  payload?: unknown;
}

export interface PaymentProvider {
  /** Goes straight into event_orders.provider. Lower-case, stable, never renamed. */
  readonly name: string;
  createCheckout(req: CheckoutRequest): Promise<CheckoutHandle>;
  verifyWebhook(rawBody: Buffer, headers: Record<string, unknown>): WebhookVerdict;
}

// ─────────────────────────────────────────────────────────────────────────────────
// The registry.
//
// Empty on purpose. When a provider is chosen, it is registered here.
// ─────────────────────────────────────────────────────────────────────────────────
const providers = new Map<string, PaymentProvider>();

export function register(p: PaymentProvider): void {
  providers.set(p.name, p);
}

export function providerByName(name: string): PaymentProvider | null {
  return providers.get(name) ?? null;
}

/**
 * The provider this deployment is configured to charge with, or null.
 *
 * NULL IS THE SUPPORTED, EXPECTED STATE and not a misconfiguration — the same posture
 * secretbox.ts takes for a missing key. It is what makes "ship free RSVP before wiring money"
 * a property of the code rather than a promise in a plan: with no provider configured, an
 * event priced at zero works end to end and an event priced above zero is refused at creation
 * with a 501 rather than half-working.
 */
export function activeProvider(): PaymentProvider | null {
  const name = process.env.VOIID_PAYMENT_PROVIDER?.trim();
  if (!name) return null;
  const p = providers.get(name);
  if (!p) {
    // Loud, and on every call rather than once: an operator who set the variable believes
    // money is switched on. Silently falling back to "free" would mean selling tickets for
    // nothing, which is worse than any error.
    console.error(
      `[payments] VOIID_PAYMENT_PROVIDER=${name} is not registered. ` +
        `Paid events are disabled. Registered: ${[...providers.keys()].join(', ') || '(none)'}`
    );
    return null;
  }
  return p;
}

/**
 * The pseudo-provider recorded on a zero-price order.
 *
 * A free RSVP never reaches a PaymentProvider — there is nothing to charge — but it is still an
 * ORDER, because that is what makes the ticket path identical with and without money and lets
 * the free flow de-risk the door before a processor exists. `provider` is NOT NULL in the
 * schema, so the row needs a value, and this is it. It is a label, not an implementation.
 */
export const FREE_PROVIDER = 'free';
