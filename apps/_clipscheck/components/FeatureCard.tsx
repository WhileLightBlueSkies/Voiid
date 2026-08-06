import Link from 'next/link';
import type { ElementType, ReactNode } from 'react';
import { Glyph, type GlyphName } from './Glyph';
import { hueVars, type DomainHue } from '../lib/hues';
import styles from './FeatureCard.module.css';

export type FeatureCardProps = {
  title: ReactNode;
  /** The body copy. Keep it to two or three lines; the page carries the argument. */
  children: ReactNode;
  /**
   * Makes the whole card a link. The click target is the card, but only the title is
   * the actual anchor — so the accessible name is the title, not the whole paragraph.
   */
  href?: string;
  hue?: DomainHue;
  glyph?: GlyphName;
  /** Usually an <E2EEBadge>. Sits under the body, above the CTA. */
  meta?: ReactNode;
  /** Link text, e.g. "Explore messaging". Only rendered with `href`. */
  cta?: string;
  /** Spans two grid columns at desktop width, for the one card that leads. */
  span?: 1 | 2;
  /** h3 inside a section with an h2. Drop to h4 if nested one level deeper. */
  headingLevel?: 2 | 3 | 4;
  className?: string;
};

export function FeatureCard({
  title,
  children,
  href,
  hue,
  glyph,
  meta,
  cta,
  span = 1,
  headingLevel = 3,
  className,
}: FeatureCardProps) {
  const Heading = `h${headingLevel}` as ElementType;

  return (
    <article
      style={hueVars(hue)}
      className={[
        styles.card,
        href ? styles.linked : '',
        span === 2 ? styles.span2 : '',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      {/* The hue rail. Purely decorative — the card's identity is also in its words. */}
      <span className={styles.rail} aria-hidden="true" />

      {glyph ? (
        <span className={styles.glyph} aria-hidden="true">
          <Glyph name={glyph} size={22} />
        </span>
      ) : null}

      <Heading className={styles.title}>
        {href ? (
          <Link href={href} className={styles.titleLink}>
            {title}
            {/* Stretches the anchor over the card without swallowing the body text
             * into the link's accessible name. */}
            <span className={styles.stretch} aria-hidden="true" />
          </Link>
        ) : (
          title
        )}
      </Heading>

      <div className={styles.body}>{children}</div>

      {meta ? <div className={styles.meta}>{meta}</div> : null}

      {href && cta ? (
        <span className={styles.cta} aria-hidden="true">
          {cta}
          <Glyph name="arrow-right" size={16} className={styles.ctaArrow} />
        </span>
      ) : null}
    </article>
  );
}

/**
 * A short, quiet fact — a spec line, a limit, a number. Use in a row of three or four
 * under a section header; it is not a card and must not compete with one.
 */
export function StatLine({
  label,
  value,
  className,
}: {
  label: string;
  value: ReactNode;
  className?: string;
}) {
  return (
    <div className={[styles.stat, className].filter(Boolean).join(' ')}>
      <span className={styles.statValue}>{value}</span>
      <span className={styles.statLabel}>{label}</span>
    </div>
  );
}
