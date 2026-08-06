import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Grid, Split } from '../../components/Section';
import { FeatureCard } from '../../components/FeatureCard';
import { CTA } from '../../components/CTA';
import { Button, ButtonRow } from '../../components/Button';
import { E2EEBadge } from '../../components/E2EEBadge';
import { Callout } from '../../components/Callout';
import { Glyph } from '../../components/Glyph';
import {
  PhoneMockup,
  PhoneAppBar,
  ChatBubble,
  PhoneAvatar,
} from '../../components/PhoneMockup';
import styles from './page.module.css';

/*
 * MESSAGING. Every claim below is traceable; the source is named in a comment beside it.
 *
 *   006_messages.sql            — the messages table stores ciphertext only; no plaintext column
 *   013_message_ciphertexts.sql — per-device fan-out: one opaque blob per recipient device
 *   011_mls.sql                 — group plumbing; the server relays opaque MLS bytes, holds no group key
 *   007_message_read_receipts   — delivery/read status is metadata, tracked per recipient device
 *   008_contact_sync.sql        — address-book matching happens on-device; no raw numbers uploaded
 *   019_privacy.sql             — photo / about / last-seen visibility, enforced server-side
 *   020_reachability.sql        — THE model on this page: mutual · one-way · @username + PIN
 *   026_contact_pin_readable    — the PIN is encrypted at rest, NOT E2EE. Said plainly below.
 *   backend/api/src/routes/reachability.ts — 5 wrong guesses/hour, 20/day, per sender per target
 *   backend/api/src/routes/conversations.ts — 'self' type (Note to Self); list filters to accepted
 *   backend/api/src/routes/media.ts — media is encrypted on-device and PUT straight to R2
 *   ios .../Networking/MessageActionWire.swift — reactions/replies/deletes ride the same E2EE pipe
 *   ios .../Main/SafetyNumberView.swift — 60-digit safety number, one per device pair
 *
 * NOT claimed here, because nothing in the repo backs it: a group member limit (no cap is
 * enforced anywhere), blocking, disappearing messages, or any store link.
 *
 * AMBER BUDGET: spent on the contact-PIN digits in the reachability section. Nothing else
 * on this page is amber — no accent button, no refereed badge, no unread pill.
 */

export const metadata: Metadata = {
  title: 'Messaging',
  description:
    'End-to-end encrypted chats, groups and Note to Self — plus the reachability model: ' +
    'a mutual contact, a one-way contact that arrives as a request, or your @username ' +
    'and a six-digit contact PIN. A leaked number list cannot become a spam list.',
};

/* ---------------------------------------------------------------------------
 * The gate. Four states, drawn rather than described: a pair of posts and a
 * barrier that is swung open, latched, locked, or barred. The state is also in
 * the words beside it — the drawing is never the only signal.
 * ------------------------------------------------------------------------ */

type GateState = 'open' | 'held' | 'pin' | 'shut';

function Gate({ state }: { state: GateState }) {
  return (
    <svg
      className={styles.gate}
      viewBox="0 0 64 56"
      width="64"
      height="56"
      aria-hidden="true"
      focusable="false"
    >
      {/* the two posts */}
      <line x1="10" y1="6" x2="10" y2="50" className={styles.gatePost} />
      <line x1="54" y1="6" x2="54" y2="50" className={styles.gatePost} />

      {/* the barrier, hinged on the left post — swung up only when the gate opens */}
      <g transform={state === 'open' ? 'rotate(-46 10 22)' : undefined}>
        <line x1="10" y1="22" x2="54" y2="22" className={styles.gateBar} />
        <circle cx="10" cy="22" r="3" className={styles.gateHinge} />
      </g>

      {/* the emblem below the barrier: pass, held, locked, barred */}
      {state === 'open' ? (
        <path d="M25 40 l5 5 l10 -12" className={styles.gateMark} />
      ) : null}
      {state === 'held' ? (
        <g className={styles.gateMark}>
          {/* an envelope dropping into a tray */}
          <path d="M32 30 v9 M28 35 l4 4 l4 -4" />
          <path d="M23 46 h18 M23 46 v-3 M41 46 v-3" />
        </g>
      ) : null}
      {state === 'pin' ? (
        <g className={styles.gateMark}>
          <rect x="25" y="38" width="14" height="10" rx="2.5" />
          <path d="M28 38 v-3.5 a4 4 0 0 1 8 0 v3.5" />
        </g>
      ) : null}
      {state === 'shut' ? (
        <path d="M26 36 l12 12 M38 36 l-12 12" className={styles.gateMark} />
      ) : null}
    </svg>
  );
}

