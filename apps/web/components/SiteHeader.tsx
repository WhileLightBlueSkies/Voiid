'use client';

import Link from 'next/link';
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { usePathname } from 'next/navigation';
import { SURFACES, HEADER_NAV } from '../lib/nav';
import { Wordmark } from './Wordmark';
import { Logomark } from './Logomark';
import { Glyph, type GlyphName } from './Glyph';
import styles from './SiteHeader.module.css';

/**
 * The site header.
 *
 * A client component for exactly one reason: `usePathname`, so the current page
 * gets `aria-current`. It still prerenders statically.
 *
 * WHY THE LINKS ARE GROUPED
 * -------------------------
 * This used to render all eight NAV entries as peers. Eight equal links is a
 * sitemap rather than a navigation bar: nothing can be ranked, so nothing reads
 * as primary and the whole header looks like documentation. The five product
 * surfaces now live behind "Features" and the two argument pages stay top-level,
 * which is the same shape WhatsApp and Arattai use.
 *
 * The Features menu is CSS-only — a focusable summary/details pair — so it works
 * without JavaScript and needs no state, no outside-click handler and no portal.
 *
 * THE MOBILE MENU IS NOT (W03). It used to be a checkbox and a label, collapsed with
 * `grid-template-rows: 0fr` and clipped by overflow — which hides it from SIGHT and from
 * nothing else. Its links stayed in the focus order, so a keyboard user tabbing across the
 * header fell into a menu they could not see and could not tell they were in, and a screen
 * reader was never told the control was a disclosure at all, because a checkbox is not a
 * button and has no expanded state to announce.
 *
 * A real button with aria-expanded needs state, so this part is no longer CSS-only. The
 * collapsed menu is `inert`, which removes it from focus AND from the accessibility tree in
 * one attribute — but ONLY at the mobile breakpoint, because at desktop the same element is
 * the visible navigation and marking it inert from stale mobile state would disable the
 * header outright.
 */

/**
 * Which glyph stands for each surface.
 *
 * Explicit rather than derived from the hue: a hue is a COLOUR and a glyph is a
 * PICTURE, and the fact that several currently share a name is a coincidence that
 * would break silently the first time a surface is re-hued.
 */
const SURFACE_GLYPH: Record<string, GlyphName> = {
  '/messaging': 'chat',
  '/calls': 'call',
  '/map': 'map',
  '/clips': 'clips',
  '/games': 'games',
};

/** Matches the `max-width: 1020px` breakpoint in SiteHeader.module.css. */
const MOBILE_QUERY = '(max-width: 1020px)';

