// TURN/ICE credential issuance.
//
// Two things are being protected here:
//  1. The coturn REST scheme must be BYTE-EXACT. coturn recomputes
//     base64(HMAC_SHA1(static-auth-secret, "<expiry>:<user>")) and string-compares.
//     Any drift — a different separator, hex instead of base64, ms instead of
//     seconds — silently breaks every relayed call in production while every unit
//     that doesn't check the actual bytes still passes. Hence a hardcoded vector.
//  2. The provider precedence + fallbacks must never 500. An unprovisioned TURN
//     config is a normal dev state, not a server fault.
import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'crypto';
import {
  coturnCredentials, resetCloudflareIceCache, resolveIceServers, splitEnvList, stunUrls,
} from '../src/turn';

const TURN_ENV = [
  'VOIID_TURN_STATIC_AUTH_SECRET',
  'VOIID_TURN_URLS',
  'VOIID_STUN_URLS',
  'VOIID_TURN_TTL_SECONDS',
  'VOIID_TURN_CLOUDFLARE_KEY_ID',
  'VOIID_TURN_CLOUDFLARE_API_TOKEN',
];
function clearTurnEnv() {
  for (const k of TURN_ENV) delete process.env[k];
  // The Cloudflare lease outlives env changes by design — it is keyed on the key ID, not on
  // the env being present. A test that swapped `fetch` without dropping it would be asserting
  // against the PREVIOUS test's credential.
  resetCloudflareIceCache();
}

const USER = '11111111-1111-4111-8111-111111111111';

test('coturn credential matches a known-good vector byte for byte', () => {
  // nowMs 1700000000000 + ttl 3600 => expiry 1700003600.
  const { username, credential, expiry } = coturnCredentials(USER, {
    secret: 'super-secret-turn-key',
    ttlSeconds: 3600,
    nowMs: 1_700_000_000_000,
  });
  assert.equal(expiry, 1_700_003_600);
  assert.equal(username, `1700003600:${USER}`);
  // Independently computed with `openssl`-equivalent HMAC-SHA1 + base64.
  assert.equal(credential, 'MpBeiHnnB5hIIFpsGzAz9QsCwM8=');
});

test('coturn credential is exactly base64(HMAC_SHA1(secret, username))', () => {
  const { username, credential } = coturnCredentials(USER, {
    secret: 's3cr3t',
    ttlSeconds: 600,
    nowMs: Date.now(),
  });
  const expected = crypto.createHmac('sha1', 's3cr3t').update(username).digest('base64');
  assert.equal(credential, expected);
});

test('coturn username binds the expiry and the user id, in that order', () => {
  const { username } = coturnCredentials(USER, { secret: 'x', ttlSeconds: 60, nowMs: 0 });
  const [expiry, userId] = username.split(':');
  assert.equal(expiry, '60'); // unix SECONDS, not ms
  assert.equal(userId, USER);
});

test('coturn credentials are time-limited: expiry advances with the TTL', () => {
  const short = coturnCredentials(USER, { secret: 'x', ttlSeconds: 60, nowMs: 1_000_000 });
  const long = coturnCredentials(USER, { secret: 'x', ttlSeconds: 7200, nowMs: 1_000_000 });
  assert.equal(long.expiry - short.expiry, 7200 - 60);
  // Different expiry => different signed username => different credential.
  assert.notEqual(short.credential, long.credential);
});

test('coturn credentials are scoped per user (a leaked one is not reusable)', () => {
  const a = coturnCredentials('user-a', { secret: 'x', ttlSeconds: 60, nowMs: 0 });
  const b = coturnCredentials('user-b', { secret: 'x', ttlSeconds: 60, nowMs: 0 });
  assert.notEqual(a.credential, b.credential);
});

test('splitEnvList trims, drops blanks, and tolerates undefined', () => {
  assert.deepEqual(splitEnvList('a, b ,,c '), ['a', 'b', 'c']);
  assert.deepEqual(splitEnvList(undefined), []);
  assert.deepEqual(splitEnvList(''), []);
});

