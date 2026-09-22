import type { Metadata } from 'next';
import Link from 'next/link';
import { Glyph } from '../components/Glyph';
import { Reveal } from '../components/Reveal';
import { HeroPhone } from '../components/home/HeroPhone';
import { Story } from '../components/home/Story';
import { SealDemo } from '../components/home/SealDemo';
import styles from '../components/home/Home.module.css';

export const metadata: Metadata = {
  // The layout template appends "— Voiid"; the home title stands alone.
  title: 'Voiid — one encrypted app for chat, calls, the map, clips and games',
  description:
    'Messages, calls, location shares and moments are end-to-end encrypted, and we hold ' +
    'no key. Clips and games are public, and we say so. Built in India, for the world.',
};

/*
 * EVERY CLAIM ON THIS PAGE IS CHECKED AGAINST THE SCHEMA:
 *   - E2EE: messages (006/013), calls (014), location shares (018), moments (017).
 *   - NOT E2EE, deliberately: clips + creator profiles (022, 029), game state (024).
 *   - No store links yet, so the download band says "coming soon", not a fake link.
 * The phone is the iOS DESIGN build (Voiid-Ui), so it shows surfaces that are still
 * being built; the copy labels those "in the design build".
 */

const MARQUEE = ['Chats', 'Group calls', 'Live map', 'Moments', 'Communities', 'Hand Cricket', 'Clips', 'Ghost Mode', 'Voiid AI', 'Voice notes'];

const GALLERY_A = ['chats', 'group_video', 'map', 'moments', 'game_play', 'community_detail'];
const GALLERY_B = ['clips', 'ai_chat', 'convo', 'games', 'map_privacy', 'group_call'];

const ENCRYPTED = [
  'Every message, one-to-one and in groups',
  'Photos, videos, voice notes and files in a chat',
  'Voice and video calls, including group calls',
  'Live location and the pins you drop',
  'Moments you post to a chosen audience',
];
const READABLE = [
  'Clips: the video, caption and thumbnail',
  'Creator profiles, follows, likes and comments',
  'Game moves and scores while a match runs',
  'Who messaged or called whom, and when',
];

const STACK = [
  { name: 'vodozemac', role: 'Double Ratchet · 1:1' },
  { name: 'OpenMLS', role: 'RFC 9420 · groups' },
  { name: 'X-Wing', role: 'ML-KEM-768 · post-quantum' },
  { name: 'AES-256-GCM', role: 'media & files' },
];

