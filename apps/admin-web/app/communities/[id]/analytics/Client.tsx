'use client';

//
// One community's analytics.
//
// Message figures count ENVELOPES, never content: Space chat is end-to-end encrypted and the
// server holds no key. That caveat is printed on the page rather than left to the reader,
// because "messages" on a dashboard is otherwise read as "we can see what they said".
//

import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import Link from 'next/link';
import Shell from '../../../../components/Shell';
import { PageHeader, Async, Pill, when, name } from '../../../../components/ui';
import { AreaChart, BarRow, type Point } from '../../../../components/Chart';
import { api } from '../../../../lib/api';

type Totals = {
  members: number; pending: number; banned: number; departed: number;
  joined_window: number; left_window: number;
  posts: number; posts_removed: number; likes: number;
  spaces: number; events: number;
};
type Row = { day: string; joined: number; departed: number; posts: number; messages: number };
type Space = {
  id: string; name: string | null; kind: string;
  messages: number; participants: number; last_message_at: string | null;
};
type Contributor = {
  author_id: string; full_name: string | null; username: string | null;
  posts: number; likes: number;
};
type Payload = {
  days: number; totals: Totals; series: Row[]; spaces: Space[]; contributors: Contributor[];
};

export default function Analytics() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const { id } = useParams<{ id: string }>();
  const [days, setDays] = useState(30);
  const [d, setD] = useState<Payload | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [communityName, setCommunityName] = useState<string>('');

  const load = useCallback(async () => {
    try {
      setD(await api<Payload>(`/communities/${id}/analytics?days=${days}`));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load analytics');
    }
  }, [id, days]);

  useEffect(() => { void load(); }, [load]);

  useEffect(() => {
    // Name only, for the header. Kept separate so a failure here cannot blank the numbers.
    api<{ community: { name: string } }>(`/communities/${id}`)
      .then((r) => setCommunityName(r.community.name))
      .catch(() => {});
  }, [id]);

  const pts = (k: keyof Row): Point[] =>
    (d?.series ?? []).map((r) => ({ day: r.day, value: Number(r[k]) || 0 }));

  const t = d?.totals;
  // Net movement over the window. Churn is the number a host acts on, and a member count
  // alone hides it completely.
  const net = t ? t.joined_window - t.left_window : 0;

  return (
    <>
      <div style={{ marginBottom: 14 }}>
        <Link href={`/communities/${id}`} style={{ fontSize: 14 }}>← Community</Link>
      </div>

      <PageHeader
        title={communityName ? `${communityName} · Analytics` : 'Analytics'}
        subtitle="Membership, posting and Space activity."
        right={
          <div className="row" style={{ gap: 6 }}>
            {[7, 30, 90].map((n) => (
              <button key={n} className={n === days ? '' : 'ghost'}
                      onClick={() => setDays(n)} style={{ padding: '5px 11px' }}>
                {n}d
              </button>
            ))}
          </div>
        }
      />

      <Async loading={!d} error={error} empty={false} emptyText="">
        {d && t && (
          <div style={{ display: 'grid', gap: 26 }}>
            <section>
              <div className="section-label">Membership</div>
              <div style={{ display: 'grid', gap: 12,
                            gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))' }}>
                <Tile label="Members" value={t.members} />
                <Tile label={`Joined · ${days}d`} value={t.joined_window} />
                <Tile label={`Left · ${days}d`} value={t.left_window}
                      tone={t.left_window > 0 ? 'attention' : undefined} />
                <Tile label="Net" value={net > 0 ? `+${net}` : String(net)}
                      tone={net < 0 ? 'danger' : undefined} />
                <Tile label="Requests" value={t.pending}
                      tone={t.pending > 0 ? 'attention' : undefined} />
                <Tile label="Banned" value={t.banned} />
              </div>
            </section>

            <section>
              <div className="section-label">Activity · last {days} days</div>
              <div style={{ display: 'grid', gap: 12,
                            gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))' }}>
                <Panel title="Members joined">
                  <AreaChart points={pts('joined')} label="Joins" />
                </Panel>
                <Panel title="Members left">
                  <AreaChart points={pts('departed')} label="Departures" color="var(--danger)" />
                </Panel>
                <Panel title="Posts">
                  <AreaChart points={pts('posts')} label="Posts" color="var(--ok)" />
                </Panel>
                <Panel title="Messages in Spaces">
                  <AreaChart points={pts('messages')} label="Messages" color="var(--info)" />
                  <p className="mute" style={{ fontSize: 12, margin: '10px 0 0' }}>
                    Counts messages sent, not their content — Space chat is end-to-end
                    encrypted and unreadable from here.
                  </p>
                </Panel>
              </div>
            </section>

            <section>
              <div className="section-label">Spaces</div>
              <div className="panel">
                <header><h2>Activity by Space · last {days} days</h2></header>
                <div className="body">
                  {d.spaces.length === 0 ? (
                    <div className="empty">No Spaces yet.</div>
                  ) : (
                    <>
                      {(() => {
                        const max = Math.max(...d.spaces.map((s) => s.messages), 1);
                        return d.spaces.map((s) => (
                          <div key={s.id} style={{ padding: '4px 0' }}>
                            <BarRow
                              label={`${s.name ?? 'Space'}${s.kind === 'announcement' ? ' · announcements' : ''}`}
                              value={s.messages}
                              max={max}
                            />
                            <div className="mute" style={{ fontSize: 12, marginTop: -2 }}>
                              {s.participants} {s.participants === 1 ? 'person' : 'people'} posting
                              {s.last_message_at ? ` · last ${when(s.last_message_at)}` : ' · nothing yet'}
                            </div>
                          </div>
                        ));
                      })()}
                    </>
                  )}
                </div>
              </div>
            </section>

            <section>
              <div className="section-label">Content</div>
              <div style={{ display: 'grid', gap: 12,
                            gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))' }}>
                <Panel title="Feed">
                  <BarRow label="Posts" value={t.posts} max={Math.max(t.posts, 1)} />
                  <BarRow label="Removed" value={t.posts_removed} max={Math.max(t.posts, 1)} />
                  <BarRow label="Likes" value={t.likes} max={Math.max(t.likes, 1)} />
                  <BarRow label="Events" value={t.events} max={Math.max(t.events, 1)} />
                </Panel>

                <Panel title={`Top contributors · ${days}d`}>
                  {d.contributors.length === 0 ? (
                    <div className="empty" style={{ padding: '18px 0' }}>Nobody has posted yet.</div>
                  ) : (
                    d.contributors.map((c) => (
                      <div key={c.author_id} className="row" style={{ gap: 10, padding: '5px 0' }}>
                        <span style={{ fontSize: 13, flex: 1, minWidth: 0, overflow: 'hidden',
                                       textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                          {name(c.full_name, c.username)}
                        </span>
                        <Pill>{c.posts} {c.posts === 1 ? 'post' : 'posts'}</Pill>
                        <span className="mono mute" style={{ fontSize: 12, minWidth: 46,
                                                             textAlign: 'right' }}>
                          {c.likes} ♥
                        </span>
                      </div>
                    ))
                  )}
                  {/* Said plainly: this is not a ranking of who talks most. */}
                  <p className="mute" style={{ fontSize: 12, margin: '10px 0 0' }}>
                    Ranked on feed posts. Encrypted Space messages are deliberately not counted
                    towards a leaderboard.
                  </p>
                </Panel>
              </div>
            </section>
          </div>
        )}
      </Async>
    </>
  );
}

function Tile({ label, value, tone }: {
  label: string; value: number | string; tone?: 'attention' | 'danger';
}) {
  return (
    <div className="card" style={{ padding: 14 }}>
      <div className="mute" style={{ fontSize: 12 }}>{label}</div>
      <div className="mono" style={{ fontSize: 24, fontWeight: 650, marginTop: 2,
                                     letterSpacing: '-0.02em',
                                     color: tone ? `var(--${tone})` : 'var(--text)' }}>
        {value}
      </div>
    </div>
  );
}

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="panel">
      <header><h2>{title}</h2></header>
      <div className="body">{children}</div>
    </div>
  );
}
