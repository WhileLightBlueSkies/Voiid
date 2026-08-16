// ═══════════════════════════════════════════════════════════════════════════════════
// GUARD TESTS: A SHARED CALL MUST NEVER CREATE A MESSAGING EDGE.
//
// This file is the reason the conference feature can be refactored safely. The product
// requirement is one sentence:
//
//   From a live 1:1 call you can add a third person. If that person is UNKNOWN to the
//   other participant, they see only an @username — and to contact them afterwards they
//   must still pass the 6-digit contact-PIN gate. A SHARED CALL GRANTS NO MESSAGING
//   RIGHTS.
//
// The cheap way to build "add a third person" is to create a group conversation with all
// three in it. That is the ONE implementation that is forbidden, because a conversation
// row IS the messaging right (020_reachability.sql) — and it is also the implementation a
// future refactor will drift back towards, because it is less code. So the invariant is
// asserted here rather than left to review:
//
//   1. No route under /calls ever INSERTs into or UPDATEs `conversations` /
//      `conversation_members`. Proved twice: statically over the source, and dynamically
//      over every SQL statement a real escalation actually executes.
//   2. After a FULL simulated escalation that puts a stranger in a call with someone, a
//      reachability request from that stranger to that someone STILL demands the PIN and
//      STILL lands as `pending`. The call changed nothing.
//   3. Nothing in reachability / conversations / messages reads `call_participants` or
//      `calls` to authorize anything — the reverse direction of the same leak.
//
// Plus unit coverage of the Redis ring grant, which is a wire format shared with a second
// service (the WS relay parses exactly these bytes) and therefore cannot be allowed to
// drift silently.
// ═══════════════════════════════════════════════════════════════════════════════════
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'fs';
import path from 'path';
import http from 'http';
import express from 'express';
import bcrypt from 'bcryptjs';

import {
  adhocRoomName,
  isAdhocRoomName,
  buildLiveKitCallGrant,
  callGrantAllows,
  callIdentity,
  decodeCallGrant,
  encodeCallGrant,
  isActiveParticipantState,
  ADHOC_ROOM_PREFIX,
  CALL_GRANT_VERSION,
  CONFERENCE_GRANT_TTL_SECONDS,
  MAX_CALL_PARTICIPANTS,
} from '../src/callConference';

const SRC = path.join(__dirname, '..', 'src');
const read = (rel: string) => readFileSync(path.join(SRC, rel), 'utf8');

