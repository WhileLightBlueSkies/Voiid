// Call-metrics validation, whitelisting and clamping.
//
// The whitelist tests are the privacy-critical ones: they assert that the object
// which reaches SQL is BUILT from a fixed key list rather than derived from the
// request body, so a client cannot cause anything unanticipated to be persisted.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeCallMetrics,
  clampInt,
  clampNum,
  dedupeHash,
  clampWindowHours,
  METRIC_KEYS,
  END_REASONS,
  LIMITS,
} from '../src/callMetrics';

const CALL_ID = '22222222-2222-4222-8222-222222222222';

function valid(extra: Record<string, unknown> = {}) {
  return {
    call_id: CALL_ID,
    connected: true,
    relayed: false,
    platform: 'ios',
    end_reason: 'hangup',
    setup_ms: 1200,
    duration_ms: 65_000,
    ice_restarts: 1,
    avg_rtt_ms: 82.5,
    avg_packet_loss_pct: 0.4,
    jitter_ms: 12.25,
    ...extra,
  };
}

function ok(body: unknown) {
  const r = normalizeCallMetrics(body);
  assert.equal(r.ok, true, `expected ok, got: ${(r as any).error}`);
  return r as Extract<typeof r, { ok: true }>;
}

test('accepts a well-formed sample and preserves every whitelisted field', () => {
  const r = ok(valid());
  assert.deepEqual(r.value, {
    connected: true,
    relayed: false,
    platform: 'ios',
    end_reason: 'hangup',
    setup_ms: 1200,
    duration_ms: 65_000,
    ice_restarts: 1,
    avg_rtt_ms: 82.5,
    avg_packet_loss_pct: 0.4,
    jitter_ms: 12.25,
  });
  assert.deepEqual(r.dropped, []);
});

// --- PRIVACY: extra fields must never survive normalization ------------------------

test('drops unknown client fields entirely — they never reach the persisted row', () => {
  const r = ok(
    valid({
      // The exact things that must never be stored.
      sdp: 'v=0\r\no=- 123 IN IP4 203.0.113.9',
      ice_candidates: ['candidate:1 1 udp 2113937151 192.168.1.5 54321 typ host'],
      peer_ip: '203.0.113.9',
      remote_ip: '198.51.100.4',
      peer_user_id: 'victim-user',
      phone_number: '+15551234567',
      transcript: 'hello there',
      user_id: 'attacker-supplied',
      call_id_raw: CALL_ID,
    })
  );
  const persisted = JSON.stringify(r.value);
  for (const leak of ['sdp', 'candidate', '203.0.113.9', '198.51.100.4', 'victim-user', '+1555', 'hello there', 'attacker-supplied']) {
    assert.ok(!persisted.includes(leak), `"${leak}" leaked into the persisted row: ${persisted}`);
  }
  // Only KEY NAMES are echoed back, and all of them are reported.
  assert.deepEqual(r.dropped.sort(), [
    'call_id_raw',
    'ice_candidates',
    'peer_ip',
    'peer_user_id',
    'phone_number',
    'remote_ip',
    'sdp',
    'transcript',
    'user_id',
  ]);
});

test('the persisted row can only ever contain whitelisted keys', () => {
  const noise: Record<string, unknown> = {};
  for (let i = 0; i < 50; i++) noise[`field_${i}`] = `value_${i}`;
  const r = ok(valid(noise));
  const allowed = new Set<string>(METRIC_KEYS);
  for (const k of Object.keys(r.value)) {
    assert.ok(allowed.has(k), `unexpected persisted key: ${k}`);
  }
  assert.equal(r.dropped.length, 50);
});

test('call_id is returned for dedupe but is NOT part of the persisted row', () => {
  const r = ok(valid());
  assert.equal(r.call_id, CALL_ID);
  assert.ok(!('call_id' in r.value), 'call_id must not be persisted');
});

test('a prototype-pollution style payload does not corrupt the output', () => {
  const r = ok(valid({ __proto__: { polluted: true }, constructor: 'x' } as any));
  assert.equal((r.value as any).polluted, undefined);
  assert.equal(({} as any).polluted, undefined);
});

// --- Required-field validation -----------------------------------------------------

test('rejects a non-object body', () => {
  for (const body of [null, undefined, 'string', 42, [1, 2, 3]]) {
    assert.equal(normalizeCallMetrics(body).ok, false, `accepted ${JSON.stringify(body)}`);
  }
});

test('rejects a missing or non-uuid call_id', () => {
  assert.equal(normalizeCallMetrics(valid({ call_id: undefined })).ok, false);
  assert.equal(normalizeCallMetrics(valid({ call_id: 'not-a-uuid' })).ok, false);
  assert.equal(normalizeCallMetrics(valid({ call_id: 12345 })).ok, false);
});

test('rejects non-boolean connected / relayed', () => {
  assert.equal(normalizeCallMetrics(valid({ connected: 'true' })).ok, false);
  assert.equal(normalizeCallMetrics(valid({ connected: 1 })).ok, false);
  assert.equal(normalizeCallMetrics(valid({ relayed: null })).ok, false);
});

test('rejects an unknown platform', () => {
  assert.equal(normalizeCallMetrics(valid({ platform: 'web' })).ok, false);
  assert.equal(normalizeCallMetrics(valid({ platform: 'IOS' })).ok, false);
  assert.equal(normalizeCallMetrics(valid({ platform: undefined })).ok, false);
});

