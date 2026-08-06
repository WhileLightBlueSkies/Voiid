'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { api, clearToken, getToken } from '@/lib/api';

interface Stats {
  users: number; clips: number; clips_removed: number;
  comments: number; clips_24h: number; users_24h: number;
}

export default function Dashboard() {
  const router = useRouter();
  const [stats, setStats] = useState<Stats | null>(null);
  const [me, setMe] = useState<{ name: string | null; email: string } | null>(null);

  useEffect(() => {
    if (!getToken()) { router.replace('/login'); return; }
    api<{ name: string | null; email: string }>('/me').then(setMe).catch(() => {});
    api<Stats>('/stats').then(setStats).catch(() => {});
  }, [router]);

  return (
    <main style={{ maxWidth: 1000, margin: '0 auto', padding: 32 }}>
      <header style={{ display: 'flex', alignItems: 'center', marginBottom: 28 }}>
        <div>
          <h1 style={{ margin: 0, fontSize: 24 }}>Voiid Admin</h1>
          {me && (
            <p style={{ margin: '2px 0 0', color: 'var(--text-dim)', fontSize: 13 }}>
              {me.name ?? me.email}
            </p>
          )}
        </div>
        <div style={{ marginLeft: 'auto' }}>
          <button className="ghost" onClick={async () => {
            await api('/logout', { method: 'POST' }).catch(() => {});
            clearToken();
            router.replace('/login');
          }}>Sign out</button>
        </div>
      </header>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 12 }}>
        <Stat label="Users" value={stats?.users} sub={stats && `+${stats.users_24h} today`} />
        <Stat label="Clips" value={stats?.clips} sub={stats && `+${stats.clips_24h} today`} />
        <Stat label="Removed" value={stats?.clips_removed} />
        <Stat label="Comments" value={stats?.comments} />
      </div>

      <nav style={{ marginTop: 28, display: 'flex', gap: 12 }}>
        <Link href="/clips"><button>Moderate clips</button></Link>
        {/* The DPDP queue is ordered by DEADLINE, not recency — an overdue request is the
            one failure this panel exists to prevent, so it gets its own entry rather than
            living behind the users list. */}
        <Link href="/reports"><button className="ghost">Reports</button></Link>
        <Link href="/dpdp"><button className="ghost">Data requests</button></Link>
        <Link href="/users"><button className="ghost">Users &amp; devices</button></Link>
      </nav>

      {/* Said plainly, on the one screen where someone might assume otherwise. An admin
          panel that can read public content invites the question of what else it can read;
          the honest answer belongs here rather than in a doc nobody opens. */}
      <p style={{ marginTop: 32, color: 'var(--text-dim)', fontSize: 12, lineHeight: 1.7 }}>
        Clips are public content and are not end-to-end encrypted, which is what makes
        moderation possible. Messages, calls, locations and moments are end-to-end
        encrypted — there is no endpoint here, or anywhere, that can read them.
      </p>
    </main>
  );
}

function Stat({ label, value, sub }: { label: string; value?: number; sub?: string | null | false }) {
  return (
    <div className="card" style={{ padding: 16 }}>
      <div style={{ color: 'var(--text-dim)', fontSize: 12 }}>{label}</div>
      <div style={{ fontSize: 26, fontWeight: 700, marginTop: 4 }}>
        {value ?? '—'}
      </div>
      {sub && <div style={{ color: 'var(--text-dim)', fontSize: 11, marginTop: 2 }}>{sub}</div>}
    </div>
  );
}
