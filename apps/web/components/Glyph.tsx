import type { CSSProperties, ReactElement } from 'react';

/**
 * The icon set, drawn inline.
 *
 * No icon library and no sprite file: there is no CDN budget and offline builds must
 * work, so every glyph is authored here as bare path data. All are on a 24×24 grid,
 * stroked (not filled) at 1.6 so they sit at the same optical weight as the rounded
 * type, and every one inherits `currentColor` — a glyph never names a colour.
 */

export type GlyphName =
  | 'chat'
  | 'call'
  | 'map'
  | 'clips'
  | 'games'
  | 'privacy'
  | 'lock'
  | 'key'
  | 'shield'
  | 'eye-off'
  | 'globe'
  | 'group'
  | 'device'
  | 'note'
  | 'sparkle'
  | 'arrow-right'
  | 'check'
  | 'broadcast';

export type GlyphProps = {
  name: GlyphName;
  /** Rendered size in px, both axes. Default 24. */
  size?: number;
  /**
   * Accessible name. Omit for decorative glyphs (the default), which are hidden
   * from assistive technology — the neighbouring text already says it.
   */
  title?: string;
  className?: string;
  style?: CSSProperties;
};

const PATHS: Record<GlyphName, ReactElement> = {
  chat: (
    <>
      <path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v7a2.5 2.5 0 0 1-2.5 2.5H10l-4.2 3.3A.5.5 0 0 1 5 18.9V16h-.5" />
      <path d="M8.5 8.75h7M8.5 12h4.5" />
    </>
  ),
  call: (
    <>
      <path d="M5.2 4.6h3l1.3 3.4-1.8 1.4a11.5 11.5 0 0 0 5.4 5.4l1.4-1.8 3.4 1.3v3a1.7 1.7 0 0 1-1.9 1.7C10.4 18.4 5.6 13.6 3.5 6.5A1.7 1.7 0 0 1 5.2 4.6Z" />
      <path d="M15 4.6a4.6 4.6 0 0 1 4.5 4.5" />
    </>
  ),
  map: (
    <>
      <path d="M9.3 4.4 3.8 6.6v13l5.5-2.2 5.4 2.2 5.5-2.2v-13l-5.5 2.2-5.4-2.2Z" />
      <path d="M9.3 4.4v13M14.7 6.6v13" />
    </>
  ),
  clips: (
    <>
      <rect x="3.6" y="4.2" width="16.8" height="15.6" rx="3.2" />
      <path d="M3.6 8.4h16.8" />
      <path d="M10.2 11.6l4.2 2.4-4.2 2.4v-4.8Z" />
    </>
  ),
  games: (
    <>
      <path d="M7.6 8.2h8.8a4 4 0 0 1 3.9 3.1l.8 3.6a2.6 2.6 0 0 1-4.7 2l-.9-1.3H8.5l-.9 1.3a2.6 2.6 0 0 1-4.7-2l.8-3.6a4 4 0 0 1 3.9-3.1Z" />
      <path d="M7.3 12.2v2.2M6.2 13.3h2.2M15.6 12.4h.01M17.4 14.2h.01" />
    </>
  ),
  privacy: (
    <>
      <path d="M12 3.6 5 6.4v5c0 4.1 2.8 7.6 7 9 4.2-1.4 7-4.9 7-9v-5L12 3.6Z" />
      <path d="M12 10.4v3.4" />
    </>
  ),
  lock: (
    <>
      <rect x="4.6" y="10.2" width="14.8" height="9.6" rx="2.6" />
      <path d="M8.2 10.2V7.8a3.8 3.8 0 0 1 7.6 0v2.4" />
      <path d="M12 14v2.2" />
    </>
  ),
  key: (
    <>
      <circle cx="8" cy="12" r="3.4" />
      <path d="M11.4 12H20M17.4 12v3M14.6 12v2.2" />
    </>
  ),
  shield: (
    <>
      <path d="M12 3.6 5 6.4v5c0 4.1 2.8 7.6 7 9 4.2-1.4 7-4.9 7-9v-5L12 3.6Z" />
      <path d="m9.2 11.9 2 2 3.6-3.8" />
    </>
  ),
  'eye-off': (
    <>
      <path d="M10.4 6.3a8.9 8.9 0 0 1 1.6-.15c4.6 0 7.6 3.4 8.8 5.4a1 1 0 0 1 0 1c-.4.7-1.2 1.8-2.4 2.8" />
      <path d="M15.6 17.4a9 9 0 0 1-3.6.7c-4.6 0-7.6-3.4-8.8-5.4a1 1 0 0 1 0-1c.6-1 1.8-2.6 3.6-3.8" />
      <path d="M10.2 10.4a2.4 2.4 0 0 0 3.3 3.4M4 4l16 16" />
    </>
  ),
  globe: (
    <>
      <circle cx="12" cy="12" r="8.2" />
      <path d="M3.8 12h16.4M12 3.8c2.1 2.2 3.2 5.1 3.2 8.2s-1.1 6-3.2 8.2c-2.1-2.2-3.2-5.1-3.2-8.2S9.9 6 12 3.8Z" />
    </>
  ),
  group: (
    <>
      <circle cx="9" cy="8.6" r="3.2" />
      <path d="M3.6 19.4a5.6 5.6 0 0 1 10.8 0" />
      <path d="M15.6 6.1a3.2 3.2 0 0 1 0 6M17 14.4a5.6 5.6 0 0 1 3.4 5" />
    </>
  ),
  device: (
    <>
      <rect x="7.2" y="2.8" width="9.6" height="18.4" rx="2.6" />
      <path d="M10.6 5.3h2.8" />
    </>
  ),
  note: (
    <>
      <path d="M6 3.8h8.2L19 8.6v11.6H6V3.8Z" />
      <path d="M14 3.8v5h5M9 13h6M9 16.4h4" />
    </>
  ),
  sparkle: (
    <>
      <path d="M12 3.4c.7 3.9 1.8 5 5.6 5.6-3.8.7-4.9 1.8-5.6 5.6-.7-3.8-1.8-4.9-5.6-5.6 3.8-.6 4.9-1.7 5.6-5.6Z" />
      <path d="M17.6 15.2c.4 2 .9 2.5 2.8 2.8-1.9.4-2.4.9-2.8 2.8-.3-1.9-.8-2.4-2.8-2.8 2-.3 2.5-.8 2.8-2.8Z" />
    </>
  ),
  'arrow-right': <path d="M4.6 12h14.2m-5.4-5.4L18.8 12l-5.4 5.4" />,
  check: <path d="m5 12.6 4.4 4.4L19 7.4" />,
  broadcast: (
    <>
      <circle cx="12" cy="12" r="2.4" />
      <path d="M8 8a5.6 5.6 0 0 0 0 8M16 8a5.6 5.6 0 0 1 0 8" />
      <path d="M5.2 5a9.6 9.6 0 0 0 0 14M18.8 5a9.6 9.6 0 0 1 0 14" />
    </>
  ),
};

export function Glyph({ name, size = 24, title, className, style }: GlyphProps) {
  return (
    <svg
      className={className}
      style={style}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      strokeLinejoin="round"
      role={title ? 'img' : undefined}
      aria-label={title}
      aria-hidden={title ? undefined : true}
      focusable="false"
    >
      {PATHS[name]}
    </svg>
  );
}
