'use client';

import { Dropdown } from '../../components/ui/dropdown';

import { useRef, useState } from 'react';
import Shell from '../../components/Shell';
import { PageHeader, Pill, when } from '../../components/ui';
import { ListTable } from '../../components/List';
import { useList } from '../../components/useList';
import { api } from '../../lib/api';
import { PromptDialog } from '../../components/ui/dialog';


type Report = {
  id: string; target_type: string; target_id: string;
  reason: string; note: string | null; has_evidence: boolean;
  status: string; created_at: string;
  resolved_at: string | null; resolution: string | null;
  reporter_username: string | null;
  report_count?: number;
};

const RESOLUTIONS = ['removed', 'no_action', 'duplicate', 'escalated'] as const;
const RESOLUTION_HINTS: Record<(typeof RESOLUTIONS)[number], string> = {
  removed: 'Take the content down',
  no_action: 'Reviewed, nothing breaks the rules',
  duplicate: 'Already handled in another report',
  escalated: 'Needs a senior or legal decision',
};

export default function Reports() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [resolved, setResolved] = useState(false);
  const list = useList<Report>('/reports', 'reports', { status: resolved ? 'resolved' : 'open' });
  const busyRef = useRef(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [writeError, setWriteError] = useState<string | null>(null);

  // What the open dialog will resolve, or null. W01 SURVIVES THE REWRITE: cancelling and
  // submitting an empty note were once the same empty string, so a cancelled dialog still
  // resolved the report — an irreversible action taken after the operator declined it.
  // Here they are different code paths entirely; onCancel cannot reach resolve().
  const [pending, setPending] = useState<{ id: string; resolution: string } | null>(null);

  async function resolve(id: string, resolution: string, note: string) {
    if (busyRef.current) return;

    // One report at a time. Two resolutions in flight can finish out of order and leave the
    // list showing the loser.
    busyRef.current = true;
    setBusy(id);
    setWriteError(null);
    try {
      await api(`/reports/${id}/resolve`, { method: 'POST', json: { resolution, note } });
      await list.reload();
    } catch (e) {
      // The error stays on screen and the row is NOT reloaded away: an operator who sees
      // nothing change needs to know the resolution did not land.
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally {
      busyRef.current = false;
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
                <>
                {/* An ACTION menu, not a stored choice: it always shows the prompt, and a
                    pick opens the confirmation rather than changing a value in place. */}
                <Dropdown
                  ariaLabel="Resolve report"
                  placeholder="Resolve as…"
                  value=""
                  disabled={busy !== null}
                  onChange={(resolution) => setPending({ id: r.id, resolution })}
                  options={RESOLUTIONS.map((v) => ({
                    value: v,
                    label: v.charAt(0).toUpperCase() + v.slice(1).replace('_', ' '),
                    hint: RESOLUTION_HINTS[v],
                    tone: v === 'removed' ? 'danger' as const : undefined,
                  }))}
                  className="min-w-[160px]"
                  menuMinWidth={240}
                />
                </>
              )}
            </td>
          </tr>
        ))}
      </ListTable>

      <PromptDialog
        open={pending !== null}
        title={`Resolve as ${pending?.resolution.replace(/_/g, ' ') ?? ''}?`}
        body="The note is kept with the report and is what someone reviewing this decision later will read."
        label="Note"
        placeholder="Optional — what you found, or why this outcome."
        confirmLabel="Resolve report"
        requireReason={false}
        busy={busy === pending?.id}
        onCancel={() => setPending(null)}
        onConfirm={(note) => {
          const p = pending;
          setPending(null);
          if (p) void resolve(p.id, p.resolution, note);
        }}
      />
    </>
  );
}
