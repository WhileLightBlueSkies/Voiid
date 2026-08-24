import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Split } from '../../components/Section';
import { Callout } from '../../components/Callout';
import { E2EEBadge } from '../../components/E2EEBadge';
import { CTA } from '../../components/CTA';
import { Glyph } from '../../components/Glyph';
import { PhoneMockup, PhoneAppBar, PhoneRow, PhoneAvatar } from '../../components/PhoneMockup';
import { CallPath } from '../../components/CallPath';
import styles from './page.module.css';

export const metadata: Metadata = {
  title: 'Calls',
  description:
    'One-to-one and group voice and video with frame-level end-to-end encryption and ' +
    'verified keying. We keep the call log — who, when, how long — and never the call.',
};

/*
 * CLAIMS CHECKED (README rule 2):
 *   - Media + SRTP keys are derived on-device; the server issues TURN credentials, rings
 *     the callee with a content-free push and stores a lean history row — 014_calls.sql
 *     and the header of backend/api/src/routes/calls.ts.
 *   - Group calls run through an SFU with frame-level encryption keyed off the group.
 *   - Conference escalation from a 1:1 exists on the backend (031_call_conference.sql)
 *     but has NO client UI yet, so this page describes it as coming rather than shipped.
 *   - The ledger below splits exactly what 014_calls.sql stores from what it does not.
 */

/**
 * The in-call screen, drawn rather than photographed.
 *
 * No stock image and no CDN — and, deliberately, no face belonging to a real person
 * who never agreed to appear on a marketing page. The "camera" is a soft mass where
 * a head and shoulders would be, which is enough to read as a video call.
 */
function InCallScreen() {
  return (
    <div className={styles.callScreen}>
      <div className={styles.remote} aria-hidden="true" />

      <div className={styles.callHead}>
        <span className={styles.callName}>Nehal</span>
        {/* The verified badge is the one moment of green on the screen: it is the
            claim the whole page is making, so nothing else competes with it. */}
        <span className={styles.callSecure}>
          <Glyph name="lock" size={11} />
          End-to-end encrypted
        </span>
        <span className={styles.callTimer}>04:12</span>
      </div>

      <div className={styles.selfTile} aria-hidden="true">
        <span className={styles.selfLabel}>You</span>
      </div>

      <div className={styles.callControls} aria-hidden="true">
        <span className={styles.ctl}><Glyph name="device" size={14} /></span>
        <span className={styles.ctl}><Glyph name="eye-off" size={14} /></span>
        <span className={`${styles.ctl} ${styles.ctlEnd}`}><Glyph name="call" size={14} /></span>
      </div>
    </div>
  );
}

