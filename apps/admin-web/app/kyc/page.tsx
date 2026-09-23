'use client';

//
// Host verification — the review queue in front of paid events.
//
// A host who wants to sell tickets verifies their PAN and bank account in the app through
// Cashfree Secure ID. That answer is evidence, not the decision: it lands here as
// "Awaiting review", and a Voiid admin approves or rejects with the checks and any documents in
// front of them. Only an approved host can price an event, and their share of each sale
// settles to the bank account verified here.
//
// Voiid never holds the full PAN or account number — only the last four characters are shown
// because only the last four are stored. Documents open through a one-time link, and every
// view is written to the audit log with the reviewer's name.
//

import { useCallback, useEffect, useState } from 'react';
import Shell, { type Me } from '../../components/Shell';
import { PageHeader, Async, Pill, when, name } from '../../components/ui';
import { Card } from '../../components/ui/card';
import { Button } from '../../components/ui/button';
import { api } from '../../lib/api';

type Row = {
  user_id: string; status: string; legal_name: string | null;
  pan_last4: string | null; pan_registered_name: string | null; pan_name_match: boolean | null;
  bank_last4: string | null; ifsc: string | null; bank_name: string | null;
  name_at_bank: string | null; bank_name_match: string | null;
  payout_method: string | null; upi_masked: string | null;
  aadhaar_last4: string | null; aadhaar_name_match: boolean | null; aadhaar_verified_at: string | null;
  cashfree_vendor_id: string | null; vendor_status: string | null;
  submitted_at: string | null; reviewed_at: string | null; rejection_reason: string | null;
  full_name: string | null; username: string | null;
  document_count: number; communities_owned: number;
};

type Detail = {
  verification: Row & { email: string | null; phone_number: string | null; reviewed_by_email: string | null; aadhaar_name: string | null };
  documents: { id: string; kind: string; mime: string; uploaded_at: string; deleted_at: string | null }[];
  communities: { id: string; handle: string; name: string; institution_name: string | null }[];
};

const TABS = [
  { value: 'pending_review', label: 'Awaiting review' },
  { value: 'verified', label: 'Verified' },
  { value: 'rejected', label: 'Rejected' },
  { value: 'all', label: 'All' },
];

const STATUS: Record<string, { label: string; tone?: 'ok' | 'danger' | 'warning' | 'accent' }> = {
  pending_review: { label: 'Awaiting review', tone: 'warning' },
  verified: { label: 'Verified', tone: 'ok' },
  rejected: { label: 'Rejected', tone: 'danger' },
  draft: { label: 'Not submitted' },
};

const DOC_LABEL: Record<string, string> = {
  pan_card: 'PAN card', bank_proof: 'Bank proof', address_proof: 'Address proof',
  institution_letter: 'Institution letter', other: 'Other',
};

// Cashfree's bank name-match grades, strongest first.
const MATCH_TONE: Record<string, 'ok' | 'warning' | 'danger'> = {
  DIRECT_MATCH: 'ok', GOOD_PARTIAL_MATCH: 'ok', MODERATE_PARTIAL_MATCH: 'warning',
  POOR_PARTIAL_MATCH: 'danger', NO_MATCH: 'danger',
};

export default function Kyc() {
  return <Shell>{(me) => <Body me={me} />}</Shell>;
}

