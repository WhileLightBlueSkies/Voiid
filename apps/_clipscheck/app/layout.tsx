import './globals.css';
import type { Metadata, Viewport } from 'next';
import type { ReactNode } from 'react';
import { SiteHeader } from '../components/SiteHeader';
import { SiteFooter } from '../components/SiteFooter';

export const metadata: Metadata = {
  title: {
    default: 'Voiid — one encrypted app for chat, calls, the map, clips and games',
    template: '%s — Voiid',
  },
  description:
    'Voiid puts messages, calls, location sharing and moments under end-to-end ' +
    'encryption, and says plainly which parts — clips and games — are not. Built in India.',
  applicationName: 'Voiid',
  // No verification tokens, no analytics, no third-party script. The site collects
  // nothing, so there is nothing here that needs a consent banner.
  robots: { index: true, follow: true },
  openGraph: {
    title: 'Voiid — one encrypted app for chat, calls, the map, clips and games',
    description:
      'End-to-end encrypted messages, calls, location and moments. Clips and games are ' +
      'public, and we say so. Built in India, for the world.',
    siteName: 'Voiid',
    type: 'website',
  },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  // Both themes are designed; tell the browser so form controls and scrollbars follow.
  // These two are the ONLY raw hexes outside globals.css that a page may contain: a
  // <meta name="theme-color"> is read by the browser chrome before any stylesheet is
  // parsed, so var() is not available. They must stay equal to --color-background.
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#f1eef5' },
    { media: '(prefers-color-scheme: dark)', color: '#0d0b14' },
  ],
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <a className="skipLink" href="#main">
          Skip to content
        </a>
        <SiteHeader />
        <main id="main">{children}</main>
        <SiteFooter />
      </body>
    </html>
  );
}
