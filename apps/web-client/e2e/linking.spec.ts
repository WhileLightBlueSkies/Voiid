import { test, expect } from '@playwright/test';
import { createHash, randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const artifacts = fileURLToPath(new URL('../test-results/', import.meta.url));
const uid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', peer = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const did = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', peerDid = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', cid = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
function native(value: object) {
  const result = spawnSync(fileURLToPath(new URL('../../../packages/e2e-core/bindings/wasm/target/debug/examples/interop', import.meta.url)), [], { input: JSON.stringify(value), encoding: 'utf8' });
  expect(result.status, result.stderr || result.error?.message).toBe(0); return JSON.parse(result.stdout);
}
async function fixture(context: any, page: any) {
  const phone = native({ op: 'new' });
  const qrToken = randomBytes(24).toString('base64url'), proof = randomBytes(32).toString('base64url');
  let identity = '', approved = false, failSend = false, sent: any[] = [], pending: any[] = [];
  let nativeSession: string | undefined; let acknowledgements = 0;
  const canonical = (key: string) => Buffer.from(key, 'base64').toString('base64');
  await context.route('**/api/v1/**', async (route: any) => {
    const req = route.request(), path = new URL(req.url()).pathname.replace('/api/v1', ''), body = req.postDataJSON();
    let result: any = {};
    if (path === '/linking/request') { identity = body.identity_public_key; result = { link_token: qrToken, poll_secret: proof, expires_in: 300 }; }
    else if (path.startsWith('/linking/poll/')) { expect(req.headers()['x-link-proof']).toBe(proof); result = approved ? { status: 'approved', token: 'isolated-test-session', user_id: uid, device_id: did } : { status: 'pending' }; }
    else if (path === '/prekeys/upload') result = { uploaded: true };
    else if (path === '/prekeys/count') result = { available: 50 };
    else if (path === '/conversations') result = { conversations: [{ id: cid, type: 'direct', name: null, unread_count: 0 }] };
    else if (path === `/conversations/${cid}`) result = { members: [{ user_id: uid, full_name: 'You' }, { user_id: peer, full_name: 'Alex' }] };
    else if (path.startsWith('/messages/pending/')) result = { messages: pending, next_cursor: null };
    else if (path.startsWith('/messages/conversation/')) result = { messages: [], next_cursor: null };
    else if (path === `/devices/${peer}`) result = { devices: [{ id: peerDid, identity_public_key: canonical(phone.bundle.identity_key) }] };
    else if (path === `/devices/${uid}`) result = { devices: [] };
    else if (path === `/prekeys/${peer}`) result = { bundles: [{ device_id: peerDid, identity_public_key: canonical(phone.bundle.identity_key), one_time_prekey: { public_key: canonical(phone.bundle.one_time_keys[0]) } }] };
    else if (path === '/messages/send') {
      sent.push(body);
      if (failSend) { failSend = false; await route.fulfill({ status: 503, json: {} }); return; }
      const wire = JSON.parse(Buffer.from(body.messages[0].ciphertext, 'base64').toString());
      if (!nativeSession) {
        const received = native({ op: 'accept', identity: phone.identity, peer: identity, wire: JSON.stringify({ msg_type: wire.t, body: wire.b }), reply: 'Hello from the native core 👋' });
        expect(received.text).toBe('Hello <script>not markup</script>'); nativeSession = received.session;
        const reply = JSON.parse(received.wire);
        pending = [{ id: 'ffffffff-ffff-4fff-8fff-ffffffffffff', conversation_id: cid, sender_id: peer, sender_device_id: peerDid, ciphertext: Buffer.from(JSON.stringify({ t: reply.msg_type, b: reply.body })).toString('base64'), content_type: 'text', created_at: new Date().toISOString() }];
      }
      result = { message_id: body.client_message_id };
    } else if (path === '/messages/ack') {
      // Inspect only this isolated test context. ACK must follow an encrypted durable commit.
      const stored = await page.evaluate(async () => {
        const db = await new Promise<IDBDatabase>(resolve => { const request = indexedDB.open('voiid-companion'); request.onsuccess = () => resolve(request.result); });
        const get = (key: string) => new Promise<any>(resolve => { const request = db.transaction('vault').objectStore('vault').get(key); request.onsuccess = () => resolve(request.result); });
        const key = await get('key'), snapshot = await get('snapshot');
        const value = JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: snapshot.iv, additionalData: new TextEncoder().encode('voiid-companion:v1') }, key, snapshot.blob)));
        db.close(); return value.messages.map((m: any) => m.id);
      });
      for (const id of body.message_ids) expect(stored).toContain(id);
      acknowledgements++;
      pending = pending.filter(m => !body.message_ids.includes(m.id)); result = { acknowledged: body.message_ids.length };
    } else if (path === '/linking/socket-ticket') { await route.fulfill({ status: 503, json: {} }); return; }
    else if (path === '/receipts/mark') result = { marked: true };
    else throw new Error(`Unexpected test route: ${path}`);
    await route.fulfill({ json: result });
  });
  return { qrToken, proof, approve: () => { approved = true; }, failNextSend: () => { failSend = true; }, sent: () => sent, acknowledgements: () => acknowledgements,
    code: () => createHash('sha256').update(Buffer.from(identity, 'base64')).digest('hex').slice(0, 12).toUpperCase().match(/.{4}/g)!.join(' ') };
}
test('real WASM linking screen, iOS themes, QR proof separation and tab ownership', async ({ context, page }) => {
  const f = await fixture(context, page);
  const errors: string[] = []; page.on('pageerror', error => errors.push(error.message));
  const response = await page.goto('/');
  expect(response!.headers()['content-security-policy']).toContain("frame-ancestors 'none'");
  await page.getByRole('button', { name: 'Show Linking Code' }).click();
  await expect(page.getByAltText('Scan this code from Linked Devices in Voiid')).toBeVisible();
  await expect(page.getByText(f.code(), { exact: true })).toBeVisible();
  expect(await page.locator('body').textContent()).not.toContain(f.proof);
  await page.screenshot({ path: artifacts + 'linking-light.png', fullPage: true });
  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' });
  await page.screenshot({ path: artifacts + 'linking-dark.png', fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: artifacts + 'linking-mobile.png', fullPage: true });
  const second = await context.newPage(); await second.goto('/');
  await expect(second.getByText('One secure tab at a time')).toBeVisible();
  expect(errors).toEqual([]);
});
test('browser sends native-decryptable text, retries exact ciphertext and restores a durable ratchet', async ({ context, page }) => {
  const f = await fixture(context, page);
  await page.goto('/'); await page.getByRole('button', { name: 'Show Linking Code' }).click();
  await expect(page.getByAltText('Scan this code from Linked Devices in Voiid')).toBeVisible();
  f.approve();
  await page.getByRole('button', { name: /Alex/ }).click();
  f.failNextSend();
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Hello <script>not markup</script>');
  await page.getByRole('button', { name: 'Send message', exact: true }).click();
  await expect(page.getByText('Hello <script>not markup</script>', { exact: true })).toBeVisible();
  await expect.poll(() => f.sent().length).toBe(1);
  await page.getByRole('button', { name: 'Retry', exact: true }).click();
  await expect.poll(() => f.sent().length).toBe(2);
  expect(f.sent()[0]).toEqual(f.sent()[1]);
  await page.reload();
  await page.getByRole('button', { name: /Alex/ }).click();
  await expect(page.getByText('Hello from the native core 👋', { exact: true })).toBeVisible();
  await expect(page.getByText('Hello <script>not markup</script>', { exact: true })).toBeVisible();
  await page.screenshot({ path: artifacts + 'conversation-light.png', fullPage: true });
  await page.emulateMedia({ colorScheme: 'dark' });
  await expect(page.locator('.chat-row.selected')).toHaveCSS('background-color', 'rgb(18, 53, 56)');
  await page.screenshot({ path: artifacts + 'conversation-dark.png', fullPage: true });
  expect(await page.evaluate(() => Object.keys(localStorage))).toEqual(['voiid-browser-linked']);
});

