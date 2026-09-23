'use client';

import { useEffect, useMemo, useState, type ReactNode } from 'react';
import Link from 'next/link';
import {
  ArrowUpRight, Users, Users2, Film, Zap, Sparkles, UserPlus, Layers,
  FileWarning, FileText, Ban, PhoneCall, Trash2, Globe2, MessageCircle,
  Gamepad2, CalendarDays, CheckCircle2,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';
import {
  Bar, ComposedChart, Cell, Line, ReferenceLine, ResponsiveContainer, Tooltip, XAxis,
} from 'recharts';
import Shell, { type Me } from '../components/Shell';
import { DateRange, rangeQuery, rangeLabel, type Range } from '../components/DateRange';
import { CountryShares, type CountryShare } from '../components/CountryShares';
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

/** Routes a moderator cannot open. Links to them are hidden rather than left to 403. */
const ADMIN_ONLY = ['/analytics', '/games', '/push', '/users', '/dpdp', '/govt'];

export default function Overview() {
  return <Shell>{(me) => <Body me={me} />}</Shell>;
}

function Body({ me }: { me: Me }) {
  const [s, setS] = useState<Stats | null>(null);
  const [series, setSeries] = useState<Series[]>([]);
  const [range, setRange] = useState<Range>({ kind: 'days', days: 30 });
  /// The range the SERVER actually used. A request for five years comes back clamped to a
  /// year, and a header echoing what was asked for would then disagree with the chart.
  const [actual, setActual] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [seriesError, setSeriesError] = useState<string | null>(null);
  const [geo, setGeo] = useState<CountryShare[]>([]);
  const [geoError, setGeoError] = useState<string | null>(null);

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

  useEffect(() => {
    // Not date-filtered: a standing distribution of every live account.
    api<{ countries: CountryShare[] }>('/geo')
      .then((r) => { setGeo(r.countries); setGeoError(null); })
      .catch((e) => setGeoError(e instanceof Error ? e.message : 'could not load the map'));
  }, []);

  const can = (href: string) => me.role === 'admin' || !ADMIN_ONLY.some((p) => href.startsWith(p));
  const period = actual ?? rangeLabel(range);

  const days = useMemo(() => series.map((r) => ({
    day: r.day,
    users: Number(r.users) || 0,
    clips: Number(r.clips) || 0,
    posts: Number(r.posts) || 0,
    conversations: Number(r.conversations) || 0,
    communities: Number(r.communities) || 0,
  })), [series]);

  const sum = (k: keyof (typeof days)[number]) => days.reduce((n, d) => n + (d[k] as number), 0);

  if (error) return <div className="notice error">{error}</div>;

  const n = (v?: number) => v ?? 0;

  return (
    <div className="grid gap-5">
      {/* ── Masthead: the title, the insight stack, the range ─────────────────────── */}
      <section className="grid items-end gap-6 xl:grid-cols-[minmax(0,1fr)_minmax(0,520px)]">
        <div className="pb-1">
          <p className="m-0 mb-2 text-sm font-medium text-[var(--text-dim)]">
            Data based on every account · <span className="num">{period}</span>
          </p>
          <h1 className="text-[44px] font-semibold leading-[0.98] tracking-[-0.045em] sm:text-[64px]">
            Overview Panel
          </h1>
        </div>
        <div className="grid gap-4">
          <InsightStack
            loading={!s || (!series.length && !seriesError)}
            insights={buildInsights(s, days.length ? {
              users: sum('users'), clips: sum('clips'), posts: sum('posts'),
              conversations: sum('conversations'),
            } : null, range, can)}
          />
          <div className="flex justify-end">
            <DateRange value={range} onChange={setRange} />
          </div>
        </div>
      </section>

      {!s ? (
        <SkeletonGrid />
      ) : (
        <>
          <section className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_360px] 2xl:grid-cols-[minmax(0,1fr)_400px]">
            <div className="grid content-start gap-4 md:grid-cols-6">
              {/* ── KPI row ───────────────────────────────────────────────────────── */}
              <Card className="md:col-span-3 lg:col-span-2" icon={Users} title="Accounts" href={can('/users') ? '/users' : undefined}>
                <Big value={compact(n(s.users))} />
                <Pair
                  l={[compact(sum('users')), `Joined · ${shortRange(range)}`]}
                  r={[`+${compact(n(s.users_24h))}`, 'Last 24h']}
                />
                <Meter
                  total={n(s.users)}
                  segments={[
                    { value: n(s.users_24h), color: 'var(--tide-light)', label: 'Joined in the last 24h' },
                    { value: Math.max(sum('users') - n(s.users_24h), 0), color: 'var(--accent)', label: `Joined earlier in ${shortRange(range)}` },
                  ]}
                />
              </Card>

              <Card className="md:col-span-3 lg:col-span-2" icon={Users2} title="Community health" href="/communities">
                <Pair
                  l={[compact(n(s.communities)), 'Active']}
                  r={[compact(n(s.communities_suspended)), 'Suspended']}
                  top
                />
                <Gauge
                  pct={pct(n(s.communities), n(s.communities) + n(s.communities_suspended))}
                  caption="in good standing"
                />
              </Card>

              <Card className="md:col-span-6 lg:col-span-2" icon={Film} title="Clips live" href="/clips">
                <Big
                  value={fmtPct(pct(n(s.clips) - n(s.clips_removed), n(s.clips)))}
                  unit="%"
                />
                <Pair
                  l={[compact(n(s.clips)), 'Posted']}
                  r={[compact(n(s.clips_removed)), 'Removed']}
                />
                <Meter
                  total={n(s.clips)}
                  segments={[
                    { value: n(s.clips_removed), color: 'var(--accent)', label: 'Removed' },
                    { value: n(s.clips_24h), color: 'var(--tide-light)', label: 'Posted in the last 24h' },
                  ]}
                />
              </Card>

              {/* ── Trend row ─────────────────────────────────────────────────────── */}
              {seriesError ? (
                <div className="notice error md:col-span-6">{seriesError}</div>
              ) : (
                <>
                  <TrendCard
                    className="md:col-span-6 lg:col-span-3"
                    icon={UserPlus}
                    title="Signups"
                    href={can('/analytics') ? '/analytics' : undefined}
                    data={days.map((d) => ({ day: d.day, value: d.users }))}
                    corners={{
                      tl: [compact(lastN(days, 7, 'users')), 'Last 7 days'],
                      bl: [compact(peak(days, 'users')), 'Peak day'],
                      tr: [perDay(sum('users'), days.length), 'Per day'],
                      br: [compact(n(s.devices)), 'Devices'],
                    }}
                    big={compact(sum('users'))}
                  />
                  <TrendCard
                    className="md:col-span-6 lg:col-span-3"
                    icon={Layers}
                    title="Content posted"
                    href={can('/analytics') ? '/analytics' : '/clips'}
                    data={days.map((d) => ({ day: d.day, value: d.clips + d.posts }))}
                    corners={{
                      tl: [compact(sum('clips')), 'Clips'],
                      bl: [compact(sum('posts')), 'Posts'],
                      tr: [compact(n(s.comments)), 'Comments'],
                      br: [compact(n(s.stories)), 'Stories'],
                    }}
                    big={compact(sum('clips') + sum('posts'))}
                  />
                </>
              )}
            </div>

            {/* ── Right rail: what needs a human ──────────────────────────────────── */}
            <Attention s={s} can={can} />
          </section>

          {/* ── Modules ────────────────────────────────────────────────────────────── */}
          <section className="grid items-start gap-4 sm:grid-cols-2 xl:grid-cols-3">
              <Card icon={Globe2} title="Top countries" className="sm:row-span-2 xl:row-span-1">
              {geoError ? (
                <div className="notice error">{geoError}</div>
              ) : geo.length === 0 ? (
                <div className="py-6 text-center text-sm text-[var(--text-mute)]">No accounts with a phone number yet.</div>
              ) : (
                <>
                  <div className="mt-1"><CountryShares countries={geo} limit={5} /></div>
                  {/* "Top countries" reads as where people ARE; dialling-prefix data
                      cannot support that, so the caveat lives on the card. */}
                  <p className="m-0 mt-3 text-micro leading-relaxed text-[var(--text-mute)]">
                    By phone dialling prefix — where each SIM was issued, not where anyone is.
                    Voiid stores no user location.
                  </p>
                </>
              )}
            </Card>
            <Module icon={Film} title="Social" href="/clips" rows={[
              ['Creators', n(s.creators)], ['Highlights', n(s.highlights)], ['Comments', n(s.comments)],
            ]} />
            <Module icon={Users2} title="Communities" href="/communities" rows={[
              ['New in 24h', n(s.communities_24h)], ['Tournaments', n(s.tournaments)], ['Suspended', n(s.communities_suspended)],
            ]} />
            <Module icon={CalendarDays} title="Events" href="/events" rows={[
              ['Events', n(s.events)], ['Tickets', n(s.event_tickets)], ['Orders', n(s.event_orders)],
            ]} />
            <Module icon={Gamepad2} title="Games" href={can('/games') ? '/games' : undefined} rows={[
              ['Lobbies', n(s.game_lobbies)], ['New in 24h', n(s.game_lobbies_24h)], ['Tournaments', n(s.tournaments)],
            ]} />
            <Module icon={MessageCircle} title="Messaging" href={can('/analytics') ? '/analytics' : undefined} rows={[
              ['Conversations', n(s.conversations)], ['Calls', n(s.calls)], ['Blocks', n(s.blocks)],
            ]} note="Containers only — content is end-to-end encrypted." />
          </section>
        </>
      )}
    </div>
  );
}

