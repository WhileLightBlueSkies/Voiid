'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { NAV } from '../lib/nav';
import { Wordmark } from './Wordmark';
import styles from './SiteHeader.module.css';

/**
 * The site header.
 *
 * A client component for exactly one reason: `usePathname`, so the current page gets
 * `aria-current`. It still prerenders statically.
 *
 * The mobile menu is a checkbox and a label — no state, no hydration dependency, and
 * it works before (and without) JavaScript. The checkbox is the disclosure control
 * and carries the aria-expanded/aria-controls wiring itself.
 */

export function SiteHeader() {
  const pathname = usePathname() ?? '/';

  const isCurrent = (href: string) =>
    href === '/' ? pathname === '/' : pathname.startsWith(href);

  return (
    <header className={styles.header}>
      <div className={styles.bar}>
        <Link href="/" className={styles.brand} aria-label="Voiid — home">
          <Wordmark size={21} />
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
          <ul className={styles.list}>
            {NAV.map((item) => (
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
        </nav>
      </div>
    </header>
  );
}