test('a storage failure stops ACK, and reload decrypts the retained delivery', async ({ context, page }) => {
  const f = await fixture(context, page);
  await context.route('**/engine.js', async route => {
    const response = await route.fetch();
    const injected = `let failWrites = false;
      self.addEventListener('message', event => { if (event.data.type === 'retry') failWrites = true; });
      const original = IDBDatabase.prototype.transaction;
      IDBDatabase.prototype.transaction = function(...args) {
        if (failWrites && args[1] === 'readwrite') throw new DOMException('Test storage quota failure', 'QuotaExceededError');
        return original.apply(this, args);
      };`;
    await route.fulfill({ response, body: injected + await response.text() });
  });
  await page.goto('/'); await page.getByRole('button', { name: 'Show Linking Code' }).click();
  await expect(page.getByAltText('Scan this code from Linked Devices in Voiid')).toBeVisible(); f.approve();
  await page.getByRole('button', { name: /Alex/ }).click();
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Hello <script>not markup</script>');
  await page.getByRole('button', { name: 'Send message', exact: true }).click();
  await expect.poll(() => f.sent().length).toBe(1);
  await page.getByRole('button', { name: 'Retry', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Clear Local Data' })).toBeVisible();
  expect(f.acknowledgements()).toBe(0);
  await context.unroute('**/engine.js'); await page.reload();
  await page.getByRole('button', { name: /Alex/ }).click();
  await expect(page.getByText('Hello from the native core 👋', { exact: true })).toBeVisible();
  expect(f.acknowledgements()).toBe(1);
});

test('an older backend without a redemption proof never produces a linking QR', async ({ context, page }) => {
  await context.route('**/api/v1/linking/request', route => route.fulfill({ json: { link_token: 'a'.repeat(32), expires_in: 300 } }));
  await page.goto('/');
  await page.getByRole('button', { name: 'Show Linking Code' }).click();
  await expect(page.getByText('This server needs the secure browser-linking update. No linking code has been displayed.')).toBeVisible();
  await expect(page.getByAltText('Scan this code from Linked Devices in Voiid')).toHaveCount(0);
});
