import styles from './LockMotif.module.css';

/**
 * The E2EE motif, told as a loop: a message is written on her phone, her key seals it
 * into ciphertext, the sealed packet climbs to our server (which scans it and finds
 * no key), then drops to his phone where his key opens it back into the message.
 *
 * It is a diagram, not decoration — it is the one claim the whole product rests on,
 * so it shows the actual mechanism. All of it is authored SVG plus CSS: no library,
 * no external asset, no client JS. Every moving part runs on one 9s timeline
 * (`--loop` in the stylesheet), so the beats stay in step.
 *
 * The packet rides the wire with CSS `offset-path` rather than SMIL `animateMotion`
 * because SMIL ignores prefers-reduced-motion. The path data therefore appears twice,
 * once as SVG geometry here and once in the CSS. If you change one, change the other.
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
  'Animated diagram: a message written on device 1 is sealed with its key into ' +
  'ciphertext, passes through the Voiid server, which holds no key and cannot read ' +
  'it, and is opened with the key on device 2.';

const WIRE = 'M118 232 C 190 232, 190 168, 250 168 C 310 168, 310 232, 382 232';

/** A chat bubble inside a phone screen: two lines of text that can turn to ciphertext. */
function Bubble({ x, side }: { x: number; side: 'out' | 'in' }) {
  const cls = side === 'out' ? styles.bubbleOut : styles.bubbleIn;
  return (
    <g className={cls}>
      <rect x={x} y="232" width="38" height="24" rx="7" className={styles.bubbleBox} />
      <g className={styles.plain}>
        <line x1={x + 6} y1="240" x2={x + 32} y2="240" />
        <line x1={x + 6} y1="248" x2={x + 23} y2="248" />
      </g>
      <g className={styles.cipher}>
        <line x1={x + 6} y1="240" x2={x + 32} y2="240" />
        <line x1={x + 6} y1="248" x2={x + 23} y2="248" />
      </g>
    </g>
  );
}

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

      <ellipse cx="250" cy="200" rx="230" ry="150" fill={`url(#${bloom})`} className={styles.bloom} />

      {/* ---- the wire between the two devices, over the server ------------- */}
      <path d={WIRE} fill="none" stroke={`url(#${rail})`} strokeWidth="2.5" />
      <path
        d={WIRE}
        fill="none"
        strokeWidth="2"
        strokeDasharray="5 11"
        strokeLinecap="round"
        className={styles.wire}
      />

      {/* ---- the server: it relays, it cannot read -------------------------- */}
      <text x="250" y="40" className={styles.label} textAnchor="middle">
        our server
      </text>
      <g className={styles.server}>
        <rect x="216" y="52" width="68" height="21" rx="6" />
        <rect x="216" y="79" width="68" height="21" rx="6" />
        <circle cx="229" cy="62.5" r="2.8" className={styles.led} />
        <circle cx="229" cy="89.5" r="2.8" className={styles.ledScan} />
        <line x1="241" y1="62.5" x2="272" y2="62.5" className={styles.serverSlot} />
        <line x1="241" y1="89.5" x2="264" y2="89.5" className={styles.serverSlot} />
      </g>
      {/* The scan: a beam drops from the server onto the packet while it passes. */}
      <line x1="250" y1="100" x2="250" y2="156" className={styles.beamTrack} strokeDasharray="4 6" />
      <line x1="250" y1="100" x2="250" y2="156" className={styles.beam} />
      <circle cx="250" cy="168" r="14" className={styles.relayRing} />

      <g className={styles.noKey}>
        <rect x="296" y="60" width="164" height="30" rx="15" />
        <g className={styles.noKeyIcon} transform="translate(314 75)">
          <circle cx="-4" cy="0" r="4" />
          <path d="M0 0 H 9 M 6 0 v 3.5" />
          <line x1="-9" y1="7" x2="11" y2="-7" className={styles.strike} />
        </g>
        <text x="332" y="79.5" className={styles.noKeyText}>
          no key · can&rsquo;t read
        </text>
      </g>

      {/* ---- left device: hers ---------------------------------------------- */}
      <g className={styles.device}>
        <rect x="52" y="176" width="66" height="112" rx="14" />
        <rect x="61" y="188" width="48" height="80" rx="7" className={styles.deviceScreen} />
        <line x1="76" y1="182" x2="94" y2="182" strokeWidth="3" strokeLinecap="round" />
      </g>
      <Bubble x={66} side="out" />
      <g className={`${styles.key} ${styles.keyHer}`} transform="translate(85 322)">
        <circle cx="-15" cy="0" r="7.5" />
        <path d="M-7.5 0 H 17 M 9 0 v 7 M 17 0 v 5" />
      </g>
      <text x="85" y="356" className={styles.label} textAnchor="middle">
        device 1
      </text>

      {/* ---- right device: his ---------------------------------------------- */}
      <g className={styles.device}>
        <rect x="382" y="176" width="66" height="112" rx="14" />
        <rect x="391" y="188" width="48" height="80" rx="7" className={styles.deviceScreen} />
        <line x1="406" y1="182" x2="424" y2="182" strokeWidth="3" strokeLinecap="round" />
      </g>
      <Bubble x={396} side="in" />
      <g className={`${styles.key} ${styles.keyHis}`} transform="translate(415 322)">
        <circle cx="-15" cy="0" r="7.5" />
        <path d="M-7.5 0 H 17 M 9 0 v 7 M 17 0 v 5" />
      </g>
      <text x="415" y="356" className={styles.label} textAnchor="middle">
        device 2
      </text>

      {/* ---- the sealed packet riding the wire, ciphertext churning above it -- */}
      <g className={styles.packet}>
        <g className={styles.scramble}>
          <text y="-17" textAnchor="middle">x9#Qa7</text>
          <text y="-17" textAnchor="middle">7f!Kd2</text>
          <text y="-17" textAnchor="middle">Zp@2e$</text>
        </g>
        <rect x="-13" y="-10" width="26" height="20" rx="5" className={styles.envelope} />
        <path d="M-13 -6 L0 3.5 L13 -6" fill="none" className={styles.envelopeFlap} />
      </g>

      {/* ---- the step being shown ------------------------------------------ */}
      <g className={styles.captions}>
        <text x="250" y="300" textAnchor="middle" className={`${styles.caption} ${styles.c1}`}>
          1 · sealed on device 1
        </text>
        <text x="250" y="300" textAnchor="middle" className={`${styles.caption} ${styles.c2}`}>
          2 · relayed, never read
        </text>
        <text x="250" y="300" textAnchor="middle" className={`${styles.caption} ${styles.c3}`}>
          3 · opened on device 2
        </text>
      </g>
    </svg>
  );
}
