import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import QRCode from 'qrcode';
import type { Conversation, Message, View } from './protocol';
import './styles.css';

//
// Voiid Web — the UI half.
//
// Everything security-relevant (keys, the vault, the socket, linking) lives in the engine
// worker. This file only DRAWS the View the worker emits and forwards intents back to it, so
// the presentation can change freely without touching what protects the messages.
//

const marker = 'voiid-browser-linked';

// ── Theme ── Light, Dark, or follow the system. Stored per browser as a convenience only;
// storage can be blocked, so every read and write is guarded and "system" is the fallback.
type Theme = 'light' | 'dark' | 'system';
const THEME_KEY = 'voiid-web-theme';
function readTheme(): Theme {
  try { const v = localStorage.getItem(THEME_KEY); return v === 'light' || v === 'dark' ? v : 'system'; } catch { return 'system'; }
}
function applyTheme(theme: Theme) {
  if (theme === 'system') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = theme;
}
// Before the first render, so a chosen theme never flashes the other one.
applyTheme(readTheme());

/** How long a linking code lives. The engine owns expiry; this only scales the countdown bar. */
const CODE_TTL_SECONDS = 300;

type Stage = 'boot' | 'idle' | 'requesting' | 'qr' | 'expired' | 'blocked' | 'error';

function App() {
  const [view, setView] = useState<View>({ phase: 'starting' });
  const [filter, setFilter] = useState('');
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [confirmLogout, setConfirmLogout] = useState(false);
  const [qr, setQr] = useState('');
  const [now, setNow] = useState(Date.now());
  const [requested, setRequested] = useState(false);
  const [profileOpen, setProfileOpen] = useState(false);
  const [contactOpen, setContactOpen] = useState(false);
  const [listFilter, setListFilter] = useState<'all' | 'unread'>('all');
  const worker = useRef<Worker | null>(null);
  const messagesEnd = useRef<HTMLDivElement>(null);
  const send = (type: string, data: Record<string, unknown> = {}) => worker.current?.postMessage({ type, ...data });
  useEffect(() => {
    if (!window.isSecureContext || !navigator.locks || !crypto.subtle) { setView({ phase: 'error', message: 'Use a current browser with secure storage and HTTPS to open Voiid Web.' }); return; }
    let disposed = false, release: (() => void) | undefined;
    navigator.locks.request('voiid-crypto-owner', { ifAvailable: true }, async lock => {
      if (disposed) return;
      if (!lock) { setView({ phase: 'blocked', message: 'Voiid is already open in another tab. Close that tab, then retry here.' }); return; }
      const instance = new Worker('/engine.js', { type: 'module', name: 'voiid-encrypted-messages' });
      worker.current = instance;
      instance.onmessage = ({ data }) => {
        if (disposed) return;
        if (data.type === 'send-queued') { setDraft(current => current === data.text ? '' : current); setSending(false); }
        if (data.type === 'send-failed') setSending(false);
        if (data.type === 'view') setView(data);
        if (data.type === 'linked') { try { localStorage.setItem(marker, '1'); } catch { /* IDB remains authoritative. */ } }
        if (data.type === 'wiped') { try { localStorage.removeItem(marker); } catch { /* non-secret marker only */ } }
      };
      instance.onerror = () => setView({ phase: 'error', message: 'The encrypted messaging engine stopped. Reload before continuing.' });
      let linked = false; try { linked = localStorage.getItem(marker) === '1'; } catch { /* storage checked by worker */ }
      instance.postMessage({ type: 'boot', marker: linked });
      await new Promise<void>(resolve => { release = resolve; });
      instance.terminate(); worker.current = null;
    }).catch(() => setView({ phase: 'error', message: 'Could not secure access to browser storage. Close other tabs and reload.' }));
    const retry = () => send('retry');
    const read = () => { if (document.visibilityState === 'visible' && document.hasFocus()) { send('retry'); send('read'); } };
    window.addEventListener('online', retry); window.addEventListener('focus', read);
    document.addEventListener('visibilitychange', read);
    // Never restore a page from BFCache holding a worker whose ownership lock was released.
    const leave = () => { worker.current?.terminate(); release?.(); };
    const restore = (event: PageTransitionEvent) => { if (event.persisted) location.reload(); };
    window.addEventListener('pagehide', leave); window.addEventListener('pageshow', restore);
    const heartbeat = setInterval(() => send('heartbeat'), 20000);
    return () => { disposed = true; release?.(); clearInterval(heartbeat); window.removeEventListener('online', retry); window.removeEventListener('focus', read); document.removeEventListener('visibilitychange', read); window.removeEventListener('pagehide', leave); window.removeEventListener('pageshow', restore); };
  }, []);
  useEffect(() => { let disposed = false; setQr(''); if (view.qr) QRCode.toDataURL(view.qr, { width: 264, margin: 3, errorCorrectionLevel: 'M', color: { dark: '#101617', light: '#FFFFFF' } }).then(value => { if (!disposed) setQr(value); }).catch(() => setView({ phase: 'error', message: 'Could not draw the QR code. Reload and try again.' })); return () => { disposed = true; }; }, [view.qr]);
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  useEffect(() => { messagesEnd.current?.scrollIntoView({ behavior: 'instant', block: 'end' }); }, [view.selected, view.messages?.length]);
  // A request is "in flight" from the click until the engine answers with a code or a new phase.
  useEffect(() => { setRequested(false); }, [view.qr, view.phase]);

  const expired = view.expiresAt != null && now >= view.expiresAt;
  const status = view.message ? <div className="notice" role="status"><Icon name="info" /><span>{view.message}</span>{view.phase === 'ready' && <button className="notice-action" onClick={() => send('retry')}>Retry</button>}</div> : null;

  if (view.phase !== 'ready') {
    const stage: Stage = view.phase === 'starting' ? 'boot'
      : view.phase === 'blocked' ? 'blocked'
      : view.phase === 'error' ? 'error'
      : view.qr && expired ? 'expired'
      : view.qr && qr ? 'qr'
      : requested || view.qr ? 'requesting'
      : 'idle';
    const remaining = Math.min(CODE_TTL_SECONDS, Math.max(0, Math.ceil(((view.expiresAt || 0) - now) / 1000)));
    return <Welcome
      stage={stage} qr={qr} code={view.verificationCode} remaining={remaining} status={status}
      onLink={() => { setRequested(true); send('link'); }}
      onWipe={() => { if (confirm('Remove this browser in Linked Devices on your phone first. Clear its local data now?')) send('wipe'); }}
    />;
  }

  const chosen = view.conversations?.find(c => c.id === view.selected);
  const available = !!chosen && ['direct', 'self'].includes(chosen.type);
  const unreadTotal = view.conversations?.reduce((n, c) => n + (c.unread_count || 0), 0) ?? 0;
  const shown = (view.conversations ?? [])
    .filter(c => (c.title || '').toLowerCase().includes(filter.toLowerCase()))
    .filter(c => listFilter === 'all' || (c.unread_count || 0) > 0);
  // Our own name, as the conversations we are in already carry it. Nothing extra is fetched.
  const myName = view.conversations?.flatMap(c => c.members ?? []).find(m => m.user_id === view.userId && m.full_name)?.full_name;
  const profile = <ProfileMenu
    name={myName} open={profileOpen} setOpen={setProfileOpen} online={!!view.online} row
    onSignOut={() => { setProfileOpen(false); setConfirmLogout(true); }}
  />;

  return <main className={`messenger ${chosen ? 'has-chat' : ''}`}>
    <aside className="sidebar panel">
      <header className="sidebar-top">
        <Brand />
      </header>
      <div className="sidebar-heading">
        <h1>Chats</h1>
        {unreadTotal > 0 && <span className="count-pill">{unreadTotal} unread</span>}
      </div>
      <label className="search">
        <span className="search-icon" aria-hidden="true"><Icon name="search" /></span>
        <input aria-label="Search chats" placeholder="Search conversations" value={filter} onChange={e => setFilter(e.target.value)} />
      </label>
      <div className="list-filters" role="tablist" aria-label="Filter chats">
        <button role="tab" aria-selected={listFilter === 'all'} onClick={() => setListFilter('all')}>All</button>
        <button role="tab" aria-selected={listFilter === 'unread'} onClick={() => setListFilter('unread')}>Unread{unreadTotal > 0 && <i>{unreadTotal}</i>}</button>
      </div>
      <nav aria-label="Conversations" className="chat-list">
        {shown.map((c, i) => <button
          key={c.id}
          className={`chat-row ${view.selected === c.id ? 'selected' : ''}`}
          style={{ '--i': Math.min(i, 12) } as React.CSSProperties}
          aria-current={view.selected === c.id ? 'page' : undefined}
          onClick={() => { setDraft(''); setContactOpen(false); send('select', { id: c.id, visible: document.hasFocus() }); }}
        >
          <Avatar name={c.title} />
          <span className="chat-row-copy">
            <strong>{c.title || 'Conversation'}</strong>
            <small>{c.type === 'group' ? 'Continue on your phone' : <><Icon name="lock" size={11} />End-to-end encrypted</>}</small>
          </span>
          {!!c.unread_count && <span className="unread">{c.unread_count}</span>}
        </button>)}
        {!view.conversations?.length && <div className="empty-list"><Icon name="chat" size={22} /><p>Start a conversation on your phone. It will appear here.</p></div>}
        {!!view.conversations?.length && !shown.length && <div className="empty-list"><p>{listFilter === 'unread' && !filter ? 'You’re all caught up.' : `No chat matches “${filter}”.`}</p></div>}
      </nav>
      <div className="sidebar-footer">{profile}</div>
    </aside>

    <section className={`conversation panel ${chosen && contactOpen ? 'with-panel' : ''}`} aria-label={chosen?.title || 'Select a conversation'}>
      {chosen ? <>
        <header className="chat-header">
          <button className="back icon-button" aria-label="Back to chats" onClick={() => send('select', { id: undefined })}><Icon name="back" /></button>
          <button className="chat-who" onClick={() => setContactOpen(true)} aria-label={`View ${chosen.title || 'contact'} profile`} aria-expanded={contactOpen}>
            <Avatar name={chosen.title} small />
            <div className="chat-title">
              <h2>{chosen.title}</h2>
              <span className="chat-sub"><Icon name="lock" size={11} />End-to-end encrypted{chosen.type === 'group' ? ' · Group' : chosen.type === 'self' ? ' · Notes to self' : ''}</span>
            </div>
          </button>
          <button className="icon-button info-button" onClick={() => setContactOpen(o => !o)} aria-label="Contact info" aria-pressed={contactOpen}><Icon name="info" /></button>
        </header>
        {status}
        <Messages key={`messages-${chosen.id}`} messages={view.messages || []} userId={view.userId} onHistory={() => send('history')} end={messagesEnd} />
        <Composer
          draft={draft} setDraft={setDraft} available={available} sending={sending}
          onSend={() => { if (draft.trim() && !sending) { setSending(true); send('send', { text: draft }); } }}
        />
        {contactOpen && <ContactPanel key={`contact-${chosen.id}`} conversation={chosen} userId={view.userId} onClose={() => setContactOpen(false)} />}
      </> : <div className="empty-chat">
        <div className="empty-art" aria-hidden="true">
          <span className="float-bubble one" /><span className="float-bubble two" /><span className="float-bubble three" />
          <span className="mark-tile"><img src="/mark.svg" alt="" width="56" height="51" /></span>
        </div>
        <h1>A little more connected.</h1>
        <p>Choose a conversation to start messaging.</p>
        <small><Icon name="shield" size={13} />End-to-end encrypted, from your phone to here.</small>
        {status}
      </div>}
    </section>

    {confirmLogout && <Dialog onClose={() => setConfirmLogout(false)} onConfirm={() => { setConfirmLogout(false); send('logout'); }} />}
  </main>;
}

