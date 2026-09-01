'use client';

//
// One account, for answering a support case or a rights request.
//
// `GET /admin/users/:id` shipped complete and had no caller, so devices, security events,
// consent history and DPDP requests — everything needed to answer "what happened to this
// account" — were unreachable from the panel.
//
// The phone number stays MASKED here as it is everywhere else. Reveal is its own audited act
// on the list, deliberately: opening a profile should not silently log a disclosure.
//

import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import Link from 'next/link';
import Shell, { type Me } from '../../../components/Shell';
import { PageHeader, Async, Pill, when, name } from '../../../components/ui';
import { api } from '../../../lib/api';

type User = {
  id: string; username: string | null; full_name: string | null;
  email: string | null; bio: string | null; status_text: string | null;
  phone_masked: string | null; created_at: string; deleted_at: string | null;
  consent_given_at: string | null;
};
type Device = {
  id: string; device_name: string | null; platform: string | null;
  push_provider: string | null; os_version: string | null; app_version: string | null;
  created_at: string; revoked_at: string | null;
};
type SecurityEvent = {
  id: string; event_type: string; ip_address: string | null;
  metadata: unknown; created_at: string;
};
type Consent = {
  notice_version: string | null; language: string | null; purposes: unknown;
  given_at: string | null; given_via: string | null;
  withdrawn_at: string | null; withdrawn_via: string | null;
};
type DpdpRequest = {
  id: string; kind: string; status: string; opened_at: string;
  due_at: string | null; closed_at: string | null; resolution: string | null;
};
type Payload = {
  user: User; devices: Device[]; security_events: SecurityEvent[];
  consent_records: Consent[]; dpdp_requests: DpdpRequest[];
};

export default function UserDetail() {
  return <Shell>{(me) => <Body me={me} />}</Shell>;
}

