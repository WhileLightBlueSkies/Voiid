import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { Hero } from '../../components/Hero';
import { Section, Grid, Split } from '../../components/Section';
import { FeatureCard, StatLine } from '../../components/FeatureCard';
import { CTA } from '../../components/CTA';
import { Button, ButtonRow } from '../../components/Button';
import { E2EEBadge } from '../../components/E2EEBadge';
import { Callout } from '../../components/Callout';
import { Glyph } from '../../components/Glyph';
import {
  PhoneMockup,
  PhoneAppBar,
  PhoneAvatar,
  PhoneRow,
} from '../../components/PhoneMockup';
import { CallPathDiagram } from './CallPathDiagram';
import { SfuDiagram } from './SfuDiagram';
import styles from './page.module.css';

export const metadata: Metadata = {
  title: 'Calls',
  description:
    'Voice and video calls in Voiid: one to one and in groups, with the media ' +
    'encrypted between the devices. What our server relays, what it keeps, and what ' +
    'it has no key for.',
};

/*
 * ═══════════════════════════════════════════════════════════════════════════════
 * SOURCES. Every claim below was read out of the codebase before it was written.
 *
 *   backend/api/src/routes/calls.ts       TURN issuance, /ring authorization, the
 *                                         Redis ring grant, LiveKit token minting,
 *                                         /group/ring fan-out, anonymous metrics.
 *   backend/websocket/src/index.ts        the signalling relay: sender stamped from
 *                                         the socket, callPairAuthorized fail-closed,
 *                                         the 60s offer/ICE buffer.
 *   database/migrations/014_calls.sql     what the call row holds; what it does not.
 *   database/migrations/016_call_metrics  — via callMetrics.ts: the anonymous sample.
 *   database/migrations/020_reachability  the three ways to become reachable.
 *   packages/e2e-core/src/call.rs         HKDF-SHA256 SRTP derivation, 1:1 and group.
 *   apps/ios/.../CallService.swift        DTLS-SRTP, ICE restart cap of 3, hold and
 *                                         call waiting, audio routes, PiP wiring.
 *   apps/ios/.../GroupCallService.swift   LiveKit + MLS-derived frame key.
 *   apps/ios/.../CallPiPController.swift  the sample-buffer layer behind PiP.
 *   apps/ios/.../CallIntentRouter.swift   contact-card and Recents integration.
 *   apps/android/.../CallService.kt       the same engine on Android; the explicit
 *                                         call-waiting swap; MAX_ICE_RESTARTS = 3.
 *   apps/android/.../GroupCallService.kt  LiveKit E2EE keyed from GroupEngine.callKey.
 *   apps/android/.../CallPip.kt           system PiP, chrome stripped to bare video.
 *   docs/TURN_SETUP.md, docs/LIVEKIT_SETUP.md, docs/CALL_RELIABILITY.md.
 *
 * THINGS DELIBERATELY NOT CLAIMED, because a grep makes them look shipped:
 *   - Screen sharing. There is none, on either platform. Said plainly below.
 *   - Ad-hoc conference calls (adding a third person to a live 1:1). The migration
 *     031_call_conference.sql exists; there is NO route and no client for it. A
 *     schema is not a feature, so this page does not mention it.
 *   - Multi-region TURN. docs/CALL_RELIABILITY.md still has that box unticked.
 *   - App Store / Play links. None exist.
 *
 * AMBER BUDGET: spent once, on the <Callout tone="warn"> in "What we keep". No
 * accent Button, no accent CTA, no PhoneRow badge anywhere on this page.
 * ═══════════════════════════════════════════════════════════════════════════════
 */

type Step = { n: string; title: string; body: ReactNode };

