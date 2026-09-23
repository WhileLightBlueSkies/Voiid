import { Glyph } from './Glyph';
import styles from './FeaturePreview.module.css';

/**
 * A small piece of the real interface, one per feature card.
 *
 * The feature grid used to be five identical cards with an icon in the corner and
 * two-thirds of the card empty. An icon is a label, not proof; these are little
 * fragments of the thing itself, so the grid shows five different products
 * instead of five different words for "app".
 *
 * They are pictures: no text that matters lives only in here, and each is hidden
 * from assistive technology because the card's heading and copy already say it.
 */

export type PreviewKind = 'messaging' | 'calls' | 'map' | 'clips' | 'games';

export function FeaturePreview({ kind }: { kind: PreviewKind }) {
  return (
    <span className={styles.frame} data-kind={kind} aria-hidden="true">
      {kind === 'messaging' ? (
        <span className={styles.thread}>
          <span className={styles.day}>Today</span>
          <span className={`${styles.bubble} ${styles.me}`}>That place by the park?</span>
          <span className={`${styles.bubble} ${styles.them}`}>Dinner at eight?</span>
          <span className={`${styles.bubble} ${styles.me}`}>Booked it ✓✓</span>
          <span className={`${styles.bubble} ${styles.them} ${styles.dots}`}>
            <i /><i /><i />
          </span>
        </span>
      ) : null}

      {kind === 'calls' ? (
        <span className={styles.call}>
          <span className={styles.callAvatar}>N</span>
          <span className={styles.callName}>Nehal · 04:12</span>
          <span className={styles.callLock}>
            <Glyph name="lock" size={11} /> encrypted
          </span>
          <span className={styles.callRow}>
            <i /><i /><i className={styles.callEnd} />
          </span>
        </span>
      ) : null}

      {kind === 'map' ? (
        <span className={styles.map}>
          <i className={styles.mapPark} />
          <i className={styles.mapRoadA} />
          <i className={styles.mapRoadB} />
          <span className={styles.mapFriend}>A</span>
          <i className={styles.mapYou} />
          <span className={styles.mapChip}>Sharing · 58 min left</span>
        </span>
      ) : null}

      {kind === 'clips' ? (
        <span className={styles.clip}>
          <span className={styles.clipChip}>
            <Glyph name="broadcast" size={11} /> Public
          </span>
          <span className={styles.clipPlay}>
            <Glyph name="play" size={16} filled />
          </span>
          <span className={styles.clipFoot}>@maya · 2.4K</span>
        </span>
      ) : null}

      {kind === 'games' ? (
        <span className={styles.games}>
          <span className={styles.board}>
            {Array.from({ length: 36 }, (_, index) => (
              <i key={index} data-cell={CELLS[index] ?? undefined} />
            ))}
          </span>
          <span className={styles.gamesChip}>Snake · your turn</span>
        </span>
      ) : null}
    </span>
  );
}

/** A frozen frame of a 6×6 Snake board: three body cells, one head, one apple. */
const CELLS: Record<number, string> = {
  8: 'body',
  14: 'body',
  20: 'head',
  27: 'food',
};
