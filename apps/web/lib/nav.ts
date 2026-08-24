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
    href: '/encryption',
    label: 'Encryption',
    blurb: 'Every primitive we encrypt with — vetted libraries and our own glue, named.',
    hue: 'privacy',
    privacy: 'e2ee',
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

/**
 * What the HEADER shows.
 *
 * Not all of NAV. Eight top-level links is a sitemap, not a navigation bar — the
 * eye cannot rank eight peers, so nothing reads as important and the header stops
 * looking like a product's. WhatsApp and Arattai both run three or four plus one
 * call to action, which is the shape this follows.
 *
 * The five surfaces collapse into a "Features" group; Encryption and Privacy stay
 * top-level because they are the site's actual argument, not a feature.
 */
export const HEADER_NAV: NavItem[] = NAV.filter((item) =>
  ['/messaging', '/encryption', '/privacy'].includes(item.href),
);

/** The five product surfaces, for the header's Features menu and the home grid. */
export const SURFACES: NavItem[] = NAV.filter((item) =>
  ['/messaging', '/calls', '/map', '/clips', '/games'].includes(item.href),
);