const SETUP: Step[] = [
  {
    n: '01',
    title: 'Your phone asks for a route',
    body: (
      <>
        Before anything rings, your device fetches a set of time-limited ICE and TURN
        credentials. If a deployment has no relay configured it says so honestly and
        the call falls back to direct-only, rather than failing in a way you cannot read.
      </>
    ),
  },
  {
    n: '02',
    title: 'We check you are allowed to ring at all',
    body: (
      <>
        Ringing someone is a reachability decision, not just an authentication one. You
        can only ring through a conversation you both belong to — which means the caller
        already came through the front door. Both sides are checked, not just the
        caller, so being in a large group with someone does not let you ring them.
      </>
    ),
  },
  {
    n: '03',
    title: 'Their devices wake on a content-free push',
    body: (
      <>
        The push carries routing identifiers and a call id. No name, no preview, no key,
        no media. On iOS, where a PushKit key is configured, it is a VoIP push — the
        only kind that can resume a fully killed app fast enough to ring properly.
      </>
    ),
  },
  {
    n: '04',
    title: 'Setup messages cross a relay that fails closed',
    body: (
      <>
        The offer, the answer and the network candidates travel our WebSocket relay,
        which stamps the sender from the authenticated socket — you cannot claim to be
        someone else — and verifies both ends against the permission the ring created.
        No permission, no relay, and it says nothing useful back to whoever asked.
      </>
    ),
  },
  {
    n: '05',
    title: 'The two phones agree a key, and we drop out',
    body: (
      <>
        The devices complete their own handshake and start sending SRTP to each other.
        Ringback only begins when their handset reports that it is genuinely alerting,
        so the tone you hear is the truth rather than an optimistic guess.
      </>
    ),
  },
];

/** Control icons for the mocked call screen. Not part of the site glyph set — they
 *  exist only inside the device frame, on the same 24 grid and the same 1.6 stroke. */
function CtlIcon({ name }: { name: 'mic' | 'video' | 'route' | 'end' }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {name === 'mic' ? (
        <>
          <rect x="9.2" y="3.2" width="5.6" height="10.4" rx="2.8" />
          <path d="M5.8 11.4a6.2 6.2 0 0 0 12.4 0M12 17.6v3.2" />
        </>
      ) : null}
      {name === 'video' ? (
        <>
          <rect x="3" y="6.4" width="12.4" height="11.2" rx="2.8" />
          <path d="m15.4 11 5.6-3.2v8.4L15.4 13Z" />
        </>
      ) : null}
      {name === 'route' ? (
        <>
          <path d="M4.4 9.6v4.8h3l4.4 3.6V6L7.4 9.6Z" />
          <path d="M15.6 9.4a3.6 3.6 0 0 1 0 5.2M18.2 7a7.2 7.2 0 0 1 0 10" />
        </>
      ) : null}
      {name === 'end' ? (
        <path d="M3.4 14.2 5 11.6a11.4 11.4 0 0 1 14 0l1.6 2.6a1.6 1.6 0 0 1-.7 2.3l-2.6 1.1a1.6 1.6 0 0 1-2-.7l-.8-1.4a9 9 0 0 0-6 0l-.8 1.4a1.6 1.6 0 0 1-2 .7l-2.6-1.1a1.6 1.6 0 0 1-.7-2.3Z" />
      ) : null}
    </svg>
  );
}

