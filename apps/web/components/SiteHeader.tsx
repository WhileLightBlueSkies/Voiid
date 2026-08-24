'use client';

import Link from 'next/link';
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
 * The mobile menu is likewise a checkbox and a label.
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

export function SiteHeader() {
  const pathname = usePathname() ?? '/';

  const isCurrent = (href: string) =>
    href === '/' ? pathname === '/' : pathname.startsWith(href);

  const inFeatures = SURFACES.some((s) => isCurrent(s.href));

  return (
    <header className={styles.header}>
      <div className={styles.bar}>
        <Link href="/" className={styles.brand} aria-label="Voiid — home">
          <Logomark size={23} className={styles.mark} />
          <Wordmark size={22} />
        </Link>

        {/*
          The toggle input sits before the nav so the CSS sibling selector can open
          it. It is visually hidden, not display:none — a hidden input is not
          focusable, which would strand keyboard users on a phone.
        */}
        <input
          type="checkbox"
          id="nav-toggle"
          className={styles.toggleInput}
          aria-controls="site-nav"
        />
        <label htmlFor="nav-toggle" className={styles.toggle}>
          <span className={styles.bars} aria-hidden="true">
            <span />
            <span />
            <span />
          </span>
          <span className="srOnly">Menu</span>
        </label>

        <nav id="site-nav" className={styles.nav} aria-label="Main">
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