// SQL comparison is done on a normalized copy: lower-cased, comments stripped, runs of
// whitespace collapsed. Without that, `insert\n  into  conversations` slips past a regex
// written for `insert into conversations`.
function normalizeSql(text: string): string {
  return text
    .replace(/--[^\n]*/g, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .toLowerCase()
    .replace(/\s+/g, ' ');
}

/**
 * Every way to WRITE the two tables that constitute a messaging right.
 *
 * `conversations?` covers both table names; the trailing boundary stops
 * `conversation_members` from being missed and stops `conversations_backup` from being a
 * false negative. If you are adding a legitimate new write to these tables somewhere,
 * it does not belong in the call path — that is the point.
 */
const CONVERSATION_WRITE_PATTERNS: RegExp[] = [
  /insert\s+into\s+conversations\b/,
  /insert\s+into\s+conversation_members\b/,
  /update\s+conversations\b/,
  /update\s+conversation_members\b/,
  /delete\s+from\s+conversations\b/,
  /delete\s+from\s+conversation_members\b/,
];

// ─────────────────────────────────────────────────────────────────────────────────
// 1. STATIC GUARD — the call path contains no write to a conversation table.
// ─────────────────────────────────────────────────────────────────────────────────

/** Every source file that participates in serving a /calls request. */
const CALL_PATH_FILES = [
  'routes/calls.ts',
  'callConference.ts',
  'callMetrics.ts',
  'turn.ts',
];

test('no file in the call path writes to conversations or conversation_members', () => {
  for (const rel of CALL_PATH_FILES) {
    const sql = normalizeSql(read(rel));
    for (const pattern of CONVERSATION_WRITE_PATTERNS) {
      assert.equal(
        pattern.test(sql),
        false,
        `${rel} matches ${pattern}. A shared call grants no messaging rights: the call path ` +
          `may READ conversation membership to answer "may A reach B", but writing a ` +
          `conversation or a membership row creates the messaging edge the contact-PIN gate ` +
          `in 020_reachability.sql exists to withhold. Keep call state in call_participants.`
      );
    }
  }
});

test('the call path still READS conversation membership (the reachability gate is inherited, not reimplemented)', () => {
  // The inverse failure mode of the test above: someone "fixes" the guard by deleting the
  // reads too, and the call path silently stops enforcing 020 at all. Ringing and inviting
  // must both resolve to "do these two share an accepted relationship".
  const calls = normalizeSql(read('routes/calls.ts'));
  assert.match(calls, /from conversation_members/, 'calls.ts must still check membership');
  assert.match(calls, /contact_sync/, 'escalate must still check the mutual-contact path');
});

// ─────────────────────────────────────────────────────────────────────────────────
// 3. STATIC GUARD (reverse direction) — nothing that decides messaging reads call state.
//
// The leak has two ends. The other one is subtler and would look like a feature: "they
// were in a call with me, so let them message me". That is a fourth path to reachability
// and 020 has exactly three.
// ─────────────────────────────────────────────────────────────────────────────────
const MESSAGING_AUTHORITY_FILES = [
  'routes/reachability.ts',
  'routes/conversations.ts',
  'routes/messages.ts',
  'routes/contacts.ts',
  'routes/users.ts',
];

test('nothing in the messaging/reachability path reads call_participants or calls', () => {
  for (const rel of MESSAGING_AUTHORITY_FILES) {
    const sql = normalizeSql(read(rel));
    assert.equal(
      /call_participants/.test(sql),
      false,
      `${rel} references call_participants. Sharing a call is NOT a reachability edge ` +
        `(029: "FOLLOWING ADDS NO FOURTH PATH" — same rule). Reading call membership to ` +
        `decide whether a message, request or conversation is allowed bypasses the ` +
        `6-digit PIN gate and breaks the product requirement.`
    );
    assert.equal(
      /\bfrom calls\b|\bjoin calls\b/.test(sql),
      false,
      `${rel} reads the calls table. Call history must not influence who may message whom.`
    );
  }
});

// ─────────────────────────────────────────────────────────────────────────────────
// THE RING GRANT — wire format shared with backend/websocket.
// ─────────────────────────────────────────────────────────────────────────────────

const A = '11111111-1111-4111-8111-111111111111'; // original caller
const B = '22222222-2222-4222-8222-222222222222'; // original callee (Ana's friend)
const C = '33333333-3333-4333-8333-333333333333'; // the invited stranger
const D = '44444444-4444-4444-8444-444444444444'; // someone not on the call
const CALL = '55555555-5555-4555-8555-555555555555';
const CONV = '66666666-6666-4666-8666-666666666666';
const DEV_A = '77777777-7777-4777-8777-777777777777';

test('room is named for the CALL, never for a conversation', () => {
  assert.equal(adhocRoomName(CALL), `voiid-call-${CALL}`);
  assert.equal(ADHOC_ROOM_PREFIX, 'voiid-call-');
  assert.ok(isAdhocRoomName(adhocRoomName(CALL)));
  // `voiid-<conversation_id>` is the group-call room. It must NOT be recognised here:
  // that room is authorized by conversation membership, which is the messaging right.
  assert.equal(isAdhocRoomName(`voiid-${CONV}`), false);
});

test('grant names N participants and stays backward compatible with the {a,b} pair', () => {
  const raw = encodeCallGrant([A, B, C], [A, B]);
  const g = decodeCallGrant(raw)!;
  assert.deepEqual(g.p, [A, B, C]);
  assert.equal(g.v, CALL_GRANT_VERSION);
  // a/b keep naming the ORIGINAL 1:1 pair so the still-standing 1:1 leg keeps relaying
  // during make-before-break, including on a relay build that only understands the pair.
  assert.equal(g.a, A);
  assert.equal(g.b, B);
});

test('a v1 pair-only grant still authorizes its two parties', () => {
  const legacy = JSON.stringify({ a: A, b: B });
  assert.equal(callGrantAllows(legacy, A, B), true);
  assert.equal(callGrantAllows(legacy, B, A), true);
  assert.equal(callGrantAllows(legacy, A, C), false);
});

test('grant authorizes every pair among participants and nobody else', () => {
  const raw = encodeCallGrant([A, B, C], [A, B]);
  for (const [from, to] of [[A, B], [B, A], [A, C], [C, A], [B, C], [C, B]]) {
    assert.equal(callGrantAllows(raw, from, to), true, `${from} -> ${to} should relay`);
  }
  assert.equal(callGrantAllows(raw, A, D), false, 'a non-participant must not be reachable');
  assert.equal(callGrantAllows(raw, D, A), false, 'a non-participant must not be able to signal');
  assert.equal(callGrantAllows(raw, A, A), false, 'self-addressed frames are refused');
});

test('grant fails CLOSED on absent or corrupt values', () => {
  assert.equal(callGrantAllows(null, A, B), false);
  assert.equal(callGrantAllows('', A, B), false);
  assert.equal(callGrantAllows('not json', A, B), false);
  assert.equal(callGrantAllows('{}', A, B), false);
  assert.equal(callGrantAllows(JSON.stringify({ a: A }), A, B), false);
  assert.equal(decodeCallGrant('[1,2,3]'), null);
});

test('grant deduplicates so a rejoin cannot inflate the participant list', () => {
  const g = decodeCallGrant(encodeCallGrant([A, B, A, C, B]))!;
  assert.deepEqual(g.p, [A, B, C]);
});

test('a leaver drops out of the grant', () => {
  const before = encodeCallGrant([A, B, C], [A, B]);
  assert.equal(callGrantAllows(before, B, C), true);
  const after = encodeCallGrant([A, B], [A, B]); // C left
  assert.equal(callGrantAllows(after, B, C), false);
  assert.equal(callGrantAllows(after, A, B), true, 'the 1:1 leg survives the leave');
});

test('the conference grant outlives a ring, because a call does', () => {
  assert.ok(
    CONFERENCE_GRANT_TTL_SECONDS >= 3600,
    'a 120s ring-sized TTL would stop relaying hangup/ICE mid-conversation'
  );
});

test('participant states gate the token exactly as the roster does', () => {
  assert.equal(isActiveParticipantState('invited'), true);
  assert.equal(isActiveParticipantState('joined'), true);
  assert.equal(isActiveParticipantState('left'), false);
  assert.equal(isActiveParticipantState('anything-else'), false);
});

test('the LiveKit token asserts NO display name', () => {
  const grant = buildLiveKitCallGrant({
    apiKey: 'devkey',
    identity: callIdentity(A, DEV_A),
    room: adhocRoomName(CALL),
    ttlSeconds: 3600,
    nowSeconds: 1_700_000_000,
  });
  // A `name` claim would push the server's idea of who you are into a room containing
  // someone who has not passed your PIN gate. Identity is resolved viewer-side.
  assert.equal((grant as any).name, undefined);
  assert.equal(Object.keys(grant).sort().join(','), 'exp,iss,nbf,sub,video');
  assert.equal(grant.video.room, `voiid-call-${CALL}`);
  // Per-DEVICE identity: LiveKit evicts a duplicate identity, which would kick the user's
  // other device out of the call.
  assert.equal(grant.sub, `${A}:${DEV_A}`);
  assert.equal(grant.exp, 1_700_003_600);
});

test('room size is capped, because every membership change re-keys', () => {
  assert.ok(MAX_CALL_PARTICIPANTS >= 3, 'escalation needs at least three seats');
  assert.ok(MAX_CALL_PARTICIPANTS <= 16, 'an ad-hoc call is not a broadcast');
});

// ═══════════════════════════════════════════════════════════════════════════════════
// 2. THE FULL SIMULATED ESCALATION.
//
// The real express routers, the real SQL strings, the real order of operations — run
// against an in-memory store that stands in for Postgres and records every statement.
// Then, with the conference in place, the stranger tries to message the peer.
// ═══════════════════════════════════════════════════════════════════════════════════

// Imported AFTER the pure tests so the module-level pg Pool / ioredis clients are created
// as late as possible; both are neutralised immediately below.
import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { issueToken } from '../src/auth';
import callsRouter from '../src/routes/calls';
import reachabilityRouter from '../src/routes/reachability';

// ioredis connects on construction and retries forever, which would hold the test process
// open. Disconnect the sockets and replace the two methods the routes use.
redis.disconnect();
publisher.disconnect();

interface Row { [k: string]: any }

const db = {
  users: [] as Row[],
  conversations: [] as Row[],
  conversation_members: [] as Row[],
  contact_sync: [] as Row[],
  calls: [] as Row[],
  call_participants: [] as Row[],
  devices: [] as Row[],
  contact_pin_attempts: [] as Row[],
  user_blocks: [] as Row[],
};

/** Every statement executed since the last reset — the dynamic half of guard (1). */
let sqlLog: string[] = [];
const redisStore = new Map<string, string>();

function resetDb() {
  for (const k of Object.keys(db) as (keyof typeof db)[]) db[k] = [];
  sqlLog = [];
  redisStore.clear();
}

const now = () => new Date().toISOString();

/**
 * A deliberately small SQL interpreter: it matches each statement the routes issue by a
 * distinctive fragment and answers it from the in-memory tables. Anything unrecognised
 * THROWS — a silent `[]` would let a future query slip through the simulation unexercised,
 * which is exactly the failure mode this file exists to prevent.
 */
async function fakeQuery(text: string, params: any[] = []): Promise<{ rows: Row[] }> {
  const s = normalizeSql(text);
  sqlLog.push(s);
  const p = params ?? [];
  const rows = (r: Row[]) => ({ rows: r });

  // ── transaction control (reachability opens one to create a conversation)
  if (s === 'begin' || s === 'commit' || s === 'rollback') return rows([]);

  // ── auth: account liveness (only reached if the redis cache misses)
  if (s.includes('deleted_at is null) as ok from users')) {
    const u = db.users.find((x) => x.id === p[0]);
    return rows(u ? [{ ok: !u.deleted_at }] : []);
  }

  // ── calls.ts: loadCall
  if (s.startsWith('select id, conversation_id, caller_user_id, call_kind, status from calls')) {
    return rows(db.calls.filter((c) => c.id === p[0]));
  }

  // ── calls.ts: isLiveCallParticipant
  if (s.includes('as ok') && s.includes('call_participants') && s.includes('conversation_members')) {
    const [callId, userId, convId] = p;
    const live = db.call_participants.some(
      (cp) => cp.call_id === callId && cp.user_id === userId && cp.state !== 'left'
    );
    const member = db.conversation_members.some(
      (m) => m.conversation_id === convId && m.user_id === userId && !m.left_at
    );
    return rows([{ ok: live || member }]);
  }

  // ── calls.ts: invitee lookup
  if (s.startsWith('select id, username from users where id =')) {
    return rows(db.users.filter((u) => u.id === p[0] && !u.deleted_at).map((u) => ({ id: u.id, username: u.username })));
  }

  // ── calls.ts: canReachForCall
  if (s.includes('a_saved_b')) {
    const [a, b] = p;
    const saved = (o: string, c: string) => db.contact_sync.some((r) => r.owner_user_id === o && r.contact_user_id === c);
    const acceptedConv = db.conversation_members.some((m1) =>
      m1.user_id === a && !m1.left_at && m1.request_state === 'accepted' &&
      db.conversation_members.some((m2) =>
        m2.conversation_id === m1.conversation_id && m2.user_id === b && !m2.left_at && m2.request_state === 'accepted'
      )
    );
    return rows([{ a_saved_b: saved(a, b), b_saved_a: saved(b, a), accepted_conv: acceptedConv }]);
  }

  // ── calls.ts: seedOriginalParticipants
  if (s.startsWith("insert into call_participants (call_id, user_id, state, state_changed_at) select")) {
    const [callId, convId] = p;
    if (db.call_participants.some((cp) => cp.call_id === callId)) return rows([]);
    for (const m of db.conversation_members.filter((m) => m.conversation_id === convId && !m.left_at)) {
      db.call_participants.push({
        call_id: callId, user_id: m.user_id, device_id: null, state: 'joined',
        invited_by: null, joined_at: now(), left_at: null, state_changed_at: now(),
      });
    }
    return rows([]);
  }

  // ── calls.ts: upsert self as joined
  if (s.startsWith('insert into call_participants (call_id, user_id, device_id, state, state_changed_at)')) {
    const [callId, userId, deviceId] = p;
    const cp = db.call_participants.find((r) => r.call_id === callId && r.user_id === userId);
    if (cp) Object.assign(cp, { state: 'joined', device_id: deviceId ?? cp.device_id, left_at: null, state_changed_at: now() });
    else db.call_participants.push({
      call_id: callId, user_id: userId, device_id: deviceId, state: 'joined',
      invited_by: null, joined_at: now(), left_at: null, state_changed_at: now(),
    });
    return rows([]);
  }

  // ── calls.ts: upsert invitee as invited
  if (s.startsWith('insert into call_participants (call_id, user_id, state, invited_by, state_changed_at)')) {
    const [callId, userId, invitedBy] = p;
    const cp = db.call_participants.find((r) => r.call_id === callId && r.user_id === userId);
    if (cp) Object.assign(cp, {
      state: cp.state === 'joined' ? 'joined' : 'invited',
      invited_by: cp.invited_by ?? invitedBy, left_at: null, state_changed_at: now(),
    });
    else db.call_participants.push({
      call_id: callId, user_id: userId, device_id: null, state: 'invited',
      invited_by: invitedBy, joined_at: now(), left_at: null, state_changed_at: now(),
    });
    return rows([]);
  }

  // ── calls.ts: join / leave transitions
  if (s.startsWith('update call_participants set state =')) {
    const joining = s.includes("set state = 'joined'");
    const [callId, userId, deviceId] = p;
    const cp = db.call_participants.find((r) => r.call_id === callId && r.user_id === userId && r.state !== 'left');
    if (!cp) return rows([]);
    if (joining) Object.assign(cp, { state: 'joined', device_id: deviceId ?? cp.device_id, left_at: null, state_changed_at: now() });
    else Object.assign(cp, { state: 'left', left_at: now(), state_changed_at: now() });
    return rows([{ user_id: cp.user_id, state: cp.state }]);
  }

  // ── calls.ts: liveParticipantIds
  if (s.startsWith('select user_id from call_participants')) {
    return rows(db.call_participants.filter((cp) => cp.call_id === p[0] && cp.state !== 'left').map((cp) => ({ user_id: cp.user_id })));
  }

  // ── calls.ts: original peer, for the legacy a/b pair in the grant
  if (s.startsWith('select user_id from conversation_members')) {
    const [convId, notUser] = p;
    return rows(
      db.conversation_members
        .filter((m) => m.conversation_id === convId && m.user_id !== notUser && !m.left_at)
        .slice(0, 1)
        .map((m) => ({ user_id: m.user_id }))
    );
  }

  // ── calls.ts: adhoc-token gate
  if (s.startsWith('select state from call_participants')) {
    return rows(
      db.call_participants
        .filter((cp) => cp.call_id === p[0] && cp.user_id === p[1] && cp.state !== 'left')
        .map((cp) => ({ state: cp.state }))
    );
  }

  // ── calls.ts: roster
  if (s.includes('select cp.user_id, u.username, cp.state, cp.invited_by')) {
    return rows(
      db.call_participants
        .filter((cp) => cp.call_id === p[0] && cp.state !== 'left')
        .map((cp) => ({
          user_id: cp.user_id,
          username: db.users.find((u) => u.id === cp.user_id)?.username ?? null,
          state: cp.state,
          invited_by: cp.invited_by ?? null,
        }))
    );
  }

  // ── calls.ts: push targets
  if (s.includes('from devices')) {
    return rows(db.devices.filter((d) => d.user_id === p[0] && !d.revoked_at));
  }

  // ── calls.ts: last-one-out ends the call record
  if (s.startsWith('update calls set status =')) {
    const c = db.calls.find((x) => x.id === p[0]);
    if (c && (c.status === 'ringing' || c.status === 'connected')) {
      Object.assign(c, { status: 'ended', ended_at: now(), end_reason: c.end_reason ?? 'hangup' });
    }
    return rows([]);
  }

  // ── reachability.ts: resolve @username (+ pin columns)
  if (s.includes('from users where lower(username) =')) {
    const u = db.users.find((x) => (x.username ?? '').toLowerCase() === p[0] && !x.deleted_at);
    return rows(u ? [u] : []);
  }

  // ── reachability.ts: isMutualContact
  if (s.includes('count(*)::text as n from contact_sync')) {
    const [a, b] = p;
    const n = db.contact_sync.filter(
      (r) => (r.owner_user_id === a && r.contact_user_id === b) || (r.owner_user_id === b && r.contact_user_id === a)
    ).length;
    return rows([{ n: String(n) }]);
  }

  // ── reachability.ts: PIN attempt throttle counters
  if (s.includes('from contact_pin_attempts')) {
    const [target, sender] = p;
    const mine = db.contact_pin_attempts.filter((r) => r.target_user_id === target && r.sender_user_id === sender && !r.succeeded);
    return rows([{ hour: String(mine.length), day: String(mine.length) }]);
  }
  if (s.startsWith('insert into contact_pin_attempts')) {
    db.contact_pin_attempts.push({ target_user_id: p[0], sender_user_id: p[1], sender_ip: p[2], succeeded: p[3] });
    return rows([]);
  }

  // ── reachability.ts: existing 1:1 lookup
  if (s.includes("where c.type = 'direct'")) {
    const [a, b] = p;
    const hit = db.conversations.find((c) => {
      if (c.type !== 'direct') return false;
      const members = db.conversation_members.filter((m) => m.conversation_id === c.id && !m.left_at);
      return members.length === 2 && members.some((m) => m.user_id === a) && members.some((m) => m.user_id === b);
    });
    return rows(hit ? [{ id: hit.id }] : []);
  }

  // ── reachability.ts: create the conversation (the messaging edge)
  if (s.startsWith('insert into conversations')) {
    const id = `conv-${db.conversations.length + 1}`;
    db.conversations.push({ id, type: 'direct', created_by: p[0] });
    return rows([{ id }]);
  }
  if (s.startsWith('insert into conversation_members')) {
    const [convId, sender, target, openedVia, recipientState] = p;
    db.conversation_members.push({ conversation_id: convId, user_id: sender, request_state: 'accepted', opened_via: openedVia, left_at: null, joined_at: now() });
    db.conversation_members.push({ conversation_id: convId, user_id: target, request_state: recipientState, opened_via: openedVia, left_at: null, joined_at: now() });
    return rows([]);
  }

  // ── blocking.ts: isBlockedEitherWay — a block in EITHER direction blocks the pair.
  // canReachForCall consults this before any other proof of reachability, so a blocked
  // user cannot ring a phone on the strength of a mutual contact-sync that predates
  // the block.
  if (s.includes('from user_blocks')) {
    const [a, b] = p;
    const hit = db.user_blocks.some(
      (r) =>
        (r.blocker_user_id === a && r.blocked_user_id === b) ||
        (r.blocker_user_id === b && r.blocked_user_id === a)
    );
    return rows(hit ? [{ one: 1 }] : []);
  }

  throw new Error(
    `test/callConference.test.ts: unhandled SQL in the fake database.\n  ${s}\n` +
      `Add a handler above — an unexercised statement is an unguarded statement.`
  );
}

(pool as any).query = fakeQuery;
(pool as any).connect = async () => ({ query: fakeQuery, release() {} });
// Auth's liveness cache: answer "active" so requireAuth never needs the DB for it.
(redis as any).get = async (k: string) => (k.startsWith('auth:active:') ? '1' : redisStore.get(k) ?? null);
(redis as any).set = async (k: string, v: string) => { redisStore.set(k, v); return 'OK'; };
(redis as any).del = async (k: string) => { redisStore.delete(k); return 1; };

const app = express();
app.use(express.json());
app.use('/calls', callsRouter);
app.use('/reachability', reachabilityRouter);

let server: http.Server;
let base = '';

test.before(async () => {
  await new Promise<void>((resolve) => {
    server = app.listen(0, '127.0.0.1', () => {
      base = `http://127.0.0.1:${(server.address() as any).port}`;
      resolve();
    });
  });
  process.env.LIVEKIT_URL = 'wss://livekit.test';
  process.env.LIVEKIT_API_KEY = 'test-key';
  process.env.LIVEKIT_API_SECRET = 'test-secret-at-least-32-bytes-long!!';
});

test.after(() => {
  server?.close();
});

function tokenFor(userId: string, deviceId?: string) {
  return issueToken(deviceId ? { user_id: userId, device_id: deviceId } : { user_id: userId });
}

async function call(
  method: 'GET' | 'POST',
  urlPath: string,
  actor: { user: string; device?: string },
  body?: unknown
) {
  const res = await fetch(`${base}${urlPath}`, {
    method,
    headers: {
      authorization: `Bearer ${tokenFor(actor.user, actor.device)}`,
      'content-type': 'application/json',
    },
    body: method === 'POST' ? JSON.stringify(body ?? {}) : undefined,
  });
  return { status: res.status, body: (await res.json()) as any };
}

/**
 * The scenario, in the founder's words:
 *
 *   ANA (A) and BEN (B) are on a live 1:1 call. Ana adds CARA (C) — her own contact, and a
 *   COMPLETE STRANGER to Ben. Ben and Cara now share a call.
 *
 * DAN (D) exists only to prove non-participants stay out.
 */
const PIN = '418302';
async function seedScenario() {
  resetDb();
  const pinHash = await bcrypt.hash(PIN, 10);
  db.users.push(
    { id: A, username: 'ana', full_name: 'Ana Real Name', deleted_at: null, contact_pin_hash: null, contact_pin_enc: null },
    { id: B, username: 'ben', full_name: 'Ben Real Name', deleted_at: null, contact_pin_hash: pinHash, contact_pin_enc: null },
    { id: C, username: 'cara', full_name: 'Cara Real Name', deleted_at: null, contact_pin_hash: null, contact_pin_enc: null },
    { id: D, username: 'dan', full_name: 'Dan Real Name', deleted_at: null, contact_pin_hash: null, contact_pin_enc: null }
  );
  // Ana <-> Ben: an accepted 1:1 conversation. This is the call they are on.
  db.conversations.push({ id: CONV, type: 'direct', created_by: A });
  db.conversation_members.push(
    { conversation_id: CONV, user_id: A, request_state: 'accepted', left_at: null, joined_at: now() },
    { conversation_id: CONV, user_id: B, request_state: 'accepted', left_at: null, joined_at: now() }
  );
  // Ana <-> Cara: mutual contacts. That is Ana's right to invite Cara — and ONLY Ana's.
  db.contact_sync.push(
    { owner_user_id: A, contact_user_id: C },
    { owner_user_id: C, contact_user_id: A }
  );
  db.calls.push({
    id: CALL, conversation_id: CONV, caller_user_id: A, call_kind: 'voice', status: 'connected',
    started_at: now(), answered_at: now(), ended_at: null, end_reason: null,
  });
}

test('a stranger can be added to a live 1:1 call — and no conversation row is written', async () => {
  await seedScenario();
  sqlLog = [];

  const res = await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  assert.equal(res.status, 200, JSON.stringify(res.body));

  // The room is the CALL's, not the conversation's.
  assert.equal(res.body.room, `voiid-call-${CALL}`);
  assert.notEqual(res.body.room, `voiid-${CONV}`);

  // Membership landed in call_participants — the table 014 shipped and nothing ever used.
  const roster = db.call_participants.filter((cp) => cp.call_id === CALL);
  assert.equal(roster.length, 3);
  assert.equal(roster.find((r) => r.user_id === C)!.state, 'invited');
  assert.equal(roster.find((r) => r.user_id === C)!.invited_by, A);
  assert.equal(roster.find((r) => r.user_id === A)!.state, 'joined');
  assert.equal(roster.find((r) => r.user_id === B)!.state, 'joined');

  // ── THE LOAD-BEARING ASSERTION ────────────────────────────────────────────────
  // Not one statement executed during a real escalation touched a conversation table
  // for writing, and no conversation or membership row exists beyond the two we seeded.
  for (const stmt of sqlLog) {
    for (const pattern of CONVERSATION_WRITE_PATTERNS) {
      assert.equal(pattern.test(stmt), false, `escalation executed a conversation write: ${stmt}`);
    }
  }
  assert.equal(db.conversations.length, 1, 'escalation must not create a conversation');
  assert.equal(db.conversation_members.length, 2, 'escalation must not add a membership row');
  assert.equal(db.conversation_members.some((m) => m.user_id === C), false, 'the stranger joined NO conversation');
});

test('the escalation grant lets the stranger and the peer signal, and nobody else', async () => {
  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });

  const raw = redisStore.get(`callgrant:${CALL}`) ?? null;
  assert.ok(raw, 'escalation must rewrite the ring grant');
  // Ben <-> Cara are strangers, and that is exactly the pair that must be able to
  // exchange call frames — a call is not a messaging edge, but it IS a media session.
  assert.equal(callGrantAllows(raw, B, C), true);
  assert.equal(callGrantAllows(raw, C, B), true);
  // The original 1:1 leg is still authorized (make-before-break), including for a relay
  // that only reads the legacy pair.
  const g = decodeCallGrant(raw)!;
  assert.equal(g.a, A);
  assert.equal(g.b, B);
  // Dan is not on the call.
  assert.equal(callGrantAllows(raw, A, D), false);
  assert.equal(callGrantAllows(raw, D, C), false);
});

