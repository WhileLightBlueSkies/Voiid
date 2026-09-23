import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { randomUUID, createHash } from 'node:crypto';
import vm from 'node:vm';
import pg from 'pg';
import express from 'express';
import ts from 'typescript';

const url = process.env.COMMUNITY_TEST_DATABASE_URL;
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../src');
const require = createRequire(import.meta.url);

test('community roles, official controls, invite admission and encrypted lifecycle against PostgreSQL', { skip: !url }, async t => {
  assert.match(new URL(url!).pathname, /(?:test_communities|communities_test)$/);
  const pool = new pg.Pool({ connectionString: url });
  const query = async (sql: string, params?: any[]) => (await pool.query(sql, params)).rows;
  const cache = new Map<string, any>();
  const noop = (_req: any, _res: any, next: Function) => next();
  const notices: { channel: string; body: any }[] = [];
  const mocks: Record<string, any> = {
    [resolve(root, 'db.ts')]: { pool, query },
    [resolve(root, 'auth.ts')]: { requireAuth: (req: any, res: any, next: Function) => req.auth?.user_id ? next() : res.status(401).json({ error: 'auth required' }), invalidateAccountState: async () => {} },
    [resolve(root, 'redis.ts')]: { publisher: { publish: async (channel: string, raw: string) => { notices.push({channel, body:JSON.parse(raw)}); }, pipeline: () => ({ publish(channel: string, raw: string) { notices.push({channel,body:JSON.parse(raw)}); return this; }, exec: async () => {} }) } },
    [resolve(root, 'security.ts')]: { rateLimit: () => noop, clientIp: () => '127.0.0.1', guardKeyMaterialFetch: async () => 'allow' },
    [resolve(root, 'r2.ts')]: { r2Configured: () => false, presignGet: async () => '', deleteObject: async () => {} },
    [resolve(root, 'push.ts')]: { sendAdminBroadcast: async () => {} },
    [resolve(root, 'blocking.ts')]: { isBlockedEitherWay: async () => false, blockedUserIds: async () => new Set() },
    [resolve(root, 'util.ts')]: { asyncHandler: (f: Function) => (req: any, res: any, next: Function) => Promise.resolve(f(req, res, next)).catch(next), b64: (s: string) => s ? Buffer.from(s, 'base64') : null },
  };
  function load(file: string): any {
    if (mocks[file]) return mocks[file];
    if (cache.has(file)) return cache.get(file);
    const exports = {}; cache.set(file, exports);
    const code = ts.transpileModule(readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
    vm.runInNewContext(code, { exports, Buffer, console, process,
      require: (id: string) => id.startsWith('.') ? load(resolve(dirname(file), id + '.ts')) : require(id),
    }, { filename: file });
    return exports;
  }
  const app = express(); app.use(express.json());
  app.use((req: any, _res, next) => { req.auth = { user_id: req.headers['x-test-user'], device_id: req.headers['x-test-device'] }; next(); });
  app.use('/communities', load(resolve(root, 'routes/communities.ts')).default);
  app.use('/conversations', load(resolve(root, 'routes/conversations.ts')).default);
  app.use('/mls', load(resolve(root, 'routes/mls.ts')).default);
  app.use('/admin', load(resolve(root, 'routes/admin.ts')).default);
  app.use((error: any, _req: any, res: any, _next: any) => { res.status(500).json({ error: error.message }); });
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(r => server.once('listening', r));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;
  const users = [randomUUID(), randomUUID(), randomUUID(), randomUUID()];
  const [owner, member, admin, outsider] = users;
  const device = randomUUID(), secondDevice = randomUUID(), memberDevice = randomUUID(), memberSibling = randomUUID();
  const community = randomUUID(), normal = randomUUID(), approval = randomUUID();
  const prefix = 'ct' + randomUUID().replace(/-/g, '').slice(0, 8);
  const adminId = randomUUID(), moderatorId = randomUUID();
  const adminToken = randomUUID(), moderatorToken = randomUUID();
  async function request(method: string, path: string, body?: unknown, user = owner, auth?: string, dev?: string) {
    const response = await fetch(base + path, { method, headers: { 'content-type': 'application/json', 'x-test-user': user,
      ...(auth ? { authorization: `Bearer ${auth}` } : {}), ...(dev ? { 'x-test-device': dev } : {}) }, body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: response.status, body: await response.json() as any };
  }
  try {
    for (const [i, id] of users.entries()) await query(`insert into users(id,phone_number,username,full_name) values($1,$2,$3,$4)`, [id, '+' + Date.now() + i, prefix + i, 'Community fixture ' + i]);
    // A Social Profile is now a prerequisite for every public act — joining a community,
    // posting, liking (see social/identity.ts). Without one the routes answer 428
    // `profile_required`, which is correct behaviour and would make every fixture here fail
    // as a missing member rather than an authorization result.
    for (const [i, id] of users.entries()) await query(`insert into social_profiles(user_id,handle,display_name) values($1,$2,$3)`, [id, prefix + i, 'Community fixture ' + i]);
    for (const [id, uid, reg] of [[device,owner,1],[secondDevice,owner,2],[memberDevice,member,1],[memberSibling,member,2]]) await query(`insert into devices(id,user_id,platform,registration_id,identity_public_key) values($1,$2,'ios',$3,$4)`, [id,uid,reg,Buffer.from('test')]);
    for (const [id, token, role] of [[adminId,adminToken,'admin'],[moderatorId,moderatorToken,'moderator']]) {
      await query(`insert into admin_users(id,email,password_hash,role) values($1,$2,'unused-test-hash',$3)`,[id,`${id}@example.invalid`,role]);
      await query(`insert into admin_sessions(admin_id,token_hash,expires_at) values($1,$2,now()+interval '1 hour')`,[id,createHash('sha256').update(token).digest('hex')]);
    }
    for (const [id, suffix, policy] of [[community,'official','open'],[normal,'normal','open'],[approval,'approval','approval']]) {
      const r = await request('POST','/communities',{id,handle:prefix+suffix,name:'Fixture '+suffix,discoverable:true,join_policy:policy});
      assert.equal(r.status,201,JSON.stringify(r.body));
    }
    await query(`update communities set official_key='feedback',posting_policy='managers' where id=$1`,[community]);
    await t.test('handle availability agrees with what create will accept', async () => {
      const check = async (h: string, user = owner) => (await request('GET',`/communities/handle-available?handle=${h}`,undefined,user)).body;
      assert.deepEqual(await check('2bad'), { available: false, reason: 'format' });
      assert.equal((await check(prefix+'normal', outsider)).available, false);              // another community
      assert.equal((await check(prefix.toUpperCase()+'NORMAL', outsider)).available, false); // case-insensitive
      assert.equal((await check('invite')).available, false);                               // reserved route
      // A community may not take even its OWN creator's username — unlike the creators
      // checker, which excludes the caller. Create must refuse the same name.
      assert.equal((await check(prefix+'0')).available, false);
      assert.equal((await request('POST','/communities',{id:randomUUID(),handle:prefix+'0',name:'Own name'})).status, 409);
      assert.deepEqual(await check(prefix+'free'), { available: true, reason: null });
    });
    await t.test('admin list counts setup exactly as the app card does, and filters', async () => {
      const row = async (qs = '') => (await request('GET',`/admin/communities?q=${prefix}${qs}`,undefined,owner,adminToken))
        .body.communities.find((c: any) => c.id === normal);
      // Fresh: no description, only the two built-in Spaces, no rules, no invites, one member.
      assert.equal((await row()).setup_done, 0);
      assert.equal((await request('PATCH',`/communities/${normal}`,{description:'For testing.'})).status, 200);
      assert.equal((await request('POST',`/communities/${normal}/rules`,{title:'Be kind'})).status, 201);
      assert.equal((await row()).setup_done, 2);
      assert.ok(await row('&join_policy=open'));
      assert.equal(await row('&join_policy=approval'), undefined);
      await query(`update communities set category='Education' where id=$1`,[normal]);
      assert.ok(await row('&category=education'));
      assert.equal(await row('&category=Music'), undefined);
    });
    await t.test('institution communities are created for an owner and carry moderator tags only while granted', async () => {
      const body = { owner: prefix + '2', handle: prefix + 'inst', name: 'Fixture university', institution_name: 'Fixture University' };
      assert.equal((await request('POST','/admin/communities',body,owner,moderatorToken)).status, 403);  // admin role only
      const made = await request('POST','/admin/communities',body,owner,adminToken);
      assert.equal(made.status, 201, JSON.stringify(made.body));
      const inst = made.body.community;
      assert.equal(inst.institution_name, 'Fixture University');
      assert.equal(inst.owner_id, admin);                        // owned by the account named, not the Voiid admin
      assert.equal((await request('GET',`/communities/${prefix}inst`,undefined,outsider)).body.community.institution_name, 'Fixture University');
      // Same handle rules as the app: a taken handle is refused through the admin path too.
      assert.equal((await request('POST','/admin/communities',{...body, handle: prefix+'normal'},owner,adminToken)).status, 409);

      // A tag needs an active member …
      assert.equal((await request('POST',`/admin/communities/${inst.id}/badges`,{user_id:member,note:'Council'},owner,adminToken)).status, 409);
      assert.equal((await request('POST',`/communities/${inst.id}/join`,{},member)).status, 200);
      const granted = await request('POST',`/admin/communities/${inst.id}/badges`,{user_id:member,note:'Student council',make_admin:true},owner,adminToken);
      assert.equal(granted.status, 201, JSON.stringify(granted.body));
      assert.equal((await query(`select role from community_members where community_id=$1 and user_id=$2`,[inst.id,member]))[0].role, 'admin');
      assert.equal((await request('POST',`/admin/communities/${inst.id}/badges`,{user_id:member,note:'again'},owner,adminToken)).status, 409);

      // … and shows on that member's posts, and nobody else's.
      const tagged = await request('POST',`/communities/${inst.id}/posts`,{body:'Fest registrations open'},member);
      assert.equal(tagged.status, 201, JSON.stringify(tagged.body));
      assert.equal(tagged.body.post.author_badge, 'community_moderator');
      const plain = await request('POST',`/communities/${inst.id}/posts`,{body:'Owner update'},admin);
      assert.equal(plain.body.post.author_badge, null);
      // Every query that reads authors goes through the same join — pinning included.
      const pinned = await request('POST',`/communities/${inst.id}/announcements`,{title:'Welcome',body:'Read the rules'},admin);
      assert.equal(pinned.status, 201, JSON.stringify(pinned.body));
      assert.equal((await request('GET',`/communities/${inst.id}/announcements`,undefined,member)).status, 200);

      // Switching the capability off takes the tag off every past post at once.
      assert.equal((await request('POST',`/admin/communities/${inst.id}/entitlements/moderator_badge/revoke`,{note:'Contract ended'},owner,adminToken)).status, 200);
      const feed = await request('GET',`/communities/${inst.id}/posts`,undefined,member);
      assert.ok(feed.body.posts.length >= 2);
      assert.ok(feed.body.posts.every((p: any) => p.author_badge === null));
      // And a normal community cannot be given tags at all.
      assert.equal((await request('POST',`/admin/communities/${normal}/badges`,{user_id:owner,note:'x'},owner,adminToken)).body.code, 'capability_required');
    });
    await t.test('KYC: only a passed application can be approved, and review is admin-only', async () => {
      const kycUser = outsider;
      await query(`insert into host_verifications (user_id, status, legal_name, pan_last4, pan_valid)
                   values ($1, 'pending_review', 'Fixture Host', '234F', true)`, [kycUser]);
      // No payout vendor yet: approving must be impossible, whatever the admin clicks.
      assert.equal((await request('POST',`/admin/kyc/${kycUser}/approve`,{},owner,adminToken)).status, 409);
      await query(`update host_verifications set cashfree_vendor_id = $2 where user_id = $1`, [kycUser, 'vh_fixture']);
      assert.equal((await request('POST',`/admin/kyc/${kycUser}/approve`,{},owner,moderatorToken)).status, 403);
      assert.equal((await request('POST',`/admin/kyc/${kycUser}/approve`,{},owner,adminToken)).status, 200);
      const queue = await request('GET',`/admin/kyc?status=verified`,undefined,owner,moderatorToken);
      assert.ok(queue.body.verifications.some((v: any) => v.user_id === kycUser));
      // The schema itself refuses a verified row without a passing check, not just the route.
      await assert.rejects(query(`update host_verifications set pan_valid = false where user_id = $1`, [kycUser]));
      assert.equal((await request('POST',`/admin/kyc/${kycUser}/reject`,{reason:'no'},owner,adminToken)).status, 400);
      assert.equal((await request('POST',`/admin/kyc/${kycUser}/reject`,{reason:'Name on PAN does not match'},owner,adminToken)).status, 200);
      // A document that was never confirmed as uploaded is never viewable.
      const doc = randomUUID();
      await query(`insert into kyc_documents (id, user_id, kind, r2_key, mime) values ($1,$2,'pan_card',$3,'image/jpeg')`,
                  [doc, kycUser, `kyc/${kycUser}/${doc}.jpg`]);
      assert.equal((await request('GET',`/admin/kyc/${kycUser}`,undefined,owner,adminToken)).body.documents.length, 0);
      await query(`delete from host_verifications where user_id = $1`, [kycUser]);
    });
    await t.test('member cannot edit settings or grant themselves a role', async () => {
      assert.equal((await request('POST',`/communities/${community}/join`,{},member)).status,200);
      assert.equal((await request('PATCH',`/communities/${community}`,{name:'hijacked'},member)).status,403);
      assert.equal((await request('POST',`/communities/${community}/members/${member}/role`,{role:'admin'},member)).status,403);
      assert.equal((await request('POST',`/communities/${community}/posts`,{body:'not allowed'},member)).status,403);
    });
    await t.test('membership wake-up reaches the owner with the conversation field iOS requires', async () => {
      for (let i=0;i<20 && !notices.some(n=>n.body.community_id===community);i++) await new Promise(r=>setTimeout(r,10));
      const notice = notices.find(n=>n.channel===`channel:user:${owner}` && n.body.community_id===community);
      assert.ok(notice); assert.equal(notice.body.type,'mls_event');
      assert.ok(notice.body.conversation_ids.includes(notice.body.conversation_id));
      assert.ok(notice.body.conversation_id);
    });
    await t.test('member invitation toggle is enforced; invitation gives membership only', async () => {
      const invite = await request('POST',`/communities/${community}/invites`,{max_uses:1},member);
      assert.equal(invite.status,201,JSON.stringify(invite.body));
      assert.equal((await request('POST',`/communities/${community}/join`,{invite_token:invite.body.invite.token},outsider)).status,200);
      assert.equal((await query(`select role from community_members where community_id=$1 and user_id=$2`,[community,outsider]))[0].role,'member');
      assert.equal((await request('GET',`/communities/invites/${invite.body.invite.token}`,undefined,admin)).status,404);
      await request('PATCH',`/communities/${community}`,{members_can_invite:false});
      assert.equal((await request('POST',`/communities/${community}/invites`,{},member)).status,403);
    });
    await t.test('invitation cannot bypass approval; revoked links cannot be redeemed', async () => {
      const invite = await request('POST',`/communities/${approval}/invites`,{max_uses:5});
      const join = await request('POST',`/communities/${approval}/join`,{invite_token:invite.body.invite.token},member);
      assert.equal(join.body.state,'pending');
      assert.equal((await request('GET',`/communities/${approval}/channels`,undefined,member)).status,403);
      await request('DELETE',`/communities/${approval}/invites/${invite.body.invite.token}`);
      assert.equal((await request('POST',`/communities/${approval}/join`,{invite_token:invite.body.invite.token},outsider)).status,400);
    });
    await t.test('leaving and rejoining cannot resurrect administrator rights', async () => {
      await request('POST',`/communities/${community}/members/${member}/role`,{role:'admin'});
      await request('POST',`/communities/${community}/leave`,{},member);
      await request('POST',`/communities/${community}/join`,{},member);
      assert.equal((await query(`select role from community_members where community_id=$1 and user_id=$2`,[community,member]))[0].role,'member');
      assert.ok((await query(`select role from conversation_members where user_id=$1 and conversation_id in (select conversation_id from community_channels where community_id=$2)`,[member,community])).every(r=>r.role==='member'));
    });
    await t.test('admins cannot remove peer admins or owners; bans prevent rejoining', async () => {
      await request('POST',`/communities/${community}/join`,{},admin);
      for (const uid of [member,admin]) await request('POST',`/communities/${community}/members/${uid}/role`,{role:'admin'});
      assert.equal((await request('POST',`/communities/${community}/members/${admin}/remove`,{},member)).status,403);
      assert.equal((await request('POST',`/communities/${community}/members/${owner}/ban`,{},member)).status,400);
      await request('POST',`/communities/${community}/members/${outsider}/ban`,{});
      assert.equal((await request('POST',`/communities/${community}/join`,{},outsider)).status,403);
    });
    await t.test('official admin controls are authenticated, scoped and cannot dispatch arbitrary paths', async () => {
      const payload = {method:'POST',path:'posts',payload:{body:'Official post'}};
      assert.equal((await request('POST',`/admin/communities/${community}/manage`,payload)).status,401);
      assert.equal((await request('POST',`/admin/communities/${community}/manage`,payload,owner,moderatorToken)).status,403);
      assert.equal((await request('POST',`/admin/communities/${normal}/manage`,payload,owner,adminToken)).status,403);
      assert.equal((await request('POST',`/admin/communities/${community}/manage`,{...payload,path:'../users'},owner,adminToken)).status,400);
      const posted = await request('POST',`/admin/communities/${community}/manage`,payload,owner,adminToken);
      assert.equal(posted.status,201,JSON.stringify(posted.body)); assert.equal(posted.body.post.author_id,owner);
      const rules = await request('POST',`/admin/communities/${community}/manage`,{method:'GET',path:'rules'},owner,adminToken);
      assert.equal(rules.status,200,JSON.stringify(rules.body));
      assert.ok((await query(`select id from admin_audit_log where admin_id=$1 and action='official_community_action'`,[adminId])).length>=2);
    });
    await t.test('only owner device coordinates MLS; batches are idempotent and ordered', async () => {
      assert.equal((await request('POST','/communities/channel-sync',{device_id:device},member,undefined,memberDevice)).status,403);
      const sync = await request('POST','/communities/channel-sync',{device_id:device},owner,undefined,device);
      assert.equal(sync.status,200,JSON.stringify(sync.body)); assert.ok(sync.body.channels.length>=2);
      const other = await request('POST','/communities/channel-sync',{device_id:secondDevice},owner,undefined,secondDevice);
      assert.equal(other.body.channels.length,0);
      const cid = sync.body.channels[0].conversation_id;
      const bid = randomUUID();
      const batch = {device_id:device,conversation_id:cid,batch_id:bid,group_id:'dGVzdGdyb3Vw',events:[
        {recipient_user_id:member,recipient_device_id:memberDevice,kind:'welcome',payload:'d2VsY29tZQ==',ratchet_tree:'dHJlZQ=='},
        {recipient_user_id:member,recipient_device_id:memberDevice,kind:'commit',payload:'Y29tbWl0'},
      ]};
      // Pick a Space in the community where the member actually joined.
      batch.conversation_id = (await query(`select conversation_id from community_channels where community_id=$1 order by position limit 1`,[community]))[0].conversation_id;
      for (let i=0;i<2;i++) assert.equal((await request('POST','/communities/channel-events',batch,owner,undefined,device)).status,200);
      assert.equal((await query('select count(*)::int n from mls_group_events where conversation_id=$1',[batch.conversation_id]))[0].n,2);
      const wrong = await request('POST','/communities/channel-events',{...batch,device_id:secondDevice,batch_id:randomUUID()},owner,undefined,secondDevice);
      assert.equal(wrong.status,403);
      assert.equal((await request('POST','/mls/group-events',{conversation_id:batch.conversation_id,events:[]},member)).status,403);
      const first = await request('GET',`/mls/group-events?ack=explicit&device_id=${memberDevice}`,undefined,member,undefined,memberDevice);
      assert.equal(first.status,200,JSON.stringify(first.body)); assert.deepEqual(first.body.events.map((e:any)=>e.kind),['welcome','commit']);
      assert.ok(first.body.events.every((e:any)=>e.device_targeted === true));
      const sibling = await request('GET',`/mls/group-events?ack=explicit&device_id=${memberSibling}`,undefined,member,undefined,memberSibling);
      assert.equal(sibling.body.events.length,0,'another device must not receive commits before its own welcome');
      const retry = await request('GET',`/mls/group-events?ack=explicit&device_id=${memberDevice}`,undefined,member,undefined,memberDevice);
      assert.equal(retry.body.events.length,2);
      await request('POST','/mls/group-events/ack',{device_id:memberDevice,event_ids:first.body.events.map((e:any)=>e.id)},member,undefined,memberDevice);
      assert.equal((await request('GET',`/mls/group-events?ack=explicit&device_id=${memberDevice}`,undefined,member,undefined,memberDevice)).body.events.length,0);
      assert.equal((await request('POST',`/conversations/${batch.conversation_id}/members`,{user_ids:[outsider]},owner)).status,403);
    });
    await t.test('retrying one unready device cannot drain another device’s key packages', async () => {
      await query('insert into mls_key_packages(user_id,device_id,key_package) values($1,$2,$3)',[member,memberDevice,Buffer.from('phone package')]);
      const readiness = await request('POST','/communities/channel-sync',{device_id:device},owner,undefined,device);
      const devices = readiness.body.channels.flatMap((c:any)=>c.devices);
      assert.ok(devices.some((d:any)=>d.device_id===memberDevice && d.key_packages_available));
      assert.ok(devices.some((d:any)=>d.device_id===memberSibling && !d.key_packages_available));
      const count = await request('GET',`/mls/keypackages/count?device_id=${memberDevice}`,undefined,member);
      assert.equal(count.status,200); assert.equal(count.body.available,1);
      for (let i=0;i<3;i++) assert.equal((await request('GET',`/mls/keypackages/${member}?device_id=${memberSibling}`)).status,409);
      assert.equal((await query('select count(*)::int n from mls_key_packages where device_id=$1 and consumed_at is null',[memberDevice]))[0].n,1);
      const fetched = await request('GET',`/mls/keypackages/${member}?device_id=${memberDevice}`);
      assert.equal(fetched.status,200); assert.equal(fetched.body.key_packages.length,1);
      assert.equal(fetched.body.key_packages[0].device_id,memberDevice);
      assert.equal(fetched.body.device_count,1); assert.equal(fetched.body.partial,false);
    });
    await t.test('private communities stay out of search; suspension freezes every channel', async () => {
      await request('PATCH',`/communities/${community}`,{discoverable:false});
      const search = await request('GET',`/communities/search?q=${prefix}`,undefined,outsider);
      assert.ok(!search.body.communities.some((r:any)=>r.id===community));
      await query('update communities set suspended_at=now() where id=$1',[community]);
      assert.equal((await request('PATCH',`/communities/${community}`,{name:'frozen'})).status,403);
      const cid = (await query(`select conversation_id from community_channels where community_id=$1 and kind='chat'`,[community]))[0].conversation_id;
      const reason = await load(resolve(root,'communityGuard.ts')).announcementPostDeniedReason(cid,owner);
      assert.ok(reason);
      await query('update communities set suspended_at=null where id=$1',[community]);
    });
    await t.test('official member search is authenticated and cannot manage normal communities', async () => {
      assert.equal((await request('GET',`/admin/communities/${community}/manage-members?q=${prefix}0`)).status,401);
      assert.equal((await request('GET',`/admin/communities/${community}/manage-members?q=${prefix}0`,undefined,owner,moderatorToken)).status,403);
      assert.equal((await request('GET',`/admin/communities/${normal}/manage-members?q=${prefix}0`,undefined,owner,adminToken)).status,403);
      const result = await request('GET',`/admin/communities/${community}/manage-members?q=${prefix}0`,undefined,owner,adminToken);
      assert.equal(result.status,200); assert.equal(result.body.members[0].user_id,owner);
    });
    await t.test('post edits are author-bound and deletion needs owner and exact confirmation', async () => {
      const post = await request('POST',`/communities/${community}/posts`,{body:'original'});
      const path = `posts/${post.body.post.id}`;
      assert.equal((await request('PATCH',`/communities/${community}/${path}`,{body:'forged'},member)).status,404);
      assert.equal((await request('POST',`/admin/communities/${community}/manage`,{method:'PATCH',path,payload:{body:'edited'}},owner,adminToken)).status,200);
      assert.equal((await query('select body from community_posts where id=$1',[post.body.post.id]))[0].body,'edited');
      assert.equal((await request('DELETE',`/communities/${normal}`,{confirm_name:'Fixture normal'},member)).status,403);
      assert.equal((await request('DELETE',`/communities/${normal}`,{confirm_name:'wrong'})).status,400);
      assert.equal((await request('POST',`/admin/communities/${normal}/manage`,{method:'DELETE',path:'',payload:{confirm_name:'Fixture normal'}},owner,adminToken)).status,403);
    });
    await t.test('reset removes community conversations and data while preserving unrelated chats', async () => {
      const unrelated = (await query(`insert into conversations(type,name,created_by) values('group','unrelated',$1) returning id`,[owner]))[0].id;
      const client = await pool.connect();
      try {
        await client.query('begin');
        const result = await load(resolve(root,'communityDeletion.ts')).purgeCommunityData(client,[community]);
        assert.equal(result.communities,1);
        assert.equal((await client.query('select id from communities where id=$1',[community])).rowCount,0);
        assert.equal((await client.query('select id from conversations where id=$1',[unrelated])).rowCount,1);
        await client.query('rollback');
      } finally { client.release(); }
      await query('delete from conversations where id=$1',[unrelated]);
    });
    await t.test('official admin deletion removes the container and backing chats', async () => {
      const name = (await query('select name from communities where id=$1',[community]))[0].name;
      const channels = (await query('select conversation_id from community_channels where community_id=$1',[community])).map(r=>r.conversation_id);
      const deleted = await request('POST',`/admin/communities/${community}/manage`,{method:'DELETE',path:'',payload:{confirm_name:name}},owner,adminToken);
      assert.equal(deleted.status,200,JSON.stringify(deleted.body));
      assert.equal((await query('select id from conversations where id=any($1::uuid[])',[channels])).length,0);
      assert.equal((await query('select id from communities where id=$1',[normal])).length,1);
    });
  } finally {
    const client=await pool.connect();
    try {await client.query('begin'); await load(resolve(root,'communityDeletion.ts')).purgeCommunityData(client,[community,normal,approval]); await client.query('commit');}
    catch(e){await client.query('rollback'); throw e;} finally{client.release();}
    await query('delete from users where id=any($1::uuid[])',[users]);
    await query('delete from admin_users where id=any($1::uuid[])',[[adminId,moderatorId]]);
    await new Promise<void>(r=>server.close(()=>r())); await pool.end();
  }
});
