import './globals.css';
import type { Metadata, Viewport } from 'next';
import type { ReactNode } from 'react';
import { SiteHeader } from '../components/SiteHeader';
import { SiteFooter } from '../components/SiteFooter';
import { ThemeScript } from '../components/ThemeScript';
import { absoluteUrl, SITE_DESCRIPTION, SITE_NAME, SITE_URL } from '../lib/site';

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: 'Private messaging, calls and more — Voiid',
    template: '%s — Voiid',
  },
  description: SITE_DESCRIPTION,
  applicationName: SITE_NAME,
  alternates: { canonical: '/' },
  // No verification tokens, no analytics, no third-party script. The site collects
  // nothing, so there is nothing here that needs a consent banner.
  robots: { index: true, follow: true },
  openGraph: {
    title: 'Private messaging, calls and more — Voiid',
    description: SITE_DESCRIPTION,
    siteName: SITE_NAME,
    type: 'website',
    url: '/',
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Private messaging, calls and more — Voiid',
    description: SITE_DESCRIPTION,
  },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  // Light is the first-visit default. ThemeScript and ThemeToggle keep this browser
  // chrome value in sync when an explicit dark choice is restored or changed.
  themeColor: '#fbfcfc',
};

export default function RootLayout({ children }: { children: ReactNode }) {
  const structuredData = {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'Organization',
        '@id': `${SITE_URL}/#organization`,
        name: SITE_NAME,
        url: SITE_URL,
        logo: absoluteUrl('/voiid-logomark.svg'),
      },
      {
        '@type': 'SoftwareApplication',
        '@id': `${SITE_URL}/#app`,
        name: SITE_NAME,
        applicationCategory: 'SocialNetworkingApplication',
        operatingSystem: 'iOS, Android',
        description: SITE_DESCRIPTION,
        url: SITE_URL,
        author: { '@id': `${SITE_URL}/#organization` },
      },
    ],
  };

  return (
    <html lang="en" data-theme="light" suppressHydrationWarning>
      <head>
        <ThemeScript />
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(structuredData) }}
        />
      </head>
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