test('the invited stranger gets an SFU token; an outsider does not', async () => {
  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });

  const mine = await call('POST', `/calls/${CALL}/adhoc-token`, { user: C, device: DEV_A });
  assert.equal(mine.status, 200, JSON.stringify(mine.body));
  assert.equal(mine.body.room, `voiid-call-${CALL}`);
  assert.equal(mine.body.identity, `${C}:${DEV_A}`);
  assert.equal(mine.body.state, 'invited');

  const outsider = await call('POST', `/calls/${CALL}/adhoc-token`, { user: D, device: DEV_A });
  assert.equal(outsider.status, 403);

  // Leaving revokes the token immediately — the gate is the row, not the JWT.
  const left = await call('POST', `/calls/${CALL}/leave`, { user: C });
  assert.equal(left.status, 200);
  const after = await call('POST', `/calls/${CALL}/adhoc-token`, { user: C, device: DEV_A });
  assert.equal(after.status, 403);
  assert.equal(callGrantAllows(redisStore.get(`callgrant:${CALL}`) ?? null, B, C), false);
});

test('the roster discloses @username and NOTHING else', async () => {
  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });

  // Ben — a stranger to Cara — asks who is in the call.
  const res = await call('GET', `/calls/${CALL}/participants`, { user: B });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const cara = res.body.participants.find((p: any) => p.user_id === C);
  assert.equal(cara.username, 'cara');
  // The private plane must not cross a shared call.
  const serialized = JSON.stringify(res.body);
  for (const leak of ['Cara Real Name', 'Ana Real Name', 'full_name', 'photo_url', 'phone']) {
    assert.equal(serialized.includes(leak), false, `roster leaked ${leak}`);
  }
  // And an outsider learns nothing at all.
  const outsider = await call('GET', `/calls/${CALL}/participants`, { user: D });
  assert.equal(outsider.status, 403);
});

