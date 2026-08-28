'use client';

//
// A dotted world map, coloured by share of accounts, with a percentage legend beneath.
//
// The look is Aceternity's world-map (dotted-map underneath). That component itself could
// not be used: it draws animated arcs between point PAIRS with no concept of filling a
// region by value, it wants Tailwind + next-themes + motion where this panel is plain CSS,
// and it emits the grid as a single flat <img> data-URI that cannot be coloured per region.
//
// So the library is used directly and the classification happens at BUILD time
// (scripts/build-dots.mjs): every land dot is point-in-polygon tested against Natural Earth
// geometry, including India's official J&K boundary. The browser receives 3065 tagged
// coordinates — no map library, no topology download, nothing for a CSP to block.
//

import { useState } from 'react';
import { DOTS, DOT_VB_W as W, DOT_VB_H as H } from './dots';

export type GeoRegion = { region: string; users: number; share: number };

// A fixed palette rather than one hue at varying opacity: at a handful of regions the eye
// separates distinct colours far faster than shades, and the legend swatch then matches the
// map exactly. Teal leads because it is the brand.
const PALETTE = [
  'var(--accent)', '#7c6cf0', '#3b82f6', '#2fa36b', '#f6821f', '#c86bd8',
];

export function WorldMap({ regions, height = 320 }: {
  regions: GeoRegion[]; height?: number;
}) {
  const [hover, setHover] = useState<string | null>(null);

  // Colour by RANK, so the largest region always wears the brand colour and the palette
  // does not reshuffle as numbers move.
  const colorOf = new Map<string, string>();
  regions.forEach((r, i) => colorOf.set(r.region, PALETTE[i % PALETTE.length]));

  const present = new Set(regions.filter((r) => r.users > 0).map((r) => r.region));
  const total = regions.reduce((n, r) => n + r.users, 0);

  return (
    <div>
      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="xMidYMid meet"
        style={{ width: '100%', height, display: 'block',
                 background: 'var(--surface-2)', borderRadius: 'var(--radius)' }}
        role="img"
        aria-label={`Accounts by region: ${total} across ${present.size} regions`}
      >
        {DOTS.map(([x, y, region], i) => {
          const on = region !== '' && present.has(region);
          const dim = hover !== null && hover !== region;
          return (
            <circle
              key={i}
              cx={x} cy={y}
              // Active dots are drawn slightly larger so a region reads as present even
              // before colour is accounted for — the map should survive being printed in
              // greyscale or seen by someone who cannot separate these hues.
              r={on ? 0.34 : 0.22}
              fill={on ? (colorOf.get(region) ?? 'var(--accent)') : 'var(--text-mute)'}
              fillOpacity={on ? (dim ? 0.3 : 1) : 0.28}
              onMouseEnter={() => on && setHover(region)}
              onMouseLeave={() => setHover(null)}
              style={{ transition: 'fill-opacity 120ms ease' }}
            />
          );
        })}
      </svg>

      {/* Two columns. Swatch colours are the map's own fills, so legend and map cannot
          disagree. */}
      <div
        style={{
          display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))',
          gap: '10px 20px', marginTop: 16,
        }}
      >
        {regions.map((r) => (
          <div key={r.region}
               onMouseEnter={() => setHover(r.region)}
               onMouseLeave={() => setHover(null)}>
            <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 5 }}>{r.region}</div>
            <div className="row" style={{ gap: 9 }}>
              <div style={{ flex: 1, height: 5, background: 'var(--surface-3)', borderRadius: 999, overflow: 'hidden' }}>
                <div style={{
                  width: `${r.share}%`, height: '100%', borderRadius: 999,
                  background: colorOf.get(r.region),
                  // A non-zero share must never render as an invisible sliver: reading as
                  // nothing at all is a different fact from being small.
                  minWidth: r.users > 0 ? 3 : 0,
                }} />
              </div>
              <span className="mono mute" style={{ fontSize: 12, minWidth: 42, textAlign: 'right' }}>
                {r.share}%
              </span>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
