import init, { WebIdentity, WebSession, prekey_session_id } from '../../../packages/e2e-core/bindings/wasm/pkg/voiid_e2e.js';
import { Vault } from './vault';
import { base64ToBytes, bytesToBase64, encodeWire, decodeWire, type Conversation, type Message, type View } from './protocol';

type Bundle = { identity_key: string; signing_key: string; one_time_keys: string[]; fallback_key?: string };
type SessionRecord = { device: string; owner: string; id: string; pickle: string };
type Outgoing = { client_message_id: string; conversation_id: string; sender_device_id: string; content_type: string; messages: { recipient_device_id: string; ciphertext: string }[] };
type State = {
  version: 1; key: string; identity: string; bundle: Bundle; registration: number;
  auth?: { token: string; user_id: string; device_id: string };
  link?: { link_token: string; poll_secret: string; expiresAt: number };
  upload?: unknown; published?: boolean; nextPrekeyId?: number; refill?: unknown;
  sessions: SessionRecord[]; pins: Record<string, { owner: string; key: string }>;
  conversations: Conversation[]; messages: Message[]; outbox: Outgoing[];
};

/** All intents, network arrivals and ratchet writes go through one promise queue.
 * The host holds a Web Lock for this worker's entire lifetime. */
let queue = Promise.resolve();
let vault: Vault | undefined, state: State | undefined, identity: WebIdentity | undefined;
let selected: string | undefined, fatal = false, socket: WebSocket | undefined;
let timer: ReturnType<typeof setTimeout> | undefined;
let online = false, lastKeyCheck = 0;
const historyCursors = new Map<string, string | null>();
const emit = (view: View) => postMessage({ type: 'view', ...view });
function ready(message?: string) {
  emit({ phase: 'ready', userId: state!.auth!.user_id, conversations: state!.conversations,
    messages: state!.messages.filter(m => m.conversation_id === selected).map(({ ciphertext, ...visible }) => visible), selected, online, message });
}
function enqueue(work: () => Promise<void>, recovery = false) {
  queue = queue.then(async () => { if (!fatal || recovery) await work(); }).catch(error => {
    const message = error instanceof Error ? error.message : 'Operation failed. Please retry.';
    if (state?.auth && !fatal) ready(message); else emit({ phase: 'error', message });
  });
}
async function save() {
  try { await vault!.save(state); }
  catch (error) { fatal = true; socket?.close(); clearTimeout(timer); throw new Error('Could not save encrypted data. Free browser storage and reload before continuing.'); }
}
async function api<T = any>(path: string, body?: unknown, method = body === undefined ? 'GET' : 'POST', extra: Record<string, string> = {}): Promise<T> {
  const response = await fetch(`/api/v1${path}`, { method, credentials: 'omit', cache: 'no-store', redirect: 'error',
    headers: { ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...(state?.auth ? { Authorization: `Bearer ${state.auth.token}` } : {}), ...extra },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(20_000) });
  if (response.status === 401 && state?.auth) { await erase(); throw new Error('This browser was signed out. Link it again from your phone.'); }
  if (!response.ok) {
    const error = new Error(response.status === 429 ? 'Too many requests. Wait a little and retry.' : response.status === 404 ? 'This link or item has expired.' : 'The server could not complete this request.');
    Object.assign(error, { status: response.status }); throw error;
  }
  return response.json() as Promise<T>;
}
async function erase() {
  socket?.close(); socket = undefined; clearTimeout(timer); identity?.free(); identity = undefined;
  vault?.close(); vault = undefined; state = undefined; online = false; selected = undefined;
  await Vault.wipe(); postMessage({ type: 'wiped' });
}
async function boot(marker: boolean) {
  await init({ module_or_path: '/crypto/voiid_e2e_bg.wasm' });
  vault = await Vault.open(marker); state = await vault.read<State>();
  if (!state) { emit({ phase: 'link' }); return; }
  if (state.version !== 1) throw new Error('Unsupported browser storage. Remove this browser on your phone and link it again.');
  identity = WebIdentity.restore(state.identity, base64ToBytes(state.key));
  if (state.auth) await connected(); else if (state.link) await pollLink(); else emit({ phase: 'link' });
}
async function link() {
  if (state?.auth) throw new Error('Sign out before linking another session.');
  clearTimeout(timer); identity?.free(); identity = undefined;
  // A fresh attempt needs a fresh registration, including after a lost approval response.
  {
    identity = new WebIdentity(); const key = crypto.getRandomValues(new Uint8Array(32));
    const bundle: Bundle = JSON.parse(identity.publish_bundle(50));
    state = { version: 1, key: bytesToBase64(key), identity: identity.export_encrypted(key), bundle,
      registration: (crypto.getRandomValues(new Uint32Array(1))[0] % 2147483646) + 1,
      sessions: [], pins: {}, conversations: [], messages: [], outbox: [] };
    key.fill(0); await save();
  }
  const response = await api<{ link_token: string; poll_secret: string; expires_in: number }>('/linking/request', {
    platform: 'web', registration_id: state.registration, identity_public_key: state.bundle.identity_key, device_name: 'Voiid browser' });
  if (typeof response.link_token !== 'string' || !/^[A-Za-z0-9_-]{32}$/.test(response.link_token) ||
      typeof response.poll_secret !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(response.poll_secret) ||
      !Number.isFinite(response.expires_in) || response.expires_in <= 0 || response.expires_in > 300) {
    throw new Error('This server needs the secure browser-linking update. No linking code has been displayed.');
  }
  state.link = { link_token: response.link_token, poll_secret: response.poll_secret, expiresAt: Date.now() + response.expires_in * 1000 };
  await save(); await pollLink();
}
async function pollLink() {
  const pending = state?.link; if (!pending) return;
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', base64ToBytes(state!.bundle.identity_key)));
  const verificationCode = Array.from(hash.subarray(0, 6), b => b.toString(16).padStart(2, '0')).join('').toUpperCase().match(/.{4}/g)!.join(' ');
  emit({ phase: 'link', verificationCode, qr: `voiid://link?token=${encodeURIComponent(pending.link_token)}`, expiresAt: pending.expiresAt });
  clearTimeout(timer);
  timer = setTimeout(() => enqueue(async () => {
    if (Date.now() >= pending.expiresAt) { emit({ phase: 'link', message: 'This QR code expired. Start a new link.' }); return; }
    const result = await api('/linking/poll/' + encodeURIComponent(pending.link_token), undefined, 'GET', { 'X-Link-Proof': pending.poll_secret });
    if (result.status !== 'approved') { await pollLink(); return; }
    state!.auth = { token: result.token, user_id: result.user_id, device_id: result.device_id }; delete state!.link;
    await save(); postMessage({ type: 'linked' }); await connected();
  }), 2000);
}
async function publish() {
  if (state!.published) return;
  if (!state!.upload) {
    const bundle = state!.bundle;
    const first = (crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000_000) + 1;
    state!.nextPrekeyId = first + 101;
    state!.upload = { device_id: state!.auth!.device_id,
      one_time_prekeys: bundle.one_time_keys.map((public_key, i) => ({ key_id: first + i, public_key })),
      ...(bundle.fallback_key ? { signed_prekey: { key_id: first + 100, public_key: bundle.fallback_key } } : {}) };
    await save();
  }
  await api('/prekeys/upload', state!.upload); state!.published = true; delete state!.upload; await save();
}
async function replenish() {
  if (!state?.auth || !state.published || Date.now() - lastKeyCheck < 300000) return;
  if (!state.refill) {
    const { available } = await api<{ available: number }>(`/prekeys/count?device_id=${state.auth.device_id}`);
    if (available >= 15) { lastKeyCheck = Date.now(); return; }
    const bundle: Bundle = JSON.parse(identity!.publish_bundle(50));
    const first = state.nextPrekeyId ?? 1500000000;
    if (first > 2147483500) throw new Error('Relink this browser to renew its encryption keys.');
    state.nextPrekeyId = first + 50;
    state.refill = { device_id: state.auth.device_id, one_time_prekeys: bundle.one_time_keys.map((public_key, i) => ({ key_id: first + i, public_key })) };
    state.identity = identity!.export_encrypted(base64ToBytes(state.key));
    await save();
  }
  await api('/prekeys/refresh', state.refill); delete state.refill; await save(); lastKeyCheck = Date.now();
}
async function connected() {
  await publish(); await replenish(); await conversations(); await sync(); await flush(); await connectSocket(); ready();
}
async function conversations() {
  const result = await api<{ conversations: Conversation[] }>('/conversations');
  state!.conversations = result.conversations.map(c => ({ ...c, ...state!.conversations.find(old => old.id === c.id), unread_count: c.unread_count }));
  for (const c of state!.conversations.filter(c => !c.members)) {
    const detail = await api<{ members: Conversation['members'] }>(`/conversations/${c.id}`);
    c.members = detail.members;
    c.title = c.name || detail.members?.filter(m => m.user_id !== state!.auth!.user_id).map(m => m.full_name || 'Contact').join(', ') || 'Notes to self';
  }
  await save();
}
async function deviceKeys(user: string): Promise<{ id: string; identity_public_key: string }[]> {
  const result = await api<{ devices: { id: string; identity_public_key: string }[] }>(`/devices/${user}`);
  for (const d of result.devices) {
    const previous = state!.pins[d.id];
    if (previous && (previous.key !== d.identity_public_key || previous.owner !== user)) throw new Error('A contact’s device identity changed. Verify it on your phone before continuing.');
    if (base64ToBytes(d.identity_public_key).length !== 32) throw new Error('Invalid device identity.');
    state!.pins[d.id] = { owner: user, key: d.identity_public_key };
  }
  return result.devices;
}
function rememberSession(device: string, owner: string, session: WebSession) {
  const id = session.id(), pickle = session.export_encrypted(base64ToBytes(state!.key));
  state!.sessions = state!.sessions.filter(s => !(s.device === device && s.id === id));
  state!.sessions.push({ device, owner, id, pickle });
}
async function decrypt(message: Message): Promise<Message> {
  if (!message.ciphertext || !message.sender_device_id) return { ...message, unavailable: true };
  const device = message.sender_device_id;
  if (!state!.pins[device]) await deviceKeys(message.sender_id);
  const pin = state!.pins[device];
  if (!pin || pin.owner !== message.sender_id) return { ...message, unavailable: true };
  let wire: string, incomingId: string | undefined;
  try { wire = decodeWire(message.ciphertext); incomingId = prekey_session_id(wire); }
  catch { return { ...message, unavailable: true }; }
  const candidates = state!.sessions.filter(s => s.device === device && s.owner === message.sender_id && (!incomingId || s.id === incomingId)).reverse();
  for (const record of candidates) {
    const session = WebSession.restore(record.pickle, base64ToBytes(state!.key));
    try {
      const text = new TextDecoder('utf-8').decode(session.decrypt(wire));
      rememberSession(device, message.sender_id, session); return { ...message, text, unavailable: false };
    } catch { /* try another established session without persisting a failed ratchet */ }
    finally { session.free(); }
  }
  if (!incomingId || candidates.length) return { ...message, unavailable: true };
  try {
    const accepted = identity!.accept(pin.key, wire), session = accepted.take_session();
    try {
      const text = new TextDecoder('utf-8').decode(accepted.plaintext());
      rememberSession(device, message.sender_id, session);
      state!.identity = identity!.export_encrypted(base64ToBytes(state!.key));
      return { ...message, text, unavailable: false };
    } finally { session.free(); accepted.free(); }
  } catch { return { ...message, unavailable: true }; }
}
async function ingest(messages: Message[], acknowledge: boolean) {
  const ids: string[] = [];
  for (const incoming of messages) {
    const existing = state!.messages.find(m => m.id === incoming.id);
    if (!existing) state!.messages.push(await decrypt(incoming));
    ids.push(incoming.id);
  }
  // Ratchets, ciphertext, plaintext read model and dedup ids commit together, BEFORE ACK.
  await save();
  if (acknowledge && ids.length) await api('/messages/ack', { device_id: state!.auth!.device_id, message_ids: ids });
}
async function sync() {
  let cursor: string | null = null;
  do {
    const response: { messages: Message[]; next_cursor: string | null } = await api(`/messages/pending/${state!.auth!.user_id}?limit=100${cursor ? '&cursor=' + encodeURIComponent(cursor) : ''}`);
    await ingest(response.messages, true); cursor = response.next_cursor;
  } while (cursor && state?.auth && !fatal);
  ready();
}
async function history(id: string) {
  const cursor = historyCursors.get(id);
  if (cursor === null) return;
  const response = await api<{ messages: Message[]; next_cursor: string | null }>(`/messages/conversation/${id}?limit=50${cursor ? '&cursor=' + encodeURIComponent(cursor) : ''}`);
  await ingest([...response.messages].reverse().map(m => ({ ...m, conversation_id: id })), false);
  historyCursors.set(id, response.next_cursor); ready();
}
async function send(text: string) {
  if (typeof text !== 'string') return;
  // Prepare in a snapshot: a failed recipient lookup cannot advance only some ratchets.
  const before = structuredClone(state!);
  try { await prepareSend(text); }
  catch (error) { if (!fatal && state?.auth) state = before; postMessage({ type: 'send-failed' }); throw error; }
  postMessage({ type: 'send-queued', text });
  ready(); await flush();
}
async function prepareSend(text: string) {
  const conversation = state!.conversations.find(c => c.id === selected);
  if (!conversation || !['direct', 'self'].includes(conversation.type)) throw new Error('Open this group on your phone. Browser group encryption is not available yet.');
  if (!text.trim() || new TextEncoder().encode(text).length > 64 * 1024) throw new Error('Enter a message under 64 KB.');
  const targets: Outgoing['messages'] = [];
  for (const owner of new Set(conversation.members!.map(m => m.user_id))) {
    const devices = await deviceKeys(owner);
    let bundles: any[] | undefined;
    for (const d of devices.filter(d => d.id !== state!.auth!.device_id)) {
      const record = state!.sessions.filter(s => s.device === d.id && s.owner === owner).at(-1);
      let session: WebSession;
      if (record) session = WebSession.restore(record.pickle, base64ToBytes(state!.key));
      else {
        bundles ??= (await api(`/prekeys/${owner}`)).bundles;
        const bundle = bundles!.find(b => b.device_id === d.id);
        if (!bundle || bundle.identity_public_key !== state!.pins[d.id].key) throw new Error('Device keys changed. Retry after checking your phone.');
        const prekey = bundle.one_time_prekey?.public_key || bundle.signed_prekey?.public_key;
        if (!prekey) throw new Error('A recipient device is not ready. Retry shortly.');
        session = identity!.initiate(bundle.identity_public_key, prekey);
      }
      try { targets.push({ recipient_device_id: d.id, ciphertext: encodeWire(session.encrypt(new TextEncoder().encode(text))) }); rememberSession(d.id, owner, session); }
      finally { session.free(); }
    }
  }
  if (!targets.length) throw new Error('No recipient device is currently available.');
  const id = crypto.randomUUID();
  state!.outbox.push({ client_message_id: id, conversation_id: conversation.id, sender_device_id: state!.auth!.device_id, content_type: 'text', messages: targets });
  state!.messages.push({ id, conversation_id: conversation.id, sender_id: state!.auth!.user_id, text, created_at: new Date().toISOString(), status: 'Sending' });
  await save();
}
async function flush() {
  for (const payload of [...state!.outbox]) {
    const result = await api<{ message_id: string }>('/messages/send', payload);
    const message = state!.messages.find(m => m.id === payload.client_message_id);
    if (message) { message.id = result.message_id; message.status = 'Sent'; }
    state!.outbox = state!.outbox.filter(p => p.client_message_id !== payload.client_message_id);
    await save(); ready();
  }
}
async function markRead() {
  if (!selected) return;
  await api(`/receipts/conversation/${selected}/read`, {
    device_id: state!.auth!.device_id, read_before: new Date().toISOString(),
  });
}