export default function HomePage() {
  return (
    <div className={styles.page}>
      {/* ---- hero -------------------------------------------------------- */}
      <section className={styles.hero} aria-labelledby="hero-title">
        <div className={styles.aurora} aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <div className={styles.heroGrid} aria-hidden="true" />

        <div className={styles.heroInner}>
          <div className={styles.heroCopy}>
            <p className={styles.eyebrow}>
              <span className={styles.eyebrowDot} aria-hidden="true" />
              Built in India · for the world
            </p>
            <h1 id="hero-title" className={styles.heroTitle}>
              <span className={styles.line}>Everything you share.</span>
              <span className={`${styles.line} ${styles.shine}`}>Nothing we can read.</span>
            </h1>
            <p className={styles.heroLede}>
              Chats, calls, a live map, moments, clips and games in one app. The private parts
              are end-to-end encrypted and we hold no key. The public parts are labelled public.
            </p>
            <div className={styles.heroActions}>
              <a href="#tour" className={styles.btnPrimary}>
                Take the tour
                <Glyph name="arrow-right" size={15} />
              </a>
              <a href="#download" className={styles.btnGhost}>
                Get Voiid
              </a>
            </div>
            <dl className={styles.heroStats}>
              <div>
                <dt>4</dt>
                <dd>surfaces sealed end to end</dd>
              </div>
              <div>
                <dt>0</dt>
                <dd>keys we hold to your chats</dd>
              </div>
              <div>
                <dt>1</dt>
                <dd>app instead of five</dd>
              </div>
            </dl>
          </div>

          <HeroPhone />
        </div>
      </section>

      {/* ---- marquee ----------------------------------------------------- */}
      <div className={styles.marquee} aria-hidden="true">
        <div className={styles.marqueeTrack}>
          {[...MARQUEE, ...MARQUEE].map((word, i) => (
            <span key={i} className={styles.marqueeItem}>
              {word}
              <i className={styles.marqueeStar}>✦</i>
            </span>
          ))}
        </div>
      </div>

      {/* ---- the tour ---------------------------------------------------- */}
      <section id="tour" className={styles.tour} aria-labelledby="tour-title">
        <Reveal className={styles.sectionHead}>
          <p className={styles.kicker}>The tour</p>
          <h2 id="tour-title" className={styles.h2}>
            One app. <span className={styles.muted}>Seven places to be.</span>
          </h2>
          <p className={styles.lede}>
            Scroll, and the phone follows. Every button you see works, so tap your way in and
            out the way you would in the app.
          </p>
        </Reveal>
        <Story />
      </section>

      {/* ---- sealed ------------------------------------------------------ */}
      <section className={styles.sealed} aria-labelledby="sealed-title">
        <div className={styles.sealedGlow} aria-hidden="true" />
        <Reveal className={styles.sectionHead}>
          <p className={`${styles.kicker} ${styles.kickerDark}`}>How it stays private</p>
          <h2 id="sealed-title" className={`${styles.h2} ${styles.onDark}`}>
            Sealed here. Opened there. <span className={styles.shine}>Noise in between.</span>
          </h2>
          <p className={`${styles.lede} ${styles.onDarkDim}`}>
            Your phone locks each message with the recipient&rsquo;s key before it leaves.
            Our servers pass it along without being able to open it. This is what they see.
          </p>
        </Reveal>

        <Reveal delay={120}>
          <SealDemo />
        </Reveal>

        <Reveal delay={200} className={styles.stack}>
          {STACK.map((s) => (
            <div key={s.name} className={styles.stackChip}>
              <b>{s.name}</b>
              <small>{s.role}</small>
            </div>
          ))}
          <Link href="/encryption" className={styles.stackLink}>
            Every primitive we use <Glyph name="arrow-right" size={13} />
          </Link>
        </Reveal>
      </section>

      {/* ---- the line ---------------------------------------------------- */}
      <section className={styles.line2} aria-labelledby="line-title">
        <Reveal className={styles.sectionHead}>
          <p className={styles.kicker}>No fine print</p>
          <h2 id="line-title" className={styles.h2}>
            &ldquo;Private&rdquo; on every screen tells you nothing.{' '}
            <span className={styles.muted}>So here&rsquo;s the line.</span>
          </h2>
        </Reveal>
        <div className={styles.ledger}>
          <Reveal className={`${styles.ledgerCard} ${styles.ledgerSealed}`}>
            <span className={styles.ledgerIcon}><Glyph name="lock" size={20} /></span>
            <h3>We can&rsquo;t read</h3>
            <ul>
              {ENCRYPTED.map((t) => (
                <li key={t}>
                  <Glyph name="check" size={15} />
                  {t}
                </li>
              ))}
            </ul>
          </Reveal>
          <Reveal delay={120} className={`${styles.ledgerCard} ${styles.ledgerOpen}`}>
            <span className={styles.ledgerIcon}><Glyph name="broadcast" size={20} /></span>
            <h3>We can read</h3>
            <ul>
              {READABLE.map((t) => (
                <li key={t}>
                  <Glyph name="eye-off" size={15} />
                  {t}
                </li>
              ))}
            </ul>
            <p className={styles.ledgerNote}>
              A broadcast can&rsquo;t be encrypted to an audience that hasn&rsquo;t signed up yet, and
              a referee has to see the moves. <Link href="/privacy">Read the privacy page</Link>
            </p>
          </Reveal>
        </div>
      </section>

      {/* ---- gallery ----------------------------------------------------- */}
      <section className={styles.gallery} aria-labelledby="gallery-title">
        <Reveal className={styles.sectionHead}>
          <p className={styles.kicker}>Screens</p>
          <h2 id="gallery-title" className={styles.h2}>
            Designed down to <span className={styles.muted}>the last pixel.</span>
          </h2>
        </Reveal>
        <div className={styles.galleryRows} aria-hidden="true">
          {[GALLERY_A, GALLERY_B].map((row, r) => (
            <div key={r} className={styles.galleryRow} data-reverse={r === 1 ? 'true' : undefined}>
              <div className={styles.galleryTrack}>
                {[...row, ...row].map((id, i) => (
                  <figure key={i} className={styles.galleryShot}>
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={`/app/${id}.webp`} alt="" loading="lazy" decoding="async" width={603} height={1311} />
                  </figure>
                ))}
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* ---- download ---------------------------------------------------- */}
      <section id="download" className={styles.download} aria-labelledby="download-title">
        <div className={styles.aurora} aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <div className={styles.downloadInner}>
          <Reveal className={styles.downloadCopy}>
            <p className={`${styles.kicker} ${styles.kickerDark}`}>Coming soon</p>
            <h2 id="download-title" className={`${styles.h2} ${styles.onDark} ${styles.downloadTitle}`}>
              Your people. <span className={styles.shine}>Your keys.</span>
            </h2>
            <p className={`${styles.lede} ${styles.onDarkDim}`}>
              Voiid is on its way to the App Store and Google Play. The links will go here, and
              only here, the day they&rsquo;re real.
            </p>
            <div className={styles.stores}>
              <span className={styles.store} aria-disabled="true">
                <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true">
                  <path fill="currentColor" d="M16.4 12.6c0-2.6 2.1-3.8 2.2-3.9-1.2-1.8-3.1-2-3.7-2-1.6-.2-3.1.9-3.9.9-.8 0-2-.9-3.4-.9-1.7 0-3.3 1-4.2 2.6-1.8 3.1-.5 7.7 1.3 10.2.9 1.2 1.9 2.6 3.2 2.6 1.3-.1 1.8-.8 3.3-.8 1.6 0 2 .8 3.4.8 1.4 0 2.3-1.3 3.1-2.5 1-1.4 1.4-2.8 1.4-2.9-.1 0-2.7-1-2.7-4.1zM13.9 5c.7-.9 1.2-2 1-3.2-1 0-2.3.7-3 1.6-.7.8-1.2 2-1.1 3.1 1.2.1 2.3-.6 3.1-1.5z" />
                </svg>
                <span>
                  <small>Soon on the</small>
                  App Store
                </span>
              </span>
              <span className={styles.store} aria-disabled="true">
                <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
                  <path fill="#34d399" d="M3.6 2.3l10.3 10.3-10.3 10.1c-.4-.2-.6-.6-.6-1.1V3.4c0-.5.2-.9.6-1.1z" />
                  <path fill="#60a5fa" d="M17.3 9.2l-3.4 3.4 3.4 3.3 3.9-2.2c1.1-.6 1.1-1.7 0-2.3z" />
                  <path fill="#fbbf24" d="M13.9 12.6l3.4-3.4L5.1 2.2c-.5-.3-1-.3-1.5.1z" />
                  <path fill="#f87171" d="M13.9 12.6L3.6 22.7c.5.3 1 .3 1.5 0l12.2-6.8z" />
                </svg>
                <span>
                  <small>Soon on</small>
                  Google Play
                </span>
              </span>
            </div>
          </Reveal>
          <Reveal delay={150} className={styles.downloadArt}>
            <div className={styles.fan} aria-hidden="true">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src="/app/map.webp" alt="" loading="lazy" />
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src="/app/chats.webp" alt="" loading="lazy" />
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src="/app/games.webp" alt="" loading="lazy" />
            </div>
          </Reveal>
        </div>
      </section>
    </div>
  );
}
