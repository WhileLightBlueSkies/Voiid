import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import ts from 'typescript';

// Run production route handlers with external I/O replaced. Authenticated request fixtures;
// no live database, Redis, storage, push, or copied authorization implementations.
const localRequire = createRequire(import.meta.url);
const author = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const viewer = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const device = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const story = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
function harness(file: string, query: (sql: string, params: any[]) => Promise<any[]>, blocked = new Set<string>()) {
  const routes = new Map<string, Function>(), signed: string[] = [];
  const router = Object.fromEntries(['get', 'post', 'delete'].map(method => [method,
    (path: string, ...handlers: Function[]) => routes.set(`${method} ${path}`, handlers.at(-1)!)]));
  const mocks: Record<string, any> = {
    express: { Router: () => router }, '../db': { query },
    '../blocking': { blockedUserIds: async () => blocked },
    '../redis': { publisher: { publish: async () => { throw new Error('relay offline'); } } },
    '../auth': { requireAuth() {} }, '../security': { rateLimit: () => () => {} },
    '../util': { asyncHandler: (f: Function) => f, b64: (s: string) => Buffer.from(s, 'base64') },
    '../push': { sendWakePush: async () => {} },
    '../r2': { r2Configured: () => true, presignGet: async (key: string) => { signed.push(key); return 'https://example.invalid/encrypted'; },
      presignPut: async () => '', deleteObject: async () => {}, objectExists: async () => true },
  };
  const source = readFileSync(resolve('src/routes', file), 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  vm.runInNewContext(code, { require: (id: string) => mocks[id] ?? localRequire(id), exports: {}, Buffer, console: { warn() {} } });
  return { signed, async request(method: string, path: string, body: any = {}, user = viewer) {
    let status = 200, data: any;
    const res = { status(n: number) { status = n; return this; }, json(value: any) { data = value; return this; }, end() { return this; } };
    await routes.get(`${method} ${path}`)!({ body, auth: { user_id: user }, params: { id: story }, query: { device_id: device } }, res);
    return { status, data };
  } };
}

test('generic media cannot bypass Memories authorization; chat media still downloads', async () => {
  const h = harness('media.ts', async () => []);
  assert.equal((await h.request('post', '/presign-download', { key: `media/stories/${author}/${story}` })).status, 403);
  assert.equal(h.signed.length, 0);
  assert.equal((await h.request('post', '/presign-download', { key: `media/${author}/${story}` })).status, 200);
  assert.equal(h.signed.length, 1);
});

test('story downloads require live, entitled, unblocked content', async () => {
  for (const [exists, entitled, blocked, status] of [[false,false,false,404], [true,false,false,403], [true,true,true,403], [true,true,false,200]] as const) {
    const h = harness('stories.ts', async sql => {
      assert.match(sql, /expires_at > now\(\)/); assert.match(sql, /d.revoked_at is null/);
      return exists ? [{ r2_key: 'encrypted', author_id: author, entitled }] : [];
    }, new Set(blocked ? [author] : []));
    assert.equal((await h.request('post', '/presign-download', { story_id: story })).status, status);
    assert.equal(h.signed.length, status === 200 ? 1 : 0);
  }
});

test('unowned devices cannot fetch envelopes', async () => {
  let reads = 0;
  const h = harness('stories.ts', async sql => { reads++; assert.match(sql, /user_id = \$2 and revoked_at is null/); return []; });
  assert.equal((await h.request('get', '/feed')).status, 403);
  assert.equal(reads, 1);
});

test('fan-out handles uppercase UUIDs, blocking and failed wake relays', async () => {
  for (const blocked of [false, true]) {
    let inserts = 0;
    const h = harness('stories.ts', async (sql, params) => {
      if (sql.includes('select author_id from stories')) return [{ author_id: author }];
      if (sql.includes('select id, user_id from devices')) return [{ id: device, user_id: viewer }];
      if (sql.includes('insert into story_keys')) { inserts++; assert.equal(params[1], device); return [{ story_id: story }]; }
      if (sql.includes('select push_token')) return [];
      throw new Error(`Unexpected SQL: ${sql}`);
    }, new Set(blocked ? [viewer] : []));
    const r = await h.request('post', '/:id/keys', { keys: [{ recipient_device_id: device.toUpperCase(), ciphertext: 'AQID' }] }, author);
    assert.equal(r.status, 200); assert.equal(r.data.added, blocked ? 0 : 1); assert.equal(inserts, blocked ? 0 : 1);
  }
});

test('view receipts require a live story and a non-revoked viewer device', async () => {
  let reads = 0;
  const h = harness('stories.ts', async sql => {
    reads++;
    if (sql.includes('select author_id from stories')) { assert.match(sql, /expires_at > now\(\)/); return [{ author_id: author }]; }
    assert.match(sql, /d.revoked_at is null/); return [];
  });
  assert.equal((await h.request('post', '/:id/receipt', { receipts: [{ recipient_device_id: device, ciphertext: 'AQID' }] })).status, 403);
  assert.equal(reads, 2);
});


test('availability is bounded and returns only live authorized IDs without replaying ciphertext', async () => {
  let reads = 0;
  const h = harness('stories.ts', async (sql, params) => {
    reads++;
    assert.match(sql, /s.expires_at > now\(\)/);
    assert.match(sql, /d.user_id = \$2::uuid and d.revoked_at is null/);
    assert.match(sql, /not \(s.author_id = any/);
    assert.doesNotMatch(sql, /update|ciphertext/i);
    assert.deepEqual(Array.from(params[0]), [story]);
    assert.equal(params[1], viewer);
    assert.deepEqual(Array.from(params[2]), [author]);
    return [];
  }, new Set([author]));
  assert.equal((await h.request('post', '/availability', { story_ids: ['invalid'] })).status, 400);
  assert.equal((await h.request('post', '/availability', { story_ids: Array(1001).fill(story) })).status, 400);
  assert.equal((await h.request('post', '/availability', { story_ids: [] })).data.available.length, 0);
  assert.equal(reads, 0);
  const result = await h.request('post', '/availability', { story_ids: [story.toUpperCase(), story] });
  assert.equal(result.status, 200); assert.equal(result.data.available.length, 0); assert.equal(reads, 1);
});

test('availability preserves authorized live IDs', async () => {
  const h = harness('stories.ts', async () => [{ id: story }]);
  const result = await h.request('post', '/availability', { story_ids: [story] });
  assert.equal(result.status, 200); assert.equal(result.data.available[0], story);
});

test('a completed deletion succeeds even when the socket relay is offline', async () => {
  let deleted = false;
  const h = harness('stories.ts', async sql => {
    if (sql.includes('select author_id, r2_key')) return [{ author_id: author, r2_key: 'encrypted' }];
    if (sql.includes('select distinct d.user_id')) return [{ user_id: viewer }];
    if (sql.includes('delete from stories')) { deleted = true; return []; }
    throw new Error(`Unexpected SQL: ${sql}`);
  });
  assert.equal((await h.request('delete', '/:id', {}, author)).status, 204);
  assert.equal(deleted, true);
});

test('a persisted view receipt succeeds even when its socket relay is offline', async () => {
  let inserted = false;
  const h = harness('stories.ts', async sql => {
    if (sql.includes('select author_id from stories')) return [{ author_id: author }];
    if (sql.includes('select 1 as one from story_keys')) return [{ one: 1 }];
    if (sql.includes('select id from devices')) return [{ id: device }];
    if (sql.includes('insert into story_receipts')) { inserted = true; return []; }
    throw new Error(`Unexpected SQL: ${sql}`);
  });
  const result = await h.request('post', '/:id/receipt', { receipts: [{ recipient_device_id: device, ciphertext: 'AQID' }] });
  assert.equal(result.status, 200); assert.equal(result.data.accepted, 1); assert.equal(inserted, true);
});