async function connectSocket() {
  if (socket || !state?.auth) return;
  try { await openSocket(); } catch (error) {
    if (state?.auth && !fatal) { clearTimeout(timer); timer = setTimeout(() => enqueue(connectSocket), 3000); }
    throw error;
  }
}
async function openSocket() {
  const { ticket } = await api<{ ticket: string }>('/linking/socket-ticket', {});
  const url = new URL('/live', self.location.origin); url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'; url.searchParams.set('ticket', ticket);
  const current = socket = new WebSocket(url);
  current.onopen = () => enqueue(async () => { if (socket !== current) return; online = true; await sync(); await flush(); ready(); });
  current.onmessage = event => enqueue(async () => {
    if (socket !== current || !state?.auth) return;
    let frame: any; try { frame = JSON.parse(event.data); } catch { return; }
    if (frame.type === 'force_signout' && (!frame.device_id || frame.device_id === state.auth.device_id)) { await erase(); emit({ phase: 'error', message: 'This browser was signed out from your phone. Reload to link again.' }); return; }
    if (frame.type === 'message') { await sync(); if (!state.conversations.some(c => c.id === frame.conversation_id)) await conversations(); ready(); }
    if (frame.type === 'receipt') { const message = state.messages.find(m => m.id === frame.message_id); if (message && message.sender_id === state.auth.user_id) { message.status = frame.status === 'read' ? 'Read' : 'Delivered'; await save(); ready(); } }
  });
  current.onclose = event => {
    if (socket !== current) return; socket = undefined; online = false;
    if ([4401, 4403].includes(event.code)) { enqueue(async () => { await erase(); emit({ phase: 'error', message: 'Your browser session ended. Reload to link again.' }); }); return; }
    if (state?.auth && !fatal) { ready('Reconnecting…'); clearTimeout(timer); timer = setTimeout(() => enqueue(connectSocket), 3000); }
  };
}
self.onmessage = event => enqueue(async () => {
  const intent = event.data;
  switch (intent.type) {
    case 'boot': await boot(intent.marker === true); break;
    case 'link': await link(); break;
    case 'select': selected = state?.conversations.some(c => c.id === intent.id) ? intent.id : undefined; ready(); if (selected) { await history(selected); if (intent.visible) await markRead(); } break;
    case 'history': if (selected) await history(selected); break;
    case 'send': await send(intent.text); break;
    case 'retry': if (state?.auth) { await sync(); await flush(); await connectSocket(); } else if (state?.link) await pollLink(); break;
    case 'read': if (state?.auth) await markRead(); break;
    case 'heartbeat': if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'heartbeat' })); if (state?.auth) await replenish(); break;
    case 'logout':
      if (state?.auth) await api(`/devices/${state.auth.device_id}`, undefined, 'DELETE');
      await erase(); vault = await Vault.open(); emit({ phase: 'link' }); break;
    case 'wipe': await erase(); fatal = false; vault = await Vault.open(); emit({ phase: 'link' }); break;
  }
}, event.data?.type === 'wipe');
