/**
 * The four-value posting policy, against real PostgreSQL.
 *
 * WHY THIS EXISTS. `everyone | managers | selected | none` replaced two different two-value
 * spellings (078), and the 2026-09-15 audit found the old default let ANY member publish to
 * a community's public Home feed. A matrix like this is only trustworthy if every cell is
 * exercised: the interesting failures are `selected` granting too much (an allowlist that
 * silently includes everyone) and `none` granting too little in the wrong direction (an
 * owner exception nobody asked for).
 *
 * Run: COMMUNITY_TEST_DATABASE_URL=postgres://.../voiid_test_communities npm test -w @voiid/api
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import vm from 'node:vm';
import pg from 'pg';
import express from 'express';
import ts from 'typescript';

const url = process.env.COMMUNITY_TEST_DATABASE_URL;
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../src');
const require = createRequire(import.meta.url);

test('posting policy: everyone, managers, selected and none', { skip: !url }, async t => {
  assert.match(new URL(url!).pathname, /(?:test_communities|communities_test)$/);
  const pool = new pg.Pool({ connectionString: url });
  const query = async (sql: string, params?: any[]) => (await pool.query(sql, params)).rows;
  const cache = new Map<string, any>();
  const noop = (_req: any, _res: any, next: Function) => next();
  const mocks: Record<string, any> = {
    [resolve(root, 'db.ts')]: { pool, query },
    [resolve(root, 'auth.ts')]: {
      requireAuth: (req: any, res: any, next: Function) =>
        req.auth?.user_id ? next() : res.status(401).json({ error: 'auth required' }),
      invalidateAccountState: async () => {},
    },
    [resolve(root, 'redis.ts')]: {
      publisher: { publish: async () => {}, pipeline: () => ({ publish() { return this; }, exec: async () => {} }) },
    },
    [resolve(root, 'security.ts')]: { rateLimit: () => noop, clientIp: () => '127.0.0.1', guardKeyMaterialFetch: async () => 'allow' },
    [resolve(root, 'r2.ts')]: { r2Configured: () => false, presignGet: async () => '', deleteObject: async () => {} },
    [resolve(root, 'push.ts')]: { sendAdminBroadcast: async () => {} },
    [resolve(root, 'blocking.ts')]: { isBlockedEitherWay: async () => false, blockedUserIds: async () => new Set() },
    [resolve(root, 'util.ts')]: {
      asyncHandler: (f: Function) => (req: any, res: any, next: Function) => Promise.resolve(f(req, res, next)).catch(next),
      b64: (s: string) => (s ? Buffer.from(s, 'base64') : null),
    },
  };
  function load(file: string): any {
    if (mocks[file]) return mocks[file];
    if (cache.has(file)) return cache.get(file);
    const exports = {}; cache.set(file, exports);
    const code = ts.transpileModule(readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    vm.runInNewContext(code, {
      exports, Buffer, console, process,
      require: (id: string) => (id.startsWith('.') ? load(resolve(dirname(file), id + '.ts')) : require(id)),
    }, { filename: file });
    return exports;
  }

  const app = express();
  app.use(express.json());
  app.use((req: any, _res, next) => { req.auth = { user_id: req.headers['x-test-user'] }; next(); });
  app.use('/communities', load(resolve(root, 'routes/communities.ts')).default);
  app.use((error: any, _req: any, res: any, _next: any) => res.status(500).json({ error: error.message }));
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(r => server.once('listening', r));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;

  const owner = randomUUID(), plain = randomUUID(), picked = randomUUID();
  const community = randomUUID();
  const handle = 'pp' + randomUUID().replace(/-/g, '').slice(0, 8);

  async function post(as: string) {
    const res = await fetch(`${base}/communities/${community}/posts`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user': as },
      body: JSON.stringify({ body: 'hello' }),
    });
    return res.status;
  }
  const setPolicy = (p: string) =>
    query('update communities set posting_policy = $2 where id = $1', [community, p]);

  try {
    for (const [i, id] of [owner, plain, picked].entries()) {
      await query('insert into users (id, phone_number) values ($1,$2) on conflict do nothing',
                  [id, `+9198000000${i}${Math.floor(Math.random() * 90 + 10)}`]);
    }
    await query(
      `insert into communities (id, name, handle, owner_id, posting_policy)
       values ($1,'Perms',$2,$3,'everyone')`,
      [community, handle, owner],
    );
    for (const [id, role] of [[owner, 'owner'], [plain, 'member'], [picked, 'member']] as const) {
      await query(
        `insert into community_members (community_id, user_id, role, state)
         values ($1,$2,$3,'active') on conflict do nothing`,
        [community, id, role],
      );
    }

    await t.test('everyone: any active member may post', async () => {
      await setPolicy('everyone');
      assert.equal(await post(plain), 201);
    });

    await t.test('managers: the owner may, an ordinary member may not', async () => {
      await setPolicy('managers');
      assert.equal(await post(owner), 201);
      assert.equal(await post(plain), 403);
    });

    await t.test('none refuses EVERYONE, the owner included', async () => {
      // The interesting half. `none` is a statement about the space rather than about
      // people, so an owner exception here would make the setting mean something other
      // than what its name says.
      await setPolicy('none');
      assert.equal(await post(owner), 403);
      assert.equal(await post(plain), 403);
    });

    await t.test('selected: the allowlist ADDS to managers, it does not replace them', async () => {
      await setPolicy('selected');
      // Nobody listed yet: only the manager gets through.
      assert.equal(await post(owner), 201);
      assert.equal(await post(picked), 403);
      assert.equal(await post(plain), 403);

      await query(
        `insert into community_post_allowlist (community_id, channel_id, user_id, granted_by)
         values ($1, null, $2, $3)`,
        [community, picked, owner],
      );
      assert.equal(await post(picked), 201);
      // Still scoped: listing one person must not open the feed to the rest.
      assert.equal(await post(plain), 403);
      // And the owner never loses access by being absent from the list — an allowlist that
      // could lock out the owner would make one slip unrecoverable.
      assert.equal(await post(owner), 201);
    });

    await t.test('a Home-feed grant does not carry into a Space', async () => {
      // The allowlist is keyed by (community, channel), with null meaning Home. A grant that
      // leaked across that boundary would silently widen every Space in the community.
      const rows = await query(
        `select 1 from community_post_allowlist
          where community_id = $1 and user_id = $2 and channel_id = $3`,
        [community, picked, randomUUID()],
      );
      assert.equal(rows.length, 0);
    });
  } finally {
    await query('delete from community_post_allowlist where community_id = $1', [community]).catch(() => {});
    await query('delete from community_members where community_id = $1', [community]).catch(() => {});
    await query('delete from community_posts where community_id = $1', [community]).catch(() => {});
    await query('delete from communities where id = $1', [community]).catch(() => {});
    await query('delete from users where id = any($1::uuid[])', [[owner, plain, picked]]).catch(() => {});
    await new Promise<void>((r, j) => server.close(e => (e ? j(e) : r())));
    await pool.end();
  }
});
