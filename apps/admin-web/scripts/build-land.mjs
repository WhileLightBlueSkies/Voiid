#!/usr/bin/env node
//
// Generates components/land.ts from Natural Earth data (world-atlas), at BUILD TIME.
//
// The atlas and topojson-client stay devDependencies: the browser gets pre-projected SVG
// path strings, not an 8MB topology plus a decoder. Real cartography, no runtime cost, and
// nothing fetched at render time for a CSP to block.
//
// Run: node scripts/build-land.mjs
//
import { readFileSync, writeFileSync } from 'node:fs';
import { feature } from 'topojson-client';

const topo = JSON.parse(readFileSync(
  new URL('../../../node_modules/world-atlas/countries-110m.json', import.meta.url), 'utf8'));
const fc = feature(topo, topo.objects.countries);

// ISO 3166-1 NUMERIC -> region. Numeric because that is what Natural Earth keys on; mapping
// through alpha-2 would add a lookup table that could drift from this one.
const REGION = {
  // North America
  840: 'North America', 124: 'North America', 484: 'North America', 304: 'North America',
  // South America
  76: 'South America', 32: 'South America', 152: 'South America', 170: 'South America',
  604: 'South America', 862: 'South America', 218: 'South America', 68: 'South America',
  858: 'South America', 600: 'South America', 328: 'South America', 740: 'South America',
  // Europe
  826: 'Europe', 372: 'Europe', 250: 'Europe', 276: 'Europe', 380: 'Europe', 724: 'Europe',
  620: 'Europe', 528: 'Europe', 56: 'Europe', 756: 'Europe', 40: 'Europe', 752: 'Europe',
  578: 'Europe', 208: 'Europe', 246: 'Europe', 616: 'Europe', 203: 'Europe', 300: 'Europe',
  642: 'Europe', 348: 'Europe', 804: 'Europe', 100: 'Europe', 191: 'Europe', 688: 'Europe',
  703: 'Europe', 705: 'Europe', 440: 'Europe', 428: 'Europe', 233: 'Europe', 352: 'Europe',
  70: 'Europe', 807: 'Europe', 8: 'Europe', 499: 'Europe', 498: 'Europe', 470: 'Europe',
  // Russia & Central Asia
  643: 'Russia & C. Asia', 398: 'Russia & C. Asia', 860: 'Russia & C. Asia',
  112: 'Russia & C. Asia', 268: 'Russia & C. Asia', 51: 'Russia & C. Asia',
  31: 'Russia & C. Asia', 417: 'Russia & C. Asia', 762: 'Russia & C. Asia',
  795: 'Russia & C. Asia',
  // India & neighbours
  356: 'India', 586: 'India', 50: 'India', 144: 'India', 524: 'India', 64: 'India',
  4: 'India',
  // China & East Asia
  156: 'China & E. Asia', 392: 'China & E. Asia', 410: 'China & E. Asia',
  158: 'China & E. Asia', 496: 'China & E. Asia', 408: 'China & E. Asia',
  // Indonesia
  360: 'Indonesia',
  // SE Asia
  764: 'SE Asia', 704: 'SE Asia', 458: 'SE Asia', 702: 'SE Asia', 608: 'SE Asia',
  104: 'SE Asia', 116: 'SE Asia', 418: 'SE Asia', 96: 'SE Asia', 626: 'SE Asia',
  // Middle East
  784: 'Middle East', 682: 'Middle East', 634: 'Middle East', 414: 'Middle East',
  512: 'Middle East', 48: 'Middle East', 400: 'Middle East', 422: 'Middle East',
  376: 'Middle East', 368: 'Middle East', 364: 'Middle East', 792: 'Middle East',
  887: 'Middle East', 760: 'Middle East', 275: 'Middle East',
  // Africa
  710: 'Africa', 566: 'Africa', 404: 'Africa', 818: 'Africa', 288: 'Africa', 231: 'Africa',
  834: 'Africa', 800: 'Africa', 504: 'Africa', 12: 'Africa', 788: 'Africa', 686: 'Africa',
  384: 'Africa', 120: 'Africa', 716: 'Africa', 894: 'Africa', 646: 'Africa', 508: 'Africa',
  24: 'Africa', 434: 'Africa', 729: 'Africa', 450: 'Africa', 466: 'Africa', 562: 'Africa',
  854: 'Africa', 324: 'Africa', 226: 'Africa', 148: 'Africa', 178: 'Africa', 180: 'Africa',
  262: 'Africa', 232: 'Africa', 706: 'Africa', 270: 'Africa', 624: 'Africa', 430: 'Africa',
  694: 'Africa', 204: 'Africa', 768: 'Africa', 288: 'Africa', 132: 'Africa', 516: 'Africa',
  426: 'Africa', 748: 'Africa', 72: 'Africa', 174: 'Africa', 262: 'Africa', 728: 'Africa',
  // Oceania
  36: 'Oceania', 554: 'Oceania', 242: 'Oceania', 598: 'Oceania', 90: 'Oceania',
  548: 'Oceania', 296: 'Oceania',
};

