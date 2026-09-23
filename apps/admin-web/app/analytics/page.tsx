'use client';

import { Dropdown } from '../../components/ui/dropdown';

//
// Analytics.
//
// WHAT THIS PAGE IS CAREFUL ABOUT, and why the layout follows from it:
//
// Every number here has a caveat — collection started on a date, today is partial, a person
// with two devices counts twice per platform but once overall. The old page carried those
// caveats honestly but buried them: one notice at the top, and a wall of <p className="mute">
// under each chart. Read quickly, the caveats vanish and the numbers look more certain than
// they are, which is the failure mode a metrics page has to design against.
//
// So each caveat now sits ON the thing it qualifies — under the stat, in the chart's own
// footnote — where it cannot be scrolled past independently of the figure it modifies.
//
// The page is also ordered by how a question actually gets asked: how many people are here
// now (the headline row), which way is that going (the charts), where are they (platforms),
// and only then the raw daily table for someone checking a specific date.
//

import { useEffect, useState } from 'react';
import Shell from '../../components/Shell';
import { PageHeader } from '../../components/ui';
import { AreaChart, StackedBarChart } from '../../components/Chart';
import { Card } from '../../components/ui/card';
import { Badge } from '../../components/ui/badge';
import { Button } from '../../components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../components/ui/table';
import { api } from '../../lib/api';

type Data = {
  collected_since: string;
  summary: { dau: number; wau: number; mau: number };
  platforms: { platform: string; devices: number; registered_users: number; dau: number; mau: number }[];
  series: { day: string; dau: number | null; ios: number; android: number; web: number; signups: number }[];
};
type Stats = Record<string, number>;

const PLATFORM: Record<string, string> = { ios: 'iOS', android: 'Android', web: 'Web', unknown: 'Unknown' };

export default function Analytics() {
  return (
    <Shell>
      {(me) =>
        me.role === 'admin' ? <Body /> : (
          <Card className="p-5 text-sm text-[var(--text-dim)]">
            Analytics is available to platform admins.
          </Card>
        )
      }
    </Shell>
  );
}

