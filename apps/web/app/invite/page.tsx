import type { Metadata } from 'next';
import Link from 'next/link';

import { Glyph } from '../../components/Glyph';
import { buildPageMetadata } from '../../lib/metadata';
import styles from './page.module.css';

export const metadata: Metadata = buildPageMetadata({
  title: 'Open your private community invite',
  description:
    'Open this private community invitation in the Voiid app, or learn where the official iOS and Android download links will appear.',
  path: '/invite/',
  robots: { index: false, follow: false },
});

export default function CommunityInvite() {
  return (
    <div className={styles.main}>
      <section className={styles.card} aria-labelledby="invite-title">
        <div className={styles.icon} aria-hidden="true">
          <Glyph name="lock" size={30} />
        </div>
        <p className="eyebrow">Private community invite</p>
        <h1 id="invite-title">Open this invite in Voiid</h1>
        <p className={styles.lede}>
          Install Voiid, then open this link again on your phone. It will take you
          straight to the community without exposing the invite on the web.
        </p>
        <div className={styles.actions}>
          <Link href="/#download" className={styles.primary}>
            Get the app <Glyph name="arrow-right" size={18} />
          </Link>
          <Link href="/" className={styles.secondary}>
            Explore Voiid
          </Link>
        </div>
        <p className={styles.note}>
          Already installed? Open this exact link from your phone&rsquo;s browser to
          launch Voiid.
        </p>
      </section>
    </div>
  );
}
