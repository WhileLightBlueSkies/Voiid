import type { DomainHue } from './hues';

export type NavItem = {
  href: string;
  label: string;
  /** One-line summary — reused by the home feature grid and the footer. */
  blurb: string;
  hue: DomainHue;
  /** Whether the server can read this surface. Drives <E2EEBadge>. */
  privacy: 'e2ee' | 'public' | 'refereed';
};

/**
 * The site map, in nav order. Single source — the header, the footer and the home
 * feature grid all read this, so a page is added in exactly one place.
 *
 * Communities is deliberately absent: the plan (docs/research/04_communities_plan.md)
 * has not shipped, and this site does not advertise unbuilt features.
 */
export const NAV: NavItem[] = [
  {
    href: '/',
    label: 'Home',
    blurb: 'One encrypted app for the way you actually talk.',
    hue: 'chat',
    privacy: 'e2ee',
  },
  {
    href: '/messaging',
    label: 'Messaging',
    blurb: 'End-to-end encrypted chats and groups, with a reachability model you control.',
    hue: 'chat',
    privacy: 'e2ee',
  },
  {
    href: '/calls',
    label: 'Calls',
    blurb: 'One-to-one and group voice and video, encrypted end to end.',
    hue: 'calls',
    privacy: 'e2ee',
  },
  {
    href: '/map',
    label: 'Map',
    blurb: 'See the friends who chose to share, at the accuracy they chose.',
    hue: 'map',
    privacy: 'e2ee',
  },
  {
    href: '/clips',
    label: 'Clips',
    blurb: 'Short public video, creator profiles and follows — public, and we say so.',
    hue: 'clips',
    privacy: 'public',
  },
  {
    href: '/games',
    label: 'Games',
    blurb: 'Play a friend inside the chat. The server referees the match.',
    hue: 'games',
    privacy: 'refereed',
  },
  {
    href: '/privacy',
    label: 'Privacy',
    blurb: 'What is encrypted, what is not, and exactly what we can see.',
    hue: 'privacy',
    privacy: 'e2ee',
  },
];

/** Everything except Home — the feature grid and the footer's product column. */
export const FEATURE_NAV = NAV.filter((item) => item.href !== '/');