test('only a participant may escalate, and only to someone THEY can reach', async () => {
  await seedScenario();
  // Dan is on nobody's call.
  const outsider = await call('POST', `/calls/${CALL}/escalate`, { user: D, device: DEV_A }, { invitee_user_id: C });
  assert.equal(outsider.status, 403);

  // Ben IS on the call, but has no relationship with Cara — he cannot pull her in. The
  // invite right is the inviter's own 020 reachability, never the call's.
  const noRight = await call('POST', `/calls/${CALL}/escalate`, { user: B, device: DEV_A }, { invitee_user_id: C });
  assert.equal(noRight.status, 403);

  // Ana can, because Ana and Cara are mutual contacts.
  const ok = await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  assert.equal(ok.status, 200);

  // ...and being IN the call still does not give Ben the right to add Dan, whom he does
  // not know: sharing a call with Ana does not inherit Ana's contacts.
  const stillNo = await call('POST', `/calls/${CALL}/escalate`, { user: B, device: DEV_A }, { invitee_user_id: D });
  assert.equal(stillNo.status, 403);
});

test('a pending message request is NOT enough to pull someone into a call', async () => {
  await seedScenario();
  // Ana sent Dan a request that Dan never accepted.
  db.conversations.push({ id: 'conv-pending', type: 'direct', created_by: A });
  db.conversation_members.push(
    { conversation_id: 'conv-pending', user_id: A, request_state: 'accepted', left_at: null, joined_at: now() },
    { conversation_id: 'conv-pending', user_id: D, request_state: 'pending', left_at: null, joined_at: now() }
  );
  const res = await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: D });
  assert.equal(res.status, 403, 'an unanswered request must not become a ringing channel');
});

