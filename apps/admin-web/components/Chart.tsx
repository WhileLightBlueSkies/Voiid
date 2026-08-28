'use client';

//
// Charts, hand-drawn as inline SVG.
//
// No charting library: this console renders five small series and a library would be the
// single largest thing it ships, for axes and tooltips that are forty lines here. It also
// keeps the palette on our own tokens rather than a vendor's defaults.
//
// Everything is drawn from a viewBox with preserveAspectRatio="none" so the plot stretches
// to whatever width the grid gives it, while stroke widths stay honest via
// vector-effect="non-scaling-stroke" — a stretched viewBox would otherwise render a 2px
// line as a wedge that is thick on one axis and thin on the other.
//

import { useId, useState } from 'react';

export type Point = { day: string; value: number };

const W = 600;
const H = 160;
const PAD = 4;

export function AreaChart({ points, color = 'var(--accent)', label }: {
  points: Point[]; color?: string; label: string;
}) {
  const gradId = useId();
  const [hover, setHover] = useState<number | null>(null);

  if (points.length === 0) return <div className="empty">No data.</div>;

  const max = Math.max(...points.map((p) => p.value));
  // A flat-zero series still needs a floor, or every y divides by zero and the path
  // collapses to NaN. It draws along the bottom, which is the truth.
  const top = max === 0 ? 1 : max;
  const step = points.length > 1 ? (W - PAD * 2) / (points.length - 1) : 0;

  const xy = (p: Point, i: number) => {
    const x = PAD + i * step;
    const y = H - PAD - (p.value / top) * (H - PAD * 2);
    return [x, y] as const;
  };

  const line = points.map((p, i) => {
    const [x, y] = xy(p, i);
    return `${i === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(' ');

  const area = `${line} L${(PAD + (points.length - 1) * step).toFixed(1)},${H - PAD} L${PAD},${H - PAD} Z`;
  const total = points.reduce((n, p) => n + p.value, 0);
  const active = hover != null ? points[hover] : null;

  return (
    <div>
      <div className="row" style={{ marginBottom: 10, alignItems: 'baseline' }}>
        <span style={{ fontSize: 13, fontWeight: 600 }}>{label}</span>
        <span className="mute" style={{ fontSize: 12 }}>
          {/* The hovered day replaces the total in place, rather than appearing in a
              floating tooltip that would cover the very point being inspected. */}
          {active ? `${active.day} · ${active.value}` : `${total} total`}
        </span>
        <span style={{ flex: 1 }} />
        <span className="mono" style={{ fontSize: 12, color: 'var(--text-mute)' }}>peak {max}</span>
      </div>

      <div
        style={{ position: 'relative' }}
        onMouseLeave={() => setHover(null)}
        onMouseMove={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          const i = Math.round(((e.clientX - r.left) / r.width) * (points.length - 1));
          setHover(Math.max(0, Math.min(points.length - 1, i)));
        }}
      >
        <svg
          viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none"
          style={{ width: '100%', height: 130, display: 'block' }}
          role="img" aria-label={`${label}: ${total} over ${points.length} days`}
        >
          <defs>
            <linearGradient id={gradId} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={color} stopOpacity="0.28" />
              <stop offset="100%" stopColor={color} stopOpacity="0" />
            </linearGradient>
          </defs>

          {[0.25, 0.5, 0.75].map((f) => (
            <line
              key={f} x1={PAD} x2={W - PAD} y1={H * f} y2={H * f}
              stroke="var(--border)" strokeWidth="1" vectorEffect="non-scaling-stroke"
            />
          ))}

          <path d={area} fill={`url(#${gradId})`} />
          <path
            d={line} fill="none" stroke={color} strokeWidth="2"
            strokeLinejoin="round" strokeLinecap="round" vectorEffect="non-scaling-stroke"
          />

          {hover != null && (() => {
            const [x, y] = xy(points[hover], hover);
            return (
              <g>
                <line x1={x} x2={x} y1={PAD} y2={H - PAD} stroke="var(--border-strong)"
                      strokeWidth="1" vectorEffect="non-scaling-stroke" />
                {/* Drawn as an ellipse, not a circle: the viewBox is stretched horizontally,
                    so an r=3 circle would render as a squashed oval. */}
                <ellipse cx={x} cy={y} rx={3} ry={3} fill={color}
                         vectorEffect="non-scaling-stroke" />
              </g>
            );
          })()}
        </svg>
      </div>

      <div className="row" style={{ justifyContent: 'space-between', marginTop: 6 }}>
        <span className="mute" style={{ fontSize: 11 }}>{points[0]?.day}</span>
        <span className="mute" style={{ fontSize: 11 }}>{points[points.length - 1]?.day}</span>
      </div>
    </div>
  );
}

/** A compact bar row for distributions — where a line would imply continuity it lacks. */
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
        <div style={{ height: 6, background: 'var(--surface-2)', borderRadius: 999, overflow: 'hidden' }}>
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
