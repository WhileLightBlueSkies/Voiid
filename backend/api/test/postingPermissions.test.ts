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
  const space = randomUUID(), otherSpace = randomUUID();
  const handle = 'pp' + randomUUID().replace(/-/g, '').slice(0, 8);

  async function post(as: string, channelId?: string) {
    const res = await fetch(`${base}/communities/${community}/posts`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user': as },
      body: JSON.stringify({ body: 'hello', channel_id:channelId }),
    });
    return res.status;
  }
  const setPolicy = (p: string) =>
    query('update communities set posting_policy = $2 where id = $1', [community, p]);

  try {
    for (const [i, id] of [owner, plain, picked].entries()) {
      await query('insert into users (id, phone_number) values ($1,$2) on conflict do nothing',
                  [id, `+9198000000${i}${Math.floor(Math.random() * 90 + 10)}`]);
      // Posting is a public act and now requires a Social Profile (social/identity.ts);
      // without one these fixtures would get 428 rather than the permission answer under test.
      await query('insert into social_profiles (user_id, handle) values ($1,$2) on conflict do nothing',
                  [id, `perm${i}${Math.floor(Math.random() * 9000 + 1000)}`]);
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

    for (const id of [space,otherSpace]) {
      await query("insert into conversations(id,type,name) values($1,'group','Topic')",[id]);
      await query("insert into community_channels(conversation_id,community_id,kind,posting) values($1,$2,'chat','selected')",[id,community]);
    }
    async function request(path: string, as: string, method='GET', body?: object) {
      const response = await fetch(`${base}/communities/${community}${path}`,{
        method,headers:{'content-type':'application/json','x-test-user':as},
        body:body===undefined?undefined:JSON.stringify(body)});
      return {status:response.status,body:await response.json() as any};
    }
    await t.test('channel list returns authoritative policy and permission, including managers',async()=>{
      const result=await request('/channels',owner);
      assert.equal(result.status,200);
      assert.equal(result.body.channels.find((c:any)=>c.conversation_id===space).can_post,true);
      assert.equal(result.body.channels.find((c:any)=>c.conversation_id===space).posting,'selected');
      assert.equal((await request('/join',owner,'POST',{})).body.channels.find((c:any)=>c.conversation_id===space).can_post,true);
      const member=await request('/channels',plain);
      assert.equal(member.body.channels.find((c:any)=>c.conversation_id===space).can_post,false);
    });
    await t.test('Space settings persist policy, purpose and pinning; invalid policy changes nothing',async()=>{
      assert.equal((await request(`/channels/${space}`,plain,'PATCH',{posting:'everyone'})).status,403);
      assert.equal((await request(`/channels/${space}`,owner,'PATCH',{posting:'none',purpose:'Space topic',pinned:true})).status,200);
      assert.equal(await post(owner,space),403);
      let row=(await query('select posting,purpose,pinned_at from community_channels where conversation_id=$1',[space]))[0];
      assert.equal(row.posting,'none'); assert.equal(row.purpose,'Space topic'); assert.ok(row.pinned_at);
      assert.equal((await request(`/channels/${space}`,owner,'PATCH',{name:'must not apply',posting:'invalid'})).status,400);
      assert.equal((await query('select name from conversations where id=$1',[space]))[0].name,'Topic');
      await request(`/channels/${space}`,owner,'PATCH',{posting:'selected',pinned:false});
    });
    await t.test('everyone: any active member may post', async () => {
      await setPolicy('everyone');
      assert.equal(await post(plain), 201);
      assert.equal((await request('',plain)).body.can_post,true);
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
      assert.equal((await request('',owner)).body.can_post,false);
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

    await t.test('Home and Space grants are independent, and removal takes effect on the next fetch',async()=>{
      assert.equal(await post(picked,space),403);
      assert.equal((await request('/posting-allowlist',owner,'POST',{user_id:picked,channel_id:space,allowed:true})).status,200);
      assert.equal(await post(picked,space),201);
      assert.equal(await post(picked,otherSpace),403);
      const permitted=await request(`/posts?channel_id=${space}`,picked);
      assert.equal(permitted.body.can_post,true);
      assert.equal((await request('/posting-allowlist',plain)).status,403);
      assert.equal((await request('/posting-allowlist',owner,'POST',{user_id:picked,channel_id:randomUUID(),allowed:true})).status,404);
      await request('/posting-allowlist',owner,'POST',{user_id:picked,channel_id:space,allowed:false});
      assert.equal((await request(`/posts?channel_id=${space}`,picked)).body.can_post,false);
      assert.equal(await post(picked,space),403);
    });
    await t.test('one post can target Home and multiple Spaces atomically', async () => {
      await setPolicy('everyone');
      await query("update community_channels set posting='everyone' where conversation_id=$1", [space]);
      await query("update community_channels set posting='selected' where conversation_id=$1", [otherSpace]);
      const ok = await request('/posts', owner, 'POST', {
        body: 'everywhere-once', channel_ids: [null, space, otherSpace],
      });
      assert.equal(ok.status, 201);
      assert.equal(ok.body.posts.length, 3);
      assert.deepEqual(new Set(ok.body.posts.map((p:any) => p.channel_id)), new Set([null, space, otherSpace]));

      const before = Number((await query(
        "select count(*) from community_posts where community_id=$1 and body='must-not-partially-land'",
        [community]))[0].count);
      const denied = await request('/posts', plain, 'POST', {
        body: 'must-not-partially-land', channel_ids: [null, otherSpace],
      });
      assert.equal(denied.status, 403);
      const after = Number((await query(
        "select count(*) from community_posts where community_id=$1 and body='must-not-partially-land'",
        [community]))[0].count);
      assert.equal(after, before);
    });
    await t.test('feeds isolate Home and each Space and preserve every same-timestamp page',async()=>{
      const ids=Array.from({length:3},()=>randomUUID());
      for(const id of ids) await query("insert into community_posts(id,community_id,channel_id,author_id,body,created_at) values($1,$2,$3,$4,'page','2090-01-01T00:00:00.123456Z')",[id,community,space,owner]);
      const home=await request('/posts',owner);
      assert.ok(home.body.posts.every((p:any)=>p.channel_id===null));
      let cursor:string|null=null; const seen:string[]=[];
      do {
        const page=await request(`/posts?channel_id=${space}&limit=1${cursor?'&cursor='+encodeURIComponent(cursor):''}`,owner);
        assert.equal(page.status,200);
        assert.ok(page.body.posts.every((p:any)=>p.channel_id===space));
        seen.push(...page.body.posts.map((p:any)=>p.id)); cursor=page.body.next_cursor;
      } while(cursor);
      for(const id of ids) assert.equal(seen.filter(v=>v===id).length,1);
      assert.equal((await request('/posts?cursor=garbage',owner)).status,400);
      // ISOLATION, not emptiness. An earlier subtest posts 'everywhere-once' to
      // [null, space, otherSpace] deliberately, so asserting this feed is EMPTY makes the two
      // tests contradict each other and whichever runs second fails. What matters here is
      // that this Space's feed contains only ITS OWN posts — never the three 'page' rows
      // written to `space` above.
      const other = (await request(`/posts?channel_id=${otherSpace}`,owner)).body.posts;
      assert.ok(other.every((p:any)=>p.channel_id===otherSpace));
      assert.equal(other.filter((p:any)=>ids.includes(p.id)).length,0);
      await query('update communities set discoverable=true where id=$1',[community]);
      assert.equal((await request(`/posts?channel_id=${space}`,randomUUID())).status,404);
    });
    await t.test('Space likes are idempotent and cannot be added by a non-member',async()=>{
      const row=(await query('select id from community_posts where community_id=$1 and channel_id=$2 limit 1',[community,space]))[0];
      const path=`/posts/${row.id}/like`;
      // 428, not 403: liking is a public act, so requireSocialProfile() runs before the
      // membership check. A stranger with no Social Profile is told to make one rather than
      // told they are not a member — which also says less about the community than 403 did.
      assert.equal((await request(path,randomUUID(),'POST',{})).status,428);
      for(let i=0;i<2;i++) assert.equal((await request(path,plain,'POST',{})).status,200);
      assert.equal((await query('select like_count from community_posts where id=$1',[row.id]))[0].like_count,1);
      for(let i=0;i<2;i++) assert.equal((await request(path,plain,'DELETE')).status,200);
      assert.equal((await query('select like_count from community_posts where id=$1',[row.id]))[0].like_count,0);
    });
    await t.test('views increment only readable published posts and return only a count',async()=>{
      const row=(await query('select id from community_posts where community_id=$1 and channel_id=$2 limit 1',[community,space]))[0];
      assert.equal((await request(`/posts/${row.id}/view`,randomUUID(),'POST',{})).status,404);
      const first=await request(`/posts/${row.id}/view`,plain,'POST',{});
      const second=await request(`/posts/${row.id}/view`,plain,'POST',{});
      assert.equal(first.status,200); assert.deepEqual(Object.keys(first.body),['view_count']);
      assert.equal(second.body.view_count,first.body.view_count+1);
      const concurrent = await Promise.all(Array.from({length:10},()=>request(`/posts/${row.id}/view`,plain,'POST',{})));
      assert.ok(concurrent.every(r=>r.status===200));
      assert.equal((await query('select view_count from community_posts where id=$1',[row.id]))[0].view_count,second.body.view_count+10);
      await query("update community_posts set scheduled_at=now()+interval '1 hour' where id=$1",[row.id]);
      assert.equal((await request(`/posts/${row.id}/view`,plain,'POST',{})).status,404);
      await query('update community_posts set scheduled_at=null,removed_at=now() where id=$1',[row.id]);
      assert.equal((await request(`/posts/${row.id}/view`,plain,'POST',{})).status,404);
    });

    await t.test('suspension hides channel capabilities and refuses feeds and views',async()=>{
      await query('update communities set suspended_at=now() where id=$1',[community]);
      assert.equal((await request('/channels',owner)).status,403);
      assert.equal((await request('/posts',owner)).status,403);
      const detail=await request('',owner);
      assert.equal(detail.body.can_post,false);
      assert.deepEqual(detail.body.channels,[]);
    });

  } finally {
    await query('delete from community_post_allowlist where community_id = $1', [community]).catch(() => {});
    await query('delete from community_members where community_id = $1', [community]).catch(() => {});
    await query('delete from community_posts where community_id = $1', [community]).catch(() => {});
    await query('delete from conversations where id=any($1::uuid[])',[[space,otherSpace]]).catch(()=>{});
    await query('delete from communities where id = $1', [community]).catch(() => {});
    await query('delete from users where id = any($1::uuid[])', [[owner, plain, picked]]).catch(() => {});
    await new Promise<void>((r, j) => server.close(e => (e ? j(e) : r())));
    await pool.end();
  }
});
