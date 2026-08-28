'use client';

import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import Link from 'next/link';
import Shell, { type Me } from '../../../components/Shell';
import { PageHeader, Stat, Async, Pill, when, name } from '../../../components/ui';
import { api } from '../../../lib/api';

type Detail = {
  community: {
    id: string; handle: string; name: string; description: string | null;
    category: string | null; discoverable: boolean; join_policy: string;
    member_count: number; max_members: number | null; members_can_invite: boolean;
    suspended_at: string | null; created_at: string;
    owner_name: string | null; owner_username: string | null;
  };
  counts: { active?: number; pending?: number; banned?: number; managers?: number };
  posts: { total: number; last_7d: number };
  members: {
    user_id: string; role: string; state: string; joined_at: string;
    full_name: string | null; username: string | null;
  }[];
  members_truncated: boolean;
};

export default function CommunityDetail() {
  return <Shell>{(me) => <Body me={me} />}</Shell>;
}

function Body({ me }: { me: Me }) {
  const { id } = useParams<{ id: string }>();
  const [d, setD] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [writeError, setWriteError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setD(await api<Detail>(`/communities/${id}`));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load this community');
    }
  }, [id]);

  useEffect(() => { void load(); }, [load]);

  async function suspend() {
    // A takedown with no stated reason is one nobody can review later — and the server
    // rejects it anyway, so asking here saves a round trip and states the requirement.
    const reason = window.prompt('Why is this community being suspended?')?.trim();
    if (!reason) return;
    await act(`/communities/${id}/suspend`, { reason });
  }

  async function restore() {
    const reason = window.prompt('Why is it being reinstated? (optional)')?.trim() ?? '';
    await act(`/communities/${id}/restore`, { reason });
  }

  async function act(path: string, json: unknown) {
    setBusy(true);
    setWriteError(null);
    try {
      await api(path, { method: 'POST', json });
      await load();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Async loading={!d} error={error} empty={false} emptyText="">
      {d && (
        <>
          <div style={{ marginBottom: 14 }}>
            <Link href="/communities" style={{ fontSize: 14 }}>← Communities</Link>
          </div>

          <PageHeader
            title={d.community.name}
            subtitle={`@${d.community.handle}${d.community.category ? ` · ${d.community.category}` : ''}`}
            right={
              // Suspension is admin-role only server-side. Showing the button to a moderator
              // would only produce a 403 — the gate here is courtesy, not enforcement.
              me.role === 'admin' ? (
                d.community.suspended_at ? (
                  <button className="ghost" disabled={busy} onClick={() => void restore()}>
                    {busy ? 'Working…' : 'Lift suspension'}
                  </button>
                ) : (
                  <button className="danger" disabled={busy} onClick={() => void suspend()}>
                    {busy ? 'Working…' : 'Suspend'}
                  </button>
                )
              ) : undefined
            }
          />

          {writeError && <div className="notice error" style={{ marginBottom: 16 }}>{writeError}</div>}

          {d.community.suspended_at && (
            <div className="notice error" style={{ marginBottom: 16 }}>
              Suspended {when(d.community.suspended_at)}. Members cannot post or join while
              this stands. Nothing has been deleted.
            </div>
          )}

          <div style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', marginBottom: 22 }}>
            <Stat label="Members" value={d.counts.active ?? 0} />
            <Stat label="Managers" value={d.counts.managers ?? 0} />
            <Stat
              label="Requests"
              value={d.counts.pending ?? 0}
              tone={(d.counts.pending ?? 0) > 0 ? 'warning' : undefined}
            />
            <Stat label="Banned" value={d.counts.banned ?? 0} />
            <Stat label="Posts" value={d.posts.total} />
            <Stat label="Posts (7d)" value={d.posts.last_7d} />
          </div>

          <div className="card" style={{ marginBottom: 22 }}>
            <h2 style={{ marginBottom: 12 }}>About</h2>
            <Field label="Owner" value={name(d.community.owner_name, d.community.owner_username)} />
            <Field label="Created" value={when(d.community.created_at)} />
            <Field label="Joining" value={d.community.join_policy} />
            <Field label="Discoverable" value={d.community.discoverable ? 'Yes' : 'No'} />
            <Field label="Members can invite" value={d.community.members_can_invite ? 'Yes' : 'No'} />
            {d.community.description && <Field label="Description" value={d.community.description} />}
          </div>

          <h2 style={{ marginBottom: 10 }}>Roster</h2>
          {d.members_truncated && (
            <div className="notice info" style={{ marginBottom: 10 }}>
              Showing the first 200 members. This is a cap on the list, not the roster.
            </div>
          )}
          <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
            <table>
              <thead>
                <tr><th>Member</th><th>Role</th><th>State</th><th>Joined</th></tr>
              </thead>
              <tbody>
                {d.members.map((m) => (
                  <tr key={m.user_id}>
                    <td>{name(m.full_name, m.username)}</td>
                    <td>
                      {m.role === 'owner' ? <Pill tone="accent">Owner</Pill>
                        : m.role === 'admin' ? <Pill tone="accent">Admin</Pill>
                        : <span className="muted">Member</span>}
                    </td>
                    <td>
                      {m.state === 'banned' ? <Pill tone="danger">Banned</Pill>
                        : m.state === 'pending' ? <Pill tone="warning">Pending</Pill>
                        : <Pill tone="ok">Active</Pill>}
                    </td>
                    <td className="muted" style={{ fontSize: 13 }}>{when(m.joined_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <p className="mute" style={{ fontSize: 13, marginTop: 18, maxWidth: 640 }}>
            Community chat is end-to-end encrypted and cannot be read from here. Post counts
            come from the community feed, which is not encrypted.
          </p>
        </>
      )}
    </Async>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div style={{ display: 'flex', gap: 16, padding: '7px 0', fontSize: 14 }}>
      <span className="mute" style={{ width: 150, flex: '0 0 150px' }}>{label}</span>
      <span style={{ minWidth: 0 }}>{value}</span>
    </div>
  );
}
