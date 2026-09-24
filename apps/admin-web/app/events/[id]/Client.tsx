'use client';

//
// One event: its pricing, its ticket counts, and the order ledger behind them.
//
// The totals are grouped BY STATUS rather than summed into one net figure, because a single
// number cannot answer both "what did this take" and "what went back". A payment operator
// reconciling against the provider needs each line separately.
//

import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import Shell, { type Me } from '../../../components/Shell';
import { WithRecordId } from '../../../components/RecordId';
import { PageHeader, Async, Pill, Stat, when, name, money } from '../../../components/ui';
import { api } from '../../../lib/api';
import { RefundDialog, refundState, REFUND_TONE, REFUND_LABEL } from '../../../components/Refunds';

type Event = {
  id: string; community_id: string; title: string; description: string | null;
  starts_at: string; ends_at: string | null; location_text: string | null;
  capacity: number | null; price_minor: number; currency: string; status: string;
  created_at: string; community_name: string | null; community_handle: string | null;
  host_name: string | null; host_username: string | null;
  suspended_at: string | null;
};
type Order = {
  id: string; buyer_id: string; quantity: number;
  unit_price_minor: number; amount_minor: number; currency: string;
  provider: string; provider_ref: string; status: string;
  failure_reason: string | null; created_at: string; settled_at: string | null;
  buyer_name: string | null; buyer_username: string | null;
  refund_requested_at: string | null; refund_reason: string | null;
  refund_error: string | null; refund_attempts: number;
};
type Total = { status: string; orders: number; seats: number; amount_minor: string | number };
type Tickets = { issued: number; checked_in: number; voided: number };
type Payload = { event: Event; orders: Order[]; totals: Total[]; tickets: Tickets };

const ORDER_TONE: Record<string, 'ok' | 'danger' | 'warning' | 'accent' | undefined> = {
  paid: 'ok', refunded: 'danger', failed: 'danger', pending: 'warning', cancelled: undefined,
};

export default function EventDetail() {
  // The id comes from the address bar, not useParams() — see components/RecordId.tsx.
  return <Shell>{(me) => <WithRecordId section="events" noun="event">{(id) => <Body key={id} me={me} id={id} />}</WithRecordId>}</Shell>;
}

