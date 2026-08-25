import type { CSSProperties } from 'react';

/**
 * The Voiid logo mark — three rounded bars forming the V.
 *
 * Matched to the shipping app icon
 * (apps/ios/.../AppIcon.appiconset/AppIcon-1024.png): peacock teal, with the
 * back bar SHADED rather than flat.
 *
 * ── WHY THE BACK BAR IS A GRADIENT ──────────────────────────────────────────
 * The shading is not decoration, it is the depth cue. Ramping the back bar from
 * a dark #0F464A at its far end to full brand #13828C where the two bars meet
 * is what makes it read as ONE STROKE PASSING BEHIND the other, instead of as
 * three flat bars crossing at a point. Flattening it (which this file did for a
 * while) loses the third dimension and the mark goes muddy at small sizes.
 *
 * The stops are sampled directly off AppIcon-1024.png along the bar's axis, so
 * the web mark and the app icon are the same artwork.
 *
 * `gradientUnits="userSpaceOnUse"` is load-bearing. With the default
 * objectBoundingBox, the gradient maps to the bounding box of the PATH DATA —
 * and because this rect is tall, thin and carries rotate(150), that box is
 * measured BEFORE the rotation. The darkest stop lands in a corner as a
 * hard-edged dark slab: the "black thing behind the logo" from the original
 * Figma export. userSpaceOnUse resolves in the rect's own rotated space, so the
 * ramp runs along the bar's long axis where it belongs.
 *
 * ── ONE MARK, FOUR PLACES ───────────────────────────────────────────────────
 * Kept identical in shape to the iOS imageset and the Android drawable.
 * Changing the brand colour means changing all of them.
 *
 * NOTE the app icon also has a near-black #0B0B0B ground. That is deliberately
 * NOT reproduced here: the site is light, and a black tile beside a teal
 * wordmark in near-white chrome reads as a pasted sticker. The ground belongs
 * to the ICON (see app/icon.svg, app/apple-icon.png), not to the mark.
 *
 * Inline (not <img>) so it costs no extra request and scales cleanly. The
 * gradient id is prefixed so two marks on one page cannot cross-wire.
 */

/** Peacock teal — the brand colour. Matches VoiidColor.accent / .primary. */
const BRAND = '#13828C';
/** The back bar's far end, sampled off AppIcon-1024.png. */
const BRAND_DEEP = '#0F464A';

export type LogomarkProps = {
  /** Rendered height in px. Default 24. */
  size?: number;
  /**
   * Disambiguates the gradient id. Only needed if more than one mark renders on
   * a page — duplicate ids would cross-wire the fills.
   */
  idPrefix?: string;
  className?: string;
  style?: CSSProperties;
};

export function Logomark({
  size = 24,
  idPrefix = 'voiid',
  className,
  style,
}: LogomarkProps) {
  const backBarId = `${idPrefix}-mark-backbar`;
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
      <defs>
        {/*
          Runs along the back bar's LONG AXIS, in the bar's own rotated space.
          x1/x2 sit at the bar's mid-width (21.6824 / 2) and y spans its full
          height, so the ramp travels end-to-end rather than across the width.
        */}
        <linearGradient
          id={backBarId}
          gradientUnits="userSpaceOnUse"
          x1="10.8412"
          y1="0"
          x2="10.8412"
          y2="79.5639"
        >
          <stop offset="0" stopColor={BRAND_DEEP} />
          <stop offset="1" stopColor={BRAND} />
        </linearGradient>
      </defs>
      {/* The back bar — shaded, so it reads as passing BEHIND the front one. */}
      <rect
        x="58.5586"
        y="68.9043"
        width="21.6824"
        height="79.5639"
        rx="10.8412"
        transform="rotate(150 58.5586 68.9043)"
        fill={`url(#${backBarId})`}
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