// ═══════════════════════════════════════════════════════════════════════════════════
// THE REQUIREMENT ITSELF: after the call, the stranger still faces the PIN.
// ═══════════════════════════════════════════════════════════════════════════════════

test('after a full escalation, the stranger STILL needs the PIN to message the peer', async () => {
  await seedScenario();

  // Full lifecycle: invite, join, talk, leave. Everything a real conference does.
  assert.equal((await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C })).status, 200);
  assert.equal((await call('POST', `/calls/${CALL}/join`, { user: C, device: DEV_A })).status, 200);
  assert.equal((await call('POST', `/calls/${CALL}/adhoc-token`, { user: C, device: DEV_A })).status, 200);
  assert.equal((await call('GET', `/calls/${CALL}/participants`, { user: C })).status, 200);
  assert.equal((await call('POST', `/calls/${CALL}/leave`, { user: C })).status, 200);

  // Cara now knows Ben exists, has seen his @username, and shared a call with him.

  // 1. No PIN => refused. Sharing a call bought her nothing.
  const noPin = await fetch(`${base}/reachability/request`, {
    method: 'POST',
    headers: { authorization: `Bearer ${tokenFor(C)}`, 'content-type': 'application/json' },
    body: JSON.stringify({ username: 'ben' }),
  });
  assert.equal(noPin.status, 400);
  assert.match((await noPin.json() as any).error, /pin required/i);
  assert.equal(db.conversations.length, 1, 'a refused request creates nothing');

  // 2. Wrong PIN => refused, and the attempt is counted against her.
  const wrongPin = await fetch(`${base}/reachability/request`, {
    method: 'POST',
    headers: { authorization: `Bearer ${tokenFor(C)}`, 'content-type': 'application/json' },
    body: JSON.stringify({ username: 'ben', pin: '000000' }),
  });
  assert.equal(wrongPin.status, 403);
  assert.equal(db.contact_pin_attempts.filter((a) => !a.succeeded).length, 1);

  // 3. Correct PIN => a conversation opens, but Ben's side is PENDING. He still gets to
  //    accept or decline. The call never made him reachable, only findable.
  const withPin = await fetch(`${base}/reachability/request`, {
    method: 'POST',
    headers: { authorization: `Bearer ${tokenFor(C)}`, 'content-type': 'application/json' },
    body: JSON.stringify({ username: 'ben', pin: PIN }),
  });
  assert.equal(withPin.status, 200);
  const created = await withPin.json() as any;
  assert.equal(created.pending, true, 'the recipient of a PIN-gated request is always pending');
  const bensMembership = db.conversation_members.find(
    (m) => m.conversation_id === created.conversation_id && m.user_id === B
  );
  assert.equal(bensMembership.request_state, 'pending');
  assert.equal(bensMembership.opened_via, 'username', 'opened by handle+PIN, never by the call');
});

