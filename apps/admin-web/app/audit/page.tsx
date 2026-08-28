'use client';

//
// The audit log. GET /admin/audit has existed with no UI at all — so every moderation action
// and, more importantly, every DENIED privileged attempt has been recorded where nobody
// could read it. A log nobody looks at is a log that is not doing its job.
//

import { useCallback, useEffect, useState } from 'react';
import Shell from '../../components/Shell';
import { PageHeader, Async, Pill, when } from '../../components/ui';
import { api } from '../../lib/api';

type Entry = {
  id: string; admin_id: string | null; action: string;
  target_type: string | null; target_id: string | null;
  detail: unknown; created_at: string;
  admin_email?: string | null; admin_name?: string | null;
};

export default function Audit() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [rows, setRows] = useState<Entry[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (append: string | null = null) => {
    setLoading(true);
    try {
      const p = new URLSearchParams();
      if (append) p.set('cursor', append);
      const r = await api<{ entries?: Entry[]; audit?: Entry[]; next_cursor: string | null }>(
        `/audit?${p}`,
      );
      // The route's envelope key is read defensively: this list is the record of what
      // happened, and rendering it as empty because a key was named differently would be
      // the most misleading possible failure.
      const list = r.entries ?? r.audit ?? [];
      setRows((prev) => (append ? [...prev, ...list] : list));
      setCursor(r.next_cursor);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load the audit log');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(null); }, [load]);

  return (
    <>
      <PageHeader
        title="Audit log"
        subtitle="Every action taken from this console, and every privileged attempt that was refused."
      />

      <Async
        loading={loading && rows.length === 0}
        error={error}
        empty={rows.length === 0}
        emptyText="Nothing recorded yet."
      >
        <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
          <table>
            <thead>
              <tr><th>When</th><th>Who</th><th>Action</th><th>Target</th><th>Detail</th></tr>
            </thead>
            <tbody>
              {rows.map((e) => (
                <tr key={e.id}>
                  <td className="muted" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>{when(e.created_at)}</td>
                  <td className="muted" style={{ fontSize: 13 }}>{e.admin_name || e.admin_email || '—'}</td>
                  <td>
                    {/* A refusal is the interesting half of an incident, so it is the one
                        action that gets a colour of its own. */}
                    {e.action.endsWith('forbidden')
                      ? <Pill tone="danger">{e.action}</Pill>
                      : <Pill>{e.action}</Pill>}
                  </td>
                  <td className="muted" style={{ fontSize: 13 }}>
                    {e.target_type ? `${e.target_type}` : '—'}
                    {e.target_id && (
                      <div className="mute" style={{ fontSize: 12, fontFamily: 'ui-monospace, monospace' }}>
                        {e.target_id.slice(0, 8)}…
                      </div>
                    )}
                  </td>
                  <td className="mute" style={{ fontSize: 12, maxWidth: 260, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {e.detail ? JSON.stringify(e.detail) : '—'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {cursor && (
          <div style={{ marginTop: 14, textAlign: 'center' }}>
            <button className="ghost" disabled={loading} onClick={() => void load(cursor)}>
              {loading ? 'Loading…' : 'Load more'}
            </button>
          </div>
        )}
      </Async>
    </>
  );
}
