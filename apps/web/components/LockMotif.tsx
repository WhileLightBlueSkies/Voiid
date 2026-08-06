import styles from './LockMotif.module.css';

/**
 * The E2EE motif: two devices, two keys, one sealed packet crossing between them,
 * and a server in the middle that only ever sees the sealed thing.
 *
 * It is a diagram, not decoration — it is the one claim the whole product rests on,
 * so it shows the actual mechanism rather than a padlock floating in a gradient. All
 * of it is authored SVG plus CSS: no library, no external asset.
 *
 * The packet is animated with CSS `offset-path` rather than SMIL `animateMotion`,
 * for one reason: SMIL ignores prefers-reduced-motion. A CSS animation can be
 * switched off, and it is — the packet parks mid-flight and the diagram still reads.
 * The path data therefore appears twice, once as SVG geometry and once in the CSS.
 * If you change one, change the other.
 */

export type LockMotifProps = {
  /** Rendered width in px; height follows the 5:4 viewBox. Default 420. */
  size?: number;
  /** Accessible description. A default is provided; override if the page reframes it. */
  label?: string;
  /**
   * Prefix for the SVG's internal ids. Only needs setting if a page renders more than
   * one motif, since duplicate ids would cross-wire the gradients.
   */
  idPrefix?: string;
  className?: string;
};

const DEFAULT_LABEL =
  'Diagram: two phones, each holding its own key, exchange a sealed packet. The ' +
  'packet passes through the Voiid server, which relays it without holding a key ' +
  'and never sees the contents.';

export function LockMotif({
  size = 420,
  label = DEFAULT_LABEL,
  idPrefix = 'motif',
  className,
}: LockMotifProps) {
  const rail = `${idPrefix}-rail`;
  const bloom = `${idPrefix}-bloom`;

  return (
    <svg
      className={[styles.motif, className].filter(Boolean).join(' ')}
      width={size}
      height={size * 0.8}
      viewBox="0 0 500 400"
      role="img"
      aria-label={label}
    >
      <defs>
        <linearGradient id={rail} x1="0" y1="0" x2="1" y2="0">
          <stop offset="0%" className={styles.railStart} />
          <stop offset="50%" className={styles.railMid} />
          <stop offset="100%" className={styles.railEnd} />
        </linearGradient>
        <radialGradient id={bloom} cx="50%" cy="50%" r="50%">
          <stop offset="0%" className={styles.bloomIn} />
          <stop offset="100%" className={styles.bloomOut} />
        </radialGradient>
      </defs>

      <ellipse cx="250" cy="200" rx="230" ry="150" fill={`url(#${bloom})`} />

      {/* ---- the wire between the two devices, over the server ------------- */}
      <path
        d="M118 232 C 190 232, 190 168, 250 168 C 310 168, 310 232, 382 232"
        fill="none"
        stroke={`url(#${rail})`}
        strokeWidth="2.5"
      />
      <path
        d="M118 232 C 190 232, 190 168, 250 168 C 310 168, 310 232, 382 232"
        fill="none"
        strokeWidth="2"
        strokeDasharray="5 11"
        strokeLinecap="round"
        className={styles.wire}
      />

      {/* ---- left device --------------------------------------------------- */}
      <g className={styles.device}>
        <rect x="52" y="176" width="66" height="112" rx="14" />
        <rect x="61" y="188" width="48" height="80" rx="7" className={styles.deviceScreen} />
        <line x1="76" y1="182" x2="94" y2="182" strokeWidth="3" strokeLinecap="round" />
      </g>
      <g className={styles.key} transform="translate(85 322)">
        <circle cx="-15" cy="0" r="7.5" />
        <path d="M-7.5 0 H 17 M 9 0 v 7 M 17 0 v 5" />
      </g>
      <text x="85" y="356" className={styles.label} textAnchor="middle">
        her key
      </text>

      {/* ---- right device -------------------------------------------------- */}
      <g className={styles.device}>
        <rect x="382" y="176" width="66" height="112" rx="14" />
        <rect x="391" y="188" width="48" height="80" rx="7" className={styles.deviceScreen} />
        <line x1="406" y1="182" x2="424" y2="182" strokeWidth="3" strokeLinecap="round" />
      </g>
      <g className={styles.key} transform="translate(415 322)">
        <circle cx="-15" cy="0" r="7.5" />
        <path d="M-7.5 0 H 17 M 9 0 v 7 M 17 0 v 5" />
      </g>
      <text x="415" y="356" className={styles.label} textAnchor="middle">
        his key
      </text>

      {/* ---- the server: it relays, it cannot read -------------------------- */}
      <text x="250" y="40" className={styles.label} textAnchor="middle">
        our server
      </text>
      <g className={styles.server}>
        <rect x="216" y="52" width="68" height="21" rx="6" />
        <rect x="216" y="79" width="68" height="21" rx="6" />
        <circle cx="229" cy="62.5" r="2.8" className={styles.led} />
        <circle cx="229" cy="89.5" r="2.8" className={styles.ledDim} />
        <line x1="250" y1="100" x2="250" y2="140" strokeDasharray="4 6" />
      </g>

      {/* ---- the padlock sitting on the wire's apex ------------------------- */}
      <g className={styles.lock}>
        <path d="M236 152 v -10 a 14 14 0 0 1 28 0 v 10" className={styles.shackle} fill="none" />
        <rect x="227" y="150" width="46" height="34" rx="10" className={styles.lockBody} />
        <circle cx="250" cy="164" r="3.6" className={styles.lockPin} />
        <line x1="250" y1="167" x2="250" y2="175" className={styles.lockPin} strokeLinecap="round" />
      </g>

      {/* ---- the sealed packet riding the wire ----------------------------- */}
      <g className={styles.packet}>
        <rect x="-12" y="-9.5" width="24" height="19" rx="4.5" />
        <path d="M-12 -5.5 L0 3.5 L12 -5.5" fill="none" />
      </g>

      <text x="250" y="300" className={styles.caption} textAnchor="middle">
        ciphertext in · ciphertext out
      </text>
    </svg>
  );
}
