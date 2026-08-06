import type { ReactNode } from 'react';
import { Glyph, type GlyphName } from './Glyph';
import styles from './Callout.module.css';

/**
 * A set-aside paragraph — most often the sentence that says what we CANNOT do.
 *
 * Those sentences are the reason anyone believes the rest of the page, so they get a
 * frame of their own rather than being buried in body copy. `tone="honest"` is the
 * default and the one to reach for.
 */

export type CalloutProps = {
  children: ReactNode;
  /** Short bold lead-in, e.g. "Clips are public." */
  title?: ReactNode;
  /**
   * 'honest' — the plain caveat (default). Quiet, neutral, not alarming.
   * 'note'   — supporting detail.
   * 'warn'   — reserved for something a reader could get wrong to their cost.
   */
  tone?: 'honest' | 'note' | 'warn';
  glyph?: GlyphName;
  className?: string;
};

const DEFAULT_GLYPH: Record<NonNullable<CalloutProps['tone']>, GlyphName> = {
  honest: 'eye-off',
  note: 'note',
  warn: 'shield',
};

export function Callout({
  children,
  title,
  tone = 'honest',
  glyph,
  className,
}: CalloutProps) {
  return (
    <aside className={[styles.callout, styles[tone], className].filter(Boolean).join(' ')}>
      <span className={styles.icon} aria-hidden="true">
        <Glyph name={glyph ?? DEFAULT_GLYPH[tone]} size={19} />
      </span>
      <div className={styles.body}>
        {title ? <strong className={styles.title}>{title}</strong> : null}
        <div className={styles.text}>{children}</div>
      </div>
    </aside>
  );
}
