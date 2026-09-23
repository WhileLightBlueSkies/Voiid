'use client';

//
// Charts, on Recharts — the library shadcn/ui's own chart block is built on.
//
// WHY A LIBRARY NOW, WHEN THE HAND-ROLLED SVG WAS A DEFENSIBLE CHOICE
// ===================================================================
// The old Chart.tsx argued, correctly, that five small series do not justify a dependency.
// What changed is the ASK: more chart types, and types the hand-rolled version could not
// reach without becoming a charting library of its own — stacked bars need a layout pass,
// grouped series need a scale shared across them, and a tooltip that tracks the nearest
// point rather than the hovered band needs hit-testing. Writing those badly is worse than
// shipping 40kB, and writing them well is writing Recharts.
//
// WHAT IS KEPT FROM THE OLD FILE, DELIBERATELY
//   * The palette stays on OUR tokens. Recharts' defaults are a different product's brand.
//   * A flat-zero series still draws along the floor rather than collapsing to NaN — the
//     truth about a quiet day is a flat line, not an empty panel.
//   * Axes stay quiet: a console chart is read at a glance beside a number, so gridlines
//     recede and the series is the only thing at full contrast.
//
// ACCESSIBILITY: every series carries a distinct SHAPE or position, never hue alone. A
// reader who cannot separate teal from green still reads a stacked bar by order.
//

import type { ReactNode } from 'react';
import {
  Area, AreaChart as RArea, Bar, BarChart as RBar, CartesianGrid, Cell,
  Line, LineChart as RLine, Pie, PieChart as RPie, ResponsiveContainer,
  Tooltip, XAxis, YAxis, Legend,
} from 'recharts';

export type Point = { day: string; value: number };

/**
 * The series palette, in the order a chart should consume it.
 *
 * Ink first and mint second, the console's two marks; the rest are chosen to stay separable
 * on white AND when desaturated — which is both the colour-blind case and what happens when someone
 * prints a board pack in greyscale.
 */
export const SERIES = [
  '#0f1110',
  '#4fc95b',
  '#9aa09a',
  '#2f6ed8',
  '#e2701b',
  '#b35fc4',
] as const;

const AXIS = {
  stroke: 'var(--text-mute)',
  fontSize: 11,
  tickLine: false,
  axisLine: false,
} as const;

/** One tooltip for every chart on the console, so a hover always reads the same way. */
function ChartTooltip() {
  return (
    <Tooltip
      cursor={{ fill: 'rgba(15,17,16,0.04)' }}
      contentStyle={{
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        borderRadius: 12,
        fontSize: 12,
        padding: '8px 10px',
        boxShadow: 'var(--shadow-2)',
      }}
      labelStyle={{ color: 'var(--text-dim)', marginBottom: 4, fontSize: 11 }}
      itemStyle={{ color: 'var(--text)', padding: 0 }}
    />
  );
}

function Frame({ title, right, total, children }: {
  title: string; right?: ReactNode; total?: string; children: ReactNode;
}) {
  return (
    <div className="rounded-lg border border-black/[0.04] bg-card p-5 shadow-[var(--shadow-1)]">
      <div className="mb-3 flex items-baseline gap-3">
        <div className="text-sm font-semibold">{title}</div>
        {total && <div className="mono text-tiny text-[var(--text-mute)]">{total}</div>}
        <div className="ml-auto">{right}</div>
      </div>
      <div className="h-[180px] w-full">
        <ResponsiveContainer width="100%" height="100%">{children as any}</ResponsiveContainer>
      </div>
    </div>
  );
}

function Empty({ title }: { title: string }) {
  return (
    <div className="rounded-lg border border-black/[0.04] bg-card p-5 shadow-[var(--shadow-1)]">
      <div className="mb-3 text-sm font-semibold">{title}</div>
      <div className="flex h-[180px] items-center justify-center text-sm text-[var(--text-mute)]">
        No data.
      </div>
    </div>
  );
}