function Body({ me }: { me: Me }) {
  const { id } = useParams<{ id: string }>();
  const [d, setD] = useState<Payload | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [writeError, setWriteError] = useState<string | null>(null);
  const [phone, setPhone] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setD(await api<Payload>(`/users/${id}`));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load this account');
    }
  }, [id]);

  useEffect(() => { void load(); }, [load]);

  async function reveal() {
    const reason = window.prompt(
      'Why do you need this number? (recorded in the audit log against your name)')?.trim();
    if (!reason) return;
    setBusy(true);
    setWriteError(null);
    try {
      const r = await api<{ phone: string | null }>(`/users/${id}/reveal-phone`,
                                                    { method: 'POST', json: { reason } });
      setPhone(r.phone ?? 'none on file');
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'could not reveal that number');
    } finally { setBusy(false); }
  }

  async function revokeDevices() {
    const u = d?.user;
    const label = u ? name(u.full_name, u.username, u.id.slice(0, 8)) : 'this user';
    if (!window.confirm(`Sign out every device for ${label}? They'll have to log in again.`)) return;
    setBusy(true);
    setWriteError(null);
    try {
      await api(`/users/${id}/revoke-devices`, { method: 'POST', json: {} });
      await load();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally { setBusy(false); }
  }

  const live = d?.devices.filter((x) => !x.revoked_at) ?? [];

  return (
    <Async loading={!d} error={error} empty={false} emptyText="">
      {d && (
        <>
          <div style={{ marginBottom: 14 }}>
            <Link href="/users" style={{ fontSize: 14 }}>← Users</Link>
          </div>

          <PageHeader
            title={name(d.user.full_name, d.user.username)}
            subtitle={d.user.username ? `@${d.user.username}` : d.user.id}
            right={
              me.role === 'admin' ? (
                <button className="ghost" disabled={busy || live.length === 0}
                        onClick={() => void revokeDevices()}>
                  Sign out devices
                </button>
              ) : undefined
            }
          />

          {writeError && <div className="notice error" style={{ marginBottom: 16 }}>{writeError}</div>}

          {d.user.deleted_at && (
            <div className="notice error" style={{ marginBottom: 16 }}>
              Account deleted {when(d.user.deleted_at)}.
            </div>
          )}

          <div className="card" style={{ marginBottom: 22 }}>
            <h2 style={{ marginBottom: 12 }}>Account</h2>
            <Field label="Phone">
              {phone ? (
                <span className="mono">{phone}</span>
              ) : (
                <span className="row" style={{ gap: 8 }}>
                  <span className="mono muted">{d.user.phone_masked ?? '—'}</span>
                  {me.role === 'admin' && d.user.phone_masked && (
                    <button className="ghost sm" disabled={busy}
                            onClick={() => void reveal()}>Reveal</button>
                  )}
                </span>
              )}
            </Field>
            <Field label="Email">{d.user.email ?? '—'}</Field>
            <Field label="Joined">{when(d.user.created_at)}</Field>
            <Field label="Consent given">
              {d.user.consent_given_at ? when(d.user.consent_given_at) : '—'}
            </Field>
            {d.user.bio && <Field label="Bio">{d.user.bio}</Field>}
          </div>

          <Section title={`Devices · ${live.length} active`}>
            {d.devices.length === 0 ? (
              <div className="empty" style={{ padding: '18px 0' }}>No devices.</div>
            ) : (
              <div className="scroller">
                <table>
                  <thead>
                    <tr><th>Device</th><th>Platform</th><th>App</th><th>Added</th><th>State</th></tr>
                  </thead>
                  <tbody>
                    {d.devices.map((x) => (
                      <tr key={x.id}>
                        <td>{x.device_name ?? 'Unnamed'}</td>
                        <td className="muted">{x.platform ?? '—'} {x.os_version ?? ''}</td>
                        <td className="muted">{x.app_version ?? '—'}</td>
                        <td className="muted" style={{ fontSize: 13 }}>{when(x.created_at)}</td>
                        <td>
                          {x.revoked_at
                            ? <Pill>Revoked</Pill>
                            : <Pill tone="ok">Active</Pill>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Section>

          <Section title="Data requests">
            {d.dpdp_requests.length === 0 ? (
              <div className="empty" style={{ padding: '18px 0' }}>None filed.</div>
            ) : (
              d.dpdp_requests.map((r) => (
                <div key={r.id} className="row" style={{ gap: 10, padding: '6px 0' }}>
                  <Pill tone={r.kind === 'erasure' ? 'danger' : 'accent'}>{r.kind}</Pill>
                  <span style={{ fontSize: 13 }}>{r.status}</span>
                  <span className="mute" style={{ fontSize: 12 }}>opened {when(r.opened_at)}</span>
                  <span style={{ flex: 1 }} />
                  {r.closed_at
                    ? <span className="mute" style={{ fontSize: 12 }}>closed {when(r.closed_at)}</span>
                    : <Pill tone="warning">Open</Pill>}
                </div>
              ))
            )}
          </Section>

          <Section title="Consent history">
            {d.consent_records.length === 0 ? (
              <div className="empty" style={{ padding: '18px 0' }}>No records.</div>
            ) : (
              d.consent_records.map((c, i) => (
                <div key={i} className="row" style={{ gap: 10, padding: '6px 0' }}>
                  <span style={{ fontSize: 13 }}>v{c.notice_version ?? '?'}</span>
                  <span className="mute" style={{ fontSize: 12 }}>
                    {c.given_at ? `given ${when(c.given_at)}` : ''}
                    {c.given_via ? ` · ${c.given_via}` : ''}
                  </span>
                  <span style={{ flex: 1 }} />
                  {/* A withdrawal is the fact that matters in a rights case, so it gets the
                      colour rather than being another grey line. */}
                  {c.withdrawn_at
                    ? <Pill tone="danger">Withdrawn {when(c.withdrawn_at)}</Pill>
                    : <Pill tone="ok">Active</Pill>}
                </div>
              ))
            )}
          </Section>

          <Section title="Security events · last 90 days">
            {d.security_events.length === 0 ? (
              <div className="empty" style={{ padding: '18px 0' }}>Nothing recorded.</div>
            ) : (
              <div className="scroller">
                <table>
                  <thead><tr><th>When</th><th>Event</th><th>IP</th></tr></thead>
                  <tbody>
                    {d.security_events.map((e) => (
                      <tr key={e.id}>
                        <td className="muted" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>
                          {when(e.created_at)}
                        </td>
                        <td><Pill>{e.event_type}</Pill></td>
                        <td className="mono muted" style={{ fontSize: 12 }}>
                          {e.ip_address ?? '—'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Section>
        </>
      )}
    </Async>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <>
      <h2 style={{ marginBottom: 10 }}>{title}</h2>
      <div className="card" style={{ marginBottom: 22 }}>{children}</div>
    </>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div style={{ display: 'flex', gap: 16, padding: '7px 0', fontSize: 14 }}>
      <span className="mute" style={{ width: 130, flex: '0 0 130px' }}>{label}</span>
      <span style={{ minWidth: 0 }}>{children}</span>
    </div>
  );
}
