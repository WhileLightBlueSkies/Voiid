import './globals.css';
import type { ReactNode } from 'react';
import { Inter, JetBrains_Mono } from 'next/font/google';

//
// Inter, self-hosted through next/font rather than a <link> to Google.
//
// Two reasons beyond speed. The font file is served from our own origin, so the panel makes
// no third-party request on load — an admin console phoning out to a CDN on every page view
// is a needless tell about who is using it and when. And next/font emits the size-adjust
// metrics for the fallback, so the swap from system font to Inter does not reflow the page:
// on a dense table, a reflow after paint moves every row under the cursor.
//
const inter = Inter({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-sans',
  // Only the weights actually used. A console needs four, not nine, and each unused weight
  // is a file the browser may fetch.
  weight: ['400', '500', '600', '700'],
});

//
// JetBrains Mono for figures and identifiers.
//
// The tabular numerals are the point: in a column of counts, a proportional font makes 111
// narrower than 999, so the digits fail to line up and the eye cannot compare rows by
// length. Its zero is also slashed, which matters where the console prints ids and hashes
// that someone will read aloud or type back.
//
const mono = JetBrains_Mono({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-mono',
  weight: ['400', '500', '600'],
});

export const metadata = {
  title: 'Voiid Admin',
  // noindex: this panel must never appear in a search result. It is not a secret in itself
  // — the login gates everything — but an indexed admin URL is free reconnaissance.
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
