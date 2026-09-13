'use client';

import { useState } from 'react';
import Shell, { type Me } from '../../components/Shell';
import { Button } from '../../components/ui/button';
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
        <p style={{ color: 'var(--text-dim)', fontSize: 13, marginBottom: 16 }}>
          You have the moderator role — sending announcements requires the admin role.
        </p>
      )}
      {error && <p style={{ color: 'var(--danger)', fontSize: 13, marginBottom: 16 }}>{error}</p>}

      {sent && (
        <div style={{ border: '1px solid var(--border)', background: 'var(--accent-quiet)', borderRadius: 12,
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
              <SegButton key={a} active={audience === a} disabled={readOnly || busy}
                         onClick={() => touch(setAudience)(a)}>
                {a === 'all' ? 'Everyone' : a === 'platform' ? 'One platform' : 'One user'}
              </SegButton>
            ))}
          </div>
        </Labelled>

        {audience === 'platform' && (
          <Labelled label="Platform" hint="">
            <div style={{ display: 'flex', gap: 8 }}>
              {(['ios', 'android'] as const).map((p) => (
                <SegButton key={p} active={platform === p} disabled={readOnly || busy}
                           onClick={() => touch(setPlatform)(p)}>
                  {p === 'ios' ? 'iOS' : 'Android'}
                </SegButton>
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
          <div style={{ border: '1px solid var(--border)', borderRadius: 12, padding: 16,
                        background: 'var(--surface)' }}>
            <p style={{ fontSize: 12, color: 'var(--text-dim)', margin: '0 0 10px' }}>
              This will reach <strong style={{ color: 'var(--text)' }}>{preview.recipients}</strong>
              {' '}device{preview.recipients === 1 ? '' : 's'} — {preview.ios} iOS,
              {' '}{preview.android} Android. There is no undo.
            </p>
            {/* The payload as it will appear, so the last thing reviewed is the thing sent. */}
            <div style={{ border: '1px solid var(--border)', borderRadius: 10, padding: 12,
                          background: 'var(--surface-2)', marginBottom: 12 }}>
              <div style={{ fontSize: 14, fontWeight: 600 }}>{preview.title}</div>
              <div style={{ fontSize: 13, color: 'var(--text-dim)', marginTop: 2 }}>{preview.body}</div>
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <Button disabled={busy} onClick={doSend}>
                {busy ? 'Sending…' : `Send to ${preview.recipients}`}
              </Button>
              <Button variant="ghost" disabled={busy} onClick={() => setPreview(null)}>
                Cancel
              </Button>
            </div>
          </div>
        )}
      </div>
    </>
  );
}

/**
 * One option in a small exclusive set.
 *
 * Written against the design tokens rather than hex literals — these two selectors carried
 * the old accent inline, so they went on showing the pre-redesign teal after the palette
 * moved. aria-pressed rather than colour alone: the selected state must survive a reader
 * who cannot see the fill.
 */
function SegButton({ active, disabled, onClick, children }: {
  active: boolean; disabled?: boolean; onClick: () => void; children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      disabled={disabled}
      onClick={onClick}
      className={[
        'rounded-full border px-3.5 py-1.5 text-tiny font-medium transition-colors',
        'disabled:cursor-default disabled:opacity-50',
        active
          ? 'border-transparent bg-primary text-white'
          : 'border-border bg-transparent text-[var(--text-dim)] hover:bg-[var(--surface-2)] hover:text-[var(--text)]',
      ].join(' ')}
    >
      {children}
    </button>
  );
}

function Labelled({ label, hint, children }: {
  label: string; hint: string; children: React.ReactNode;
}) {
  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 5 }}>
        <label style={{ fontSize: 12, color: 'var(--text-dim)' }}>{label}</label>
        {hint && <span style={{ fontSize: 11, color: 'var(--text-mute)' }}>{hint}</span>}
      </div>
      {children}
    </div>
  );
}

const input: React.CSSProperties = {
  width: '100%', padding: '9px 11px', borderRadius: 8,
  border: '1px solid var(--border)', background: 'var(--surface-2)', color: 'var(--text)', fontSize: 13,
};

const primary: React.CSSProperties = {
  padding: '10px 18px', borderRadius: 10, fontSize: 14, fontWeight: 600,
  border: 'none', background: 'var(--accent)', color: '#fff', cursor: 'pointer',
};
