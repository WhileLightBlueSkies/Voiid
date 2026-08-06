// A conference invite must be DISTINGUISHABLE from a 1:1 ring at the push layer.
//
// ── THE BUG ──────────────────────────────────────────────────────────────────────
// `POST /calls/:id/escalate` sent `{ type: 'call', call_id, call_kind, caller_id }` — byte
// for byte the same push a 1:1 ring sends. Both clients therefore routed it into their 1:1
// handler, which arms a 30-second OFFER TIMEOUT.
//
// A 1:1 ring promises an SDP offer over the socket within seconds. A conference invitee
// never receives one: it joins the SFU by fetching a token. So the watchdog fired and ended
// every push-woken invite about 30 seconds in.
//
// Both clients already HAD a conference-invite handler that does the right thing
// (`onConferenceInvitePush` on Android, `isConference` on iOS). Neither was reachable from
// the push path — only over the WebSocket, which a backgrounded or killed device does not
// have. That is why "add to call" appeared to work in the foreground and never otherwise.
//
// These tests pin the flag in both payload builders so the marker cannot be dropped again.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildFcmData, buildVoipPayload } from '../src/pushPayload';

const RING = {
  type: 'call',
  call_id: 'cccccccc-0000-0000-0000-000000000003',
  call_kind: 'voice',
  caller_id: 'aaaaaaaa-0000-0000-0000-000000000001',
} as const;

test('FCM: a conference invite is marked, a 1:1 ring is not', () => {
  const invite = buildFcmData({ ...RING, conference: true });
  const ring = buildFcmData(RING);

  // FCM data values must be STRINGS — the SDK silently drops a boolean, which would put
  // the marker back to being absent without anyone noticing.
  assert.equal(invite.conference, 'true');
  assert.equal(typeof invite.conference, 'string');

  assert.equal(
    ring.conference,
    undefined,
    'a 1:1 ring must NOT carry the flag, or every ordinary call would skip its offer timeout'
  );
});

test('VoIP: a conference invite is marked, a 1:1 ring is not', () => {
  const invite = buildVoipPayload({ ...RING, conference: true });
  const ring = buildVoipPayload(RING);

  assert.equal(invite.conference, true);
  assert.equal(ring.conference, undefined);
});

test('the invite still carries the routing ids a 1:1 ring does', () => {
  // It rides the SAME surface on purpose: CallKit/Telecom, the full-screen intent, the
  // system call log and the ringtone all keep working with no second code path. Dropping
  // any of these would break the ring itself rather than just the conference routing.
  const invite = buildFcmData({ ...RING, conference: true });

  assert.equal(invite.type, 'call');
  assert.equal(invite.call_id, RING.call_id);
  assert.equal(invite.call_kind, RING.call_kind);
  assert.equal(invite.caller_id, RING.caller_id);
});

test('no content ever rides a conference invite', () => {
  // The privacy rule does not relax because the push gained a flag: routing ids only.
  const invite = buildFcmData({ ...RING, conference: true });
  const allowed = new Set(['type', 'call_id', 'call_kind', 'caller_id', 'conference']);

  for (const key of Object.keys(invite)) {
    assert.ok(allowed.has(key), `unexpected field on a call push: ${key}`);
  }
});
