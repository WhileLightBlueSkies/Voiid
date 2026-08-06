import { Glyph, type GlyphName } from './Glyph';
import styles from './E2EEBadge.module.css';

/**
 * The honesty chip.
 *
 * This is a privacy product, so an overclaim on this site is a liability rather than
 * a pitch. Three states, and only three, because there are only three answers in the
 * schema:
 *
 *   'e2ee'     — the server stores ciphertext it holds no key for. Messages, calls,
 *                location shares, moments.
 *   'public'   — the server can read it, deliberately. Clips, creator profiles,
 *                follows, likes, comments (database/migrations/022_clips.sql header:
 *                you cannot encrypt a broadcast to an audience that has not signed
 *                up yet, and a server that cannot read a row cannot count it).
 *   'refereed' — the server reads game state because it is the referee
 *                (024_games.sql). The invite still travels the E2EE message pipe.
 *
 * There is no fourth, softer state, and there must never be one. If a surface does
 * not fit these three, the fix is to describe it in a sentence, not to blur it here.
 */

export type PrivacyState = 'e2ee' | 'public' | 'refereed';

export type E2EEBadgeProps = {
  state?: PrivacyState;
  /** 'sm' for inside a card, 'md' next to a heading. Default 'sm'. */
  size?: 'sm' | 'md';
  /** Override the label text. The state's own wording is the safe default. */
  label?: string;
  /** Extra sentence rendered under the chip — use it to say what the server sees. */
  detail?: string;
  className?: string;
};

const COPY: Record<PrivacyState, { label: string; glyph: GlyphName }> = {
  e2ee: { label: 'End-to-end encrypted', glyph: 'lock' },
  public: { label: 'Public — not encrypted', glyph: 'broadcast' },
  refereed: { label: 'Server-refereed', glyph: 'games' },
};

export function E2EEBadge({
  state = 'e2ee',
  size = 'sm',
  label,
  detail,
  className,
}: E2EEBadgeProps) {
  const copy = COPY[state];
  const chip = (
    <span
      className={[styles.badge, styles[state], styles[size], className]
        .filter(Boolean)
        .join(' ')}
    >
      <Glyph name={copy.glyph} size={size === 'md' ? 16 : 14} />
      {label ?? copy.label}
    </span>
  );

  if (!detail) return chip;

  return (
    <span className={styles.stack}>
      {chip}
      <span className={styles.detail}>{detail}</span>
    </span>
  );
}
