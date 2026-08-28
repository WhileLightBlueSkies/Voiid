'use client';

import { useState } from 'react';
import Shell from '../../components/Shell';
import { PageHeader, Pill, when } from '../../components/ui';
import { ListTable } from '../../components/List';
import { useList } from '../../components/useList';
import { api } from '../../lib/api';

type Report = {
  id: string; target_type: string; target_id: string;
  reason: string; note: string | null; has_evidence: boolean;
  status: string; created_at: string;
  resolved_at: string | null; resolution: string | null;
  reporter_username: string | null;
  report_count?: number;
};

const RESOLUTIONS = ['removed', 'no_action', 'duplicate', 'escalated'] as const;

export default function Reports() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [resolved, setResolved] = useState(false);
  const list = useList<Report>('/reports', 'reports', { status: resolved ? 'resolved' : 'open' });
  const [busy, setBusy] = useState<string | null>(null);
  const [writeError, setWriteError] = useState<string | null>(null);

  async function resolve(id: string, resolution: string) {
    setBusy(id);
    setWriteError(null);
    try {
      const note = window.prompt('Note (optional)')?.trim() ?? '';
      await api(`/reports/${id}/resolve`, { method: 'POST', json: { resolution, note } });
      await list.reload();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <PageHeader
        title="Reports"
        subtitle="What users have flagged, newest first."
        right={
          <button className="ghost" onClick={() => setResolved((r) => !r)}>
            {resolved ? 'Show open' : 'Show resolved'}
          </button>
        }
      />

      {writeError && <div className="notice error" style={{ marginBottom: 16 }}>{writeError}</div>}

      <ListTable
        head={['Target', 'Reason', 'Reporter', 'Filed', resolved ? 'Resolution' : '']}
        loading={list.loading}
        error={list.error}
        empty={list.rows.length === 0}
        emptyText={resolved ? 'Nothing resolved yet.' : 'Nothing open. The queue is clear.'}
        cursor={list.cursor}
        onMore={list.more}
      >
        {list.rows.map((r) => (
          <tr key={r.id}>
            <td>
              <Pill>{r.target_type}</Pill>
              <div className="mute" style={{ fontSize: 12, fontFamily: 'ui-monospace, monospace', marginTop: 4 }}>
                {r.target_id.slice(0, 8)}…
              </div>
              {/* Repeat reports on one target are the strongest signal in the queue, so the
                  count sits on the row rather than behind a click. */}
              {(r.report_count ?? 0) > 1 && (
                <div style={{ marginTop: 4 }}>
                  <Pill tone="warning">{r.report_count} reports</Pill>
                </div>
              )}
            </td>
            <td>
              <div>{r.reason}</div>
              {r.note && <div className="mute" style={{ fontSize: 13 }}>{r.note}</div>}
              {r.has_evidence && <Pill>Evidence attached</Pill>}
            </td>
            <td className="muted">{r.reporter_username ? `@${r.reporter_username}` : '—'}</td>
            <td className="muted" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>{when(r.created_at)}</td>
            <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
              {resolved ? (
                <span className="muted">{r.resolution ?? '—'}</span>
              ) : (
                <select
                  disabled={busy === r.id}
                  defaultValue=""
                  onChange={(e) => { if (e.target.value) void resolve(r.id, e.target.value); }}
                  style={{ width: 'auto', minWidth: 150 }}
                >
                  <option value="" disabled>Resolve as…</option>
                  {RESOLUTIONS.map((v) => <option key={v} value={v}>{v.replace('_', ' ')}</option>)}
                </select>
              )}
            </td>
          </tr>
        ))}
      </ListTable>
    </>
  );
}
