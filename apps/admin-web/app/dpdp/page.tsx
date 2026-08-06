'use client';

import { useCallback, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { api, getToken } from '@/lib/api';

/*
 * THE DATA-PRINCIPAL REQUEST QUEUE (plan item 3.27).
 *
 * India's DPDP Act gives a person the right to ask what you hold about them, to have it
 * corrected, and to have it erased — and to get an answer within a statutory window. This
 * screen is how those requests get worked, and the ONE thing it must never do is let one
 * quietly age past its deadline. So it is ordered by due date ascending and overdue rows
 * are marked, rather than sorted newest-first like every other queue in this panel.
 *
 * WHAT IT CANNOT DO, deliberately: there is no "view their messages" affordance, because
 * there is nothing to view. An export is metadata only — we do not hold the keys, so
 * content cannot be produced by anyone, including us. That is a property of the system
 * rather than a policy this screen enforces.
 */

interface DpdpRequest {
  id: string;
  user_id: string;
  kind: 'access' | 'correction' | 'erasure' | string;
  status: string;
  subject_note: string | null;
  opened_at: string;
  due_at: string;
  overdue: boolean;
  username: string | null;
  phone_masked?: string | null;
  subject_deleted_at: string | null;
  handled_by_email: string | null;
}

const KIND_LABEL: Record<string, string> = {
  access: 'Access',
  correction: 'Correction',
  erasure: 'Erasure',
};

export default function DpdpPage() {
  const router = useRouter();
  const [rows, setRows] = useState<DpdpRequest[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [scope, setScope] = useState<'open' | 'closed'>('open');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async (reset: boolean) => {
    setLoading(true);
    const qs = new URLSearchParams({ status: scope });
    if (!reset && cursor) qs.set('cursor', cursor);
    try {
      const res = await api<{ requests: DpdpRequest[]; next_cursor: string | null }>(`/dpdp?${qs}`);
      setRows((prev) => (reset ? res.requests : [...prev, ...res.requests]));
      setCursor(res.next_cursor);
    } finally {
      setLoading(false);
    }
  }, [cursor, scope]);

  useEffect(() => {
    if (!getToken()) { router.replace('/login'); return; }
    setCursor(null);
    load(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scope]);

  async function setStatus(id: string, status: string) {
    // A note is required on close. "Why was this closed" is the question a regulator asks,
    // and an empty audit row cannot answer it.
    const note = window.prompt(`Note for marking this ${status}?`);
    if (note === null) return;
    if (!note.trim()) { alert('A note is required.'); return; }
    setBusy(id);
    try {
      await api(`/dpdp/${id}/status`, { method: 'POST', json: { status, note } });
      setRows((prev) => prev.filter((r) => r.id !== id));
    } finally { setBusy(null); }
  }

  async function startErasure(id: string) {
    // Deliberately blunt wording. This queues a real, irreversible purge — the worker
    // deletes rows and R2 objects — so the confirmation should read like what it is.
    if (!window.confirm(
      'Queue a permanent erasure for this account?\n\n' +
      'This cannot be undone. Their data and uploaded media will be deleted.'
    )) return;
    setBusy(id);
    try {
      await api(`/dpdp/${id}/start-erasure`, { method: 'POST' });
      await load(true);
    } finally { setBusy(null); }
  }

  return (
    <main style={{ maxWidth: 1040, margin: '0 auto', padding: 32 }}>
      <header style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 8 }}>
        <Link href="/"><button className="ghost">← Back</button></Link>
        <h1 style={{ margin: 0, fontSize: 22 }}>
          {scope === 'open' ? 'Open requests' : 'Closed requests'}
        </h1>
        <div style={{ marginLeft: 'auto' }}>
          <button className="ghost" onClick={() => setScope((s) => (s === 'open' ? 'closed' : 'open'))}>
            {scope === 'open' ? 'Show closed' : 'Show open'}
          </button>
        </div>
      </header>

      <p style={{ color: 'var(--text-dim)', fontSize: 13, margin: '0 0 20px', maxWidth: '68ch' }}>
        Ordered by deadline, soonest first — not newest first like the other queues, because
        the failure mode here is a request quietly ageing past its statutory window. An export
        contains metadata only: message content is end-to-end encrypted and cannot be produced
        by anyone, including us.
      </p>

      {rows.length === 0 && !loading && (
        <p style={{ color: 'var(--text-dim)' }}>
          {scope === 'open' ? 'Nothing outstanding.' : 'Nothing closed yet.'}
        </p>
      )}

      <div style={{ display: 'grid', gap: 10 }}>
        {rows.map((r) => (
          <div key={r.id} className="card" style={{
            padding: 14,
            borderLeft: r.overdue ? '3px solid var(--danger)' : '3px solid transparent',
          }}>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, flexWrap: 'wrap' }}>
              <strong>{KIND_LABEL[r.kind] ?? r.kind}</strong>
              {r.overdue && (
                <span style={{ color: 'var(--danger)', fontSize: 12, fontWeight: 600 }}>OVERDUE</span>
              )}
              <span style={{ color: 'var(--text-dim)', fontSize: 13 }}>
                {r.username ? `@${r.username}` : r.user_id.slice(0, 8)}
              </span>
              {r.subject_deleted_at && (
                <span style={{ color: 'var(--text-dim)', fontSize: 12 }}>account already deleted</span>
              )}
              <span style={{ marginLeft: 'auto', color: 'var(--text-dim)', fontSize: 12 }}>
                due {new Date(r.due_at).toLocaleDateString()}
              </span>
            </div>

            {r.subject_note && (
              <div style={{ marginTop: 6, fontSize: 13.5 }}>{r.subject_note}</div>
            )}

            <div style={{ marginTop: 6, color: 'var(--text-dim)', fontSize: 12 }}>
              opened {new Date(r.opened_at).toLocaleString()}
              {r.handled_by_email && ` · handled by ${r.handled_by_email}`}
              {` · status ${r.status}`}
            </div>

            {scope === 'open' && (
              <div style={{ display: 'flex', gap: 8, marginTop: 12, flexWrap: 'wrap' }}>
                <Link href={`/users?id=${r.user_id}`}>
                  <button className="ghost">Open profile</button>
                </Link>
                <button className="ghost" disabled={busy === r.id}
                        onClick={() => setStatus(r.id, 'fulfilled')}>
                  Mark fulfilled
                </button>
                <button className="ghost" disabled={busy === r.id}
                        onClick={() => setStatus(r.id, 'rejected')}>
                  Reject
                </button>
                {r.kind === 'erasure' && (
                  <button className="danger" disabled={busy === r.id}
                          onClick={() => startErasure(r.id)}>
                    Queue erasure
                  </button>
                )}
              </div>
            )}
          </div>
        ))}
      </div>

      {cursor && (
        <button className="ghost" onClick={() => load(false)} disabled={loading} style={{ marginTop: 16 }}>
          {loading ? 'Loading…' : 'Load more'}
        </button>
      )}
    </main>
  );
}
