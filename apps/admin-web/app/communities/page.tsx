'use client';

import { Dropdown } from '../../components/ui/dropdown';

import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import Shell from '../../components/Shell';
import { PageHeader, Async, Pill, when, name } from '../../components/ui';
import { api } from '../../lib/api';

type Community = {
  official_key: string | null;
  id: string; handle: string; name: string; category: string | null;
  discoverable: boolean; join_policy: string;
  member_count: number; post_count: number;
  suspended_at: string | null; created_at: string;
  owner_name: string | null; owner_username: string | null;
  /** 0–4, counted like the app's "Finish setting up" card. See GET /admin/communities. */
  setup_done: number;
};

// Same order and wording as the apps' create flow and settings (JoinPolicyOption).
const JOIN_LABEL: Record<string, string> = {
  open: 'Open to all', approval: 'Request to join', invite_only: 'Invite only',
};
// The create flow's list (CommunityCategory). The column is free text, so this filters only.
const CATEGORIES = ['Education', 'Design', 'Tech', 'Gaming', 'Music', 'Sport', 'Local', 'Business'];
const SETUP_TOTAL = 4;

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
  const [joinPolicy, setJoinPolicy] = useState<'all' | 'open' | 'approval' | 'invite_only'>('all');
  const [category, setCategory] = useState('all');

  const load = useCallback(async (append: string | null = null) => {
    setLoading(true);
    setError(null);
    try {
      const p = new URLSearchParams();
      if (append) p.set('cursor', append);
      if (q.trim()) p.set('q', q.trim());
      if (state !== 'all') p.set('state', state);
      if (joinPolicy !== 'all') p.set('join_policy', joinPolicy);
      if (category !== 'all') p.set('category', category);
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
  }, [q, state, joinPolicy, category]);

  // Debounced so typing a handle does not fire a request per keystroke.
  useEffect(() => {
    const t = setTimeout(() => { void load(null); }, 250);
    return () => clearTimeout(t);
  }, [load]);

  return (
    <>
      <PageHeader
        title="Communities"
        subtitle="Manage official Voiid communities and review community moderation."
      />

      <div className="row" style={{ marginBottom: 16 }}>
        <input
          placeholder="Search name or handle"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          style={{ maxWidth: 320 }}
        />
        <Dropdown
          ariaLabel="Status"
          value={state}
          onChange={setState}
          options={[
            { value: 'all', label: 'All communities' },
            { value: 'active', label: 'Active' },
            { value: 'suspended', label: 'Suspended' },
          ]}
          className="min-w-[190px]"
        />
        <Dropdown
          ariaLabel="Who can join"
          value={joinPolicy}
          onChange={setJoinPolicy}
          options={[
            { value: 'all', label: 'Any join setting' },
            { value: 'open', label: JOIN_LABEL.open },
            { value: 'approval', label: JOIN_LABEL.approval },
            { value: 'invite_only', label: JOIN_LABEL.invite_only },
          ]}
          className="min-w-[190px]"
        />
        <Dropdown
          ariaLabel="Category"
          value={category}
          onChange={setCategory}
          options={[
            { value: 'all', label: 'All categories' },
            ...CATEGORIES.map((c) => ({ value: c, label: c })),
          ]}
          className="min-w-[170px]"
        />
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
                <th>Category</th>
                <th>Who can join</th>
                <th title="The host's Finish setting up card: description, Spaces, rules, invites">Setup</th>
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
                  <td className="muted">{c.category || '—'}</td>
                  <td className="muted">{JOIN_LABEL[c.join_policy] ?? c.join_policy}</td>
                  <td>
                    {/* Official communities are run by Voiid, not set up by a host. */}
                    {c.official_key
                      ? <span className="mute">—</span>
                      : c.setup_done >= SETUP_TOTAL
                        ? <Pill tone="ok">Done</Pill>
                        : <Pill tone={c.setup_done === 0 ? 'warning' : undefined}>
                            {c.setup_done}/{SETUP_TOTAL}
                          </Pill>}
                  </td>
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
