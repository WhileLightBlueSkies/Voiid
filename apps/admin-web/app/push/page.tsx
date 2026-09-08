'use client';

import { useState } from 'react';
import Shell, { type Me } from '../../components/Shell';
import { PageHeader } from '../../components/ui';
import { api } from '../../lib/api';

/**
 * Send an announcement to every device.
 *
 * ── PREVIEW, THEN SEND ───────────────────────────────────────────────────────────
 * This reaches every phone at once and there is no undo — no edit, no delete, no "ignore
 * that". So the flow is deliberately two steps: Preview resolves the audience and shows
 * the exact copy and the exact number, and only then does Send appear. A single button
 * would put a typo one click from every user.
 *
 * The count comes from the SAME query the send uses, so the number confirmed is the number
 * reached rather than an estimate computed a different way.
 *
 * ── WHAT BELONGS HERE ────────────────────────────────────────────────────────────
 * Operator copy: maintenance windows, an outage, a release note. Never anything derived
 * from user content — this is the one push path in the system permitted to carry visible
 * text, which is exactly why it must not be fed from anything private.
 */

type Preview = { recipients: number; ios: number; android: number; title: string; body: string };
type SendResult = { attempted: number; apns: number; fcm: number; skipped: number };

type Audience = 'all' | 'platform' | 'user';

export default function Push() {
  return <Shell>{(me) => <Body me={me} />}</Shell>;
}

