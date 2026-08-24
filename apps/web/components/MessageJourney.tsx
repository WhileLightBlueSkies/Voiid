import { Glyph, type GlyphName } from './Glyph';
import styles from './MessageJourney.module.css';

/**
 * The three legs of a message's journey, on one continuous rail.
 *
 * This replaces three identical FeatureCards. Three cards in a row say "here are
 * three things"; a rail says "here is one path, and the middle of it is dashed."
 * The claim the section is making — we are blind for the middle leg — is carried
 * by the GRAPHIC, not only by the prose, which is the mapping principle: the
 * control (or here, the diagram) resembles the thing it describes.
 *
 * `blind` is marked with a dashed ring AND a dashed rail AND the word in the copy
 * — never by colour alone.
 */

export type JourneyStep = {
  glyph: GlyphName;
  title: string;
  body: string;
  /** The leg where the server carries ciphertext it cannot read. */
  blind?: boolean;
};

export function MessageJourney({ steps }: { steps: JourneyStep[] }) {
  return (
    <div className={styles.wrap}>
      {/* Decorative: the rail duplicates what the copy already says. */}
      <div className={styles.rail} aria-hidden="true">
        <div className={styles.railSolid} />
        <div className={styles.railBlind} />
      </div>

      <ol className={styles.steps}>
        {steps.map((s, i) => (
          <li
            key={s.title}
            className={[styles.step, s.blind ? styles.blind : ''].filter(Boolean).join(' ')}
          >
            <span className={styles.node} aria-hidden="true">
              <Glyph name={s.glyph} size={18} />
              <span className={styles.index}>{i + 1}</span>
            </span>
            <h3 className={styles.stepTitle}>{s.title}</h3>
            <p className={styles.stepBody}>{s.body}</p>
          </li>
        ))}
      </ol>
    </div>
  );
}
