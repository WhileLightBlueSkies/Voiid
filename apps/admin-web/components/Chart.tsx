'use client';

//
// The charting entry point. Chart TYPES now live in ui/chart.tsx on Recharts; this file
// re-exports them so the four pages already importing from here upgrade without an edit,
// and keeps BarRow, which is not a chart.
//
// WHY BarRow STAYED HAND-DRAWN. It is an inline meter — a label, a bar, a number, on one
// row of a list. Recharts would wrap each one in a ResponsiveContainer and a layout pass to
// draw a rounded rectangle, which is slower and no clearer. A library earns its place on
// axes, scales and hit-testing; none of those appear here.
//

export {
  AreaChart, BarChart, MultiLineChart, StackedBarChart, DonutChart, Sparkline, SERIES,
} from './ui/chart';
export type { Point } from './ui/chart';

export function BarRow({ label, value, max, tone }: {
  label: string; value: number; max: number; tone?: string;
}) {
  const pct = max > 0 ? (value / max) * 100 : 0;
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1fr 60px', gap: 10, alignItems: 'center', padding: '5px 0' }}>
      <div>
        <div className="row" style={{ justifyContent: 'space-between', marginBottom: 4 }}>
          <span style={{ fontSize: 13 }}>{label}</span>
        </div>
        <div style={{ height: 6, background: 'var(--surface-3)', borderRadius: 999, overflow: 'hidden' }}>
          <div style={{
            width: `${pct}%`, height: '100%',
            background: tone ?? 'var(--accent)', borderRadius: 999,
            // A non-zero value must never render as an invisible sliver — that reads as
            // nothing at all, which is a different fact.
            minWidth: value > 0 ? 3 : 0,
          }} />
        </div>
      </div>
      <span className="mono" style={{ fontSize: 13, textAlign: 'right' }}>{value}</span>
    </div>
  );
}
