import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Grid } from '../../components/Section';
import { FeatureCard } from '../../components/FeatureCard';
import { Callout } from '../../components/Callout';
import { E2EEBadge } from '../../components/E2EEBadge';
import { CTA } from '../../components/CTA';
import { PhoneMockup, PhoneAppBar } from '../../components/PhoneMockup';

export const metadata: Metadata = {
  title: 'Clips',
  description:
    'Short public video with creator profiles and follows. Clips are not end-to-end ' +
    'encrypted — the server can read them, and here is why.',
};

/*
 * THIS IS THE PAGE MOST AT RISK OF OVERCLAIMING, so it leads with the exception rather
 * than burying it. Checked against the header of 022_clips.sql and 029_creator_profiles.sql:
 *   - Clip media is PLAINTEXT in R2; captions, view/like/comment counts are server-readable.
 *   - Creator profiles, follows, likes and comments are server-readable.
 *   - A follow grants NO messaging right — 029 header, and the follow graph is deliberately
 *     not joinable into the reachability graph.
 *   - A creator handle is separate from the chat @username but shares one namespace.
 */
export default function ClipsPage() {
  return (
    <>
      <Hero
        hue="clips"
        eyebrow="Clips"
        title={<>Public video, and we say so plainly.</>}
        lede={
          <>
            Clips are short vertical videos anyone can watch. They are the one part of Voiid
            that is <strong>not</strong> end-to-end encrypted, and that is a deliberate choice
            with a reason we are happy to put in writing.
          </>
        }
        badges={<E2EEBadge state="public" detail="Clips, profiles, likes and comments" />}
        aside={
          <PhoneMockup hue="clips" tilt="right" label="The clips feed" decorative>
            <PhoneAppBar title="Clips" subtitle="Explore" />
          </PhoneMockup>
        }
      />

      <Section
        hue="clips"
        eyebrow="Why not encrypted"
        title="You cannot encrypt to an audience that has not arrived"
        width="narrow"
      >
        <p>
          End-to-end encryption needs a known list of recipients at the moment you write. A
          message has one. A group has one. A broadcast does not: anyone may discover a clip,
          including people who have not signed up yet, and the product needs view and like
          counts the server can actually vouch for. A server that cannot read a row cannot
          count it.
        </p>
        <p>
          So clip video is stored as plaintext, and we tell you rather than describing the app
          as &ldquo;encrypted&rdquo; and letting you assume it covers everything. Messages,
          calls, locations and moments are unaffected.
        </p>
        <Callout tone="honest" title="What the server can read here">
          The video, the caption, the thumbnail, and who viewed, liked or commented. Treat a
          clip the way you would treat a public post anywhere else — because that is what it is.
        </Callout>
      </Section>

      <Section hue="clips" tone="raised" eyebrow="Creators" title="A public identity, kept separate on purpose">
        <Grid>
          <FeatureCard title="Your handle is not your username" glyph="key" hue="clips">
            A creator handle is meant to go on a poster. Your chat @username is half of a
            private credential — it only works alongside your PIN. Merging them would publish
            the messaging lookup key of exactly the people most likely to be targeted.
          </FeatureCard>
          <FeatureCard title="One name, one owner" glyph="check" hue="clips">
            Handles and usernames share a single namespace, so @acme cannot be one person in
            chat and somebody else in Clips. You can always take your own username as your
            handle.
          </FeatureCard>
          <FeatureCard title="A follow is not an introduction" glyph="shield" hue="clips">
            Following someone lets you see clips that were already public to everyone. It opens
            no conversation and grants no messaging rights — a creator with a million followers
            gains exactly zero people who can message them.
          </FeatureCard>
        </Grid>
      </Section>

      <Section hue="clips" eyebrow="Making one" title="Record, trim, filter, post" width="narrow">
        <p>
          Record in the app or bring a video in, trim it against a strip of real frames, pick a
          colour filter and choose the cover. What plays in the editor is what gets encoded —
          the preview runs the same filter pipeline as the export, so the look you choose is
          the look you ship.
        </p>
        <p>
          You need a creator profile before your first post. That is a deliberate gate: a clip
          in a public feed should have a public identity behind it.
        </p>
      </Section>

      <CTA
        hue="clips"
        title="What is encrypted and what is not"
        lede="The whole map, in one table."
        actions={<></>}
        note={<>See the <a href="/privacy">privacy page</a>.</>}
      />
    </>
  );
}