test('stunUrls falls back to a public STUN server when unconfigured', () => {
  clearTurnEnv();
  assert.deepEqual(stunUrls(), ['stun:stun.l.google.com:19302']);
  process.env.VOIID_STUN_URLS = 'stun:one:3478, stun:two:3478';
  assert.deepEqual(stunUrls(), ['stun:one:3478', 'stun:two:3478']);
  clearTurnEnv();
});

test('unconfigured TURN degrades to STUN-only instead of failing', async () => {
  clearTurnEnv();
  const cfg = await resolveIceServers(USER);
  assert.equal(cfg.turn_configured, false);
  assert.equal(cfg.ice_servers.length, 1);
  assert.ok(cfg.ice_servers[0].urls[0].startsWith('stun:'));
  // Crucially: no credentials leak into the STUN-only response.
  assert.equal(cfg.ice_servers[0].username, undefined);
  assert.equal(cfg.ice_servers[0].credential, undefined);
});

test('coturn is used when urls + secret are set (STUN still listed first)', async () => {
  clearTurnEnv();
  process.env.VOIID_TURN_URLS = 'turn:turn.voiid.example:3478';
  process.env.VOIID_TURN_STATIC_AUTH_SECRET = 'super-secret-turn-key';
  process.env.VOIID_TURN_TTL_SECONDS = '3600';

  const cfg = await resolveIceServers(USER);
  assert.equal(cfg.turn_configured, true);
  assert.equal(cfg.ttl_seconds, 3600);
  assert.equal(cfg.ice_servers.length, 2);
  assert.ok(cfg.ice_servers[0].urls[0].startsWith('stun:'));

  const turn = cfg.ice_servers[1];
  assert.deepEqual(turn.urls, ['turn:turn.voiid.example:3478']);
  const [, uid] = (turn.username as string).split(':');
  assert.equal(uid, USER);
  const expected = crypto
    .createHmac('sha1', 'super-secret-turn-key')
    .update(turn.username as string)
    .digest('base64');
  assert.equal(turn.credential, expected);
  clearTurnEnv();
});

test('TURN urls without a secret do NOT produce credentials (falls back to STUN)', async () => {
  clearTurnEnv();
  process.env.VOIID_TURN_URLS = 'turn:turn.voiid.example:3478';
  const cfg = await resolveIceServers(USER);
  assert.equal(cfg.turn_configured, false);
  assert.equal(cfg.ice_servers.length, 1);
  clearTurnEnv();
});

test('Cloudflare takes precedence over coturn when configured', async () => {
  clearTurnEnv();
  process.env.VOIID_TURN_URLS = 'turn:turn.voiid.example:3478';
  process.env.VOIID_TURN_STATIC_AUTH_SECRET = 'super-secret-turn-key';
  process.env.VOIID_TURN_CLOUDFLARE_KEY_ID = 'cf-key';
  process.env.VOIID_TURN_CLOUDFLARE_API_TOKEN = 'cf-token';

  const realFetch = globalThis.fetch;
  globalThis.fetch = (async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      iceServers: { urls: 'turn:cf.example:3478', username: 'cf-user', credential: 'cf-cred' },
    }),
  })) as unknown as typeof fetch;
  try {
    const cfg = await resolveIceServers(USER);
    assert.equal(cfg.turn_configured, true);
    assert.equal(cfg.ice_servers.length, 2);
    // Cloudflare's server, NOT the coturn one — precedence, not merge.
    assert.deepEqual(cfg.ice_servers[1].urls, ['turn:cf.example:3478']);
    assert.equal(cfg.ice_servers[1].username, 'cf-user');
  } finally {
    globalThis.fetch = realFetch;
    clearTurnEnv();
  }
});

