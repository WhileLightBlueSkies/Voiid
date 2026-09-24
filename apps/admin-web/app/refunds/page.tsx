'use client';

//
// Every refund, in one queue: what is on its way, what failed, what went back.
//
// Failed refunds are the line to act on — a buyer is owed money and the provider refused — so
// they get a tab of their own and a Retry. "Check with Cashfree" asks the provider directly
// for any refund that has sat on its way, for when its confirming webhook never arrived (a
// sweep does the same every 15 minutes on its own).
//

import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import Shell, { type Me } from '../../components/Shell';
import { PageHeader, Async, Pill, Stat, when, name, money } from '../../components/ui';
import { api } from '../../lib/api';
import { RefundDialog, REFUND_LABEL, REFUND_TONE, type RefundState } from '../../components/Refunds';

type Row = {
  id: string; event_id: string; event_title: string; community_name: string | null;
  buyer_id: string; buyer_name: string | null; buyer_username: string | null;
  amount_minor: string | number; currency: string; provider: string; status: string;
  refund_requested_at: string | null; refund_reason: string | null; refund_error: string | null;
  refund_attempts: number; settled_at: string | null; created_at: string;
  refund_state: RefundState;
};
type Totals = { pending: number; failed: number; refunded: number;
                refunded_minor: string | number; pending_minor: string | number };

const TABS: { key: 'all' | RefundState; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'pending', label: 'On the way' },
  { key: 'failed', label: 'Failed' },
  { key: 'refunded', label: 'Refunded' },
];

export default function Refunds() {
  return <Shell>{(me) => <Body me={me} />}</Shell>;
}

function Body({ me }: { me: Me }) {
  const [tab, setTab] = useState<'all' | RefundState>('all');
  const [rows, setRows] = useState<Row[] | null>(null);
  const [totals, setTotals] = useState<Totals | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [retrying, setRetrying] = useState<Row | null>(null);

  const load = useCallback(async () => {
    try {
      const d = await api<{ refunds: Row[]; totals: Totals }>(`/refunds?state=${tab}`);
      setRows(d.refunds); setTotals(d.totals); setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load refunds');
    }
  }, [tab]);

  useEffect(() => { setRows(null); void load(); }, [load]);

  async function check(r: Row) {
    setBusy(true); setNotice(null);
    try {
      const s = await api<{ state: string | null }>(`/orders/${r.id}/refund-sync`, { method: 'POST', json: {} });
      setNotice(s.state === 'refunded' ? 'Cashfree confirms it — refunded.'
              : s.state === 'refund_pending' ? 'Still on its way at Cashfree.'
              : s.state === 'failed' ? 'Cashfree says this refund failed.' : 'Nothing to check.');
    } catch (e) {
      setNotice(e instanceof Error ? e.message : 'could not reach Cashfree');
    } finally { setBusy(false); await load(); }
  }

  async function retry(reason: string) {
    const r = retrying;
    setRetrying(null);
    if (!r) return;
    setBusy(true); setNotice(null);
    try {
      await api(`/events/${r.event_id}/orders/${r.id}/refund`, { method: 'POST', json: { reason } });
      setNotice('Refund requested again.');
    } catch (e) {
      setNotice(e instanceof Error ? e.message : 'the retry did not go through');
    } finally { setBusy(false); await load(); }
  }

  return (
    <>
      <PageHeader title="Refunds" subtitle="Money going back to buyers for paid events" />

      {totals && (
        <div className="stats" style={{ marginBottom: 22 }}>
          <Stat label="On the way" value={String(totals.pending)} sub={money(totals.pending_minor, 'INR')} />
          <Stat label="Failed" value={String(totals.failed)} tone={totals.failed > 0 ? 'danger' : undefined}
                sub={totals.failed > 0 ? 'needs a retry' : undefined} />
          <Stat label="Refunded" value={String(totals.refunded)} sub={money(totals.refunded_minor, 'INR')} />
        </div>
      )}

      <div className="row" style={{ gap: 6, marginBottom: 14, flexWrap: 'wrap' }}>
        {TABS.map((t) => (
          <button key={t.key} className={tab === t.key ? '' : 'ghost'} onClick={() => setTab(t.key)}>
            {t.label}
          </button>
        ))}
      </div>

      {notice && <div className="notice" style={{ marginBottom: 14 }}>{notice}</div>}
      {retrying && (
        <RefundDialog
          title={`Retry the refund to ${name(retrying.buyer_name, retrying.buyer_username, 'this buyer')}?`}
          detail={`${money(retrying.amount_minor, retrying.currency)} for “${retrying.event_title}”. It failed last time: ${retrying.refund_error ?? 'no reason given'}.`}
          defaultReason="attendee_request"
          onCancel={() => setRetrying(null)}
          onConfirm={(reason) => void retry(reason)}
        />
      )}

      <Async loading={!rows} error={error} empty={rows?.length === 0} emptyText="No refunds here.">
        {rows && (
          <div className="card">
            <div className="scroller">
              <table>
                <thead>
                  <tr><th>Buyer</th><th>Event</th><th>Amount</th><th>Reason</th><th>Requested</th><th>Status</th><th /></tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.id}>
                      <td>{name(r.buyer_name, r.buyer_username, r.buyer_id.slice(0, 8))}</td>
                      <td>
                        <Link href={`/events/${r.event_id}`}>{r.event_title}</Link>
                        {r.community_name && <div className="mute" style={{ fontSize: 11 }}>{r.community_name}</div>}
                      </td>
                      <td className="mono" style={{ whiteSpace: 'nowrap' }}>{money(r.amount_minor, r.currency)}</td>
                      <td style={{ fontSize: 13 }}>{r.refund_reason ?? '—'}</td>
                      <td className="muted" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>{when(r.refund_requested_at)}</td>
                      <td>
                        <Pill tone={REFUND_TONE[r.refund_state]}>{REFUND_LABEL[r.refund_state]}</Pill>
                        {r.refund_error && r.refund_state === 'failed' && (
                          <div style={{ fontSize: 11, color: 'var(--danger)' }}>{r.refund_error}</div>
                        )}
                        {r.refund_attempts > 1 && <div className="mute" style={{ fontSize: 11 }}>attempt {r.refund_attempts}</div>}
                      </td>
                      <td style={{ whiteSpace: 'nowrap', textAlign: 'right' }}>
                        {r.refund_state === 'failed' && me.role === 'admin' && (
                          <button className="ghost" disabled={busy} onClick={() => setRetrying(r)}>Retry</button>
                        )}
                        {r.refund_state === 'pending' && (
                          <button className="ghost" disabled={busy} onClick={() => void check(r)}>Check with Cashfree</button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </Async>
    </>
  );
}