export function SiteHeader() {
  const pathname = usePathname() ?? '/';
  const [open, setOpen] = useState(false);
  const toggleRef = useRef<HTMLButtonElement>(null);
  const navRef = useRef<HTMLElement>(null);
  const brandRef = useRef<HTMLAnchorElement>(null);

  // Whether the collapsing menu is the one on screen. Read from the SAME query the stylesheet
  // uses, because the two disagreeing is how the desktop navigation would end up inert.
  //
  // Start collapsed for server rendering; measure before paint during hydration.
  const [isMobile, setIsMobile] = useState(true);
  useLayoutEffect(() => {
    const mq = window.matchMedia(MOBILE_QUERY);
    let lastFocused: Element | null = document.activeElement;
    const rememberFocus = (event: FocusEvent) => { lastFocused = event.target as Element; };
    document.addEventListener('focusin', rememberFocus);
    const sync = () => {
      const focused = document.activeElement === document.body ? lastFocused : document.activeElement;
      if (mq.matches && navRef.current?.contains(focused)) toggleRef.current?.focus();
      if (!mq.matches && focused === toggleRef.current) brandRef.current?.focus();
      setIsMobile(mq.matches);
      setOpen(false);
    };
    sync();
    mq.addEventListener('change', sync);
    return () => { mq.removeEventListener('change', sync); document.removeEventListener('focusin', rememberFocus); };
  }, []);

  const close = useCallback((restoreFocus: boolean) => {
    if (restoreFocus && navRef.current?.contains(document.activeElement)) toggleRef.current?.focus();
    setOpen(false);
  }, []);

  // Escape closes and hands focus back to the control that opened it.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') close(true); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, close]);

  // A navigation closes the menu. Without this the panel stays open over the new page, and
  // focus is left inside a menu describing somewhere the user has already left.
  useLayoutEffect(() => { close(true); }, [pathname, close]);

  // Growing past the breakpoint with the menu open must not leave the desktop header in a
  // half-open state, or `inert` applied from a mobile flag nobody can see any more.
  useEffect(() => { if (!isMobile) setOpen(false); }, [isMobile]);

  const collapsed = isMobile && !open;

  const isCurrent = (href: string) =>
    href === '/' ? pathname === '/' : pathname.startsWith(href);

  const inFeatures = SURFACES.some((s) => isCurrent(s.href));

  return (
    <header className={styles.header} data-nav-open={open ? 'true' : undefined}>
      <div className={styles.bar}>
        <Link href="/" ref={brandRef} className={styles.brand} aria-label="Voiid — home">
          <Logomark size={23} idPrefix="header" className={styles.mark} />
          <Wordmark size={22} />
        </Link>

        {/*
          A BUTTON, not a checkbox. A checkbox has a checked state, which assistive technology
          announces as "checked" rather than "expanded", and it cannot carry aria-expanded at
          all. This is the control the disclosure pattern actually asks for.
        */}
        <button
          type="button"
          ref={toggleRef}
          className={styles.toggle}
          aria-expanded={open}
          aria-controls="site-nav"
          onClick={() => setOpen((o) => !o)}
        >
          <span className={styles.bars} aria-hidden="true">
            <span />
            <span />
            <span />
          </span>
          <span className="srOnly">{open ? 'Close menu' : 'Menu'}</span>
        </button>

        {/*
          `inert` when collapsed: one attribute that takes the links out of the focus order AND
          out of the accessibility tree, which `overflow: hidden` never did. Applied only at
          the mobile breakpoint — at desktop this element IS the navigation.
        */}
        <nav ref={navRef} aria-hidden={collapsed || undefined} id="site-nav" className={styles.nav} aria-label="Main" inert={collapsed}>
          {/* The collapsing wrapper: `grid-template-rows` on .nav animates the
              height, and this element is what gets clipped while it does. */}
          <div className={styles.navInner}>
          <ul className={styles.list}>
            <li className={styles.hasMenu}>
              <details className={styles.menu}>
                <summary
                  className={styles.link}
                  data-current={inFeatures ? 'true' : undefined}
                >
                  Features
                  <Glyph name="arrow-right" size={13} className={styles.chevron} />
                </summary>
                <div className={styles.menuPanel}>
                  <ul className={styles.menuList}>
                    {SURFACES.map((s) => (
                      <li key={s.href}>
                        <Link
                          href={s.href}
                          className={styles.menuItem}
                          aria-current={isCurrent(s.href) ? 'page' : undefined}
                        >
                          <span className={styles.menuIcon} style={{ color: `var(--hue-${s.hue})` }}>
                            <Glyph name={SURFACE_GLYPH[s.href] ?? 'chat'} size={16} />
                          </span>
                          <span className={styles.menuText}>
                            <span className={styles.menuLabel}>{s.label}</span>
                            <span className={styles.menuBlurb}>{s.blurb}</span>
                          </span>
                        </Link>
                      </li>
                    ))}
                  </ul>
                </div>
              </details>
            </li>

            {HEADER_NAV.filter((i) => i.href !== '/messaging').map((item) => (
              <li key={item.href}>
                <Link
                  href={item.href}
                  className={styles.link}
                  aria-current={isCurrent(item.href) ? 'page' : undefined}
                >
                  {item.label}
                </Link>
              </li>
            ))}
          </ul>

          {/* The one call to action in the chrome. Every reference site has one;
              without it the header reads as a table of contents. */}
          <Link href="/messaging" className={styles.cta}>
            Get Voiid
          </Link>
          </div>
        </nav>
      </div>
    </header>
  );
}