test('a failing Cloudflare call falls back to coturn rather than erroring', async () => {
  clearTurnEnv();
  process.env.VOIID_TURN_URLS = 'turn:turn.voiid.example:3478';
  process.env.VOIID_TURN_STATIC_AUTH_SECRET = 'super-secret-turn-key';
  process.env.VOIID_TURN_CLOUDFLARE_KEY_ID = 'cf-key';
  process.env.VOIID_TURN_CLOUDFLARE_API_TOKEN = 'cf-token';

  const realFetch = globalThis.fetch;
  globalThis.fetch = (async () => {
    throw new Error('network down');
  }) as unknown as typeof fetch;
  try {
    const cfg = await resolveIceServers(USER);
    assert.equal(cfg.turn_configured, true);
    assert.deepEqual(cfg.ice_servers[1].urls, ['turn:turn.voiid.example:3478']);
  } finally {
    globalThis.fetch = realFetch;
    clearTurnEnv();
  }
});

test('Cloudflare non-2xx with no coturn configured degrades to STUN-only', async () => {
  clearTurnEnv();
  process.env.VOIID_TURN_CLOUDFLARE_KEY_ID = 'cf-key';
  process.env.VOIID_TURN_CLOUDFLARE_API_TOKEN = 'cf-token';

  const realFetch = globalThis.fetch;
  globalThis.fetch = (async () => ({ ok: false, status: 503, json: async () => ({}) })) as unknown as typeof fetch;
  try {
    const cfg = await resolveIceServers(USER);
    assert.equal(cfg.turn_configured, false);
    assert.equal(cfg.ice_servers.length, 1);
  } finally {
    globalThis.fetch = realFetch;
    clearTurnEnv();
  }
});

// --- The Cloudflare lease -----------------------------------------------------------
//
// WHY THESE EXIST. Minting a credential per request put a third party on the call-setup path:
// every call every user placed waited on an HTTPS round trip to Cloudflare, so their rate
// limit became our call failures. The credential is not user-scoped, so that request was
// buying nothing. What follows pins the cache that replaced it — including the parts that
// only matter when Cloudflare is having a bad day.

/** Counts calls and returns a distinct credential each time, so staleness is visible. */
function countingCloudflareFetch() {
  let calls = 0;
  const fetchImpl = (async () => {
    calls += 1;
    return {
      ok: true,
      status: 200,
      json: async () => ({
        iceServers: {
          urls: 'turn:cf.example:3478',
          username: `cf-user-${calls}`,
          credential: `cf-cred-${calls}`,
        },
      }),
    };
  }) as unknown as typeof fetch;
  return { fetchImpl, count: () => calls };
}

function configureCloudflare(ttlSeconds?: string) {
  clearTurnEnv();
  process.env.VOIID_TURN_CLOUDFLARE_KEY_ID = 'cf-key';
  process.env.VOIID_TURN_CLOUDFLARE_API_TOKEN = 'cf-token';
  if (ttlSeconds) process.env.VOIID_TURN_TTL_SECONDS = ttlSeconds;
}

test('a cached credential is reused instead of re-minted on every call', async () => {
  configureCloudflare('3600');
  const { fetchImpl, count } = countingCloudflareFetch();
  const realFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl;
  try {
    for (let i = 0; i < 25; i++) await resolveIceServers(USER);
    assert.equal(count(), 1, 'every call placed hit Cloudflare');
  } finally {
    globalThis.fetch = realFetch;
    clearTurnEnv();
  }
});

test('concurrent callers on a cold cache make ONE request, not one each', async () => {
  // The restart case: a hundred clients reconnect at once and all ask for ICE servers before
  // any answer has come back. Without a shared in-flight promise that is a hundred requests.
  configureCloudflare('3600');
  const { fetchImpl, count } = countingCloudflareFetch();
  const realFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl;
  try {
    const all = await Promise.all(Array.from({ length: 100 }, () => resolveIceServers(USER)));
    assert.equal(count(), 1, `${count()} concurrent mints`);
    // And every one of them got the same, valid answer.
    for (const cfg of all) assert.equal(cfg.ice_servers[1].username, 'cf-user-1');
  } finally {
    globalThis.fetch = realFetch;
    clearTurnEnv();
  }
});

