import Link from 'next/link';
import type { ReactNode } from 'react';
import { Glyph } from './Glyph';
import styles from './Button.module.css';

/**
 * Every action on this site is a LINK. There is no form, no auth, nothing to submit
 * — it is a brochure — so there is deliberately no <button> variant. If a page ever
 * needs one, that is a signal to re-read the brief before adding it.
 */

export type ButtonProps = {
  href: string;
  children: ReactNode;
  /**
   * 'primary'   — brand aubergine/lilac. The one obvious action in a group.
   * 'secondary' — outlined, sits on the ground.
   * 'ghost'     — text with an arrow; for "read more" inside prose.
   * 'accent'    — AMBER. At most one per page, and only if the page has no other
   *               amber element. Check before you reach for it.
   */
  variant?: ButtonVariant;
  size?: 'md' | 'lg';
  /** Renders a trailing arrow. Default true for 'ghost', false otherwise. */
  arrow?: boolean;
  /** Leading glyph, e.g. <Glyph name="lock" size={18} />. */
  icon?: ReactNode;
  /** Opens in a new tab and adds the rel/aria affordances. */
  external?: boolean;
  className?: string;
};

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'accent';

export function Button({
  href,
  children,
  variant = 'primary',
  size = 'md',
  arrow,
  icon,
  external = false,
  className,
}: ButtonProps) {
  const showArrow = arrow ?? variant === 'ghost';
  // A stable, unhashed class travels alongside the module class so a surrounding
  // component can restyle buttons on a non-standard ground (see CTA's filled
  // block) without matching against hashed build output.
  const cls = [styles.btn, styles[variant], styles[size], `btn-${variant}`, className]
    .filter(Boolean)
    .join(' ');

  const inner = (
    <>
      {icon ? <span className={styles.icon}>{icon}</span> : null}
      <span>{children}</span>
      {showArrow ? (
        <Glyph name="arrow-right" size={size === 'lg' ? 19 : 17} className={styles.arrow} />
      ) : null}
    </>
  );

  if (external) {
    return (
      <a className={cls} href={href} target="_blank" rel="noopener noreferrer">
        {inner}
        <span className="srOnly"> (opens in a new tab)</span>
      </a>
    );
  }

  return (
    <Link className={cls} href={href}>
      {inner}
    </Link>
  );
}

/** Lays out a row of buttons that wraps rather than overflowing on a phone. */
export function ButtonRow({
  children,
  align = 'start',
  className,
}: {
  children: ReactNode;
  align?: 'start' | 'center';
  className?: string;
}) {
  return (
    <div
      className={[styles.row, align === 'center' ? styles.rowCenter : '', className]
        .filter(Boolean)
        .join(' ')}
    >
      {children}
    </div>
  );
}