test('the escalation changes NOTHING about the reachability outcome — control vs. escalated', async () => {
  // The strongest form of the guarantee: run the identical request with and without a
  // conference having happened, and get byte-identical authorization behaviour.
  async function requestWithoutPin() {
    const r = await fetch(`${base}/reachability/request`, {
      method: 'POST',
      headers: { authorization: `Bearer ${tokenFor(C)}`, 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'ben' }),
    });
    return { status: r.status, body: await r.json() as any };
  }

  await seedScenario();
  const control = await requestWithoutPin();

  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  await call('POST', `/calls/${CALL}/join`, { user: C, device: DEV_A });
  const escalated = await requestWithoutPin();

  assert.deepEqual(escalated, control, 'a shared call must not change the reachability answer');
});

test('the reachability path never reads call state, even when a call is in flight', async () => {
  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  await call('POST', `/calls/${CALL}/join`, { user: C, device: DEV_A });

  sqlLog = [];
  await fetch(`${base}/reachability/request`, {
    method: 'POST',
    headers: { authorization: `Bearer ${tokenFor(C)}`, 'content-type': 'application/json' },
    body: JSON.stringify({ username: 'ben', pin: PIN }),
  });

  for (const stmt of sqlLog) {
    assert.equal(/call_participants/.test(stmt), false, `reachability read call_participants: ${stmt}`);
    assert.equal(/\bfrom calls\b|\bjoin calls\b/.test(stmt), false, `reachability read the calls table: ${stmt}`);
  }
});

