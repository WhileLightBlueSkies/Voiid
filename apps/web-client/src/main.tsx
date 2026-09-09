import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import QRCode from 'qrcode';
import type { View } from './protocol';
import './styles.css';

const marker = 'voiid-browser-linked';
function App() {
  const [view, setView] = useState<View>({ phase: 'starting' });
  const [filter, setFilter] = useState('');
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [confirmLogout, setConfirmLogout] = useState(false);
  const [qr, setQr] = useState('');
  const [now, setNow] = useState(Date.now());
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
  const chosen = view.conversations?.find(c => c.id === view.selected);
  const available = chosen && ['direct', 'self'].includes(chosen.type);
  const expired = view.expiresAt != null && now >= view.expiresAt;
  const status = view.message ? <div className="notice" role="status">{view.message}{view.phase === 'ready' && <button onClick={() => send('retry')}>Retry</button>}</div> : null;
  const brand = <a className="brand" href="/" aria-label="Voiid Web"><img src="/mark.svg" alt="" width="32" height="32" /><span>Voiid<span className="web-label">web</span></span></a>;
  return view.phase !== 'ready' ? <main className="welcome">
    <header>{brand}<span className="private-label">Your conversations. Your devices.</span></header>
    <section className="link-card" aria-labelledby="link-title">
      <div className="link-copy"><span className="eyebrow">A little more room to connect</span><h1 id="link-title">Your Voiid.<br />On your computer.</h1><p>Stay close to your people, with end-to-end encrypted messages from your browser.</p>
        <ol className="steps"><li><span>1</span><div>Open Voiid on your phone<small>Use the phone signed in to your account.</small></div></li><li><span>2</span><div>Go to Settings → Linked Devices<small>Choose Link a Browser.</small></div></li><li><span>3</span><div>Scan, check, and confirm<small>Match the verification code, then approve on your phone.</small></div></li></ol>
      </div>
      <div className="link-action">
        {view.phase === 'starting' ? <div className="qr-placeholder" role="status">Opening secure storage…</div> : view.phase === 'link' ? <>
          {qr && !expired ? <img className="qr" src={qr} width="264" height="264" alt="Scan this code from Linked Devices in Voiid" /> : <div className="qr-placeholder"><svg viewBox="0 0 64 64" width="64" height="64" aria-hidden="true"><path d="M8 24V8h16M40 8h16v16M56 40v16H40M24 56H8V40M24 24h16v16H24Z" fill="none" stroke="currentColor" strokeWidth="3" /></svg><button className="primary" onClick={() => send('link')}>{expired ? 'Get a New Code' : 'Show Linking Code'}</button></div>}
          {view.verificationCode && !expired && <><span className="muted">Verification code</span><strong className="verification">{view.verificationCode}</strong></>}
          <p className="hint">{qr && !expired ? `Code expires in ${Math.min(300, Math.max(0, Math.ceil(((view.expiresAt || 0) - now) / 1000)))} seconds` : 'Approve only a code on your own computer.'}</p>
        </> : <div className="qr-placeholder"><p>{view.phase === 'blocked' ? 'One secure tab at a time' : 'Let’s reconnect'}</p><button className="primary" onClick={() => location.reload()}>Reload</button>{view.phase === 'error' && <button onClick={() => { if (confirm('Remove this browser in Linked Devices on your phone first. Clear its local data now?')) send('wipe'); }}>Clear Local Data</button>}</div>}
        {status}
      </div>
    </section>
    <footer className="welcome-footer"><span className="lock-icon" aria-hidden="true">◇</span> Messages stay encrypted between your devices.<span>Preview · 1:1 text messaging</span></footer>
  </main> : <main className={`messenger ${chosen ? 'has-chat' : ''}`}>
    <aside className="sidebar"><header>{brand}<button className="icon-button" onClick={() => setConfirmLogout(true)} aria-label="Linked browser settings">•••</button></header>
      <div className="sidebar-heading"><h1>Chats</h1><span className={`connection ${view.online ? 'online' : ''}`}>{view.online ? 'Connected' : 'Connecting'}</span></div>
      <label className="search"><span aria-hidden="true">⌕</span><input aria-label="Search chats" placeholder="Search conversations" value={filter} onChange={e => setFilter(e.target.value)} /></label>
      <nav aria-label="Conversations">{view.conversations?.filter(c => (c.title || '').toLowerCase().includes(filter.toLowerCase())).map(c => <button key={c.id} className={`chat-row ${view.selected === c.id ? 'selected' : ''}`} aria-current={view.selected === c.id ? 'page' : undefined} onClick={() => { setDraft(''); send('select', { id: c.id, visible: document.hasFocus() }); }}><span className="avatar">{(c.title || 'V').slice(0, 1).toUpperCase()}</span><span className="chat-row-copy"><strong>{c.title || 'Conversation'}</strong><small>{c.type === 'group' ? 'Continue on your phone' : 'End-to-end encrypted'}</small></span>{!!c.unread_count && <span className="unread">{c.unread_count}</span>}</button>)}{!view.conversations?.length && <p className="empty-list">Start a conversation on your phone. It will appear here.</p>}</nav>
      <div className="sidebar-footer">Linked to your phone<span>1:1 messaging preview</span></div>
    </aside>
    <section className="conversation" aria-label={chosen?.title || 'Select a conversation'}>
      {chosen ? <><header className="chat-header"><button className="back icon-button" aria-label="Back to chats" onClick={() => send('select', { id: undefined })}>‹</button><span className="avatar small">{chosen.title?.slice(0, 1)}</span><div><h2>{chosen.title}</h2><span className="muted">End-to-end encrypted</span></div></header>{status}
        <div className="message-list" role="log" aria-label="Messages" aria-live="polite"><button className="history" onClick={() => send('history')}>Load Earlier Messages</button><p className="history-note">This browser receives new messages after linking. Earlier messages may only be available on your phone.</p>{[...(view.messages || [])].sort((a, b) => a.created_at.localeCompare(b.created_at)).map(m => <article key={m.id} className={`bubble ${m.sender_id === view.userId ? 'sent' : 'received'}`}><p>{m.unavailable ? 'Open this message on your phone.' : m.content_type && m.content_type !== 'text' ? 'Attachment — open on your phone.' : m.text}</p><div className="message-meta"><time dateTime={m.created_at}>{new Date(m.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</time><span>{m.status}</span></div></article>)}<div ref={messagesEnd} /></div>
        <form className="composer" onSubmit={e => { e.preventDefault(); if (draft.trim() && !sending) { setSending(true); send('send', { text: draft }); } }}><textarea aria-label="Message" placeholder={available ? 'Write a message…' : 'Open this group on your phone'} disabled={!available} value={draft} onChange={e => setDraft(e.target.value)} onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); } }} rows={1} /><button className="primary send" disabled={!available || !draft.trim() || sending} aria-label="Send message">↑</button></form></> : <div className="empty-chat"><img src="/mark.svg" alt="" width="80" height="80" /><h1>A little more connected.</h1><p>Choose a conversation to start messaging.</p><small>End-to-end encrypted, from your phone to here.</small>{status}</div>}
    </section>
    {confirmLogout && <div className="modal-backdrop"><section className="dialog" role="alertdialog" aria-modal="true" aria-labelledby="logout-title"><h2 id="logout-title">Sign out this browser?</h2><p>Its access will be revoked and its local messages cleared. Your phone stays signed in.</p><button className="primary" autoFocus onClick={() => { setConfirmLogout(false); send('logout'); }}>Sign Out</button><button onClick={() => setConfirmLogout(false)}>Cancel</button></section></div>}
  </main>;
}
createRoot(document.getElementById('root')!).render(<App />);
