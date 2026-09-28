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
  | 'broadcast'
  /* Added for the interactive tour: a simulated app needs the same small verbs a
   * real one does — go back, send, search, like, play, mute, hang up. */
  | 'chevron-left'
  | 'chevron-right'
  | 'send'
  | 'search'
  | 'plus'
  | 'more'
  | 'heart'
  | 'play'
  | 'pause'
  | 'pin'
  | 'mic'
  | 'mic-off'
  | 'video'
  | 'speaker'
  | 'user'
  | 'settings'
  | 'image'
  | 'comment'
  | 'refresh'
  | 'close';

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
  /**
   * Paint the glyph solid. Only meaningful for the closed shapes (`heart`,
   * `play`), where filled/outline is the state itself — a liked clip, a playing
   * one — rather than decoration.
   */
  filled?: boolean;
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
  'chevron-left': <path d="M15 5.5 8.5 12l6.5 6.5" />,
  'chevron-right': <path d="M9 5.5 15.5 12 9 18.5" />,
  send: <path d="M20.4 3.6 3.9 9.8a.6.6 0 0 0 0 1.1l6.9 2.3 2.3 6.9a.6.6 0 0 0 1.1 0l6.2-16.5ZM10.8 13.2l9.6-9.6" />,
  search: (
    <>
      <circle cx="10.8" cy="10.8" r="6.2" />
      <path d="m15.4 15.4 4.2 4.2" />
    </>
  ),
  plus: <path d="M12 5.2v13.6M5.2 12h13.6" />,
  more: (
    <>
      <circle cx="5.4" cy="12" r="1.15" fill="currentColor" stroke="none" />
      <circle cx="12" cy="12" r="1.15" fill="currentColor" stroke="none" />
      <circle cx="18.6" cy="12" r="1.15" fill="currentColor" stroke="none" />
    </>
  ),
  heart: (
    <path d="M12 20.2c-.4 0-.8-.15-1.1-.4C6.6 16.2 3.4 13.4 3.4 9.8a4.6 4.6 0 0 1 8.6-2.4 4.6 4.6 0 0 1 8.6 2.4c0 3.6-3.2 6.4-7.5 10a1.7 1.7 0 0 1-1.1.4Z" />
  ),
  play: <path d="M8 5.6 18.4 12 8 18.4V5.6Z" />,
  pause: <path d="M9 5.4v13.2M15 5.4v13.2" />,
  pin: (
    <>
      <path d="M12 21.2s6.4-6 6.4-10.6a6.4 6.4 0 1 0-12.8 0C5.6 15.2 12 21.2 12 21.2Z" />
      <circle cx="12" cy="10.4" r="2.4" />
    </>
  ),
  mic: (
    <>
      <rect x="9.2" y="3" width="5.6" height="10.6" rx="2.8" />
      <path d="M5.8 11.4a6.2 6.2 0 0 0 12.4 0M12 17.6V21" />
    </>
  ),
  'mic-off': (
    <>
      <path d="M14.8 5.6v-.2a2.8 2.8 0 0 0-5.6.2v4.8M9.2 13.2a2.8 2.8 0 0 0 4.4 1.3" />
      <path d="M5.8 11.4a6.2 6.2 0 0 0 9.5 5.3M18.2 11.4v.6M12 17.6V21M4 4l16 16" />
    </>
  ),
  video: (
    <>
      <rect x="2.8" y="6" width="12.6" height="12" rx="3" />
      <path d="m15.4 13 5.8 3.2V7.8L15.4 11v2Z" />
    </>
  ),
  speaker: (
    <>
      <path d="M11.6 4.6 6.8 8.6H3.6v6.8h3.2l4.8 4V4.6Z" />
      <path d="M15.4 9.2a3.8 3.8 0 0 1 0 5.6M18.2 6.4a7.6 7.6 0 0 1 0 11.2" />
    </>
  ),
  user: (
    <>
      <circle cx="12" cy="8.4" r="3.8" />
      <path d="M4.8 20.2a7.2 7.2 0 0 1 14.4 0" />
    </>
  ),
  settings: (
    <>
      <circle cx="12" cy="12" r="2.8" />
      <path d="M19.2 14.4a1.6 1.6 0 0 0 .32 1.76l.06.06a1.94 1.94 0 1 1-2.74 2.74l-.06-.06a1.6 1.6 0 0 0-1.76-.32 1.6 1.6 0 0 0-.97 1.46v.16a1.94 1.94 0 0 1-3.88 0v-.08a1.6 1.6 0 0 0-1.05-1.46 1.6 1.6 0 0 0-1.76.32l-.06.06a1.94 1.94 0 1 1-2.74-2.74l.06-.06a1.6 1.6 0 0 0 .32-1.76 1.6 1.6 0 0 0-1.46-.97H3.3a1.94 1.94 0 0 1 0-3.88h.08a1.6 1.6 0 0 0 1.46-1.05 1.6 1.6 0 0 0-.32-1.76l-.06-.06A1.94 1.94 0 1 1 7.2 4.06l.06.06a1.6 1.6 0 0 0 1.76.32h.08a1.6 1.6 0 0 0 .97-1.46V2.8a1.94 1.94 0 0 1 3.88 0v.08a1.6 1.6 0 0 0 .97 1.46 1.6 1.6 0 0 0 1.76-.32l.06-.06a1.94 1.94 0 1 1 2.74 2.74l-.06.06a1.6 1.6 0 0 0-.32 1.76v.08a1.6 1.6 0 0 0 1.46.97h.16a1.94 1.94 0 0 1 0 3.88h-.08a1.6 1.6 0 0 0-1.46.97Z" />
    </>
  ),
  image: (
    <>
      <rect x="3.4" y="4.6" width="17.2" height="14.8" rx="3.2" />
      <circle cx="9" cy="10" r="1.6" />
      <path d="m4.2 17.4 4.6-4.4a2 2 0 0 1 2.7 0l5.4 5" />
    </>
  ),
  comment: (
    <path d="M20.4 11.6a7.6 7.6 0 0 1-8.2 7.6 8.6 8.6 0 0 1-2.6-.4l-4.6 1.4 1.4-4.2a7.4 7.4 0 0 1-1-3.8 7.6 7.6 0 0 1 7.6-7.6h.4a7.6 7.6 0 0 1 7 7Z" />
  ),
  refresh: (
    <>
      <path d="M20 12a8 8 0 1 1-2.6-5.9" />
      <path d="M20.4 4.2v4.6h-4.6" />
    </>
  ),
  close: <path d="M6 6l12 12M18 6 6 18" />,
};

export function Glyph({ name, size = 24, title, className, style, filled }: GlyphProps) {
  return (
    <svg
      className={className}
      style={style}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={filled ? 'currentColor' : 'none'}
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
