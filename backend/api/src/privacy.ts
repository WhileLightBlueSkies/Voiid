export const PRIVACY_VISIBILITIES = ['everyone', 'contacts', 'nobody'] as const;
export type PrivacyVisibility = (typeof PRIVACY_VISIBILITIES)[number];

export function isPrivacyVisibility(value: unknown): value is PrivacyVisibility {
  return typeof value === 'string' &&
    (PRIVACY_VISIBILITIES as readonly string[]).includes(value);
}

/** Audience choices are account settings, disclosed only to their owner. */
export function ownerPrivacyPreferences(viewerId: string, targetId: string, settings: {
  last_seen_privacy: string;
  photo_privacy: string;
  about_privacy: string;
}) {
  if (viewerId !== targetId) return {};
  return {
    last_seen_privacy: settings.last_seen_privacy,
    photo_privacy: settings.photo_privacy,
    about_privacy: settings.about_privacy,
  };
}
