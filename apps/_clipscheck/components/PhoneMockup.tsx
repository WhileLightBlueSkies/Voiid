import type { ReactNode } from 'react';
import { hueVars, type DomainHue } from '../lib/hues';
import styles from './PhoneMockup.module.css';

/**
 * A phone, drawn in CSS.
 *
 * No screenshots: there is no CDN budget, offline builds must work, and a real
 * screenshot goes stale the day the app ships a change. This is a frame — the
 * titanium rail, the rounded display, the Dynamic-Island cutout, the home
 * indicator — that a page fills with real markup styled from the same tokens the
 * app uses. What is inside is HTML, so it stays sharp, reflows on a phone, and can
 * be read by a screen reader.
 *
 * ACCESSIBILITY: the frame is decorative and hidden. What a page puts inside is
 * real content, so give the mockup a `label` describing what the screen shows, or
 * mark it `decorative` if the surrounding copy already says everything.
 */

export type PhoneMockupProps = {
  /** The screen content. Fills the display area; scrolling is clipped, not scrolled. */
  children: ReactNode;
  hue?: DomainHue;
  /** 'sm' 240px · 'md' 300px · 'lg' 340px display width. Scales with the viewport. */
  size?: 'sm' | 'md' | 'lg';
  /** A slight perspective tilt. Suppressed at phone widths where it wastes room. */
  tilt?: 'none' | 'left' | 'right';
  /** A soft bloom of the current hue behind the device. */
  glow?: boolean;
  /** Describes the screen for assistive tech, e.g. "A group chat in Voiid". */
  label?: string;
  /** Set when the copy beside it already conveys everything the screen shows. */
  decorative?: boolean;
  /** Status-bar clock. Fixed by default so no build looks like it drifted. */
  time?: string;
  className?: string;
};

export function PhoneMockup({
  children,
  hue,
  size = 'md',
  tilt = 'none',
  glow = true,
  label,
  decorative = false,
  time = '9:41',
  className,
}: PhoneMockupProps) {
  return (
    <div
      style={hueVars(hue)}
      className={[
        styles.stage,
        styles[size],
        tilt !== 'none' ? styles[`tilt-${tilt}`] : '',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
      role={decorative ? 'presentation' : 'img'}
      aria-label={decorative ? undefined : label}
      aria-hidden={decorative || undefined}
    >
      {glow ? <span className={styles.glow} aria-hidden="true" /> : null}

      <div className={styles.device}>
        {/* Frame, buttons and cutout are chrome — never announced. */}
        <span className={styles.buttonVolumeUp} aria-hidden="true" />
        <span className={styles.buttonVolumeDown} aria-hidden="true" />
        <span className={styles.buttonPower} aria-hidden="true" />

        <div className={styles.screen}>
          <div className={styles.statusBar} aria-hidden="true">
            <span className={styles.clock}>{time}</span>
            <span className={styles.island} />
            <span className={styles.indicators}>
              <span className={styles.signal} />
              <span className={styles.battery} />
            </span>
          </div>

          <div className={styles.content}>{children}</div>

          <span className={styles.homeIndicator} aria-hidden="true" />
        </div>
      </div>
    </div>
  );
}

/* ---------------------------------------------------------------------------
 * Screen furniture. These exist so a page never writes a raw hex to fake a chat
 * row or a nav bar inside the frame.
 * ------------------------------------------------------------------------ */

/** The in-app top bar: back chevron, title, optional subtitle and trailing slot. */
export function PhoneAppBar({
  title,
  subtitle,
  trailing,
  back = true,
}: {
  title: ReactNode;
  subtitle?: ReactNode;
  trailing?: ReactNode;
  back?: boolean;
}) {
  return (
    <div className={styles.appBar}>
      {back ? <span className={styles.back} aria-hidden="true" /> : null}
      <span className={styles.appBarText}>
        <span className={styles.appBarTitle}>{title}</span>
        {subtitle ? <span className={styles.appBarSubtitle}>{subtitle}</span> : null}
      </span>
      {trailing ? <span className={styles.appBarTrailing}>{trailing}</span> : null}
    </div>
  );
}

/** A message bubble in the app's real bubble colours. */
export function ChatBubble({
  children,
  side = 'received',
  meta,
}: {
  children: ReactNode;
  side?: 'sent' | 'received';
  /** Timestamp / tick line inside the bubble. */
  meta?: string;
}) {
  return (
    <div className={[styles.bubbleRow, styles[`row-${side}`]].join(' ')}>
      <div className={[styles.bubble, styles[side]].join(' ')}>
        <span>{children}</span>
        {meta ? <span className={styles.bubbleMeta}>{meta}</span> : null}
      </div>
    </div>
  );
}

/** A stand-in avatar. `seed` picks one of five hue washes deterministically. */
export function PhoneAvatar({
  initials,
  size = 36,
  seed = 0,
}: {
  initials: string;
  size?: number;
  seed?: number;
}) {
  const hues = ['chat', 'stories', 'map', 'calls', 'payments'] as const;
  const hue = hues[Math.abs(seed) % hues.length];
  return (
    <span
      className={styles.avatar}
      style={{
        width: size,
        height: size,
        fontSize: Math.round(size * 0.36),
        ['--hue' as string]: `var(--hue-${hue})`,
      }}
      aria-hidden="true"
    >
      {initials}
    </span>
  );
}

/** A list row: avatar, title, preview line, trailing meta. */
export function PhoneRow({
  avatar,
  title,
  preview,
  meta,
  badge,
}: {
  avatar?: ReactNode;
  title: ReactNode;
  preview?: ReactNode;
  meta?: ReactNode;
  /** The unread pill. This is the app's amber — count it against the page's one. */
  badge?: ReactNode;
}) {
  return (
    <div className={styles.row}>
      {avatar}
      <span className={styles.rowText}>
        <span className={styles.rowTitle}>{title}</span>
        {preview ? <span className={styles.rowPreview}>{preview}</span> : null}
      </span>
      <span className={styles.rowTrail}>
        {meta ? <span className={styles.rowMeta}>{meta}</span> : null}
        {badge ? <span className={styles.rowBadge}>{badge}</span> : null}
      </span>
    </div>
  );
}
