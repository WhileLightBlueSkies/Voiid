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
import {
  LayoutDashboard, BarChart3, Flag, Film, Users2, CalendarDays, Gamepad2,
  BellRing, UserCog, FileText, Landmark, ScrollText, LogOut,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';

export type Me = { email: string; name: string; role: 'admin' | 'moderator' };

type NavItem = { href: string; label: string; icon: LucideIcon; adminOnly?: boolean; tone?: 'legal' };

/**
 * GROUPED, not a flat list of eleven.
 *
 * Eleven equal-weight links is a scan problem: nothing tells the operator that "Clips" and
 * "Data requests" are different KINDS of work, so finding the second one means reading all
 * of them. The groups say what each stretch of the sidebar is for, and the ordering runs
 * from the everyday to the consequential — moderation queues first, the legal surfaces last,
 * because that is both how often they are opened and how much damage a misclick does.
 */
const NAV: { section: string; items: NavItem[] }[] = [
  {
    section: '',
    items: [
      { href: '/', label: 'Overview', icon: LayoutDashboard },
      { href: '/analytics', label: 'Analytics', icon: BarChart3, adminOnly: true },
    ],
  },
  {
    section: 'Moderation',
    items: [
      { href: '/reports', label: 'Reports', icon: Flag },
      { href: '/clips', label: 'Clips', icon: Film },
      { href: '/communities', label: 'Communities', icon: Users2 },
    ],
  },
  {
    section: 'Operations',
    items: [
      { href: '/events', label: 'Events & revenue', icon: CalendarDays },
      { href: '/games', label: 'Games', icon: Gamepad2, adminOnly: true },
      { href: '/push', label: 'Push', icon: BellRing, adminOnly: true },
      { href: '/users', label: 'Users & devices', icon: UserCog, adminOnly: true },
    ],
  },
  {
    // The two surfaces where a mistake is a legal problem rather than an operational one.
    // Separated and last so neither is reachable by muscle memory aimed at something else.
    section: 'Legal',
    items: [
      { href: '/dpdp', label: 'Data requests', icon: FileText, adminOnly: true },
      { href: '/govt', label: 'Government requests', icon: Landmark, adminOnly: true, tone: 'legal' },
      { href: '/audit', label: 'Audit log', icon: ScrollText },
    ],
  },
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

  const sections = NAV
    .map((g) => ({ ...g, items: g.items.filter((n) => !n.adminOnly || me.role === 'admin') }))
    .filter((g) => g.items.length > 0);

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
        <div className="mb-4 flex items-center gap-2.5 px-2.5 pb-4"
             style={{ borderBottom: '1px solid var(--border)' }}>
          <span
            className="grid h-7 w-7 place-items-center rounded-md text-[13px] font-bold text-[#04181b]"
            style={{
              background: 'linear-gradient(150deg, var(--accent-ink), var(--accent))',
              boxShadow: '0 2px 10px rgba(25,195,212,0.25)',
            }}
          >
            V
          </span>
          <div className="leading-tight">
            <div className="text-sm font-semibold tracking-[-0.01em]">Voiid</div>
            <div className="text-micro text-[var(--text-mute)]">Operations</div>
          </div>
        </div>

        {sections.map((g, gi) => (
          <div key={g.section || gi} style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            {g.section && (
              <div className="px-2.5 pb-1.5 pt-4 text-micro font-semibold uppercase tracking-[0.07em] text-[var(--text-mute)]">
                {g.section}
              </div>
            )}
            {g.items.map((n) => {
              const active = n.href === '/' ? pathname === '/' : pathname.startsWith(n.href);
              return (
                <Link
                  key={n.href}
                  href={n.href}
                  aria-current={active ? 'page' : undefined}
                  className={[
                    'group relative flex items-center gap-2.5 rounded-md px-2.5 py-2 text-sm',
                    'no-underline transition-colors',
                    active
                      ? 'bg-[var(--accent-quiet)] font-semibold text-[var(--text)]'
                      : 'font-medium text-[var(--text-dim)] hover:bg-[var(--surface-2)] hover:text-[var(--text)]',
                  ].join(' ')}
                >
                  {/* A RAIL, not just a fill. A tinted background alone is easy to lose in
                      peripheral vision on a dark sidebar; a bright edge against the panel
                      border is what the eye actually catches when scanning back. */}
                  {active && (
                    <span
                      aria-hidden
                      className="absolute left-0 top-1/2 h-4 w-[3px] -translate-y-1/2 rounded-r"
                      style={{ background: 'var(--accent-ink)' }}
                    />
                  )}
                  <n.icon
                    size={15}
                    strokeWidth={active ? 2.2 : 1.9}
                    className={active ? 'text-[var(--accent-ink)]' : 'text-[var(--text-mute)] group-hover:text-[var(--text-dim)]'}
                  />
                  <span className="flex-1">{n.label}</span>
                  {/* A standing mark on the surfaces where a mistake is a legal problem.
                      Not a warning — the work is legitimate — but the eye should never
                      land here thinking it is somewhere ordinary. */}
                  {n.tone === 'legal' && (
                    <span aria-hidden className="h-1.5 w-1.5 rounded-full"
                          style={{ background: 'var(--attention)' }} />
                  )}
                </Link>
              );
            })}
          </div>
        ))}

        <div className="mt-auto pt-3" style={{ borderTop: '1px solid var(--border)' }}>
          <div className="mb-2 flex items-center gap-2.5 px-1">
            {/* An initial, not a generic avatar glyph. On a console where two people share a
                machine, the question the footer answers is "who am I signed in as" — and a
                letter answers it faster than a name read at 12px. */}
            <span
              className="grid h-7 w-7 shrink-0 place-items-center rounded-full text-tiny font-semibold"
              style={{ background: 'var(--surface-3)', color: 'var(--accent-ink)' }}
            >
              {(me.name || me.email).charAt(0).toUpperCase()}
            </span>
            <div className="min-w-0 flex-1 leading-tight">
              <div className="truncate text-tiny font-semibold" title={me.name || me.email}>
                {me.name || me.email}
              </div>
              <div className="text-micro text-[var(--text-mute)]">
                {me.role === 'admin' ? 'Admin' : 'Moderator'}
              </div>
            </div>
          </div>
          <button
            className="flex w-full items-center justify-center gap-1.5 rounded-md border border-border bg-transparent px-2.5 py-1.5 text-tiny font-medium text-[var(--text-dim)] transition-colors hover:bg-[var(--surface-2)] hover:text-[var(--text)]"
            onClick={async () => {
              // Best-effort server logout, then clear locally REGARDLESS. A network failure
              // must not leave a live token sitting in the tab.
              await api('/logout', { method: 'POST', json: {} }).catch(() => {});
              clearToken();
              router.replace('/login');
            }}
          >
            <LogOut size={13} strokeWidth={2} />
            Sign out
          </button>
        </div>
      </aside>

      <main style={{ flex: 1, padding: '28px 32px', minWidth: 0 }}>{children(me)}</main>
    </div>
  );
}

type ReactNodeLike = React.ReactElement | null;
