'use client';

import { useEffect, useRef, useState } from 'react';
import { Glyph } from '../Glyph';
import styles from './Home.module.css';

/**
 * Sealed here, opened there. One message makes the trip on a loop:
 *   typed → sealed on the sender's phone → relayed as ciphertext → opened on the
 *   recipient's phone.
 * The middle card is the point: all the server ever holds is noise.
 */

const MESSAGES = ['Pinned! See you there ☕', 'Landed. Sharing my location 📍', 'Happy birthday!! 🎂 call me'];
const GLYPHS = 'ABCDEFabcdef0123456789+/=xZqK';

const STAGES = ['typed', 'sealed', 'relay', 'opened'] as const;
type Stage = (typeof STAGES)[number];
const HOLD: Record<Stage, number> = { typed: 1500, sealed: 1100, relay: 1700, opened: 2300 };

function noise(n: number) {
  let s = '';
  for (let i = 0; i < n; i++) s += GLYPHS[Math.floor(Math.random() * GLYPHS.length)];
  return s;
}

export function SealDemo() {
  const [stage, setStage] = useState<Stage>('typed');
  const [index, setIndex] = useState(0);
  const [cipher, setCipher] = useState('');
  const rootRef = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);
  const message = MESSAGES[index];

  // Only run while on screen.
  useEffect(() => {
    const el = rootRef.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setVisible(!!e?.isIntersecting), { threshold: 0.25 });
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => {
    if (!visible) return;
    const t = window.setTimeout(() => {
      const next = STAGES[(STAGES.indexOf(stage) + 1) % STAGES.length];
      if (next === 'typed') setIndex((i) => (i + 1) % MESSAGES.length);
      setStage(next);
    }, HOLD[stage]);
    return () => window.clearTimeout(t);
  }, [stage, visible]);

  // The ciphertext keeps churning, the way it looks to anyone without the key.
  useEffect(() => {
    if (!visible) return;
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    setCipher(noise(28));
    if (reduced) return;
    const t = window.setInterval(() => setCipher(noise(28)), 90);
    return () => window.clearInterval(t);
  }, [visible, index]);

  const sealedOrLater = stage !== 'typed';

  return (
    <div className={styles.seal} ref={rootRef} data-stage={stage}>
      <div className={styles.sealNode}>
        <span className={styles.sealWho}>Your phone</span>
        <div className={styles.sealBubble} data-side="sent" data-sealed={sealedOrLater ? 'true' : undefined}>
          <span className={styles.sealPlain}>{message}</span>
          <span className={styles.sealCipher} aria-hidden="true">{cipher}</span>
        </div>
        <span className={styles.sealStep} data-on={stage === 'sealed' ? 'true' : undefined}>
          <Glyph name="lock" size={13} /> Sealed with their key
        </span>
      </div>

      <div className={styles.sealWire} aria-hidden="true">
        <span className={styles.sealPacket} />
      </div>

      <div className={`${styles.sealNode} ${styles.sealServer}`}>
        <span className={styles.sealWho}>Voiid servers</span>
        <div className={styles.sealVault}>
          <code aria-label="Ciphertext">{cipher}</code>
          <code aria-hidden="true">{cipher.split('').reverse().join('')}</code>
        </div>
        <span className={styles.sealStep} data-on={stage === 'relay' ? 'true' : undefined}>
          <Glyph name="eye-off" size={13} /> Relayed, never read
        </span>
      </div>

      <div className={styles.sealWire} aria-hidden="true" data-second="true">
        <span className={styles.sealPacket} />
      </div>

      <div className={styles.sealNode}>
        <span className={styles.sealWho}>Ananya&rsquo;s phone</span>
        <div className={styles.sealBubble} data-side="received" data-shown={stage === 'opened' ? 'true' : undefined}>
          <span className={styles.sealPlain}>{message}</span>
        </div>
        <span className={styles.sealStep} data-on={stage === 'opened' ? 'true' : undefined}>
          <Glyph name="key" size={13} /> Opened on her device
        </span>
      </div>
    </div>
  );
}
