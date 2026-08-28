'use client';

//
// A world map drawn as inline SVG: real coastlines, with the countries we actually see
// marked on them.
//
// No mapping library and no GeoJSON fetch. A full world topology is megabytes and a strict
// CSP would block the CDN anyway; these outlines are ~3KB of simplified coastline, which is
// the right resolution for "which countries, roughly where, how many". They are deliberately
// coarse — this is a distribution chart with a geographic axis, not an atlas, and pretending
// to border-level precision would be the dishonest option.
//
// Equirectangular, so longitude and latitude map linearly to x and y. Naive on purpose: no
// reader mistakes it for an area-accurate projection the way they might Mercator.
//

import { useState } from 'react';
import { LAND } from './land';

/** Centroids for the countries Voiid actually sees. Not an exhaustive gazetteer. */
const CENTROIDS: Record<string, [number, number, string]> = {
  IN: [78.9, 22.6, 'India'],          US: [-98.6, 39.8, 'United States'],
  NANP: [-95.0, 42.0, 'US & Canada'], GB: [-1.5, 52.4, 'United Kingdom'],
  CA: [-106.3, 56.1, 'Canada'],       AU: [133.8, -25.3, 'Australia'],
  DE: [10.5, 51.2, 'Germany'],        FR: [2.2, 46.2, 'France'],
  AE: [53.8, 23.4, 'UAE'],            SG: [103.8, 1.35, 'Singapore'],
  RU: [105.3, 61.5, 'Russia'],        IT: [12.6, 41.9, 'Italy'],
  BR: [-51.9, -14.2, 'Brazil'],       ZA: [22.9, -30.6, 'South Africa'],
  JP: [138.3, 36.2, 'Japan'],         CN: [104.2, 35.9, 'China'],
  PK: [69.3, 30.4, 'Pakistan'],       BD: [90.4, 23.7, 'Bangladesh'],
  LK: [80.8, 7.9, 'Sri Lanka'],       NP: [84.1, 28.4, 'Nepal'],
  MY: [101.98, 4.2, 'Malaysia'],      ID: [113.9, -0.8, 'Indonesia'],
  PH: [121.8, 12.9, 'Philippines'],   TH: [100.99, 15.9, 'Thailand'],
  SA: [45.1, 23.9, 'Saudi Arabia'],   QA: [51.2, 25.4, 'Qatar'],
  KW: [47.5, 29.3, 'Kuwait'],         OM: [55.9, 21.5, 'Oman'],
  NL: [5.3, 52.1, 'Netherlands'],     ES: [-3.7, 40.5, 'Spain'],
  NZ: [174.9, -40.9, 'New Zealand'],  NG: [8.7, 9.1, 'Nigeria'],
  KE: [37.9, -0.02, 'Kenya'],         EG: [30.8, 26.8, 'Egypt'],
};

const W = 720;
// Latitude is clipped at ±83: the poles carry no accounts and an uncropped
// equirectangular wastes a third of its height on empty ice.
const LAT_MAX = 83;
const H = Math.round((W * (LAT_MAX * 2)) / 360);

const px = (lon: number) => ((lon + 180) / 360) * W;
const py = (lat: number) => ((LAT_MAX - lat) / (LAT_MAX * 2)) * H;