// ── Insight stack ──────────────────────────────────────────────────────────────────────

type Insight = { lead: string; body: ReactNode; href?: string };

function buildInsights(
  s: Stats | null,
  t: { users: number; clips: number; posts: number; conversations: number } | null,
  range: Range,
  can: (href: string) => boolean,
): Insight[] {
  if (!s) return [];
  const span = range.kind === 'days' ? `In the last ${range.days} days` : 'In this range';
  const out: Insight[] = [];
  // An overdue legal request outranks every growth number, so it leads when it exists.
  if ((s.dpdp_overdue ?? 0) > 0) {
    const k = s.dpdp_overdue!;
    out.push({
      lead: 'Needs action',
      body: <><b>{k} data request{k > 1 ? 's are' : ' is'}</b> past the statutory deadline.</>,
      href: can('/dpdp') ? '/dpdp' : undefined,
    });
  }
  if (t) {
    out.push({
      lead: 'Growth',
      body: <>{span}, <b>{t.users.toLocaleString()} {t.users === 1 ? 'person' : 'people'}</b> joined Voiid.</>,
      href: can('/users') ? '/users' : undefined,
    });
    out.push({
      lead: 'Content',
      body: <>{span}, creators shared <b>{(t.clips + t.posts).toLocaleString()} clips and posts</b>.</>,
      href: '/clips',
    });
    out.push({
      lead: 'Conversations',
      body: <><b>{t.conversations.toLocaleString()} new conversations</b> started — every one end-to-end encrypted.</>,
      href: can('/analytics') ? '/analytics' : undefined,
    });
  }
  return out;
}