type Lane = {
  state: GateState;
  step: string;
  title: string;
  body: string;
  outcome: string;
};

/* The four routes, exactly as 020_reachability.sql defines them. */
const LANES: Lane[] = [
  {
    state: 'open',
    step: '1',
    title: 'You have each other saved',
    body:
      'Both address books hold the other person. Voiid reads a mutual link as proof you ' +
      'already know each other, and the conversation opens with no extra step.',
    outcome: 'Opens in your chat list',
  },
  {
    state: 'held',
    step: '2',
    title: 'They have you saved — you do not have them',
    body:
      'A one-way link is deliberately not enough. Their first message arrives as a request ' +
      'you accept or decline. This single rule is what stops a bought number list: it buys ' +
      'a million requests, not a million chats.',
    outcome: 'Waits in Requests',
  },
  {
    state: 'pin',
    step: '3',
    title: 'They typed your @username, and your PIN',
    body:
      'A handle is public, so a handle on its own opens nothing. They must also present the ' +
      'six-digit contact PIN you gave them out loud — and even then, it still lands as a ' +
      'request rather than as a chat.',
    outcome: 'Waits in Requests',
  },
  {
    state: 'shut',
    step: '4',
    title: 'A handle, but the wrong PIN — or none',
    body:
      'The wrong six digits, or a PIN you never set at all: the attempt is refused and ' +
      'counted. Five wrong guesses an hour and twenty a day, counted per sender against ' +
      'each target, so a fresh account does not reset the clock.',
    outcome: 'Refused',
  },
];

