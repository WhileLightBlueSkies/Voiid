import styles from './Wordmark.module.css';

/**
 * The "voiid" wordmark.
 *
 * The app sets it in Urbanist Bold; we do not load a webfont here (no CDN budget,
 * offline builds must work), so this is the system rounded face at the heaviest
 * weight with the tracking pulled in — close in character, and it never blocks a
 * paint waiting on a font.
 *
 * The two i-dots are replaced by a drawn pair: one filled, one hollow. That is the
 * whole product in a mark — a sealed thing and its counterpart key.
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
        vo
        <span className={styles.stem}>
          <span className={styles.dotFilled} />ı
        </span>
        <span className={styles.stem}>
          <span className={styles.dotHollow} />ı
        </span>
        d
      </span>
      <span className="srOnly">Voiid</span>
    </span>
  );
}