function Body({ me }: { me: Me }) {
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [audience, setAudience] = useState<Audience>('all');
  const [platform, setPlatform] = useState<'ios' | 'android'>('ios');
  const [userId, setUserId] = useState('');

  const [preview, setPreview] = useState<Preview | null>(null);
  const [sent, setSent] = useState<SendResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const readOnly = me.role !== 'admin';

  function payload() {
    return {
      title, body,
      audience,
      ...(audience === 'platform' ? { platform } : {}),
      ...(audience === 'user' ? { user_id: userId.trim() } : {}),
    };
  }

  /** Any edit invalidates a preview — otherwise Send could deliver copy nobody confirmed. */
  function touch<T>(set: (v: T) => void) {
    return (v: T) => { set(v); setPreview(null); setSent(null); setError(null); };
  }

  async function doPreview() {
    setBusy(true); setError(null); setSent(null);
    try {
      setPreview(await api<Preview>('/push/preview', { method: 'POST', json: payload() }));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not resolve that audience');
    } finally { setBusy(false); }
  }

  async function doSend() {
    setBusy(true); setError(null);
    try {
      const r = await api<SendResult & { ok: boolean }>('/push/send', {
        method: 'POST', json: { ...payload(), confirm: true },
      });
      setSent(r);
      setPreview(null);
      setTitle(''); setBody('');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'send failed');
    } finally { setBusy(false); }
  }

  return (
    <>
      <PageHeader
        title="Push announcement"
        subtitle="Goes to every device in the audience immediately. There is no undo."
      />

      {readOnly && (
        <p style={{ color: '#a6b0b2', fontSize: 13, marginBottom: 16 }}>
          You have the moderator role — sending announcements requires the admin role.
        </p>
      )}
      {error && <p style={{ color: '#e5484d', fontSize: 13, marginBottom: 16 }}>{error}</p>}

      {sent && (
        <div style={{ border: '1px solid #13828c', background: '#0f1f21', borderRadius: 12,
                      padding: 14, marginBottom: 16, fontSize: 13 }}>
          Sent to {sent.attempted} device{sent.attempted === 1 ? '' : 's'} — {sent.apns} iOS,
          {' '}{sent.fcm} Android
          {sent.skipped > 0 && ` · ${sent.skipped} skipped (no usable token)`}
        </div>
      )}

      <div style={{ display: 'grid', gap: 16, maxWidth: 620 }}>
        <Labelled label="Title" hint={`${title.length}/64`}>
          <input value={title} maxLength={64} disabled={readOnly || busy}
                 onChange={(e) => touch(setTitle)(e.target.value)}
                 placeholder="Scheduled maintenance"
                 style={input} />
        </Labelled>

        <Labelled label="Message" hint={`${body.length}/240`}>
          <textarea value={body} maxLength={240} rows={3} disabled={readOnly || busy}
                    onChange={(e) => touch(setBody)(e.target.value)}
                    placeholder="Voiid will be briefly unavailable tonight at 11pm IST."
                    style={{ ...input, resize: 'vertical' }} />
        </Labelled>

        <Labelled label="Audience" hint="">
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {(['all', 'platform', 'user'] as Audience[]).map((a) => (
              <button key={a} disabled={readOnly || busy}
                      onClick={() => touch(setAudience)(a)}
                      style={{
                        padding: '7px 14px', borderRadius: 999, fontSize: 13,
                        border: '1px solid ' + (audience === a ? '#13828c' : '#263236'),
                        background: audience === a ? '#13828c' : 'transparent',
                        color: audience === a ? '#fff' : '#a6b0b2',
                        cursor: readOnly || busy ? 'default' : 'pointer',
                      }}>
                {a === 'all' ? 'Everyone' : a === 'platform' ? 'One platform' : 'One user'}
              </button>
            ))}
          </div>
        </Labelled>

        {audience === 'platform' && (
          <Labelled label="Platform" hint="">
            <div style={{ display: 'flex', gap: 8 }}>
              {(['ios', 'android'] as const).map((p) => (
                <button key={p} disabled={readOnly || busy}
                        onClick={() => touch(setPlatform)(p)}
                        style={{
                          padding: '7px 14px', borderRadius: 999, fontSize: 13,
                          border: '1px solid ' + (platform === p ? '#13828c' : '#263236'),
                          background: platform === p ? '#13828c' : 'transparent',
                          color: platform === p ? '#fff' : '#a6b0b2',
                          cursor: readOnly || busy ? 'default' : 'pointer',
                        }}>
                  {p === 'ios' ? 'iOS' : 'Android'}
                </button>
              ))}
            </div>
          </Labelled>
        )}

        {audience === 'user' && (
          <Labelled label="User ID" hint="A uuid — use the Users page to find one.">
            <input value={userId} disabled={readOnly || busy}
                   onChange={(e) => touch(setUserId)(e.target.value)}
                   placeholder="00000000-0000-0000-0000-000000000000"
                   style={input} />
          </Labelled>
        )}

        {!preview ? (
          <button
            disabled={readOnly || busy || !title.trim() || !body.trim()}
            onClick={doPreview}
            style={{ ...primary, opacity: readOnly || busy || !title.trim() || !body.trim() ? 0.5 : 1 }}
          >
            {busy ? 'Checking…' : 'Preview'}
          </button>
        ) : (
          <div style={{ border: '1px solid #263236', borderRadius: 12, padding: 16,
                        background: '#111719' }}>
            <p style={{ fontSize: 12, color: '#a6b0b2', margin: '0 0 10px' }}>
              This will reach <strong style={{ color: '#f6f8f8' }}>{preview.recipients}</strong>
              {' '}device{preview.recipients === 1 ? '' : 's'} — {preview.ios} iOS,
              {' '}{preview.android} Android. There is no undo.
            </p>
            {/* The payload as it will appear, so the last thing reviewed is the thing sent. */}
            <div style={{ border: '1px solid #263236', borderRadius: 10, padding: 12,
                          background: '#0b0f10', marginBottom: 12 }}>
              <div style={{ fontSize: 14, fontWeight: 600 }}>{preview.title}</div>
              <div style={{ fontSize: 13, color: '#a6b0b2', marginTop: 2 }}>{preview.body}</div>
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <button disabled={busy} onClick={doSend}
                      style={{ ...primary, opacity: busy ? 0.5 : 1 }}>
                {busy ? 'Sending…' : `Send to ${preview.recipients}`}
              </button>
              <button disabled={busy} onClick={() => setPreview(null)}
                      style={{ ...primary, background: 'transparent', border: '1px solid #263236',
                               color: '#a6b0b2' }}>
                Cancel
              </button>
            </div>
          </div>
        )}
      </div>
    </>
  );
}

function Labelled({ label, hint, children }: {
  label: string; hint: string; children: React.ReactNode;
}) {
  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 5 }}>
        <label style={{ fontSize: 12, color: '#a6b0b2' }}>{label}</label>
        {hint && <span style={{ fontSize: 11, color: '#5d696c' }}>{hint}</span>}
      </div>
      {children}
    </div>
  );
}

const input: React.CSSProperties = {
  width: '100%', padding: '9px 11px', borderRadius: 8,
  border: '1px solid #263236', background: '#0b0f10', color: '#f6f8f8', fontSize: 13,
};

const primary: React.CSSProperties = {
  padding: '10px 18px', borderRadius: 10, fontSize: 14, fontWeight: 600,
  border: 'none', background: '#13828c', color: '#fff', cursor: 'pointer',
};
