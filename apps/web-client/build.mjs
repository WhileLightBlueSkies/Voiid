import { build } from 'esbuild';
import { mkdir, copyFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
process.chdir(fileURLToPath(new URL('.', import.meta.url)));
await mkdir('dist/crypto', { recursive: true });
await mkdir('dist/fonts', { recursive: true });
await build({ entryPoints: { app: 'src/main.tsx', engine: 'src/engine.ts' }, outdir: 'dist', bundle: true, format: 'esm', target: ['es2022'], minify: true, sourcemap: false, external: ['/fonts/*'], define: { 'process.env.NODE_ENV': '"production"' } });
await copyFile('../../packages/e2e-core/bindings/wasm/pkg/voiid_e2e_bg.wasm', 'dist/crypto/voiid_e2e_bg.wasm');
await copyFile('../web/public/voiid-logomark.svg', 'dist/mark.svg');
// Self-hosted, Latin subset: the CSP allows fonts from this origin only (font-src 'self').
for (const font of ['plus-jakarta-sans-latin', 'geist-latin', 'geist-mono-latin']) await copyFile(`fonts/${font}.woff2`, `dist/fonts/${font}.woff2`);
await writeFile('dist/index.html', '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="referrer" content="no-referrer"><title>Voiid Web</title><link rel="icon" href="/mark.svg"><link rel="stylesheet" href="/app.css"></head><body><div id="root"></div><script type="module" src="/app.js"></script></body></html>');
console.log('Built Voiid Web. Start with npm start --workspace @voiid/web-client.');
