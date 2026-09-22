#!/usr/bin/env node
// Validates every manifest against the schema AND against the real canonical
// face model, so a bad anchor index is caught in CI rather than by an artist
// wondering why an ear is attached to a chin.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  SCHEMA_VERSION, BLENDSHAPES, PASSES, BINDING_TARGETS, WARP_MODES,
  BLEND_MODES, BILLBOARD_MODES, PHYSICS_DRIVERS, MAX_TIER, MAX_PARTICLES,
} from './schema.mjs';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const MODEL = JSON.parse(readFileSync(join(ROOT, 'canonical', 'face_model.json'), 'utf8'));
const BLEND_SET = new Set(BLENDSHAPES);

class Failures {
  constructor(file) { this.file = file; this.list = []; }
  check(cond, msg) { if (!cond) this.list.push(msg); return cond; }
}

function validateAnchor(f, where, a) {
  if (!f.check(a && Array.isArray(a.indices) && Array.isArray(a.weights),
      `${where}: anchor needs 'indices' and 'weights' arrays`)) return;
  f.check(a.indices.length === a.weights.length,
    `${where}: indices (${a.indices.length}) and weights (${a.weights.length}) differ in length`);
  f.check(a.indices.length >= 1 && a.indices.length <= 4,
    `${where}: anchor must blend 1-4 vertices, got ${a.indices.length}`);
  for (const i of a.indices) {
    f.check(Number.isInteger(i) && i >= 0 && i < MODEL.landmarkCount,
      `${where}: vertex index ${i} outside 0..${MODEL.landmarkCount - 1}`);
  }
  const sum = a.weights.reduce((s, w) => s + w, 0);
  f.check(Math.abs(sum - 1) <= 0.001, `${where}: weights sum to ${sum.toFixed(4)}, must be 1.000`);
  f.check(a.weights.every((w) => w >= 0), `${where}: negative weight`);
}

function validateBindings(f, where, bindings) {
  if (bindings === undefined) return;
  if (!f.check(Array.isArray(bindings), `${where}: bindings must be an array`)) return;
  for (const [i, b] of bindings.entries()) {
    const w = `${where}.bindings[${i}]`;
    f.check(BLEND_SET.has(b.blendshape), `${w}: unknown blendshape '${b.blendshape}'`);
    f.check(BINDING_TARGETS.includes(b.target), `${w}: unknown target '${b.target}'`);
    f.check(Array.isArray(b.inRange) && b.inRange.length === 2, `${w}: inRange must be [lo,hi]`);
    f.check(Array.isArray(b.outRange) && b.outRange.length === 2, `${w}: outRange must be [lo,hi]`);
    if (Array.isArray(b.inRange) && b.inRange.length === 2) {
      f.check(b.inRange[0] < b.inRange[1], `${w}: inRange is empty or inverted`);
    }
  }
}

