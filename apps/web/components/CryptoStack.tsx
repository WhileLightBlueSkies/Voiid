import styles from './CryptoStack.module.css';

/**
 * The layer stack: what rests on what, and which band is ours.
 *
 * The page's argument is that the custom surface is SMALL and sits on top of
 * published standards. That is a claim about proportion, and proportion is
 * exactly what a list cannot show — six borrowed cards next to six built cards
 * reads as "half of this is homemade", which is the opposite of the truth. Drawn
 * as a stack with one tinted band, the proportion is visible before a word is
 * read.
 */

export type StackLayer = {
  name: string;
  detail: string;
  /** True when Voiid wrote this layer rather than adopting a standard. */
  ours?: boolean;
};

export function CryptoStack({
  layers,
  caption,
}: {
  layers: StackLayer[];
  caption?: React.ReactNode;
}) {
  return (
    <div>
      {/* A list, because the order is the meaning. */}
      <ol className={styles.stack}>
        {layers.map((l) => (
          <li
            key={l.name}
            className={[styles.layer, l.ours ? styles.ours : ''].filter(Boolean).join(' ')}
          >
            <span className={[styles.label, l.ours ? styles.labelOurs : styles.labelStd].join(' ')}>
              {l.ours ? 'Ours' : 'Standard'}
            </span>
            <span className={styles.text}>
              <span className={styles.name}>{l.name}</span>
              <span className={styles.detail}> — {l.detail}</span>
            </span>
          </li>
        ))}
      </ol>
      {caption ? <p className={styles.caption}>{caption}</p> : null}
    </div>
  );
}
