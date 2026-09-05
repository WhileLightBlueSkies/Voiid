// P03 — every route rejection reaches the error handler, and every error means what it says.
//
// Express 4 does NOT catch a rejected promise from a route handler. A bare `async (req, res)`
// that throws therefore sends no response at all: the client waits until it times out, the
// socket is held, and the only trace is a process-level unhandledRejection log that cannot
// finish the request it belongs to. `asyncHandler` exists for exactly this and was applied to
// some routes and not others.
//
// The error middleware also decided "was this a bad request?" by running a regex over the
// error MESSAGE, so an oversized body — which carries its own status — came back as 500, and
// any internal error whose text happened to contain "invalid input" came back as 400.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import express from 'express';
import { asyncHandler } from '../src/util';
import { installErrorHandler } from '../src/errors';

// ── The guard: no route may be left unwrapped ───────────────────────────────────

test('no route handler is left bare, in any router', async () => {
  const dir = resolve(__dirname, '../src/routes');
  const offenders: string[] = [];
  for (const name of (await readdir(dir)).filter((f) => f.endsWith('.ts'))) {
    const source = await readFile(resolve(dir, name), 'utf8');
    // `router.get('/x', requireAuth, async (req, res) => {` — an async function passed
    // straight to Express rather than through asyncHandler.
    const bare = source.match(/router\.(get|post|put|patch|delete)\((?:[^()]|\([^()]*\))*?,\s*async\s*\(/g);
    if (bare) offenders.push(`${name} (${bare.length})`);
  }
  assert.deepEqual(
    offenders, [],
    'these routers pass async handlers straight to Express, so a rejection sends no response ' +
      'and the client hangs. Wrap them in asyncHandler (src/util.ts).'
  );
});

// ── The middleware's behaviour ─────────────────────────────────────────────────

async function appWith(route: (app: express.Express) => void) {
  const app = express();
  app.use(express.json({ limit: '1kb' }));
  route(app);
  installErrorHandler(app);
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>((done) => server.once('listening', () => done()));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;
  return {
    base,
    close: () => new Promise<void>((done, fail) => server.close((e) => (e ? fail(e) : done()))),
  };
}

test('a rejected handler finishes the request instead of hanging it', async () => {
  const app = await appWith((a) =>
    a.get('/boom', asyncHandler(async () => { throw new Error('the database fell over'); }))
  );
  try {
    const res = await fetch(`${app.base}/boom`);
    assert.equal(res.status, 500);
    const body = await res.json() as any;
    assert.equal(body.code, 'internal_error');
    // The reason must not travel: it is where SQL text and provider detail leak out.
    assert.ok(!JSON.stringify(body).includes('database fell over'), 'the internal reason was returned');
  } finally { await app.close(); }
});

test('malformed JSON is a 400, not a 500', async () => {
  const app = await appWith((a) => a.post('/echo', (_req, res) => res.json({ ok: true })));
  try {
    const res = await fetch(`${app.base}/echo`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: '{ not json',
    });
    assert.equal(res.status, 400);
    assert.equal((await res.json() as any).code, 'invalid_json');
  } finally { await app.close(); }
});

// The specific mapping the issue names: body-too-large carried a 413 and was answered 500.
test('an oversized body is a 413, not a 500', async () => {
  const app = await appWith((a) => a.post('/echo', (_req, res) => res.json({ ok: true })));
  try {
    const res = await fetch(`${app.base}/echo`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ blob: 'x'.repeat(4096) }),
    });
    assert.equal(res.status, 413);
    assert.equal((await res.json() as any).code, 'payload_too_large');
  } finally { await app.close(); }
});

test('an error carrying its own status is honoured, not guessed at', async () => {
  const app = await appWith((a) =>
    a.get('/gone', asyncHandler(async () => {
      throw Object.assign(new Error('no such thing'), { status: 404, code: 'not_found' });
    }))
  );
  try {
    const res = await fetch(`${app.base}/gone`);
    assert.equal(res.status, 404);
    assert.equal((await res.json() as any).code, 'not_found');
  } finally { await app.close(); }
});

// The old middleware ran /base64|invalid input/i over the message, so an internal failure
// mentioning either word was reported to the caller as their mistake.
test('an internal error is not downgraded to 400 by what its message happens to say', async () => {
  const app = await appWith((a) =>
    a.get('/boom', asyncHandler(async () => { throw new Error('invalid input syntax for type uuid'); }))
  );
  try {
    const res = await fetch(`${app.base}/boom`);
    assert.equal(res.status, 500, 'a Postgres cast error is our bug, not the caller\'s');
    assert.equal((await res.json() as any).code, 'internal_error');
  } finally { await app.close(); }
});

test('every error response carries a request id the logs can be searched by', async () => {
  const app = await appWith((a) =>
    a.get('/boom', asyncHandler(async () => { throw new Error('x'); }))
  );
  try {
    const res = await fetch(`${app.base}/boom`);
    const body = await res.json() as any;
    assert.match(String(body.request_id ?? ''), /^[0-9a-f-]{8,}/);
    assert.equal(res.headers.get('x-request-id'), body.request_id);
  } finally { await app.close(); }
});

test('a response already begun is not written over', async () => {
  const app = await appWith((a) =>
    a.get('/half', asyncHandler(async (_req, res) => {
      res.status(200).json({ ok: true });
      throw new Error('after the fact');
    }))
  );
  try {
    const res = await fetch(`${app.base}/half`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true });
  } finally { await app.close(); }
});
