import type { ReactNode } from 'react';
import { hueVars, type DomainHue } from '../lib/hues';
import styles from './Hero.module.css';

/**
 * The top of every page. One per page, and it always carries the page's only <h1>.
 *
 * The background is a gradient mesh plus a hairline grid, both drawn in CSS and both
 * clipped by the hero — no image, and nothing that can widen the page on a phone.
 */

export type HeroProps = {
  /** The page's h1. */
  title: ReactNode;
  eyebrow?: string;
  /** The standfirst. One or two sentences; this is the claim, so keep it true. */
  lede?: ReactNode;
  /** Usually a <ButtonRow>. */
  actions?: ReactNode;
  /**
   * The visual: a <PhoneMockup>, a <LockMotif>, whatever the page draws. Omit for a
   * centred, copy-only hero — which is what the text-heavy pages should use.
   */
  aside?: ReactNode;
  /** Small print under the actions — a caveat, a store note, a link out. */
  note?: ReactNode;
  /** A row of <E2EEBadge> or similar, between the lede and the actions. */
  badges?: ReactNode;
  hue?: DomainHue;
  /** 'split' when there is an aside, otherwise 'center'. Inferred if omitted. */
  layout?: 'split' | 'center';
  /** Puts the aside on the left at desktop width; reading order is unchanged. */
  reverse?: boolean;
  className?: string;
};

export function Hero({
  title,
  eyebrow,
  lede,
  actions,
  aside,
  note,
  badges,
  hue,
  layout,
  reverse = false,
  className,
}: HeroProps) {
  const mode = layout ?? (aside ? 'split' : 'center');

  return (
    <section
      style={hueVars(hue)}
      className={[styles.hero, styles[mode], reverse ? styles.reverse : '', className]
        .filter(Boolean)
        .join(' ')}
    >
      {/* Three blurred colour fields and a faint grid. Decorative; hidden. */}
      <div className={styles.backdrop} aria-hidden="true">
        <span className={styles.mesh1} />
        <span className={styles.mesh2} />
        <span className={styles.mesh3} />
        <span className={styles.grid} />
      </div>

      <div className={styles.inner}>
        <div className={styles.copy}>
          {eyebrow ? <span className={styles.eyebrow}>{eyebrow}</span> : null}
          <h1 className={styles.title}>{title}</h1>
          {lede ? <p className={styles.lede}>{lede}</p> : null}
          {badges ? <div className={styles.badges}>{badges}</div> : null}
          {actions ? <div className={styles.actions}>{actions}</div> : null}
          {note ? <p className={styles.note}>{note}</p> : null}
        </div>

        {aside ? <div className={styles.aside}>{aside}</div> : null}
      </div>
    </section>
  );
}
