'use client';

import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import Shell, { type Me } from '../../../components/Shell';
import { WithRecordId } from '../../../components/RecordId';
import { PageHeader, Async, when, name } from '../../../components/ui';
import { api } from '../../../lib/api';
import { Card } from '../../../components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../../components/ui/table';
import { Badge } from '../../../components/ui/badge';
import { Button } from '../../../components/ui/button';
import { AreaChart, MultiLineChart } from '../../../components/Chart';
import { Users2, MessageSquare, ShieldAlert, UserPlus } from 'lucide-react';
import OfficialControls from './OfficialControls';
import ModeratorPanel from './ModeratorPanel';
import FinancePanel from './FinancePanel';
import PaymentsDemo from './PaymentsDemo';

type Detail = {
  community: {
    official_key: string | null; posting_policy: string;
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

type Post = {
  id: string; author_id: string; body: string | null; media_url: string | null;
  like_count: number; comment_count: number; created_at: string; edited_at: string | null;
  author_name: string | null; author_username: string | null;
};

/** The daily series behind the inline charts — same endpoint the Analytics page reads. */
type Pulse = {
  days: number;
  series: { day: string; joined: number; departed: number; posts: number; messages: number }[];
};

type Entitlement = {
  id: string; capability: string; granted_at: string;
  expires_at: string | null; revoked_at: string | null;
  note: string; live: boolean; granted_by_email: string | null;
};

export default function CommunityDetail() {
  // The id comes from the address bar, not useParams() — see components/RecordId.tsx.
  return <Shell>{(me) => <WithRecordId section="communities" noun="community">{(id) => <Body key={id} me={me} id={id} />}</WithRecordId>}</Shell>;
}

function Body({ me, id }: { me: Me; id: string }) {
  const [d, setD] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [writeError, setWriteError] = useState<string | null>(null);
  const [ents, setEnts] = useState<Entitlement[]>([]);
  const [available, setAvailable] = useState<string[]>([]);
  const [entsError, setEntsError] = useState<string | null>(null);
  const [posts, setPosts] = useState<Post[]>([]);
  const [postsError, setPostsError] = useState<string | null>(null);
  // Activity lives ON this page rather than only behind the Analytics link. "Is this
  // community alive, and which way is it going" is the question you are already asking
  // while looking at its member count — making it a second page means the two facts are
  // never on screen together, and the answer arrives after a navigation.
  const [pulse, setPulse] = useState<Pulse | null>(null);

  const load = useCallback(async () => {
    try {
      setD(await api<Detail>(`/communities/${id}`));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load this community');
    }
  }, [id]);

  const loadEnts = useCallback(async () => {
    try {
      const r = await api<{ entitlements: Entitlement[]; available: string[] }>(
        `/communities/${id}/entitlements`);
      setEnts(r.entitlements);
      setAvailable(r.available);
      setEntsError(null);
    } catch (e) {
      // Kept apart from the community's own load error: a capability list that failed to
      // fetch must not draw as "none granted", which would invite granting a second time.
      setEntsError(e instanceof Error ? e.message : 'could not load capabilities');
    }
  }, [id]);

  const loadPulse = useCallback(async () => {
    // Failure is SILENT here, unlike the feed above. The charts are context around the
    // moderation controls, not the reason the page exists — a red banner for a missing
    // sparkline would outrank the suspension notice it sits beside.
    try { setPulse(await api<Pulse>(`/communities/${id}/analytics?days=30`)); } catch { /* context only */ }
  }, [id]);

  const loadPosts = useCallback(async () => {
    try {
      const r = await api<{ posts: Post[] }>(`/communities/${id}/posts?limit=20`);
      setPosts(r.posts);
      setPostsError(null);
    } catch (e) {
      // Apart from the community's own error: a feed that failed to load must not draw as
      // "nothing posted", which would tell a moderator there is nothing to look at.
      setPostsError(e instanceof Error ? e.message : 'could not load the feed');
    }
  }, [id]);

  useEffect(() => { void load(); void loadEnts(); void loadPosts(); void loadPulse(); },
            [load, loadEnts, loadPosts, loadPulse]);

  async function grant(capability: string) {
    const note = window.prompt(
      `Why does this community get ${capability}? (recorded against your name)`)?.trim();
    if (!note) return;
    setBusy(true);
    setWriteError(null);
    try {
      await api(`/communities/${id}/entitlements`, { method: 'POST', json: { capability, note } });
      await loadEnts();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally { setBusy(false); }
  }

  async function revoke(capability: string) {
    const note = window.prompt(`Why is ${capability} being switched off?`)?.trim();
    if (!note) return;
    setBusy(true);
    setWriteError(null);
    try {
      await api(`/communities/${id}/entitlements/${capability}/revoke`,
                { method: 'POST', json: { note } });
      await loadEnts();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally { setBusy(false); }
  }

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
              <div className="row" style={{ gap: 8 }}>
              <Link href={`/communities/${id}/analytics`}>
                <Button variant="outline" size="sm">Full analytics</Button>
              </Link>
              {me.role === 'admin' ? (
                d.community.suspended_at ? (
                  <Button variant="outline" size="sm" disabled={busy} onClick={() => void restore()}>
                    {busy ? 'Working…' : 'Lift suspension'}
                  </Button>
                ) : (
                  <Button variant="destructive" size="sm" disabled={busy} onClick={() => void suspend()}>
                    {busy ? 'Working…' : 'Suspend'}
                  </Button>
                )
              ) : null}
              </div>
            }
          />

          {writeError && <div className="notice error" style={{ marginBottom: 16 }}>{writeError}</div>}

          {d.community.suspended_at && (
            <div className="notice error" style={{ marginBottom: 16 }}>
              Suspended {when(d.community.suspended_at)}. Members cannot post or join while
              this stands. Nothing has been deleted.
            </div>
          )}

          <div className="mb-5 grid gap-3"
               style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(158px, 1fr))' }}>
            <CountCard icon={Users2} label="Members" value={d.counts.active ?? 0}
                       sub={`${d.counts.managers ?? 0} managers`} />
            {/* The only figure here that is a QUEUE rather than a measurement. It carries
                the tint because a pending request is work waiting, and a count of work
                waiting should not look the same as a count of things that merely exist. */}
            <CountCard icon={UserPlus} label="Requests" value={d.counts.pending ?? 0}
                       tone={(d.counts.pending ?? 0) > 0 ? 'warning' : undefined}
                       sub={(d.counts.pending ?? 0) > 0 ? 'awaiting review' : 'none waiting'} />
            <CountCard icon={ShieldAlert} label="Banned" value={d.counts.banned ?? 0}
                       sub="from this community" />
            <CountCard icon={MessageSquare} label="Posts" value={d.posts.total}
                       sub={`${d.posts.last_7d} in the last 7 days`} />
          </div>

          {/* ACTIVITY, INLINE. Two charts answering the two questions a moderator has
              while looking at the counts above: is anyone still posting, and is the
              membership growing or bleeding. Joins and departures share one scale
              deliberately — the gap between the lines IS the answer, and two separately
              normalised charts would hide a month where both ran high. */}
          {pulse && pulse.series.length > 1 && (
            <div className="mb-5 grid gap-3"
                 style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))' }}>
              <AreaChart
                label="Posts"
                totalLabel="in 30 days"
                points={pulse.series.map((r) => ({ day: r.day, value: r.posts }))}
              />
              <MultiLineChart
                label="Joined vs left"
                data={pulse.series.map((r) => ({ day: r.day, joined: r.joined, departed: r.departed }))}
                series={[{ key: 'joined', name: 'Joined' }, { key: 'departed', name: 'Left' }]}
              />
            </div>
          )}

          <Card className="mb-5">
            <div className="border-b border-border px-4 py-3">
              <h2 className="text-sm font-semibold">About</h2>
            </div>
            <div className="grid gap-x-8 gap-y-0 p-4 sm:grid-cols-2">
              <Field label="Owner" value={name(d.community.owner_name, d.community.owner_username)} />
              <Field label="Created" value={when(d.community.created_at)} />
              <Field label="Joining" value={d.community.join_policy} />
              <Field label="Discoverable" value={d.community.discoverable ? 'Yes' : 'No'} />
              <Field label="Members can invite" value={d.community.members_can_invite ? 'Yes' : 'No'} />
            </div>
            {/* The description spans rather than sitting in a column: it is prose of
                unknown length, and a paragraph wrapped into half the width beside a
                one-word value reads as a layout accident. */}
            {d.community.description && (
              <div className="border-t border-border px-4 py-3">
                <div className="mb-1 text-tiny text-[var(--text-mute)]">Description</div>
                <p className="m-0 text-sm leading-relaxed">{d.community.description}</p>
              </div>
            )}
          </Card>

          {me.role === 'admin' && <><PaymentsDemo /><FinancePanel id={id} /></>}
          {d.community.official_key && me.role === 'admin' && <OfficialControls id={id} community={d.community} members={d.members} reload={async () => { await load(); await loadPosts(); }} />}
          {/* Same gate as OfficialControls: the backend restricts these routes to the three
              official_key communities anyway, so the UI simply does not offer them elsewhere. */}
          {d.community.official_key && me.role === 'admin' && <ModeratorPanel id={id} members={d.members} reload={async () => { await load(); await loadPosts(); }} />}
          <Card className="mb-5">
            <div className="border-b border-border px-4 py-3">
              <h2 className="text-sm font-semibold">Paid capabilities</h2>
              <p className="m-0 mt-0.5 text-tiny text-[var(--text-mute)]">
                Running a community is free. These are switched on per community, on request.
              </p>
            </div>

            {entsError && (
              <div role="alert" className="mx-4 mt-3 rounded-md border px-3 py-2 text-sm"
                   style={{ borderColor: 'rgba(248,113,113,0.28)', background: 'rgba(248,113,113,0.09)', color: 'var(--danger)' }}>
                {entsError}
              </div>
            )}

            <div className="divide-y" style={{ borderColor: 'var(--border)' }}>
              {available.map((cap) => {
                const live = ents.find((e) => e.capability === cap && e.live);
                return (
                  <div key={cap} className="flex items-center gap-3 px-4 py-2.5">
                    <span className="text-sm font-medium">{cap.replace(/_/g, ' ')}</span>
                    {live ? <Badge variant="ok">On</Badge> : <Badge variant="secondary">Off</Badge>}
                    <span className="flex-1" />
                    {me.role === 'admin' && (
                      live
                        ? <Button variant="ghost" size="sm" disabled={busy}
                                  onClick={() => void revoke(cap)}>Switch off</Button>
                        : <Button variant="outline" size="sm" disabled={busy}
                                  onClick={() => void grant(cap)}>Switch on</Button>
                    )}
                  </div>
                );
              })}
            </div>

            {/* History, not just the current state. "Did they ever have this" is a real
                question in a dispute, and revoked rows are kept precisely to answer it. */}
            {ents.length > 0 && (
              <div className="border-t border-border px-4 py-3">
                <div className="mb-1.5 text-micro font-semibold uppercase tracking-wider text-[var(--text-mute)]">
                  History
                </div>
                {ents.map((e) => (
                  <div key={e.id} className="flex items-center gap-2 py-1 text-tiny text-[var(--text-mute)]">
                    <span className={e.live ? 'text-[var(--ok)]' : 'text-[var(--text-mute)]'}>
                      {e.live ? '+' : '−'}
                    </span>
                    <span className="text-[var(--text-dim)]">{e.capability.replace(/_/g, ' ')}</span>
                    <span>{when(e.granted_at)}</span>
                    {e.granted_by_email && <span className="truncate">· {e.granted_by_email}</span>}
                  </div>
                ))}
              </div>
            )}
          </Card>

          <Card className="mb-5">
            <div className="flex items-baseline gap-3 border-b border-border px-4 py-3">
              <h2 className="text-sm font-semibold">Recent posts</h2>
              <span className="text-tiny text-[var(--text-mute)]">Newest first</span>
            </div>
            {postsError ? (
              <div role="alert" className="m-4 rounded-md border px-3 py-2 text-sm"
                   style={{ borderColor: 'rgba(248,113,113,0.28)', background: 'rgba(248,113,113,0.09)', color: 'var(--danger)' }}>
                {postsError}
              </div>
            ) : posts.length === 0 ? (
              <div className="px-4 py-8 text-center text-sm text-[var(--text-mute)]">Nothing posted yet.</div>
            ) : (
              <div className="divide-y" style={{ borderColor: 'var(--border)' }}>
                {posts.map((p) => (
                  <article key={p.id} className="px-4 py-3">
                    <div className="mb-1.5 flex items-center gap-2">
                      <span className="text-sm font-semibold">{name(p.author_name, p.author_username)}</span>
                      <span className="text-tiny text-[var(--text-mute)]">{when(p.created_at)}</span>
                      {p.edited_at && <Badge variant="secondary">edited</Badge>}
                      {p.media_url && <Badge>media</Badge>}
                      <span className="flex-1" />
                      {/* Engagement sits at the end of the meta row, quiet: it is context
                          for a moderation decision, never the point of the row. */}
                      <span className="mono text-tiny text-[var(--text-mute)]">
                        {p.like_count} likes · {p.comment_count} replies
                      </span>
                    </div>
                    {p.body && (
                      <p className="m-0 whitespace-pre-wrap text-sm leading-relaxed text-[var(--text-dim)]">
                        {p.body}
                      </p>
                    )}
                  </article>
                ))}
              </div>
            )}
          </Card>

          <Card className="mb-5">
            <div className="flex items-baseline gap-3 border-b border-border px-4 py-3">
              <h2 className="text-sm font-semibold">Roster</h2>
              <span className="text-tiny text-[var(--text-mute)]">
                {d.members.length.toLocaleString()} shown
                {d.members_truncated && ' · capped at 200, the roster is larger'}
              </span>
            </div>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Member</TableHead>
                  <TableHead>Role</TableHead>
                  <TableHead>State</TableHead>
                  <TableHead className="text-right">Joined</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {d.members.map((m) => (
                  <TableRow key={m.user_id}>
                    <TableCell className="font-medium">{name(m.full_name, m.username)}</TableCell>
                    <TableCell>
                      {m.role === 'owner' ? <Badge>Owner</Badge>
                        : m.role === 'admin' ? <Badge>Admin</Badge>
                        : <span className="text-tiny text-[var(--text-mute)]">Member</span>}
                    </TableCell>
                    <TableCell>
                      {m.state === 'banned' ? <Badge variant="destructive">Banned</Badge>
                        : m.state === 'pending' ? <Badge variant="warning">Pending</Badge>
                        : <Badge variant="ok">Active</Badge>}
                    </TableCell>
                    <TableCell className="text-right text-tiny text-[var(--text-mute)]">
                      {when(m.joined_at)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </Card>

          <p className="mute" style={{ fontSize: 13, marginTop: 18, maxWidth: 640 }}>
            Community chat is end-to-end encrypted and cannot be read from here. Post counts
            come from the community feed, which is not encrypted.
          </p>
        </>
      )}
    </Async>
  );
}

/**
 * One count, with the thing it counts named beside it.
 *
 * The icon is not decoration: at a glance across six cards the glyph is what distinguishes
 * them, because four of the six labels are single words of similar length and the eye
 * cannot tell them apart at 12px without reading each one.
 */
function CountCard({ icon: Icon, label, value, sub, tone }: {
  icon: typeof Users2; label: string; value: number; sub?: string;
  tone?: 'warning';
}) {
  return (
    <Card className="p-3.5">
      <div className="flex items-center gap-1.5">
        <Icon size={13} strokeWidth={2}
              className={tone === 'warning' ? 'text-[var(--warning)]' : 'text-[var(--text-mute)]'} />
        <span className="text-tiny text-[var(--text-mute)]">{label}</span>
      </div>
      <div className="mono mt-1.5 text-[22px] font-semibold leading-none tracking-[-0.025em]"
           style={tone === 'warning' && value > 0 ? { color: 'var(--warning)' } : undefined}>
        {value.toLocaleString()}
      </div>
      {sub && <div className="mt-1.5 text-micro text-[var(--text-mute)]">{sub}</div>}
    </Card>
  );
}

/**
 * A labelled value, on one row.
 *
 * The label column is fixed so values line up DOWN the column — in a two-column grid a
 * label-width that flexes per row makes the values stagger, and the eye stops being able
 * to scan them as a list.
 */
function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline gap-4 border-b border-border py-2 text-sm last:border-0">
      <span className="w-[128px] shrink-0 text-tiny text-[var(--text-mute)]">{label}</span>
      <span className="min-w-0 truncate" title={value}>{value}</span>
    </div>
  );
}