// ── Linking ───────────────────────────────────────────────────────────────────────────────

function Welcome({ stage, qr, code, remaining, status, onLink, onWipe }: {
  stage: Stage; qr: string; code?: string; remaining: number; status: React.ReactNode;
  onLink: () => void; onWipe: () => void;
}) {
  // Which of the three steps the person is on. Before a code exists they are getting their
  // phone ready (1–2); once it is on screen, scanning and confirming (3) is the only thing left.
  const current = stage === 'qr' ? 3 : stage === 'expired' ? 3 : stage === 'requesting' ? 2 : 1;
  const steps = [
    { title: 'Open Voiid on your phone', detail: 'Use the phone signed in to your account.' },
    { title: 'Go to Settings → Linked Devices', detail: 'Choose Link a Browser.' },
    { title: 'Scan, check, and confirm', detail: 'Match the verification code, then approve on your phone.' },
  ];
  const trouble = stage === 'blocked' || stage === 'error';

  return <main className="welcome">
    <div className="backdrop" aria-hidden="true" />
    <header className="welcome-top">
      <Brand />
      <div className="top-actions">
        <span className="trust-pill"><Icon name="shield" size={14} />Your conversations. Your devices.</span>
        <ThemeSwitch />
      </div>
    </header>

    <section className="link-card" aria-labelledby="link-title">
      <div className="link-copy">
        <span className="eyebrow"><i aria-hidden="true" />A little more room to connect</span>
        <h1 id="link-title">Your Voiid.<br />On your computer.</h1>
        <p className="lede">Stay close to your people, with end-to-end encrypted messages from your browser.</p>
        <ol className={`steps ${trouble ? 'paused' : ''}`}>
          {steps.map((s, i) => {
            const n = i + 1;
            const state = trouble ? 'todo' : n < current ? 'done' : n === current ? 'active' : 'todo';
            return <li key={n} className={state} aria-current={state === 'active' ? 'step' : undefined}>
              <span className="step-mark">{state === 'done' ? <Icon name="check" size={14} /> : n}</span>
              <div><strong>{s.title}</strong><small>{s.detail}</small></div>
            </li>;
          })}
        </ol>
      </div>

      <div className="link-action">
        <div className="stage" data-stage={stage}>
          {/* Keyed on the stage so each state enters with its own transition. */}
          <div key={stage} className="stage-inner">
            {stage === 'boot' && <>
              <div className="qr-skeleton" aria-hidden="true" />
              <p className="stage-title" role="status">Opening secure storage…</p>
              <p className="hint">Your keys are created and kept on this computer.</p>
            </>}

            {stage === 'idle' && <>
              <LinkArt />
              <button className="primary big" onClick={onLink}>Show Linking Code</button>
              <p className="hint">Approve only a code on your own computer.</p>
            </>}

            {stage === 'requesting' && <>
              <LinkArt busy />
              <button className="primary big" disabled aria-busy="true"><span className="spinner" aria-hidden="true" />Creating a secure code…</button>
              <p className="hint">This takes a moment. Keep this tab open.</p>
            </>}

            {stage === 'qr' && <>
              <div className="qr-frame">
                <img className="qr" src={qr} width="264" height="264" alt="Scan this code from Linked Devices in Voiid" />
                <span className="corner tl" /><span className="corner tr" /><span className="corner bl" /><span className="corner br" />
              </div>
              {code && <div className="verify">
                <span>Verification code</span>
                <strong className="verification">{code}</strong>
                <small>Check it matches on your phone before you approve.</small>
              </div>}
              <div className="countdown" aria-live="off">
                <div className="countdown-track"><span style={{ '--left': remaining / CODE_TTL_SECONDS } as React.CSSProperties} className={remaining <= 30 ? 'low' : ''} /></div>
                <span className={`countdown-text ${remaining <= 30 ? 'low' : ''}`}>Code expires in {Math.floor(remaining / 60)}:{String(remaining % 60).padStart(2, '0')}</span>
              </div>
            </>}

            {stage === 'expired' && <>
              <div className="qr-frame expired">
                {qr && <img className="qr" src={qr} width="264" height="264" alt="" aria-hidden="true" />}
                <span className="expired-label"><Icon name="clock" size={18} />Code expired</span>
              </div>
              <button className="primary big" onClick={onLink}>Get a New Code</button>
              <p className="hint">Codes last five minutes so an old one can’t be reused.</p>
            </>}

            {stage === 'blocked' && <>
              <span className="state-icon" aria-hidden="true"><Icon name="tabs" size={28} /></span>
              <p className="stage-title">One secure tab at a time</p>
              <p className="hint wide">Voiid keeps a single encrypted session per browser. Close the other Voiid tab, then reload here.</p>
              <button className="primary big" onClick={() => location.reload()}><Icon name="refresh" size={16} />Reload</button>
            </>}

            {stage === 'error' && <>
              <span className="state-icon warn" aria-hidden="true"><Icon name="alert" size={28} /></span>
              <p className="stage-title">Let’s reconnect</p>
              <button className="primary big" onClick={() => location.reload()}><Icon name="refresh" size={16} />Reload</button>
              <button className="ghost" onClick={onWipe}>Clear Local Data</button>
            </>}
          </div>
        </div>
        {status}
      </div>
    </section>

    <footer className="welcome-footer">
      <span><Icon name="shield" size={14} />Messages stay encrypted between your devices.</span>
      <span><Icon name="key" size={14} />Keys never leave your devices.</span>
      <span className="preview-tag">Preview · 1:1 text messaging</span>
    </footer>
  </main>;
}