export default function CallsPage() {
  return (
    <>
      <Hero
        hue="calls"
        eyebrow="Calls"
        title={<>The call is yours. The log is all we keep.</>}
        lede={
          <>
            Voice and video are encrypted end to end on every call: each frame of media is
            sealed with a key derived on your devices and delivered over the same encrypted
            channel as your messages. Our servers find you a path and carry nothing but
            ciphertext.
          </>
        }
        badges={<E2EEBadge state="e2ee" detail="All call media · verified keying" />}
        aside={
          <PhoneMockup hue="calls" tilt="right" label="An encrypted call" decorative>
            <InCallScreen />
          </PhoneMockup>
        }
      />

      {/* ---- how a call connects ------------------------------------------- */}
      <Section
        hue="calls"
        eyebrow="How a call connects"
        title="Three moving pieces, and only one of them touches your audio"
        lede={
          <>
            A call has to cross two networks that have never met, which takes more
            coordination than sending a message. None of that coordination requires
            hearing you — so none of it does.
          </>
        }
      >
        <CallPath />
        <Callout tone="honest" title="What we can see" className={styles.afterGrid}>
          The call log: who called whom, when, and for how long. That is metadata we cannot
          avoid holding if the feature is to work at all — a missed call has to be a record of
          something. We never hold the call.
        </Callout>
      </Section>

      {/* ---- the ledger ------------------------------------------------------ */}
      <Section
        hue="calls"
        tone="raised"
        eyebrow="The ledger"
        title="Kept and not kept, side by side"
        lede={
          <>
            The honest version of a call is two lists. Putting them next to each other is
            the only way to read the second one properly.
          </>
        }
      >
        <div className={styles.ledger}>
          <div className={styles.ledgerCol}>
            <h3 className={styles.ledgerHead}>
              <span className={styles.ledgerIconOk} aria-hidden="true">
                <Glyph name="eye-off" size={16} />
              </span>
              Never leaves your devices
            </h3>
            <ul className={`${styles.ledgerList} ${styles.ledgerListOk}`}>
              <li>The audio of the call</li>
              <li>The video of the call</li>
              <li>The per-call media key</li>
              <li>Anything said, shown or shared during it</li>
            </ul>
            <p className={styles.ledgerFoot}>
              Encrypted on your device, decrypted on theirs. Our infrastructure forwards
              packets it has no key for.
            </p>
          </div>

          <div className={styles.ledgerCol}>
            <h3 className={styles.ledgerHead}>
              <span className={styles.ledgerIconOpen} aria-hidden="true">
                <Glyph name="note" size={16} />
              </span>
              Stored in the call log
            </h3>
            <ul className={styles.ledgerList}>
              <li>Who called whom</li>
              <li>When it started</li>
              <li>How long it lasted</li>
              <li>Whether it was answered, missed or declined</li>
            </ul>
            <p className={styles.ledgerFoot}>
              A missed call has to be a record of something. We hold the shape of the call
              so your history works — never its contents.
            </p>
          </div>
        </div>
      </Section>

      {/* ---- group calls ----------------------------------------------------- */}
      <Section
        hue="calls"
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
          <div className={styles.prosePlus}>
            <p>
              A group call routes through a selective forwarding server, because a mesh where
              everyone sends to everyone stops working after a handful of people. Frames are
              encrypted with a key derived from the group&rsquo;s own cryptographic state, so
              the forwarding server moves frames it cannot open.
            </p>
            <h3 className={styles.subhead}>The key rolls with the group</h3>
            <p>
              Adding or removing someone re-keys the call. A person who leaves cannot decrypt
              what is said after they go, and a person who joins cannot decrypt what came
              before — the same guarantee groups get in messaging, applied to live media.
            </p>
          </div>
        </Split>
      </Section>

      {/* ---- the call keeps running ----------------------------------------- */}
      <Section
        hue="calls"
        eyebrow="While you are on it"
        title="The call stays on top of whatever you go and do"
      >
        <Split
          reverse
          aside={
            <PhoneMockup hue="calls" size="sm" tilt="right" label="Returning to a call" decorative>
              <div className={styles.listStage}>
                <PhoneAppBar title="Chats" />
                <PhoneRow avatar={<PhoneAvatar initials="PR" seed={2} />} title="Priyanshu" preview="Green on both platforms." meta="09:38" />
                <PhoneRow avatar={<PhoneAvatar initials="LT" seed={4} />} title="Launch team" preview="Ship it." meta="09:31" />
                <PhoneRow avatar={<PhoneAvatar initials="AS" seed={6} />} title="Aisha" preview="Sent the keys over" meta="Tue" />
                <div className={styles.floatingCall} aria-hidden="true">
                  <span className={styles.floatingVideo} />
                  <span className={styles.floatingMeta}>
                    <span className={styles.floatingName}>Nehal</span>
                    <span className={styles.floatingTime}>04:12</span>
                  </span>
                </div>
              </div>
            </PhoneMockup>
          }
        >
          <div className={styles.prosePlus}>
            <p>
              Leaving the call screen does not leave the call. It shrinks to a window that
              floats over whatever you went to look up, and tapping it puts you straight
              back — the call is never something you have to go and find again.
            </p>
            <p>
              None of this changes the encryption. The window is the same call, keyed the
              same way; only the size of it changed.
            </p>
          </div>
        </Split>
      </Section>

      {/* ---- not shipped yet -------------------------------------------------- */}
      <Section hue="calls" eyebrow="In progress" title="Adding someone mid-call" width="narrow">
        <p>
          Turning a one-to-one call into a small conference is built on the server and covered
          by tests, but the in-app controls are not finished — so it is not something you can
          do yet. We would rather say that than list it.
        </p>
        <Callout tone="note" title="A shared call is not an introduction" className={styles.afterGrid}>
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
