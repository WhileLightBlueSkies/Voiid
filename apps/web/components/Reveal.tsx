'use client';

import { useEffect, useRef, type CSSProperties, type ReactNode } from 'react';
import styles from './Reveal.module.css';

/**
 * Scroll-reveal wrapper.
 *
 * Children start shifted down and transparent; when the block enters the
 * viewport they settle in with the spring curve. One IntersectionObserver per
 * instance, disconnected after the first reveal — after that the element is a
 * plain div and costs nothing.
 *
 * `delay` staggers siblings (e.g. grid cards at i * 70ms). Reduced-motion users
 * get the final state immediately with no observer at all.
 */
export function Reveal({
  children,
  delay = 0,
  className,
}: {
  children: ReactNode;
  /** Stagger offset in ms. */
  delay?: number;
  className?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      el.classList.add(styles.in);
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting) {
          el.classList.add(styles.in);
          io.disconnect();
        }
      },
      { threshold: 0.12, rootMargin: '0px 0px -6% 0px' },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  return (
    <div
      ref={ref}
      className={[styles.reveal, className].filter(Boolean).join(' ')}
      style={{ '--reveal-delay': `${delay}ms` } as CSSProperties}
    >
      {children}
    </div>
  );
}
