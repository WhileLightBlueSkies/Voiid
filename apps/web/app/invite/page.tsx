import type { Metadata } from 'next';
import { Logomark } from '../../components/Logomark';
import styles from './page.module.css';

/*
 * CLAIMS CHECKED (README rule 2):
 *   - /c/<handle>?i=<token> is the community invite link, and the ONLY path the apps claim
 *     in apple-app-site-association. Everything else on voiid.app stays in the browser.
 *   - Every /c/* URL is rewritten onto this page by public/_redirects with a 200, so the
 *     handle and the ?i= token stay in the address bar.
 *   - The token is NOT redeemed here. Redemption is an authenticated POST from inside the
 *     app (routes/communities.ts); this page never sees an account and never calls the API.
 *   - No analytics, no cookie, no fetch: static HTML from the same export as the brochure.
 */

/**
 * THE PAGE A PERSON WITHOUT THE APP LANDS ON.
 *
 * When iOS or Android has verified domain ownership, an invite link opens the app and this
 * page is never seen. It exists for everyone else — no app installed, a desktop browser, a
 * link pasted into a work laptop — who until now got a 404 that reads as "this invite is
 * broken" when the invite is fine and the reader simply does not have Voiid.
 *
 * Deliberately says almost nothing about the community. The handle is not resolved against
 * the API: doing so would let anyone enumerate community names and member counts by trying
 * handles, and would turn a static brochure into something that talks to the backend.
 */

export const metadata: Metadata = {
  title: 'Community invite',
  description: 'Open this invite in Voiid.',
  // An invite is a private link — a token in the URL is the whole point. Letting a crawler
  // index the page would defeat it.
  robots: { index: false, follow: false },
};

export default function CommunityInvite() {
  // A <section>, not a <main>: the root layout already provides the page's <main>.
  return (
    <section className={styles.invite} aria-labelledby="invite-title">
      <div className={styles.aurora} aria-hidden="true">
        <span />
        <span />
      </div>
      <div className={styles.card}>
        <span className={styles.mark} aria-hidden="true">
          <span className={styles.ring} />
          <Logomark size={40} idPrefix="invite" />
        </span>
        <p className={styles.kicker}>Community invite</p>
        <h1 id="invite-title" className={styles.title}>
          Open this invite in Voiid
        </h1>
        <p className={styles.lede}>
          You have a community invite. Install Voiid, then open this link again — it will take
          you straight to the community.
        </p>
        <p className={styles.small}>
          Already have Voiid? Opening this link on your phone should launch the app. If it
          opened here instead, try it from your phone&rsquo;s browser.
        </p>
        <a href="/" className={styles.button}>
          What is Voiid?
        </a>
      </div>
    </section>
  );
}
