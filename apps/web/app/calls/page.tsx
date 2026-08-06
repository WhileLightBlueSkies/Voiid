import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Grid, Split } from '../../components/Section';
import { FeatureCard } from '../../components/FeatureCard';
import { Callout } from '../../components/Callout';
import { E2EEBadge } from '../../components/E2EEBadge';
import { CTA } from '../../components/CTA';
import { PhoneMockup, PhoneAppBar } from '../../components/PhoneMockup';

export const metadata: Metadata = {
  title: 'Calls',
  description:
    'One-to-one and group voice and video with end-to-end encrypted media. We keep the ' +
    'call log — who, when, how long — and never the call.',
};

/*
 * CLAIMS CHECKED (README rule 2):
 *   - Media + SRTP keys are derived on-device; the server issues TURN credentials, rings
 *     the callee with a content-free push and stores a lean history row — 014_calls.sql
 *     and the header of backend/api/src/routes/calls.ts.
 *   - Group calls run through an SFU with frame-level encryption keyed off the group.
 *   - Conference escalation from a 1:1 exists on the backend (031_call_conference.sql)
 *     but has NO client UI yet, so this page describes it as coming rather than shipped.
 */
export default function CallsPage() {
  return (
    <>
      <Hero
        hue="calls"
        eyebrow="Calls"
        title={<>The call is yours. The log is all we keep.</>}
        lede={
          <>
            Voice and video are encrypted end to end, with the keys derived on the two devices
            in the call. Our servers help you find each other through a firewall and then carry
            nothing but noise.
          </>
        }
        badges={<E2EEBadge state="e2ee" detail="Call media and keys" />}
        aside={
          <PhoneMockup hue="calls" tilt="right" label="An encrypted call" decorative>
            <PhoneAppBar title="Nehal" subtitle="Encrypted · 04:12" />
          </PhoneMockup>
        }
      />

      <Section
        hue="calls"
        eyebrow="How a call connects"
        title="What each part actually does"
        lede="Three moving pieces, and only one of them touches your audio — your own phone."
      >
        <Grid>
          <FeatureCard title="Ringing" glyph="device" hue="calls">
            A content-free push wakes the other phone. It carries routing ids and nothing
            else — no name, no number, no reason for the call. The phone rings before it knows
            anything worth protecting.
          </FeatureCard>
          <FeatureCard title="Finding a path" glyph="globe" hue="calls">
            Short-lived TURN credentials help two devices behind different networks reach each
            other. When a direct path exists the media never touches our infrastructure at all.
          </FeatureCard>
          <FeatureCard title="The media" glyph="lock" hue="calls">
            Encryption keys are derived on the devices. A relay that has to forward your audio
            forwards it encrypted — it is a pipe, not a participant.
          </FeatureCard>
        </Grid>
        <Callout tone="honest" title="What we can see">
          The call log: who called whom, when, and for how long. That is metadata we cannot
          avoid holding if the feature is to work at all — a missed call has to be a record of
          something. We never hold the call.
        </Callout>
      </Section>

      <Section
        hue="calls"
        tone="raised"
        eyebrow="Group calls"
        title="Group voice and video, still encrypted"
      >
        <Split
          aside={
            <PhoneMockup hue="calls" size="sm" tilt="left" label="A group call" decorative>
              <PhoneAppBar title="Launch team" subtitle="4 on the call" />
            </PhoneMockup>
          }
        >
          <div>
            <p>
              A group call routes through a selective forwarding server, because a mesh where
              everyone sends to everyone stops working after a handful of people. Frames are
              encrypted with a key derived from the group&rsquo;s own cryptographic state, so
              the forwarding server moves frames it cannot open.
            </p>
            <p>
              The key rolls as the group changes. Someone who leaves cannot decrypt what is
              said after they go.
            </p>
          </div>
        </Split>
      </Section>

      <Section hue="calls" eyebrow="In progress" title="Adding someone mid-call" width="narrow">
        <p>
          Turning a one-to-one call into a small conference is built on the server and covered
          by tests, but the in-app controls are not finished — so it is not something you can
          do yet. We would rather say that than list it.
        </p>
        <Callout tone="note" title="A shared call is not an introduction">
          When it does ship, being in a call with someone will grant no messaging rights
          whatsoever. If you do not already know them, you will see their @username and nothing
          more, and reaching them afterwards will still take their PIN — the same gate as
          everyone else.
        </Callout>
      </Section>

      <CTA
        hue="calls"
        title="What we can and cannot see"
        lede="The honest version, surface by surface."
        actions={<></>}
        note={<>See the <a href="/privacy">privacy page</a>.</>}
      />
    </>
  );
}