/** A laptop and a phone with a secure line drawn between them. */
function LinkArt({ busy }: { busy?: boolean }) {
  return <div className={`link-art ${busy ? 'busy' : ''}`} aria-hidden="true">
    <span className="device laptop"><Icon name="laptop" size={34} /></span>
    <span className="wire"><i /><i /><i /></span>
    <span className="device phone"><Icon name="phone" size={30} /></span>
  </div>;
}

// ── Messenger parts ───────────────────────────────────────────────────────────────────────

function Messages({ messages, userId, onHistory, end }: {
  messages: Message[]; userId?: string; onHistory: () => void; end: React.RefObject<HTMLDivElement | null>;
}) {
  // Only messages that ARRIVE while the chat is open animate in. Remounted per conversation
  // (keyed by the parent), so opening a chat shows its history still, not as a cascade.
  const seen = useRef<Set<string> | null>(null);
  const sorted = [...messages].sort((a, b) => a.created_at.localeCompare(b.created_at));
  const fresh = new Set(seen.current ? sorted.filter(m => !seen.current!.has(m.id)).map(m => m.id) : []);
  useEffect(() => { seen.current = new Set(sorted.map(m => m.id)); });

  // What the list draws: a day divider, a bubble, or ONE note standing in for a run of
  // messages this browser cannot read (sent before it was linked, or attachments).
  type Item = { kind: 'day'; label: string; key: string } | { kind: 'msg'; m: Message } | { kind: 'hidden'; count: number; attachments: number; key: string; last: string };
  const items: Item[] = [];
  let lastDay = '';
  for (const m of sorted) {
    const day = dayLabel(m.created_at);
    if (day !== lastDay) { items.push({ kind: 'day', label: day, key: `d-${m.id}` }); lastDay = day; }
    const unreadable = m.unavailable || (m.content_type && m.content_type !== 'text');
    if (unreadable) {
      const prev = items[items.length - 1];
      if (prev?.kind === 'hidden') { prev.count++; if (m.content_type && m.content_type !== 'text' && !m.unavailable) prev.attachments++; prev.last = m.created_at; }
      else items.push({ kind: 'hidden', count: 1, attachments: m.content_type && m.content_type !== 'text' && !m.unavailable ? 1 : 0, key: `h-${m.id}`, last: m.created_at });
    } else items.push({ kind: 'msg', m });
  }
  const groupKey = (m: Message) => `${m.sender_id}|${dayLabel(m.created_at)}`;
  const close = (a?: Item, b?: Item) => a?.kind === 'msg' && b?.kind === 'msg' && groupKey(a.m) === groupKey(b.m)
    && Math.abs(new Date(b.m.created_at).getTime() - new Date(a.m.created_at).getTime()) < 5 * 60_000;
  const time = (iso: string) => new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return <div className="message-list" role="log" aria-label="Messages" aria-live="polite">
    <div className="message-column">
    <button className="history" onClick={onHistory}><Icon name="up" size={13} />Load Earlier Messages</button>
    <p className="history-note">This browser receives new messages after linking. Earlier messages may only be available on your phone.</p>
    {items.map((it, i) => {
      if (it.kind === 'day') return <div className="day" key={it.key}><span>{it.label}</span></div>;
      if (it.kind === 'hidden') {
        const text = it.attachments === it.count
          ? `${it.count === 1 ? 'An attachment' : `${it.count} attachments`} — open on your phone`
          : `${it.count} ${it.count === 1 ? 'message' : 'messages'} from before this browser was linked — open on your phone`;
        return <div className="system-note" key={it.key}><Icon name="lock" size={13} /><span>{text}</span><time>{time(it.last)}</time></div>;
      }
      const m = it.m;
      const mine = m.sender_id === userId;
      const first = !close(items[i - 1], it), last = !close(it, items[i + 1]);
      return <article key={m.id} className={`bubble ${mine ? 'sent' : 'received'} ${first ? 'first' : ''} ${last ? 'last' : ''} ${fresh.has(m.id) ? 'fresh' : ''}`}>
        <p>{m.text}</p>
        {last && <div className="message-meta">
          <time dateTime={m.created_at}>{time(m.created_at)}</time>
          {mine && m.status && <span className={`tick ${m.status === 'Read' ? 'read' : ''}`}>{m.status}</span>}
        </div>}
      </article>;
    })}
    <div ref={end} />
    </div>
  </div>;
}

