// The one thing this feature can never get wrong: a coordinate must never reach the
// server. `assertOpaque` alone does NOT cover that — it only knows four message-body
// field names, so a body carrying `latitude` sails straight past it. `assertNoCoordinates`
// is the structural guard that every handler in routes/location.ts runs on the whole body
// before doing anything, and these tests pin its behaviour: what it rejects, how deep it
// looks, and — just as important — that it does not reject the legitimate share-session
// bodies the routes actually accept.
import test from 'node:test';
import assert from 'node:assert/strict';
import { assertNoCoordinates, assertOpaque } from '../../../packages/common-utils/src/crypto';

test('assertOpaque does NOT catch a coordinate — which is why assertNoCoordinates exists', () => {
  // Documents the gap rather than the fix: if this ever starts throwing, the second
  // guard is still required, but this test's premise needs revisiting.
  assert.doesNotThrow(() => assertOpaque({ latitude: 12.97163, longitude: 77.5946 }));
});

test('a body containing latitude is rejected', () => {
  assert.throws(
    () => assertNoCoordinates({ share_id: 'x', latitude: 12.97163 }),
    /forbidden field "body\.latitude"/
  );
});

for (const key of [
  'lat', 'lon', 'lng', 'latitude', 'longitude',
  'coords', 'coordinates', 'accuracy', 'altitude', 'speed', 'heading',
  'geo', 'position', 'gps',
]) {
  test(`a body containing "${key}" is rejected`, () => {
    assert.throws(() => assertNoCoordinates({ [key]: 1 }), /forbidden field/);
  });
}

test('case and separators do not smuggle a coordinate through', () => {
  for (const key of ['Latitude', 'LAT', 'user_lat', 'lastLon', 'device-position', 'Geo']) {
    assert.throws(() => assertNoCoordinates({ [key]: 1 }), /forbidden field/, key);
  }
});

test('a coordinate nested inside an object or array is still rejected', () => {
  assert.throws(
    () => assertNoCoordinates({ meta: { fix: { lat: 1, lon: 2 } } }),
    /forbidden field "body\.meta\.fix\.lat"/
  );
  assert.throws(
    () => assertNoCoordinates({ target_user_ids: [{ id: 'a' }, { longitude: 2 }] }),
    /forbidden field "body\.target_user_ids\[1\]\.longitude"/
  );
});

test('matching is per token, not substring — innocent keys survive', () => {
  // A substring match would reject every one of these and make the guard unusable.
  assert.doesNotThrow(() =>
    assertNoCoordinates({ related: 1, translation: 2, latest: 3, speedy: 4, geometry: 5, deposition: 6 })
  );
});

test('the real share-session bodies the routes accept are clean', () => {
  assert.doesNotThrow(() =>
    assertNoCoordinates({
      kind: 'conversation',
      conversation_id: '11111111-1111-4111-8111-111111111111',
      target_user_ids: ['22222222-2222-4222-8222-222222222222'],
      duration_seconds: 3600,
    })
  );
  assert.doesNotThrow(() => assertNoCoordinates({ kind: 'map', duration_seconds: 86400 }));
  // Empty/absent bodies (DELETE with no payload) must not throw.
  assert.doesNotThrow(() => assertNoCoordinates({}));
  assert.doesNotThrow(() => assertNoCoordinates(undefined));
  assert.doesNotThrow(() => assertNoCoordinates(null));
});

test('a hostile body cannot turn the guard into a DoS', () => {
  // Cycles terminate instead of recursing forever...
  const cyclic: Record<string, unknown> = { a: 1 };
  cyclic.self = cyclic;
  assert.doesNotThrow(() => assertNoCoordinates(cyclic));

  // ...and absurd nesting is refused rather than blowing the stack.
  let deep: Record<string, unknown> = {};
  for (let i = 0; i < 50; i++) deep = { next: deep };
  assert.throws(() => assertNoCoordinates(deep), /nested too deeply/);
});
