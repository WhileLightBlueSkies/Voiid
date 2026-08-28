'use client';

//
// A world choropleth, drawn as inline SVG from a coarse equirectangular projection.
//
// No mapping library and no GeoJSON download: a full world topology is megabytes, and this
// console needs to answer "which countries, roughly where, how many" — not to be an atlas.
// Countries are plotted as points at their centroid, sized and coloured by volume, over a
// simple graticule. That is honest about the resolution it has rather than implying
// border-level precision it does not.
//
// Equirectangular is the right projection here precisely because it is naive: lon/lat map
// linearly to x/y, so a reader cannot mistake it for an area-accurate view.
//

import { useState } from 'react';

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
const H = 360;

// Equirectangular: longitude and latitude map straight to x and y.
const px = (lon: number) => ((lon + 180) / 360) * W;
const py = (lat: number) => ((90 - lat) / 180) * H;

export type GeoRow = { code: string; users: number };

export function WorldMap({ rows }: { rows: GeoRow[] }) {
  const [hover, setHover] = useState<string | null>(null);

  const known = rows.filter((r) => CENTROIDS[r.code]);
  // Anything without a centroid is COUNTED and named, never silently dropped: a map that
  // quietly omits a country under-reports the total it appears to be showing.
  const unplaced = rows.filter((r) => !CENTROIDS[r.code] && r.code !== 'UNKNOWN');
  const unknown = rows.find((r) => r.code === 'UNKNOWN');

  const max = Math.max(...rows.map((r) => r.users), 1);
  const total = rows.reduce((n, r) => n + r.users, 0);

  return (
    <div>
      <svg
        viewBox={`0 0 ${W} ${H}`}
        style={{ width: '100%', height: 'auto', display: 'block',
                 background: 'var(--surface-2)', borderRadius: 'var(--radius)' }}
        role="img" aria-label={`Accounts by country: ${total} total`}
      >
        {/* Graticule every 30°, so the plot reads as a globe rather than a scatter chart. */}
        {[-60, -30, 0, 30, 60].map((lat) => (
          <line key={`a${lat}`} x1={0} x2={W} y1={py(lat)} y2={py(lat)}
                stroke="var(--border)" strokeWidth={lat === 0 ? 1.2 : 0.6} />
        ))}
        {[-120, -60, 0, 60, 120].map((lon) => (
          <line key={`o${lon}`} x1={px(lon)} x2={px(lon)} y1={0} y2={H}
                stroke="var(--border)" strokeWidth="0.6" />
        ))}

        {known.map((r) => {
          const [lon, lat, name] = CENTROIDS[r.code];
          // Area-proportional, not radius-proportional: scaling the radius by the count
          // makes a 4× value look 16× bigger, which is the classic bubble-map lie.
          const rad = 5 + Math.sqrt(r.users / max) * 22;
          const on = hover === r.code;
          return (
            <g key={r.code}
               onMouseEnter={() => setHover(r.code)}
               onMouseLeave={() => setHover(null)}>
              <circle
                cx={px(lon)} cy={py(lat)} r={rad}
                fill="var(--accent)" fillOpacity={on ? 0.55 : 0.32}
                stroke="var(--accent-ink)" strokeWidth={on ? 2 : 1.2}
              />
              <text
                x={px(lon)} y={py(lat) - rad - 5} textAnchor="middle"
                fill="var(--text)" fontSize="11" fontWeight="600"
                style={{ pointerEvents: 'none' }}
              >
                {name} · {r.users}
              </text>
            </g>
          );
        })}
      </svg>

      {(unplaced.length > 0 || unknown) && (
        <p className="mute" style={{ fontSize: 12, margin: '10px 0 0' }}>
          {unplaced.length > 0 && (
            <>Not plotted: {unplaced.map((r) => `${r.code} (${r.users})`).join(', ')}. </>
          )}
          {unknown && <>{unknown.users} with no recognised dialling prefix. </>}
        </p>
      )}
    </div>
  );
}
