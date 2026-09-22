'use client';

import { useEffect, useRef } from 'react';
import { Glyph } from '../Glyph';
import { VoiidPhone } from './VoiidPhone';
import styles from './Home.module.css';

/**
 * The hero's phone: the live prototype, a gentle pointer-driven tilt, and a few
 * glass chips that orbit it. The tilt is written straight to CSS variables on
 * one element — no React state, so moving the mouse never re-renders the phone.
 */
export function HeroPhone() {
  const stageRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    if (!window.matchMedia('(hover: hover) and (pointer: fine)').matches) return;

    let frame = 0;
    const onMove = (e: PointerEvent) => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const x = e.clientX / window.innerWidth - 0.5;
        const y = e.clientY / window.innerHeight - 0.5;
        stage.style.setProperty('--rx', `${(-y * 6).toFixed(2)}deg`);
        stage.style.setProperty('--ry', `${(x * 9).toFixed(2)}deg`);
        stage.style.setProperty('--px', `${(x * 26).toFixed(1)}px`);
        stage.style.setProperty('--py', `${(y * 20).toFixed(1)}px`);
      });
    };
    window.addEventListener('pointermove', onMove, { passive: true });
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener('pointermove', onMove);
    };
  }, []);

  return (
    <div className={styles.heroStage} ref={stageRef}>
      <div className={styles.heroGlow} aria-hidden="true" />
      <div className={styles.heroRing} aria-hidden="true" />

      <div className={styles.heroTilt}>
        <VoiidPhone initial="chats" coach label="Voiid app — interactive preview. Tap anything." />
      </div>

      <div className={`${styles.chip} ${styles.chipA}`} aria-hidden="true">
        <span className={styles.chipIcon} data-tone="teal"><Glyph name="lock" size={15} /></span>
        <span>
          <b>End-to-end encrypted</b>
          <small>Chats · calls · map · moments</small>
        </span>
      </div>
      <div className={`${styles.chip} ${styles.chipB}`} aria-hidden="true">
        <span className={styles.chipIcon} data-tone="blue"><Glyph name="map" size={15} /></span>
        <span>
          <b>Ava is sharing</b>
          <small>Stops by itself in 1h</small>
        </span>
      </div>
      <div className={`${styles.chip} ${styles.chipC}`} aria-hidden="true">
        <span className={styles.chipIcon} data-tone="gold"><Glyph name="games" size={15} /></span>
        <span>
          <b>Hand Cricket</b>
          <small>Your turn to bat</small>
        </span>
      </div>

      <p className={styles.tryIt} aria-hidden="true">
        <svg viewBox="0 0 60 40" width="46" height="30">
          <path d="M4 34 C 18 32, 34 22, 50 8" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          <path d="M40 8 L 51 7 L 49 18" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
        It&rsquo;s live. Tap anything.
      </p>
    </div>
  );
}
