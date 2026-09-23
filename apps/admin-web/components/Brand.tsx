//
// The console's mark: a mint lozenge carrying a black four-point spark.
//
// Drawn inline rather than loaded as an image so it arrives with the first paint of the
// shell and inherits no extra request — the sidebar should never flash an empty slot.
//
export function BrandMark({ size = 36 }: { size?: number }) {
  return (
    <svg width={size * 1.45} height={size} viewBox="0 0 44 30" aria-hidden>
      <rect x="0" y="0" width="44" height="30" rx="15" fill="var(--lime)" />
      <path
        d="M24 3.5c.9 6.4 3.3 9.4 10 10.5-6.7 1.1-9.1 4.1-10 10.5-.9-6.4-3.3-9.4-10-10.5 6.7-1.1 9.1-4.1 10-10.5Z"
        fill="#0f1110"
        transform="rotate(-18 24 14)"
      />
    </svg>
  );
}
