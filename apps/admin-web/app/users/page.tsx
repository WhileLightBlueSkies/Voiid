'use client';

import { useState } from 'react';
import Shell from '../../components/Shell';
import { PageHeader, Pill, when, name } from '../../components/ui';
import { ListTable } from '../../components/List';
import { useList } from '../../components/useList';
import { api } from '../../lib/api';

type User = {
  id: string; username: string | null; full_name: string | null;
  phone_masked: string | null; created_at: string; deleted_at: string | null;
  consent_given_at: string | null;
  clip_count: number; device_count: number;
};

export default function Users() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [q, setQ] = useState('');
  const list = useList<User>('/users', 'users', q.trim() ? { search: q.trim() } : {});
  const [busy, setBusy] = useState<string | null>(null);
  const [writeError, setWriteError] = useState<string | null>(null);
  /// Revealed numbers, held in component state ONLY — never written to storage. They vanish
  /// on navigation, which is the correct lifetime for something each viewing of which is
  /// separately audited.
  const [revealed, setRevealed] = useState<Record<string, string>>({});

  async function revoke(u: User) {
    // Signing every device out is disruptive and not obviously reversible from the user's
    // side, so it confirms — the one destructive act on this page.
    const label = name(u.full_name, u.username, u.id.slice(0, 8));
    if (!window.confirm(`Sign out every device for ${label}? They'll have to log in again.`)) return;
    setBusy(u.id);
    setWriteError(null);
    try {
      await api(`/users/${u.id}/revoke-devices`, { method: 'POST', json: {} });
      await list.reload();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally {
      setBusy(null);
    }
  }

  async function reveal(u: User) {
    const reason = window.prompt(
      'Why do you need this number? (recorded in the audit log against your name)',
    )?.trim();
    if (!reason) return;
    setBusy(u.id);
    setWriteError(null);
    try {
      const r = await api<{ phone: string | null }>(`/users/${u.id}/reveal-phone`, {
        method: 'POST', json: { reason },
      });
      setRevealed((prev) => ({ ...prev, [u.id]: r.phone ?? 'none on file' }));
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'could not reveal that number');
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <PageHeader
        title="Users & devices"
        subtitle="Numbers are masked by default. Revealing one is logged against your name."
      />

      <input
        placeholder="Search username, name, phone digits, or user id"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        style={{ maxWidth: 420, marginBottom: 16 }}
      />

      {writeError && <div className="notice error" style={{ marginBottom: 16 }}>{writeError}</div>}

      <ListTable
        head={['User', 'Phone', 'Devices', 'Clips', 'Joined', '']}
        loading={list.loading}
        error={list.error}
        empty={list.rows.length === 0}
        emptyText={q ? 'No user matches that.' : 'No users yet.'}
        cursor={list.cursor}
        onMore={list.more}
      >
        {list.rows.map((u) => (
          <tr key={u.id}>
            <td>
              <div style={{ fontWeight: 600 }}>{name(u.full_name, u.username)}</div>
              <div className="mute" style={{ fontSize: 12, fontFamily: 'ui-monospace, monospace' }}>
                {u.id.slice(0, 8)}…
              </div>
              {u.deleted_at && <Pill tone="danger">Deleted</Pill>}
            </td>
            <td className="mono">
              {revealed[u.id] ? (
                <span style={{ color: 'var(--text)' }}>{revealed[u.id]}</span>
              ) : (
                <span className="row" style={{ gap: 8 }}>
                  <span className="muted">{u.phone_masked ?? '—'}</span>
                  {u.phone_masked && (
                    <button
                      className="ghost sm" disabled={busy === u.id}
                      onClick={() => void reveal(u)}
                    >
                      Reveal
                    </button>
                  )}
                </span>
              )}
            </td>
            <td className="mono">{u.device_count}</td>
            <td className="mono">{u.clip_count}</td>
            <td className="muted" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>{when(u.created_at)}</td>
            <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
              <button
                className="ghost sm"
                disabled={busy === u.id || u.device_count === 0}
                onClick={() => void revoke(u)}
              >
                Sign out devices
              </button>
            </td>
          </tr>
        ))}
      </ListTable>
    </>
  );
}
