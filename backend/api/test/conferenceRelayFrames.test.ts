// The conference signalling frames the relay silently dropped.
//
// ── THE BUG ──────────────────────────────────────────────────────────────────────
// Both clients send four frames to drive an ad-hoc conference:
//
//   call_invite         : call_id, to_user_id, call_kind, room
//   call_invite_accept  : call_id, to_user_id
//   call_invite_decline : call_id, to_user_id
//   call_migrate        : call_id, to_user_id, room
//
// Both clients also LISTEN for all four (iOS WebSocketClient.swift:461-476, Android
// WebSocketClient.kt:350-353). The relay's allowlist contained none of them, so every one was
// dropped — with no error, because the relay only forwards types it recognises and ignores
// the rest.
//
// The consequences, all of which read as "conference calling is broken":
//   * the invitee is never told over the socket that they were invited (the push path works,
//     which is why it appeared to work at all when the app was backgrounded);
//   * ACCEPT never reaches the inviter, so their roster never updates;
//   * DECLINE never reaches the inviter, so a refused invite looks identical to one still
//     ringing — forever;
//   * MIGRATE never arrives, so the original peer never moves to the SFU and the engine
//     times out and abandons the upgrade (CallConference.swift: handoverTimeout).
//
// `room` compounds it: the relay rebuilds every outbound frame from a fixed field list and
// `room` was not on it, so even once the type is allowed, call_invite and call_migrate would
// arrive naming no room to join.
//
// These tests pin the contract: the frame types the relay must forward, and the fields it
// must preserve.
import { test } from 'node:test';
import assert from 'node:assert/strict';

/**
 * The relay's forwarding predicate and frame rebuild, mirrored from
 * backend/websocket/src/index.ts. The relay is a separate service with no test harness of
 * its own; this pins the contract the clients depend on.
 */
const RELAYED_CALL_TYPES = new Set([
  'call_offer',
  'call_answer',
  'call_ice',
  'call_hangup',
  'call_busy',
  'call_decline',
  'call_ringing',
  'call_hold',
  'call_unhold',
  // The conference four.
  'call_invite',
  'call_invite_accept',
  'call_invite_decline',
  'call_migrate',
]);

function isRelayed(msg: { type?: unknown; to_user_id?: unknown; call_id?: unknown }): boolean {
  return (
    typeof msg.type === 'string' &&
    RELAYED_CALL_TYPES.has(msg.type) &&
    typeof msg.to_user_id === 'string' &&
    typeof msg.call_id === 'string'
  );
}

/** The outbound frame, rebuilt from KNOWN fields only — never echoing client extras. */
function rebuild(msg: Record<string, unknown>, senderId: string): Record<string, unknown> {
  return JSON.parse(
    JSON.stringify({
      type: msg.type,
      call_id: msg.call_id,
      from_user_id: senderId,
      conversation_id: msg.conversation_id,
      call_kind: msg.call_kind,
      sdp: msg.sdp,
      candidate: msg.candidate,
      reason: msg.reason,
      // Required by call_invite and call_migrate: the SFU room to join. Without it the
      // invitee is told a conference exists and given no way to enter it.
      room: msg.room,
    })
  );
}

const A = 'aaaaaaaa-0000-0000-0000-000000000001';
const B = 'bbbbbbbb-0000-0000-0000-000000000002';
const CALL = 'cccccccc-0000-0000-0000-000000000003';

test('THE BUG: the four conference frames must be relayed', () => {
  for (const type of ['call_invite', 'call_invite_accept', 'call_invite_decline', 'call_migrate']) {
    assert.equal(
      isRelayed({ type, to_user_id: B, call_id: CALL }),
      true,
      `${type} was dropped — the client sends it and the peer listens for it`
    );
  }
});

test('call_invite carries the room, or the invitee has nowhere to go', () => {
  const out = rebuild(
    { type: 'call_invite', call_id: CALL, to_user_id: B, call_kind: 'voice', room: 'voiid-call-abc' },
    A
  );
  assert.equal(out.room, 'voiid-call-abc');
  assert.equal(out.call_kind, 'voice');
  assert.equal(out.from_user_id, A, 'sender is stamped by the relay, never client-supplied');
});

test('call_migrate carries the room too', () => {
  const out = rebuild({ type: 'call_migrate', call_id: CALL, to_user_id: B, room: 'voiid-call-abc' }, A);
  assert.equal(out.room, 'voiid-call-abc');
});

test('accept and decline need no room — they are verdicts, not destinations', () => {
  for (const type of ['call_invite_accept', 'call_invite_decline']) {
    const out = rebuild({ type, call_id: CALL, to_user_id: A }, B);
    assert.equal(out.room, undefined, `${type} must not invent a room`);
    assert.equal(out.call_id, CALL);
    assert.equal(out.from_user_id, B, 'the DECLINER is the sender, so the inviter learns who');
  }
});

test('the relay still refuses frames it does not know', () => {
  assert.equal(isRelayed({ type: 'call_teleport', to_user_id: B, call_id: CALL }), false);
});

test('a frame missing to_user_id or call_id is not relayed', () => {
  assert.equal(isRelayed({ type: 'call_invite', call_id: CALL }), false);
  assert.equal(isRelayed({ type: 'call_invite', to_user_id: B }), false);
});
