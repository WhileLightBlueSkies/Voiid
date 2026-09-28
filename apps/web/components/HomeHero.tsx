import Link from 'next/link';
import { Glyph } from './Glyph';
import { DeviceScene } from './DeviceScene';
import { AppSandboxLauncher } from './AppSandbox/AppSandboxLauncher';
import styles from './HomeHero.module.css';

export function HomeHero() {
  return (
    <section className={styles.hero} aria-labelledby="home-title">
      <div className={styles.glow} aria-hidden="true" />
      <div className={styles.inner}>
        <div className={styles.copy}>
          <p className={styles.kicker}><Glyph name="shield" size={15} /> Private where it matters</p>
          <h1 id="home-title">Stay close. Keep control.</h1>
          <p className={styles.lede}>
            Chat, call, share, watch and play in one beautifully connected place—built
            around your people, with clear privacy on every surface.
          </p>
          <div className={styles.actions}>
            <AppSandboxLauncher className={styles.primary} />
            <Link href="#features" className={styles.secondary}>Explore features</Link>
          </div>
          <div className={styles.proof}>
            <span><Glyph name="lock" size={14} /> End-to-end encrypted chats &amp; calls</span>
            <span><Glyph name="globe" size={14} /> Built in India</span>
          </div>
        </div>
        <DeviceScene />
      </div>
    </section>
  );
}