const W = 720, LAT_MAX = 83;
const H = Math.round((W * LAT_MAX * 2) / 360);
const px = (lon) => ((lon + 180) / 360) * W;
const py = (lat) => ((LAT_MAX - lat) / (LAT_MAX * 2)) * H;

/** One decimal is ~80m at the equator — far below a 720px render, and it halves the file. */
const r1 = (n) => Math.round(n * 10) / 10;

function ring(coords) {
  let d = '';
  let last = null;
  for (const [lon, lat] of coords) {
    if (lat > LAT_MAX || lat < -LAT_MAX) continue;   // clip the poles we do not draw
    const x = r1(px(lon)), y = r1(py(lat));
    // Drop points that round to the same pixel — invisible detail, real bytes.
    if (last && last[0] === x && last[1] === y) continue;
    d += `${d ? 'L' : 'M'}${x},${y}`;
    last = [x, y];
  }
  return d ? d + 'Z' : '';
}

function pathOf(geom) {
  if (geom.type === 'Polygon') return geom.coordinates.map(ring).join('');
  if (geom.type === 'MultiPolygon') return geom.coordinates.flat().map(ring).join('');
  return '';
}

const shapes = [];
let unmapped = [];
for (const f of fc.features) {
  const region = REGION[Number(f.id)];
  const d = pathOf(f.geometry);
  if (!d) continue;
  // A country with no region mapping is still DRAWN, as neutral geography. Dropping it
  // would leave holes in the world — and a map missing Kazakhstan reads as a broken render,
  // not as "no accounts there".
  if (!region) unmapped.push(f.properties?.name);
  shapes.push({ id: String(f.id), region: region ?? '', name: f.properties?.name ?? '', d });
}

const out = `// GENERATED by scripts/build-land.mjs from world-atlas (Natural Earth 110m).
// Do not edit by hand — re-run the script.
//
// Real cartography, pre-projected to an equirectangular ${W}x${H} viewBox at build time, so
// the browser receives path strings rather than an 8MB topology and a decoder.
export const MAP_W = ${W};
export const MAP_H = ${H};
export const SHAPES: { id: string; region: string; name: string; d: string }[] = [
${shapes.map((s) => `  { id: '${s.id}', region: '${s.region}', name: ${JSON.stringify(s.name)}, d: '${s.d}' },`).join('\n')}
];
`;

writeFileSync(new URL('../components/land.ts', import.meta.url), out);
console.log(`shapes: ${shapes.length}  regions: ${new Set(shapes.map(s => s.region)).size}  KB: ${(out.length / 1024).toFixed(0)}`);
if (unmapped.length) console.log(`unmapped (drawn as neutral): ${unmapped.length}`);
