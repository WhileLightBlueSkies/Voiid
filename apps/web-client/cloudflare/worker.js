// Voiid Web on Cloudflare Pages — the production twin of ../server.mjs.
//
// Deployed as Pages "advanced mode": build.mjs copies this file to dist/_worker.js, so it
// receives EVERY request for the site and serves the static build through env.ASSETS.
// Anything server.mjs enforces locally is enforced here too, and in the same way:
//
//   • the same security headers on every response (strict CSP, no framing, no referrer);
//   • same-origin only — a request from another site is refused before it goes anywhere;
//   • /api/v1/* forwarded to the API with a fixed header allowlist and a 2 MB body cap;
//   • /live upgraded to the relay's WebSocket only with a well-formed ticket and our Origin;
//   • only the files the app is made of are served, nothing else in the bucket.
//
// Configuration lives in wrangler.toml [vars] (see ../CLOUDFLARE.md); nothing here is
// browser-supplied. Upstreams are https:// — Workers speak WebSocket over an https URL.

const FILES = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript'],
  '/engine.js': ['engine.js', 'text/javascript'],
  '/app.css': ['app.css', 'text/css'],
  '/mark.svg': ['mark.svg', 'image/svg+xml'],
  '/crypto/voiid_e2e_bg.wasm': ['crypto/voiid_e2e_bg.wasm', 'application/wasm'],
  '/fonts/plus-jakarta-sans-latin.woff2': ['fonts/plus-jakarta-sans-latin.woff2', 'font/woff2'],
  '/fonts/geist-latin.woff2': ['fonts/geist-latin.woff2', 'font/woff2'],
  '/fonts/geist-mono-latin.woff2': ['fonts/geist-mono-latin.woff2', 'font/woff2'],
};

const SECURITY_HEADERS = {
  'Content-Security-Policy': "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; worker-src 'self'; font-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'",
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=()',
  'Cache-Control': 'no-store',
  'Strict-Transport-Security': 'max-age=31536000',
};

const FORWARDED_HEADERS = ['authorization', 'content-type', 'x-link-proof'];
const MAX_BODY = 2 * 1024 * 1024;
const TICKET = /^[A-Za-z0-9_-]{43}$/;

function secure(response, extra = {}) {
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries({ ...SECURITY_HEADERS, ...extra })) headers.set(name, value);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

const plain = (status, body = null) => secure(new Response(body, { status }));

export default {
  async fetch(request, env) {
    const origin = env.VOIID_WEB_ORIGIN;
    // Refuse to run half-configured rather than fall back to something permissive.
    if (!origin?.startsWith('https://') || !env.VOIID_API_UPSTREAM || !env.VOIID_WS_UPSTREAM) {
      return plain(500, 'Voiid Web is not configured. Set the [vars] in wrangler.toml.');
    }

    const url = new URL(request.url);
    const requestOrigin = request.headers.get('origin');
    const fetchSite = request.headers.get('sec-fetch-site');
    if ((requestOrigin && requestOrigin !== origin) || fetchSite === 'cross-site' || fetchSite === 'same-site') {
      return plain(403);
    }

    if (url.pathname === '/live') return live(request, url, env, origin);
    if (url.pathname.startsWith('/api/v1/')) return api(request, url, env);

    if (!['GET', 'HEAD'].includes(request.method)) return plain(405);
    const file = FILES[url.pathname];
    if (!file) return plain(404);
    const asset = await env.ASSETS.fetch(new Request(new URL(`/${file[0]}`, url.origin), { method: request.method }));
    if (!asset.ok) return plain(503, 'The web client build is missing.');
    return secure(asset, { 'Content-Type': file[1] });
  },
};

async function api(request, url, env) {
  if (!['GET', 'POST', 'DELETE'].includes(request.method)) return plain(405);

  const headers = new Headers({ accept: 'application/json', 'x-voiid-platform': 'web' });
  for (const name of FORWARDED_HEADERS) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }

  let body;
  if (request.method === 'POST') {
    const declared = Number(request.headers.get('content-length') || 0);
    if (declared > MAX_BODY) return plain(413);
    body = await request.arrayBuffer();
    if (body.byteLength > MAX_BODY) return plain(413);
  }

  // /api/v1/x -> <upstream>/v1/x, exactly as server.mjs strips the "/api" prefix.
  const target = new URL(url.pathname.slice(4) + url.search, env.VOIID_API_UPSTREAM);
  try {
    const upstream = await fetch(target, {
      method: request.method, headers, body, redirect: 'manual',
      signal: AbortSignal.timeout(25_000),
    });
    const extra = { 'Content-Type': 'application/json' };
    const retryAfter = upstream.headers.get('retry-after');
    if (retryAfter) extra['Retry-After'] = retryAfter;
    // Only the body and status cross back — upstream cookies and headers stay upstream.
    return secure(new Response(upstream.body, { status: upstream.status }), extra);
  } catch {
    return secure(new Response('{"error":"temporarily unavailable"}', { status: 502 }),
      { 'Content-Type': 'application/json' });
  }
}

async function live(request, url, env, origin) {
  const ticket = url.searchParams.get('ticket') || '';
  if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket' ||
      request.headers.get('origin') !== origin ||
      !TICKET.test(ticket) || [...url.searchParams].length !== 1) {
    return plain(400);
  }
  // The relay checks this Origin against its own VOIID_WEB_ORIGIN before it redeems the
  // ticket, so the two settings must be the same string (see ../CLOUDFLARE.md).
  const target = new URL(env.VOIID_WS_UPSTREAM);
  target.search = `?ticket=${ticket}`;
  return fetch(target, { headers: { Upgrade: 'websocket', Origin: origin } });
}
