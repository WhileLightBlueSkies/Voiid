import styles from './CallPathDiagram.module.css';

/**
 * THE CALLS MECHANISM, DRAWN.
 *
 * A call travels two separate paths, and the whole privacy claim is that they are
 * separate. This diagram is that fact and nothing else:
 *
 *   - UP, dashed, through our server: the ring, the SDP offer/answer, the ICE
 *     candidates. Relayed opaquely; the relay stamps the sender from the
 *     authenticated socket and never inspects or logs the payload
 *     (backend/websocket/src/index.ts, "Call signaling relay").
 *   - ACROSS, solid, phone to phone: the SRTP media, with the key derived on the
 *     two devices. It does not enter the server at all
 *     (database/migrations/014_calls.sql header; backend/api/src/routes/calls.ts).
 *
 * Authored SVG plus CSS — no library, no external asset. The two sealed packets ride
 * a CSS `offset-path` rather than SMIL `animateMotion`, because SMIL ignores
 * prefers-reduced-motion; the reduced-motion rule parks them mid-flight so the still
 * frame still reads. THE MEDIA PATH DATA THEREFORE APPEARS TWICE, once as SVG
 * geometry and once in the stylesheet. Change one, change the other.
 */

export type CallPathDiagramProps = {
  /** Rendered width in px; height follows the 520:430 viewBox. */
  size?: number;
  idPrefix?: string;
  className?: string;
};

const LABEL =
  'Diagram of a one-to-one Voiid call. Two dashed lines run from the two phones up ' +
  'to the Voiid server, carrying only the ring, the session description and the ' +
  'network candidates — relayed, never opened. A separate solid line runs directly ' +
  'between the two phones along the bottom, carrying the encrypted audio and video ' +
  'through a padlock; it never reaches the server. Each phone holds its own key.';

export function CallPathDiagram({
  size = 520,
  idPrefix = 'callpath',
  className,
}: CallPathDiagramProps) {
  const rail = `${idPrefix}-rail`;
  const bloom = `${idPrefix}-bloom`;

  return (
    <svg
      className={[styles.diagram, className].filter(Boolean).join(' ')}
      width={size}
      height={size * (430 / 520)}
      viewBox="0 0 520 430"
      role="img"
      aria-label={LABEL}
    >
      <defs>
        <linearGradient id={rail} x1="0" y1="0" x2="1" y2="0">
          <stop offset="0%" className={styles.railEdge} />
          <stop offset="50%" className={styles.railMid} />
          <stop offset="100%" className={styles.railEdge} />
        </linearGradient>
        <radialGradient id={bloom} cx="50%" cy="50%" r="50%">
          <stop offset="0%" className={styles.bloomIn} />
          <stop offset="100%" className={styles.bloomOut} />
        </radialGradient>
      </defs>

      <ellipse cx="260" cy="230" rx="250" ry="180" fill={`url(#${bloom})`} />

      {/* ---- the server, and the only thing it carries --------------------- */}
      <text x="260" y="24" className={styles.label} textAnchor="middle">
        our server
      </text>
      <g className={styles.server}>
        <rect x="214" y="38" width="92" height="24" rx="6" />
        <rect x="214" y="68" width="92" height="24" rx="6" />
        <circle cx="229" cy="50" r="3" className={styles.led} />
        <circle cx="229" cy="80" r="3" className={styles.ledDim} />
      </g>
      <text x="260" y="118" className={styles.small} textAnchor="middle">
        ring · SDP · ICE
      </text>
      <text x="260" y="136" className={styles.smallDim} textAnchor="middle">
        relayed, never opened
      </text>

      {/* ---- signalling: the only thing that goes through us ---------------- */}
      <path d="M88 226 C 116 196, 152 126, 208 90" className={styles.signal} fill="none" />
      <path d="M432 226 C 404 196, 368 126, 312 90" className={styles.signal} fill="none" />

      {/* ---- the two phones ------------------------------------------------- */}
      <g className={styles.device}>
        <rect x="56" y="230" width="64" height="110" rx="14" />
        <rect x="64" y="242" width="48" height="82" rx="7" className={styles.deviceScreen} />
        <line x1="74" y1="236" x2="102" y2="236" strokeWidth="3" strokeLinecap="round" />
      </g>
      <g className={styles.device}>
        <rect x="400" y="230" width="64" height="110" rx="14" />
        <rect x="408" y="242" width="48" height="82" rx="7" className={styles.deviceScreen} />
        <line x1="418" y1="236" x2="446" y2="236" strokeWidth="3" strokeLinecap="round" />
      </g>

      {/* ---- a key under each phone: the material exists only here ---------- */}
      <g className={styles.key} transform="translate(88 372)">
        <circle cx="-15" cy="0" r="7.5" />
        <path d="M-7.5 0 H 17 M 9 0 v 7 M 17 0 v 5" />
      </g>
      <g className={styles.key} transform="translate(432 372)">
        <circle cx="-15" cy="0" r="7.5" />
        <path d="M-7.5 0 H 17 M 9 0 v 7 M 17 0 v 5" />
      </g>

      {/* ---- media: phone to phone, under the padlock, past the server ------ */}
      <path
        d="M120 280 C 194 372, 326 372, 400 280"
        fill="none"
        stroke={`url(#${rail})`}
        strokeWidth="7"
        strokeLinecap="round"
      />
      <path
        d="M120 280 C 194 372, 326 372, 400 280"
        fill="none"
        strokeWidth="2"
        strokeDasharray="5 11"
        strokeLinecap="round"
        className={styles.mediaCrawl}
      />

      <g className={styles.lock}>
        <path d="M249 336 v -7 a 11 11 0 0 1 22 0 v 7" className={styles.shackle} fill="none" />
        <rect x="243" y="336" width="34" height="26" rx="8" className={styles.lockBody} />
        <circle cx="260" cy="346" r="3.2" className={styles.lockPin} />
        <line x1="260" y1="349" x2="260" y2="355" className={styles.lockPin} strokeLinecap="round" />
      </g>

      {/* Two packets, one each way — a call is not a one-way delivery. */}
      <g className={[styles.packet, styles.packetOut].join(' ')}>
        <rect x="-11" y="-8" width="22" height="16" rx="4" />
        <circle cx="0" cy="0" r="2.2" className={styles.packetPin} />
      </g>
      <g className={[styles.packet, styles.packetBack].join(' ')}>
        <rect x="-11" y="-8" width="22" height="16" rx="4" />
        <circle cx="0" cy="0" r="2.2" className={styles.packetPin} />
      </g>

      <text x="260" y="404" className={styles.caption} textAnchor="middle">
        media never touches the server
      </text>
    </svg>
  );
}
