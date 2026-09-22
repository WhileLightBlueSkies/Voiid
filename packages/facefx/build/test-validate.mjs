#!/usr/bin/env node
// Phase 0 exit criterion: the validator must REJECT each malformed manifest,
// and reject it for the stated reason. A validator that only ever says "ok" is
// indistinguishable from no validator at all.

import { mkdtempSync, mkdirSync, writeFileSync, rmSync, cpSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const GOOD = JSON.parse(
  execFileSync('cat', [join(ROOT, 'manifests', 'shades.json')], { encoding: 'utf8' }));

const clone = () => JSON.parse(JSON.stringify(GOOD));

const CASES = [
  ['accepts the valid manifest', clone(), null],

  ['rejects an unknown schema version',
    (() => { const m = clone(); m.schema = 99; return m; })(), /schema must be 1/],

  ['rejects a vertex index past the landmark count',
    (() => { const m = clone(); m.layers[0].anchor.indices = [999, 234, 33]; return m; })(),
    /index 999 outside/],

  ['rejects anchor weights that do not sum to 1',
    (() => { const m = clone(); m.layers[0].anchor.weights = [0.5, 0.2, 0.2]; return m; })(),
    /weights sum to 0\.9000/],

  ['rejects a sprite with no art on disk',
    (() => { const m = clone(); m.layers[0].sprite = 'nonesuch'; return m; })(),
    /no art for sprite 'nonesuch'/],

  ['rejects a hardcoded atlasRect in a source manifest',
    (() => { const m = clone(); m.layers[0].atlasRect = [0, 0, 8, 8]; return m; })(),
    /must not hardcode atlasRect/],

  ['rejects an unknown blendshape',
    (() => {
      const m = clone();
      m.layers[0].bindings = [{ blendshape: 'smileALot', target: 'opacity',
                                inRange: [0, 1], outRange: [0, 1] }];
      return m;
    })(), /unknown blendshape 'smileALot'/],

  ['rejects an unknown binding target',
    (() => {
      const m = clone();
      m.layers[0].bindings = [{ blendshape: 'jawOpen', target: 'colour.r',
                                inRange: [0, 1], outRange: [0, 1] }];
      return m;
    })(), /unknown target 'colour.r'/],

  ['rejects duplicate layer order',
    (() => { const m = clone(); m.layers[1].order = m.layers[0].order; return m; })(),
    /duplicate order/],

  ['rejects passes listed out of canonical order',
    (() => { const m = clone(); m.passes = ['props', 'occluder']; return m; })(),
    /canonical order/],

  ['rejects a pass with no content',
    (() => { const m = clone(); m.passes = ['occluder', 'warp', 'props']; return m; })(),
    /pass 'warp' listed but no warps/],

  ['rejects an id that disagrees with the filename',
    (() => { const m = clone(); m.id = 'notshades'; return m; })(), /must match filename/],
];

let pass = 0, fail = 0;
for (const [label, manifest, expect] of CASES) {
  const dir = mkdtempSync(join(tmpdir(), 'facefx-'));
  try {
    mkdirSync(join(dir, 'manifests'), { recursive: true });
    mkdirSync(join(dir, 'canonical'), { recursive: true });
    cpSync(join(ROOT, 'canonical'), join(dir, 'canonical'), { recursive: true });
    cpSync(join(ROOT, 'art'), join(dir, 'art'), { recursive: true });
    cpSync(join(ROOT, 'build'), join(dir, 'build'), { recursive: true });
    writeFileSync(join(dir, 'manifests', 'shades.json'), JSON.stringify(manifest));

    let out = '', code = 0;
    try {
      out = execFileSync('node', [join(dir, 'build', 'validate.mjs')],
                         { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      code = e.status ?? 1;
      out = `${e.stdout ?? ''}${e.stderr ?? ''}`;
    }

    let ok;
    if (expect === null) ok = code === 0;
    else ok = code !== 0 && expect.test(out);

    if (ok) { pass++; console.log(`  ok   ${label}`); }
    else {
      fail++;
      console.error(`  FAIL ${label}`);
      console.error(`       expected ${expect ?? 'exit 0'}, got exit ${code}`);
      console.error(`       ${out.trim().split('\n').join('\n       ')}`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`\n${pass}/${pass + fail} validator cases passed`);
if (fail) process.exit(1);
