'use client';

import { useState } from 'react';
import Link from 'next/link';
import Shell from '../../components/Shell';
import { PageHeader, Pill, when, name } from '../../components/ui';
import { ListTable } from '../../components/List';
import { useList } from '../../components/useList';
import { api } from '../../lib/api';
import { PromptDialog, ConfirmDialog } from '../../components/ui/dialog';

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

  // The user each dialog acts on. Holding the whole record rather than an id so the
  // dialog can name the person — "sign out every device" is a different decision when you
  // can see whose devices they are.
  const [revoking, setRevoking] = useState<User | null>(null);
  const [revealing, setRevealing] = useState<User | null>(null);

  async function revoke(u: User) {
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

  async function reveal(u: User, reason: string) {
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
              {/* The name is the way in. A row that shows an account but cannot open it
                  leaves an operator with the summary and no way to answer the question the
                  summary raised. */}
              <Link href={`/users/${u.id}`}
                    style={{ fontWeight: 600, color: 'var(--text)' }}>
                {name(u.full_name, u.username)}
              </Link>
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
                      onClick={() => setRevealing(u)}
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
                onClick={() => setRevoking(u)}
              >
                Sign out devices
              </button>
            </td>
          </tr>
        ))}
      </ListTable>

      <PromptDialog
        open={revealing !== null}
        title="Reveal this phone number?"
        body="The number is shown to you once and the request is written to the audit log against your name. The panel masks numbers so it cannot be used to harvest them — only to confirm one you already hold."
        label="Why you need it"
        placeholder="The ticket or case this is for."
        confirmLabel="Reveal number"
        busy={busy === revealing?.id}
        onCancel={() => setRevealing(null)}
        onConfirm={(reason) => {
          const u = revealing;
          setRevealing(null);
          if (u) void reveal(u, reason);
        }}
      />

      <ConfirmDialog
        open={revoking !== null}
        title={`Sign out every device for ${revoking ? name(revoking.full_name, revoking.username, revoking.id.slice(0, 8)) : ''}?`}
        body="Every session ends immediately and they will have to log in again on each device. Their messages and keys are untouched."
        confirmLabel="Sign out all devices"
        destructive
        busy={busy === revoking?.id}
        onCancel={() => setRevoking(null)}
        onConfirm={() => {
          const u = revoking;
          setRevoking(null);
          if (u) void revoke(u);
        }}
      />
    </>
  );
}
