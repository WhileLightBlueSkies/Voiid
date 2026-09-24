import http from 'node:http';
import https from 'node:https';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const port = Number(process.env.PORT || 4173);
const origin = process.env.VOIID_WEB_ORIGIN || `http://localhost:${port}`;
if (process.env.NODE_ENV === 'production' && !origin.startsWith('https://')) throw new Error('Set VOIID_WEB_ORIGIN to the dedicated HTTPS messenger origin.');
const api = new URL(process.env.VOIID_API_UPSTREAM || 'http://127.0.0.1:4000');
const live = new URL(process.env.VOIID_WS_UPSTREAM || 'http://127.0.0.1:4001/ws');
const root = fileURLToPath(new URL('dist/', import.meta.url));
const transport = url => url.protocol === 'https:' ? https : http;
const headers = {
  'Content-Security-Policy': "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; worker-src 'self'; font-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'",
  'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY', 'Referrer-Policy': 'no-referrer',
  'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Resource-Policy': 'same-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=()', 'Cache-Control': 'no-store',
  ...(origin.startsWith('https://') ? { 'Strict-Transport-Security': 'max-age=31536000' } : {}),
};
const sameOrigin = req => (!req.headers.origin || req.headers.origin === origin) && !['cross-site', 'same-site'].includes(req.headers['sec-fetch-site']);
const server = http.createServer(async (req, res) => {
  for (const [name, value] of Object.entries(headers)) res.setHeader(name, value);
  const path = new URL(req.url, origin).pathname;
  if (!sameOrigin(req)) { res.writeHead(403).end(); return; }
  if (path.startsWith('/api/v1/')) {
    if (!['GET', 'POST', 'DELETE'].includes(req.method)) { res.writeHead(405).end(); return; }
    const forwarded = { accept: 'application/json', 'x-voiid-platform': 'web' };
    for (const name of ['authorization', 'content-type', 'x-link-proof']) if (req.headers[name]) forwarded[name] = req.headers[name];
    const upstream = transport(api).request(api, { method: req.method, path: req.url.slice(4), headers: forwarded, timeout: 25000 }, response => {
      res.writeHead(response.statusCode || 502, { 'Content-Type': 'application/json', ...(response.headers['retry-after'] ? { 'Retry-After': response.headers['retry-after'] } : {}) });
      response.pipe(res);
    });
    let size = 0;
    req.on('data', chunk => { size += chunk.length; if (size > 2 * 1024 * 1024) { upstream.destroy(); if (!res.headersSent) res.writeHead(413).end(); } });
    upstream.on('timeout', () => upstream.destroy());
    upstream.on('error', () => { if (!res.headersSent) res.writeHead(502).end('{"error":"temporarily unavailable"}'); else res.destroy(); });
    req.on('aborted', () => upstream.destroy()); req.pipe(upstream); return;
  }
  if (!['GET', 'HEAD'].includes(req.method)) { res.writeHead(405).end(); return; }
  const files = { '/': ['index.html', 'text/html'], '/app.js': ['app.js', 'text/javascript'], '/engine.js': ['engine.js', 'text/javascript'], '/app.css': ['app.css', 'text/css'], '/mark.svg': ['mark.svg', 'image/svg+xml'], '/crypto/voiid_e2e_bg.wasm': ['crypto/voiid_e2e_bg.wasm', 'application/wasm'], '/fonts/plus-jakarta-sans-latin.woff2': ['fonts/plus-jakarta-sans-latin.woff2', 'font/woff2'], '/fonts/geist-latin.woff2': ['fonts/geist-latin.woff2', 'font/woff2'], '/fonts/geist-mono-latin.woff2': ['fonts/geist-mono-latin.woff2', 'font/woff2'] };
  const file = files[path]; if (!file) { res.writeHead(404).end(); return; }
  try { const bytes = await readFile(resolve(root, file[0])); res.writeHead(200, { 'Content-Type': file[1], 'Content-Length': bytes.length }); res.end(req.method === 'HEAD' ? undefined : bytes); }
  catch { res.writeHead(503).end('Build the web client first.'); }
});
server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, origin);
  if (url.pathname !== '/live' || req.headers.origin !== origin || !/^[A-Za-z0-9_-]{43}$/.test(url.searchParams.get('ticket') || '') || [...url.searchParams].length !== 1) { socket.destroy(); return; }
  const upstream = transport(live).request(live, { path: live.pathname + url.search, headers: { host: live.host, origin, connection: 'Upgrade', upgrade: 'websocket', 'sec-websocket-key': req.headers['sec-websocket-key'], 'sec-websocket-version': '13' }, timeout: 10000 });
  upstream.on('upgrade', (response, peer, remaining) => {
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${response.headers['sec-websocket-accept']}\r\n\r\n`);
    if (remaining.length) socket.write(remaining); if (head.length) peer.write(head);
    peer.on('error', () => socket.destroy()); socket.on('error', () => peer.destroy());
    socket.on('close', () => peer.destroy()); peer.on('close', () => socket.destroy());
    peer.pipe(socket); socket.pipe(peer);
  });
  upstream.on('response', () => socket.destroy()); upstream.on('error', () => socket.destroy()); upstream.on('timeout', () => upstream.destroy()); upstream.end();
});
server.listen(port, process.env.HOST || '127.0.0.1', () => console.log(`Voiid Web listening on ${origin}`));
