import type { ReactNode } from 'react';
import Link from 'next/link';
import { Glyph } from './Glyph';
import { hueVars, type DomainHue } from '../lib/hues';
import styles from './SurfaceTour.module.css';

/**
 * The five surfaces, as alternating diptychs.
 *
 * One band per surface: the claim on one side, a real screen on the other,
 * flipping direction each time. See the module CSS for why this replaced a
 * three-column card grid.
 *
 * Each band states its privacy stance in the same slot in the same voice —
 * including for the two surfaces that are NOT encrypted. Saying so in the tour,
 * next to the feature, rather than in a footnote further down, is the whole
 * posture of the site; a tour that quietly omitted it for Clips and Games would
 * be a worse page even if it read more smoothly.
 */

export type Surface = {
  href: string;
  index: string;
  title: string;
  body: string;
  hue: DomainHue;
  /** The E2EEBadge for this surface — encrypted, public, or refereed. */
  stance: ReactNode;
  /** The PhoneMockup (or other proof) shown opposite the claim. */
  proof: ReactNode;
  cta: string;
};

export function SurfaceTour({ surfaces }: { surfaces: Surface[] }) {
  return (
    <div className={styles.tour}>
      {surfaces.map((s, i) => (
        <section
          key={s.href}
          style={hueVars(s.hue)}
          aria-labelledby={`surface-${s.index}`}
          // Odd bands flip. Visual only — the DOM keeps claim before proof.
          className={[styles.band, i % 2 === 1 ? styles.flip : ''].filter(Boolean).join(' ')}
        >
          <div className={styles.copy}>
            <span className={styles.index}>{s.index}</span>
            <h3 id={`surface-${s.index}`} className={styles.title}>
              {s.title}
            </h3>
            <p className={styles.body}>{s.body}</p>
            <span className={styles.stance}>{s.stance}</span>
            <Link href={s.href} className={styles.action}>
              {s.cta}
              <Glyph name="arrow-right" size={16} className={styles.arrow} />
            </Link>
          </div>

          <div className={styles.proof}>{s.proof}</div>
        </section>
      ))}
    </div>
  );
}
