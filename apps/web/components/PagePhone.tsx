import { VoiidPhone } from './home/VoiidPhone';
import type { ScreenId } from './home/screens';
import styles from './PagePhone.module.css';

/**
 * The live phone, dressed for a feature page: a soft brand glow behind it and a
 * one-line caption under it. `path` opens it on the right screen with a real back
 * stack, so Back inside the phone lands where the app would.
 */
export function PagePhone({
  path,
  label,
  caption = 'Live preview · tap anything',
  size = 'lg',
  tilt,
}: {
  path: ScreenId[];
  label: string;
  caption?: string | null;
  size?: 'md' | 'lg';
  tilt?: 'left' | 'right';
}) {
  return (
    <figure className={styles.wrap} data-size={size} data-tilt={tilt}>
      <span className={styles.glow} aria-hidden="true" />
      <div className={styles.phone}>
        <VoiidPhone initialPath={path} label={label} />
      </div>
      {caption ? (
        <figcaption className={styles.caption}>
          <span className={styles.dot} aria-hidden="true" />
          {caption}
        </figcaption>
      ) : null}
    </figure>
  );
}
