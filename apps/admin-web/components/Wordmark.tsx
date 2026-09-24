//
// "Voiid" as TYPE, exactly as iOS (DesignSystem/BrandMark.swift → BrandWordmark) and voiid.app
// (components/Wordmark.tsx) set it: SF Pro Rounded Bold, capital V, and both i's DOTLESS
// (U+0131) with the dots drawn as Tide circles. A glyph's tittle cannot be recoloured, so the
// dots are drawn — they are the only accent in the word. Sizes are in em so it scales cleanly.
//
export function Wordmark({ size = 20, className = '' }: { size?: number; className?: string }) {
  return (
    <span className={`wordmark ${className}`} style={{ fontSize: size }}>
      <span aria-hidden="true" className="wordmark-glyphs">
        Vo<span className="wordmark-stem"><span className="wordmark-dot" />ı</span><span className="wordmark-stem"><span className="wordmark-dot" />ı</span>d
      </span>
      <span className="sr-only">Voiid</span>
    </span>
  );
}
