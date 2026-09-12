'use client';

//
// GOVERNMENT REQUESTS — the console for a compelled disclosure.
//
// WHY THIS PAGE OPENS ON A LIST AND NOT A SEARCH BOX
// ==================================================
// The obvious build is a field that takes a phone number and shows everything Voiid knows
// about that person. This page deliberately has no such field, and the API has no endpoint
// behind one. That design is a mass-surveillance tool with a legal justification attached
// afterwards: an insider checking on an ex, a stolen admin session, or a staff member
// standing in front of someone with a badge and no warrant all reach the same data, and
// nothing afterwards can say which of those it was.
//
// So the ORDER is the first thing that exists. A case is opened with the authority, the
// statute, the reference and the served document; a second admin approves it; only then can
// anyone look at what we hold, and every look is written to lawful_access_log whether or
// not it is ultimately disclosed.
//
// The operator loses nothing real. They already have the phone number — the authority
// served it to them. What they cannot do is read one they did not arrive with.
//

import { useCallback, useEffect, useState } from 'react';
import Shell from '../../components/Shell';
import { PageHeader, Pill, Async, when } from '../../components/ui';
import { ListTable } from '../../components/List';
import { api } from '../../lib/api';

type Req = {
  id: string; authority: string; legal_basis: string; reference: string;
  scope_requested: string; received_channel: string; received_at: string;
  status: string; emergency: boolean; subject_phone: string | null;
  subject_user_id: string | null; subject_notified: string;
  order_document_key: string | null; order_document_kind: string | null;
  decision_note: string | null; approved_at: string | null; closed_at: string | null;
  opened_by_email: string | null; approved_by_email: string | null;
  disclosure_count: number;
};

const STATUS_TONE: Record<string, 'ok' | 'danger' | 'warning' | 'accent' | undefined> = {
  received: 'warning', under_review: 'accent', refused: 'danger',
  narrowed: 'warning', complied: 'ok', no_data: undefined, withdrawn: undefined,
};

export default function Govt() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [rows, setRows] = useState<Req[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await api<{ requests: Req[] }>('/admin/lawful/requests');
      setRows(r.requests);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load requests');
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => { void load(); }, [load]);

  if (open) return <CaseFile id={open} onBack={() => { setOpen(null); void load(); }} />;

  return (
    <>
      <PageHeader
        title="Government requests"
        subtitle="Compelled disclosures, the order behind each one, and exactly what was handed over."
        right={<button onClick={() => setCreating(true)}>Log a request</button>}
      />

      {/* STATED ON THE PAGE, not only in a policy document. The operator answering an
          officer at a counter needs the limits in front of them, in the words they can
          repeat back. */}
      <div className="card" style={{ padding: 14, marginBottom: 18, borderLeft: '2px solid var(--attention)' }}>
        <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 6 }}>Before you disclose anything</div>
        <ul className="mute" style={{ fontSize: 13, margin: 0, paddingLeft: 18, lineHeight: 1.7 }}>
          <li>The served order — FIR copy, warrant or written notice — must be attached. Nothing can be closed as complied without it.</li>
          <li>A second admin must approve. You cannot approve a request you opened.</li>
          <li>Message content cannot be produced. It is end-to-end encrypted and the keys never reach our servers.</li>
          <li>Disclose only what the order names. Anything beyond its scope is an over-disclosure you will have to account for.</li>
        </ul>
      </div>

      {creating && <NewRequest onDone={(id) => { setCreating(false); void load(); if (id) setOpen(id); }} />}

      <ListTable
        head={['Authority', 'Basis', 'Subject', 'Received', 'Status', '']}
        loading={loading}
        error={error}
        empty={rows.length === 0}
        emptyText="No requests have been logged."
        cursor={null}
        onMore={() => {}}
      >
        {rows.map((r) => (
        <tr key={r.id}>
          <td>
            <div style={{ fontWeight: 600 }}>{r.authority}</div>
            <div className="mute" style={{ fontSize: 13 }}>{r.reference}</div>
          </td>
          <td>
            <div style={{ fontSize: 13 }}>{r.legal_basis}</div>
            {r.emergency && <Pill tone="danger">emergency</Pill>}
          </td>
          <td className="mono" style={{ fontSize: 13 }}>
            {r.subject_phone ?? '—'}
            {!r.subject_user_id && <div className="mute" style={{ fontSize: 12 }}>no account</div>}
          </td>
          <td className="mute" style={{ fontSize: 13 }}>{when(r.received_at)}</td>
          <td>
            <Pill tone={STATUS_TONE[r.status]}>{r.status.replace(/_/g, ' ')}</Pill>
            {/* The absence of paperwork is the thing worth seeing from the list. */}
            {!r.order_document_key && (
              <div style={{ fontSize: 12, color: 'var(--attention)', marginTop: 3 }}>no order attached</div>
            )}
          </td>
          <td style={{ textAlign: 'right' }}>
            <button className="ghost sm" onClick={() => setOpen(r.id)}>Open</button>
          </td>
        </tr>
        ))}
      </ListTable>
    </>
  );
}

