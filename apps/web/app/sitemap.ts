import type { MetadataRoute } from 'next';

import { absoluteUrl } from '@/lib/site';

export const dynamic = 'force-static';

const routes = [
  { path: '/', priority: 1, changeFrequency: 'weekly' },
  { path: '/messaging/', priority: 0.9, changeFrequency: 'monthly' },
  { path: '/calls/', priority: 0.9, changeFrequency: 'monthly' },
  { path: '/map/', priority: 0.9, changeFrequency: 'monthly' },
  { path: '/clips/', priority: 0.8, changeFrequency: 'monthly' },
  { path: '/games/', priority: 0.8, changeFrequency: 'monthly' },
  { path: '/encryption/', priority: 0.8, changeFrequency: 'monthly' },
  { path: '/privacy/', priority: 0.8, changeFrequency: 'monthly' },
] as const;

export default function sitemap(): MetadataRoute.Sitemap {
  return routes.map(({ path, priority, changeFrequency }) => ({
    url: absoluteUrl(path),
    priority,
    changeFrequency,
  }));
}
