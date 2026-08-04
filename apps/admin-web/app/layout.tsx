import './globals.css';
import type { ReactNode } from 'react';

export const metadata = {
  title: 'Voiid Admin',
  // noindex: this panel must never appear in a search result. It is not a secret in itself
  // — the login gates everything — but an indexed admin URL is free reconnaissance.
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