test('an ended call cannot be reopened as a ringing channel', async () => {
  await seedScenario();
  db.calls[0].status = 'ended';
  const res = await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  assert.equal(res.status, 409);
  assert.equal(db.call_participants.length, 0);
});

test('escalate refuses uuid-shaped garbage and self-invites without touching state', async () => {
  await seedScenario();
  assert.equal((await call('POST', `/calls/${CALL}/escalate`, { user: A }, { invitee_user_id: 'nope' })).status, 400);
  assert.equal((await call('POST', `/calls/${CALL}/escalate`, { user: A }, { invitee_user_id: A })).status, 400);
  assert.equal((await call('POST', `/calls/not-a-uuid/escalate`, { user: A }, { invitee_user_id: C })).status, 400);
  assert.equal(db.call_participants.length, 0);
});

test('inviting an unknown user id is indistinguishable from inviting an unreachable one', async () => {
  await seedScenario();
  const ghost = '99999999-9999-4999-8999-999999999999';
  const missing = await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: ghost });
  const unreachable = await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: D });
  // Same status AND same body — otherwise this endpoint is a user-id existence oracle.
  assert.equal(missing.status, 403);
  assert.deepEqual(missing.body, unreachable.body);
});

test('re-inviting someone who already joined does not demote them to "Ringing…"', async () => {
  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  await call('POST', `/calls/${CALL}/join`, { user: C, device: DEV_A });
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  const cara = db.call_participants.find((cp) => cp.user_id === C)!;
  assert.equal(cara.state, 'joined');
  assert.equal(db.call_participants.filter((cp) => cp.call_id === CALL).length, 3, 'no duplicate row');
});

