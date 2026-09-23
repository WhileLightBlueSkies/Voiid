'use client';

//
// The console frame: a floating left sidebar, the top bar, and the session guard every
// page sits behind.
//
// The guard lives HERE rather than in each page because a page that forgot it would render
// its shell, fire its fetches, and only then bounce — briefly showing an operator chrome
// they may not be entitled to. One gate, applied once, cannot be forgotten by a new page.
//

import { useEffect, useRef, useState } from 'react';
import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { api, clearToken, getToken, ApiError } from '../lib/api';
import {
  LayoutDashboard, BarChart3, Flag, Film, Users2, CalendarDays, Gamepad2,
  BellRing, UserCog, FileText, Landmark, ScrollText, LogOut,
  Bell, Menu, Search, ShieldCheck, X, PanelLeftClose, PanelLeftOpen, BadgeCheck,
} from 'lucide-react';
import { BrandMark } from './Brand';
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
      { href: '/kyc', label: 'Host verification', icon: BadgeCheck },
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

const COLLAPSE_KEY = 'voiid.admin.sidebar-collapsed';

export default function Shell({ children }: { children: (me: Me) => ReactNodeLike }) {
  const [me, setMe] = useState<Me | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [navOpen, setNavOpen] = useState(false);
  // Desktop only: the sidebar folds to an icon rail. Remembered per browser — a convenience,
  // so a blocked or empty storage simply means "expanded".
  const [collapsed, setCollapsed] = useState(() => {
    try { return typeof window !== 'undefined' && localStorage.getItem(COLLAPSE_KEY) === '1'; } catch { return false; }
  });
  const toggleCollapsed = () => setCollapsed((c) => {
    try { localStorage.setItem(COLLAPSE_KEY, c ? '0' : '1'); } catch { /* not persisted; still toggles */ }
    return !c;
  });

  useEffect(() => {
    // "[" folds and unfolds, as in most consoles — never while typing into a field.
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable)) return;
      if (e.key === '[' && !e.metaKey && !e.ctrlKey && !e.altKey) { e.preventDefault(); toggleCollapsed(); }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);
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

  const signOut = async () => {
    // Best-effort server logout, then clear locally REGARDLESS. A network failure must not
    // leave a live token sitting in the tab.
    await api('/logout', { method: 'POST', json: {} }).catch(() => {});
    clearToken();
    router.replace('/login');
  };

  return (
    <div className="flex min-h-screen gap-5 p-3 sm:p-4">
      {/* Scrim for the drawer below lg. The sidebar is a permanent column on a desktop and a
          sheet on anything narrower, where a 256px column would take half the screen. */}
      {navOpen && (
        <div
          aria-hidden
          onClick={() => setNavOpen(false)}
          className="fixed inset-0 z-30 bg-black/20 backdrop-blur-[2px] lg:hidden"
        />
      )}

      <aside
        className={[
          'z-40 flex w-[var(--sidebar)] shrink-0 flex-col rounded-[28px] bg-card p-4',
          'shadow-[var(--shadow-1)] ring-1 ring-black/[0.04]',
          'fixed inset-y-3 left-3 transition-[transform,width,padding] duration-200 ease-out sm:inset-y-4 sm:left-4',
          collapsed ? 'lg:w-[84px] lg:px-3' : '',
          'lg:sticky lg:top-4 lg:h-[calc(100vh-32px)] lg:translate-x-0',
          navOpen ? 'translate-x-0 shadow-[var(--shadow-2)]' : '-translate-x-[calc(100%+24px)]',
        ].join(' ')}
      >
        <div className={`mb-5 flex items-center gap-3 px-1.5 pt-1 ${collapsed ? 'lg:flex-col lg:gap-3 lg:px-0' : ''}`}>
          <BrandMark size={30} />
          <div className={`whitespace-nowrap leading-tight ${collapsed ? 'lg:hidden' : ''}`}>
            <div className="text-[17px] font-bold tracking-[-0.02em]">Voiid</div>
            <div className="text-micro font-medium text-[var(--text-mute)]">Operations console</div>
          </div>
          <button
            aria-label="Close menu"
            onClick={() => setNavOpen(false)}
            className="ml-auto grid h-8 w-8 place-items-center rounded-full bg-transparent p-0 text-[var(--text-dim)] hover:bg-[var(--surface-2)] lg:hidden"
          >
            <X size={16} />
          </button>
          <button
            aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            title={`${collapsed ? 'Expand' : 'Collapse'} sidebar  [`}
            aria-expanded={!collapsed}
            onClick={toggleCollapsed}
            className={`hidden h-9 w-9 place-items-center rounded-full bg-transparent p-0 text-[var(--text-dim)] hover:bg-[var(--surface-2)] hover:text-[var(--text)] lg:grid ${collapsed ? '' : 'ml-auto'}`}
          >
            {collapsed ? <PanelLeftOpen size={17} /> : <PanelLeftClose size={17} />}
          </button>
        </div>

        <nav className="-mx-1 flex-1 overflow-y-auto px-1" aria-label="Sections">
          {sections.map((g, gi) => (
            <div key={g.section || gi} className="flex flex-col gap-0.5">
              {g.section && (
                <>
                  <div className={`whitespace-nowrap px-3.5 pb-1.5 pt-5 text-micro font-semibold text-[var(--text-mute)] ${collapsed ? 'lg:hidden' : ''}`}>
                    {g.section}
                  </div>
                  {/* In the rail a group heading becomes a hairline: the grouping survives
                      even when there is no room for its name. */}
                  {collapsed && <div aria-hidden className="mx-3 my-3 hidden h-px bg-[var(--border)] lg:block" />}
                </>
              )}
              {g.items.map((n) => {
                const active = isActive(pathname, n.href);
                return (
                  <Link
                    key={n.href}
                    href={n.href}
                    aria-current={active ? 'page' : undefined}
                    onClick={() => setNavOpen(false)}
                    title={collapsed ? n.label : undefined}
                    aria-label={collapsed ? n.label : undefined}
                    className={[
                      'group relative flex h-11 items-center gap-3 rounded-full px-3.5 text-sm',
                      collapsed ? 'lg:mx-auto lg:w-11 lg:justify-center lg:px-0' : '',
                      'no-underline transition-colors duration-150 hover:no-underline',
                      active
                        ? 'bg-[var(--accent)] font-semibold text-white'
                        : 'font-medium text-[var(--text-dim)] hover:bg-[var(--surface-2)] hover:text-[var(--text)]',
                    ].join(' ')}
                  >
                    <n.icon
                      size={17}
                      strokeWidth={active ? 2.2 : 1.9}
                      className={active ? 'text-white' : 'text-[var(--text-mute)] group-hover:text-[var(--text)]'}
                    />
                    <span className={`flex-1 whitespace-nowrap ${collapsed ? 'lg:hidden' : ''}`}>{n.label}</span>
                    {/* A standing mark on the surfaces where a mistake is a legal problem.
                        Not a warning — the work is legitimate — but the eye should never
                        land here thinking it is somewhere ordinary. */}
                    {n.tone === 'legal' && (
                      <span aria-hidden className={`h-1.5 w-1.5 rounded-full ${collapsed ? 'lg:absolute lg:right-1.5 lg:top-2' : ''}`}
                            style={{ background: 'var(--attention)' }} />
                    )}
                  </Link>
                );
              })}
            </div>
          ))}
        </nav>

        {/* The privacy promise, stated where every operator sees it every day: this console
            administers containers, never content. */}
        <div className={`mt-4 rounded-[20px] bg-[var(--tide-soft)] p-4 [@media(max-height:940px)]:hidden ${collapsed ? 'lg:hidden' : ''}`}>
          <div className="flex items-center gap-2 text-tiny font-semibold text-[var(--text)]">
            <ShieldCheck size={15} className="text-[var(--accent-ink)]" />
            End-to-end encrypted
          </div>
          <p className="m-0 mt-1 text-micro leading-relaxed text-[var(--text-dim)]">
            Messages and calls never reach this console. The server holds no key.
          </p>
        </div>

        <div className={`mt-3 flex items-center gap-2.5 rounded-full bg-[var(--surface-2)] p-1.5 pr-2 ${collapsed ? 'lg:flex-col lg:rounded-[22px] lg:pr-1.5' : ''}`}>
          <Avatar me={me} size={34} />
          <div className={`min-w-0 flex-1 leading-tight ${collapsed ? 'lg:hidden' : ''}`}>
            <div className="truncate text-tiny font-semibold" title={me.name || me.email}>
              {me.name || me.email}
            </div>
            <div className="text-micro text-[var(--text-mute)]">
              {me.role === 'admin' ? 'Admin' : 'Moderator'}
            </div>
          </div>
          <button
            onClick={signOut}
            aria-label="Sign out"
            title="Sign out"
            className="grid h-8 w-8 place-items-center rounded-full bg-card p-0 text-[var(--text-dim)] shadow-[var(--shadow-1)] hover:bg-card hover:text-[var(--danger)]"
          >
            <LogOut size={14} strokeWidth={2} />
          </button>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-14 items-center gap-3 pb-1 sm:h-16">
          <button
            aria-label="Open menu"
            onClick={() => setNavOpen(true)}
            className="grid h-11 w-11 shrink-0 place-items-center rounded-full bg-card p-0 text-[var(--text)] shadow-[var(--shadow-1)] hover:bg-card lg:hidden"
          >
            <Menu size={18} />
          </button>

          <JumpTo sections={sections} onGo={(href) => router.push(href)} />

          <div className="ml-auto flex items-center gap-2">
            <Link
              href="/reports"
              aria-label="Reports queue"
              title="Reports queue"
              className="grid h-11 w-11 place-items-center rounded-full bg-card text-[var(--text)] shadow-[var(--shadow-1)] transition-colors hover:bg-[var(--surface-2)]"
            >
              <Bell size={17} strokeWidth={2} />
            </Link>
            <Link
              href="/audit"
              aria-label="Audit log"
              title="Audit log"
              className="hidden h-11 w-11 place-items-center rounded-full bg-card text-[var(--text)] shadow-[var(--shadow-1)] transition-colors hover:bg-[var(--surface-2)] sm:grid"
            >
              <ScrollText size={17} strokeWidth={2} />
            </Link>
          </div>
        </header>

        <main className="min-w-0 flex-1 pb-8 pt-4 sm:px-1">{children(me)}</main>
      </div>
    </div>
  );
}

