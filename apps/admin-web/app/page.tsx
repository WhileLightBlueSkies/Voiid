'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import Shell from '../components/Shell';
import { PageHeader, Async } from '../components/ui';
import { AreaChart, BarRow, type Point } from '../components/Chart';
import { DateRange, rangeQuery, rangeLabel, type Range } from '../components/DateRange';
import { api } from '../lib/api';

type Stats = {
  users?: number; users_24h?: number;
  clips?: number; clips_removed?: number; clips_24h?: number; comments?: number;
  dpdp_open?: number; dpdp_overdue?: number;
  communities?: number; communities_suspended?: number; communities_24h?: number;
  stories?: number; creators?: number; highlights?: number;
  game_lobbies?: number; game_lobbies_24h?: number; tournaments?: number;
  events?: number; event_tickets?: number; event_orders?: number;
  conversations?: number; calls?: number; calls_active?: number;
  devices?: number; blocks?: number;
};

type Series = { day: string; users: number; clips: number; communities: number; posts: number; conversations: number };

export default function Overview() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [s, setS] = useState<Stats | null>(null);
  const [series, setSeries] = useState<Series[]>([]);
  const [range, setRange] = useState<Range>({ kind: 'days', days: 30 });
  /// The range the SERVER actually used. A request for five years comes back clamped to a
  /// year, and a header echoing what was asked for would then disagree with the chart
  /// beneath it.
  const [actual, setActual] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [seriesError, setSeriesError] = useState<string | null>(null);

  useEffect(() => {
    api<Stats>('/stats').then(setS)
      .catch((e) => setError(e instanceof Error ? e.message : 'could not load the numbers'));
  }, []);

  useEffect(() => {
    // Kept separate from the totals: a failed chart must not blank the numbers above it,
    // which are the half an operator can act on.
    api<{ series: Series[]; from: string | null; to: string | null; days: number }>(
      `/series?${rangeQuery(range)}`,
    )
      .then((r) => {
        setSeries(r.series);
        setActual(r.from && r.to ? `${r.from} → ${r.to}` : null);
        setSeriesError(null);
      })
      .catch((e) => setSeriesError(e instanceof Error ? e.message : 'could not load the history'));
  }, [range]);

  const n = (v?: number) => v ?? 0;
  const pts = (k: keyof Series): Point[] =>
    series.map((r) => ({ day: r.day, value: Number(r[k]) || 0 }));

  return (
    <>
      <PageHeader
        title="Overview"
        subtitle="Everything on Voiid, at a glance."
        right={<DateRange value={range} onChange={setRange} />}
      />

      <Async loading={!s} error={error} empty={false} emptyText="">
        {s && (
          <div style={{ display: 'grid', gap: 26 }}>
            {/* ── The four numbers worth interrupting someone for ─────────────── */}
            <section>
              <div className="section-label">Right now</div>
              <div style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))' }}>
                <Head label="Users" value={n(s.users)} delta={n(s.users_24h)} href="/users" />
                <Head label="Communities" value={n(s.communities)} delta={n(s.communities_24h)} href="/communities" />
                <Head label="Clips" value={n(s.clips)} delta={n(s.clips_24h)} href="/clips" />
                <Head
                  label="Needs attention"
                  value={n(s.dpdp_overdue) + n(s.communities_suspended)}
                  tone={n(s.dpdp_overdue) > 0 ? 'danger' : n(s.communities_suspended) > 0 ? 'attention' : undefined}
                  note={
                    n(s.dpdp_overdue) > 0 ? `${n(s.dpdp_overdue)} overdue data request${n(s.dpdp_overdue) > 1 ? 's' : ''}`
                    : n(s.communities_suspended) > 0 ? `${n(s.communities_suspended)} suspended`
                    : 'Nothing waiting'
                  }
                  href={n(s.dpdp_overdue) > 0 ? '/dpdp' : '/communities'}
                />
              </div>
            </section>

            {/* ── Growth ──────────────────────────────────────────────────────── */}
            <section>
              <div className="section-label">
                Growth · {actual ?? rangeLabel(range)}
              </div>
              {seriesError ? (
                <div className="notice error">{seriesError}</div>
              ) : (
                <div style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))' }}>
                  <Panel title="New users"><AreaChart points={pts('users')} label="Signups" /></Panel>
                  <Panel title="New clips"><AreaChart points={pts('clips')} label="Clips posted" color="var(--info)" /></Panel>
                  <Panel title="Community posts"><AreaChart points={pts('posts')} label="Posts" color="var(--ok)" /></Panel>
                  <Panel title="New conversations"><AreaChart points={pts('conversations')} label="Threads started" color="var(--attention)" /></Panel>
                </div>
              )}
            </section>

            {/* ── Everything else, by module ──────────────────────────────────── */}
            <section>
              <div className="section-label">Modules</div>
              <div style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))' }}>
                <Panel title="Social">
                  <Bars rows={[
                    ['Clips', n(s.clips)], ['Removed clips', n(s.clips_removed)],
                    ['Comments', n(s.comments)], ['Stories', n(s.stories)],
                    ['Creators', n(s.creators)], ['Highlights', n(s.highlights)],
                  ]} />
                </Panel>

                <Panel title="Communities">
                  <Bars rows={[
                    ['Active', n(s.communities)], ['Suspended', n(s.communities_suspended)],
                    ['Events', n(s.events)], ['Tickets', n(s.event_tickets)],
                    ['Orders', n(s.event_orders)], ['Tournaments', n(s.tournaments)],
                  ]} />
                </Panel>

                <Panel title="Games">
                  <Bars rows={[
                    ['Lobbies', n(s.game_lobbies)], ['New in 24h', n(s.game_lobbies_24h)],
                    ['Tournaments', n(s.tournaments)],
                  ]} />
                </Panel>

                <Panel title="Messaging & calls">
                  <Bars rows={[
                    ['Conversations', n(s.conversations)], ['Calls', n(s.calls)],
                    ['In progress', n(s.calls_active)], ['Devices', n(s.devices)],
                    ['Blocks', n(s.blocks)],
                  ]} />
                  <p className="mute" style={{ fontSize: 12, margin: '10px 0 0' }}>
                    Containers only — message and call content is end-to-end encrypted and
                    the server holds no key.
                  </p>
                </Panel>

                <Panel title="Data rights">
                  <Bars rows={[['Open', n(s.dpdp_open)], ['Overdue', n(s.dpdp_overdue)]]} />
                  <div style={{ marginTop: 10 }}>
                    <Link href="/dpdp" style={{ fontSize: 13 }}>Open queue →</Link>
                  </div>
                </Panel>
              </div>
            </section>
          </div>
        )}
      </Async>
    </>
  );
}

function Head({ label, value, delta, note, tone, href }: {
  label: string; value: number; delta?: number; note?: string;
  tone?: 'danger' | 'attention'; href: string;
}) {
  return (
    <Link href={href} className="card" style={{ display: 'block', textDecoration: 'none', color: 'inherit' }}>
      <div className="mute" style={{ fontSize: 12 }}>{label}</div>
      <div
        className="mono"
        style={{
          fontSize: 26, fontWeight: 650, marginTop: 2, letterSpacing: '-0.02em',
          color: tone ? `var(--${tone})` : 'var(--text)',
        }}
      >
        {value}
      </div>
      {/* A delta of zero is stated, not hidden: "nothing joined today" is information, and
          an absent line reads as a rendering gap instead. */}
      <div className="mute" style={{ fontSize: 12, marginTop: 2 }}>
        {note ?? (delta ? `+${delta} in 24h` : 'no change in 24h')}
      </div>
    </Link>
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

function Bars({ rows }: { rows: [string, number][] }) {
  const max = Math.max(...rows.map(([, v]) => v), 1);
  return <>{rows.map(([l, v]) => <BarRow key={l} label={l} value={v} max={max} />)}</>;
}