// ── Logging a new order ────────────────────────────────────────────────────────────────
function NewRequest({ onDone }: { onDone: (id: string | null) => void }) {
  const [f, setF] = useState({
    authority: '', legal_basis: '', reference: '', scope_requested: '',
    received_channel: 'sealed_post', subject_phone: '', emergency: false,
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const set = (k: string, v: unknown) => setF((p) => ({ ...p, [k]: v }));

  async function submit() {
    setBusy(true); setErr(null);
    try {
      const r = await api<{ id: string }>('/admin/lawful/requests', { method: 'POST', json: f });
      onDone(r.id);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'could not log the request');
      setBusy(false);
    }
  }

  return (
    <div className="card" style={{ padding: 18, marginBottom: 18 }}>
      <div style={{ fontWeight: 600, marginBottom: 4 }}>Log a request</div>
      <div className="mute" style={{ fontSize: 13, marginBottom: 14 }}>
        Record it as served, in the authority&apos;s own words. The document is attached next.
      </div>
      {err && <div className="notice error" style={{ marginBottom: 12 }}>{err}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <Field label="Authority" hint="Who served it — the cyber cell, court, or agency."
               value={f.authority} onChange={(v) => set('authority', v)} />
        <Field label="Legal basis" hint="CrPC 91, IT Act 69, DPDP s.36, court warrant, MLAT…"
               value={f.legal_basis} onChange={(v) => set('legal_basis', v)} />
        <Field label="Their reference" hint="FIR number, case number, notice number."
               value={f.reference} onChange={(v) => set('reference', v)} />
        <Field label="Subject phone" hint="Exactly as the order names them."
               value={f.subject_phone} onChange={(v) => set('subject_phone', v)} mono />
        <label style={{ gridColumn: '1 / -1', display: 'block' }}>
          <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 4 }}>Scope requested</div>
          <div className="mute" style={{ fontSize: 12, marginBottom: 5 }}>
            Verbatim. What we disclose is checked against this later.
          </div>
          <textarea rows={3} value={f.scope_requested}
                    onChange={(e) => set('scope_requested', e.target.value)} style={{ width: '100%' }} />
        </label>
        <label>
          <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 4 }}>How it arrived</div>
          <select value={f.received_channel} onChange={(e) => set('received_channel', e.target.value)}
                  style={{ width: '100%' }}>
            <option value="sealed_post">Sealed post</option>
            <option value="email">Email</option>
            <option value="in_person">In person</option>
            <option value="court_portal">Court portal</option>
            <option value="mlat">MLAT</option>
            <option value="other">Other</option>
          </select>
        </label>
        <label style={{ display: 'flex', alignItems: 'flex-end', gap: 8, paddingBottom: 8 }}>
          <input type="checkbox" checked={f.emergency}
                 onChange={(e) => set('emergency', e.target.checked)} />
          <span style={{ fontSize: 13 }}>Claimed emergency</span>
        </label>
      </div>

      <div style={{ display: 'flex', gap: 8, marginTop: 14 }}>
        <button onClick={submit} disabled={busy}>{busy ? 'Logging…' : 'Log request'}</button>
        <button className="ghost" onClick={() => onDone(null)} disabled={busy}>Cancel</button>
      </div>
    </div>
  );
}