function Body() {
  const [days, setDays] = useState(30);
  const [revision, setRevision] = useState(0);
  const [data, setData] = useState<Data | null>(null);
  const [stats, setStats] = useState<Stats | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError('');
    Promise.all([api<Data>(`/analytics?days=${days}`), api<Stats>('/stats')])
      .then(([d, s]) => { if (active) { setData(d); setStats(s); } })
      .catch((e) => { if (active) setError(e instanceof Error ? e.message : 'Unable to load analytics'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [days, revision]);

  const num = (n: number) => n.toLocaleString();

  return (
    <>
      <PageHeader
        title="Analytics"
        subtitle="Usage, audience and growth across Voiid."
        right={
          <div className="flex items-center gap-2">
            <Dropdown
              ariaLabel="Chart date range"
              value={days}
              onChange={setDays}
              options={[7, 30, 90].map((n) => ({ value: n, label: `Last ${n} days` }))}
              className="min-w-[150px]"
              menuMinWidth={180}
            />
            <Button variant="outline" disabled={loading} onClick={() => setRevision((v) => v + 1)}>
              {loading ? 'Loading…' : 'Refresh'}
            </Button>
          </div>
        }
      />

      {error && (
        <div role="alert" className="mb-5 rounded-md border px-3 py-2.5 text-sm"
             style={{ borderColor: 'rgba(248,113,113,0.28)', background: 'rgba(248,113,113,0.09)', color: 'var(--danger)' }}>
          {error}{' '}
          <button className="underline" onClick={() => setRevision((v) => v + 1)}>Retry</button>
        </div>
      )}

      {data && stats && (
        <div className="grid gap-6" style={{ opacity: loading ? 0.55 : 1, transition: 'opacity .15s' }}>

          {/* ── The four numbers someone opens this page to read ──────────────── */}
          <section className="grid gap-3" style={{ gridTemplateColumns: 'repeat(auto-fit,minmax(190px,1fr))' }}>
            <Metric label="Daily active" value={num(data.summary.dau)} note="Unique users today · UTC" />
            <Metric label="Weekly active" value={num(data.summary.wau)} note="7 calendar days, including today" />
            <Metric label="Monthly active" value={num(data.summary.mau)} note="30 calendar days, including today" />
            <Metric
              label="DAU / MAU"
              value={data.summary.mau ? `${((100 * data.summary.dau) / data.summary.mau).toFixed(1)}%` : '—'}
              note="Stickiness"
              // The caveat rides WITH the number rather than sitting in a notice above it:
              // a ratio against an incomplete denominator is the one figure here that can
              // mislead badly, and it stays provisional until 30 days have accumulated.
              caveat="Provisional while the first 30 days accumulate"
            />
          </section>

          <div className="rounded-md border border-border px-3.5 py-2.5 text-sm text-[var(--text-dim)]"
               style={{ background: 'var(--surface-2)' }}>
            Activity collection started{' '}
            <span className="mono text-[var(--text)]">{new Date(data.collected_since).toLocaleDateString()}</span>.
            Today is partial, and all day boundaries are UTC.
          </div>

          {/* ── Direction of travel ───────────────────────────────────────────── */}
          <section className="grid gap-3" style={{ gridTemplateColumns: 'repeat(auto-fit,minmax(320px,1fr))' }}>
            <Figure note="Dates before collection are excluded, not reported as zero — a gap is a gap, not a quiet day.">
              <AreaChart
                label="Daily active users"
                totalLabel="user-days"
                points={data.series.filter((r) => r.dau !== null).map((r) => ({ day: r.day, value: r.dau! }))}
              />
            </Figure>
            <Figure note="Account creation dates. Deleted accounts are excluded, so history can move down as well as up.">
              <AreaChart
                label="New accounts"
                points={data.series.map((r) => ({ day: r.day, value: r.signups }))}
              />
            </Figure>
          </section>

          {/* Platform mix over time. A stacked bar rather than three lines: the question is
              what share each platform carries, and a share is read from composition — three
              separate lines make the reader do the addition themselves. */}
          <Figure note="A person with both iOS and Android appears in both bands, but only once in overall DAU.">
            <StackedBarChart
              label="Active users by platform"
              data={data.series.filter((r) => r.dau !== null).map((r) => ({
                day: r.day, ios: r.ios, android: r.android, web: r.web,
              }))}
              series={[
                { key: 'ios', name: 'iOS' },
                { key: 'android', name: 'Android' },
                { key: 'web', name: 'Web' },
              ]}
            />
          </Figure>

          {/* ── Where they are ────────────────────────────────────────────────── */}
          <Card>
            <div className="flex items-baseline gap-3 border-b border-border px-4 py-3">
              <h2 className="text-sm font-semibold">Platforms</h2>
              <span className="text-tiny text-[var(--text-mute)]">Non-revoked registered devices</span>
            </div>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Platform</TableHead>
                  <TableHead className="text-right">Devices</TableHead>
                  <TableHead className="text-right">Users</TableHead>
                  <TableHead className="text-right">DAU</TableHead>
                  <TableHead className="text-right">MAU</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.platforms.map((p) => (
                  <TableRow key={p.platform}>
                    <TableCell className="font-medium">{PLATFORM[p.platform] ?? p.platform}</TableCell>
                    <TableCell className="mono text-right">{num(p.devices)}</TableCell>
                    <TableCell className="mono text-right">{num(p.registered_users)}</TableCell>
                    <TableCell className="mono text-right">{num(p.dau)}</TableCell>
                    <TableCell className="mono text-right">{num(p.mau)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </Card>

          {/* ── Totals ────────────────────────────────────────────────────────── */}
          <section>
            <div className="section-label">Product totals</div>
            <div className="grid gap-3" style={{ gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))' }}>
              {([
                ['Accounts', 'users'], ['Communities', 'communities'], ['Conversations', 'conversations'],
                ['Calls', 'calls'], ['Events', 'events'], ['Ticket orders', 'event_orders'],
                ['Tickets', 'event_tickets'], ['Clips', 'clips'],
              ] as const).map(([label, key]) => (
                <Card key={key} className="p-3.5">
                  <div className="text-tiny text-[var(--text-mute)]">{label}</div>
                  <div className="mono mt-1 text-[19px] font-semibold tracking-[-0.02em]">
                    {stats && typeof stats[key] === 'number' ? num(stats[key]) : '—'}
                  </div>
                </Card>
              ))}
            </div>
          </section>

          {/* ── The raw rows, for checking one specific date ──────────────────── */}
          <Card>
            <div className="flex items-baseline gap-3 border-b border-border px-4 py-3">
              <h2 className="text-sm font-semibold">Daily breakdown</h2>
              <span className="text-tiny text-[var(--text-mute)]">Most recent first · UTC</span>
            </div>
            <div className="max-h-[360px] overflow-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Date</TableHead>
                    <TableHead className="text-right">Active</TableHead>
                    <TableHead className="text-right">iOS</TableHead>
                    <TableHead className="text-right">Android</TableHead>
                    <TableHead className="text-right">Web</TableHead>
                    <TableHead className="text-right">New</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {[...data.series].reverse().map((r) => (
                    <TableRow key={r.day}>
                      <TableCell className="mono">{r.day}</TableCell>
                      {/* "Not collected" is a DIFFERENT fact from zero and must never be
                          rendered as one — a dash reads as "none happened", which would be
                          a claim we cannot make about a day before collection began. */}
                      <TableCell className="mono text-right">
                        {r.dau === null
                          ? <span className="text-tiny text-[var(--text-mute)]">not collected</span>
                          : num(r.dau)}
                      </TableCell>
                      <TableCell className="mono text-right">{r.dau === null ? '—' : num(r.ios)}</TableCell>
                      <TableCell className="mono text-right">{r.dau === null ? '—' : num(r.android)}</TableCell>
                      <TableCell className="mono text-right">{r.dau === null ? '—' : num(r.web)}</TableCell>
                      <TableCell className="mono text-right">{num(r.signups)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          </Card>

          {/* ── What the numbers do and do not mean ───────────────────────────── */}
          <Card className="p-4">
            <h2 className="mb-2 text-sm font-semibold">What these numbers mean</h2>
            <div className="grid gap-3 text-sm leading-relaxed text-[var(--text-dim)]"
                 style={{ gridTemplateColumns: 'repeat(auto-fit,minmax(260px,1fr))' }}>
              <p className="m-0">
                <strong className="text-[var(--text)]">Active</strong> means a signed-in device made an
                authenticated API request. Background requests count; WebSocket-only activity and offline
                use do not. This is not screen time.
              </p>
              <p className="m-0">
                <strong className="text-[var(--text)]">Stored</strong>: account id, UTC day and platform,
                for 90 days. No message content, phone numbers, IP addresses or recordings feed these charts.
              </p>
              <p className="m-0">
                <strong className="text-[var(--text)]">Not available yet</strong>: retention cohorts, app
                versions, crash rates, notification conversion, payment settlement. Each needs
                instrumentation that does not exist.
              </p>
            </div>
          </Card>
        </div>
      )}
    </>
  );
}

/**
 * One headline figure.
 *
 * The caveat is part of the component rather than a sibling paragraph, so a number that
 * needs qualifying cannot be copied into a layout without its qualification.
 */
function Metric({ label, value, note, caveat }: {
  label: string; value: string; note: string; caveat?: string;
}) {
  return (
    <Card className="p-4">
      <div className="text-tiny text-[var(--text-mute)]">{label}</div>
      <div className="mono mt-1.5 text-[26px] font-semibold leading-none tracking-[-0.03em]">{value}</div>
      <div className="mt-2 text-tiny text-[var(--text-mute)]">{note}</div>
      {caveat && (
        <Badge variant="warning" className="mt-2">{caveat}</Badge>
      )}
    </Card>
  );
}

/** A chart with its footnote attached, so the qualification travels with the figure. */
function Figure({ note, children }: { note: string; children: React.ReactNode }) {
  return (
    <div>
      {children}
      <p className="m-0 mt-2 px-1 text-tiny leading-relaxed text-[var(--text-mute)]">{note}</p>
    </div>
  );
}
