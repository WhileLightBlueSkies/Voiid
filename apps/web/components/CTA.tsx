import type { ReactNode } from 'react';
import { hueVars, type DomainHue } from '../lib/hues';
import styles from './CTA.module.css';

/**
 * The closing band. One per page, at the bottom, and the only place a page asks for
 * anything. There is nothing to submit — no form, no field, no tracking — so a CTA
 * here is always a link somewhere else.
 */

export type CTAProps = {
  title: ReactNode;
  lede?: ReactNode;
  /** Usually a <ButtonRow>. */
  actions?: ReactNode;
  /** Small print under the actions. Use it for the honest caveat, not for legalese. */
  note?: ReactNode;
  hue?: DomainHue;
  /**
   * AMBER treatment. This is a page's one warm moment — check that the page has no
   * other amber element (an accent Button, a Games hue, an unread badge in a mockup)
   * before setting it, or the accent stops meaning anything.
   */
  accent?: boolean;
  className?: string;
};

export function CTA({
  title,
  lede,
  actions,
  note,
  hue,
  accent = false,
  className,
}: CTAProps) {
  return (
    <section
      style={hueVars(hue)}
      className={[styles.cta, accent ? styles.accent : '', className]
        .filter(Boolean)
        .join(' ')}
    >
      <div className={styles.panel}>
        {/* A single sweep of the hue across the top edge, and a soft bloom behind. */}
        <span className={styles.edge} aria-hidden="true" />
        <span className={styles.bloom} aria-hidden="true" />

        <div className={styles.body}>
          <h2 className={styles.title}>{title}</h2>
          {lede ? <p className={styles.lede}>{lede}</p> : null}
          {actions ? <div className={styles.actions}>{actions}</div> : null}
          {note ? <p className={styles.note}>{note}</p> : null}
        </div>
      </div>
    </section>
  );
}