export default function CallsPage() {
  return (
    <>
      <Hero
        hue="calls"
        eyebrow="Calls"
        title={<>We can connect your call. We cannot hear it.</>}
        lede={
          <>
            Voice and video, one to one or with a whole group. The audio and video are
            encrypted between the phones on the call, with a key that is derived on
            those phones and never handed to us. Our job is to make the other handset
            ring and to pass the setup messages along.
          </>
        }
        badges={
          <E2EEBadge
            state="e2ee"
            size="md"
            label="Call media — encrypted device to device"
          />
        }
        actions={
          <ButtonRow>
            <Button href="#setup" size="lg">
              What happens when you tap call
            </Button>
            <Button href="/privacy" variant="secondary" size="lg">
              The whole architecture
            </Button>
          </ButtonRow>
        }
        note={
          <>
            The call log — who rang whom, when, and for how long — is a row on our
            server, and we would rather you read that here than discover it later.{' '}
            <a href="#ledger">Exactly what that row holds.</a>
          </>
        }
        aside={<CallPathDiagram size={540} idPrefix="calls-hero" />}
      />

      {/* ---- the setup sequence --------------------------------------------- */}
      <Section
        id="setup"
        hue="calls"
        eyebrow="Five seconds, step by step"
        title="What actually happens when you tap call."
        lede={
          <>
            Most of this is invisible and takes about a second. It is written out here
            because &ldquo;encrypted&rdquo; is a claim, and a claim is worth what its
            mechanism is worth.
          </>
        }
      >
        <ol className={styles.steps}>
          {SETUP.map((step) => (
            <li key={step.n} className={styles.step}>
              <span className={styles.stepNum} aria-hidden="true">
                {step.n}
              </span>
              <div className={styles.stepBody}>
                <h3 className={styles.stepTitle}>{step.title}</h3>
                <p className={styles.stepText}>{step.body}</p>
              </div>
            </li>
          ))}
        </ol>

        <Callout title="One place we will not round up." glyph="key">
          <p>
            On a one-to-one call the SRTP keys come from the DTLS handshake the two
            phones perform with each other. That key never exists on our side. What our
            server does provide is the authenticated channel the fingerprints crossed —
            so an attacker on the network cannot substitute their own without us
            colluding, but the authentication is ours to make rather than yours to
            verify. A layer that derives the call key from the same ratchet your
            messages use is written and tested in our crypto core, and is not yet wired
            into one-to-one calls. Group calls already work the stronger way, below.
          </p>
        </Callout>
      </Section>

      {/* ---- one to one ------------------------------------------------------ */}
      <Section
        id="one-to-one"
        hue="calls"
        tone="raised"
        eyebrow="One to one"
        title="A call that behaves like a call."
        lede={
          <>
            Voiid calls are reported to the operating system properly, so they ring on
            the lock screen, respect your silent switch, and survive the things phone
            calls have to survive.
          </>
        }
      >
        <Split
          reverse
          aside={
            <PhoneMockup
              hue="calls"
              size="md"
              tilt="left"
              label="A Voiid video call in progress. The caller's name, a lock and the words 'End-to-end encrypted' sit at the top, a self-view tile in the corner, and a row of controls — microphone, camera, audio output and hang up — along the bottom."
            >
              <div className={styles.callScreen}>
                <span className={styles.remote} aria-hidden="true" />

                <div className={styles.callHead}>
                  <span className={styles.callName}>Rhea Sharma</span>
                  <span className={styles.callSecure}>
                    <Glyph name="lock" size={11} />
                    End-to-end encrypted
                  </span>
                  <span className={styles.callTimer}>04:12</span>
                </div>

                <div className={styles.selfTile}>
                  <span className={styles.selfLabel}>You</span>
                </div>

                <div className={styles.callControls}>
                  <span className={styles.ctl}>
                    <CtlIcon name="mic" />
                  </span>
                  <span className={styles.ctl}>
                    <CtlIcon name="video" />
                  </span>
                  <span className={styles.ctl}>
                    <CtlIcon name="route" />
                  </span>
                  <span className={[styles.ctl, styles.ctlEnd].join(' ')}>
                    <CtlIcon name="end" />
                  </span>
                </div>
              </div>
            </PhoneMockup>
          }
        >
          <Grid columns={2} gap="md">
            <FeatureCard title="Voice or video, either way" hue="calls" glyph="call">
              <p>
                Start a call as voice and turn the camera on later, or the other way
                round. Mute, switch cameras, and pick where the sound comes out —
                earpiece, speaker, a Bluetooth headset or wired headphones — from a
                picker that only offers the routes actually plugged in right now.
              </p>
            </FeatureCard>

            <FeatureCard title="Hold, and a second call" hue="calls" glyph="device">
              <p>
                Put a call on hold and the other side is told, so their screen says
                &ldquo;on hold&rdquo; instead of looking frozen. If a second call arrives
                mid-conversation you get to decide. On Android that decision is an
                explicit swap — the first caller is properly hung up rather than left on
                a zombie line — because the engine holds exactly one microphone.
              </p>
            </FeatureCard>

            <FeatureCard title="It reaches the rest of the phone" hue="calls" glyph="group">
              <p>
                A Voiid call appears where phone calls appear: a &ldquo;Voiid&rdquo; row
                inside the contact card, an entry in Recents, and on newer Android a
                redial straight from the system call log. Tapping any of them starts a
                real Voiid call — an affordance that does nothing when tapped is worse
                than not offering it.
              </p>
            </FeatureCard>

            <FeatureCard title="Missed calls that are actually missed" hue="calls" glyph="note">
              <p>
                Answer on your tablet and your phone is told the call was taken
                elsewhere, so it does not post a missed-call notification for a call your
                account picked up. Recents has a Missed filter, and you can clear the
                whole log whenever you like.
              </p>
            </FeatureCard>
          </Grid>
        </Split>
      </Section>

      {/* ---- reliability ----------------------------------------------------- */}
      <Section
        id="resilience"
        hue="calls"
        eyebrow="When the network moves"
        title="Walking out of the front door should not end the call."
        lede={
          <>
            Step off Wi-Fi onto mobile data and the addresses your call was negotiated
            on stop existing. This is the single most common way a real call dies, so it
            is handled rather than hoped about.
          </>
        }
      >
        <div className={styles.stats}>
          <StatLine
            value="3"
            label="attempts to re-gather the network path before a call is declared lost"
          />
          <StatLine
            value="1 call ID"
            label="the reconnection keeps the same call, so it never rings you a second time"
          />
          <StatLine
            value="60s"
            label="the only thing ever parked on our side: an unanswered offer, deleted the moment the call resolves"
          />
        </div>

        <Grid columns={3} gap="md">
          <FeatureCard title="The handover" hue="calls" glyph="globe">
            <p>
              Both apps watch the network path directly rather than waiting for the call
              to fail. When the interface changes, they renegotiate over the existing
              signalling channel and the same call — the screen says
              &ldquo;Reconnecting&rdquo;, and media often resumes before you finish the
              sentence.
            </p>
          </FeatureCard>

          <FeatureCard title="Patience, on purpose" hue="calls" glyph="check">
            <p>
              A briefly disconnected call usually heals itself, and a needless
              renegotiation is disruptive in its own right. So a wobble gets a grace
              period and only a genuine failure is acted on immediately. The socket
              reconnects with backoff and queues candidates rather than losing them.
            </p>
          </FeatureCard>

          <FeatureCard title="When there is no direct path" hue="calls" glyph="shield">
            <p>
              Somewhere between one call in ten and one in five cannot go peer to peer —
              carrier-grade NAT, office firewalls, hotel Wi-Fi. Those calls use a relay,
              which forwards the same encrypted packets it could not open if it wanted
              to. It sees addresses and timing; it never sees the call.
            </p>
          </FeatureCard>
        </Grid>
      </Section>

      {/* ---- backgrounding + PiP --------------------------------------------- */}
      <Section
        id="background"
        hue="calls"
        tone="raised"
        eyebrow="Off the screen, still in the call"
        title="Look something up without hanging up."
        lede={
          <>
            A video call that dies the moment you check an address is not a video call.
            Leaving the screen — inside the app or out of it — hands the same picture to
            a smaller window and carries on.
          </>
        }
      >
        <Split
          aside={
            <PhoneMockup
              hue="calls"
              size="sm"
              tilt="right"
              label="The Voiid chat list with a small floating call window resting above it, showing the other person's video and the running call time. Tapping it returns to the full call screen."
            >
              <PhoneAppBar title="Chats" back={false} />
              <div className={styles.listStage}>
                <PhoneRow
                  avatar={<PhoneAvatar initials="RS" size={30} seed={3} />}
                  title="Rhea Sharma"
                  preview="On a call"
                  meta="now"
                />
                <PhoneRow
                  avatar={<PhoneAvatar initials="DK" size={30} seed={1} />}
                  title="Dev Kapoor"
                  preview="Sent the address"
                  meta="18:52"
                />
                <PhoneRow
                  avatar={<PhoneAvatar initials="TW" size={30} seed={4} />}
                  title="Trek weekend"
                  preview="Aarav: leaving at six"
                  meta="18:31"
                />
                <PhoneRow
                  avatar={<PhoneAvatar initials="NM" size={30} seed={2} />}
                  title="Nisha M"
                  preview="Photo"
                  meta="Yesterday"
                />

                <div className={styles.floatingCall}>
                  <span className={styles.floatingVideo} aria-hidden="true" />
                  <span className={styles.floatingMeta}>
                    <span className={styles.floatingName}>Rhea</span>
                    <span className={styles.floatingTime}>04:31</span>
                  </span>
                </div>
              </div>
            </PhoneMockup>
          }
        >
          <div className={styles.prosePlus}>
            <h3 className={styles.subhead}>Inside the app</h3>
            <p>
              Navigate away from the call screen and the call collapses into a small
              floating window that follows you around the app. Tap it and you are back on
              the full screen, with the same stream — nothing is torn down and rebuilt.
            </p>

            <h3 className={styles.subhead}>Out of the app</h3>
            <p>
              Background the app during a video call and the system takes over: iOS puts
              it into Picture in Picture, Android into its own PiP window. On iOS the
              in-app view and the PiP window are fed by the same layer, so the handover
              is the identical picture rather than a second, slightly different one. On
              Android every piece of call chrome is stripped away in PiP, leaving just
              the other person, and a foreground service keeps the call alive.
            </p>

            <Callout title="There is no screen sharing in Voiid." glyph="eye-off">
              <p>
                Not on iOS, not on Android, not in a group call. It is a reasonable thing
                to expect from a video-calling app, so it is worth stating plainly rather
                than letting you find out mid-meeting. Cameras, microphones and the call
                itself are what ships today.
              </p>
            </Callout>
          </div>
        </Split>
      </Section>

      {/* ---- group calls ------------------------------------------------------ */}
      <Section
        id="group"
        hue="calls"
        eyebrow="Group calls"
        title="More than two people, without giving anything away."
        lede={
          <>
            A group call runs in a group conversation — the conversation is the room, so
            there is no separate roster to keep in step and no way to join one you are
            not a member of.
          </>
        }
      >
        <div className={styles.diagramFrame}>
          <SfuDiagram size={620} />
          <p className={styles.diagramNote}>
            Everyone sending to everyone else is quadratic: four people on a mesh means
            twelve uploads, and phones are the first thing to overheat. A forwarding
            server takes one upload from each device and passes it on — so the count
            grows with the room instead of with its square.
          </p>
        </div>

        <Grid columns={3} gap="md">
          <FeatureCard
            title="The key comes from your group, not from the server"
            hue="calls"
            glyph="key"
            span={2}
          >
            <p>
              Every member derives the media key locally from the conversation&rsquo;s own
              encrypted group state. Nobody sends it anywhere: identical material appears
              on each device because each device already holds the group. The forwarding
              server is handed a join permission and nothing else — it routes sealed
              frames and cannot open one.
            </p>
            <p>
              And because that state changes whenever the membership does, the media key
              changes with it. Add someone to the group and the key rotates, mid-call
              included; remove someone and the frames they could have decrypted stop
              being the frames anyone is sending.
            </p>
          </FeatureCard>

          <FeatureCard title="One call at a time" hue="calls" glyph="device">
            <p>
              A device can be in a group call or a one-to-one call, never both. Two call
              engines fighting over one microphone and one audio route is how you get a
              call where nobody can hear anybody, so each refuses to start while the
              other is running.
            </p>
          </FeatureCard>
        </Grid>

        <Callout
          className={styles.afterGrid}
          title="Group calling depends on the deployment."
          tone="note"
          glyph="note"
        >
          <p>
            The forwarding server is a piece of infrastructure an operator has to run.
            Where one is not configured, the app hides the group-call button rather than
            offering you something that will fail — and one-to-one calls, which need no
            such server, are unaffected.
          </p>
        </Callout>
      </Section>

      {/* ---- who can ring you -------------------------------------------------- */}
      <Section
        id="reach"
        hue="calls"
        tone="inset"
        eyebrow="Who can make your phone ring"
        title="A ringing phone is a permission, so it is treated as one."
        lede={
          <>
            Knowing your account identifier is not enough to make every device you own
            ring at two in the morning. Reaching you by call uses exactly the same gate
            as reaching you by message.
          </>
        }
      >
        <Grid columns={3} gap="md">
          <FeatureCard title="Three ways in, and no fourth" hue="calls" glyph="privacy">
            <p>
              Someone becomes able to reach you by having you in their contacts while you
              have them in yours, by sending a request you accept, or by finding your
              @username and presenting the six-digit PIN you handed out — which still
              only opens a request. Calling inherits that gate rather than reimplementing
              it.
            </p>
          </FeatureCard>

          <FeatureCard title="Both ends, every time" hue="calls" glyph="check">
            <p>
              The check confirms that both people belong to the conversation being rung
              through, not just the caller. Verifying only the caller would let anyone in
              a large group ring a stranger who happens to be in it too.
            </p>
          </FeatureCard>

          <FeatureCard title="The refusal tells you nothing" hue="calls" glyph="eye-off">
            <p>
              A blocked ring does not distinguish &ldquo;you are not a member&rdquo; from
              &ldquo;they are not a member&rdquo;, and an unauthorised call leaves no
              history row and never reaches the other person&rsquo;s device. Probing who
              is where returns the same unhelpful answer every time.
            </p>
          </FeatureCard>
        </Grid>
      </Section>

      {/* ---- the ledger --------------------------------------------------------- */}
      <Section
        id="ledger"
        hue="calls"
        eyebrow="The honest part"
        title="What we keep, and what we could not produce if asked."
        lede={
          <>
            An encrypted call still leaves a trace, because the phone has to ring and the
            missed-call badge has to come from somewhere. Here is that trace in full.
          </>
        }
      >
        <div className={styles.ledger}>
          <div className={styles.ledgerCol}>
            <h3 className={styles.ledgerHead}>
              <span className={styles.ledgerIconOpen} aria-hidden="true">
                <Glyph name="note" size={16} />
              </span>
              One row per call, on our server
            </h3>
            <ul className={styles.ledgerList}>
              <li>The conversation it happened in, and who started it</li>
              <li>Whether it was voice or video</li>
              <li>How it ended: answered, hung up, missed, declined</li>
              <li>When it started, when it was answered, when it ended</li>
            </ul>
            <p className={styles.ledgerFoot}>
              That row is what draws your call history and your missed-call badge. It is
              the whole record.
            </p>
          </div>

          <div className={styles.ledgerCol}>
            <h3 className={styles.ledgerHead}>
              <span className={styles.ledgerIconOk} aria-hidden="true">
                <Glyph name="lock" size={16} />
              </span>
              Never written down anywhere
            </h3>
            <ul className={[styles.ledgerList, styles.ledgerListOk].join(' ')}>
              <li>The audio and the video</li>
              <li>The keys — we hold none, so there is nothing to hand over</li>
              <li>The session descriptions and network candidates</li>
              <li>Any transcript, summary or analysis. There is no such system</li>
            </ul>
            <p className={styles.ledgerFoot}>
              One narrow exception, stated rather than buried: an unanswered offer and
              its candidates are parked for up to a minute so a phone waking from a push
              can still collect them, and are deleted the instant the call resolves.
            </p>
          </div>
        </div>

        <Grid columns={2} gap="md">
          <FeatureCard title="Quality numbers with nobody attached" hue="calls" glyph="sparkle">
            <p>
              We measure whether calling works — did it connect, how quickly, did it need
              a relay, did it drop — because otherwise reliability is guesswork. The
              sample stores no account, no device and no call identifier, and its
              timestamp is rounded to the hour so it cannot be lined up against a
              specific call. The call id is replaced by a keyed hash, which makes a retry
              idempotent and the row unjoinable.
            </p>
          </FeatureCard>

          <FeatureCard title="Your Recents list is yours" hue="calls" glyph="device">
            <p>
              The call log you scroll in the app is written locally, on the device that
              placed or took the call. That has a real downside and the empty state says
              so: a call answered on your other phone will not appear here, and
              reinstalling loses the list.
            </p>
          </FeatureCard>
        </Grid>

        <Callout tone="warn" title="Encrypted is not the same as untraceable." glyph="shield">
          <p>
            We cannot tell you what was said on a call, and neither can anyone who
            compels us — the key was never ours. We can tell that a call happened,
            between which accounts, when, and for how long. That is the honest limit of
            what end-to-end encryption buys you here, and any product that implies
            otherwise is selling you a feeling rather than a mechanism.
          </p>
        </Callout>
      </Section>

      <CTA
        hue="calls"
        title="The rest of the argument."
        lede={
          <>
            Calls are one surface. The privacy page carries the whole picture — including
            the two features that are deliberately not encrypted, and why we would rather
            say so on the tin.
          </>
        }
        actions={
          <ButtonRow align="center">
            <Button href="/privacy" size="lg">
              Read the privacy architecture
            </Button>
            <Button href="/messaging" variant="secondary" size="lg">
              How messaging works
            </Button>
          </ButtonRow>
        }
        note="iOS and Android builds are still in testing. There are no store links yet, and this site will not pretend otherwise."
      />
    </>
  );
}