function Body({ me, id }: { me: Me; id: string }) {
  const [busy, setBusy] = useState(false);
  const [writeError, setWriteError] = useState<string | null>(null);
  const [d, setD] = useState<Payload | null>(null);
  const [error, setError] = useState<string | null>(null);
  /** The order being refunded, or 'all' for every paid order; null when no dialog is open. */
  const [refunding, setRefunding] = useState<Order | 'all' | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setD(await api<Payload>(`/events/${id}`));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load this event');
    }
  }, [id]);

  useEffect(() => { void load(); }, [load]);

  async function suspend() {
    const reason = window.prompt(
      'Why is this listing being taken off sale? (recorded in the audit log)')?.trim();
    if (!reason) return;
    setBusy(true); setWriteError(null);
    try {
      await api(`/events/${id}/suspend`, { method: 'POST', json: { reason } });
      await load();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally { setBusy(false); }
  }

  async function restore() {
    setBusy(true); setWriteError(null);
    try {
      await api(`/events/${id}/restore`, { method: 'POST', json: {} });
      await load();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally { setBusy(false); }
  }

  async function refund(reason: string) {
    const target = refunding;
    setRefunding(null);
    if (!target) return;
    setBusy(true); setWriteError(null); setNotice(null);
    try {
      if (target === 'all') {
        const r = await api<{ requested: number; failed: number }>(
          `/events/${id}/refund-all`, { method: 'POST', json: { reason } });
        setNotice(`${r.requested} refund${r.requested === 1 ? '' : 's'} requested` +
                  (r.failed ? ` · ${r.failed} failed — see the orders below` : '.'));
      } else {
        await api(`/events/${id}/orders/${target.id}/refund`, { method: 'POST', json: { reason } });
        setNotice(`Refund requested for ${name(target.buyer_name, target.buyer_username, 'this order')}.`);
      }
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'the refund did not go through');
    } finally {
      setBusy(false);
      await load();
    }
  }

  async function check(o: Order) {
    setBusy(true); setWriteError(null); setNotice(null);
    try {
      const r = await api<{ state: string | null }>(`/orders/${o.id}/refund-sync`, { method: 'POST', json: {} });
      setNotice(r.state === 'refunded' ? 'Cashfree confirms it — refunded.'
              : r.state === 'refund_pending' ? 'Still on its way at Cashfree.'
              : r.state === 'failed' ? 'Cashfree says this refund failed.' : 'Nothing to check.');
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'could not reach Cashfree');
    } finally {
      setBusy(false);
      await load();
    }
  }

  const by = (s: string) => d?.totals.find((t) => t.status === s);
  const cur = d?.event.currency ?? 'INR';
  const paid = by('paid');
  const refunded = by('refunded');
  const pending = by('pending');

  return (
    <Async loading={!d} error={error} empty={false} emptyText="">
      {d && (
        <>
          <div style={{ marginBottom: 14 }}>
            <Link href="/events" style={{ fontSize: 14 }}>← Events</Link>
          </div>

          <PageHeader
            title={d.event.title}
            subtitle={
              d.event.community_handle
                ? `@${d.event.community_handle} · ${when(d.event.starts_at)}`
                : when(d.event.starts_at)
            }
            right={
              <div className="row" style={{ gap: 8, alignItems: 'center' }}>
                <Pill tone={d.event.status === 'published' ? 'ok'
                            : d.event.status === 'cancelled' ? 'danger' : undefined}>
                  {d.event.status}
                </Pill>
                {d.event.suspended_at && <Pill tone="danger">Suspended</Pill>}
                {me.role === 'admin' && (paid?.orders ?? 0) > 0 && (
                  <button className="ghost" disabled={busy} onClick={() => setRefunding('all')}>
                    Refund all paid orders
                  </button>
                )}
                {me.role === 'admin' && (
                  d.event.suspended_at
                    ? <button className="ghost" disabled={busy}
                              onClick={() => void restore()}>Put back on sale</button>
                    : <button className="ghost" disabled={busy}
                              onClick={() => void suspend()}>Take off sale</button>
                )}
              </div>
            }
          />

          {writeError && <div className="notice error" style={{ marginBottom: 16 }}>{writeError}</div>}
          {notice && <div className="notice" style={{ marginBottom: 16 }}>{notice}</div>}
          {refunding && (
            <RefundDialog
              title={refunding === 'all' ? `Refund every paid order for “${d.event.title}”?`
                                         : `Refund ${money(refunding.amount_minor, refunding.currency)} to ${name(refunding.buyer_name, refunding.buyer_username, 'this buyer')}?`}
              detail={refunding === 'all'
                ? `${paid?.orders ?? 0} orders, ${money(paid?.amount_minor ?? 0, cur)} in total. Each buyer gets their full amount back to how they paid, usually within 5–7 working days, and their tickets stop working.`
                : 'The full amount goes back to how they paid, usually within 5–7 working days. Their tickets stop working once Cashfree confirms.'}
              defaultReason={refunding === 'all' ? 'event_cancelled' : 'attendee_request'}
              onCancel={() => setRefunding(null)}
              onConfirm={(reason) => void refund(reason)}
            />
          )}

          {/* Says what suspension DID and did not do. A moderator who thinks this voided the
              tickets will not chase the refund that someone is actually owed. */}
          {d.event.suspended_at && (
            <div className="notice error" style={{ marginBottom: 16 }}>
              Off sale since {when(d.event.suspended_at)}. No new orders are accepted.
              Tickets already issued remain valid — voiding or refunding them is a separate
              decision.
            </div>
          )}

          <div className="stats" style={{ marginBottom: 22 }}>
            <Stat label="Ticket price"
                  value={d.event.price_minor > 0 ? money(d.event.price_minor, cur) : 'Free'} />
            <Stat label="Collected" value={money(paid?.amount_minor ?? 0, cur)}
                  sub={`${paid?.orders ?? 0} paid orders`} />
            <Stat label="Refunded" value={money(refunded?.amount_minor ?? 0, cur)}
                  sub={`${refunded?.orders ?? 0} refunds`} />
            <Stat label="Tickets" value={String(d.tickets.issued)}
                  sub={d.event.capacity ? `of ${d.event.capacity} capacity` : 'no capacity set'} />
            <Stat label="Checked in" value={String(d.tickets.checked_in)}
                  sub={d.tickets.voided > 0 ? `${d.tickets.voided} void` : undefined} />
          </div>

          {/* Pending money is called out rather than folded into the take: it is the line an
              operator has to chase, and it disappears if it is only ever netted. */}
          {pending && pending.orders > 0 && (
            <div className="notice" style={{ marginBottom: 22 }}>
              {pending.orders} order{pending.orders === 1 ? '' : 's'} still pending —{' '}
              {money(pending.amount_minor, cur)} not settled.
            </div>
          )}

          {d.event.location_text && (
            <div className="card" style={{ marginBottom: 22 }}>
              <div className="mute" style={{ fontSize: 12, marginBottom: 4 }}>Location</div>
              <div style={{ fontSize: 14 }}>{d.event.location_text}</div>
              {d.event.host_name && (
                <div className="mute" style={{ fontSize: 12, marginTop: 8 }}>
                  Host: {name(d.event.host_name, d.event.host_username)}
                </div>
              )}
            </div>
          )}

          <h2 style={{ marginBottom: 10 }}>Orders</h2>
          <div className="card">
            {d.orders.length === 0 ? (
              <div className="empty" style={{ padding: '20px 0' }}>No orders.</div>
            ) : (
              <div className="scroller">
                <table>
                  <thead>
                    <tr>
                      <th>Buyer</th><th>Qty</th><th>Amount</th>
                      <th>Provider</th><th>Placed</th><th>Status</th><th />
                    </tr>
                  </thead>
                  <tbody>
                    {d.orders.map((o) => (
                      <tr key={o.id}>
                        <td>{name(o.buyer_name, o.buyer_username, o.buyer_id.slice(0, 8))}</td>
                        <td className="mono">{o.quantity}</td>
                        <td className="mono" style={{ whiteSpace: 'nowrap' }}>
                          {money(o.amount_minor, o.currency)}
                        </td>
                        <td className="muted" style={{ fontSize: 12 }}>
                          {o.provider}
                          {/* The provider reference is how a row is matched to the gateway's
                              own record, so it is shown in full rather than truncated. */}
                          <div className="mono mute" style={{ fontSize: 11 }}>{o.provider_ref}</div>
                        </td>
                        <td className="muted" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>
                          {when(o.created_at)}
                        </td>
                        <td>
                          {refundState(o) ? (
                            <Pill tone={REFUND_TONE[refundState(o)!]}>{REFUND_LABEL[refundState(o)!]}</Pill>
                          ) : (
                            <Pill tone={ORDER_TONE[o.status]}>{o.status}</Pill>
                          )}
                          {o.refund_reason && <div className="mute" style={{ fontSize: 11 }}>{o.refund_reason}</div>}
                          {o.refund_error && o.status === 'paid' && (
                            <div style={{ fontSize: 11, color: 'var(--danger, #c33)' }}>{o.refund_error}</div>
                          )}
                          {o.failure_reason && (
                            <div className="mute" style={{ fontSize: 11 }}>{o.failure_reason}</div>
                          )}
                        </td>
                        <td style={{ whiteSpace: 'nowrap', textAlign: 'right' }}>
                          {o.status === 'paid' && me.role === 'admin' && !o.refund_requested_at && !o.refund_error && (
                            <button className="ghost" disabled={busy} onClick={() => setRefunding(o)}>Refund</button>
                          )}
                          {o.status === 'paid' && me.role === 'admin' && o.refund_error && (
                            <button className="ghost" disabled={busy} onClick={() => setRefunding(o)}>Retry refund</button>
                          )}
                          {o.status === 'paid' && o.refund_requested_at && !o.refund_error && (
                            <button className="ghost" disabled={busy} onClick={() => void check(o)}>Check with Cashfree</button>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </>
      )}
    </Async>
  );
}
