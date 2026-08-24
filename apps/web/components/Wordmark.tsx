import styles from './Wordmark.module.css';

/**
 * The "voiid" wordmark.
 *
 * Mirrors BrandWordmark.swift exactly: capital V, the rest lowercase; each `i` is
 * set with the DOTLESS form (U+0131) and its tittle drawn as a circle above —
 * both dots in the ACCENT colour, which is what makes them the mark. No webfont
 * loads here (offline builds must work), so the system rounded face stands in
 * for Urbanist/SF at the heaviest weight with tracking pulled in.
 */

export type WordmarkProps = {
  /** Cap height in px. Default 22 (header size). */
  size?: number;
  /** Renders the mark in a single flat colour instead of the brand hue. */
  muted?: boolean;
  className?: string;
};

export function Wordmark({ size = 22, muted = false, className }: WordmarkProps) {
  return (
    <span
      className={[styles.mark, muted ? styles.muted : '', className].filter(Boolean).join(' ')}
      style={{ fontSize: size }}
    >
      {/* The visible glyphs are decorative; the accessible name is the plain word. */}
      <span aria-hidden="true" className={styles.glyphs}>
        Vo
        <span className={styles.stem}>
          <span className={styles.dot} />ı
        </span>
        <span className={styles.stem}>
          <span className={styles.dot} />ı
        </span>
        d
      </span>
      <span className="srOnly">Voiid</span>
    </span>
  );
}
