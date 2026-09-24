// The payment delivery inbox: claim a delivery, apply it, and record that it was applied —
// with the last two in ONE transaction.
//
// ── THE RULE THIS FILE EXISTS TO ENFORCE ─────────────────────────────────────────
//
// The effect and the record of the effect commit together, or neither does. Before 058 they
// were separate writes in that order, so a failure between them left money moved, no ticket
// minted, and a ledger row claiming the delivery had been handled — which made every
// subsequent retry a no-op. A delivery that fails now stays RETRYABLE, and the provider's
// next attempt (or a sweep) picks it up.
//
// ── WHY A LEASE AND NOT A LOCK ───────────────────────────────────────────────────
//
// Two deliveries of the same event arrive concurrently — every provider does this. A row lock
// held for the length of the settlement would serialise them correctly but leave a stuck
// 'processing' row forever if the process holding it died. A lease is the same exclusion with
// an expiry: a handler that dies takes its claim with it, and the row becomes claimable again
// on its own.
import { query, withTransaction } from '../db';
import { newTicketNonce } from './tickets';

/**
 * How long a claim holds a delivery.
 *
 * Longer than any honest settlement (a handful of statements against the primary), short
 * enough that a crashed handler's work is retryable within one provider retry cycle. Too
 * short would let a slow-but-alive handler have its delivery stolen and applied twice —
 * which the `status = 'pending'` guard on settlement would still make safe, but noisily.
 */
export const DELIVERY_LEASE_SECONDS = Number(process.env.VOIID_WEBHOOK_LEASE_SECONDS) || 60;

/** The provider's normalised verdict — the only thing settlement acts on. */
export interface DeliveryFacts {
  outcome?: 'paid' | 'failed' | 'refunded';
  amountMinor?: number;
  currency?: string;
  reason?: string;
}

export interface DeliveryRecord extends DeliveryFacts {
  provider: string;
  providerEventId: string;
  eventType: string;
  providerRef?: string;
  orderId?: string;
  payload?: unknown;
}

export type Claim =
  /** This handler owns the delivery and must apply it. */
  | { state: 'claimed'; id: string }
  /** Already applied. Answer 200: retrying will not change anything. */
  | { state: 'duplicate' }
  /** Someone else holds a live lease. Answer non-2xx so the provider comes back. */
  | { state: 'leased' };

/**
 * Take exclusive ownership of a delivery, inserting it if this is the first sight of it.
 *
 * Insert-then-check, never check-then-insert: two concurrent retries both pass a SELECT and
 * both proceed, which is the double-mint this design exists to prevent. The unique index on
 * (provider, provider_event_id) is NULL-free, so the conflict target actually fires.
 *
 * The DO UPDATE's WHERE is what makes a retry meaningful: a row that is 'failed' or
 * 'unmatched', or whose lease has expired, is re-claimable. A 'processed' row is not, and
 * neither is one another handler is actively holding.
 */
export async function claimDelivery(record: DeliveryRecord): Promise<Claim> {
  const claimed = await query<{ id: string }>(
    `insert into payment_webhook_events
       (provider, provider_event_id, event_type, order_id, provider_ref, payload,
        outcome, outcome_reason, amount_minor, currency, status, attempts, lease_until)
     values ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, $10, 'processing', 1,
             now() + make_interval(secs => $11))
     on conflict (provider, provider_event_id) do update
        set status      = 'processing',
            attempts    = payment_webhook_events.attempts + 1,
            lease_until = now() + make_interval(secs => $11),
            -- Never overwrite what we already know with a null: a redelivery is allowed to
            -- TEACH us the order it belongs to, never to forget it.
            order_id     = coalesce(excluded.order_id, payment_webhook_events.order_id),
            provider_ref = coalesce(excluded.provider_ref, payment_webhook_events.provider_ref)
      where payment_webhook_events.status in ('received', 'failed', 'unmatched')
        and (payment_webhook_events.lease_until is null or payment_webhook_events.lease_until < now())
     returning id`,
    [
      record.provider,
      record.providerEventId,
      record.eventType,
      record.orderId ?? null,
      record.providerRef ?? null,
      record.payload === undefined ? null : JSON.stringify(record.payload),
      record.outcome ?? null,
      record.reason ?? null,
      record.amountMinor ?? null,
      record.currency ?? null,
      DELIVERY_LEASE_SECONDS,
    ]
  );
  if (claimed[0]) return { state: 'claimed', id: claimed[0].id };

  // No row came back, which means the WHERE refused it. Ask why, so the caller can answer
  // "done" or "come back later" — those are different answers and returning the wrong one
  // either drops a payment or makes a provider retry forever.
  const existing = await query<{ status: string }>(
    `select status from payment_webhook_events where provider = $1 and provider_event_id = $2`,
    [record.provider, record.providerEventId]
  );
  return existing[0]?.status === 'processed' ? { state: 'duplicate' } : { state: 'leased' };
}

