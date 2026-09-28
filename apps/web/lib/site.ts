export const SITE_NAME = 'Voiid';
export const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://voiid.app';
export const SITE_DESCRIPTION =
  'Private messaging, encrypted calls, live location, moments, clips and games in one beautifully connected app.';

export function absoluteUrl(path: string): string {
  return new URL(path, `${SITE_URL.replace(/\/$/, '')}/`).toString();
}