function Field({ label, hint, value, onChange, mono }: {
  label: string; hint: string; value: string; onChange: (v: string) => void; mono?: boolean;
}) {
  return (
    <label style={{ display: 'block' }}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 4 }}>{label}</div>
      <div className="mute" style={{ fontSize: 12, marginBottom: 5 }}>{hint}</div>
      <input className={mono ? 'mono' : undefined} value={value}
             onChange={(e) => onChange(e.target.value)} style={{ width: '100%' }} />
    </label>
  );
}

// ── One case ───────────────────────────────────────────────────────────────────────────
type Detail = {
  request: Req & { order_document_sha256: string | null };
  disclosures: { category: string; record_count: number; disclosed_at: string; disclosed_by_email: string | null }[];
  access_log: { category: string; record_count: number; created_at: string; admin_email: string | null }[];
};

function CaseFile({ id, onBack }: { id: string; onBack: () => void }) {
  const [d, setD] = useState<Detail | null>(null);
  const [cats, setCats] = useState<{ id: string; description: string }[]>([]);
  const [cannot, setCannot] = useState<string[]>([]);
  const [preview, setPreview] = useState<{ category: string; count: number; rows: unknown[] } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [detail, c] = await Promise.all([
        api<Detail>(`/admin/lawful/requests/${id}`),
        api<{ categories: { id: string; description: string }[]; cannot_produce: string[] }>('/admin/lawful/categories'),
      ]);
      setD(detail); setCats(c.categories); setCannot(c.cannot_produce); setErr(null);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'could not load the case');
    }
  }, [id]);
  useEffect(() => { void load(); }, [load]);

  async function act(path: string, json?: unknown) {
    setBusy(true); setErr(null);
    try { await api(`/admin/lawful/requests/${id}${path}`, { method: 'POST', json }); await load(); }
    catch (e) { setErr(e instanceof Error ? e.message : 'that did not go through'); }
    finally { setBusy(false); }
  }

  async function runPreview(category: string) {
    setBusy(true); setErr(null);
    try {
      setPreview(await api(`/admin/lawful/requests/${id}/preview`, { method: 'POST', json: { category } }));
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'could not read that category');
    } finally { setBusy(false); }
  }

  if (err && !d) return <div className="notice error">{err}</div>;
  if (!d) return <div className="empty">Loading…</div>;
  const r = d.request;
  const approved = !!r.approved_by_email;

  return (
    <>
      <PageHeader
        title={r.authority}
        subtitle={`${r.legal_basis} · ${r.reference}`}
        right={<button className="ghost" onClick={onBack}>Back</button>}
      />
      {err && <div className="notice error" style={{ marginBottom: 14 }}>{err}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 18 }}>
        <div className="card" style={{ padding: 16 }}>
          <Row k="Subject" v={r.subject_phone ?? '—'} mono />
          <Row k="Account" v={r.subject_user_id ? 'resolved' : 'no account matches'} />
          <Row k="Received" v={`${when(r.received_at)} · ${r.received_channel.replace(/_/g, ' ')}`} />
          <Row k="Opened by" v={r.opened_by_email ?? '—'} />
          <Row k="Approved by" v={r.approved_by_email ?? 'not approved'} />
          <Row k="Status" v={r.status.replace(/_/g, ' ')} />
        </div>
        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 6 }}>Scope requested</div>
          <div className="mute" style={{ fontSize: 13, whiteSpace: 'pre-wrap', lineHeight: 1.6 }}>
            {r.scope_requested}
          </div>
        </div>
      </div>

      {/* THE ORDER. Its absence is the loudest thing on the page, because every other
          control here is gated on it. */}
      <div className="card" style={{ padding: 16, marginBottom: 18 }}>
        <div style={{ fontWeight: 600, marginBottom: 8 }}>Served order</div>
        {r.order_document_key ? (
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <Pill tone="ok">{r.order_document_kind ?? 'attached'}</Pill>
            <span className="mono mute" style={{ fontSize: 12 }}>
              sha256 {r.order_document_sha256?.slice(0, 16)}…
            </span>
            <button className="ghost sm" onClick={async () => {
              const { url } = await api<{ url: string }>(`/admin/lawful/requests/${id}/document`);
              window.open(url, '_blank', 'noopener');
            }}>View</button>
          </div>
        ) : (
          <>
            <div className="notice" style={{ marginBottom: 10 }}>
              No order is attached. Nothing can be approved or disclosed until it is.
            </div>
            <UploadOrder id={id} onDone={load} />
          </>
        )}
      </div>

      {!approved && r.order_document_key && (
        <div className="card" style={{ padding: 16, marginBottom: 18 }}>
          <div style={{ fontWeight: 600, marginBottom: 4 }}>Second approval</div>
          <div className="mute" style={{ fontSize: 13, marginBottom: 10 }}>
            A request must be approved by someone other than the person who opened it
            ({r.opened_by_email}). If that is you, hand it to another admin.
          </div>
          <button onClick={() => act('/approve')} disabled={busy}>Approve this request</button>
        </div>
      )}

      {approved && (
        <div className="card" style={{ padding: 16, marginBottom: 18 }}>
          <div style={{ fontWeight: 600, marginBottom: 4 }}>What we hold</div>
          <div className="mute" style={{ fontSize: 13, marginBottom: 12 }}>
            Every category you open here is written to the access log, whether or not you
            disclose it.
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            {cats.map((c) => (
              <button key={c.id} className="ghost sm" title={c.description}
                      onClick={() => runPreview(c.id)} disabled={busy}>
                {c.id.replace(/_/g, ' ')}
              </button>
            ))}
          </div>

          {preview && (
            <div style={{ marginTop: 14 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
                <strong style={{ fontSize: 14 }}>{preview.category.replace(/_/g, ' ')}</strong>
                <Pill>{preview.count} records</Pill>
                <button className="ghost sm" disabled={busy}
                        onClick={() => act('/disclose', { category: preview.category, record_count: preview.count })}>
                  Record as disclosed
                </button>
              </div>
              <pre className="mono" style={{
                fontSize: 12, background: 'var(--surface-2)', padding: 12,
                borderRadius: 6, maxHeight: 280, overflow: 'auto', margin: 0,
              }}>{JSON.stringify(preview.rows, null, 2)}</pre>
            </div>
          )}

          <div className="mute" style={{ fontSize: 12, marginTop: 14, lineHeight: 1.7 }}>
            {cannot.map((c) => <div key={c}>· {c}</div>)}
          </div>
        </div>
      )}

      {d.disclosures.length > 0 && (
        <div className="card" style={{ padding: 16, marginBottom: 18 }}>
          <div style={{ fontWeight: 600, marginBottom: 10 }}>Disclosed</div>
          {d.disclosures.map((x) => (
            <Row key={x.category} k={x.category.replace(/_/g, ' ')}
                 v={`${x.record_count} records · ${when(x.disclosed_at)} · ${x.disclosed_by_email ?? '—'}`} />
          ))}
        </div>
      )}

      {!r.closed_at && approved && <CloseCase busy={busy} onClose={(j) => act('/close', j)} />}

      <div className="card" style={{ padding: 16 }}>
        <div style={{ fontWeight: 600, marginBottom: 4 }}>Access log</div>
        <div className="mute" style={{ fontSize: 13, marginBottom: 10 }}>
          Every read of this subject&apos;s data, disclosed or not.
        </div>
        <Async loading={false} error={null} empty={d.access_log.length === 0}
               emptyText="Nothing has been read yet.">
          <table className="list">
            <tbody>
              {d.access_log.map((a, i) => (
                <tr key={i}>
                  <td style={{ fontSize: 13 }}>{a.category.replace(/_/g, ' ')}</td>
                  <td className="mute" style={{ fontSize: 13 }}>{a.record_count} records</td>
                  <td className="mute" style={{ fontSize: 13 }}>{a.admin_email ?? '—'}</td>
                  <td className="mute" style={{ fontSize: 13 }}>{when(a.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Async>
      </div>
    </>
  );
}

function UploadOrder({ id, onDone }: { id: string; onDone: () => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [kind, setKind] = useState('fir');

  async function upload(file: File) {
    setBusy(true); setErr(null);
    try {
      const { upload_url, key } = await api<{ upload_url: string; key: string }>(
        `/admin/lawful/requests/${id}/document`, { method: 'POST', json: { kind, content_type: file.type } });
      await fetch(upload_url, { method: 'PUT', body: file, headers: { 'content-type': file.type } });
      // Digest the bytes we actually sent, so the copy on record can be proven to be the
      // copy we were served.
      const buf = await file.arrayBuffer();
      const hash = await crypto.subtle.digest('SHA-256', buf);
      const sha = Array.from(new Uint8Array(hash)).map((b) => b.toString(16).padStart(2, '0')).join('');
      await api(`/admin/lawful/requests/${id}/document/confirm`, { method: 'POST', json: { key, sha256: sha, kind } });
      onDone();
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'the upload did not complete');
    } finally { setBusy(false); }
  }

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
      <select value={kind} onChange={(e) => setKind(e.target.value)}>
        <option value="fir">FIR copy</option>
        <option value="court_warrant">Court warrant</option>
        <option value="magistrate_order">Magistrate order</option>
        <option value="written_notice">Written notice</option>
        <option value="mlat_request">MLAT request</option>
        <option value="other">Other</option>
      </select>
      <input type="file" accept="application/pdf,image/*" disabled={busy}
             onChange={(e) => { const f = e.target.files?.[0]; if (f) void upload(f); }} />
      {busy && <span className="mute" style={{ fontSize: 13 }}>Uploading…</span>}
      {err && <span style={{ fontSize: 13, color: 'var(--danger)' }}>{err}</span>}
    </div>
  );
}

function CloseCase({ busy, onClose }: { busy: boolean; onClose: (j: unknown) => void }) {
  const [status, setStatus] = useState('complied');
  const [note, setNote] = useState('');
  const [notified, setNotified] = useState('pending');
  return (
    <div className="card" style={{ padding: 16, marginBottom: 18 }}>
      <div style={{ fontWeight: 600, marginBottom: 10 }}>Close this request</div>
      <div style={{ display: 'flex', gap: 10, marginBottom: 10, flexWrap: 'wrap' }}>
        <select value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="complied">Complied</option>
          <option value="narrowed">Narrowed after pushback</option>
          <option value="refused">Refused</option>
          <option value="no_data">No responsive data</option>
          <option value="withdrawn">Withdrawn by authority</option>
        </select>
        <select value={notified} onChange={(e) => setNotified(e.target.value)}>
          <option value="pending">Subject: not yet notified</option>
          <option value="notified">Subject notified</option>
          <option value="barred_by_order">Notification barred by the order</option>
          <option value="deferred">Notification deferred</option>
          <option value="not_required">Notification not required</option>
        </select>
      </div>
      <textarea rows={3} placeholder="Why this outcome. Required — a decision with no stated reason is indefensible later."
                value={note} onChange={(e) => setNote(e.target.value)} style={{ width: '100%', marginBottom: 10 }} />
      <button disabled={busy || !note.trim()}
              onClick={() => onClose({ status, decision_note: note, subject_notified: notified })}>
        Close as {status.replace(/_/g, ' ')}
      </button>
    </div>
  );
}

function Row({ k, v, mono }: { k: string; v: string; mono?: boolean }) {
  return (
    <div style={{ display: 'flex', gap: 12, padding: '5px 0', fontSize: 13 }}>
      <span className="mute" style={{ width: 110, flex: '0 0 110px' }}>{k}</span>
      <span className={mono ? 'mono' : undefined}>{v}</span>
    </div>
  );
}