/** Verified, but about an order we have never seen. Held for reconciliation, not finished. */
export async function holdUnmatched(deliveryId: string): Promise<void> {
  await query(
    `update payment_webhook_events
        set status = 'unmatched', lease_until = null
      where id = $1`,
    [deliveryId]
  );
}

/** Attempted and did not finish. Stays claimable, which is the whole point of 058. */
export async function markFailed(deliveryId: string, error: unknown): Promise<void> {
  await query(
    `update payment_webhook_events
        set status = 'failed', lease_until = null, last_error = $2
      where id = $1`,
    [deliveryId, String((error as Error)?.message ?? error).slice(0, 500)]
  );
}

interface OrderRow {
  id: string;
  event_id: string;
  buyer_id: string;
  quantity: number;
  amount_minor: string;
  currency: string;
  status: string;
}

/**
 * Apply one delivery's effect and mark it processed, atomically.
 *
 * The order row is locked FOR UPDATE first, so concurrent deliveries about the same order
 * queue behind each other rather than interleaving a settlement with a refund.
 */
export async function applyDelivery(
  deliveryId: string,
  orderId: string,
  facts: DeliveryFacts
): Promise<void> {
  await withTransaction(async (execute) => {
    const order = (
      await execute<OrderRow>(
        `select id, event_id, buyer_id, quantity, amount_minor::text as amount_minor, currency, status
           from event_orders where id = $1 for update`,
        [orderId]
      )
    )[0];

    // The order can be gone (cancelled and swept) between claim and here. The delivery is
    // still finished as far as we are concerned: there is nothing left to apply it to, and
    // leaving it retryable would mean retrying forever.
    if (order) {
      if (facts.outcome === 'paid') {
        await settleOrder(execute, order, facts);
      } else if (facts.outcome === 'refunded') {
        await refundOrder(execute, order.id);
      } else if (facts.outcome === 'failed') {
        await execute(
          `update event_orders set status = 'failed', failure_reason = $2
            where id = $1 and status = 'pending'`,
          [order.id, facts.reason ?? null]
        );
      }
      // An `ok: true` verdict with no outcome is a real and common case — providers send
      // dozens of event types and the mapping is deliberately conservative. Recorded, not acted on.
    }

    await execute(
      `update payment_webhook_events
          set status = 'processed', processed_at = now(), lease_until = null, last_error = null
        where id = $1`,
      [deliveryId]
    );
  });
}

/**
 * pending -> paid, and mint the tickets.
 *
 * The `where status = 'pending'` predicate is what makes minting safe: only the statement
 * that actually performs the transition proceeds to insert tickets. A second path arriving
 * later updates zero rows and mints nothing.
 */
async function settleOrder(
  execute: typeof query,
  order: OrderRow,
  facts: DeliveryFacts
): Promise<void> {
  const owed = Number(order.amount_minor);

  // AN UNDERPAYMENT IS NOT A PAYMENT. If the provider tells us what settled and it is less
  // than what was owed — or in a different currency — no ticket is minted. Trusting the
  // event's "paid" label over its amount is how a manipulated or mis-configured integration
  // hands out free tickets. Recorded as failed with a reason so it is visible rather than silent.
  if (facts.amountMinor !== undefined && facts.amountMinor < owed) {
    await execute(
      `update event_orders set status = 'failed', failure_reason = $2
        where id = $1 and status = 'pending'`,
      [order.id, `underpaid: ${facts.amountMinor} of ${owed}`]
    );
    return;
  }
  if (facts.currency !== undefined && facts.currency.toUpperCase() !== order.currency) {
    await execute(
      `update event_orders set status = 'failed', failure_reason = $2
        where id = $1 and status = 'pending'`,
      [order.id, `currency mismatch: ${facts.currency} for a ${order.currency} order`]
    );
    return;
  }

  const moved = await execute<{ id: string }>(
    `update event_orders set status = 'paid', settled_at = now()
      where id = $1 and status = 'pending'
      returning id`,
    [order.id]
  );
  // Already settled, or refunded/cancelled/failed before this delivery landed. Either way
  // this event has nothing to do — an out-of-order delivery is Tuesday.
  if (!moved.length) return;

  for (let i = 0; i < order.quantity; i++) {
    await execute(
      `insert into event_tickets (order_id, event_id, holder_id, qr_nonce)
       values ($1, $2, $3, $4)`,
      [order.id, order.event_id, order.buyer_id, newTicketNonce()]
    );
  }
}

