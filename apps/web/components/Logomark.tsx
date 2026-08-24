import type { CSSProperties } from 'react';

/**
 * The Voiid logo mark — three rounded bars forming the V.
 *
 * PEACOCK TEAL, FLAT. Kept byte-identical in shape to the iOS
 * (VoiidLogoMark.imageset/voiid-logomark.svg) and Android
 * (res/drawable/voiid_logomark.xml) marks; changing the brand colour means
 * changing all three.
 *
 * ── MIGRATED FROM ELECTRIC LIME ─────────────────────────────────────────────
 * The lime original shaded the back bar with a five-stop gradient (#457512 at
 * the ends to #AAD91E mid-bar), which is what made that bar read as one stroke
 * passing BEHIND the other two rather than as three bars crossing. That depth
 * cue is dropped deliberately: the mark is now unmistakably on-theme at every
 * size, and at the sizes it is actually drawn the gradient survived downscaling
 * poorly anyway.
 *
 * If the depth is ever wanted back, it is a linearGradient on the first rect
 * with gradientUnits="userSpaceOnUse" — NOT objectBoundingBox, which (because
 * the rect is tall, thin, and rotated 150°) drops the darkest stop into one
 * corner as a hard-edged dark slab. That was the "black thing" behind the mark
 * in the original Figma export. Teal stops mirroring the old ramp: #0A4A50,
 * #0E6970, #17A3B0, #13929E, #0C5A62.
 *
 * Inline (not <img>) so it costs no extra request and scales cleanly.
 */

/** Peacock teal — the brand colour. Matches VoiidColor.accent / .primary. */
const BRAND = '#13828C';

export type LogomarkProps = {
  /** Rendered height in px. Default 24. */
  size?: number;
  className?: string;
  style?: CSSProperties;
};

export function Logomark({ size = 24, className, style }: LogomarkProps) {
  return (
    <svg
      width={(size * 88) / 80}
      height={size}
      viewBox="0 0 88 80"
      fill="none"
      role="img"
      aria-hidden="true"
      focusable="false"
      className={className}
      style={style}
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect
        x="58.5586"
        y="68.9043"
        width="21.6824"
        height="79.5639"
        rx="10.8412"
        transform="rotate(150 58.5586 68.9043)"
        fill={BRAND}
      />
      <rect
        x="44.6035"
        y="42.1816"
        width="20.2613"
        height="30.6242"
        rx="10.1307"
        transform="rotate(30 44.6035 42.1816)"
        fill={BRAND}
      />
      <rect
        x="68.9043"
        y="0"
        width="21.6824"
        height="79.625"
        rx="10.8412"
        transform="rotate(30 68.9043 0)"
        fill={BRAND}
      />
    </svg>
  );
}
