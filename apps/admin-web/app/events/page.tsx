'use client';

//
// Events and what they took.
//
// The dashboard could count events and orders and show nothing else: not what a ticket
// costs, not what an event collected, not whether a buyer's money settled. This is that
// page.
//
// Revenue here is PAID orders only. Pending money is not money, and a page that counts it
// overstates every figure an operator would act on. Refunds are shown beside the take
// rather than netted into it — "collected" and "refunded" answer different questions.
//

import { useState } from 'react';
import Link from 'next/link';
import Shell from '../../components/Shell';
import { PageHeader, Pill, when, money } from '../../components/ui';
import { ListTable } from '../../components/List';
import { useList } from '../../components/useList';

type EventRow = {
  id: string; community_id: string; title: string;
  starts_at: string; location_text: string | null;
  capacity: number | null; price_minor: number; currency: string;
  status: string; created_at: string;
  community_name: string | null; community_handle: string | null;
  revenue_minor: string | number; refunded_minor: string | number;
  paid_orders: number; pending_orders: number;
  tickets: number; checked_in: number;
};

const STATUS_TONE: Record<string, 'ok' | 'danger' | 'accent' | undefined> = {
  published: 'ok', cancelled: 'danger', draft: undefined,
};

export default function Events() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [status, setStatus] = useState('');
  const [paidOnly, setPaidOnly] = useState(false);
  const list = useList<EventRow>('/events', 'events', {
    ...(status ? { status } : {}),
    ...(paidOnly ? { paid: 'true' } : {}),
  });

  return (
    <>
      <PageHeader
        title="Events"
        subtitle="Ticket pricing, orders and what each event collected"
      />

      <div className="row" style={{ gap: 8, marginBottom: 16, flexWrap: 'wrap' }}>
        {['', 'published', 'draft', 'cancelled'].map((s) => (
          <button key={s || 'all'}
                  className={status === s ? 'chip active' : 'chip'}
                  onClick={() => setStatus(s)}>
            {s === '' ? 'All' : s}
          </button>
        ))}
        <button className={paidOnly ? 'chip active' : 'chip'}
                onClick={() => setPaidOnly((v) => !v)}>
          Paid only
        </button>
      </div>

      <ListTable
        head={['Event', 'Community', 'Price', 'Collected', 'Tickets', 'Starts', 'Status']}
        loading={list.loading}
        error={list.error}
        empty={list.rows.length === 0}
        emptyText="No events match that filter."
        cursor={list.cursor}
        onMore={list.more}
      >
        {list.rows.map((e) => {
          const refunded = Number(e.refunded_minor) || 0;
          return (
            <tr key={e.id}>
              <td style={{ maxWidth: 260 }}>
                <Link href={`/events/${e.id}`} style={{ fontWeight: 600, color: 'var(--text)' }}>
                  {e.title}
                </Link>
                {e.location_text && (
                  <div className="mute" style={{ fontSize: 12 }}>{e.location_text}</div>
                )}
              </td>
              <td className="muted" style={{ fontSize: 13 }}>
                {e.community_handle
                  ? <Link href={`/communities/${e.community_id}`}>@{e.community_handle}</Link>
                  : (e.community_name ?? '—')}
              </td>
              <td className="mono" style={{ whiteSpace: 'nowrap' }}>
                {/* Free is a decision, not a missing value, so it says so rather than
                    rendering ₹0.00 and reading like an unfinished row. */}
                {e.price_minor > 0 ? money(e.price_minor, e.currency) : <span className="mute">Free</span>}
              </td>
              <td className="mono" style={{ whiteSpace: 'nowrap' }}>
                {money(e.revenue_minor, e.currency)}
                {refunded > 0 && (
                  <div style={{ fontSize: 12 }} className="mute">
                    −{money(refunded, e.currency)} refunded
                  </div>
                )}
                {e.pending_orders > 0 && (
                  <div style={{ fontSize: 12 }} className="mute">
                    {e.pending_orders} pending
                  </div>
                )}
              </td>
              <td className="mono" style={{ whiteSpace: 'nowrap' }}>
                {e.tickets}
                {e.capacity ? <span className="mute"> / {e.capacity}</span> : null}
                {e.checked_in > 0 && (
                  <div className="mute" style={{ fontSize: 12 }}>{e.checked_in} in</div>
                )}
              </td>
              <td className="muted" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>
                {when(e.starts_at)}
              </td>
              <td><Pill tone={STATUS_TONE[e.status]}>{e.status}</Pill></td>
            </tr>
          );
        })}
      </ListTable>
    </>
  );
}
