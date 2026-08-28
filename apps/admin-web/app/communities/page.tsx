'use client';

import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import Shell from '../../components/Shell';
import { PageHeader, Async, Pill, when, name } from '../../components/ui';
import { api } from '../../lib/api';

type Community = {
  id: string; handle: string; name: string; category: string | null;
  discoverable: boolean; join_policy: string;
  member_count: number; post_count: number;
  suspended_at: string | null; created_at: string;
  owner_name: string | null; owner_username: string | null;
};

export default function Communities() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [rows, setRows] = useState<Community[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [more, setMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [q, setQ] = useState('');
  const [state, setState] = useState<'all' | 'active' | 'suspended'>('all');

  const load = useCallback(async (append: string | null = null) => {
    setLoading(true);
    setError(null);
    try {
      const p = new URLSearchParams();
      if (append) p.set('cursor', append);
      if (q.trim()) p.set('q', q.trim());
      if (state !== 'all') p.set('state', state);
      const r = await api<{ communities: Community[]; next_cursor: string | null }>(
        `/communities?${p}`,
      );
      setRows((prev) => (append ? [...prev, ...r.communities] : r.communities));
      setCursor(r.next_cursor);
      setMore(Boolean(r.next_cursor));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load communities');
    } finally {
      setLoading(false);
    }
  }, [q, state]);

  // Debounced so typing a handle does not fire a request per keystroke.
  useEffect(() => {
    const t = setTimeout(() => { void load(null); }, 250);
    return () => clearTimeout(t);
  }, [load]);

  return (
    <>
      <PageHeader
        title="Communities"
        subtitle="Every community on Voiid, including the ones nobody has reported yet."
      />

      <div className="row" style={{ marginBottom: 16 }}>
        <input
          placeholder="Search name or handle"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          style={{ maxWidth: 320 }}
        />
        <select
          value={state}
          onChange={(e) => setState(e.target.value as typeof state)}
          style={{ maxWidth: 180 }}
        >
          <option value="all">All</option>
          <option value="active">Active</option>
          <option value="suspended">Suspended</option>
        </select>
      </div>

      <Async
        loading={loading && rows.length === 0}
        error={error}
        empty={rows.length === 0}
        emptyText={q ? 'No community matches that.' : 'No communities yet.'}
      >
        <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
          <table>
            <thead>
              <tr>
                <th>Community</th>
                <th>Owner</th>
                <th>Members</th>
                <th>Posts</th>
                <th>Created</th>
                <th>State</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => (
                <tr key={c.id}>
                  <td>
                    <Link href={`/communities/${c.id}`} style={{ fontWeight: 600, color: 'var(--text)' }}>
                      {c.name}
                    </Link>
                    <div className="mute" style={{ fontSize: 13 }}>@{c.handle}</div>
                  </td>
                  <td className="muted">{name(c.owner_name, c.owner_username)}</td>
                  <td className="mono">{c.member_count}</td>
                  <td className="mono">{c.post_count}</td>
                  <td className="muted" style={{ fontSize: 13 }}>{when(c.created_at)}</td>
                  <td>
                    {c.suspended_at
                      ? <Pill tone="danger">Suspended</Pill>
                      : c.discoverable
                        ? <Pill tone="ok">Discoverable</Pill>
                        : <Pill>Private</Pill>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {more && (
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
