#!/usr/bin/env node
// Verify the 1:1 messaging SERVER path end-to-end over HTTP — the contracts the
// apps depend on, including the two bugs fixed on 2026-06-22:
//   • conversations/create returns a FLAT { conversation_id }
//   • GET /devices/:id returns identity_public_key (needed by the receive path)
//
// It does NOT exercise e2e-core crypto (that runs in the apps) — it sends opaque
// random "ciphertext" to prove the relay + storage path reaches Supabase.
//
// Usage (two logged-in accounts' JWTs):
//   API=https://api-dev.voiid.app A_JWT=<jwtA> B_JWT=<jwtB> node verify-1to1.mjs
//
// Grab a JWT from a logged-in app: it's the bearer token the app stores
// (iOS Keychain "jwt" / Android EncryptedSharedPreferences "jwt"), or log it.

const API = (process.env.API || 'https://api-dev.voiid.app').replace(/\/$/, '');
const A = process.env.A_JWT, B = process.env.B_JWT;
if (!A || !B) { console.error('Set A_JWT and B_JWT (two accounts).'); process.exit(2); }

let pass = 0, fail = 0;
const ok = (m) => { console.log(`  ✅ ${m}`); pass++; };
const no = (m) => { console.log(`  ❌ ${m}`); fail++; };

function userId(jwt) {
  try { return JSON.parse(Buffer.from(jwt.split('.')[1], 'base64').toString()).user_id; }
  catch { return null; }
}
async function call(jwt, method, path, body) {
  const res = await fetch(`${API}/${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null; try { json = await res.json(); } catch {}
  return { status: res.status, json };
}
const b64 = (n) => Buffer.from(Array.from({ length: n }, (_, i) => (i * 7 + 3) & 255)).toString('base64');

const uA = userId(A), uB = userId(B);
console.log(`API=${API}\nuserA=${uA} userB=${uB}\n`);

// 1. Register both devices + upload a prekey each (so sessions can start).
for (const [name, jwt] of [['A', A], ['B', B]]) {
  const reg = await call(jwt, 'POST', 'devices/register',
    { platform: 'script', registration_id: 100000 + (name === 'A' ? 1 : 2), identity_public_key: b64(32) });
  if (reg.status === 200 && reg.json?.device_id) {
    ok(`${name} device registered (${reg.json.device_id.slice(0, 8)}…)`);
    const up = await call(jwt, 'POST', 'prekeys/upload',
      { device_id: reg.json.device_id, one_time_prekeys: [{ key_id: 0, public_key: b64(32) }] });
    up.status === 200 ? ok(`${name} prekey uploaded`) : no(`${name} prekey upload → ${up.status} ${JSON.stringify(up.json)}`);
  } else no(`${name} device register → ${reg.status} ${JSON.stringify(reg.json)}`);
}

// 2. A creates a direct conversation with B — assert the FLAT shape (the Android bug).
const create = await call(A, 'POST', 'conversations/create', { type: 'direct', member_id: uB });
const convId = create.json?.conversation_id;
if (create.status === 200 && convId) ok(`conversation created (flat conversation_id ✓): ${convId.slice(0, 8)}…`);
else no(`create → ${create.status} ${JSON.stringify(create.json)} (expected { conversation_id })`);

// 3. A fetches B's prekey bundle — needed to startSession.
const bundle = await call(A, 'GET', `prekeys/${uB}`);
const b0 = bundle.json?.bundles?.[0];
if (b0?.identity_public_key && b0?.one_time_prekey?.public_key) ok('B prekey bundle has identity + one_time_prekey');
else no(`prekeys/${uB} → ${bundle.status} ${JSON.stringify(bundle.json)}`);

// 4. A fetches B's devices — assert identity_public_key present (the receive-path fix).
const devs = await call(A, 'GET', `devices/${uB}`);
const d0 = devs.json?.devices?.[0];
if (d0?.identity_public_key) ok('devices/:id returns identity_public_key (receive-path fix ✓)');
else no(`devices/${uB} missing identity_public_key → ${JSON.stringify(devs.json)}`);

// 5. A sends an (opaque) message → assert it reaches the server (Supabase).
if (convId) {
  const send = await call(A, 'POST', 'messages/send', { conversation_id: convId, ciphertext: b64(64) });
  if (send.status === 200 && send.json?.message_id) ok(`message accepted → id ${send.json.message_id.slice(0, 8)}… (in Supabase)`);
  else no(`messages/send → ${send.status} ${JSON.stringify(send.json)}`);

  // 6. B reads the conversation back → assert the message is there.
  const hist = await call(B, 'GET', `messages/conversation/${convId}`);
  const got = hist.json?.messages?.some((m) => m.ciphertext);
  got ? ok('B fetched the conversation and sees the message') : no(`B history → ${hist.status} ${JSON.stringify(hist.json)}`);
}

console.log(`\n${fail === 0 ? '🎉 PASS' : '⚠️  FAIL'} — ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
