import styles from './SfuDiagram.module.css';

/**
 * WHY A GROUP CALL IS BUILT DIFFERENTLY — the argument, drawn.
 *
 * Left: a full mesh. Every participant uploads a separate stream to every other one,
 * so four people means twelve uploads and the arithmetic gets worse fast. It collapses
 * past about four people, and phones overheat first (docs/LIVEKIT_SETUP.md).
 *
 * Right: a Selective Forwarding Unit. Each client uploads ONCE and the server forwards.
 * Four people, four uploads. The frames are encrypted before they leave the phone with
 * a key derived from the conversation's own MLS group, so the SFU can route them and
 * cannot open them — `POST /calls/group/token` mints a join permission and no key
 * material (backend/api/src/routes/calls.ts).
 *
 * The two numbers under each cluster are the point: this is a diagram of a cost, which
 * is the honest reason the group path exists rather than "it scales better".
 */

export type SfuDiagramProps = {
  size?: number;
  className?: string;
};

const LABEL =
  'Diagram comparing two ways to run a four-person call. On the left, a full mesh: ' +
  'every phone is joined to every other phone, twelve uploads in all. On the right, ' +
  'a selective forwarding unit sits in the middle: each phone connects only to it, ' +
  'four uploads in all, and the frames it forwards stay sealed.';

/** Node centres, shared by both clusters so the two read as the same four people. */
const MESH = [
  [130, 42],
  [64, 108],
  [130, 174],
  [196, 108],
] as const;

const SPOKE = [
  [390, 36],
  [312, 108],
  [390, 180],
  [468, 108],
] as const;

export function SfuDiagram({ size = 520, className }: SfuDiagramProps) {
  // Every unordered pair — the n(n-1)/2 lines that are the whole problem.
  const meshPairs: [number, number][] = [];
  for (let i = 0; i < MESH.length; i += 1) {
    for (let j = i + 1; j < MESH.length; j += 1) meshPairs.push([i, j]);
  }

  return (
    <svg
      className={[styles.diagram, className].filter(Boolean).join(' ')}
      width={size}
      height={size * (250 / 520)}
      viewBox="0 0 520 250"
      role="img"
      aria-label={LABEL}
    >
      {/* ---- left: the full mesh we did not build ------------------------- */}
      <g className={styles.meshLines}>
        {meshPairs.map(([i, j]) => (
          <line
            key={`${i}-${j}`}
            x1={MESH[i][0]}
            y1={MESH[i][1]}
            x2={MESH[j][0]}
            y2={MESH[j][1]}
          />
        ))}
      </g>
      {MESH.map(([cx, cy]) => (
        <circle key={`m${cx}-${cy}`} cx={cx} cy={cy} r="13" className={styles.nodeMuted} />
      ))}

      <text x="130" y="214" className={styles.headingMuted} textAnchor="middle">
        full mesh
      </text>
      <text x="130" y="234" className={styles.figureMuted} textAnchor="middle">
        4 people · 12 uploads
      </text>

      {/* ---- the divider --------------------------------------------------- */}
      <line x1="260" y1="34" x2="260" y2="186" className={styles.divider} />

      {/* ---- right: the SFU, drawn under the nodes so spokes end at its edge */}
      <g className={styles.spokeLines}>
        {SPOKE.map(([cx, cy]) => (
          <line key={`s${cx}-${cy}`} x1={cx} y1={cy} x2="390" y2="108" />
        ))}
      </g>

      <rect x="362" y="88" width="56" height="40" rx="10" className={styles.hub} />
      <text x="390" y="113" className={styles.hubLabel} textAnchor="middle">
        SFU
      </text>

      {SPOKE.map(([cx, cy]) => (
        <circle key={`n${cx}-${cy}`} cx={cx} cy={cy} r="13" className={styles.node} />
      ))}

      {/* One frame arriving, one leaving — forwarding, shown rather than said. */}
      <rect className={[styles.frame, styles.frameIn].join(' ')} x="-6" y="-6" width="12" height="12" rx="3" />
      <rect className={[styles.frame, styles.frameOut].join(' ')} x="-6" y="-6" width="12" height="12" rx="3" />

      <text x="390" y="214" className={styles.heading} textAnchor="middle">
        SFU — forwards, cannot open
      </text>
      <text x="390" y="234" className={styles.figure} textAnchor="middle">
        4 people · 4 uploads
      </text>
    </svg>
  );
}
