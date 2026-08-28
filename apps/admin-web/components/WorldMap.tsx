'use client';

//
// A regional choropleth: landmasses filled by share of accounts, with a percentage legend
// beneath — the shape of the reference.
//
// No mapping library and no GeoJSON fetch. A world topology is megabytes and a strict CSP
// would block a CDN anyway; this is ~4KB of simplified coastline, which is the right
// resolution for "which regions, roughly where, what share". Coarse on purpose: a
// distribution chart with a geographic axis, not an atlas.
//
// FILLED BY REGION, not by country, because the underlying data cannot resolve finer — +1
// is a single dialling prefix spanning the whole NANP. Drawing country borders over
// prefix-derived numbers would imply a precision the input does not have.
//
// Equirectangular, so lon/lat map linearly to x/y. Naive on purpose: nobody mistakes it for
// an area-accurate projection the way they might Mercator.
//

import { useState } from 'react';
import { SHAPES } from './land';

const W = 720;
// Clipped at ±83: the poles carry no accounts, and an uncropped equirectangular spends a
// third of its height on empty ice.
const LAT_MAX = 83;
const H = Math.round((W * (LAT_MAX * 2)) / 360);

const px = (lon: number) => ((lon + 180) / 360) * W;
const py = (lat: number) => ((LAT_MAX - lat) / (LAT_MAX * 2)) * H;

/** Rewrites a lon/lat path into viewBox coordinates. */
function project(d: string): string {
  return d.replace(/(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/g, (_m, lon, lat) =>
    `${px(Number(lon)).toFixed(1)},${py(Number(lat)).toFixed(1)}`);
}

export type GeoRegion = { region: string; users: number; share: number };

// A fixed palette rather than one hue at varying opacity: at four regions the eye reads
// distinct colours far faster than four shades of teal, and the legend swatch then matches
// the map exactly. Teal leads because it is the brand.
const PALETTE = [
  'var(--accent)',
  '#7c6cf0',
  '#3b82f6',
  '#2fa36b',
  '#f6821f',
  '#c86bd8',
];

export function WorldMap({ regions, height = 320 }: {
  regions: GeoRegion[]; height?: number;
}) {
  const [hover, setHover] = useState<string | null>(null);

  // Colour by RANK, so the largest region is always the brand colour and the map does not
  // reshuffle its palette as numbers move.
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
        aria-label={`Accounts by region: ${total} total across ${present.size} regions`}
      >
        {SHAPES.map((s) => {
          const on = present.has(s.region);
          const dim = hover !== null && hover !== s.region;
          return (
            <path
              key={s.id}
              d={project(s.d)}
              // A region with no accounts stays neutral grey. Tinting it faintly would put
              // it on the same scale as a real value and imply a share it does not have.
              fill={on ? (colorOf.get(s.region) ?? 'var(--accent)') : 'var(--surface-3)'}
              fillOpacity={on ? (dim ? 0.35 : 0.92) : 1}
              stroke="var(--border-strong)"
              strokeWidth="0.7"
              onMouseEnter={() => on && setHover(s.region)}
              onMouseLeave={() => setHover(null)}
              style={{ transition: 'fill-opacity 120ms ease' }}
            >
              {on && <title>{`${s.region} — ${regions.find((r) => r.region === s.region)?.share}%`}</title>}
            </path>
          );
        })}
      </svg>

      {/* Two columns, matching the reference. Swatch colours are the map's own fills, so
          the legend and the map can never disagree. */}
      <div
        style={{
          display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))',
          gap: '10px 20px', marginTop: 16,
        }}
      >
        {regions.map((r) => (
          <div
            key={r.region}
            onMouseEnter={() => setHover(r.region)}
            onMouseLeave={() => setHover(null)}
          >
            <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 5 }}>{r.region}</div>
            <div className="row" style={{ gap: 9 }}>
              <div style={{ flex: 1, height: 5, background: 'var(--surface-3)', borderRadius: 999, overflow: 'hidden' }}>
                <div
                  style={{
                    width: `${r.share}%`, height: '100%', borderRadius: 999,
                    background: colorOf.get(r.region),
                    // A non-zero share must never render as an invisible sliver: reading as
                    // nothing at all is a different fact from being small.
                    minWidth: r.users > 0 ? 3 : 0,
                  }}
                />
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