// ── Area: one series over time ─────────────────────────────────────────────────────────
export function AreaChart({ points, label, color = SERIES[0], totalLabel = 'total' }: {
  points: Point[]; label: string; color?: string; totalLabel?: string;
}) {
  if (!points.length) return <Empty title={label} />;
  const total = points.reduce((n, p) => n + p.value, 0);
  return (
    <Frame title={label} total={`${total.toLocaleString()} ${totalLabel}`}>
      <RArea data={points} margin={{ top: 4, right: 4, bottom: 0, left: -20 }}>
        <defs>
          <linearGradient id={`g-${label}`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={0.28} />
            <stop offset="100%" stopColor={color} stopOpacity={0} />
          </linearGradient>
        </defs>
        <CartesianGrid strokeDasharray="2 4" stroke="var(--border)" vertical={false} />
        <XAxis dataKey="day" {...AXIS} minTickGap={24} />
        <YAxis {...AXIS} width={44} allowDecimals={false} />
        <ChartTooltip />
        <Area type="monotone" dataKey="value" stroke={color} strokeWidth={2}
              fill={`url(#g-${label})`} dot={false} activeDot={{ r: 3 }} />
      </RArea>
    </Frame>
  );
}

// ── Bars: comparison across categories ─────────────────────────────────────────────────
export function BarChart({ points, label, color = SERIES[0], horizontal }: {
  points: Point[]; label: string; color?: string; horizontal?: boolean;
}) {
  if (!points.length) return <Empty title={label} />;
  return (
    <Frame title={label}>
      <RBar data={points} layout={horizontal ? 'vertical' : 'horizontal'}
            margin={{ top: 4, right: 8, bottom: 0, left: horizontal ? 8 : -20 }}>
        <CartesianGrid strokeDasharray="2 4" stroke="var(--border)"
                       vertical={!!horizontal} horizontal={!horizontal} />
        {horizontal
          ? <><XAxis type="number" {...AXIS} /><YAxis type="category" dataKey="day" {...AXIS} width={92} /></>
          : <><XAxis dataKey="day" {...AXIS} minTickGap={16} /><YAxis {...AXIS} width={44} allowDecimals={false} /></>}
        <ChartTooltip />
        <Bar dataKey="value" fill={color} radius={horizontal ? [0, 3, 3, 0] : [3, 3, 0, 0]} maxBarSize={28} />
      </RBar>
    </Frame>
  );
}

// ── Multi-series: several lines sharing one scale ──────────────────────────────────────
export function MultiLineChart({ data, series, label }: {
  data: Record<string, string | number>[];
  series: { key: string; name: string }[];
  label: string;
}) {
  if (!data.length) return <Empty title={label} />;
  return (
    <Frame title={label}>
      <RLine data={data} margin={{ top: 4, right: 4, bottom: 0, left: -20 }}>
        <CartesianGrid strokeDasharray="2 4" stroke="var(--border)" vertical={false} />
        <XAxis dataKey="day" {...AXIS} minTickGap={24} />
        <YAxis {...AXIS} width={44} allowDecimals={false} />
        <ChartTooltip />
        <Legend wrapperStyle={{ fontSize: 11, color: 'var(--text-dim)' }} iconType="plainline" iconSize={14} />
        {series.map((s, i) => (
          <Line key={s.key} type="monotone" dataKey={s.key} name={s.name}
                stroke={SERIES[i % SERIES.length]} strokeWidth={2} dot={false}
                // Each series gets its own dash, so the chart survives greyscale and
                // colour-blindness rather than relying on hue to separate five lines.
                strokeDasharray={i === 0 ? undefined : [undefined, '5 3', '2 3', '8 3', '1 3'][i % 5]} />
        ))}
      </RLine>
    </Frame>
  );
}

// ── Stacked bars: composition over time ────────────────────────────────────────────────
export function StackedBarChart({ data, series, label }: {
  data: Record<string, string | number>[];
  series: { key: string; name: string }[];
  label: string;
}) {
  if (!data.length) return <Empty title={label} />;
  return (
    <Frame title={label}>
      <RBar data={data} margin={{ top: 4, right: 4, bottom: 0, left: -20 }}>
        <CartesianGrid strokeDasharray="2 4" stroke="var(--border)" vertical={false} />
        <XAxis dataKey="day" {...AXIS} minTickGap={24} />
        <YAxis {...AXIS} width={44} allowDecimals={false} />
        <ChartTooltip />
        <Legend wrapperStyle={{ fontSize: 11, color: 'var(--text-dim)' }} iconType="square" iconSize={9} />
        {series.map((s, i) => (
          <Bar key={s.key} dataKey={s.key} name={s.name} stackId="a"
               fill={SERIES[i % SERIES.length]} maxBarSize={32}
               // Only the top segment gets a radius, or every band looks detached.
               radius={i === series.length - 1 ? [3, 3, 0, 0] : undefined} />
        ))}
      </RBar>
    </Frame>
  );
}

// ── Donut: share of a whole, when the whole is meaningful ──────────────────────────────
export function DonutChart({ points, label }: { points: Point[]; label: string }) {
  if (!points.length) return <Empty title={label} />;
  const total = points.reduce((n, p) => n + p.value, 0);
  return (
    <Frame title={label} total={total.toLocaleString()}>
      <RPie margin={{ top: 0, right: 0, bottom: 0, left: 0 }}>
        <ChartTooltip />
        <Legend wrapperStyle={{ fontSize: 11, color: 'var(--text-dim)' }} iconType="square" iconSize={9} />
        <Pie data={points} dataKey="value" nameKey="day" innerRadius="55%" outerRadius="80%"
             paddingAngle={2} stroke="var(--bg)" strokeWidth={2}>
          {points.map((_, i) => <Cell key={i} fill={SERIES[i % SERIES.length]} />)}
        </Pie>
      </RPie>
    </Frame>
  );
}

/**
 * A sparkline: the shape of a series, inline beside its number.
 *
 * No axes, no tooltip, no grid — it answers "which way is this going" at a glance and
 * nothing else. Anything more belongs in a real chart.
 */
export function Sparkline({ points, color = SERIES[0] }: { points: Point[]; color?: string }) {
  if (points.length < 2) return null;
  return (
    <div className="h-8 w-full">
      <ResponsiveContainer width="100%" height="100%">
        <RArea data={points} margin={{ top: 2, right: 0, bottom: 0, left: 0 }}>
          <Area type="monotone" dataKey="value" stroke={color} strokeWidth={1.5}
                fill={color} fillOpacity={0.14} dot={false} isAnimationActive={false} />
        </RArea>
      </ResponsiveContainer>
    </div>
  );
}
