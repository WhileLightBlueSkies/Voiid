// Refunds for paid event orders — requested by a host or an admin, confirmed by the provider.
//
// ── WHO DECIDES, WHO CONFIRMS ────────────────────────────────────────────────────
//
// A person asks (host for their own event, or a Voiid admin). The provider confirms. An order
// stays 'paid' with `refund_requested_at` set — "refund on the way" — until the provider's
// signed webhook says the money went back; only then does payments/inbox.ts move it to
// 'refunded' and void its tickets. Nothing here marks a paid order refunded on its own say-so.
//
// ── A REFUND NEVER HAPPENS TWICE ─────────────────────────────────────────────────
//
// The refund id is `rf_<order>_<attempt>` and doubles as the provider's idempotency key, so a
// double tap, a retried request or two admins at once all name the SAME refund. A new attempt
// number is used only when the previous one definitively failed, because the provider will not
// accept a refund id it has already seen.
//
// ── WHEN THE WEBHOOK NEVER COMES ─────────────────────────────────────────────────
//
// `sweepPendingRefunds` asks the provider about refunds that have been pending a while and
// settles them either way, so a lost webhook cannot leave a buyer's refund "on the way" forever.
import { query } from '../db';
import { FREE_PROVIDER, providerByName } from './provider';
import { markRefunded } from './inbox';

export const REFUND_REASONS: Record<string, string> = {
  event_cancelled: 'Event cancelled',
  attendee_request: 'Requested by the attendee',
  duplicate_payment: 'Duplicate payment',
  event_changed: 'Event changed',
};

export type RefundState = 'refund_pending' | 'refunded' | 'failed';
export interface RefundResult { orderId: string; status: RefundState; error?: string }

export class RefundError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

interface RefundOrderRow {
  id: string;
  status: string;
  provider: string;
  provider_ref: string;
  amount_minor: string;
  organiser_minor: string | null;
  split_vendor_id: string | null;
  refund_requested_at: string | null;
  refund_error: string | null;
  refund_attempts: number;
  title: string;
}

function refundId(orderId: string, attempt: number): string {
  return `rf_${orderId.replace(/-/g, '')}_${attempt}`;
}

/** Turns a reason code or free text into what is stored and shown. */
export function refundReasonText(reason: unknown): string {
  const raw = typeof reason === 'string' ? reason.trim() : '';
  return (REFUND_REASONS[raw] ?? raw).slice(0, 200) || 'Refund';
}

async function loadOrder(orderId: string): Promise<RefundOrderRow | undefined> {
  return (await query<RefundOrderRow>(
    `select o.id, o.status, o.provider, o.provider_ref, o.amount_minor::text as amount_minor,
            o.organiser_minor::text as organiser_minor, o.split_vendor_id,
            o.refund_requested_at, o.refund_error, o.refund_attempts, e.title
       from event_orders o join community_events e on e.id = o.event_id
      where o.id = $1`, [orderId]))[0];
}

/**
 * Ask for a paid order's money back. Idempotent: a refund already on the way is reported, not
 * requested again. A free RSVP is simply withdrawn — there is no money to move.
 */
/**
 * `actorId` is the HOST's user id, or null for a Voiid admin — admins are not rows in `users`,
 * and the admin audit log records which one it was.
 */
export async function requestRefund(orderId: string, actorId: string | null, reason: unknown): Promise<RefundResult> {
  const order = await loadOrder(orderId);
  if (!order) throw new RefundError('no such order', 404);
  if (order.status === 'refunded') return { orderId, status: 'refunded' };
  if (order.status !== 'paid') {
    throw new RefundError(`only a paid order can be refunded — this one is ${order.status}`, 409);
  }
  const text = refundReasonText(reason);

  if (order.provider === FREE_PROVIDER) {
    await query(`update event_orders set refund_reason = $2, refund_requested_by = $3,
                        refund_requested_at = now() where id = $1`, [orderId, text, actorId]);
    await markRefunded(orderId);
    return { orderId, status: 'refunded' };
  }

  // Already on its way and not failed: the same refund, not a second one.
  if (order.refund_requested_at && !order.refund_error) return { orderId, status: 'refund_pending' };

  const provider = providerByName(order.provider);
  if (!provider?.refund) throw new RefundError('refunds are not available for this payment method', 501);

  // A fresh attempt only after a failure; the first request is attempt 1.
  const attempt = order.refund_error ? order.refund_attempts + 1 : Math.max(1, order.refund_attempts);
  const amount = Number(order.amount_minor);
  const hostShare = order.organiser_minor ? Number(order.organiser_minor) : 0;
  try {
    await provider.refund({
      providerRef: order.provider_ref,
      refundId: refundId(orderId, attempt),
      amountMinor: amount,
      note: order.title,
      splits: order.split_vendor_id && hostShare > 0
        ? [{ vendorId: order.split_vendor_id, amountMinor: Math.min(hostShare, amount) }]
        : undefined,
    });
  } catch (e) {
    const message = ((e as Error).message || 'the refund was not accepted').slice(0, 300);
    await query(
      `update event_orders set refund_error = $2, refund_reason = $3, refund_requested_by = $4,
              refund_attempts = $5
        where id = $1`, [orderId, message, text, actorId, attempt]);
    return { orderId, status: 'failed', error: message };
  }
  await query(
    `update event_orders set refund_requested_at = now(), refund_requested_by = $2, refund_reason = $3,
            refund_error = null, refund_attempts = $4
      where id = $1 and status = 'paid'`, [orderId, actorId, text, attempt]);
  return { orderId, status: 'refund_pending' };
}

/** Every paid order of an event — "cancel and refund everyone". Each order stands alone. */
export async function refundEvent(eventId: string, actorId: string | null, reason: unknown): Promise<RefundResult[]> {
  const orders = await query<{ id: string }>(
    `select id from event_orders where event_id = $1 and status = 'paid' order by created_at`, [eventId]);
  const results: RefundResult[] = [];
  for (const o of orders) {
    try {
      results.push(await requestRefund(o.id, actorId, reason));
    } catch (e) {
      results.push({ orderId: o.id, status: 'failed', error: (e as Error).message });
    }
  }
  return results;
}

/**
 * Ask the provider where a requested refund stands and settle it: refunded, still on its way,
 * or failed (with the reason kept so it can be retried).
 */
export async function syncRefund(orderId: string): Promise<RefundState | null> {
  const order = await loadOrder(orderId);
  if (!order || !order.refund_requested_at) return null;
  if (order.status === 'refunded') return 'refunded';
  const provider = providerByName(order.provider);
  if (!provider?.refundStatus) return null;
  const state = await provider.refundStatus(order.provider_ref, refundId(orderId, Math.max(1, order.refund_attempts)));
  if (state === 'succeeded') {
    await markRefunded(orderId);
    return 'refunded';
  }
  if (state === 'failed' || state === null) {
    await query(`update event_orders set refund_error = $2 where id = $1 and status = 'paid'`,
      [orderId, state === null ? 'The payment provider has no record of this refund.' : 'The payment provider cancelled this refund.']);
    return 'failed';
  }
  return 'refund_pending';
}

/** Refunds pending more than ten minutes, checked with the provider. Never throws. */
export async function sweepPendingRefunds(): Promise<void> {
  const rows = await query<{ id: string }>(
    `select id from event_orders
      where status = 'paid' and refund_requested_at is not null and refund_error is null
        and refund_requested_at < now() - interval '10 minutes'
      order by refund_requested_at limit 50`);
  for (const r of rows) {
    try { await syncRefund(r.id); }
    catch (e) { console.warn('[refunds] sync failed', r.id, (e as Error).message); }
  }
}
