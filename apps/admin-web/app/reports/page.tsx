'use client';

import { useCallback, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { api, getToken } from '@/lib/api';

/*
 * THE REPORT QUEUE (plan item 3.29).
 *
 * WHAT A MODERATOR CAN SEE HERE depends on what was reported, and the difference is the
 * whole point:
 *
 *   clip / creator  — public content. The server can read it, so the queue shows it.
 *   message_sender  — the report is about a PERSON, never a message. There is no
 *                     "view the message" button and there cannot be one: the server has
 *                     no key. If the reporter chose to attach an excerpt they decrypted
 *                     on their own device, that is marked `reporter_attached` and is the
 *                     ONLY circumstance in which any message text exists here at all.
 *
 * A target may be null. 035_reports.sql puts no foreign key on target_id on purpose — a
 * report is the record of WHY something was removed, and every FK action destroys that
 * record at the worst moment — so a dangling target renders as "deleted", not as a
 * missing row.
 */

interface Report {
  id: string;
  target_type: 'clip' | 'creator' | 'message_sender';
  target_id: string;
  reason: string;
  note: string | null;
  disclosure: 'metadata_only' | 'reporter_attached';
  has_evidence: boolean;
  status: string;
  created_at: string;
  resolution: string | null;
  resolution_note: string | null;
  reporter_username: string | null;
  target_username: string | null;
  target_deleted_at: string | null;
  clip_caption: string | null;
  clip_removed_at: string | null;
  resolved_by_email: string | null;
  open_against_target: number;
}

// Reasons the schema routes differently on purpose — surfaced so they cannot be worked
// as ordinary spam. 035 notes the handling obligations for these are an open legal
// question, so this only makes them visible; it does not claim any timeline is met.
const URGENT = new Set(['child_safety', 'illegal', 'self_harm']);

const RESOLUTIONS = [
  ['removed', 'Removed'],
  ['no_action', 'No action'],
  ['duplicate', 'Duplicate'],
  ['escalated', 'Escalated'],
] as const;

export default function ReportsPage() {
  const router = useRouter();
  const [rows, setRows] = useState<Report[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [scope, setScope] = useState<'open' | 'resolved'>('open');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async (reset: boolean) => {
    setLoading(true);
    const qs = new URLSearchParams({ status: scope });
    if (!reset && cursor) qs.set('cursor', cursor);
    try {
      const res = await api<{ reports: Report[]; next_cursor: string | null }>(`/reports?${qs}`);
      setRows((prev) => (reset ? res.reports : [...prev, ...res.reports]));
      setCursor(res.next_cursor);
    } finally { setLoading(false); }
  }, [cursor, scope]);

  useEffect(() => {
    if (!getToken()) { router.replace('/login'); return; }
    setCursor(null);
    load(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scope]);

  async function resolve(id: string, resolution: string) {
    const note = window.prompt(`Note for "${resolution}"? (optional)`);
    if (note === null) return;
    setBusy(id);
    try {
      await api(`/reports/${id}/resolve`, { method: 'POST', json: { resolution, note } });
      setRows((prev) => prev.filter((r) => r.id !== id));
    } catch (e) {
      // A 409 means another moderator got there first — that is normal on a shared queue,
      // not an error worth a stack trace.
      alert((e as Error).message);
      await load(true);
    } finally { setBusy(null); }
  }

  function targetLabel(r: Report) {
    if (r.target_type === 'clip') {
      if (r.clip_caption === null && !r.clip_removed_at) return 'clip (deleted)';
      return `clip${r.clip_removed_at ? ' (already removed)' : ''}`;
    }
    if (r.target_deleted_at) return 'account (deleted)';
    return r.target_username ? `@${r.target_username}` : 'account';
  }

  return (
    <main style={{ maxWidth: 1040, margin: '0 auto', padding: 32 }}>
      <header style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 8 }}>
        <Link href="/"><button className="ghost">← Back</button></Link>
        <h1 style={{ margin: 0, fontSize: 22 }}>
          {scope === 'open' ? 'Open reports' : 'Resolved reports'}
        </h1>
        <div style={{ marginLeft: 'auto' }}>
          <button className="ghost" onClick={() => setScope((s) => (s === 'open' ? 'resolved' : 'open'))}>
            {scope === 'open' ? 'Show resolved' : 'Show open'}
          </button>
        </div>
      </header>

      <p style={{ color: 'var(--text-dim)', fontSize: 13, margin: '0 0 20px', maxWidth: '70ch' }}>
        Reporting a person is a report about <em>them</em>, not about a message — there is no
        way to view a reported message and there cannot be one, because the server holds no
        key. Text appears here only when the reporter chose to attach an excerpt themselves.
      </p>

      {rows.length === 0 && !loading && (
        <p style={{ color: 'var(--text-dim)' }}>
          {scope === 'open' ? 'Queue is empty.' : 'Nothing resolved yet.'}
        </p>
      )}

      <div style={{ display: 'grid', gap: 10 }}>
        {rows.map((r) => (
          <div key={r.id} className="card" style={{
            padding: 14,
            borderLeft: URGENT.has(r.reason) ? '3px solid var(--danger)' : '3px solid transparent',
          }}>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, flexWrap: 'wrap' }}>
              <strong style={{ textTransform: 'capitalize' }}>{r.reason.replace(/_/g, ' ')}</strong>
              {URGENT.has(r.reason) && (
                <span style={{ color: 'var(--danger)', fontSize: 12, fontWeight: 600 }}>PRIORITY</span>
              )}
              <span style={{ color: 'var(--text-dim)', fontSize: 13 }}>{targetLabel(r)}</span>
              {r.open_against_target > 1 && (
                <span style={{ fontSize: 12, fontWeight: 600 }}>
                  {r.open_against_target} open against this target
                </span>
              )}
              <span style={{ marginLeft: 'auto', color: 'var(--text-dim)', fontSize: 12 }}>
                {new Date(r.created_at).toLocaleString()}
              </span>
            </div>

            {r.clip_caption && (
              <div style={{ marginTop: 6, fontSize: 13.5 }}>“{r.clip_caption}”</div>
            )}
            {r.note && (
              <div style={{ marginTop: 6, fontSize: 13.5, color: 'var(--text-dim)' }}>
                Reporter said: {r.note}
              </div>
            )}

            <div style={{ marginTop: 6, color: 'var(--text-dim)', fontSize: 12 }}>
              from {r.reporter_username ? `@${r.reporter_username}` : 'a user'}
              {r.disclosure === 'reporter_attached'
                ? ' · reporter attached an excerpt'
                : ' · metadata only'}
              {r.resolved_by_email && ` · resolved by ${r.resolved_by_email}`}
              {r.resolution && ` · ${r.resolution}`}
            </div>

            {scope === 'open' && (
              <div style={{ display: 'flex', gap: 8, marginTop: 12, flexWrap: 'wrap' }}>
                {r.target_type === 'clip' && (
                  <Link href="/clips"><button className="ghost">Open clip queue</button></Link>
                )}
                {r.target_type !== 'clip' && (
                  <Link href={`/users?id=${r.target_id}`}>
                    <button className="ghost">Open profile</button>
                  </Link>
                )}
                {RESOLUTIONS.map(([value, label]) => (
                  <button key={value}
                          className={value === 'removed' ? 'danger' : 'ghost'}
                          disabled={busy === r.id}
                          onClick={() => resolve(r.id, value)}>
                    {label}
                  </button>
                ))}
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