function Body({ me }: { me: Me }) {
  const [tab, setTab] = useState('pending_review');
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const r = await api<{ verifications: Row[] }>(`/kyc?status=${tab}`);
      setRows(r.verifications);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load the queue');
    } finally {
      setLoading(false);
    }
  }, [tab]);

  useEffect(() => { void load(); }, [load]);

  return (
    <>
      <PageHeader title="Host verification"
                  subtitle="Hosts verify their PAN and bank account to sell tickets. Review each one before they can take payments." />

      <div className="row" style={{ gap: 8, marginBottom: 16, flexWrap: 'wrap' }}>
        {TABS.map(t => (
          <Button key={t.value} size="sm" variant={tab === t.value ? 'default' : 'outline'}
                  onClick={() => { setTab(t.value); setOpen(null); }}>
            {t.label}
          </Button>
        ))}
      </div>

      <div className="grid gap-4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))', alignItems: 'start' }}>
        <Async loading={loading && rows.length === 0} error={error} empty={rows.length === 0}
               emptyText={tab === 'pending_review' ? 'Nobody is waiting for review.' : 'Nothing here.'}>
          <Card style={{ padding: 0, overflow: 'hidden' }}>
            <table>
              <thead><tr><th>Host</th><th>Checks</th><th>Submitted</th></tr></thead>
              <tbody>
                {rows.map(r => (
                  <tr key={r.user_id} onClick={() => setOpen(r.user_id)}
                      style={{ cursor: 'pointer', background: open === r.user_id ? 'var(--surface-2, rgba(0,0,0,0.04))' : undefined }}>
                    <td>
                      <div style={{ fontWeight: 600 }}>{r.legal_name ?? name(r.full_name, r.username)}</div>
                      <div className="mute" style={{ fontSize: 13 }}>
                        {name(r.full_name, r.username)} · {r.communities_owned} {r.communities_owned === 1 ? 'community' : 'communities'}
                      </div>
                    </td>
                    <td>
                      <Pill tone={STATUS[r.status]?.tone}>{STATUS[r.status]?.label ?? r.status}</Pill>{' '}
                      {r.bank_name_match && <Pill tone={MATCH_TONE[r.bank_name_match]}>{prettyMatch(r.bank_name_match)}</Pill>}{' '}
                      <Pill tone={r.aadhaar_verified_at ? 'ok' : 'warning'}>{r.aadhaar_verified_at ? 'Aadhaar ✓' : 'Aadhaar pending'}</Pill>
                    </td>
                    <td className="muted" style={{ fontSize: 13 }}>{r.submitted_at ? when(r.submitted_at) : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Card>
        </Async>

        {open && <Application userId={open} me={me} onChanged={() => void load()} />}
      </div>
    </>
  );
}

function Application({ userId, me, onChanged }: { userId: string; me: Me; onChanged: () => void }) {
  const [d, setD] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reason, setReason] = useState('');

  const load = useCallback(async () => {
    setError(null);
    try { setD(await api<Detail>(`/kyc/${userId}`)); }
    catch (e) { setError(e instanceof Error ? e.message : 'Could not load'); }
  }, [userId]);
  useEffect(() => { setD(null); setReason(''); void load(); }, [load]);

  async function act(path: string, json: unknown) {
    setBusy(true); setError(null);
    try {
      await api(`/kyc/${userId}/${path}`, { json });
      await load();
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save');
    } finally {
      setBusy(false);
    }
  }

  async function view(docId: string) {
    setError(null);
    // Opened BEFORE the request so the browser does not treat it as an unrequested popup.
    const tab = window.open('', '_blank', 'noopener');
    try {
      const r = await api<{ url: string }>(`/kyc/${userId}/documents/${docId}/view`, { json: {} });
      if (tab) tab.location.href = r.url; else window.location.href = r.url;
    } catch (e) {
      tab?.close();
      setError(e instanceof Error ? e.message : 'Could not open the document');
    }
  }

  if (!d) return <Card className="p-4">{error ? <div role="alert" className="notice error">{error}</div> : 'Loading…'}</Card>;
  const v = d.verification;
  const canDecide = me.role === 'admin';

  return (
    <Card>
      <div className="border-b border-border px-4 py-3">
        <h2 className="m-0 text-sm font-semibold">{v.legal_name ?? name(v.full_name, v.username)}</h2>
        <p className="m-0 mt-0.5 text-tiny text-[var(--text-mute)]">
          {name(v.full_name, v.username)}{v.email ? ` · ${v.email}` : ''}{v.phone_number ? ` · ${v.phone_number}` : ''}
        </p>
      </div>
      <div className="grid gap-4 p-4">
        {error && <div role="alert" className="notice error">{error}</div>}

        <section className="grid gap-1">
          <h3 className="m-0 text-sm font-semibold">PAN</h3>
          <Line label="Number" value={v.pan_last4 ? `•••••${v.pan_last4}` : '—'} />
          <Line label="Name on PAN" value={v.pan_registered_name ?? '—'} />
          <Line label="Matches the name given" value={v.pan_name_match == null ? 'Not reported' : v.pan_name_match ? 'Yes' : 'No'} />
        </section>

        <section className="grid gap-1">
          <h3 className="m-0 text-sm font-semibold">{v.payout_method === 'upi' ? 'UPI ID (payouts go here)' : 'Bank account (payouts go here)'}</h3>
          {v.payout_method === 'upi' ? (
            <Line label="UPI ID" value={`${v.upi_masked ?? '—'}${v.bank_name ? ` · ${v.bank_name}` : ''}`} />
          ) : (
            <>
              <Line label="Account" value={v.bank_last4 ? `••••${v.bank_last4}` : '—'} />
              <Line label="IFSC" value={`${v.ifsc ?? '—'}${v.bank_name ? ` · ${v.bank_name}` : ''}`} />
            </>
          )}
          <Line label="Name at bank" value={v.name_at_bank ?? '—'} />
          <Line label="Name match" value={v.bank_name_match ? prettyMatch(v.bank_name_match) : '—'} />
          <Line label="Payout account" value={v.cashfree_vendor_id ? `${v.cashfree_vendor_id} (${v.vendor_status ?? 'unknown'})` : 'Not created'} />
        </section>

        <section className="grid gap-1">
          <h3 className="m-0 text-sm font-semibold">Aadhaar (via DigiLocker)</h3>
          {v.aadhaar_verified_at ? (
            <>
              <Line label="Aadhaar" value={`xxxx xxxx ${v.aadhaar_last4 ?? '••••'}`} />
              <Line label="Name on Aadhaar" value={v.aadhaar_name ?? '—'} />
              <Line label="Matches the PAN name" value={v.aadhaar_name_match == null ? 'Not checked' : v.aadhaar_name_match ? 'Yes' : 'No — check carefully'} />
              <Line label="Verified" value={when(v.aadhaar_verified_at)} />
            </>
          ) : (
            <p className="m-0 text-sm text-[var(--text-mute)]">
              Not verified yet. The host completes this in the app through DigiLocker; approval waits for it.
            </p>
          )}
        </section>

        <section className="grid gap-1">
          <h3 className="m-0 text-sm font-semibold">Documents</h3>
          {d.documents.length === 0 && <p className="m-0 text-sm text-[var(--text-mute)]">None uploaded.</p>}
          {d.documents.map(doc => (
            <div key={doc.id} className="row" style={{ gap: 10, alignItems: 'center', opacity: doc.deleted_at ? 0.5 : 1 }}>
              <span style={{ flex: 1 }}>{DOC_LABEL[doc.kind] ?? doc.kind} <span className="text-tiny text-[var(--text-mute)]">· {when(doc.uploaded_at)}{doc.deleted_at ? ' · withdrawn' : ''}</span></span>
              {!doc.deleted_at && canDecide && <Button size="sm" variant="outline" onClick={() => void view(doc.id)}>View</Button>}
            </div>
          ))}
          {d.documents.length > 0 && <p className="m-0 text-tiny text-[var(--text-mute)]">Each view is recorded in the audit log.</p>}
        </section>

        {d.communities.length > 0 && (
          <section className="grid gap-1">
            <h3 className="m-0 text-sm font-semibold">Communities they own</h3>
            {d.communities.map(c => <Line key={c.id} label={`@${c.handle}`} value={c.institution_name ? `${c.name} · ✓ ${c.institution_name}` : c.name} />)}
          </section>
        )}

        <section className="grid gap-2">
          <Line label="Status" value={STATUS[v.status]?.label ?? v.status} />
          {v.reviewed_at && <Line label="Reviewed" value={`${when(v.reviewed_at)}${v.reviewed_by_email ? ` by ${v.reviewed_by_email}` : ''}`} />}
          {v.rejection_reason && <Line label="Reason given" value={v.rejection_reason} />}
          {canDecide && (v.status === 'pending_review' || v.status === 'verified') && (
            <>
              <textarea rows={2} maxLength={500} placeholder="Reason the host will see if you reject"
                        value={reason} onChange={e => setReason(e.target.value)} />
              <div className="row" style={{ gap: 8 }}>
                {v.status === 'pending_review' && (
                  <Button disabled={busy || !v.cashfree_vendor_id} onClick={() => void act('approve', {})}>
                    Approve
                  </Button>
                )}
                <Button variant="destructive" disabled={busy || reason.trim().length < 5}
                        onClick={() => { if (window.confirm('Reject this host? They will not be able to sell tickets.')) void act('reject', { reason: reason.trim() }); }}>
                  {v.status === 'verified' ? 'Revoke verification' : 'Reject'}
                </Button>
              </div>
            </>
          )}
          {!canDecide && <p className="m-0 text-tiny text-[var(--text-mute)]">Only admins can approve or reject.</p>}
        </section>
      </div>
    </Card>
  );
}

function Line({ label, value }: { label: string; value: string }) {
  return (
    <div className="row" style={{ gap: 12, fontSize: 14 }}>
      <span className="text-[var(--text-mute)]" style={{ minWidth: 150 }}>{label}</span>
      <span style={{ flex: 1 }}>{value}</span>
    </div>
  );
}

function prettyMatch(m: string) {
  return m.toLowerCase().replace(/_/g, ' ').replace(/^\w/, c => c.toUpperCase());
}
