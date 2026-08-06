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
import { pool, query } from '../db';
import { asyncHandler } from '../util';
import { providerByName } from '../payments/provider';
import { newTicketNonce } from '../payments/tickets';

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

    // ── CLAIM THE DELIVERY. This insert is the lock.
    //
    // Insert-then-check, never check-then-insert: two concurrent retries both pass a SELECT and
    // both proceed, which is precisely the double-mint this whole design exists to prevent. The
    // unique index on (provider, provider_event_id) is NULL-free, so the conflict target
    // actually fires — a NULL in a unique key makes ON CONFLICT never match and turns this into
    // a plain insert, which is the 027_receipt_null_device.sql bug with money attached.
    const claimed = (
      await query<{ id: string }>(
        `insert into payment_webhook_events
           (provider, provider_event_id, event_type, order_id, payload)
         values ($1, $2, $3, $4, $5::jsonb)
         on conflict (provider, provider_event_id) do nothing
         returning id`,
        [
          provider.name,
          verdict.eventId,
          verdict.eventType,
          order?.id ?? null,
          verdict.payload === undefined ? null : JSON.stringify(verdict.payload),
        ]
      )
    )[0];

    if (!claimed) {
      // Seen before. 200 so the provider stops retrying: the work was done the first time.
      return res.json({ ok: true, duplicate: true });
    }

    // An event about an order we have never heard of. The delivery row is kept — "we received
    // something we could not place" is exactly the fact an operator needs and exactly the fact
    // that is otherwise lost — but nothing is acted on.
    if (!order) {
      await markProcessed(claimed.id);
      return res.json({ ok: true, unmatched: true });
    }

    try {
      if (verdict.outcome === 'paid') {
        await settleOrder(order, verdict.amountMinor, verdict.currency);
      } else if (verdict.outcome === 'refunded') {
        await refundOrder(order.id);
      } else if (verdict.outcome === 'failed') {
        await query(
          `update event_orders set status = 'failed', failure_reason = $2
            where id = $1 and status = 'pending'`,
          [order.id, verdict.reason ?? null]
        );
      }
      await markProcessed(claimed.id);
      return res.json({ ok: true });
    } catch (e) {
      // The delivery row stays with a NULL processed_at, which is the alerting signal: a
      // delivery that was claimed and never completed. Re-raising gives the provider a 5xx and
      // therefore a retry — but the claim will now conflict, so the retry will be treated as a
      // duplicate. That is the deliberate trade: at-most-once ticket minting, with a visible
      // row when something needs a human, rather than a chance of minting twice.
      console.error('[payments] failed to apply webhook', claimed.id, e);
      throw e;
    }
  })
);

async function markProcessed(deliveryId: string): Promise<void> {
  await query(`update payment_webhook_events set processed_at = now() where id = $1`, [deliveryId]);
}

/**
 * pending -> paid, and mint the tickets, in ONE transaction.
 *
 * The `where status = 'pending'` predicate on the UPDATE is what makes minting safe: only the
 * statement that actually performs the transition proceeds to insert tickets. A second path
 * arriving later updates zero rows and mints nothing, even if it somehow got past the delivery
 * ledger.
 */
async function settleOrder(
  order: { id: string; event_id: string; buyer_id: string; quantity: number; amount_minor: string; currency: string },
  paidMinor: number | undefined,
  paidCurrency: string | undefined
): Promise<void> {
  const owed = Number(order.amount_minor);

  // AN UNDERPAYMENT IS NOT A PAYMENT. If the provider tells us what settled and it is less than
  // what was owed — or in a different currency — no ticket is minted. Trusting the event's
  // "paid" label over its amount is how a manipulated or mis-configured integration hands out
  // free tickets. Recorded as failed with a reason so it is visible rather than silent.
  if (paidMinor !== undefined && paidMinor < owed) {
    await query(
      `update event_orders set status = 'failed', failure_reason = $2
        where id = $1 and status = 'pending'`,
      [order.id, `underpaid: ${paidMinor} of ${owed}`]
    );
    return;
  }
  if (paidCurrency !== undefined && paidCurrency.toUpperCase() !== order.currency) {
    await query(
      `update event_orders set status = 'failed', failure_reason = $2
        where id = $1 and status = 'pending'`,
      [order.id, `currency mismatch: ${paidCurrency} for a ${order.currency} order`]
    );
    return;
  }

  const client = await pool.connect();
  try {
    await client.query('begin');

    const moved = await client.query(
      `update event_orders set status = 'paid', settled_at = now()
        where id = $1 and status = 'pending'`,
      [order.id]
    );
    if (moved.rowCount === 0) {
      // Already settled, or cancelled/failed before the money arrived. Either way this delivery
      // has nothing to do. Not an error — an out-of-order delivery is Tuesday.
      await client.query('rollback');
      return;
    }

    for (let i = 0; i < order.quantity; i++) {
      await client.query(
        `insert into event_tickets (order_id, event_id, holder_id, qr_nonce)
         values ($1, $2, $3, $4)`,
        [order.id, order.event_id, order.buyer_id, newTicketNonce()]
      );
    }

    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }
}

/** paid -> refunded, and the tickets die with it. Voided, never deleted: the row is the record. */
async function refundOrder(orderId: string): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query('begin');
    const moved = await client.query(
      `update event_orders set status = 'refunded' where id = $1 and status = 'paid'`,
      [orderId]
    );
    if (moved.rowCount === 0) {
      await client.query('rollback');
      return;
    }
    await client.query(`update event_tickets set state = 'void' where order_id = $1`, [orderId]);
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }
}

export default router;