// --- end_reason is a constrained vocabulary ----------------------------------------

test('every documented end_reason is accepted verbatim', () => {
  for (const reason of END_REASONS) {
    assert.equal(ok(valid({ end_reason: reason })).value.end_reason, reason);
  }
});

test('an unknown end_reason is coerced to "unknown", not stored verbatim', () => {
  // A newer client must not fail; but free text must never reach the column.
  assert.equal(ok(valid({ end_reason: 'brand_new_reason' })).value.end_reason, 'unknown');
  assert.equal(
    ok(valid({ end_reason: 'user +15551234567 hung up' })).value.end_reason,
    'unknown'
  );
});

test('a non-string end_reason is rejected outright', () => {
  assert.equal(normalizeCallMetrics(valid({ end_reason: 7 })).ok, false);
  assert.equal(normalizeCallMetrics(valid({ end_reason: undefined })).ok, false);
});

// --- Clamping: a client can send anything ------------------------------------------

test('clamps absurdly large numbers to the documented ceilings', () => {
  const r = ok(
    valid({
      setup_ms: 999_999_999,
      duration_ms: Number.MAX_SAFE_INTEGER,
      ice_restarts: 100_000,
      avg_rtt_ms: 1e12,
      avg_packet_loss_pct: 5000,
      jitter_ms: 1e9,
    })
  );
  assert.equal(r.value.setup_ms, LIMITS.setup_ms.max);
  assert.equal(r.value.duration_ms, LIMITS.duration_ms.max);
  assert.equal(r.value.ice_restarts, LIMITS.ice_restarts.max);
  assert.equal(r.value.avg_rtt_ms, LIMITS.avg_rtt_ms.max);
  assert.equal(r.value.avg_packet_loss_pct, 100);
  assert.equal(r.value.jitter_ms, LIMITS.jitter_ms.max);
});

test('clamps negatives up to zero', () => {
  const r = ok(valid({ setup_ms: -5000, duration_ms: -1, avg_packet_loss_pct: -12.5 }));
  assert.equal(r.value.setup_ms, 0);
  assert.equal(r.value.duration_ms, 0);
  assert.equal(r.value.avg_packet_loss_pct, 0);
});

test('drops NaN / Infinity / garbage numerics instead of persisting them', () => {
  const r = ok(
    valid({ setup_ms: 'abc', duration_ms: null, avg_rtt_ms: Infinity, jitter_ms: NaN })
  );
  assert.equal(r.value.setup_ms, undefined);
  assert.equal(r.value.duration_ms, undefined);
  assert.equal(r.value.avg_rtt_ms, undefined);
  assert.equal(r.value.jitter_ms, undefined);
});

test('optional metrics may be omitted entirely', () => {
  const r = ok({
    call_id: CALL_ID,
    connected: false,
    relayed: false,
    platform: 'android',
    end_reason: 'failed',
  });
  assert.deepEqual(r.value, {
    connected: false,
    relayed: false,
    platform: 'android',
    end_reason: 'failed',
  });
});

test('integer metrics are rounded, float metrics keep 2 decimals', () => {
  const r = ok(valid({ setup_ms: 1200.7, avg_rtt_ms: 82.456, jitter_ms: 0.005 }));
  assert.equal(r.value.setup_ms, 1201);
  assert.equal(r.value.avg_rtt_ms, 82.46);
  assert.equal(r.value.jitter_ms, 0.01);
});

test('clampInt / clampNum behave at the boundaries', () => {
  assert.equal(clampInt(5, 0, 10), 5);
  assert.equal(clampInt(0, 0, 10), 0);
  assert.equal(clampInt(10, 0, 10), 10);
  assert.equal(clampInt(11, 0, 10), 10);
  assert.equal(clampInt(undefined, 0, 10), undefined);
  assert.equal(clampNum('3.14159', 0, 10), 3.14);
  assert.equal(clampNum(-0.5, 0, 10), 0);
});

// --- Dedupe hash: idempotency without linkability ----------------------------------

test('dedupeHash is deterministic per (call_id, secret)', () => {
  const a = dedupeHash(CALL_ID, 'secret-a');
  const b = dedupeHash(CALL_ID, 'secret-a');
  assert.ok(a.equals(b));
  assert.equal(a.length, 32); // sha256
});

test('dedupeHash does not contain the call id and changes with the secret', () => {
  const h = dedupeHash(CALL_ID, 'secret-a');
  assert.ok(!h.toString('hex').includes(CALL_ID.replace(/-/g, '')));
  assert.ok(!h.toString('utf8').includes(CALL_ID));
  // Rotating the secret severs the linkage for existing rows.
  assert.ok(!h.equals(dedupeHash(CALL_ID, 'secret-b')));
});

test('different calls produce different dedupe hashes', () => {
  const a = dedupeHash('33333333-3333-4333-8333-333333333333', 's');
  const b = dedupeHash('44444444-4444-4444-8444-444444444444', 's');
  assert.ok(!a.equals(b));
});

// --- Summary window ----------------------------------------------------------------

test('summary window clamps to [1,720] with a 24h default', () => {
  assert.equal(clampWindowHours(undefined), 24);
  assert.equal(clampWindowHours('abc'), 24);
  assert.equal(clampWindowHours('168'), 168);
  assert.equal(clampWindowHours(0), 1);
  assert.equal(clampWindowHours(-5), 1);
  assert.equal(clampWindowHours(100000), 720);
});