test('a credential is re-minted once half its TTL has elapsed', async () => {
  // Refreshing at the halfway mark is what guarantees an issued credential outlives the call
  // it opens: a TURN allocation is refreshed with the SAME credential, so handing out one
  // about to expire drops a relayed call mid-conversation.
  configureCloudflare('1'); // refresh after 500ms
  const { fetchImpl, count } = countingCloudflareFetch();
  const realFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl;
  try {
    const first = await resolveIceServers(USER);
    assert.equal(first.ice_servers[1].username, 'cf-user-1');
    await new Promise((r) => setTimeout(r, 600));
    const second = await resolveIceServers(USER);
    assert.equal(count(), 2, 'the half-life refresh never fired');
    assert.equal(second.ice_servers[1].username, 'cf-user-2');
  } finally {
    globalThis.fetch = realFetch;
    clearTurnEnv();
  }
});

test('a Cloudflare outage serves the credential we still hold, not a demotion', async () => {
  // THE POINT OF REFRESHING EARLY. At the halfway mark the held credential is still valid for
  // another half TTL, so a failed refresh costs nothing. Falling back to coturn or STUN here
  // would degrade every call in the deployment over one bad HTTP response.
  configureCloudflare('1');
  process.env.VOIID_TURN_URLS = 'turn:turn.voiid.example:3478';
  process.env.VOIID_TURN_STATIC_AUTH_SECRET = 'super-secret-turn-key';
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      iceServers: { urls: 'turn:cf.example:3478', username: 'cf-user', credential: 'cf-cred' },
    }),
  })) as unknown as typeof fetch;
  try {
    const good = await resolveIceServers(USER);
    assert.equal(good.ice_servers[1].username, 'cf-user');

    await new Promise((r) => setTimeout(r, 600)); // past the refresh point
    globalThis.fetch = (async () => { throw new Error('cloudflare is down'); }) as unknown as typeof fetch;

    const degraded = await resolveIceServers(USER);
    assert.equal(degraded.turn_configured, true);
    assert.deepEqual(degraded.ice_servers[1].urls, ['turn:cf.example:3478']);
    assert.equal(degraded.ice_servers[1].username, 'cf-user', 'fell back instead of holding');
  } finally {
    globalThis.fetch = realFetch;
    clearTurnEnv();
  }
});

test('rotating the Cloudflare key id does not serve the old key\'s credential', async () => {
  configureCloudflare('3600');
  const { fetchImpl, count } = countingCloudflareFetch();
  const realFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl;
  try {
    const before = await resolveIceServers(USER);
    assert.equal(before.ice_servers[1].username, 'cf-user-1');
    process.env.VOIID_TURN_CLOUDFLARE_KEY_ID = 'cf-key-rotated';
    const after = await resolveIceServers(USER);
    assert.equal(count(), 2, 'the rotated key was served from the old key\'s cache');
    assert.equal(after.ice_servers[1].username, 'cf-user-2');
  } finally {
    globalThis.fetch = realFetch;
    clearTurnEnv();
  }
});

test('an unconfigured Cloudflare never serves a lease minted earlier', async () => {
  // Removing the env is how a deployment turns Cloudflare OFF. A cache that outlived that
  // would keep routing calls through a provider the operator had just disabled.
  configureCloudflare('3600');
  const { fetchImpl } = countingCloudflareFetch();
  const realFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl;
  try {
    const on = await resolveIceServers(USER);
    assert.equal(on.turn_configured, true);
    delete process.env.VOIID_TURN_CLOUDFLARE_KEY_ID;
    delete process.env.VOIID_TURN_CLOUDFLARE_API_TOKEN;
    const off = await resolveIceServers(USER);
    assert.equal(off.turn_configured, false);
    assert.equal(off.ice_servers.length, 1, 'a disabled provider was still being served');
  } finally {
    globalThis.fetch = realFetch;
    clearTurnEnv();
  }
});
