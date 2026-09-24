import { useId } from 'react';

//
// The Voiid mark — the same Peacock V the apps and voiid.app ship (see
// apps/web/public/voiid-logomark.svg): three rounded bars, the back one shaded from
// #0F464A to the brand Tide #13828C as the depth cue.
//
// Drawn inline rather than loaded as an image so it arrives with the first paint of the
// shell. The gradient id is per instance, so two marks on one page cannot collide.
//
export function BrandMark({ size = 36 }: { size?: number }) {
  const id = `voiid-back-${useId().replace(/:/g, '')}`;
  return (
    <svg width={size * 1.1} height={size} viewBox="0 0 88 80" aria-hidden>
      <defs>
        <linearGradient id={id} gradientUnits="userSpaceOnUse" x1="10.8412" y1="0" x2="10.8412" y2="79.5639">
          <stop offset="0" stopColor="#0F464A" />
          <stop offset="1" stopColor="#13828C" />
        </linearGradient>
      </defs>
      <rect x="58.5586" y="68.9043" width="21.6824" height="79.5639" rx="10.8412" transform="rotate(150 58.5586 68.9043)" fill={`url(#${id})`} />
      <rect x="44.6035" y="42.1816" width="20.2613" height="30.6242" rx="10.1307" transform="rotate(30 44.6035 42.1816)" fill="#13828C" />
      <rect x="68.9043" y="0" width="21.6824" height="79.625" rx="10.8412" transform="rotate(30 68.9043 0)" fill="#13828C" />
    </svg>
  );
}
