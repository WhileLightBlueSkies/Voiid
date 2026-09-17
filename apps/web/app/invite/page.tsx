import type { Metadata } from 'next';

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
  return (
    <main
      style={{
        minHeight: '70vh',
        display: 'grid',
        placeItems: 'center',
        padding: '48px 20px',
        textAlign: 'center',
      }}
    >
      <div style={{ maxWidth: 420, display: 'grid', gap: 16 }}>
        <h1 style={{ margin: 0, fontSize: 28, lineHeight: 1.2 }}>Open this invite in Voiid</h1>
        <p style={{ margin: 0, opacity: 0.75, lineHeight: 1.55 }}>
          You have a community invite. Install Voiid, then open this link again — it will take
          you straight to the community.
        </p>
        <p style={{ margin: 0, fontSize: 14, opacity: 0.6, lineHeight: 1.55 }}>
          Already have Voiid? Opening this link on your phone should launch the app. If it
          opened here instead, try it from your phone&rsquo;s browser.
        </p>
        <p style={{ margin: '8px 0 0' }}>
          <a href="/" style={{ fontSize: 14 }}>
            What is Voiid?
          </a>
        </p>
      </div>
    </main>
  );
}
