import type { ElementType, ReactNode } from 'react';
import { hueVars, type DomainHue } from '../lib/hues';
import styles from './Section.module.css';

/**
 * The page's vertical rhythm and horizontal measure, in one place.
 *
 * Pages should not write their own <section> + container + padding — the whole point
 * is that eight pages written by eight different hands share one rhythm. Set the hue
 * here and everything inside (eyebrows, ghost buttons, card rails) picks it up.
 */

export type SectionProps = {
  children: ReactNode;
  /** Anchor target. Also what the heading's id is derived from for aria-labelledby. */
  id?: string;
  eyebrow?: string;
  /** Section heading. Omit for a bare layout band. */
  title?: ReactNode;
  /** Standfirst under the heading. */
  lede?: ReactNode;
  hue?: DomainHue;
  /** 'narrow' = prose measure, 'default' = 1120, 'wide' = 1320, 'full' = no max. */
  width?: 'narrow' | 'default' | 'wide' | 'full';
  align?: 'start' | 'center';
  /**
   * 'plain'  — sits on the page ground (default)
   * 'raised' — a surface panel with a hairline, for a section that must feel separate
   * 'inset'  — a recessed well, for supporting or caveat content
   */
  tone?: 'plain' | 'raised' | 'inset';
  /** h2 by default. Use 3 only when the section genuinely nests under another. */
  headingLevel?: 2 | 3;
  /** Trims the top padding when a section abuts the one before it. */
  flush?: 'top' | 'bottom' | 'both';
  as?: ElementType;
  className?: string;
  /** Class applied to the inner measure element, for grid overrides. */
  bodyClassName?: string;
};

export function Section({
  children,
  id,
  eyebrow,
  title,
  lede,
  hue,
  width = 'default',
  align = 'start',
  tone = 'plain',
  headingLevel = 2,
  flush,
  as: Tag = 'section',
  className,
  bodyClassName,
}: SectionProps) {
  const Heading = (headingLevel === 3 ? 'h3' : 'h2') as ElementType;
  const headingId = id && title ? `${id}-heading` : undefined;
  const hasHeader = Boolean(eyebrow || title || lede);

  return (
    <Tag
      id={id}
      style={hueVars(hue)}
      aria-labelledby={headingId}
      className={[
        styles.section,
        styles[tone],
        align === 'center' ? styles.center : '',
        flush ? styles[`flush-${flush}`] : '',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      <div className={[styles.measure, styles[width], bodyClassName].filter(Boolean).join(' ')}>
        {hasHeader ? (
          <header className={styles.header}>
            {eyebrow ? <span className="eyebrow">{eyebrow}</span> : null}
            {title ? (
              <Heading id={headingId} className={styles.title}>
                {title}
              </Heading>
            ) : null}
            {lede ? <p className={styles.lede}>{lede}</p> : null}
          </header>
        ) : null}
        {children}
      </div>
    </Tag>
  );
}

/**
 * The standard responsive grid. Cards go straight in; it collapses to one column on
 * a phone without any page needing its own media query.
 */
export function Grid({
  children,
  columns = 3,
  gap = 'md',
  className,
}: {
  children: ReactNode;
  columns?: 2 | 3 | 4;
  gap?: 'sm' | 'md' | 'lg';
  className?: string;
}) {
  return (
    <div
      className={[styles.grid, styles[`cols${columns}`], styles[`gap-${gap}`], className]
        .filter(Boolean)
        .join(' ')}
    >
      {children}
    </div>
  );
}

/**
 * A two-column band: copy on one side, a visual (usually <PhoneMockup>) on the other.
 * Stacks on a phone, with the visual second so the reading order stays sensible.
 */
export function Split({
  children,
  aside,
  reverse = false,
  align = 'center',
  className,
}: {
  children: ReactNode;
  aside: ReactNode;
  /** Puts the visual on the left at desktop width. Reading order is unchanged. */
  reverse?: boolean;
  align?: 'center' | 'start';
  className?: string;
}) {
  return (
    <div
      className={[
        styles.split,
        reverse ? styles.splitReverse : '',
        align === 'start' ? styles.splitStart : '',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      <div className={styles.splitCopy}>{children}</div>
      <div className={styles.splitAside}>{aside}</div>
    </div>
  );
}
