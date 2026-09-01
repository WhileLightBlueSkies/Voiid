'use client';

//
// One event: its pricing, its ticket counts, and the order ledger behind them.
//
// The totals are grouped BY STATUS rather than summed into one net figure, because a single
// number cannot answer both "what did this take" and "what went back". A payment operator
// reconciling against the provider needs each line separately.
//

import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import Link from 'next/link';
import Shell from '../../../components/Shell';
import { PageHeader, Async, Pill, Stat, when, name, money } from '../../../components/ui';
import { api } from '../../../lib/api';

type Event = {
  id: string; community_id: string; title: string; description: string | null;
  starts_at: string; ends_at: string | null; location_text: string | null;
  capacity: number | null; price_minor: number; currency: string; status: string;
  created_at: string; community_name: string | null; community_handle: string | null;
  host_name: string | null; host_username: string | null;
};
type Order = {
  id: string; buyer_id: string; quantity: number;
  unit_price_minor: number; amount_minor: number; currency: string;
  provider: string; provider_ref: string; status: string;
  failure_reason: string | null; created_at: string; settled_at: string | null;
  buyer_name: string | null; buyer_username: string | null;
};
type Total = { status: string; orders: number; seats: number; amount_minor: string | number };
type Tickets = { issued: number; checked_in: number; voided: number };
type Payload = { event: Event; orders: Order[]; totals: Total[]; tickets: Tickets };

const ORDER_TONE: Record<string, 'ok' | 'danger' | 'warning' | 'accent' | undefined> = {
  paid: 'ok', refunded: 'danger', failed: 'danger', pending: 'warning', cancelled: undefined,
};

export default function EventDetail() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const { id } = useParams<{ id: string }>();
  const [d, setD] = useState<Payload | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setD(await api<Payload>(`/events/${id}`));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load this event');
    }
  }, [id]);

  useEffect(() => { void load(); }, [load]);

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
            right={<Pill tone={d.event.status === 'published' ? 'ok'
                               : d.event.status === 'cancelled' ? 'danger' : undefined}>
                     {d.event.status}
                   </Pill>}
          />

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
                      <th>Provider</th><th>Placed</th><th>Status</th>
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
                          <Pill tone={ORDER_TONE[o.status]}>{o.status}</Pill>
                          {o.failure_reason && (
                            <div className="mute" style={{ fontSize: 11 }}>{o.failure_reason}</div>
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
