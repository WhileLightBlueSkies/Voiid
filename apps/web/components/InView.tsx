'use client';

import { useEffect, useRef, type ReactNode } from 'react';

/**
 * Marks a block with `data-in` the first time it scrolls into view, and nothing else.
 *
 * Unlike <Reveal>, it does not animate the block itself: the page's own stylesheet
 * keys whatever choreography it wants off `[data-in]` (staggered rows, a redaction
 * bar peeling off each list item). Reduced-motion users get `data-in` immediately.
 */
export function InView({ children, className }: { children: ReactNode; className?: string }) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      el.dataset.in = '';
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting) {
          el.dataset.in = '';
          io.disconnect();
        }
      },
      { threshold: 0.2 },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  return (
    <div ref={ref} className={className}>
      {children}
    </div>
  );
}
