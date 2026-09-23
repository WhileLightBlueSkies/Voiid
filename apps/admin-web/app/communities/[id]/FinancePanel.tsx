'use client';

//
// Event finance for one community: the commission Voiid takes on its ticket sales, what has
// been sold, and the audit trail of rate changes.
//
// Everything here is an ORDER RECORD, before processing fees and taxes — never a bank
// balance. The headline figures count PAID orders only; the table below them shows every
// status, because a pending or refunded order is still something an operator must be able
// to see and explain.
//
// Money stays in minor units as BigInt end to end. A float rupee is a reconciliation bug
// waiting to happen, so the decimal point is placed once, in `money`, and never computed.
//

import { useCallback, useEffect, useState } from 'react';
import {
  CalendarDays, ChevronLeft, ChevronRight, History, Info, Percent, ReceiptText, RefreshCw,
  Ticket, Wallet,
} from 'lucide-react';
import { api } from '../../../lib/api';

type Total = {
  currency: string; status: string; orders: number; tickets: string;
  gross_minor: string; commission_minor: string | null; organiser_minor: string | null;
  unpriced_orders: number;
};
type Order = {
  id: string; event_title: string; status: string; quantity: number; currency: string;
  amount_minor: string; commission_bps: number | null; commission_minor: string | null;
  organiser_minor: string | null; created_at: string; checked_in: number;
};
type Data = {
  community: { name: string; event_commission_bps: number };
  totals: Total[];
  orders: Order[];
  has_more: boolean;
  events: { id: string; title: string; status: string; starts_at: string; orders: number; checked_in: number }[];
  events_truncated: boolean;
  history: { created_at: string; admin_email: string; detail: { previous_bps: number; commission_bps: number; reason: string } }[];
};

/** The platform default (communities.event_commission_bps defaults to 2500). */
const DEFAULT_BPS = 2500;
const PAGE = 50;

function money(v: string | null, c: string): string {
  if (v === null) return 'Not recorded';
  const n = BigInt(v);
  const neg = n < 0n;
  const abs = neg ? -n : n;
  const major = (abs / 100n).toLocaleString('en-IN');
  return `${neg ? '−' : ''}${c} ${major}.${(abs % 100n).toString().padStart(2, '0')}`;
}

const pct = (bps: number) => `${(bps / 100).toLocaleString(undefined, { maximumFractionDigits: 2 })}%`;
const when = (iso: string) => new Date(iso).toLocaleString(undefined, {
  day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
});

const STATUS_TONE: Record<string, string> = {
  paid: 'ok', published: 'ok',
  pending: 'warning', draft: '',
  refunded: 'attention',
  failed: 'danger', cancelled: 'danger',
};

function StatusPill({ status }: { status: string }) {
  const tone = STATUS_TONE[status] ?? '';
  return <span className={`pill ${tone}`} style={{ textTransform: 'capitalize' }}>{status}</span>;
}

/** Paid orders only, summed per currency. Commission/organiser skip unpriced rows, and say so. */
function paidByCurrency(totals: Total[]) {
  const by = new Map<string, { gross: bigint; commission: bigint; organiser: bigint; orders: number; places: bigint; unpriced: number }>();
  for (const t of totals) {
    if (t.status !== 'paid') continue;
    const cur = by.get(t.currency) ?? { gross: 0n, commission: 0n, organiser: 0n, orders: 0, places: 0n, unpriced: 0 };
    cur.gross += BigInt(t.gross_minor);
    if (t.commission_minor !== null) cur.commission += BigInt(t.commission_minor);
    if (t.organiser_minor !== null) cur.organiser += BigInt(t.organiser_minor);
    cur.orders += t.orders;
    cur.places += BigInt(t.tickets);
    cur.unpriced += t.unpriced_orders;
    by.set(t.currency, cur);
  }
  return [...by.entries()];
}

