import type { Metadata } from 'next';

export function buildPageMetadata({
  title,
  description,
  path,
  robots,
}: {
  title: string;
  description: string;
  path: string;
  robots?: Metadata['robots'];
}): Metadata {
  const fullTitle = `${title} — Voiid`;
  return {
    title,
    description,
    alternates: { canonical: path },
    robots,
    openGraph: { title: fullTitle, description, url: path, type: 'website' },
    twitter: { card: 'summary_large_image', title: fullTitle, description },
  };
}