test('a second escalation does not resurrect a participant who left', async () => {
  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  await call('POST', `/calls/${CALL}/leave`, { user: B });
  assert.equal(db.call_participants.find((cp) => cp.user_id === B)!.state, 'left');
  // Ana invites Cara again; the seed step must not pull Ben back in from the conversation.
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  assert.equal(db.call_participants.find((cp) => cp.user_id === B)!.state, 'left');
  assert.equal(callGrantAllows(redisStore.get(`callgrant:${CALL}`) ?? null, A, B), false);
});

test('the last participant out ends the call and destroys the grant', async () => {
  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  await call('POST', `/calls/${CALL}/leave`, { user: C });
  await call('POST', `/calls/${CALL}/leave`, { user: B });
  const last = await call('POST', `/calls/${CALL}/leave`, { user: A });
  assert.equal(last.body.participant_count, 0);
  assert.equal(db.calls[0].status, 'ended');
  assert.equal(redisStore.has(`callgrant:${CALL}`), false, 'a dead call must authorize nothing');
  // Still no messaging edge, after the whole lifecycle.
  assert.equal(db.conversations.length, 1);
  assert.equal(db.conversation_members.length, 2);
});

test('leaving is idempotent', async () => {
  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  const first = await call('POST', `/calls/${CALL}/leave`, { user: C });
  const second = await call('POST', `/calls/${CALL}/leave`, { user: C });
  assert.equal(first.status, 200);
  assert.equal(first.body.was_participant, true);
  assert.equal(second.status, 200, 'a retried teardown must not fail');
  assert.equal(second.body.was_participant, false);
});

test('join requires an invite — a known call_id is not a way into the room', async () => {
  await seedScenario();
  await call('POST', `/calls/${CALL}/escalate`, { user: A, device: DEV_A }, { invitee_user_id: C });
  const res = await call('POST', `/calls/${CALL}/join`, { user: D, device: DEV_A });
  assert.equal(res.status, 403);
});

test('the conference endpoints require authentication', async () => {
  await seedScenario();
  for (const [method, p] of [
    ['POST', `/calls/${CALL}/escalate`],
    ['POST', `/calls/${CALL}/adhoc-token`],
    ['POST', `/calls/${CALL}/join`],
    ['POST', `/calls/${CALL}/leave`],
    ['GET', `/calls/${CALL}/participants`],
  ] as const) {
    const res = await fetch(`${base}${p}`, {
      method,
      headers: { 'content-type': 'application/json' },
      body: method === 'POST' ? '{}' : undefined,
    });
    assert.equal(res.status, 401, `${method} ${p} must require auth`);
  }
});