function validateManifest(path, spritesFor) {
  const f = new Failures(basename(path));
  let m;
  try { m = JSON.parse(readFileSync(path, 'utf8')); }
  catch (e) { f.list.push(`not valid JSON: ${e.message}`); return f; }

  f.check(m.schema === SCHEMA_VERSION, `schema must be ${SCHEMA_VERSION}, got ${m.schema}`);
  f.check(typeof m.id === 'string' && /^[a-z][a-z0-9]*$/.test(m.id),
    `id '${m.id}' must be lowercase alphanumeric`);
  f.check(m.id === basename(path, '.json'), `id '${m.id}' must match filename`);
  f.check(Number.isInteger(m.version) && m.version >= 1, `version must be a positive integer`);
  f.check(typeof m.name === 'string' && m.name.length > 0, `name is required`);
  f.check(Number.isInteger(m.tier) && m.tier >= 1 && m.tier <= MAX_TIER,
    `tier must be 1..${MAX_TIER}`);
  f.check(typeof m.bundled === 'boolean', `'bundled' must be declared true or false`);

  // passes: a subset of PASSES, in PASSES order
  if (f.check(Array.isArray(m.passes) && m.passes.length > 0, `passes must be a non-empty array`)) {
    for (const p of m.passes) f.check(PASSES.includes(p), `unknown pass '${p}'`);
    const order = m.passes.map((p) => PASSES.indexOf(p));
    f.check(order.every((v, i) => i === 0 || v > order[i - 1]),
      `passes must be listed in canonical order: ${PASSES.join(' -> ')}`);
    f.check(new Set(m.passes).size === m.passes.length, `duplicate pass`);
  }

  const has = (p) => Array.isArray(m.passes) && m.passes.includes(p);
  const sprites = spritesFor(m.id);
  f.check(m.atlas === undefined,
    `'atlas' is set by the packer -- remove it from the source manifest`);

  // warps
  if (has('warp')) {
    if (f.check(Array.isArray(m.warps) && m.warps.length > 0, `pass 'warp' listed but no warps`)) {
      for (const [i, w] of m.warps.entries()) {
        const where = `warps[${i}]`;
        validateAnchor(f, where, w.anchor);
        f.check(WARP_MODES.includes(w.mode), `${where}: unknown mode '${w.mode}'`);
        f.check(w.radiusCm > 0 && w.radiusCm < 20, `${where}: radiusCm ${w.radiusCm} out of range`);
        f.check(Math.abs(w.strength) <= 1, `${where}: |strength| must be <= 1`);
        if (w.mode === 'translate') {
          f.check(Array.isArray(w.direction) && w.direction.length === 2,
            `${where}: translate mode needs direction [x,y]`);
        }
      }
    }
  } else {
    f.check(!m.warps || m.warps.length === 0, `warps defined but pass 'warp' not listed`);
  }

  // face textures
  if (has('faceTexture')) {
    if (f.check(Array.isArray(m.faceTextures) && m.faceTextures.length > 0,
        `pass 'faceTexture' listed but none defined`)) {
      for (const [i, t] of m.faceTextures.entries()) {
        const where = `faceTextures[${i}]`;
        f.check(BLEND_MODES.includes(t.blend), `${where}: unknown blend '${t.blend}'`);
        f.check(t.opacity >= 0 && t.opacity <= 1, `${where}: opacity out of 0..1`);
        checkSprite(f, where, t, sprites);
      }
    }
  }

  // props
  const orders = new Set();
  if (has('props')) {
    if (f.check(Array.isArray(m.layers) && m.layers.length > 0, `pass 'props' listed but no layers`)) {
      for (const [i, l] of m.layers.entries()) {
        const where = `layers[${i}] '${l.id ?? '?'}'`;
        f.check(typeof l.id === 'string' && l.id.length > 0, `${where}: id required`);
        f.check(l.type === 'quad', `${where}: only type 'quad' is supported`);
        checkSprite(f, where, l, sprites);
        validateAnchor(f, where, l.anchor);
        f.check(Array.isArray(l.offsetCm) && l.offsetCm.length === 3, `${where}: offsetCm [x,y,z] required`);
        f.check(Array.isArray(l.sizeCm) && l.sizeCm.length === 2 && l.sizeCm.every((v) => v > 0),
          `${where}: sizeCm [w,h] must be positive`);
        f.check(BILLBOARD_MODES.includes(l.billboard), `${where}: unknown billboard '${l.billboard}'`);
        f.check(Number.isInteger(l.order), `${where}: integer 'order' required`);
        if (Number.isInteger(l.order)) {
          f.check(!orders.has(l.order), `${where}: duplicate order ${l.order}`);
          orders.add(l.order);
        }
        if (l.physics) {
          f.check(l.physics.type === 'spring', `${where}: only physics type 'spring' supported`);
          f.check(PHYSICS_DRIVERS.includes(l.physics.driver),
            `${where}: unknown physics driver '${l.physics.driver}'`);
          f.check(l.physics.stiffness > 0 && l.physics.damping > 0,
            `${where}: spring stiffness and damping must be positive`);
        }
        validateBindings(f, where, l.bindings);
      }
    }
  }

  // particles
  if (has('ambient')) {
    if (f.check(Array.isArray(m.particles) && m.particles.length > 0,
        `pass 'ambient' listed but no particles`)) {
      for (const [i, p] of m.particles.entries()) {
        const where = `particles[${i}]`;
        checkSprite(f, where, p, sprites);
        validateAnchor(f, where, p.emitAnchor);
        f.check(BLEND_SET.has(p.trigger?.blendshape),
          `${where}: unknown trigger blendshape '${p.trigger?.blendshape}'`);
        f.check(p.maxParticles > 0 && p.maxParticles <= MAX_PARTICLES,
          `${where}: maxParticles must be 1..${MAX_PARTICLES}`);
      }
    }
  }

  return f;
}

// Source manifests name a sprite; `pack.py` resolves the name to an atlasRect.
// Validating the NAME against art/ is what catches a typo before an artist
// wonders why a layer renders blank.
function checkSprite(f, where, node, sprites) {
  if (!f.check(typeof node.sprite === 'string' && node.sprite.length > 0,
      `${where}: 'sprite' name required`)) return;
  f.check(node.atlasRect === undefined,
    `${where}: source manifests must not hardcode atlasRect -- name the sprite instead`);
  f.check(sprites.has(node.sprite),
    `${where}: no art for sprite '${node.sprite}' (expected art/<id>/${node.sprite}.svg)`);
}

// --- run -------------------------------------------------------------------

const manifestDir = join(ROOT, 'manifests');
const artDir = join(ROOT, 'art');
const spritesFor = (id) => {
  const d = join(artDir, id ?? '');
  if (!id || !existsSync(d)) return new Set();
  return new Set(readdirSync(d).filter((n) => n.endsWith('.svg')).map((n) => basename(n, '.svg')));
};

const files = existsSync(manifestDir)
  ? readdirSync(manifestDir).filter((n) => n.endsWith('.json')).sort()
  : [];

let failed = 0;
const ids = new Set();
for (const name of files) {
  const f = validateManifest(join(manifestDir, name), spritesFor);
  const id = basename(name, '.json');
  if (ids.has(id)) f.list.push(`duplicate filter id '${id}'`);
  ids.add(id);
  if (f.list.length) {
    failed++;
    console.error(`FAIL ${f.file}`);
    for (const msg of f.list) console.error(`     - ${msg}`);
  } else {
    console.log(`ok   ${f.file}`);
  }
}

console.log(`\n${files.length - failed}/${files.length} manifests valid` +
  ` (canonical model: ${MODEL.meshVertexCount} verts, ${MODEL.landmarkCount} landmarks)`);
if (failed) process.exit(1);