/**
 * A REFUND IS TERMINAL WHENEVER IT LANDS. This is the explicit ordering policy C01 asks for.
 *
 * Providers do not guarantee delivery order, and a refund arriving before its payment is a
 * real sequence — a fast reversal, or a redelivery storm. The old code only moved 'paid' ->
 * 'refunded', so a refund that arrived first matched no rows, was marked processed, and was
 * LOST; the payment then landed, minted tickets, and the buyer kept a live ticket for money
 * that had been returned.
 *
 * So 'pending' is refunded too. `settled_at` is stamped because the constraint in 032 ties it
 * to the refunded state, and it is honest: money moved and came back, even though we never
 * saw the event that said it moved. A later 'paid' delivery then finds a non-pending order
 * and mints nothing, which is the outcome that matters.
 *
 * 'failed' and 'cancelled' orders are left alone: no money was taken, so there is nothing to
 * return, and rewriting a terminal state on a stray event would destroy the audit trail.
 */
/** A refund confirmed some other way than its webhook — the reconciliation sweep, or a free RSVP. */
export async function markRefunded(orderId: string): Promise<void> {
  await withTransaction((execute) => refundOrder(execute, orderId));
}

async function refundOrder(execute: typeof query, orderId: string): Promise<void> {
  const moved = await execute<{ id: string }>(
    `update event_orders
        set status = 'refunded', settled_at = coalesce(settled_at, now()), refund_error = null
      where id = $1 and status in ('paid', 'pending')
      returning id`,
    [orderId]
  );
  if (!moved.length) return;
  // Voided, never deleted: the row is the record. A pending order has no tickets yet, so
  // this is a no-op there rather than a special case.
  await execute(`update event_tickets set state = 'void' where order_id = $1`, [orderId]);
}

/**
 * Apply any delivery that arrived before its order existed.
 *
 * THE RACE THIS CLOSES. routes/events.ts opens the checkout at the provider BEFORE it inserts
 * the order row — it has to, because provider_ref is NOT NULL and the provider mints it. A
 * buyer who pays instantly, or a provider that delivers fast, lands a webhook in that window.
 * The delivery is verified and real, but names a reference no order has yet, so it is held as
 * 'unmatched' rather than discarded.
 *
 * Called with the order's own reference the moment that order is committed. Deliveries are
 * replayed in arrival order so a paid-then-refunded pair ends refunded, not paid.
 *
 * Never throws: an order that was just created successfully must not 500 because a held
 * delivery could not be applied. The delivery stays 'failed' and therefore retryable.
 */
export async function reconcileUnmatched(
  provider: string,
  providerRef: string,
  orderId: string
): Promise<number> {
  let applied = 0;
  try {
    const held = await query<{
      id: string; outcome: string | null; outcome_reason: string | null;
      amount_minor: string | null; currency: string | null;
    }>(
      `select id, outcome, outcome_reason, amount_minor::text as amount_minor, currency
         from payment_webhook_events
        where provider = $1 and provider_ref = $2 and status = 'unmatched'
        order by received_at`,
      [provider, providerRef]
    );

    for (const row of held) {
      // Re-claim under the same rule the webhook path uses, so a delivery arriving at this
      // exact moment cannot be applied twice.
      const claimed = await query<{ id: string }>(
        `update payment_webhook_events
            set status = 'processing', order_id = $2, attempts = attempts + 1,
                lease_until = now() + make_interval(secs => $3)
          where id = $1 and status = 'unmatched'
          returning id`,
        [row.id, orderId, DELIVERY_LEASE_SECONDS]
      );
      if (!claimed.length) continue;

      try {
        await applyDelivery(row.id, orderId, {
          outcome: (row.outcome ?? undefined) as DeliveryFacts['outcome'],
          amountMinor: row.amount_minor == null ? undefined : Number(row.amount_minor),
          currency: row.currency ?? undefined,
          reason: row.outcome_reason ?? undefined,
        });
        applied++;
      } catch (e) {
        console.error('[payments] failed to reconcile held delivery', row.id, e);
        await markFailed(row.id, e);
      }
    }
  } catch (e) {
    console.error('[payments] reconciliation lookup failed for', provider, providerRef, e);
  }
  return applied;
}
