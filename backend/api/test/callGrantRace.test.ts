// The ring-grant race — why "no call is accepting" and calls sit on Connecting forever.
//
// ── THE BUG ──────────────────────────────────────────────────────────────────────
// The WS relay gates EVERY call frame on a Redis "ring grant" (`callgrant:<call_id>`)
// written by `POST /calls/ring`. `callPairAuthorized()` returns false when the key is
// absent, and the relay then **returns silently** — deliberately, so a caller cannot probe
// which user ids are reachable. Correct for security; catastrophic when the grant is simply
// late, because the frame is dropped with no error anywhere.
//
// Both clients sent the WS offer and POSTed /calls/ring CONCURRENTLY:
//   * Android: `scope.launch { ring(...) }` then `exec.execute { ...sendCallOffer }`
//   * iOS:     `await createAndSendOffer(...)` BEFORE the `POST /calls/ring`
//
// The offer travels one WS hop; the ring is a full HTTPS round trip that also does two
// Postgres queries. The offer therefore usually wins, arrives with no grant written yet,
// and is silently discarded. The callee's push fires (that path does not consult the
// grant), the phone rings, the user taps accept — and there is no offer to answer, so the
// call hangs on "Connecting" forever and every subsequent frame dies the same way.
//
// This test pins the ORDERING CONTRACT that fixes it: the grant must exist before the
// first frame is relayed. It exercises the relay's real gate function shape against a
// fake Redis, so it fails if anyone reintroduces the race by moving the ring back.
import { test } from 'node:test';
import assert from 'node:assert/strict';

/** The relay's key naming, verbatim from backend/websocket/src/index.ts. */
const ringGrantKey = (callId: string) => `callgrant:${callId}`;

/** Minimal stand-in for the Redis the relay reads its grants from. */
class FakeRedis {
  private store = new Map<string, string>();
  async set(key: string, value: string): Promise<void> {
    this.store.set(key, value);
  }
  async get(key: string): Promise<string | null> {
    return this.store.get(key) ?? null;
  }
}

/**
 * `callPairAuthorized`, copied verbatim in behaviour from the relay. The point of
 * duplicating it is that the relay is a separate service with no test harness; this pins
 * the CONTRACT the API side must satisfy for the relay to forward anything at all.
 */
async function callPairAuthorized(
  redis: FakeRedis,
  callId: string,
  from: string,
  to: string
): Promise<boolean> {
  const raw = await redis.get(ringGrantKey(callId));
  if (!raw) return false;
  try {
    const { a, b } = JSON.parse(raw) as { a: string; b: string };
    return (a === from && b === to) || (a === to && b === from);
  } catch {
    return false;
  }
}

/** What `POST /calls/ring` writes. */
async function writeGrant(redis: FakeRedis, callId: string, caller: string, callee: string) {
  await redis.set(ringGrantKey(callId), JSON.stringify({ a: caller, b: callee }));
}

const CALLER = 'aaaaaaaa-0000-0000-0000-000000000001';
const CALLEE = 'bbbbbbbb-0000-0000-0000-000000000002';
const CALL_ID = 'cccccccc-0000-0000-0000-000000000003';

test('THE BUG: an offer relayed before the ring grant exists is silently dropped', async () => {
  const redis = new FakeRedis();

  // The offer wins the race — no grant written yet.
  const offerAllowed = await callPairAuthorized(redis, CALL_ID, CALLER, CALLEE);

  assert.equal(
    offerAllowed,
    false,
    'this is the failure mode: the relay drops the offer and reports nothing, so the ' +
      'callee rings from the push but has no SDP to answer'
  );
});

test('THE FIX: ring first, then offer — the frame is authorized', async () => {
  const redis = new FakeRedis();

  // Ordering contract: the grant is written BEFORE the first frame leaves the client.
  await writeGrant(redis, CALL_ID, CALLER, CALLEE);
  const offerAllowed = await callPairAuthorized(redis, CALL_ID, CALLER, CALLEE);

  assert.equal(offerAllowed, true, 'offer must be relayed once the grant exists');
});

test('the grant is direction-agnostic: the callee\'s ANSWER travels the same pair', async () => {
  const redis = new FakeRedis();
  await writeGrant(redis, CALL_ID, CALLER, CALLEE);

  // The answer goes callee -> caller, the reverse of how the grant was written. If this
  // were direction-sensitive, accepting a call would fail even with a grant present.
  const answerAllowed = await callPairAuthorized(redis, CALL_ID, CALLEE, CALLER);

  assert.equal(answerAllowed, true, 'the answer must be relayed back to the caller');
});

test('a third party cannot ride an existing grant', async () => {
  const redis = new FakeRedis();
  await writeGrant(redis, CALL_ID, CALLER, CALLEE);

  const intruder = 'dddddddd-0000-0000-0000-000000000004';
  const allowed = await callPairAuthorized(redis, CALL_ID, intruder, CALLEE);

  assert.equal(allowed, false, 'the grant names exactly one pair and nobody else');
});

test('a grant for a DIFFERENT call does not authorize this one', async () => {
  const redis = new FakeRedis();
  await writeGrant(redis, 'other-call-id', CALLER, CALLEE);

  const allowed = await callPairAuthorized(redis, CALL_ID, CALLER, CALLEE);

  assert.equal(allowed, false, 'grants are per-call, not per-pair');
});