function isActive(pathname: string, href: string) {
  return href === '/' ? pathname === '/' : pathname.startsWith(href);
}

/** An initial, not a stock avatar glyph: "who am I signed in as" is answered faster by a letter. */
function Avatar({ me, size }: { me: Me; size: number }) {
  return (
    <span
      className="grid shrink-0 place-items-center rounded-full font-bold text-[var(--text)]"
      style={{ width: size, height: size, background: 'var(--tide-light)', fontSize: size * 0.4 }}
    >
      {(me.name || me.email).charAt(0).toUpperCase()}
    </span>
  );
}

/**
 * "Jump to…" — a page finder, not a data search.
 *
 * Every page already has its own filter for its own records; what the header can do honestly
 * is get an operator to the right page by name. "/" focuses it from anywhere, as it does on
 * most consoles, and Enter opens the highlighted match.
 */
function JumpTo({ sections, onGo }: {
  sections: { section: string; items: NavItem[] }[];
  onGo: (href: string) => void;
}) {
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const [hi, setHi] = useState(0);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      const typing = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
      if (e.key === '/' && !typing) { e.preventDefault(); input.current?.focus(); }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);

  const all = sections.flatMap((g) => g.items.map((i) => ({ ...i, section: g.section || 'General' })));
  const term = q.trim().toLowerCase();
  const matches = term
    ? all.filter((i) => i.label.toLowerCase().includes(term) || i.section.toLowerCase().includes(term))
    : all;

  const go = (href: string) => { onGo(href); setQ(''); setOpen(false); input.current?.blur(); };

  return (
    <div className="relative w-full max-w-[420px]">
      <div className="flex h-11 items-center gap-2 rounded-full bg-card pl-1.5 pr-4 shadow-[var(--shadow-1)] focus-within:ring-4 focus-within:ring-[var(--accent-quiet)]">
        <span className="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-[var(--accent)] text-white">
          <Search size={14} strokeWidth={2.4} />
        </span>
        <input
          ref={input}
          value={q}
          onChange={(e) => { setQ(e.target.value); setHi(0); setOpen(true); }}
          onFocus={() => setOpen(true)}
          onBlur={() => setTimeout(() => setOpen(false), 120)}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') { e.preventDefault(); setHi((h) => Math.min(h + 1, matches.length - 1)); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); setHi((h) => Math.max(h - 1, 0)); }
            else if (e.key === 'Enter' && matches[hi]) { e.preventDefault(); go(matches[hi].href); }
            else if (e.key === 'Escape') { setOpen(false); input.current?.blur(); }
          }}
          placeholder="Jump to a page…"
          aria-label="Jump to a page"
          className="h-full min-w-0 flex-1 border-0 bg-transparent p-0 text-sm shadow-none focus:shadow-none"
        />
        <kbd className="hidden rounded-md border border-border px-1.5 text-micro text-[var(--text-mute)] sm:block">/</kbd>
      </div>

      {open && (
        <div className="absolute left-0 right-0 top-[calc(100%+8px)] z-20 max-h-[360px] overflow-y-auto rounded-[20px] bg-card p-1.5 shadow-[var(--shadow-2)] ring-1 ring-black/[0.04]">
          {matches.length === 0 ? (
            <div className="px-3 py-4 text-sm text-[var(--text-mute)]">No page matches “{q}”.</div>
          ) : matches.map((m, i) => (
            <button
              key={m.href}
              onMouseDown={(e) => { e.preventDefault(); go(m.href); }}
              onMouseEnter={() => setHi(i)}
              className={[
                'flex w-full items-center gap-3 rounded-full bg-transparent px-3 py-2 text-left text-sm font-medium text-[var(--text)]',
                i === hi ? 'bg-[var(--surface-2)] hover:bg-[var(--surface-2)]' : 'hover:bg-transparent',
              ].join(' ')}
            >
              <m.icon size={15} className="text-[var(--text-mute)]" />
              <span className="flex-1">{m.label}</span>
              <span className="text-micro text-[var(--text-mute)]">{m.section}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

type ReactNodeLike = React.ReactElement | null;