function InsightStack({ insights, loading }: { insights: Insight[]; loading: boolean }) {
  const [i, setI] = useState(0);
  const [paused, setPaused] = useState(false);
  const count = insights.length;

  useEffect(() => { if (i >= count) setI(0); }, [count, i]);

  useEffect(() => {
    // Rotates only for people who have not asked for less motion, and never under a cursor.
    if (count < 2 || paused) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const t = setInterval(() => setI((x) => (x + 1) % count), 7000);
    return () => clearInterval(t);
  }, [count, paused]);

  const cur = insights[i];

  return (
    <div
      className="flex items-center gap-5"
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
    >
      {/* Position dots: which card of how many, and a way to pick one. */}
      <div className="hidden flex-col gap-1.5 sm:flex" role="tablist" aria-label="Insights">
        {insights.map((_, k) => (
          <button
            key={k}
            role="tab"
            aria-selected={k === i}
            aria-label={`Insight ${k + 1} of ${count}`}
            onClick={() => setI(k)}
            className={[
              'h-1.5 rounded-full p-0 transition-all duration-300',
              k === i ? 'w-6 bg-[var(--text-dim)] hover:bg-[var(--text-dim)]' : 'w-3 bg-[var(--border-strong)] hover:bg-[var(--text-mute)]',
            ].join(' ')}
          />
        ))}
      </div>

      <div className="relative min-w-0 flex-1">
        {/* The two sheets behind the card are depth, not content: they say "there are more". */}
        <div aria-hidden className="absolute inset-y-6 right-0 w-1/2 rounded-[26px] opacity-45"
             style={{ background: 'linear-gradient(135deg, #e3f3f4, #a9d6d9)' }} />
        <div aria-hidden className="absolute inset-y-3 right-4 w-2/3 rounded-[26px] opacity-70 sm:right-6"
             style={{ background: 'linear-gradient(135deg, #d9eff0, #8cc7cb)' }} />

        <div
          className="relative mr-8 overflow-hidden rounded-[26px] p-6 pr-8 shadow-[0_24px_48px_-24px_rgba(19,130,140,0.5)] sm:mr-12"
          style={{ background: 'linear-gradient(140deg, #d9eff0 0%, #9fd3d7 52%, #68b8bd 100%)' }}
        >
          {/* A soft light source top-left so the card reads as glass rather than a flat fill. */}
          <div aria-hidden className="pointer-events-none absolute inset-0"
               style={{ background: 'radial-gradient(420px circle at 12% 0%, rgba(255,255,255,0.65), transparent 55%)' }} />
          <div className="relative">
            <div className="mb-5 flex items-center gap-2 text-sm font-semibold text-[#101617]">
              <Zap size={15} fill="#101617" />
              {cur?.lead ?? 'Platform insight'}
              {cur?.href && (
                <Link href={cur.href} aria-label="Open" className="ml-auto grid h-8 w-8 place-items-center rounded-full text-[#101617] transition-colors hover:bg-white/40">
                  <ArrowUpRight size={17} />
                </Link>
              )}
            </div>
            <p key={i} className="m-0 min-h-[84px] text-[21px] leading-[1.35] tracking-[-0.02em] text-[#101617] animate-in fade-in-0 slide-in-from-bottom-1 duration-500 [&_b]:font-semibold sm:text-[24px]">
              {loading && !cur ? <span className="opacity-50">Reading the numbers…</span> : cur?.body ?? 'Nothing to report yet.'}
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Cards and their parts ──────────────────────────────────────────────────────────────

function Card({ icon: Icon, title, href, className = '', children }: {
  icon: LucideIcon; title: string; href?: string; className?: string; children: ReactNode;
}) {
  return (
    <div className={`flex flex-col rounded-[22px] bg-card p-5 shadow-[var(--shadow-1)] ring-1 ring-black/[0.04] ${className}`}>
      <div className="mb-3 flex items-center gap-2.5">
        <Icon size={17} strokeWidth={2.1} className="text-[var(--text)]" />
        <h2 className="text-[15px] font-medium text-[var(--text-dim)]">{title}</h2>
        {href && <CornerLink href={href} label={title} />}
      </div>
      {children}
    </div>
  );
}

function CornerLink({ href, label }: { href: string; label: string }) {
  return (
    <Link
      href={href}
      aria-label={`Open ${label}`}
      className="ml-auto grid h-8 w-8 place-items-center rounded-full text-[var(--text)] transition-colors hover:bg-[var(--surface-2)]"
    >
      <ArrowUpRight size={17} />
    </Link>
  );
}

function Big({ value, unit }: { value: string; unit?: string }) {
  return (
    <div className="num my-3 text-center text-[50px] font-normal leading-none !tracking-[-0.035em]">
      {value}
      {unit && <sup className="ml-0.5 align-super text-[15px] font-medium tracking-normal">{unit}</sup>}
    </div>
  );
}

function Pair({ l, r, top }: { l: [string, string]; r: [string, string]; top?: boolean }) {
  return (
    <div className={`flex justify-between gap-3 ${top ? 'mb-1' : 'mb-3 mt-auto'}`}>
      <Figure v={l[0]} k={l[1]} />
      <Figure v={r[0]} k={r[1]} right />
    </div>
  );
}

function Figure({ v, k, right }: { v: string; k: string; right?: boolean }) {
  return (
    <div className={right ? 'text-right' : ''}>
      <div className="num text-[18px] font-medium leading-tight">{v}</div>
      <div className="text-tiny text-[var(--text-mute)]">{k}</div>
    </div>
  );
}

/**
 * A proportional meter: filled segments over a whole, the unfilled remainder drawn as
 * hairline ticks. Every width is a real share of `total`; a non-zero share is floored at a
 * visible sliver, because an invisible sliver reads as "none", which is a different fact.
 */
function Meter({ total, segments }: {
  total: number; segments: { value: number; color: string; label: string }[];
}) {
  const shown = segments.filter((s) => s.value > 0);
  return (
    <div
      className="flex h-9 items-stretch gap-1 rounded-[10px]"
      role="img"
      aria-label={segments.map((s) => `${s.label}: ${s.value.toLocaleString()}`).join(', ') + ` of ${total.toLocaleString()}`}
    >
      {shown.map((s) => (
        <div
          key={s.label}
          title={`${s.label}: ${s.value.toLocaleString()}`}
          className="rounded-[8px] transition-[width] duration-500"
          style={{ width: `${total > 0 ? (s.value / total) * 100 : 0}%`, minWidth: 10, background: s.color }}
        />
      ))}
      <div className="relative flex-1 rounded-[8px] bg-[var(--surface-2)]">
        <div className="ticks absolute inset-y-1.5 left-2 right-0" />
        {shown.length > 0 && <div className="absolute inset-y-0 left-0 w-[2px] rounded-full bg-[var(--tide)]" />}
      </div>
    </div>
  );
}

/** A half-dial: grey track, black progress, a mint knob at the reading. */
function Gauge({ pct: p, caption }: { pct: number; caption: string }) {
  const f = Math.max(0, Math.min(1, p / 100));
  const a = Math.PI * (1 - f);
  const x = 100 + 84 * Math.cos(a);
  const y = 100 - 84 * Math.sin(a);
  return (
    <div className="relative mx-auto mt-auto w-full max-w-[260px]">
      <svg viewBox="0 0 200 108" className="w-full" role="img" aria-label={`${fmtPct(p)}% ${caption}`}>
        <path d="M16 100 A84 84 0 0 1 184 100" fill="none" stroke="var(--surface-3)" strokeWidth="8" strokeLinecap="round" />
        <path d="M16 100 A84 84 0 0 1 184 100" fill="none" stroke="var(--accent)" strokeWidth="8" strokeLinecap="round"
              pathLength={100} strokeDasharray={`${f * 100} 100`} className="transition-[stroke-dasharray] duration-700" />
        <circle cx={x} cy={y} r="7" fill="var(--tide-light)" stroke="#fff" strokeWidth="3" />
      </svg>
      <div className="absolute inset-x-0 bottom-0 text-center">
        <div className="num text-[44px] font-normal leading-none !tracking-[-0.035em]">
          {fmtPct(p)}<sup className="ml-0.5 align-super text-[14px] tracking-normal">%</sup>
        </div>
        <div className="mt-1 text-tiny text-[var(--text-mute)]">{caption}</div>
      </div>
    </div>
  );
}

/**
 * A trend card: four corner figures around a headline total, over a daily bar chart.
 * The last seven days are drawn in ink and everything before them in grey, the line is the
 * seven-day average, and the mint rule marks today — so "how is this week going" reads
 * without a legend.
 */
function TrendCard({ icon, title, href, className, data, corners, big }: {
  icon: LucideIcon; title: string; href?: string; className?: string;
  data: { day: string; value: number }[];
  corners: Record<'tl' | 'bl' | 'tr' | 'br', [string, string]>;
  big: string;
}) {
  const rows = data.map((d, i) => {
    const w = data.slice(Math.max(0, i - 6), i + 1);
    return { ...d, avg: w.reduce((n, x) => n + x.value, 0) / w.length };
  });
  const recentFrom = Math.max(0, rows.length - 7);
  return (
    <Card icon={icon} title={title} href={href} className={`!pb-3 ${className ?? ''}`}>
      <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-2">
        <div className="grid gap-3">
          <Figure v={corners.tl[0]} k={corners.tl[1]} />
          <Figure v={corners.bl[0]} k={corners.bl[1]} />
        </div>
        <div className="text-center">
          <div className="num text-[44px] font-normal leading-none !tracking-[-0.035em]">{big}</div>
          <div className="mt-1 text-tiny text-[var(--text-mute)]">in range</div>
        </div>
        <div className="grid gap-3">
          <Figure v={corners.tr[0]} k={corners.tr[1]} right />
          <Figure v={corners.br[0]} k={corners.br[1]} right />
        </div>
      </div>

      <div className="-mx-2 mt-3 h-[150px]">
        {rows.length === 0 ? (
          <div className="grid h-full place-items-center text-sm text-[var(--text-mute)]">No data in this range.</div>
        ) : (
          <ResponsiveContainer width="100%" height="100%">
            <ComposedChart data={rows} margin={{ top: 8, right: 8, bottom: 0, left: 8 }} barCategoryGap="22%">
              <XAxis
                dataKey="day" tickLine={false} axisLine={false} interval="preserveStartEnd"
                tick={{ fontSize: 11, fill: 'var(--text-mute)' }} minTickGap={80}
                tickFormatter={shortDay}
              />
              <Tooltip
                cursor={{ fill: 'rgba(16,22,23,0.04)' }}
                contentStyle={{ background: '#fff', border: '1px solid var(--border)', borderRadius: 12, fontSize: 12, padding: '8px 10px', boxShadow: 'var(--shadow-2)' }}
                labelStyle={{ color: 'var(--text-dim)', marginBottom: 4, fontSize: 11 }}
                itemStyle={{ color: 'var(--text)', padding: 0 }}
                formatter={(v, k) => [Math.round(Number(v)).toLocaleString(), k === 'avg' ? '7-day average' : title]}
                labelFormatter={(d) => shortDay(String(d))}
              />
              <Bar dataKey="value" radius={[3, 3, 3, 3]} maxBarSize={6} isAnimationActive={false}>
                {rows.map((_, i) => <Cell key={i} fill={i >= recentFrom ? 'var(--accent)' : '#c9d3d4'} />)}
              </Bar>
              <Line dataKey="avg" type="monotone" stroke="var(--accent)" strokeWidth={1.4} dot={false} isAnimationActive={false} />
              <ReferenceLine x={rows[rows.length - 1].day} stroke="var(--tide-light)" strokeWidth={2} />
            </ComposedChart>
          </ResponsiveContainer>
        )}
      </div>
    </Card>
  );
}

// ── Needs attention ────────────────────────────────────────────────────────────────────

function Attention({ s, can }: { s: Stats; can: (href: string) => boolean }) {
  const items: { icon: LucideIcon; label: string; sub: string; value: number; tone: 'danger' | 'attention' | 'ok' | 'quiet'; href?: string }[] = [
    { icon: FileWarning, label: 'Overdue data requests', sub: 'Past the statutory deadline', value: s.dpdp_overdue ?? 0, tone: (s.dpdp_overdue ?? 0) > 0 ? 'danger' : 'quiet', href: '/dpdp' },
    { icon: FileText, label: 'Open data requests', sub: 'Access, correction, erasure', value: s.dpdp_open ?? 0, tone: (s.dpdp_open ?? 0) > 0 ? 'attention' : 'quiet', href: '/dpdp' },
    { icon: Ban, label: 'Suspended communities', sub: 'Awaiting review or appeal', value: s.communities_suspended ?? 0, tone: (s.communities_suspended ?? 0) > 0 ? 'attention' : 'quiet', href: '/communities' },
    { icon: Trash2, label: 'Removed clips', sub: 'Taken down by moderation', value: s.clips_removed ?? 0, tone: 'quiet', href: '/clips' },
    { icon: PhoneCall, label: 'Calls in progress', sub: 'Live right now', value: s.calls_active ?? 0, tone: (s.calls_active ?? 0) > 0 ? 'ok' : 'quiet' },
  ];
  const urgent = (s.dpdp_overdue ?? 0) + (s.communities_suspended ?? 0) + (s.dpdp_open ?? 0);

  return (
    <div className="flex flex-col rounded-[22px] bg-card p-5 shadow-[var(--shadow-1)] ring-1 ring-black/[0.04]">
      <div className="mb-4 flex items-center gap-2.5">
        <Sparkles size={17} strokeWidth={2.1} />
        <h2 className="text-[15px] font-medium text-[var(--text-dim)]">Needs attention</h2>
      </div>

      <div className="mb-4 flex items-center gap-3 rounded-[18px] bg-[var(--surface-2)] p-3.5">
        <span className="grid h-10 w-10 shrink-0 place-items-center rounded-[14px] bg-[var(--tide-light)]">
          {urgent === 0 ? <CheckCircle2 size={19} /> : <span className="num text-[16px] font-semibold">{urgent}</span>}
        </span>
        <div className="leading-snug">
          <div className="text-sm font-semibold">{urgent === 0 ? 'All clear' : `${urgent} item${urgent > 1 ? 's' : ''} waiting`}</div>
          <div className="text-tiny text-[var(--text-mute)]">
            {urgent === 0 ? 'No queue has work waiting on a person.' : 'Oldest and most consequential first.'}
          </div>
        </div>
      </div>

      <ul className="m-0 flex flex-1 list-none flex-col justify-between gap-1 p-0">
        {items.map((it) => {
          const href = it.href && can(it.href) ? it.href : undefined;
          const inner = (
            <>
              <span className="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-[var(--surface-2)]">
                <it.icon size={16} strokeWidth={2} className="text-[var(--text)]" />
              </span>
              <span className="min-w-0 flex-1 leading-tight">
                <span className="block truncate text-sm font-medium text-[var(--text)]">{it.label}</span>
                <span className="block truncate text-micro text-[var(--text-mute)]">{it.sub}</span>
              </span>
              <span className="num tabular flex items-center gap-1.5 text-[16px] font-medium"
                    style={{ color: it.tone === 'danger' ? 'var(--danger)' : it.tone === 'attention' ? 'var(--attention)' : 'var(--text)' }}>
                {it.tone === 'ok' && <span className="h-2 w-2 rounded-full bg-[var(--tide)]" aria-hidden />}
                {it.value.toLocaleString()}
              </span>
            </>
          );
          return (
            <li key={it.label}>
              {href ? (
                <Link href={href} className="flex items-center gap-3 rounded-[16px] px-2 py-2 no-underline transition-colors hover:bg-[var(--surface-2)] hover:no-underline">
                  {inner}
                </Link>
              ) : (
                <div className="flex items-center gap-3 px-2 py-2">{inner}</div>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}

// ── Modules ────────────────────────────────────────────────────────────────────────────

function Module({ icon: Icon, title, href, rows, note }: {
  icon: LucideIcon; title: string; href?: string; rows: [string, number][]; note?: string;
}) {
  return (
    <div className="flex flex-col rounded-[22px] bg-card p-5 shadow-[var(--shadow-1)] ring-1 ring-black/[0.04]">
      <div className="mb-3 flex items-center gap-3">
        <span className="grid h-9 w-9 place-items-center rounded-full bg-[var(--accent)] text-white">
          <Icon size={16} strokeWidth={2.1} />
        </span>
        <div className="text-[15px] font-semibold">{title}</div>
        {href && <CornerLink href={href} label={title} />}
      </div>
      <dl className="m-0 grid gap-1.5">
        {rows.map(([k, v]) => (
          <div key={k} className="flex items-baseline justify-between gap-3">
            <dt className="text-sm text-[var(--text-mute)]">{k}</dt>
            <dd className="num tabular m-0 text-[15px] font-medium">{v.toLocaleString()}</dd>
          </div>
        ))}
      </dl>
      {note && <p className="m-0 mt-3 text-micro text-[var(--text-mute)]">{note}</p>}
    </div>
  );
}

function SkeletonGrid() {
  return (
    <div className="grid gap-4 md:grid-cols-3" aria-busy="true" aria-label="Loading">
      {[0, 1, 2].map((k) => (
        <div key={k} className="h-[220px] animate-pulse rounded-[22px] bg-card/70" />
      ))}
    </div>
  );
}

// ── Formatting ─────────────────────────────────────────────────────────────────────────

function compact(v: number): string {
  if (Math.abs(v) < 10_000) return v.toLocaleString();
  return new Intl.NumberFormat('en', { notation: 'compact', maximumFractionDigits: 1 }).format(v);
}

function pct(part: number, whole: number): number {
  return whole > 0 ? (part / whole) * 100 : 0;
}

/** One decimal under 100, none at exactly 100 — "100.00%" claims a precision nobody needs. */
function fmtPct(p: number): string {
  if (p >= 100) return '100';
  return p.toFixed(p === 0 ? 0 : 1);
}

function perDay(total: number, days: number): string {
  if (!days) return '0';
  const v = total / days;
  return v >= 10 ? Math.round(v).toLocaleString() : v.toFixed(1);
}

function lastN(rows: Record<string, string | number>[], k: number, key: string): number {
  return rows.slice(-k).reduce((n, r) => n + (Number(r[key]) || 0), 0);
}

function peak(rows: Record<string, string | number>[], key: string): number {
  return rows.reduce((m, r) => Math.max(m, Number(r[key]) || 0), 0);
}

function shortRange(r: Range): string {
  return r.kind === 'days' ? `${r.days}d` : 'range';
}

function shortDay(d: string): string {
  const t = new Date(`${d}T00:00:00`);
  return Number.isNaN(t.getTime()) ? d : t.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
