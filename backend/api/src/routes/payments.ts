// The payment webhook — the one endpoint in this API that is called by a stranger.
//
// ── EVERY ASSUMPTION HERE IS HOSTILE ─────────────────────────────────────────────
//
// This route is reachable by anyone on the internet who finds the URL, and it is the only place
// where an inbound HTTP request can move an order to 'paid' and mint tickets. So:
//
//   * NOTHING IS TRUSTED UNTIL THE SIGNATURE VERIFIES. Not the order id, not the amount, not
//     the event name. The provider's signature over the raw bytes is the whole authentication
//     story; there is no session and no token.
//   * THE SIGNATURE IS CHECKED OVER THE RAW BYTES. Re-serialised JSON is a different byte
//     string — key order, unicode escaping, whitespace — so an implementation that verifies a
//     re-encoded body verifies nothing while looking exactly like it works. This router
//     therefore parses the body itself, and refuses to run if something upstream already did.
//   * A DELIVERY IS RECORDED BEFORE IT IS ACTED ON. Providers deliver at least once and retry
//     concurrently. The INSERT into payment_webhook_events is what grants permission to act:
//     if it conflicts, this delivery has already been handled and the handler stops.
//
// ── THE TWO IDEMPOTENCY KEYS, AGAIN, BECAUSE THIS IS WHERE IT MATTERS ────────────
//
// 032_events_tickets.sql has both and they are not interchangeable:
//
//   (provider, provider_ref)       identifies the ORDER at the provider.
//   (provider, provider_event_id)  identifies THIS DELIVERY.
//
// Deduplicating on the order reference would drop the legitimate refund event, because a
// provider sends several events about one order. Deduplicating on the delivery id is correct
// and is what this file does.
//
// ── NO PROVIDER IS IMPLEMENTED ───────────────────────────────────────────────────
//
// The founder has not chosen a processor, so payments/provider.ts holds an interface and an
// empty registry. With nothing registered this endpoint answers 404 for every provider name,
// which is the correct answer: there is no integration, so there is no webhook.
import { Router } from 'express';
import express from 'express';
import { query } from '../db';
import { asyncHandler } from '../util';
import { providerByName } from '../payments/provider';
import { applyDelivery, claimDelivery, holdUnmatched, markFailed } from '../payments/inbox';

const router = Router();

/**
 * Raw-body parsing for the webhook path only.
 *
 * ── AN OPERATIONAL REQUIREMENT, STATED SO IT IS NOT DISCOVERED IN PRODUCTION ──
 *
 * `index.ts` installs `express.json()` for the whole app. Body parsing consumes the request
 * stream exactly once, so if that middleware runs first this one receives nothing and the
 * signature can never verify. THIS ROUTER MUST THEREFORE BE MOUNTED BEFORE
 * `app.use(express.json(...))`.
 *
 * The handler detects the wrong order explicitly (see `rawBodyOf`) and fails CLOSED with a log
 * that says what to change, rather than silently rejecting every payment as a bad signature —
 * which is the shape this bug takes when nobody plans for it, and it is very hard to read from
 * the outside.
 */
const rawJson = express.raw({ type: '*/*', limit: '1mb' });