export default function MessagingPage() {
  return (
    <>
      <Hero
        hue="chat"
        eyebrow="Messaging"
        title={<>Sealed to the two of you. Open only to people you let in.</>}
        lede={
          <>
            Voiid stores your messages as ciphertext it holds no key for — there is no
            plaintext column in the database to read. And before a stranger can start a
            conversation at all, they have to pass a gate you control: a mutual contact,
            or your <span className={styles.handle}>@username</span> plus a six-digit PIN
            you handed them yourself.
          </>
        }
        badges={
          /* Kept short on purpose: the chip is `white-space: nowrap`, so a longer label
             runs past the viewport on a 320px phone. */
          <E2EEBadge state="e2ee" size="md" label="Chats · Groups · Media · Notes" />
        }
        actions={
          <ButtonRow>
            <Button href="#reachability" size="lg">
              How reachability works
            </Button>
            <Button href="/privacy" variant="secondary" size="lg">
              What we can still see
            </Button>
          </ButtonRow>
        }
        aside={
          <PhoneMockup
            hue="chat"
            size="md"
            tilt="right"
            label="A Voiid chat with Aditi. The header reads 'End-to-end encrypted'; the thread ends with a system note saying messages in the chat are end-to-end encrypted."
          >
            <PhoneAppBar
              title="Aditi"
              subtitle="End-to-end encrypted"
              trailing={<Glyph name="call" size={16} />}
            />
            <div className={styles.thread}>
              <ChatBubble side="received">
                Did the safety number match when you checked?
              </ChatBubble>
              <ChatBubble side="sent" meta="21:12">
                All sixty digits. Nobody in the middle.
              </ChatBubble>
              <ChatBubble side="received">
                Good. Sending the file now.
              </ChatBubble>
              <div className={styles.systemNote}>
                <Glyph name="lock" size={12} />
                Messages and calls in this chat are end-to-end encrypted.
              </div>
            </div>
            <div className={styles.composer}>
              <span className={styles.composerField}>Message</span>
              <PhoneAvatar initials="A" size={26} seed={2} />
            </div>
          </PhoneMockup>
        }
      />

      {/* ---- what actually leaves the phone --------------------------------- */}
      <Section
        id="encryption"
        hue="chat"
        eyebrow="What leaves your phone"
        title="The server keeps a sealed envelope and the address written on it."
        lede={
          <>
            End-to-end encryption is not a setting in Voiid, and there is no way to turn it
            off. It is the shape of the database: the messages table has a ciphertext column
            and no plaintext one, so there is nothing for an employee, an attacker or a
            subpoena to read.
          </>
        }
      >
        <Grid columns={3} gap="md">
          <FeatureCard title="Ciphertext, or nothing" glyph="lock" hue="chat">
            <p>
              A stored message is an opaque blob plus the routing details around it — which
              conversation, which sender, what time. The key that opens the blob never
              leaves the devices in the conversation.
            </p>
          </FeatureCard>

          <FeatureCard title="One envelope per device" glyph="device" hue="chat">
            <p>
              Your phone encrypts the message separately for every device that has to read
              it: your friend&rsquo;s phone, their tablet, your own linked laptop. The
              server files one sealed blob per device and can open none of them.
            </p>
          </FeatureCard>

          <FeatureCard title="Groups are opaque too" glyph="group" hue="chat">
            <p>
              Group key material is agreed between the members&rsquo; own devices using MLS
              (RFC 9420). The server stores and forwards the key packages and the join and
              commit messages as raw bytes, and holds no group key at any point.
            </p>
          </FeatureCard>

          <FeatureCard title="Media never lands on our disk" glyph="shield" hue="chat">
            <p>
              Photos, videos, voice notes and documents are encrypted on your phone and
              uploaded straight to object storage through a short-lived signed URL. The
              message carries only the object key; the bytes at the other end are ciphertext.
            </p>
          </FeatureCard>

          <FeatureCard title="A reaction is a message" glyph="sparkle" hue="chat">
            <p>
              Reactions, replies and delete-for-everyone are encrypted envelopes riding the
              same per-device fan-out. The server learns that something of type
              &ldquo;reaction&rdquo; happened. It never learns which emoji.
            </p>
          </FeatureCard>

          <FeatureCard title="Check there is nobody in the middle" glyph="key" hue="chat">
            <p>
              Encryption proves the key holder can read; it does not prove whose key it is.
              Both sides derive the same 60-digit safety number from their identity keys —
              one per device pair — and compare it in person, not through Voiid.
            </p>
          </FeatureCard>
        </Grid>

        <Callout title="What we do keep, and it is not nothing.">
          <p>
            Encryption hides the contents of a conversation, not the fact of it. Our servers
            hold who sent a message, in which conversation, at what time, a routing hint for
            what kind of message it was, and per-device delivery and read receipts. Address
            books are matched on your phone rather than uploaded, so what we store from that
            is a link between two Voiid accounts — never a list of your contacts&rsquo;
            numbers. Read receipts and typing indicators are switches you can turn off, and
            the toggles gate the only code paths that send them.
          </p>
        </Callout>
      </Section>

      {/* ---- THE REACHABILITY MODEL — the differentiator -------------------- */}
      <Section
        id="reachability"
        hue="chat"
        tone="raised"
        eyebrow="The reachability model"
        title="A leaked number list cannot turn into a spam list."
        lede={
          <>
            On most platforms, holding your phone number is enough to put a message in front
            of you. In Voiid it is not. Until usernames existed, the address book was the
            gate — the only way to learn your account was to already have your number. Adding
            username search removed that gate, so we replaced it with explicit ones, written
            into the database rules rather than into the app&rsquo;s manners.
          </>
        }
      >
        <figure className={styles.figure}>
          <ol className={styles.lanes}>
            {LANES.map((lane) => (
              <li key={lane.step} className={styles.lane} data-state={lane.state}>
                <span className={styles.laneStep} aria-hidden="true">
                  {lane.step}
                </span>
                <span className={styles.laneGate}>
                  <Gate state={lane.state} />
                </span>
                <div className={styles.laneBody}>
                  <h3 className={styles.laneTitle}>{lane.title}</h3>
                  <p className={styles.laneCopy}>{lane.body}</p>
                </div>
                <span className={styles.laneOutcome}>{lane.outcome}</span>
              </li>
            ))}
          </ol>
          <figcaption className={styles.figCaption}>
            The four routes into your inbox. Only the first one opens a chat; two of the
            others open a request you can still refuse; the fourth opens nothing.
          </figcaption>
        </figure>

        <Split
          reverse
          aside={
            <div className={styles.pinPanel}>
              <span className={styles.pinLabel}>Your contact PIN</span>
              <p className={styles.pinSpoken}>
                &ldquo;My Voiid is <span className={styles.handle}>@nehal</span>, PIN&hellip;&rdquo;
              </p>
              {/* The page's one amber moment. */}
              <span className={styles.pinDigits}>418302</span>

              <div className={styles.meters}>
                <div className={styles.meter}>
                  <span className={styles.meterHead}>
                    <strong>5</strong> wrong guesses an hour
                  </span>
                  <span className={styles.meterDots} aria-hidden="true">
                    {Array.from({ length: 5 }, (_, i) => (
                      <span key={i} className={styles.dot} />
                    ))}
                  </span>
                </div>
                <div className={styles.meter}>
                  <span className={styles.meterHead}>
                    <strong>20</strong> a day, then the sender is done
                  </span>
                  <span className={[styles.meterDots, styles.meterDotsFine].join(' ')} aria-hidden="true">
                    {Array.from({ length: 20 }, (_, i) => (
                      <span key={i} className={styles.tick} />
                    ))}
                  </span>
                </div>
              </div>
            </div>
          }
        >
          <h3 className={styles.subhead}>Six digits you say out loud</h3>
          <p className={styles.copy}>
            The contact PIN is a proof of acquaintance, handed over the way you hand over a
            table number: in person, on a call, on a card. It is not a password. Knowing it
            grants exactly one thing — permission to open a request that the recipient still
            has to accept. It unlocks no account, reads no data, and sends nothing on its own.
          </p>
          <p className={styles.copy}>
            Which means the rate limit is not a refinement of the security model, it is the
            security model. Six digits is a million combinations, and a million combinations
            falls in minutes to anyone allowed to guess freely. So guesses are counted
            against the pair — five an hour, twenty a day — and the ledger is keyed on the
            target as well as the sender, so registering a fresh account does not hand an
            attacker a fresh allowance.
          </p>
          <p className={styles.copy}>
            Rotate the PIN and everyone still holding the old six digits loses reach the
            same second. The attempt ledger is cleared along with it, so a real acquaintance
            who fumbled their way into a lockout starts clean against the new number.
          </p>

          <Callout title="The contact PIN is not end-to-end encrypted.">
            <p>
              It cannot be, and we would rather write that here than let you assume
              otherwise. The server has to compare it against a guess, and you have to be
              able to look your own up instead of keeping it on a scrap of paper. So it is
              sealed with AES-256-GCM under a key that lives in the server&rsquo;s
              environment and not in the database — a stolen database dump on its own does
              not yield it — but with both, we can read your PIN. We cannot read a single
              message that PIN lets somebody send.
            </p>
          </Callout>
        </Split>
      </Section>

      {/* ---- the requests inbox -------------------------------------------- */}
      <Section
        id="requests"
        hue="chat"
        eyebrow="Requests"
        title={<>A stranger&rsquo;s first message waits in its own room.</>}
      >
        <Split
          aside={
            <PhoneMockup
              hue="chat"
              size="md"
              label="The Message requests screen in Voiid, listing two people waiting to be accepted, each with an Accept and a Decline button."
            >
              <PhoneAppBar title="Message requests" subtitle="2 waiting" />
              <div className={styles.requestList}>
                <div className={styles.request}>
                  <div className={styles.requestWho}>
                    <PhoneAvatar initials="RK" size={30} seed={0} />
                    <span className={styles.requestText}>
                      <span className={styles.requestName}>Rohan Kapoor</span>
                      <span className={styles.requestVia}>
                        Found you by @rohank
                      </span>
                    </span>
                  </div>
                  <div className={styles.requestActions}>
                    <span className={styles.requestDecline}>Decline</span>
                    <span className={styles.requestAccept}>Accept</span>
                  </div>
                </div>

                <div className={styles.request}>
                  <div className={styles.requestWho}>
                    <PhoneAvatar initials="M" size={30} seed={3} />
                    <span className={styles.requestText}>
                      <span className={styles.requestName}>Meera</span>
                      <span className={styles.requestVia}>Has you in her contacts</span>
                    </span>
                  </div>
                  <div className={styles.requestActions}>
                    <span className={styles.requestDecline}>Decline</span>
                    <span className={styles.requestAccept}>Accept</span>
                  </div>
                </div>

                <p className={styles.requestFoot}>
                  Requests stay here until you accept. Nobody is told either way.
                </p>
              </div>
            </PhoneMockup>
          }
        >
          <p className={styles.copy}>
            A pending request never appears in your chat list. The conversation list is
            filtered to accepted memberships, so an opening line from someone you have never
            met cannot arrive between two people you actually talk to.
          </p>
          <p className={styles.copy}>
            The pending flag lives on your membership rather than on the conversation,
            because a one-to-one has two sides in different states: the sender accepted by
            sending, and you have not. That also means the same machinery covers a group
            invite without inventing a second mechanism for it.
          </p>
          <p className={styles.copy}>
            <strong>Declining tells the sender nothing.</strong> If a declined request looked
            different from an unopened one, a request would become a presence oracle — send
            one, learn whether an account is live and attended. From their side, both look
            identical: the message reads Sent, and goes on reading Sent.
          </p>
          <p className={styles.copy}>
            None of this is a weaker kind of message. A pending request holds ordinary
            ciphertext the server cannot read; it is simply not surfaced as a chat yet.
            Reachability decides who may open a conversation. It never touches the
            encryption inside one.
          </p>
        </Split>
      </Section>

      {/* ---- the rest of the everyday ---------------------------------------- */}
      <Section
        id="everyday"
        hue="chat"
        eyebrow="The rest of it"
        title="Groups, a chat with yourself, and every device you own."
      >
        <Grid columns={2} gap="md" className={styles.pairGrid}>
          <FeatureCard title="Groups" glyph="group" hue="chat" meta={<E2EEBadge state="e2ee" />}>
            <p>
              Name a group, add people you already have, and the members&rsquo; devices
              negotiate the group&rsquo;s keys between themselves. Whoever creates it is the
              admin. Joins and membership changes travel as control messages the server
              relays without being able to open them.
            </p>
          </FeatureCard>

          <FeatureCard title="Note to Self" glyph="note" hue="chat" meta={<E2EEBadge state="e2ee" />}>
            <p>
              Your own chat, with exactly one member: you. It has its own conversation type
              rather than being a one-to-one with yourself, so it can never collide with a
              real conversation. Notes are encrypted to your other devices like any message
              — and with a single device, they simply never leave it.
            </p>
          </FeatureCard>

          <FeatureCard title="Your second device" glyph="device" hue="chat" meta={<E2EEBadge state="e2ee" />}>
            <p>
              A linked device gets its own session and its own identity key — which is why a
              contact with a phone and a tablet has two safety numbers to check, not one.
              Every message is encrypted once per device, so no device ever hands another one
              a key.
            </p>
          </FeatureCard>

          <FeatureCard title="Who sees what about you" glyph="eye-off" hue="chat">
            <p>
              Your profile photo, your about line and your last-seen time are each set to
              everyone, contacts only, or nobody — and that choice is enforced on the server,
              not merely hidden in someone else&rsquo;s app. Read receipts and typing
              indicators are separate switches on your device.
            </p>
          </FeatureCard>
        </Grid>
      </Section>

      <CTA
        hue="chat"
        title="The gate is the feature."
        lede={
          <>
            Encryption decides what a message says to anyone who intercepts it. Reachability
            decides whether the message reaches you at all. Voiid is one of the few places
            both answers are written down where you can check them.
          </>
        }
        actions={
          <ButtonRow align="center">
            <Button href="/privacy" size="lg">
              Everything we can and cannot see
            </Button>
            <Button href="/calls" variant="secondary" size="lg">
              How calls work
            </Button>
          </ButtonRow>
        }
        note="iOS and Android builds are still in testing. There are no App Store or Play links yet, and this site will not invent one."
      />
    </>
  );
}
