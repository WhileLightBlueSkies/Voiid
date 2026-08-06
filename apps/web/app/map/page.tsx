import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Grid } from '../../components/Section';
import { FeatureCard } from '../../components/FeatureCard';
import { Callout } from '../../components/Callout';
import { E2EEBadge } from '../../components/E2EEBadge';
import { CTA } from '../../components/CTA';
import { PhoneMockup, PhoneAppBar } from '../../components/PhoneMockup';

export const metadata: Metadata = {
  title: 'Map',
  description:
    'A friends map that starts empty. You appear to nobody until you name someone, and ' +
    'going invisible mints a new key so the dark period stays dark.',
};

/*
 * CLAIMS CHECKED (README rule 2), against docs/LOCATION.md and the header of
 * apps/ios/Voiid/Voiid/Networking/MapPresenceEngine.swift:
 *   - Ghost by default; visibility requires a non-empty per-contact audience.
 *   - Going visible mints a fresh 32-byte key; ghosting rotates it.
 *   - Fixes are encrypted on-device under that key and relayed as one opaque blob;
 *     they are never written to the database — 018_location_shares.sql covers the
 *     SESSION only, never a coordinate.
 *   - THE HONEST LIMIT, stated in the engine header and repeated here: there is no
 *     forward secrecy WITHIN one visibility session.
 */
export default function MapPage() {
  return (
    <>
      <Hero
        hue="map"
        eyebrow="Map"
        title={<>A map that starts empty, and stays that way until you say otherwise.</>}
        lede={
          <>
            Most location features begin by asking forgiveness. This one begins with nobody
            able to see you — not a setting buried three screens deep, but the state the
            feature is born in.
          </>
        }
        badges={<E2EEBadge state="e2ee" detail="Positions and live shares" />}
        aside={
          <PhoneMockup hue="map" tilt="left" label="The friends map" decorative>
            <PhoneAppBar title="Map" subtitle="2 friends sharing" />
          </PhoneMockup>
        }
      />

      <Section
        hue="map"
        eyebrow="How it works"
        title="Visible to named people, or to no one"
        lede="There is no 'everyone' and no 'friends of friends'. You add people one at a time."
      >
        <Grid>
          <FeatureCard title="Ghost is the default" glyph="shield" hue="map">
            Until you name someone, no position is sent — and because the location provider is
            stopped, none is even taken. Invisible means the phone is not looking.
          </FeatureCard>
          <FeatureCard title="Going dark rotates the key" glyph="key" hue="map">
            Turning visibility off mints a fresh key next time you turn it on. The period you
            spent invisible is not merely unshared; nobody holds a key that could ever open it.
          </FeatureCard>
          <FeatureCard title="Removing someone re-keys" glyph="lock" hue="map">
            Adding a person needs no new key. Removing one does — so a former viewer is left
            holding a key that opens nothing further.
          </FeatureCard>
        </Grid>
      </Section>

      <Section
        hue="map"
        tone="raised"
        eyebrow="Live location"
        title="Sharing in a chat is a separate decision"
      >
        <p>
          Live location in a conversation is timer-bounded and independent of the map. Stopping
          one does not stop the other, and they do not share an audience — being on someone&rsquo;s
          map has never meant they can watch you move through a chat.
        </p>
        <p>
          Every fix is encrypted on your phone and relayed as one opaque blob. Positions are
          never stored: our database holds the fact that a share exists and when it ends, and
          not a single coordinate.
        </p>
      </Section>

      <Section hue="map" eyebrow="The honest limit" title="What this does not give you" width="narrow">
        <Callout tone="honest" title="No forward secrecy inside one session">
          While you are visible, the people you named hold one key for that session. Anyone who
          holds it could read every fix you send until it rotates — on ghosting, on removing a
          viewer, or on the session ending. Forward secrecy across sessions is preserved,
          because each one mints a fresh random key, and fixes are never stored, so the window
          is the live stream only. This is a limit of the crypto we build on, and we would
          rather write it here than let you assume otherwise.
        </Callout>
      </Section>

      <CTA
        hue="map"
        title="The full picture"
        lede="Every surface, and what the server can see on each."
        actions={<></>}
        note={<>See the <a href="/privacy">privacy page</a>.</>}
      />
    </>
  );
}