function rawBodyOf(req: { body: unknown }): Buffer | null {
  return Buffer.isBuffer(req.body) ? req.body : null;
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /payments/webhook/:provider
//
// Returns 200 for anything that has been dealt with — including duplicates and events about
// orders we do not know — because a non-2xx makes the provider retry, and retrying will not
// change any of those answers. Non-2xx is reserved for "we could not verify you" and "we broke",
// which are the two cases where a retry is genuinely worth something.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/payments/webhook/:provider',
  rawJson,
  asyncHandler(async (req, res) => {
    const name = String(req.params.provider ?? '');
    const provider = providerByName(name);
    if (!provider) {
      // No such integration. Nothing to retry into existence, so 404 rather than 500.
      return res.status(404).json({ error: 'unknown payment provider' });
    }

    const raw = rawBodyOf(req);
    if (!raw) {
      console.error(
        '[payments] webhook body was already parsed before this router saw it. ' +
          'Mount the payments router BEFORE app.use(express.json()) in index.ts — ' +
          'the provider signature is over the raw bytes and cannot be checked against ' +
          're-serialised JSON.'
      );
      // 500, not 400: the caller did nothing wrong and a retry after a deploy will succeed.
      return res.status(500).json({ error: 'webhook not configured' });
    }

    const verdict = provider.verifyWebhook(raw, req.headers as Record<string, unknown>);
    if (!verdict.ok || !verdict.eventId || !verdict.eventType) {
      // NOTHING IS RECORDED FOR AN UNVERIFIED DELIVERY. Writing the payload first would turn
      // this endpoint into an unauthenticated blob store that anyone could fill.
      console.warn(`[payments] rejected an unverified ${name} webhook`);
      return res.status(400).json({ error: 'signature verification failed' });
    }

    // ── The order this event is about, if we know it.
    const order = verdict.providerRef
      ? (
          await query<{
            id: string;
            event_id: string;
            buyer_id: string;
            quantity: number;
            amount_minor: string;
            currency: string;
            status: string;
          }>(
            `select id, event_id, buyer_id, quantity, amount_minor::text as amount_minor,
                    currency, status
               from event_orders where provider = $1 and provider_ref = $2`,
            [provider.name, verdict.providerRef]
          )
        )[0]
      : undefined;

    // ── CLAIM THE DELIVERY. The claim is exclusive and, crucially, RELEASABLE.
    //
    // See payments/inbox.ts. The claim used to be a bare insert whose only outcome was
    // "conflict = already handled", which meant a delivery that failed after being claimed
    // could never be retried — the buyer's money had moved and no ticket existed. A claim now
    // carries a lease and a status, so a failure leaves the delivery retryable.
    const claim = await claimDelivery({
      provider: provider.name,
      providerEventId: verdict.eventId,
      eventType: verdict.eventType,
      providerRef: verdict.providerRef,
      orderId: order?.id,
      payload: verdict.payload,
      outcome: verdict.outcome,
      reason: verdict.reason,
      amountMinor: verdict.amountMinor,
      currency: verdict.currency,
    });

    if (claim.state === 'duplicate') {
      // Genuinely finished the first time. 200 so the provider stops retrying.
      return res.json({ ok: true, duplicate: true });
    }
    if (claim.state === 'leased') {
      // Another handler is on it right now. NOT 200: if that handler fails, this delivery
      // still needs to come back, and a 2xx here would tell the provider never to send it
      // again. 409 rather than 5xx because nothing is broken.
      return res.status(409).json({ error: 'delivery in progress' });
    }

    // An event about an order we have never heard of — most often one that arrived before its
    // order row was committed (routes/events.ts opens the checkout before it inserts). HELD,
    // not marked processed: reconcileUnmatched replays it the moment that order appears.
    if (!order) {
      await holdUnmatched(claim.id);
      return res.json({ ok: true, unmatched: true });
    }

    try {
      // The settlement and the ledger transition commit together. That is the whole fix.
      await applyDelivery(claim.id, order.id, {
        outcome: verdict.outcome,
        amountMinor: verdict.amountMinor,
        currency: verdict.currency,
        reason: verdict.reason,
      });
      return res.json({ ok: true });
    } catch (e) {
      // Retryable, and recorded as such. Re-raising gives the provider a 5xx and therefore a
      // retry, and that retry will now RE-CLAIM this row rather than being dismissed as a
      // duplicate. A sweep can pick it up too if the provider gives up first.
      console.error('[payments] failed to apply webhook', claim.id, e);
      await markFailed(claim.id, e);
      throw e;
    }
  })
);

export default router;
