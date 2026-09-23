import type { CSSProperties, ReactNode } from 'react';
import styles from './PhoneFrame.module.css';

/**
 * The device silhouette every product shot on this site is drawn inside.
 *
 * WHY ONE COMPONENT: a phone drawn twice is a phone drawn two different shapes.
 * The hero and the interactive tour previously each had their own rounded
 * rectangle with their own radius, bezel and notch, and the two disagreed — which
 * is exactly what makes a mockup read as "a div with rounded corners" instead of
 * a phone. Everything below is one set of proportions, taken from a 6.1" iPhone
 * and expressed as ratios so the same shape holds at 13rem in the hero and at
 * 24rem in the tour.
 *
 * THE PROPORTIONS (body width = W):
 *   body aspect            0.483  (70.6 × 146.6 mm)
 *   bezel                  0.042W — the black border between band and pixels
 *   body corner radius     0.17W
 *   screen corner radius   0.128W (= body radius − bezel: concentric, not guessed)
 *   Dynamic Island         31.8% of screen width, 3.4:1, 1.3% of height from top
 *   home indicator         35.4% of screen width
 *
 * THE SCREEN IS A CONTAINER (`container-type: inline-size`), so everything drawn
 * inside it sizes in `cqw` and the simulated interface scales with the device
 * instead of being re-tuned per call site.
 */

export type PhoneFrameProps = {
  children: ReactNode;
  /** Any CSS length for the body width. Everything else derives from it. */
  width?: string;
  /** Status-bar clock. A fixed string, never `new Date()` — a static export must not drift. */
  time?: string;
  /**
   * Which way the status bar and home indicator are painted. `auto` follows the
   * page theme; a screen that is dark in both themes (Clips, a call) passes `light`.
   */
  chrome?: 'auto' | 'light' | 'dark';
  /** Hide the status bar for a screen that draws its own (a full-bleed video). */
  statusBar?: boolean;
  /**
   * Accessible name. Supplying one makes the device a single labelled image and
   * its contents decorative — right for a product shot, wrong for the tour, where
   * every control inside the screen is real. Omit it there.
   */
  label?: string;
  className?: string;
  screenClassName?: string;
  style?: CSSProperties;
};

function StatusIcons() {
  return (
    <span className={styles.statusIcons} aria-hidden="true">
      <svg viewBox="0 0 18 12" className={styles.signal} fill="currentColor">
        <rect x="0" y="8" width="3" height="4" rx="1" />
        <rect x="5" y="5.5" width="3" height="6.5" rx="1" />
        <rect x="10" y="3" width="3" height="9" rx="1" />
        <rect x="15" y="0" width="3" height="12" rx="1" />
      </svg>
      <svg viewBox="0 0 16 12" className={styles.wifi} fill="currentColor">
        <path d="M8 11.4 5.9 8.9a3.2 3.2 0 0 1 4.2 0L8 11.4Z" />
        <path
          d="M3.5 6.4a6.8 6.8 0 0 1 9 0"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.7"
          strokeLinecap="round"
        />
        <path
          d="M1 3.6a10.4 10.4 0 0 1 14 0"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.7"
          strokeLinecap="round"
        />
      </svg>
      <svg viewBox="0 0 27 12" className={styles.battery} fill="none">
        <rect
          x="0.6"
          y="0.6"
          width="23"
          height="10.8"
          rx="3.2"
          stroke="currentColor"
          strokeOpacity="0.45"
          strokeWidth="1.2"
        />
        <rect x="2.4" y="2.4" width="16" height="7.2" rx="2" fill="currentColor" />
        <path
          d="M25.3 4.2a2.4 2.4 0 0 1 0 3.6"
          stroke="currentColor"
          strokeOpacity="0.45"
          strokeWidth="1.2"
          strokeLinecap="round"
        />
      </svg>
    </span>
  );
}

export function PhoneFrame({
  children,
  width,
  time = '9:41',
  chrome = 'auto',
  statusBar = true,
  label,
  className,
  screenClassName,
  style,
}: PhoneFrameProps) {
  return (
    <div
      className={[styles.phone, className].filter(Boolean).join(' ')}
      style={width ? ({ ...style, '--phone-w': width } as CSSProperties) : style}
      role={label ? 'img' : undefined}
      aria-label={label}
      data-chrome={chrome}
    >
      <span className={`${styles.key} ${styles.action}`} />
      <span className={`${styles.key} ${styles.volumeUp}`} />
      <span className={`${styles.key} ${styles.volumeDown}`} />
      <span className={`${styles.key} ${styles.power}`} />

      <div className={styles.band}>
        <div className={[styles.screen, screenClassName].filter(Boolean).join(' ')}>
          {statusBar ? (
            <div className={styles.statusBar}>
              <span className={styles.time}>{time}</span>
              <StatusIcons />
            </div>
          ) : null}

          <div className={styles.content}>{children}</div>

          <span className={styles.island} />
          <span className={styles.homeIndicator} />
          <span className={styles.glass} />
        </div>
      </div>
    </div>
  );
}
