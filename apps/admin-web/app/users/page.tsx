'use client';

import { Suspense, useCallback, useEffect, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { api, getToken } from '@/lib/api';

/*
 * USERS, DEVICES AND SESSIONS (plan item 3.30).
 *
 * The screen a support or compliance question actually gets answered on: which devices are
 * on this account, what security events has it seen, what did they consent to and when.
 *
 * WHAT IT DOES NOT SHOW, and cannot: message content, call audio, locations. The server
 * holds none of it in readable form. This is worth stating on the screen itself so nobody
 * goes looking for a tab that could never exist.
 *
 * Phone numbers arrive MASKED from the API — the raw column never leaves that function.
 * This page therefore cannot un-mask one, which is the point.
 */

interface UserRow {
  id: string;
  username: string | null;
  full_name: string | null;
  phone_masked: string | null;
  created_at: string;
  deleted_at: string | null;
}

interface Device {
  id: string; device_name: string | null; platform: string | null;
  push_provider: string | null; created_at: string;
  last_seen_at: string | null; revoked_at: string | null;
}
interface SecurityEvent {
  id: string; event_type: string; ip_address: string | null; created_at: string;
}
interface ConsentRecord {
  notice_version: string; language: string; given_at: string;
  given_via: string | null; withdrawn_at: string | null;
}
interface UserDetail {
  user: UserRow & { email: string | null; consent_given_at: string | null };
  devices: Device[];
  events: SecurityEvent[];
  consents: ConsentRecord[];
  requests: Array<{ id: string; kind: string; status: string; opened_at: string; due_at: string }>;
}

function UsersInner() {
  const router = useRouter();
  const params = useSearchParams();
  const preselect = params.get('id');

  const [q, setQ] = useState('');
  const [rows, setRows] = useState<UserRow[]>([]);
  const [detail, setDetail] = useState<UserDetail | null>(null);
  const [loading, setLoading] = useState(false);

  const search = useCallback(async (term: string) => {
    setLoading(true);
    try {
      const qs = new URLSearchParams();
      if (term.trim()) qs.set('q', term.trim());
      const res = await api<{ users: UserRow[] }>(`/users?${qs}`);
      setRows(res.users);
    } finally { setLoading(false); }
  }, []);

  const open = useCallback(async (id: string) => {
    setLoading(true);
    try { setDetail(await api<UserDetail>(`/users/${id}`)); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => {
    if (!getToken()) { router.replace('/login'); return; }
    if (preselect) open(preselect); else search('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [preselect]);

  async function revokeDevices(id: string) {
    if (!window.confirm(
      'Revoke every device on this account?\n\n' +
      'They will be signed out everywhere and will need to log in again.'
    )) return;
    await api(`/users/${id}/revoke-devices`, { method: 'POST' });
    await open(id);
  }

  if (detail) {
    const u = detail.user;
    return (
      <main style={{ maxWidth: 940, margin: '0 auto', padding: 32 }}>
        <header style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 6 }}>
          <button className="ghost" onClick={() => { setDetail(null); search(q); }}>← Back</button>
          <h1 style={{ margin: 0, fontSize: 21 }}>
            {u.username ? `@${u.username}` : (u.full_name || u.id.slice(0, 8))}
          </h1>
          {u.deleted_at && <span style={{ color: 'var(--danger)', fontSize: 13 }}>deleted</span>}
          <div style={{ marginLeft: 'auto' }}>
            <button className="danger" onClick={() => revokeDevices(u.id)}>Revoke all devices</button>
          </div>
        </header>
        <p style={{ color: 'var(--text-dim)', fontSize: 13, margin: '0 0 22px', maxWidth: '68ch' }}>
          {u.phone_masked ?? 'no number'} · joined {new Date(u.created_at).toLocaleDateString()}.
          Messages, calls and locations are end-to-end encrypted — there is no content here to
          show, and there is no view that could produce it.
        </p>

        <Section title={`Devices (${detail.devices.length})`}>
          {detail.devices.map((d) => (
            <Row key={d.id}
              main={d.device_name || d.platform || 'Unknown device'}
              meta={[
                d.platform, d.push_provider,
                d.last_seen_at ? `last seen ${new Date(d.last_seen_at).toLocaleString()}` : 'never seen',
                d.revoked_at ? 'REVOKED' : null,
              ].filter(Boolean).join(' · ')}
              danger={!!d.revoked_at}
            />
          ))}
        </Section>

        <Section title="Consent">
          {detail.consents.length === 0 && <Empty>No consent recorded.</Empty>}
          {detail.consents.map((c, i) => (
            <Row key={i}
              main={`${c.notice_version} (${c.language})`}
              meta={[
                `given ${new Date(c.given_at).toLocaleString()}`,
                c.given_via,
                c.withdrawn_at ? `WITHDRAWN ${new Date(c.withdrawn_at).toLocaleString()}` : null,
              ].filter(Boolean).join(' · ')}
              danger={!!c.withdrawn_at}
            />
          ))}
        </Section>

        <Section title="Data-principal requests">
          {detail.requests.length === 0 && <Empty>None.</Empty>}
          {detail.requests.map((r) => (
            <Row key={r.id} main={r.kind}
              meta={`${r.status} · opened ${new Date(r.opened_at).toLocaleDateString()} · due ${new Date(r.due_at).toLocaleDateString()}`} />
          ))}
        </Section>

        <Section title="Recent security events">
          {detail.events.length === 0 && <Empty>None in the retained window.</Empty>}
          {detail.events.map((e) => (
            <Row key={e.id} main={e.event_type}
              meta={`${e.ip_address ?? 'no ip'} · ${new Date(e.created_at).toLocaleString()}`} />
          ))}
        </Section>
      </main>
    );
  }

  return (
    <main style={{ maxWidth: 940, margin: '0 auto', padding: 32 }}>
      <header style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 18 }}>
        <Link href="/"><button className="ghost">← Back</button></Link>
        <h1 style={{ margin: 0, fontSize: 22 }}>Users</h1>
      </header>

      <form onSubmit={(e) => { e.preventDefault(); search(q); }}
            style={{ display: 'flex', gap: 8, marginBottom: 18 }}>
        <input value={q} onChange={(e) => setQ(e.target.value)}
               placeholder="Username, name, or full phone number"
               style={{ flex: 1 }} />
        <button type="submit" disabled={loading}>Search</button>
      </form>

      <div style={{ display: 'grid', gap: 8 }}>
        {rows.map((u) => (
          <button key={u.id} className="card"
                  onClick={() => open(u.id)}
                  style={{ textAlign: 'left', padding: 12, cursor: 'pointer' }}>
            <div style={{ fontWeight: 600 }}>
              {u.username ? `@${u.username}` : (u.full_name || u.id.slice(0, 8))}
              {u.deleted_at && <span style={{ color: 'var(--danger)', fontWeight: 400 }}> · deleted</span>}
            </div>
            <div style={{ color: 'var(--text-dim)', fontSize: 12.5 }}>
              {u.phone_masked ?? 'no number'} · joined {new Date(u.created_at).toLocaleDateString()}
            </div>
          </button>
        ))}
        {rows.length === 0 && !loading && (
          <p style={{ color: 'var(--text-dim)' }}>No matches.</p>
        )}
      </div>
    </main>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section style={{ marginBottom: 26 }}>
      <h2 style={{ fontSize: 12, letterSpacing: '.07em', textTransform: 'uppercase',
                   color: 'var(--text-dim)', margin: '0 0 8px' }}>{title}</h2>
      <div style={{ display: 'grid', gap: 6 }}>{children}</div>
    </section>
  );
}
function Row({ main, meta, danger }: { main: string; meta: string; danger?: boolean }) {
  return (
    <div className="card" style={{ padding: 10 }}>
      <div style={{ fontWeight: 600, color: danger ? 'var(--danger)' : undefined }}>{main}</div>
      <div style={{ color: 'var(--text-dim)', fontSize: 12.5 }}>{meta}</div>
    </div>
  );
}
function Empty({ children }: { children: React.ReactNode }) {
  return <p style={{ color: 'var(--text-dim)', fontSize: 13, margin: 0 }}>{children}</p>;
}

export default function UsersPage() {
  // useSearchParams needs a Suspense boundary under the App Router's static export.
  return <Suspense fallback={null}><UsersInner /></Suspense>;
}
