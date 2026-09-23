#!/usr/bin/env node
// CI gate (LUDO_GAME_SPEC.md §19): fails the build if any Ludo raster asset is referenced.
// Every board cell, pawn, die face, pip, star, chevron and invite illustration is code-drawn;
// there are NO raster assets in Ludo.
const fs = require('fs');
const path = require('path');

const ROOTS = [
  'apps/ios/Voiid/Voiid',
  'apps/android/app/src/main',
  'packages/design-tokens',
];
const BAD_EXT = /\.(png|jpe?g|webp|gif|bmp)$/i;
const offenders = [];

function walk(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walk(p); continue; }
    if (!/\.(swift|kt|json)$/.test(e.name)) continue;
    if (/ludo_board_v3\.json$/.test(p)) continue; // geometry fixture is data, not an asset
    let text;
    try { text = fs.readFileSync(p, 'utf8'); } catch { continue; }
    if (/game_ludo\s*\+\s*\.(png|jpg|jpeg|webp)/i.test(text)) offenders.push(p);
    // Any string literal naming a ludo raster asset file.
    const m = text.match(/["'][^"']*ludo[^"']*\.(png|jpe?g|webp|gif)["']/i);
    if (m) offenders.push(`${p}: ${m[0]}`);
  }
}

for (const root of ROOTS) {
  if (fs.existsSync(path.join(__dirname, '..', root))) walk(path.join(__dirname, '..', root));
}
// Games-library COVER ART is not Ludo's game surface. §19 is about what the game draws — the
// board, pawns, dice and invite — which stays code-drawn. The picture on the Games screen card
// and the setup banner is decorative artwork for the library, the same kind every other game
// has, and both platforms ship it: iOS `GameLudoHome` / `GameLudoSetup` (GameArtwork.swift),
// Android `game_ludo_home` (GamesHomeScreen.kt). Named exactly, so a NEW Ludo raster anywhere
// else still fails the build.
const COVER_ART = [
  /[\\/]GameLudo(Home|Setup)\.imageset[\\/][^\\/]+$/,
  /[\\/]game_ludo_(home|setup)\.(png|webp)$/,
];

// Raster files themselves under asset catalogs / res drawables named *ludo*.
function findRasterFiles(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { findRasterFiles(p); continue; }
    if (COVER_ART.some((re) => re.test(p))) continue;
    // The folder counts as well as the file: an asset catalog names the IMAGE by its
    // `.imageset` directory, so `GameLudoBoard.imageset/artwork.png` is a Ludo raster even
    // though the file itself is not called *ludo*. That is how the iOS covers went unnoticed.
    if (BAD_EXT.test(e.name) && (/ludo/i.test(e.name) || /ludo[^\\/]*\.imageset[\\/][^\\/]+$/i.test(p))) {
      offenders.push(`RASTER FILE: ${p}`);
    }
  }
}
findRasterFiles(path.join(__dirname, '..', 'apps/ios/Voiid/Voiid'));
findRasterFiles(path.join(__dirname, '..', 'apps/android/app/src/main/res'));

if (offenders.length > 0) {
  console.error('Ludo raster assets found (spec §19 forbids them):');
  for (const o of offenders) console.error('  ' + o);
  process.exit(1);
}
console.log('OK: no Ludo raster assets referenced.');