/** Rewrites a lon/lat path into viewBox coordinates. */
function project(d: string): string {
  return d.replace(/(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/g, (_m, lon, lat) =>
    `${px(Number(lon)).toFixed(1)},${py(Number(lat)).toFixed(1)}`);
}

export type GeoRow = { code: string; users: number };

export function WorldMap({ rows, height = 300 }: { rows: GeoRow[]; height?: number }) {
  const [hover, setHover] = useState<string | null>(null);

  const known = rows.filter((r) => CENTROIDS[r.code]);
  // Anything without a centroid is COUNTED and named below, never silently dropped: a map
  // that quietly omits a country under-reports the total it appears to show.
  const unplaced = rows.filter((r) => !CENTROIDS[r.code] && r.code !== 'UNKNOWN');
  const unknown = rows.find((r) => r.code === 'UNKNOWN');

  const max = Math.max(...rows.map((r) => r.users), 1);
  const total = rows.reduce((n, r) => n + r.users, 0);
  const active = hover ? rows.find((r) => r.code === hover) : null;

  return (
    <div>
      <div className="row" style={{ marginBottom: 10, alignItems: 'baseline' }}>
        <span style={{ fontSize: 13, fontWeight: 600 }}>Accounts by country</span>
        <span className="mute" style={{ fontSize: 12 }}>
          {active
            ? `${CENTROIDS[active.code]?.[2] ?? active.code} · ${active.users}`
            : `${total} across ${known.length + unplaced.length} ${known.length + unplaced.length === 1 ? 'country' : 'countries'}`}
        </span>
      </div>

      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="xMidYMid meet"
        style={{ width: '100%', height, display: 'block',
                 background: 'var(--surface-2)', borderRadius: 'var(--radius)' }}
        role="img" aria-label={`Accounts by country: ${total} total`}
      >
        {/* Graticule under the land, so the grid reads as behind the world rather than on it. */}
        {[-60, -30, 0, 30, 60].map((lat) => (
          <line key={`a${lat}`} x1={0} x2={W} y1={py(lat)} y2={py(lat)}
                stroke="var(--border)" strokeWidth={lat === 0 ? 1 : 0.5} opacity="0.5" />
        ))}
        {[-120, -60, 0, 60, 120].map((lon) => (
          <line key={`o${lon}`} x1={px(lon)} x2={px(lon)} y1={0} y2={H}
                stroke="var(--border)" strokeWidth="0.5" opacity="0.5" />
        ))}

        {Object.entries(LAND).map(([k, d]) => (
          <path key={k} d={project(d)}
                fill="var(--surface-3)" stroke="var(--border-strong)" strokeWidth="0.7" />
        ))}

        {known.map((r) => {
          const [lon, lat, name] = CENTROIDS[r.code];
          // Area-proportional, not radius-proportional: scaling radius by the count makes a
          // 4x value look 16x bigger, which is the classic bubble-map lie.
          const rad = 4 + Math.sqrt(r.users / max) * 16;
          const on = hover === r.code;
          return (
            <g key={r.code} style={{ cursor: 'default' }}
               onMouseEnter={() => setHover(r.code)}
               onMouseLeave={() => setHover(null)}>
              <circle cx={px(lon)} cy={py(lat)} r={rad + 6} fill="transparent" />
              <circle
                cx={px(lon)} cy={py(lat)} r={rad}
                fill="var(--accent)" fillOpacity={on ? 0.6 : 0.34}
                stroke="var(--accent-ink)" strokeWidth={on ? 2 : 1.2}
              />
              {/* The label is drawn only for the hovered country once the map is busy —
                  overlapping permanent labels are what turns a bubble map into noise. */}
              {(on || known.length <= 6) && (
                <text
                  x={px(lon)} y={py(lat) - rad - 5} textAnchor="middle"
                  fill="var(--text)" fontSize="11" fontWeight="600"
                  style={{ pointerEvents: 'none', paintOrder: 'stroke' }}
                  stroke="var(--surface-2)" strokeWidth="3"
                >
                  {name} · {r.users}
                </text>
              )}
            </g>
          );
        })}
      </svg>

      {(unplaced.length > 0 || unknown) && (
        <p className="mute" style={{ fontSize: 12, margin: '10px 0 0' }}>
          {unplaced.length > 0 && (
            <>Not plotted: {unplaced.map((r) => `${r.code} (${r.users})`).join(', ')}. </>
          )}
          {unknown && <>{unknown.users} with no recognised dialling prefix.</>}
        </p>
      )}
    </div>
  );
}
