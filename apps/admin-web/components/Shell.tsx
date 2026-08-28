'use client';

//
// The console frame: sidebar, header, and the session guard every page sits behind.
//
// The guard lives HERE rather than in each page because a page that forgot it would render
// its shell, fire its fetches, and only then bounce — briefly showing an operator chrome
// they may not be entitled to. One gate, applied once, cannot be forgotten by a new page.
//

import { useEffect, useState } from 'react';
import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { api, clearToken, getToken, ApiError } from '../lib/api';

export type Me = { email: string; name: string; role: 'admin' | 'moderator' };

const NAV: { href: string; label: string; adminOnly?: boolean }[] = [
  { href: '/', label: 'Overview' },
  { href: '/communities', label: 'Communities' },
  { href: '/clips', label: 'Clips' },
  { href: '/reports', label: 'Reports' },
  { href: '/users', label: 'Users & devices', adminOnly: true },
  { href: '/dpdp', label: 'Data requests', adminOnly: true },
  { href: '/audit', label: 'Audit log' },
];

export default function Shell({ children }: { children: (me: Me) => ReactNodeLike }) {
  const [me, setMe] = useState<Me | null>(null);
  const [error, setError] = useState<string | null>(null);
  const router = useRouter();
  const pathname = usePathname();

  useEffect(() => {
    if (!getToken()) { router.replace('/login'); return; }
    api<Me>('/me')
      .then(setMe)
      // A 401 already redirects inside api(); anything else is a real failure and must not
      // be shown as a login prompt, which would send an operator round a loop that cannot fix it.
      .catch((e: unknown) => {
        if (!(e instanceof ApiError && e.status === 401)) {
          setError(e instanceof Error ? e.message : 'could not start the session');
        }
      });
  }, [router]);

  if (error) {
    return (
      <div style={{ padding: 40, maxWidth: 520 }}>
        <div className="notice error">{error}</div>
      </div>
    );
  }
  // Deliberately blank rather than a spinner: the session check is one request against a
  // warm API, and a flashed loader is more visible than the wait it describes.
  if (!me) return null;

  const items = NAV.filter((n) => !n.adminOnly || me.role === 'admin');

  return (
    <div style={{ display: 'flex', minHeight: '100vh' }}>
      <aside
        style={{
          width: 'var(--sidebar)',
          flex: '0 0 var(--sidebar)',
          borderRight: '1px solid var(--border)',
          background: 'var(--surface)',
          padding: '20px 12px',
          display: 'flex',
          flexDirection: 'column',
          gap: 4,
          position: 'sticky',
          top: 0,
          height: '100vh',
        }}
      >
        <div style={{ padding: '0 10px 16px', display: 'flex', alignItems: 'center', gap: 9 }}>
          <span style={{ width: 10, height: 10, borderRadius: 3, background: 'var(--accent)' }} />
          <strong style={{ letterSpacing: '-0.01em' }}>Voiid</strong>
          <span className="mute" style={{ fontSize: 13 }}>Admin</span>
        </div>

        {items.map((n) => {
          const active = n.href === '/' ? pathname === '/' : pathname.startsWith(n.href);
          return (
            <Link
              key={n.href}
              href={n.href}
              style={{
                padding: '9px 10px',
                borderRadius: 9,
                fontSize: 14,
                fontWeight: active ? 600 : 500,
                color: active ? 'var(--text)' : 'var(--text-dim)',
                background: active ? 'var(--accent-quiet)' : 'transparent',
                textDecoration: 'none',
              }}
            >
              {n.label}
            </Link>
          );
        })}

        <div style={{ marginTop: 'auto', padding: '12px 10px 0', borderTop: '1px solid var(--border)' }}>
          <div style={{ fontSize: 13, fontWeight: 600 }}>{me.name || me.email}</div>
          <div className="mute" style={{ fontSize: 12, marginBottom: 10 }}>
            {me.role === 'admin' ? 'Admin' : 'Moderator'}
          </div>
          <button
            className="ghost sm"
            onClick={async () => {
              // Best-effort server logout, then clear locally REGARDLESS. A network failure
              // must not leave a live token sitting in the tab.
              await api('/logout', { method: 'POST', json: {} }).catch(() => {});
              clearToken();
              router.replace('/login');
            }}
          >
            Sign out
          </button>
        </div>
      </aside>

      <main style={{ flex: 1, padding: '28px 32px', minWidth: 0 }}>{children(me)}</main>
    </div>
  );
}

type ReactNodeLike = React.ReactElement | null;
