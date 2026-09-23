import './globals.css';
import type { ReactNode } from 'react';
import { Plus_Jakarta_Sans, Geist, Geist_Mono } from 'next/font/google';

//
// Plus Jakarta Sans, self-hosted through next/font rather than a <link> to Google. A
// geometric face with open counters: large figures read as instruments, and it stays
// legible at the 12–13px a dense table runs at.
//
// Two reasons beyond speed. The font file is served from our own origin, so the panel makes
// no third-party request on load — an admin console phoning out to a CDN on every page view
// is a needless tell about who is using it and when. And next/font emits the size-adjust
// metrics for the fallback, so the swap from system font to the webfont does not reflow the page:
// on a dense table, a reflow after paint moves every row under the cursor.
//
const sans = Plus_Jakarta_Sans({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-sans',
  // Only the weights actually used. A console needs four, not nine, and each unused weight
  // is a file the browser may fetch.
  weight: ['400', '500', '600', '700'],
});

//
// Geist for FIGURES. The text face is built for words; its digits are wide and uneven, and a
// dashboard's headline is a number. Geist's numerals are narrow, even and crisp at 48px as
// well as 12px, so every readout on the console uses it (the .num class).
//
const num = Geist({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-num',
  weight: ['400', '500', '600'],
});

//
// Geist Mono for identifiers and table counts: the same drawing as the figures, fixed-width,
// so a column of counts lines up and an id reads unambiguously.
//
const mono = Geist_Mono({
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
    // suppressHydrationWarning covers THIS element's attributes only, not its children.
    // Browser extensions (Storylane, Grammarly, dark-mode tools) stamp classes onto <html>
    // before React loads, which is noise rather than a bug in the console.
    <html lang="en" className={`${sans.variable} ${num.variable} ${mono.variable}`} suppressHydrationWarning>
      <body>{children}</body>
    </html>
  );
}
