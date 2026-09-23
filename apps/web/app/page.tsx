import type { Metadata } from 'next';
import { DownloadSection } from '../components/DownloadSection';
import { EncryptionJourney } from '../components/EncryptionJourney';
import { FeatureRail } from '../components/FeatureRail';
import { HomeHero } from '../components/HomeHero';
import { PrivacyBoundary } from '../components/PrivacyBoundary';
import styles from './page.module.css';

export const metadata: Metadata = {
  title: 'Private messaging, calls and more — Voiid',
  description:
    'Chat, call, share live location, post moments, watch clips and play games in one privacy-first app built in India.',
  alternates: { canonical: '/' },
  openGraph: {
    title: 'Private messaging, calls and more — Voiid',
    description:
      'Chat, call, share live location, post moments, watch clips and play games in one privacy-first app.',
    url: '/',
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Private messaging, calls and more — Voiid',
    description:
      'Chat, call, share live location, post moments, watch clips and play games in one privacy-first app.',
  },
};

const ENCRYPTED = [
  'Messages, groups and chat attachments',
  'One-to-one and group voice or video calls',
  'Live location shares and dropped pins',
  'Moments shared with a chosen audience',
];

const SERVER_READABLE = [
  'Public clips, captions, follows and comments',
  'Game moves, scores and match results',
  'Delivery and call metadata needed to run the service',
];

/* Three claims this site can stand behind, each one checkable against the app or
 * against this page's own source. Nothing aspirational lives here. */
const ORIGIN_POINTS = [
  {
    title: 'One app, not six',
    body: 'Chats, calls, the map, moments, clips and games share one account, one contact list and one set of settings.',
  },
  {
    title: 'One boundary, stated once',
    body: 'Encrypted where it belongs, plainly marked where it cannot be — on the feature page, in the app, and on the card above.',
  },
  {
    title: 'Nothing watching you here',
    body: 'This website loads no analytics, no trackers and no third-party fonts. The tour runs entirely in your browser.',
  },
];

export default function HomePage() {
  return (
    <>
      <HomeHero />
      <FeatureRail />
      <EncryptionJourney />
      <PrivacyBoundary encrypted={ENCRYPTED} serverReadable={SERVER_READABLE} />
      <section className={styles.origin} aria-labelledby="origin-title">
        <span className={styles.originLine}>Built in India · made for everywhere</span>
        <h2 id="origin-title">Connection without the clutter.</h2>
        <p className={styles.originLede}>
          Voiid brings conversations, shared moments, discovery and play together—then
          makes the privacy boundary clear enough to understand at a glance.
        </p>
        <ul className={styles.originPoints}>
          {ORIGIN_POINTS.map((point) => (
            <li key={point.title}>
              <h3>{point.title}</h3>
              <p>{point.body}</p>
            </li>
          ))}
        </ul>
      </section>
      <DownloadSection />
    </>
  );
}