function Composer({ draft, setDraft, available, sending, onSend }: {
  draft: string; setDraft: (v: string) => void; available: boolean; sending: boolean; onSend: () => void;
}) {
  const box = useRef<HTMLTextAreaElement>(null);
  // Grow with the text up to a ceiling, then scroll. Set through the CSSOM, which the CSP allows.
  useEffect(() => {
    const el = box.current; if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 160)}px`;
  }, [draft]);
  return <form className={`composer ${available ? '' : 'locked'}`} onSubmit={e => { e.preventDefault(); onSend(); }}>
    <textarea
      ref={box} aria-label="Message" rows={1}
      placeholder={available ? 'Write a message…' : 'Open this group on your phone'}
      disabled={!available} value={draft} onChange={e => setDraft(e.target.value)}
      onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); } }}
    />
    <button className={`send ${sending ? 'sending' : ''}`} disabled={!available || !draft.trim() || sending} aria-label="Send message">
      {sending ? <span className="spinner light" aria-hidden="true" /> : <Icon name="send" size={18} />}
    </button>
  </form>;
}

/** Our own profile: who is signed in here, the theme, and signing this browser out. */
function ProfileMenu({ name, open, setOpen, online, onSignOut, row }: {
  name?: string; open: boolean; setOpen: (v: boolean) => void; online: boolean; onSignOut: () => void; row?: boolean;
}) {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (!box.current?.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onDown); window.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('mousedown', onDown); window.removeEventListener('keydown', onKey); };
  }, [open, setOpen]);
  return <div className="profile" ref={box}>
    <button className={`profile-button ${row ? 'row' : ''}`} onClick={() => setOpen(!open)} aria-haspopup="menu" aria-expanded={open} aria-label="Your profile and settings">
      <span className="profile-avatar"><Avatar name={name || 'You'} small /><span className={`presence ${online ? 'on' : ''}`} aria-hidden="true" /></span>
      {row && <span className="profile-copy"><strong>{name || 'You'}</strong><small>{online ? 'Connected' : 'Connecting…'} · this browser</small></span>}
      {row && <Icon name="more" size={18} />}
    </button>
    {open && <div className="menu" role="menu" aria-label="Your profile">
      <div className="menu-head">
        <Avatar name={name || 'You'} />
        <div><strong>{name || 'You'}</strong><small>This browser · linked to your phone</small></div>
      </div>
      <div className="menu-row"><span>Appearance</span><ThemeSwitch /></div>
      <div className="menu-note"><Icon name="shield" size={14} /><span>Messages here are end-to-end encrypted. Your keys stay on this computer and your phone.</span></div>
      <div className="menu-note"><Icon name="phone" size={14} /><span>Edit your name, photo and privacy on your phone.</span></div>
      <button role="menuitem" className="menu-item danger" onClick={onSignOut}><Icon name="logout" size={16} />Sign out this browser</button>
    </div>}
  </div>;
}

/** The person (or group) in the open chat. */
function ContactPanel({ conversation, userId, onClose }: { conversation: Conversation; userId?: string; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);
  const title = conversation.title || 'Conversation';
  const isGroup = conversation.type === 'group';
  const isSelf = conversation.type === 'self';
  const others = (conversation.members ?? []).filter(m => m.user_id !== userId);
  return <aside className="contact-panel" aria-label={`${title} profile`}>
    <header className="contact-top">
      <span>{isGroup ? 'Group info' : 'Contact info'}</span>
      <button className="icon-button" onClick={onClose} aria-label="Close profile"><Icon name="close" /></button>
    </header>
    <div className="contact-hero">
      <Avatar name={title} large />
      <h3>{title}</h3>
      <p>{isSelf ? 'Notes to yourself' : isGroup ? `${conversation.members?.length ?? 0} members` : 'Direct message'}</p>
    </div>
    <section className="contact-card">
      <div className="contact-line"><span className="line-icon"><Icon name="lock" size={15} /></span><div><strong>End-to-end encrypted</strong><small>Only the people in this chat can read it. Not even Voiid can.</small></div></div>
      <div className="contact-line"><span className="line-icon"><Icon name="shield" size={15} /></span><div><strong>Verify safety number</strong><small>Compare it in person from this chat on your phone.</small></div></div>
    </section>
    {isGroup && others.length > 0 && <section className="contact-card">
      <div className="contact-label">Members</div>
      {others.map(m => <div key={m.user_id} className="member"><Avatar name={m.full_name || 'Member'} small /><span>{m.full_name || 'Member'}</span></div>)}
    </section>}
    <section className="contact-card muted-card">
      <div className="contact-line"><span className="line-icon"><Icon name="phone" size={15} /></span><div><strong>More on your phone</strong><small>{isGroup ? 'Group chats, ' : ''}calls, media, disappearing messages and blocking are on your phone.</small></div></div>
    </section>
  </aside>;
}

function Dialog({ onClose, onConfirm }: { onClose: () => void; onConfirm: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);
  return <div className="modal-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) onClose(); }}>
    <section className="dialog" role="alertdialog" aria-modal="true" aria-labelledby="logout-title" aria-describedby="logout-body">
      <span className="dialog-icon" aria-hidden="true"><Icon name="logout" size={22} /></span>
      <h2 id="logout-title">Sign out this browser?</h2>
      <p id="logout-body">Its access will be revoked and its local messages cleared. Your phone stays signed in.</p>
      <div className="dialog-actions">
        <button className="ghost" onClick={onClose}>Cancel</button>
        <button className="primary danger" autoFocus onClick={onConfirm}>Sign Out</button>
      </div>
    </section>
  </div>;
}

function ThemeSwitch() {
  const [theme, setTheme] = useState<Theme>(readTheme);
  const choose = (next: Theme) => {
    setTheme(next); applyTheme(next);
    try { if (next === 'system') localStorage.removeItem(THEME_KEY); else localStorage.setItem(THEME_KEY, next); } catch { /* not remembered; still applied */ }
  };
  const options: { value: Theme; icon: string; label: string }[] = [
    { value: 'light', icon: 'sun', label: 'Light theme' },
    { value: 'dark', icon: 'moon', label: 'Dark theme' },
    { value: 'system', icon: 'monitor', label: 'Use system theme' },
  ];
  return <div className="theme-switch" role="group" aria-label="Theme">
    {options.map(o => <button key={o.value} type="button" aria-label={o.label} title={o.label} aria-pressed={theme === o.value} onClick={() => choose(o.value)}>
      <Icon name={o.icon} size={15} />
    </button>)}
  </div>;
}

function Brand() {
  return <a className="brand" href="/" aria-label="Voiid Web">
    <img src="/mark.svg" alt="" width="34" height="31" />
    <Wordmark size={23} /><span className="web-label">web</span>
  </a>;
}

/** "Voiid" as type, identical to iOS BrandWordmark and voiid.app's Wordmark. */
function Wordmark({ size }: { size: number }) {
  return <span className="wordmark" style={{ fontSize: size }}>
    <span aria-hidden="true" className="wordmark-glyphs">Vo<span className="wordmark-stem"><span className="wordmark-dot" />ı</span><span className="wordmark-stem"><span className="wordmark-dot" />ı</span>d</span>
    <span className="sr-only">Voiid</span>
  </span>;
}

function Avatar({ name, small, large }: { name?: string; small?: boolean; large?: boolean }) {
  // A stable hue per name from the app's domain palette, so a person keeps their colour.
  const hues = ['tide', 'violet', 'blue', 'amber', 'green'];
  const n = [...(name || 'V')].reduce((h, ch) => h + ch.charCodeAt(0), 0);
  return <span className={`avatar ${small ? 'small' : ''} ${large ? 'large' : ''} hue-${hues[n % hues.length]}`} aria-hidden="true">
    {(name || 'V').slice(0, 1).toUpperCase()}
  </span>;
}

function dayLabel(iso: string): string {
  const d = new Date(iso);
  const today = new Date();
  const yesterday = new Date(); yesterday.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return 'Today';
  if (d.toDateString() === yesterday.toDateString()) return 'Yesterday';
  return d.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short', ...(d.getFullYear() !== today.getFullYear() ? { year: 'numeric' } : {}) });
}

// ── Icons ─────────────────────────────────────────────────────────────────────────────────
// Inline strokes rather than an icon font or package: nothing to fetch, nothing for the CSP
// to allow, and each is a handful of path commands.
const PATHS: Record<string, string> = {
  shield: 'M12 3 5 6v5c0 4.4 3 8.3 7 9.5 4-1.2 7-5.1 7-9.5V6l-7-3Zm-3 9 2 2 4-4',
  lock: 'M7 11V8a5 5 0 0 1 10 0v3M6 11h12v9H6z',
  key: 'M15 7a4 4 0 1 1-3.9 5H9v2H7v2H4v-3l6.1-6.1A4 4 0 0 1 15 7Zm1 1.5h.01',
  info: 'M12 8h.01M11 12h1v5h1M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18Z',
  search: 'm20 20-4.5-4.5M11 17a6 6 0 1 1 0-12 6 6 0 0 1 0 12Z',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  phone: 'M8 3h8a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1Zm3 15h2',
  laptop: 'M5 6h14v9H5zM3 18h18',
  send: 'M12 19V5m-6 6 6-6 6 6',
  back: 'm15 18-6-6 6-6',
  check: 'm5 12 4 4 10-10',
  refresh: 'M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6',
  tabs: 'M4 6h7v4H4zM4 10h16v9H4zM13 6h7v4',
  alert: 'M12 9v4m0 4h.01M10.3 4.3 2.6 18a2 2 0 0 0 1.7 3h15.4a2 2 0 0 0 1.7-3L13.7 4.3a2 2 0 0 0-3.4 0Z',
  clock: 'M12 7v5l3 2M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18Z',
  chat: 'M4 5h16v11H9l-5 4V5Z',
  up: 'm6 15 6-6 6 6',
  logout: 'M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3M10 16l-4-4 4-4M6 12h10',
  sun: 'M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4',
  moon: 'M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5Z',
  monitor: 'M4 5h16v11H4zM9 20h6M12 16v4',
  close: 'M6 6l12 12M18 6 6 18',
};

function Icon({ name, size = 18 }: { name: string; size?: number }) {
  return <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
              strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
    <path d={PATHS[name]} />
  </svg>;
}

createRoot(document.getElementById('root')!).render(<App />);