export default function FinancePanel({ id }: { id: string }) {
  const [data, setData] = useState<Data | null>(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [rate, setRate] = useState('25');
  const [reason, setReason] = useState('');
  const [offset, setOffset] = useState(0);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setBusy(true);
    try {
      const d = await api<Data>(`/communities/${id}/finance?offset=${offset}`);
      setData(d);
      setRate(String(d.community.event_commission_bps / 100));
      setError('');
    } catch (e) {
      setData(null);
      setError(e instanceof Error ? e.message : 'Unable to load finance');
    } finally {
      setBusy(false);
    }
  }, [id, offset]);

  useEffect(() => { void load(); }, [load]);

  const rateValid = /^\d{1,3}(\.\d{1,2})?$/.test(rate) && Number(rate) <= 100;
  const rateChanged = data !== null && Math.round(Number(rate) * 100) !== data.community.event_commission_bps;
  const reasonOk = reason.trim().length >= 5;

  async function save() {
    if (!data) return;
    setBusy(true);
    setError('');
    setNotice('');
    try {
      if (!rateValid) throw Error('Enter a percentage from 0 to 100, with at most two decimal places.');
      // expected_bps makes the save conditional: if another admin changed the rate since this
      // page loaded, the server answers 409 instead of silently overwriting their change.
      await api(`/communities/${id}/commission`, {
        method: 'PATCH',
        json: { commission_bps: Math.round(Number(rate) * 100), expected_bps: data.community.event_commission_bps, reason },
      });
      await load();
      setReason('');
      setNotice('Commission saved for new orders. Existing orders keep the rate they were sold at.');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to save');
    } finally {
      setBusy(false);
    }
  }

  const current = data?.community.event_commission_bps ?? null;
  const paid = data ? paidByCurrency(data.totals) : [];

  return (
    <section className="mb-6 rounded-[22px] bg-card p-5 shadow-[var(--shadow-1)] ring-1 ring-black/[0.04] sm:p-6">
      {/* ── Header ── */}
      <header className="mb-5 flex flex-wrap items-start gap-3">
        <span className="grid h-11 w-11 shrink-0 place-items-center rounded-full bg-[var(--accent)] text-[var(--lime)]">
          <Wallet size={19} />
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="text-[18px]">Event finance</h2>
          <p className="m-0 mt-0.5 text-sm text-[var(--text-dim)]">
            Order records before processing fees and taxes — not bank balances.
          </p>
        </div>
        <button
          onClick={() => void load()}
          disabled={busy}
          className="ghost inline-flex h-10 items-center gap-2 px-4"
        >
          <RefreshCw size={15} className={busy ? 'animate-spin' : ''} />
          {busy ? 'Loading…' : 'Refresh'}
        </button>
      </header>

      {error && <div role="alert" className="notice error mb-4">{error}</div>}
      {notice && (
        <div role="status" className="mb-4 rounded-[12px] bg-[var(--lime-soft)] px-4 py-3 text-sm text-[var(--accent-ink)]">
          {notice}
        </div>
      )}

      {!data && !error && <div className="empty">Loading finance…</div>}

      {data && (
        <div className="grid gap-5">
          {/* ── Headline figures ── */}
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <Figure icon={Percent} label="Voiid commission" value={pct(current!)}
                    sub={current === DEFAULT_BPS ? 'Platform default' : `Default is ${pct(DEFAULT_BPS)}`} accent />
            <Figure icon={ReceiptText} label="Paid gross"
                    value={paid.length ? money(paid[0][1].gross.toString(), paid[0][0]) : '—'}
                    sub={paid.length > 1 ? `+ ${paid.length - 1} more currenc${paid.length > 2 ? 'ies' : 'y'} below` : paid.length ? `${paid[0][1].orders.toLocaleString()} paid orders` : 'No paid orders yet'} />
            <Figure icon={Wallet} label="Voiid share (paid)"
                    value={paid.length ? money(paid[0][1].commission.toString(), paid[0][0]) : '—'}
                    sub={paid.length && paid[0][1].unpriced ? `${paid[0][1].unpriced} older orders not priced` : 'Commission on paid orders'} />
            <Figure icon={Ticket} label="Places sold (paid)"
                    value={paid.length ? paid.reduce((n, [, v]) => n + v.places, 0n).toLocaleString('en-IN') : '0'}
                    sub={`${data.events.length}${data.events_truncated ? '+' : ''} event${data.events.length === 1 ? '' : 's'}`} />
          </div>

          <div className="grid gap-5 xl:grid-cols-[minmax(0,360px)_minmax(0,1fr)]">
            {/* ── Commission override ── */}
            <div className="rounded-[18px] bg-[var(--surface-2)] p-4 sm:p-5">
              <div className="mb-1 text-[15px] font-semibold">Commission override</div>
              <p className="m-0 mb-4 text-tiny text-[var(--text-mute)]">
                Applies to new orders across this community. Previous sales keep the rate they were sold at.
              </p>
              <fieldset disabled={busy} className="m-0 grid gap-3 border-0 p-0">
                <label className="block">
                  <span className="mb-1.5 block text-tiny font-semibold text-[var(--text-dim)]">Voiid commission</span>
                  <div className="relative">
                    <input
                      type="number" min="0" max="100" step="0.01" inputMode="decimal"
                      value={rate} onChange={(e) => setRate(e.target.value)}
                      aria-invalid={!rateValid}
                      className={`num h-11 bg-card pr-10 text-[16px] ${!rateValid ? '!border-[var(--danger)]' : ''}`}
                    />
                    <span className="pointer-events-none absolute right-4 top-1/2 -translate-y-1/2 text-sm font-semibold text-[var(--text-mute)]">%</span>
                  </div>
                  {!rateValid && (
                    <span className="mt-1 block text-micro text-[var(--danger)]">0 to 100, at most two decimals.</span>
                  )}
                </label>
                <label className="block">
                  <span className="mb-1.5 flex items-baseline justify-between text-tiny font-semibold text-[var(--text-dim)]">
                    Reason
                    <span className="font-normal text-[var(--text-mute)]">Recorded in the audit history</span>
                  </span>
                  <textarea
                    rows={3} maxLength={500} value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder="e.g. Launch partner rate agreed for Q4"
                    className="resize-none bg-card text-sm"
                  />
                  <span className="mt-1 block text-micro text-[var(--text-mute)]">
                    {reasonOk ? `${reason.trim().length}/500` : 'At least 5 characters.'}
                  </span>
                </label>
                <button
                  onClick={() => void save()}
                  disabled={!reasonOk || !rateValid || !rateChanged}
                  className="h-11"
                  title={!rateChanged ? 'Change the rate to save' : undefined}
                >
                  {rateChanged ? `Save ${rateValid ? `${rate}%` : 'commission'}` : 'Save commission'}
                </button>
              </fieldset>
            </div>

            {/* ── Sales by currency and status ── */}
            <div className="min-w-0">
              <SectionTitle icon={ReceiptText} title="Sales by currency and status" />
              {data.totals.length === 0 ? (
                <Empty>No event orders yet.</Empty>
              ) : (
                <div className="overflow-x-auto rounded-[16px] ring-1 ring-[var(--border)]">
                  <table>
                    <thead><tr>
                      <th>Currency</th><th>Status</th><th style={{ textAlign: 'right' }}>Orders</th>
                      <th style={{ textAlign: 'right' }}>Places</th><th style={{ textAlign: 'right' }}>Gross</th>
                      <th style={{ textAlign: 'right' }}>Voiid</th><th style={{ textAlign: 'right' }}>Organiser</th>
                    </tr></thead>
                    <tbody>
                      {data.totals.map((t) => (
                        <tr key={t.currency + t.status}>
                          <td className="font-semibold">{t.currency}</td>
                          <td>
                            <StatusPill status={t.status} />
                            {t.unpriced_orders > 0 && (
                              <div className="mt-1 text-micro text-[var(--text-mute)]">
                                {t.unpriced_orders} older without a commission snapshot
                              </div>
                            )}
                          </td>
                          <td className="num tabular" style={{ textAlign: 'right' }}>{t.orders.toLocaleString()}</td>
                          <td className="num tabular" style={{ textAlign: 'right' }}>{Number(t.tickets).toLocaleString()}</td>
                          <td className="num tabular whitespace-nowrap" style={{ textAlign: 'right' }}>{money(t.gross_minor, t.currency)}</td>
                          <td className="num tabular whitespace-nowrap" style={{ textAlign: 'right' }}>{money(t.commission_minor, t.currency)}</td>
                          <td className="num tabular whitespace-nowrap" style={{ textAlign: 'right' }}>{money(t.organiser_minor, t.currency)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}

              {/* The honest limit of this page, stated where the numbers are. */}
              <div className="mt-3 flex gap-2.5 rounded-[14px] bg-[rgba(47,110,216,0.07)] p-3.5 text-tiny leading-relaxed text-[var(--text-dim)]">
                <Info size={15} className="mt-0.5 shrink-0 text-[var(--info)]" />
                <span>
                  <b className="font-semibold text-[var(--text)]">Settlement isn&rsquo;t connected yet.</b>{' '}
                  There is no withdrawable balance, and a refunded status needs provider reconciliation
                  before it counts as a completed bank refund.
                </span>
              </div>
            </div>
          </div>

          {/* ── Events ── */}
          <div>
            <SectionTitle icon={CalendarDays} title="Events" note={data.events_truncated ? 'Latest 100' : undefined} />
            {data.events.length === 0 ? (
              <Empty>No events yet.</Empty>
            ) : (
              <div className="grid gap-2 md:grid-cols-2">
                {data.events.map((e) => (
                  <div key={e.id} className="flex items-center gap-3 rounded-[14px] bg-[var(--surface-2)] px-4 py-3">
                    <div className="min-w-0 flex-1">
                      <div className="truncate text-sm font-semibold">{e.title}</div>
                      <div className="num text-micro text-[var(--text-mute)]">{when(e.starts_at)}</div>
                    </div>
                    <StatusPill status={e.status} />
                    <div className="num tabular w-[92px] text-right text-tiny leading-tight">
                      <div>{e.orders.toLocaleString()} orders</div>
                      <div className="text-[var(--text-mute)]">{e.checked_in.toLocaleString()} admitted</div>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* ── Orders ── */}
          <div>
            <SectionTitle icon={Ticket} title="Order breakdown" note={`Page ${offset / PAGE + 1}`} />
            {data.orders.length === 0 ? (
              <Empty>{offset === 0 ? 'No orders yet.' : 'No orders on this page.'}</Empty>
            ) : (
              <div className="overflow-x-auto rounded-[16px] ring-1 ring-[var(--border)]">
                <table>
                  <thead><tr>
                    <th>Order</th><th>Created</th><th>Status</th><th style={{ textAlign: 'right' }}>Qty</th>
                    <th style={{ textAlign: 'right' }}>Gross</th><th style={{ textAlign: 'right' }}>Commission</th>
                    <th style={{ textAlign: 'right' }}>Organiser</th><th style={{ textAlign: 'right' }}>Admitted</th>
                  </tr></thead>
                  <tbody>
                    {data.orders.map((o) => (
                      <tr key={o.id}>
                        <td>
                          <div className="font-medium">{o.event_title}</div>
                          <div className="mono text-micro text-[var(--text-mute)]" title={o.id}>{o.id.slice(0, 8)}</div>
                        </td>
                        <td className="num whitespace-nowrap text-tiny text-[var(--text-dim)]">{when(o.created_at)}</td>
                        <td><StatusPill status={o.status} /></td>
                        <td className="num tabular" style={{ textAlign: 'right' }}>{o.quantity}</td>
                        <td className="num tabular whitespace-nowrap" style={{ textAlign: 'right' }}>{money(o.amount_minor, o.currency)}</td>
                        <td className="num tabular whitespace-nowrap" style={{ textAlign: 'right' }}>
                          {money(o.commission_minor, o.currency)}
                          <div className="text-micro text-[var(--text-mute)]">
                            {o.commission_bps === null ? 'rate not recorded' : `at ${pct(o.commission_bps)}`}
                          </div>
                        </td>
                        <td className="num tabular whitespace-nowrap" style={{ textAlign: 'right' }}>{money(o.organiser_minor, o.currency)}</td>
                        <td className="num tabular" style={{ textAlign: 'right' }}>{o.checked_in}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {(offset > 0 || data.has_more) && (
              <div className="mt-3 flex items-center justify-end gap-2">
                <button className="ghost inline-flex h-9 items-center gap-1 px-3.5" disabled={busy || offset === 0}
                        onClick={() => setOffset(Math.max(0, offset - PAGE))}>
                  <ChevronLeft size={15} /> Previous
                </button>
                <span className="num px-2 text-tiny text-[var(--text-mute)]">Page {offset / PAGE + 1}</span>
                <button className="ghost inline-flex h-9 items-center gap-1 px-3.5" disabled={busy || !data.has_more}
                        onClick={() => setOffset(offset + PAGE)}>
                  Next <ChevronRight size={15} />
                </button>
              </div>
            )}
          </div>

          {/* ── Rate history ── */}
          <div>
            <SectionTitle icon={History} title="Commission changes" />
            {data.history.length === 0 ? (
              <Empty>No overrides recorded. This community has always used the rate above.</Empty>
            ) : (
              <ol className="m-0 grid list-none gap-0 p-0">
                {data.history.map((h, i) => (
                  <li key={i} className="relative flex gap-3 pb-4 pl-1 last:pb-0">
                    <span className="relative mt-1.5 flex flex-col items-center">
                      <span className="h-2.5 w-2.5 rounded-full bg-[var(--lime-strong)] ring-4 ring-[var(--lime-soft)]" />
                      {i < data.history.length - 1 && <span className="absolute top-3 h-[calc(100%+4px)] w-px bg-[var(--border)]" />}
                    </span>
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-baseline gap-x-2 text-sm">
                        <span className="num font-semibold">{pct(h.detail.previous_bps)} → {pct(h.detail.commission_bps)}</span>
                        <span className="text-tiny text-[var(--text-mute)]">{h.admin_email} · {when(h.created_at)}</span>
                      </div>
                      <div className="mt-0.5 text-sm text-[var(--text-dim)]">{h.detail.reason}</div>
                    </div>
                  </li>
                ))}
              </ol>
            )}
          </div>

          {paid.length > 1 && (
            <p className="m-0 text-micro text-[var(--text-mute)]">
              The headline figures show {paid[0][0]}; every currency is in the sales table above.
            </p>
          )}
        </div>
      )}
    </section>
  );
}

function Figure({ icon: Icon, label, value, sub, accent }: {
  icon: typeof Wallet; label: string; value: string; sub: string; accent?: boolean;
}) {
  return (
    <div className={`rounded-[18px] p-4 ${accent ? 'bg-[var(--lime-soft)]' : 'bg-[var(--surface-2)]'}`}>
      <div className="mb-2 flex items-center gap-2 text-tiny font-semibold text-[var(--text-dim)]">
        <Icon size={14} /> {label}
      </div>
      <div className="num truncate text-[24px] font-normal leading-tight !tracking-[-0.03em]" title={value}>{value}</div>
      <div className="mt-0.5 truncate text-micro text-[var(--text-mute)]">{sub}</div>
    </div>
  );
}

function SectionTitle({ icon: Icon, title, note }: { icon: typeof Wallet; title: string; note?: string }) {
  return (
    <div className="mb-2.5 flex items-center gap-2">
      <Icon size={15} className="text-[var(--text-dim)]" />
      <h3 className="m-0 text-[15px] font-semibold">{title}</h3>
      {note && <span className="ml-auto text-tiny text-[var(--text-mute)]">{note}</span>}
    </div>
  );
}

function Empty({ children }: { children: React.ReactNode }) {
  return (
    <div className="rounded-[14px] border border-dashed border-[var(--border-strong)] px-4 py-5 text-center text-sm text-[var(--text-mute)]">
      {children}
    </div>
  );
}
