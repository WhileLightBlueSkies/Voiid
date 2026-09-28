import Link from 'next/link';
import { SURFACES } from '../lib/nav';
import { FeaturePreview, type PreviewKind } from './FeaturePreview';
import { Glyph } from './Glyph';
import styles from './FeatureRail.module.css';

const KINDS: Record<string, PreviewKind> = {
  '/messaging': 'messaging',
  '/calls': 'calls',
  '/map': 'map',
  '/clips': 'clips',
  '/games': 'games',
};

const LEADS: Record<string, string> = {
  '/messaging': 'Say everything. Share it with the people you chose.',
  '/calls': 'Voice and video that feel close, even from far away.',
  '/map': 'Meet up without leaving your location on forever.',
  '/clips': 'Find something worth sending to the group.',
  '/games': 'Turn the chat into game night in one tap.',
};

/** The honest one-word status of each surface, shown on the card rather than buried. */
const BOUNDARY: Record<string, { label: string; kind: 'sealed' | 'open' }> = {
  '/messaging': { label: 'End-to-end encrypted', kind: 'sealed' },
  '/calls': { label: 'End-to-end encrypted', kind: 'sealed' },
  '/map': { label: 'End-to-end encrypted', kind: 'sealed' },
  '/clips': { label: 'Public by design', kind: 'open' },
  '/games': { label: 'Server-refereed', kind: 'open' },
};

export function FeatureRail() {
  return (
    <section id="features" className={styles.section} aria-label="Explore Voiid features">
      <div className={styles.heading}>
        <p className="eyebrow">One app, fewer handoffs</p>
        <h2>Your people are already the point.</h2>
        <p>Voiid brings the things you do together into one calmer place.</p>
      </div>

      {/* Two wide cards on the first row, three on the second: 3+3 then 2+2+2
          tiles the six columns exactly, so no card is orphaned on a row alone. */}
      <div className={styles.grid}>
        {SURFACES.map((surface, index) => (
          <Link
            key={surface.href}
            href={`${surface.href}/`}
            className={styles.card}
            data-large={index < 2 ? 'true' : undefined}
          >
            <FeaturePreview kind={KINDS[surface.href]} />

            <span className={styles.body}>
              <span className={styles.top}>
                <h3>{surface.label}</h3>
                <span className={styles.boundary} data-kind={BOUNDARY[surface.href].kind}>
                  <Glyph name={BOUNDARY[surface.href].kind === 'sealed' ? 'lock' : 'broadcast'} size={12} />
                  {BOUNDARY[surface.href].label}
                </span>
              </span>
              <p>{LEADS[surface.href]}</p>
              <span className={styles.link}>
                Explore {surface.label.toLowerCase()} <Glyph name="arrow-right" size={16} />
              </span>
            </span>
          </Link>
        ))}
      </div>
    </section>
  );
}
