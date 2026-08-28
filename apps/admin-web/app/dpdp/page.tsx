'use client';

//
// Data rights requests (India's DPDP Act). The one queue on this console with a legal clock:
// a request breaches its period by being FORGOTTEN, not by being refused, so overdue is
// surfaced on the row and on the dashboard rather than behind a filter.
//

import { useState } from 'react';
import Shell from '../../components/Shell';
import { PageHeader, Pill, when } from '../../components/ui';
import { ListTable } from '../../components/List';
import { useList } from '../../components/useList';
import { api } from '../../lib/api';

type Req = {
  id: string; user_id: string; kind: string; status: string;
  subject_note: string | null; opened_at: string; due_at: string;
  closed_at: string | null; resolution: string | null; overdue: boolean;
  phone_masked: string | null;
};

export default function Dpdp() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [closed, setClosed] = useState(false);
  const list = useList<Req>('/dpdp', 'requests', { status: closed ? 'closed' : 'open' });
  const [busy, setBusy] = useState<string | null>(null);
  const [writeError, setWriteError] = useState<string | null>(null);

  async function run(id: string, path: string, json: unknown) {
    setBusy(id);
    setWriteError(null);
    try {
      await api(path, { method: 'POST', json });
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
        title="Data requests"
        subtitle="Access and erasure requests, with their statutory deadline."
        right={
          <button className="ghost" onClick={() => setClosed((c) => !c)}>
            {closed ? 'Show open' : 'Show closed'}
          </button>
        }
      />

      {writeError && <div className="notice error" style={{ marginBottom: 16 }}>{writeError}</div>}

      <ListTable
        head={['Request', 'Subject', 'Opened', closed ? 'Closed' : 'Due', '']}
        loading={list.loading}
        error={list.error}
        empty={list.rows.length === 0}
        emptyText={closed ? 'Nothing closed yet.' : 'No open requests.'}
        cursor={list.cursor}
        onMore={list.more}
      >
        {list.rows.map((r) => (
          <tr key={r.id}>
            <td>
              <Pill tone={r.kind === 'erasure' ? 'danger' : 'accent'}>{r.kind}</Pill>
              <div className="mute" style={{ fontSize: 13, marginTop: 4 }}>{r.status}</div>
              {r.subject_note && <div className="mute" style={{ fontSize: 13 }}>{r.subject_note}</div>}
            </td>
            <td className="muted mono">{r.phone_masked ?? r.user_id.slice(0, 8) + '…'}</td>
            <td className="muted" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>{when(r.opened_at)}</td>
            <td style={{ whiteSpace: 'nowrap', fontSize: 13 }}>
              {closed ? (
                <span className="muted">{when(r.closed_at)}</span>
              ) : r.overdue ? (
                <Pill tone="danger">Overdue · {when(r.due_at)}</Pill>
              ) : (
                <span className="muted">{when(r.due_at)}</span>
              )}
            </td>
            <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
              {!closed && (
                <div className="row" style={{ justifyContent: 'flex-end', gap: 8 }}>
                  {r.kind === 'erasure' && (
                    <button
                      className="danger sm"
                      disabled={busy === r.id}
                      onClick={() => {
                        // Erasure soft-deletes a real person's account. It confirms, and the
                        // wording says what actually happens rather than "are you sure".
                        if (window.confirm('Start erasure? This soft-deletes the account and the worker purges it after the grace period.')) {
                          void run(r.id, `/dpdp/${r.id}/start-erasure`, {});
                        }
                      }}
                    >
                      Start erasure
                    </button>
                  )}
                  <button
                    className="ghost sm"
                    disabled={busy === r.id}
                    onClick={() => {
                      const resolution = window.prompt('Close with what resolution?')?.trim();
                      if (resolution) void run(r.id, `/dpdp/${r.id}/status`, { status: 'closed', resolution });
                    }}
                  >
                    Close
                  </button>
                </div>
              )}
            </td>
          </tr>
        ))}
      </ListTable>
    </>
  );
}
